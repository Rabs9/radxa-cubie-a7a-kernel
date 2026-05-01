#!/bin/bash
# =============================================================================
# Radxa Cubie A7A Kernel Build Script
# SoC: Allwinner A733 (sun60iw2p1)
# BSP Kernel: Linux 5.15
# =============================================================================
set -euo pipefail

# Paths
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${WORKSPACE}/kernel"
BSP_DIR="${WORKSPACE}/allwinner-bsp"
DEVICE_DIR="${WORKSPACE}/allwinner-device"
OUTPUT_DIR="${WORKSPACE}/output"
BOARD_DTS_SRC="${DEVICE_DIR}/configs/cubie_a7a/linux-5.15/board.dts"

# Cross-compilation
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export BSP_TOP=bsp/

# Parallel jobs — use all cores
JOBS=$(nproc)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# -----------------------------------------------------------------------------
# Setup: ensure BSP symlink and DTS files are in place
# -----------------------------------------------------------------------------
setup() {
    log "Setting up kernel tree..."

    # BSP symlink
    if [ ! -L "${KERNEL_DIR}/bsp" ]; then
        ln -sfn "${BSP_DIR}" "${KERNEL_DIR}/bsp"
        log "Created BSP symlink"
    fi

    # Copy SoC DTSI files
    local DTS_DIR="${KERNEL_DIR}/arch/arm64/boot/dts/allwinner"
    cp -u "${BSP_DIR}/configs/linux-5.15/sun60iw2p1.dtsi" "${DTS_DIR}/"
    cp -u "${BSP_DIR}/configs/linux-5.15/sun60iw2p1-cpu-vf.dtsi" "${DTS_DIR}/"

    # Copy board DTS (always refresh from source)
    cp "${BOARD_DTS_SRC}" "${DTS_DIR}/sun60i-a733-cubie-a7a.dts"

    # Ensure board is in DTS Makefile
    if ! grep -q "sun60i-a733-cubie-a7a" "${DTS_DIR}/Makefile"; then
        echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun60i-a733-cubie-a7a.dtb' >> "${DTS_DIR}/Makefile"
        log "Added A7A to DTS Makefile"
    fi

    # Copy BSP dt-bindings headers
    local INC="${KERNEL_DIR}/include/dt-bindings"
    mkdir -p "${INC}/spi"
    cp -u "${BSP_DIR}/include/dt-bindings/clock/sun60iw2-"*.h "${INC}/clock/"
    cp -u "${BSP_DIR}/include/dt-bindings/clock/sunxi-clk.h" "${INC}/clock/" 2>/dev/null || true
    cp -u "${BSP_DIR}/include/dt-bindings/clock/sunxi-ccu.h" "${INC}/clock/" 2>/dev/null || true
    cp -u "${BSP_DIR}/include/dt-bindings/reset/sun60iw2-"*.h "${INC}/reset/"
    cp -u "${BSP_DIR}/include/dt-bindings/power/sun60iw2-power.h" "${INC}/power/"
    cp -u "${BSP_DIR}/include/dt-bindings/display/sunxi-lcd.h" "${INC}/display/" 2>/dev/null || true
    cp -u "${BSP_DIR}/include/dt-bindings/display/lcd_command.h" "${INC}/display/" 2>/dev/null || true
    cp -u "${BSP_DIR}/include/dt-bindings/gpio/sun4i-gpio.h" "${INC}/gpio/" 2>/dev/null || true
    cp -u "${BSP_DIR}/include/dt-bindings/spi/sunxi-spi.h" "${INC}/spi/" 2>/dev/null || true

    # Create auto-generated BSP header if missing
    if [ ! -f "${BSP_DIR}/include/sunxi-autogen.h" ]; then
        cat > "${BSP_DIR}/include/sunxi-autogen.h" <<'HEADER'
/* Auto-generated BSP version header */
#ifndef _SUNXI_AUTOGEN_H
#define _SUNXI_AUTOGEN_H
#define AW_BSP_VERSION "cubie-aiot-v1.4.6-custom"
#endif
HEADER
        log "Created sunxi-autogen.h"
    fi

    mkdir -p "${OUTPUT_DIR}"
    log "Setup complete"
}

