# Radxa Cubie A7A — Custom Kernel & Hardware Tuning

Custom Linux 6.6.98 kernel build with full hardware support and overclocking for the Radxa Cubie A7A (Allwinner A733 SoC).

**The vendor abandoned this board** — shipping only Debian 11 with a dead-end Linux 5.15 kernel, no GPU acceleration, broken cpufreq, and incomplete hardware support. This project fixes all of that.

## What This Gives You

| Feature | Stock (Radxa) | This Project |
|---------|---------------|--------------|
| **Kernel** | 5.15.147 | **6.6.98+** |
| **OS** | Debian 11 (EOL) | **Debian 13 Trixie** |
| **CPU A55** | 1794 MHz (no scaling) | **2000 MHz (+11.5%, schedutil)** |
| **CPU A76** | 2002 MHz (no scaling) | **2300 MHz (+14.9%, schedutil)** |
| **GPU** | No acceleration | **Vulkan 1.3 + GLES 3.2 (PowerVR BXM-4-64)** |
| **NPU** | Not working | **3 TOPS, ResNet50 @ 130 FPS** |
| **WiFi** | Working | **Working (auto-connect on boot)** |
| **HDMI** | Working | **Working (1080p + audio)** |
| **Boot** | Manual | **Autonomous (20s)** |

## Hardware Specs

- **SoC:** Allwinner A733 (sun60iw2p1)
- **CPU:** 2x Cortex-A76 @ 2.0GHz + 6x Cortex-A55 @ 1.79GHz (big.LITTLE)
- **GPU:** Imagination PowerVR BXM-4-64 MC1 (Vulkan 1.3, GLES 3.2, OpenCL 3.0)
- **NPU:** Vivante VIP9000, 3 TOPS @ INT8
- **RAM:** 12GB LPDDR5 @ 1800MHz (32-bit bus)
- **Co-processor:** RISC-V E906 @ 200MHz (SCP/power management)
- **Storage:** SD card (SDR104), eMMC, UFS (optional)
- **Display:** HDMI 2.0 (4K decode, 1080p output)
- **WiFi:** AIC8800D80 (WiFi 6 + BT 5.x via USB)
- **Ethernet:** Gigabit RGMII (STMMAC)

## Benchmark Results

### CPU (Overclocked)

| Cluster | Cores | Stock | Overclocked | Voltage |
|---------|-------|-------|-------------|---------|
| Cortex-A55 | 6 | 1794 MHz | 2000 MHz | 1100 mV |
| Cortex-A76 | 2 | 2002 MHz | 2300 MHz | 1200 mV |

Stress test (30s, all 8 cores): peak 50C, idle 30C, throttle point 80C.

### GPU — PowerVR BXM-4-64 MC1

| Metric | Value |
|--------|-------|
| Vulkan | 1.3.277 |
| OpenGL ES | 3.2 |
| Max Clock | 1600 MHz (stock: 1008 MHz, +59%) |
| glmark2-es2 | 32 (GPU accelerated via glamor) |
| Driver | Imagination proprietary (pvrsrvkm) |

### NPU — Vivante VIP9000

| Metric | Value |
|--------|-------|
| Frequency | 1008 MHz |
| Performance | 3 TOPS (INT8) |
| ResNet50 | 7.67 ms / 130 FPS |
| SDK | VIPLite 2.0 (ai-sdk) |

### Memory — 12GB LPDDR5

| Test | Result |
|------|--------|
| NEON Copy | 5,057 MB/s |
| NEON Fill | 8,369 MB/s |
| sysbench Read (1T) | 13,477 MB/s |
| sysbench Write (1T) | 10,335 MB/s |
| sysbench Read (8T) | 18,237 MB/s |
| sysbench Write (8T) | 33,300 MB/s |
| ZRAM Swap | 6 GB (LZ4 compressed) |

### Storage (SD Card SDR104)

| Test | Result |
|------|--------|
| Sequential Write | ~80 MB/s |
| Sequential Read | ~95 MB/s |

### Thermal (idle / stress)

