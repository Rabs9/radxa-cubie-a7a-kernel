#!/bin/bash
# =============================================================================
# Radxa Cubie A7A - Iterative Build-Deploy-Debug Loop
#
# Watches for DTS/config changes, rebuilds, deploys, reboots the board,
# and captures the boot log over serial console.
#
# Usage:
#   ./loop.sh <user@host> [serial_port]
#
# Examples:
#   ./loop.sh radxa@192.168.1.100                    # SSH deploy, no serial
#   ./loop.sh radxa@192.168.1.100 /dev/ttyUSB0       # SSH deploy + serial log
# =============================================================================
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
SERIAL_PORT="${2:-}"
SERIAL_BAUD=115200
LOG_DIR="${WORKSPACE}/logs"
ITERATION=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[LOOP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
header() { echo -e "\n${BOLD}════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════${NC}\n"; }

if [ -z "${TARGET}" ]; then
    echo "Usage: $0 <user@host> [serial_port]"
    echo ""
    echo "Iterative kernel build-deploy-debug loop."
    echo "Watches for changes, rebuilds, deploys over SSH, captures dmesg."
    echo ""
    echo "  user@host     SSH target (e.g., radxa@192.168.1.100)"
    echo "  serial_port   Optional serial console (e.g., /dev/ttyUSB0)"
    echo ""
    echo "Workflow per iteration:"
    echo "  1. Wait for you to make changes (DTS, config, source)"
    echo "  2. Rebuild (dtb-only for DTS changes, full for source changes)"
    echo "  3. Deploy to board over SSH"
    echo "  4. Reboot board"
    echo "  5. Capture boot log (serial or SSH dmesg)"
    echo "  6. Show summary + errors"
    echo "  7. Back to step 1"
    exit 1
fi

mkdir -p "${LOG_DIR}"

# Track file timestamps for change detection
snapshot_timestamps() {
    find "${WORKSPACE}/allwinner-device/configs/cubie_a7a" \
         "${WORKSPACE}/allwinner-bsp/configs/linux-5.15" \
         -name "*.dts" -o -name "*.dtsi" -o -name "*defconfig*" 2>/dev/null | \
    xargs stat -c '%n %Y' 2>/dev/null | sort
}

# Determine what changed
detect_changes() {
    local OLD_SNAP="$1"
    local NEW_SNAP="$2"

    local CHANGED=$(diff <(echo "$OLD_SNAP") <(echo "$NEW_SNAP") | grep "^>" | awk '{print $2}')

    if [ -z "$CHANGED" ]; then
        echo "none"
        return
    fi

    # Check if only DTS changed (fast path) or if config/source changed too
    local DTS_ONLY=true
    while IFS= read -r file; do
        if [[ ! "$file" =~ \.dts$ ]] && [[ ! "$file" =~ \.dtsi$ ]]; then
            DTS_ONLY=false
            break
        fi
    done <<< "$CHANGED"

    if $DTS_ONLY; then
        echo "dts"
    else
        echo "full"
    fi
}

# Wait for board to come back online after reboot
wait_for_board() {
    local MAX_WAIT=120
    local WAITED=0
    log "Waiting for board to come back online..."

    while ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${TARGET}" "true" 2>/dev/null; do
        sleep 3
        WAITED=$((WAITED + 3))
        if [ $WAITED -ge $MAX_WAIT ]; then
            err "Board didn't come back after ${MAX_WAIT}s"
            return 1
        fi
        printf "."
    done
    echo ""
    log "Board is online (took ${WAITED}s)"
}

# Capture boot log
capture_boot_log() {
    local LOG_FILE="${LOG_DIR}/boot-$(date +%Y%m%d-%H%M%S)-iter${ITERATION}.log"

    if [ -n "${SERIAL_PORT}" ] && [ -c "${SERIAL_PORT}" ]; then
        # Capture serial output during reboot
        log "Capturing serial boot log from ${SERIAL_PORT}..."
        timeout 90 cat "${SERIAL_PORT}" > "${LOG_FILE}" 2>/dev/null &
        local SERIAL_PID=$!

        # Reboot the board
        ssh "${TARGET}" "sudo reboot" 2>/dev/null || true

        # Wait for serial capture to finish
        wait $SERIAL_PID 2>/dev/null || true
    else
        # Reboot and capture dmesg after boot
        ssh "${TARGET}" "sudo reboot" 2>/dev/null || true
        wait_for_board || return 1
        ssh "${TARGET}" "dmesg" > "${LOG_FILE}" 2>/dev/null
    fi

    echo "${LOG_FILE}"
}

# Analyze boot log for errors
analyze_log() {
    local LOG_FILE="$1"

    if [ ! -f "${LOG_FILE}" ]; then
        warn "No log file to analyze"
        return
    fi

    local ERRORS=$(grep -ciE "error|fail|panic|oops|bug|unable" "${LOG_FILE}" 2>/dev/null || echo 0)
    local WARNINGS=$(grep -ciE "warning|warn" "${LOG_FILE}" 2>/dev/null || echo 0)

    info "Boot log: ${LOG_FILE}"
    info "Lines: $(wc -l < "${LOG_FILE}"), Errors: ${ERRORS}, Warnings: ${WARNINGS}"

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        err "=== ERRORS FOUND ==="
        grep -inE "error|fail|panic|oops|bug|unable" "${LOG_FILE}" | head -30
        echo ""
    fi

    # Show probe results for key hardware
    info "=== Hardware Probe Summary ==="
    for hw in "gpu\|pvr\|imagination\|drm" "npu\|galcore\|vip" "mmc\|sdc\|emmc" "gmac\|ethernet\|stmmac" "usb\|dwc3\|ehci" "wifi\|aic8800\|wlan" "thermal\|cpu.*freq"; do
        local MATCHES=$(grep -ciE "${hw}" "${LOG_FILE}" 2>/dev/null || echo 0)
        local STATUS="---"
        if [ "$MATCHES" -gt 0 ]; then
            if grep -qiE "(${hw}).*error\|fail.*(${hw})" "${LOG_FILE}" 2>/dev/null; then
                STATUS="${RED}FAIL${NC}"
            else
                STATUS="${GREEN}OK${NC}"
            fi
        fi
        printf "  %-20s %b (%d messages)\n" "${hw%%\\*}" "${STATUS}" "${MATCHES}"
    done
}

# Main loop
main_loop() {
    header "Radxa Cubie A7A — Build-Debug Loop"
    info "Target: ${TARGET}"
    info "Serial: ${SERIAL_PORT:-none}"
    info "Logs:   ${LOG_DIR}"
    echo ""
    log "Taking initial snapshot of source files..."

    local LAST_SNAP=$(snapshot_timestamps)

    while true; do
        ITERATION=$((ITERATION + 1))
        header "Iteration #${ITERATION} — Waiting for changes..."
        info "Edit your DTS/DTSI/config files, then press ENTER to build."
        info "Or type 'q' to quit, 'f' for forced full rebuild, 'd' for dmesg only."
        echo ""

        read -r CMD
        case "${CMD}" in
            q|quit|exit)
                log "Exiting loop."
                exit 0
                ;;
            d|dmesg)
                log "Fetching current dmesg..."
                local DMESG_LOG="${LOG_DIR}/dmesg-$(date +%Y%m%d-%H%M%S).log"
                ssh "${TARGET}" "dmesg" > "${DMESG_LOG}"
                analyze_log "${DMESG_LOG}"
                continue
                ;;
            f|full)
                log "Forced full rebuild..."
                local BUILD_TYPE="full"
                ;;
            *)
                # Auto-detect what changed
                local NEW_SNAP=$(snapshot_timestamps)
                local BUILD_TYPE=$(detect_changes "${LAST_SNAP}" "${NEW_SNAP}")
                LAST_SNAP="${NEW_SNAP}"

                if [ "${BUILD_TYPE}" = "none" ]; then
                    warn "No file changes detected. Building anyway (DTS only)..."
                    BUILD_TYPE="dts"
                fi
                ;;
        esac

        # BUILD
        header "Building (${BUILD_TYPE})..."
        local BUILD_OK=true

        if [ "${BUILD_TYPE}" = "dts" ]; then
            "${WORKSPACE}/build.sh" dtb || BUILD_OK=false
        else
            "${WORKSPACE}/build.sh" build || BUILD_OK=false
            if $BUILD_OK; then
                "${WORKSPACE}/build.sh" package || BUILD_OK=false
            fi
        fi

        if ! $BUILD_OK; then
            err "Build failed! Fix errors and try again."
            continue
        fi

        # DEPLOY
        header "Deploying to ${TARGET}..."
        if [ "${BUILD_TYPE}" = "dts" ]; then
            "${WORKSPACE}/deploy.sh" dtb-ssh "${TARGET}" || { err "Deploy failed!"; continue; }
        else
            "${WORKSPACE}/deploy.sh" ssh "${TARGET}" || { err "Deploy failed!"; continue; }
        fi

        # REBOOT + CAPTURE LOG
        header "Rebooting board and capturing boot log..."
        local LOG_FILE=$(capture_boot_log)

        if [ -z "${SERIAL_PORT}" ]; then
            # If no serial, we already waited for SSH, get dmesg
            wait_for_board || continue
            LOG_FILE="${LOG_DIR}/boot-$(date +%Y%m%d-%H%M%S)-iter${ITERATION}.log"
            ssh "${TARGET}" "dmesg" > "${LOG_FILE}" 2>/dev/null
        fi

        # ANALYZE
        header "Boot Log Analysis — Iteration #${ITERATION}"
        analyze_log "${LOG_FILE}"

        # Quick kernel version check
        echo ""
        info "Running kernel:"
        ssh "${TARGET}" "uname -a" 2>/dev/null || warn "Could not get uname"
    done
}

main_loop
