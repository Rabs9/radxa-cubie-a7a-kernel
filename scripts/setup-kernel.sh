#!/bin/bash
# Set up the kernel tree for building
# Run from the repo root after cloning source repos and applying patches
set -euo pipefail

BSP="${1:-allwinner-bsp-1.4.8}"
KERNEL="${2:-kernel-6.6}"
DEVICE="${3:-allwinner-device-1.4.8}"

echo "Setting up kernel tree..."

# 1. BSP symlink
ln -sfn "$(pwd)/$BSP" "$KERNEL/bsp"
echo "[1/4] BSP symlink created"

# 2. Copy DTS/DTSI files
DTS_DIR="$KERNEL/arch/arm64/boot/dts/allwinner"
cp "$BSP/configs/linux-6.6/sun60iw2p1.dtsi" "$DTS_DIR/"
cp "$BSP/configs/linux-6.6/sun60iw2p1-cpu-vf.dtsi" "$DTS_DIR/"
cp "$DEVICE/configs/cubie_a7a/linux-6.6/board.dts" "$DTS_DIR/sun60i-a733-cubie-a7a.dts"

if ! grep -q "sun60i-a733-cubie-a7a" "$DTS_DIR/Makefile"; then
    echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun60i-a733-cubie-a7a.dtb' >> "$DTS_DIR/Makefile"
fi
echo "[2/4] DTS files copied"

# 3. Copy dt-bindings headers
INC="$KERNEL/include/dt-bindings"
mkdir -p "$INC/spi"
cp -u "$BSP/include/dt-bindings/clock/sun60iw2-"*.h "$INC/clock/"
cp -u "$BSP/include/dt-bindings/clock/sunxi-clk.h" "$INC/clock/" 2>/dev/null || true
cp -u "$BSP/include/dt-bindings/clock/sunxi-ccu.h" "$INC/clock/" 2>/dev/null || true
cp -u "$BSP/include/dt-bindings/reset/sun60iw2-"*.h "$INC/reset/"
cp -u "$BSP/include/dt-bindings/power/sun60iw2-power.h" "$INC/power/"
cp -u "$BSP/include/dt-bindings/display/sunxi-lcd.h" "$INC/display/" 2>/dev/null || true
cp -u "$BSP/include/dt-bindings/display/lcd_command.h" "$INC/display/" 2>/dev/null || true
cp -u "$BSP/include/dt-bindings/gpio/sun4i-gpio.h" "$INC/gpio/" 2>/dev/null || true
cp -u "$BSP/include/dt-bindings/spi/sunxi-spi.h" "$INC/spi/" 2>/dev/null || true
echo "[3/4] dt-bindings headers copied"

# 4. Configure
cd "$KERNEL"
if [ -f "../configs/cubie_a7a_defconfig" ]; then
    cp "../configs/cubie_a7a_defconfig" arch/arm64/configs/
    echo "[4/4] Defconfig installed"
else
    echo "[4/4] No defconfig found, run merge-config manually"
fi

echo ""
echo "Kernel tree ready. Build with:"
echo "  cd $KERNEL"
echo "  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ cubie_a7a_defconfig"
echo "  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ -j\$(nproc) Image dtbs modules"