# -----------------------------------------------------------------------------
# Configure: generate .config from defconfig
# -----------------------------------------------------------------------------
configure() {
    log "Configuring kernel..."
    cd "${KERNEL_DIR}"

    if [ ! -f arch/arm64/configs/cubie_a7a_defconfig ]; then
        err "cubie_a7a_defconfig not found! Run 'merge-config' first."
        exit 1
    fi

    make cubie_a7a_defconfig
    log "Configuration complete"
}

# -----------------------------------------------------------------------------
# Merge config: create defconfig from base + BSP fragment
# -----------------------------------------------------------------------------
merge_config() {
    log "Merging base defconfig with BSP configs..."
    cd "${KERNEL_DIR}"

    scripts/kconfig/merge_config.sh \
        arch/arm64/configs/defconfig \
        "${DEVICE_DIR}/configs/default/linux-5.15/bsp_defconfig"

    cp .config arch/arm64/configs/cubie_a7a_defconfig
    log "Saved merged config as cubie_a7a_defconfig ($(grep -c '=' arch/arm64/configs/cubie_a7a_defconfig) options)"
}

# -----------------------------------------------------------------------------
# Menuconfig: interactive kernel configuration
# -----------------------------------------------------------------------------
menuconfig() {
    log "Opening menuconfig..."
    cd "${KERNEL_DIR}"
    make menuconfig
    log "Saving updated config..."
    cp .config arch/arm64/configs/cubie_a7a_defconfig
}

# -----------------------------------------------------------------------------
# Build: compile kernel Image, DTB, and modules
# -----------------------------------------------------------------------------
build_kernel() {
    log "Building kernel with ${JOBS} jobs..."
    cd "${KERNEL_DIR}"

    local START=$(date +%s)

    # Build kernel Image
    make -j${JOBS} Image 2>&1 | tee "${OUTPUT_DIR}/build_kernel.log"
    local KRET=${PIPESTATUS[0]}
    if [ $KRET -ne 0 ]; then
        err "Kernel Image build FAILED (exit code: $KRET)"
        err "Check ${OUTPUT_DIR}/build_kernel.log"
        return $KRET
    fi
    log "Kernel Image built successfully"

    # Build DTB
    make -j${JOBS} dtbs 2>&1 | tee "${OUTPUT_DIR}/build_dtbs.log"
    local DRET=${PIPESTATUS[0]}
    if [ $DRET -ne 0 ]; then
        err "DTB build FAILED (exit code: $DRET)"
        err "Check ${OUTPUT_DIR}/build_dtbs.log"
        return $DRET
    fi
    log "DTBs built successfully"

    # Build modules
    make -j${JOBS} modules 2>&1 | tee "${OUTPUT_DIR}/build_modules.log"
    local MRET=${PIPESTATUS[0]}
    if [ $MRET -ne 0 ]; then
        err "Modules build FAILED (exit code: $MRET)"
        err "Check ${OUTPUT_DIR}/build_modules.log"
        return $MRET
    fi
    log "Modules built successfully"

    local END=$(date +%s)
    local ELAPSED=$((END - START))
    log "Total build time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
}

# -----------------------------------------------------------------------------
# Package: collect build artifacts into output directory
# -----------------------------------------------------------------------------
package() {
    log "Packaging build artifacts..."
    cd "${KERNEL_DIR}"

    local PKG_DIR="${OUTPUT_DIR}/package"
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}/boot" "${PKG_DIR}/lib/modules"

    # Kernel Image
    cp arch/arm64/boot/Image "${PKG_DIR}/boot/"
    log "Copied kernel Image ($(du -h arch/arm64/boot/Image | cut -f1))"

    # DTB
    local DTB="arch/arm64/boot/dts/allwinner/sun60i-a733-cubie-a7a.dtb"
    if [ -f "${DTB}" ]; then
        cp "${DTB}" "${PKG_DIR}/boot/"
        log "Copied DTB"
    else
        warn "DTB not found at ${DTB}"
    fi

    # Modules
    make modules_install INSTALL_MOD_PATH="${PKG_DIR}" INSTALL_MOD_STRIP=1
    log "Installed modules to ${PKG_DIR}/lib/modules/"

    # Kernel version
    local KVER=$(make -s kernelrelease)
    echo "${KVER}" > "${PKG_DIR}/boot/kernel-version.txt"

    log "Package ready at: ${PKG_DIR}"
    log "Kernel version: ${KVER}"

    # Summary
    info "Package contents:"
    find "${PKG_DIR}" -type f | head -20
    echo "..."
    info "Total size: $(du -sh "${PKG_DIR}" | cut -f1)"
}

