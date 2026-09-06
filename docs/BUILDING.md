# Building from source

You do not need any of this to use the board — flash an image, or install the
packages. This is for people who want to rebuild the kernel themselves.

---

## Prerequisites

On an x86_64 build machine:

```bash
# Fedora / RHEL
sudo dnf install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  bc dtc cpio kmod python3 swig flex bison openssl-devel \
  ncurses-devel elfutils-libelf-devel

# Ubuntu / Debian
sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  bc device-tree-compiler cpio kmod python3 swig flex bison \
  libssl-dev libncurses-dev libelf-dev
```

---

## Kernel

```bash
git clone https://github.com/Rabs9/radxa-cubie-a7a-kernel.git
cd radxa-cubie-a7a-kernel

git clone --branch allwinner-aiot-linux-6.6 --depth 1 https://github.com/radxa/kernel.git kernel-6.6
git clone --branch cubie-aiot-v1.4.8 --depth 1 https://github.com/radxa/allwinner-bsp.git allwinner-bsp-1.4.8
git clone --branch device-a733-v1.4.8 --depth 1 https://github.com/radxa/allwinner-device.git allwinner-device-1.4.8

# needed for the wifi firmware later - the build works without it, but the
# firmware step further down expects this tree to be present
git clone --branch target-a733-v1.4.6 --depth 1 https://github.com/radxa/allwinner-target.git allwinner-target

./scripts/apply-patches.sh

cd kernel-6.6
ln -sfn ../allwinner-bsp-1.4.8 bsp
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ cubie_a7a_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ -j$(nproc) Image dtbs modules
```

**`BSP_TOP=bsp/` is not optional.** Without it `syncconfig` dies with
`can't open platform/Kconfig`, and the error does not mention the missing
variable.

To keep your build machine's identity out of the kernel banner (it is embedded
in `linux_banner` and appears in every `uname -a` and every pasted dmesg):

```bash
export KBUILD_BUILD_USER=yourname
export KBUILD_BUILD_HOST=whatever
```

---

## Deploying a hand-built kernel

```bash
scp arch/arm64/boot/Image radxa@BOARD:/tmp/
scp arch/arm64/boot/dts/allwinner/sun60i-a733-cubie-a7a.dtb radxa@BOARD:/tmp/

# on the board
sudo cp /tmp/Image /boot/vmlinuz-6.6.98+-custom
sudo mkdir -p /usr/lib/linux-image-custom/allwinner
sudo cp /tmp/sun60i-a733-cubie-a7a.dtb /usr/lib/linux-image-custom/allwinner/
```

Then point an `extlinux.conf` entry at it — see [HARDWARE.md](HARDWARE.md), and
remember the file is immutable on shipped images.

---

## GPU module (PowerVR BXM-4-64)

Built separately from the kernel:

```bash
cd allwinner-bsp-1.4.8/modules/gpu/img-bxm/linux/rogue_km

# Make 4.4+ compatibility, reverted immediately after
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

sed -i 's/^#.NOTINTERMEDIATE:/.NOTINTERMEDIATE:/' ../../kernel-6.6/scripts/Kbuild.include

scp binary_sunxi_linux_nulldrmws_release/target_aarch64/kbuild/pvrsrvkm.ko radxa@BOARD:/tmp/
ssh radxa@BOARD "sudo cp /tmp/pvrsrvkm.ko /lib/modules/6.6.98+/extra/ && sudo depmod -a"
```

The userspace half is Imagination's proprietary DDK blob, shipped by Allwinner.
It lives in `/usr/local/lib` with an `ld.so.conf` entry. The loader resolves it
by SONAME, not filename — if you replace it by hand, create the version symlinks
or nothing will load.

---

## Wifi (AIC8800 USB)

The v1.4.8 BSP driver has bugs. Build from v1.4.6:

```bash
git clone --branch cubie-aiot-v1.4.6 --depth 1 https://github.com/radxa/allwinner-bsp.git allwinner-bsp-1.4.6

cd kernel-6.6
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- BSP_TOP=bsp/ \
  M=../allwinner-bsp-1.4.6/drivers/net/wireless/aic8800/usb -j$(nproc)
```

That produces two modules — `aic_load_fw.ko` and `aic8800_fdrv.ko`. Both are
needed: `aic_load_fw` pushes the firmware blob to the chip, `aic8800_fdrv` is the
driver proper.

**The firmware blobs are a separate download.** They live in the
`allwinner-target` tree cloned above, not in the BSP:

```bash
sudo mkdir -p /lib/firmware/aic8800D80
sudo cp allwinner-target/debian/cubie_a7a/overlay/lib/firmware/aic8800D80/* \
        /lib/firmware/aic8800D80/
sudo depmod -a
```