| Zone | Idle | Full Load (30s) |
|------|------|-----------------|
| A55 | 30C | 50C |
| A76 | 29C | 45C |
| GPU | 29C | - |
| DDR | 29C | - |
| Throttle | - | 80C |

## Quick Start

### Prerequisites (on your x86_64 build machine)

```bash
# Fedora/RHEL
sudo dnf install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  bc dtc cpio kmod python3 swig flex bison openssl-devel \
  ncurses-devel elfutils-libelf-devel

# Ubuntu/Debian
sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  bc device-tree-compiler cpio kmod python3 swig flex bison \
  libssl-dev libncurses-dev libelf-dev
```

### Build

```bash
# Clone this repo
git clone https://github.com/YOUR_USERNAME/radxa-a7a-kernel.git
cd radxa-a7a-kernel

# Clone source repos
git clone --branch allwinner-aiot-linux-6.6 --depth 1 https://github.com/radxa/kernel.git kernel-6.6
git clone --branch cubie-aiot-v1.4.8 --depth 1 https://github.com/radxa/allwinner-bsp.git allwinner-bsp-1.4.8
git clone --branch device-a733-v1.4.8 --depth 1 https://github.com/radxa/allwinner-device.git allwinner-device-1.4.8

# Apply patches
./scripts/apply-patches.sh

# Build
cd kernel-6.6
ln -sfn ../allwinner-bsp-1.4.8 bsp
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ cubie_a7a_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ -j$(nproc) Image dtbs modules
```

### Deploy

```bash
# Copy to board via SSH
scp arch/arm64/boot/Image radxa@BOARD_IP:/tmp/
scp arch/arm64/boot/dts/allwinner/sun60i-a733-cubie-a7a.dtb radxa@BOARD_IP:/tmp/

# On the board
sudo cp /tmp/Image /boot/vmlinuz-6.6.98+-custom
sudo mkdir -p /usr/lib/linux-image-custom/allwinner
sudo cp /tmp/sun60i-a733-cubie-a7a.dtb /usr/lib/linux-image-custom/allwinner/
```

### GPU Module (Imagination BXM-4-64)

The GPU kernel module must be built separately:

```bash
cd allwinner-bsp-1.4.8/modules/gpu/img-bxm/linux/rogue_km

# Temporarily patch Kbuild.include for Make 4.4+ compatibility
sed -i 's/^.NOTINTERMEDIATE:/#.NOTINTERMEDIATE:/' ../../kernel-6.6/scripts/Kbuild.include

make PVR_BUILD_DIR=sunxi_linux BUILD=release \
  KERNELDIR=$(pwd)/../../kernel-6.6 \
  KERNEL_CROSS_COMPILE=aarch64-linux-gnu- \
  KERNEL_CC=aarch64-linux-gnu-gcc \
  KERNEL_LD=aarch64-linux-gnu-ld \
  KERNEL_NM=aarch64-linux-gnu-nm \
  KERNEL_AR=aarch64-linux-gnu-ar \
  KERNEL_OBJCOPY=aarch64-linux-gnu-objcopy \
  CROSS_COMPILE=aarch64-linux-gnu- \
  ARCH=arm64 -j$(nproc)

# Restore Kbuild.include
sed -i 's/^#.NOTINTERMEDIATE:/.NOTINTERMEDIATE:/' ../../kernel-6.6/scripts/Kbuild.include

# Install on board
scp binary_sunxi_linux_nulldrmws_release/target_aarch64/kbuild/pvrsrvkm.ko radxa@BOARD_IP:/tmp/
ssh radxa@BOARD_IP "sudo cp /tmp/pvrsrvkm.ko /lib/modules/6.6.98+/extra/ && sudo depmod -a"
```

### WiFi (AIC8800 USB)

The BSP v1.4.8 AIC8800 USB driver has bugs. Build from the v1.4.6 BSP instead:

```bash
git clone --branch cubie-aiot-v1.4.6 --depth 1 https://github.com/radxa/allwinner-bsp.git allwinner-bsp-1.4.6

cd kernel-6.6
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ \
  M=../allwinner-bsp-1.4.6/drivers/net/wireless/aic8800/usb -j$(nproc)
```