# -----------------------------------------------------------------------------
# Build DTB only (fast iteration on DTS changes)
# -----------------------------------------------------------------------------
build_dtb_only() {
    log "Building DTB only..."
    cd "${KERNEL_DIR}"

    # Refresh board DTS from source
    local DTS_DIR="arch/arm64/boot/dts/allwinner"
    cp "${BOARD_DTS_SRC}" "${DTS_DIR}/sun60i-a733-cubie-a7a.dts"

    make -j${JOBS} allwinner/sun60i-a733-cubie-a7a.dtb
    local DTB="${DTS_DIR}/sun60i-a733-cubie-a7a.dtb"
    if [ -f "${DTB}" ]; then
        cp "${DTB}" "${OUTPUT_DIR}/"
        log "DTB built: ${OUTPUT_DIR}/sun60i-a733-cubie-a7a.dtb"
    else
        err "DTB build failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------
clean() {
    log "Cleaning build..."
    cd "${KERNEL_DIR}"
    make clean
    log "Clean complete"
}

distclean() {
    log "Full clean (including config)..."
    cd "${KERNEL_DIR}"
    make mrproper
    log "Distclean complete"
}

# -----------------------------------------------------------------------------
# Info: print build environment
# -----------------------------------------------------------------------------
show_info() {
    info "=== Radxa Cubie A7A Kernel Build Environment ==="
    info "Workspace:      ${WORKSPACE}"
    info "Kernel:         ${KERNEL_DIR}"
    info "BSP:            ${BSP_DIR}"
    info "Device:         ${DEVICE_DIR}"
    info "Output:         ${OUTPUT_DIR}"
    info "ARCH:           ${ARCH}"
    info "CROSS_COMPILE:  ${CROSS_COMPILE}"
    info "BSP_TOP:        ${BSP_TOP}"
    info "Parallel jobs:  ${JOBS}"
    info ""
    info "Toolchain:"
    ${CROSS_COMPILE}gcc --version | head -1
    info ""
    if [ -f "${KERNEL_DIR}/.config" ]; then
        info "Kernel config:  exists ($(grep -c '=y\|=m' "${KERNEL_DIR}/.config") enabled options)"
    else
        info "Kernel config:  NOT CONFIGURED (run: $0 configure)"
    fi
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup        - Set up kernel tree (BSP symlink, DTS, headers)"
    echo "  merge-config - Merge base + BSP defconfigs into cubie_a7a_defconfig"
    echo "  configure    - Apply cubie_a7a_defconfig to .config"
    echo "  menuconfig   - Interactive kernel configuration"
    echo "  build        - Build kernel Image, DTBs, and modules"
    echo "  dtb          - Build DTB only (fast DTS iteration)"
    echo "  package      - Collect build artifacts into output/"
    echo "  clean        - Clean build artifacts"
    echo "  distclean    - Full clean including config"
    echo "  info         - Show build environment info"
    echo "  all          - setup + configure + build + package"
    echo ""
    echo "Typical first build:"
    echo "  $0 setup"
    echo "  $0 merge-config"
    echo "  $0 configure"
    echo "  $0 build"
    echo "  $0 package"
    echo ""
    echo "Fast DTS iteration:"
    echo "  # Edit allwinner-device/configs/cubie_a7a/linux-5.15/board.dts"
    echo "  $0 dtb"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
case "${1:-}" in
    setup)        setup ;;
    merge-config) setup && merge_config ;;
    configure)    setup && configure ;;
    menuconfig)   setup && configure && menuconfig ;;
    build)        build_kernel ;;
    dtb)          setup && build_dtb_only ;;
    package)      package ;;
    clean)        clean ;;
    distclean)    distclean ;;
    info)         show_info ;;
    all)          setup && configure && build_kernel && package ;;
    *)            usage ;;
esac