The modules load on demand once the firmware is in place — `aic_load_fw` first,
then `aic8800_fdrv`. If you get a device that enumerates but never associates,
missing firmware is the usual cause.

### Regulatory database

The kernel embeds `regulatory.db` via `CONFIG_EXTRA_FIRMWARE` so 5 GHz works
without depending on a userspace `wireless-regdb` package being installed and
ordered correctly at boot.

**Where to get the file.** It comes from Debian's `wireless-regdb` package, which
ships several variants:

```bash
apt download wireless-regdb
dpkg -x wireless-regdb_*.deb wireless-regdb/

# use the -debian variants; the -upstream ones are unsigned by Debian's key
sudo cp wireless-regdb/lib/firmware/regulatory.db-debian     /lib/firmware/regulatory.db
sudo cp wireless-regdb/lib/firmware/regulatory.db.p7s-debian /lib/firmware/regulatory.db.p7s
```

`CONFIG_EXTRA_FIRMWARE` then bakes them into the image at build time, so put them
in place **before** building. To check a built kernel actually contains it, look
for the `RGDB` magic bytes:

```bash
grep -qaP '\x52\x47\x44\x42' vmlinuz && echo present
```

Do **not** grep for the string `regulatory.db` — that is just the filename
cfg80211 requests, and it appears in kernels that do not embed the database at
all. It will tell you a broken kernel is fine.

---

## NPU (Vivante VIP9000)

```bash
# on the board
git clone https://github.com/ZIFENG278/ai-sdk.git ~/ai-sdk
sudo cp ~/ai-sdk/viplite-tina/lib/glibc-gcc13_2_0/v2.0/*.so /usr/local/lib/
sudo ldconfig

cd ~/ai-sdk/examples/vpm_run
make AI_SDK_PLATFORM=a733
./vpm_run -s sample_v3.txt -l 10 -d 0     # v3 models for the A733
```

---

## BSP patches

The Allwinner BSP does not build outside their `longan/awbs` wrapper. These are
applied by `scripts/apply-patches.sh`:

| file | problem | fix |
|---|---|---|
| `bsp/include/sunxi-autogen.h` | missing generated header | create with `AW_BSP_VERSION` |
| `drivers/usb/host/sunxi-hci.h` | angle-bracket relative include | `<>` → `""` |
| `drivers/sound/platform/Makefile` | missing self-include path | add `-I$(srctree)/bsp/drivers/sound/platform` |
| `drivers/gmac/Makefile` | missing trace header include | `CFLAGS_sunxi-gmac.o += -I$(src)` |
| `drivers/ve/cedar-ve/Makefile` | commented-out include | uncomment, fix to `-I$(src)` |
| `modules/nand/Makefile` | missing `KERNEL_SRC_DIR` | add `$(srctree)` fallback |
| `modules/gpu/Makefile` | missing `KERNEL_SRC_DIR` | add `$(srctree)` fallback |
| `modules/gpu/img-bxm/.../aicusb.h` | missing struct field | add `u32 fw_version_uint` |

### Config conflicts

These must be disabled or they collide with BSP drivers:

```
CONFIG_MMC_SUNXI=n
CONFIG_MFD_AXP20X=n
CONFIG_MFD_AXP20X_I2C=n
CONFIG_MFD_AXP20X_RSB=n
CONFIG_SPI_NOR=n
CONFIG_MTD_SPI_NOR=n
CONFIG_DRM_PANFROST=n
CONFIG_VIDEO_IMX219=n
CONFIG_AW_CPUFREQ_DT=n
CONFIG_AW_CRASHDUMP=n
CONFIG_TYPEC_MUX_FSA4480=n
CONFIG_SND_SOC_AC101B=m          # =y conflicts with AC101
CONFIG_AIC_WLAN_SUPPORT=n        # use the out-of-tree v1.4.6 USB driver
CONFIG_CPUFREQ_DT=y              # but blocklist CPUFREQ_DT_PLATDEV, below
```

### cpufreq

`sun50i-cpufreq-nvmem` handles Allwinner's VF-binned OPP tables. Stop
`cpufreq-dt-platdev` racing it:

```c
// drivers/cpufreq/cpufreq-dt-platdev.c — add to blocklist[]
{ .compatible = "allwinner,sun60i-a733", },
{ .compatible = "arm,sun60iw2p1", },
```

---

## A note on `scripts/build.sh`

That script predates this documentation and **targets the 5.15 BSP kernel**, not
6.6.98. It is kept for reference only — following the steps above is the current
route. If you ran it expecting a 6.6.98 build, that is why the result looked
wrong.

---

## Packaging

See [`packaging/README.md`](../packaging/README.md) for how the `.deb`s are
built, why they package validated binaries instead of rebuilding, and the
gigabit ethernet reproducer.