Firmware files are in `allwinner-target/debian/cubie_a7a/overlay/lib/firmware/aic8800D80/`.

### NPU (Vivante VIP9000)

```bash
# On the board
git clone https://github.com/ZIFENG278/ai-sdk.git ~/ai-sdk

# Install libraries
sudo cp ~/ai-sdk/viplite-tina/lib/glibc-gcc13_2_0/v2.0/*.so /usr/local/lib/
sudo ldconfig

# Build vpm_run test tool
cd ~/ai-sdk/examples/vpm_run
make AI_SDK_PLATFORM=a733

# Test (use v3 models for A733)
./vpm_run -s sample_v3.txt -l 10 -d 0
```

## BSP Patches Required

The Allwinner BSP has several issues when built outside their `longan/awbs` build wrapper. These patches fix them:

| File | Issue | Fix |
|------|-------|-----|
| `bsp/include/sunxi-autogen.h` | Missing auto-generated header | Create with `AW_BSP_VERSION` define |
| `drivers/usb/host/sunxi-hci.h` | Angle-bracket relative include | Change `<>` to `""` |
| `drivers/sound/platform/Makefile` | Missing self-include path | Add `-I$(srctree)/bsp/drivers/sound/platform` |
| `drivers/gmac/Makefile` | Missing trace header include | Add `CFLAGS_sunxi-gmac.o += -I$(src)` |
| `drivers/ve/cedar-ve/Makefile` | Commented-out include | Uncomment and fix to `-I$(src)` |
| `modules/nand/Makefile` | Missing `KERNEL_SRC_DIR` | Add `$(srctree)` fallback |
| `modules/gpu/Makefile` | Missing `KERNEL_SRC_DIR` | Add `$(srctree)` fallback |
| `modules/gpu/img-bxm/.../aicusb.h` | Missing struct field | Add `u32 fw_version_uint` |

### Kernel Config Conflicts

These upstream configs must be disabled to avoid duplicate symbol/driver conflicts with the BSP:

```
CONFIG_MMC_SUNXI=n
CONFIG_MFD_AXP20X=n
CONFIG_MFD_AXP20X_I2C=n
CONFIG_MFD_AXP20X_RSB=n
CONFIG_SPI_NOR=n
CONFIG_MTD_SPI_NOR=n
CONFIG_DRM_PANFROST=n
CONFIG_VIDEO_IMX219=n
CONFIG_CPUFREQ_DT=y (but CPUFREQ_DT_PLATDEV must be blocklisted)
CONFIG_AW_CPUFREQ_DT=n
CONFIG_AW_CRASHDUMP=n
CONFIG_TYPEC_MUX_FSA4480=n
CONFIG_SND_SOC_AC101B=m (not =y, conflicts with AC101)
CONFIG_AIC_WLAN_SUPPORT=n (use out-of-tree v1.4.6 USB driver instead)
```

### cpufreq Fix

The `sun50i-cpufreq-nvmem` driver handles Allwinner's VF-binned OPP tables. To prevent `cpufreq-dt-platdev` from racing it:

```c
// drivers/cpufreq/cpufreq-dt-platdev.c — add to blocklist[]
{ .compatible = "allwinner,sun60i-a733", },
{ .compatible = "arm,sun60iw2p1", },
```

## Overclocking

The CPU OPP tables are in `sun60iw2p1-cpu-vf.dtsi`. Overclock entries are added for:

- **A55:** 1900 MHz @ 1050mV, 2000 MHz @ 1100mV
- **A76:** 2100 MHz @ 1100mV, 2200 MHz @ 1150mV, 2300 MHz @ 1200mV
- **GPU:** 1200 MHz @ 1050mV (stock max: 1008 MHz)
- **Thermal throttle:** Raised from 60C to 80C

The PMIC (AXP8191) supports up to 1540mV on the CPU rails, so there is headroom to push further.

DRAM overclocking (1800 → 2400 MHz) requires rebuilding boot0 from the Allwinner brandy-2.0 SDK — binary patching is not reliable.

