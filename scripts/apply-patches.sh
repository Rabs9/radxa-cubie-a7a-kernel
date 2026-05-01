#!/bin/bash
# Apply all BSP patches required for building the A7A kernel
# Run from the repo root after cloning source repos
set -euo pipefail

BSP="${1:-allwinner-bsp-1.4.8}"
KERNEL="${2:-kernel-6.6}"

echo "Applying BSP patches to $BSP..."

# 1. Create sunxi-autogen.h
cat > "$BSP/include/sunxi-autogen.h" <<'HEADER'
#ifndef _SUNXI_AUTOGEN_H
#define _SUNXI_AUTOGEN_H
#define AW_BSP_VERSION "cubie-aiot-v1.4.8-custom"
#endif
HEADER
echo "[1/7] Created sunxi-autogen.h"

# 2. Fix USB include (angle brackets to quotes)
sed -i 's|#include <\.\./sunxi_usb/include/sunxi_usb_debug.h>|#include "../sunxi_usb/include/sunxi_usb_debug.h"|' \
  "$BSP/drivers/usb/host/sunxi-hci.h"
echo "[2/7] Fixed USB host include"

# 3. Fix sound platform Makefile
sed -i '/ccflags-y += -I $(srctree)\/bsp\/drivers\/sound\/adapter/a ccflags-y += -I $(srctree)/bsp/drivers/sound/platform' \
  "$BSP/drivers/sound/platform/Makefile"
echo "[3/7] Fixed sound platform include"

# 4. Fix cedar VE Makefile
sed -i 's|# ccflags-y += -I $(srctree)/drivers/media/cedar-ve|ccflags-y += -I $(src)|' \
  "$BSP/drivers/ve/cedar-ve/Makefile"
echo "[4/7] Fixed cedar-ve include"

# 5. Fix GMAC Makefile
sed -i '/ccflag-y+= -DDYNAMIC_DEBUG_MODULE/a CFLAGS_sunxi-gmac.o += -I$(src)' \
  "$BSP/drivers/gmac/Makefile"
echo "[5/7] Fixed GMAC trace include"

# 6. Fix NAND/GPU Makefiles (add srctree fallback)
sed -i 's|KERNEL_SRC_DIR := $(word 1, $(KERNEL_SRC_DIR) $(KERNEL_SRC))|KERNEL_SRC_DIR := $(word 1, $(KERNEL_SRC_DIR) $(KERNEL_SRC) $(srctree))|' \
  "$BSP/modules/nand/Makefile" "$BSP/modules/gpu/Makefile"
echo "[6/7] Fixed NAND/GPU KERNEL_SRC_DIR"

# 7. Add cpufreq-dt-platdev blocklist entry
if [ -f "$KERNEL/drivers/cpufreq/cpufreq-dt-platdev.c" ]; then
  if ! grep -q "sun60iw2p1" "$KERNEL/drivers/cpufreq/cpufreq-dt-platdev.c"; then
    sed -i '/{ .compatible = "allwinner,sun50i-h6", },/a\\t{ .compatible = "allwinner,sun60i-a733", },\n\t{ .compatible = "arm,sun60iw2p1", },' \
      "$KERNEL/drivers/cpufreq/cpufreq-dt-platdev.c"
    echo "[7/7] Added sun60iw2p1 to cpufreq-dt-platdev blocklist"
  else
    echo "[7/7] cpufreq blocklist already patched"
  fi
else
  echo "[7/7] Skipped (kernel not found at $KERNEL)"
fi

echo ""
echo "All patches applied successfully."
echo "Next: Set up kernel tree with ./scripts/setup-kernel.sh"