## Upgrade Path: Debian 11 → 13

The OS upgrade is done in-place:

1. Hold kernel packages: `apt-mark hold linux-image-radxa-a733 u-boot-radxa-a733`
2. Switch sources from `bullseye` → `bookworm` → `trixie`
3. Disable Radxa repos (no bookworm/trixie packages available)
4. Handle conflicts: `usrmerge` firmware duplicates, `plymouth`, `zram-tools`
5. Fix `growroot` initramfs hook: `chmod -x /usr/share/initramfs-tools/hooks/growroot`

## Boot Configuration

Uses extlinux with dual-boot (custom + stock kernel):

```
# /boot/extlinux/extlinux.conf
default l1
menu title U-Boot menu
prompt 1
timeout 30

label l1
    menu label Custom Kernel 6.6.98+
    linux /boot/vmlinuz-6.6.98+-custom
    fdtdir /usr/lib/linux-image-custom/
    append root=/dev/mmcblk0p3 console=ttyAS0,115200n8 rootwait clk_ignore_unused loglevel=7 rw earlycon consoleblank=0 console=tty1 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0

label l0
    menu label Stock Kernel 5.15.147-14-a733
    linux /boot/vmlinuz-5.15.147-14-a733
    initrd /boot/initrd.img-5.15.147-14-a733
    fdtdir /usr/lib/linux-image-5.15.147-14-a733/
    append root=UUID=... console=ttyAS0,115200n8 rootwait clk_ignore_unused quiet
```

Note: Custom kernel uses `root=/dev/mmcblk0p3` (not UUID) because there is no initramfs to resolve UUIDs.

## Memory Tuning

```bash
# ZRAM compressed swap (effectively doubles usable memory)
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo 6G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

# Kernel tuning
sysctl -w vm.swappiness=100          # Optimal for zram
sysctl -w vm.vfs_cache_pressure=50   # Keep dentries cached
sysctl -w vm.dirty_ratio=20          # SD card writeback
sysctl -w vm.dirty_background_ratio=5
```

## Known Limitations

- **3.5mm audio jack:** AC101B codec chip is not physically populated on the A7A board
- **HDMI via KVM switch:** KVM switches may not pass HPD/EDID correctly. Connect directly or use `modetest -M sunxi-drm -s 146@99:1920x1080` to force output
- **DRAM overclock:** Requires boot0 rebuild from Allwinner brandy-2.0 SDK (binary patching unreliable)
- **GPU glmark2:** Score of 32 is via glamor (X11 compositor acceleration). Direct PVR DRI rendering requires Imagination's Mesa fork

## Source Repos

| Repo | Branch | Purpose |
|------|--------|---------|
| [radxa/kernel](https://github.com/radxa/kernel) | `allwinner-aiot-linux-6.6` | Linux 6.6.98 BSP kernel |
| [radxa/allwinner-bsp](https://github.com/radxa/allwinner-bsp) | `cubie-aiot-v1.4.8` | BSP drivers, GPU, NPU |
| [radxa/allwinner-bsp](https://github.com/radxa/allwinner-bsp) | `cubie-aiot-v1.4.6` | WiFi USB driver (v1.4.8 has bugs) |
| [radxa/allwinner-device](https://github.com/radxa/allwinner-device) | `device-a733-v1.4.8` | DTS, defconfig, sys_config |
| [radxa/allwinner-target](https://github.com/radxa/allwinner-target) | `target-a733-v1.4.6` | WiFi firmware, rootfs overlay |
| [radxa/u-boot](https://github.com/radxa/u-boot) | `allwinner-aiot-v2018.07` | U-Boot bootloader |
| [ZIFENG278/ai-sdk](https://github.com/ZIFENG278/ai-sdk) | `main` | NPU SDK (VIPLite 2.0) |

## License

Kernel patches: GPL-2.0 (matching Linux kernel license)
BSP drivers: Mixed (Allwinner GPL + Imagination MIT/GPL dual-license)
Documentation and scripts: MIT
