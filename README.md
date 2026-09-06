# Radxa Cubie A7A — Debian 13 images, packaged kernel, and hardware tuning

Debian 13 (Trixie) on the Radxa Cubie A7A (Allwinner A733), with a custom Linux
6.6.98 kernel, validated CPU/RAM/GPU overclocking, and the hardware fixes that
took this board from "boots if you're lucky" to a daily-usable desktop.

Everything here is built and verified on real hardware. Where a number appears,
it was measured — the date it was measured is stated.

> **A year ago this board shipped with Debian 11 and a device tree that did not
> match its own hardware.** Getting from there to here took a lot of tireless
> nights, a great deal of trial and error, and a few occasions where a corrupted
> image cost months of work. If you want the story rather than the specs —
> including what the RAM, the GPU and the boot chain actually turned out to be —
> it is in **[docs/THE-JOURNEY.md](docs/THE-JOURNEY.md)**.

---

## Download

**[Latest images →](https://github.com/Rabs9/radxa-cubie-a7a-kernel/releases/latest)**

| image | who it's for | download |
|---|---|---|
| **`a7a-standard`** | Start here. A76 3.0 GHz, A55 2.8 GHz, RAM 2040 MHz | [`.img.xz` · 1.9 GB](https://github.com/Rabs9/radxa-cubie-a7a-kernel/releases/download/images-20260825/a7a-standard-20260825.img.xz) |
| **`a7a-maximum`** | More speed, less margin. Adds RAM 2136 MHz and DSU/L3 1352 MHz | [`.img.xz` · 1.9 GB](https://github.com/Rabs9/radxa-cubie-a7a-kernel/releases/download/images-20260825/a7a-maximum-20260825.img.xz) |

Checksums and signatures are in the same release — `SHA256SUMS`, `SHA256SUMS.asc`
and `Rabs9-public-key.asc`.

Already running Debian 13 and only want the kernel? The `.deb`s are in
[packages only](https://github.com/Rabs9/radxa-cubie-a7a-kernel/releases/tag/debs-20260825), and the newest headers package is in
[6.6.98-6](https://github.com/Rabs9/radxa-cubie-a7a-kernel/releases/tag/debs-20260906).

> **These images are overclocked out of the box and need a heatsink and fan.**
> See [Before you flash](#before-you-flash-you-need-active-cooling) directly below.

---

## Before you flash: you need active cooling

These images run the board **overclocked out of the box**. A 60-second all-core
load reaches **76 °C and is still climbing**, against an 80 °C throttle point —
and that was measured with a heatsink and PWM fan already fitted and running.

Without cooling you will hit thermal throttling quickly, and sustained load on a
bare board risks damaging it. **Fit a heatsink and fan before you flash this.**

If you want the tuning with more margin, the `standard` image is the more
conservative of the two, and every clock can be lowered at runtime with
`a7a-clock`.

---

## Disclaimer

This software is provided **as is, with no warranty of any kind**, express or
implied. You use it entirely at your own risk.

Specifically:

- These images **overclock your hardware** — CPU, GPU, memory and interconnect
  all run above the manufacturer's specified frequencies and voltages.
- Overclocking can cause instability, data loss, shortened component life, or
  permanent damage to your board.
- Doing this will almost certainly **void any warranty** from Radxa or your seller.
- Everything here is validated on **one board**. Yours may not behave the same way.
- This project is **not affiliated with Radxa or Allwinner**. It is independent work.

**I accept no responsibility for any damage, data loss, or other harm resulting
from the use of these images, packages, or instructions.** If you are not
comfortable with that, use Radxa's official images instead — they are supported
by the vendor, and I would rather you had a working board than a bricked one.

---

## Get started

Two images. Both are a **single file**, flash with Etcher, Raspberry Pi Imager
or `dd`, and both grow to fill your card on first boot.

| | | |
|---|---|---|
| **`a7a-standard`** | Start here | A76 3.0 GHz · A55 2.8 GHz · RAM 2040 MHz |
| **`a7a-maximum`** | More speed, less margin | adds RAM 2136 MHz, DSU/L3 1352 MHz, and the `a7a-clock` control panel |

Both run the same kernel and the same fixes. `maximum` pushes memory and the
DSU interconnect harder; if you see instability, use `standard`.

```bash
xz -d a7a-standard-<date>.img.xz
sudo dd if=a7a-standard-<date>.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Default login is `radxa` / `radxa`. **You will be asked to change the password
on first login** — that is deliberate, so no two boards ship with the same
credentials.

**First boot takes longer than later ones.** Three one-shot services run: the
root filesystem expands to fill the card, SSH host keys are generated for
*your* board, and a fresh machine-id is created. Give it a few minutes.

Prefer to keep your existing install? The same system is available as packages
— see [docs/PACKAGES.md](docs/PACKAGES.md).

---

## What you get

| | Radxa official | This project |
|---|---|---|
| Kernel | 6.6.98+ | **6.6.98+**, custom-built |
| OS | Debian 13 | **Debian 13 Trixie** |
| Cortex-A76 | 2002 MHz | **3000 MHz** (+50%) |
| Cortex-A55 | 1794 MHz | **2800 MHz** (+56%) |
| DSU / L3 | not exposed | **1352 MHz**, tunable |
| RAM | 1800 MHz | **2040 MHz** (standard) / **2136 MHz** (maximum) |
| GPU | GLES 3.2 | **GLES 3.2 validated — glmark2-es2 889, colour-correct** |
| NPU | 3 TOPS | **3 TOPS, ResNet50 ~7.8 ms (~128 FPS), verified** |
| Gigabit ethernet | **broken** (see below) | **fixed** — RGMII tx-delay corrected |
| Local LLM | — | **`a7a-llm`** — llama.cpp, 28 tok/s prompt, 4.7 tok/s generation |
| Clock control | — | **`a7a-clock`** — GUI + CLI for every tunable rail |

---

## Gigabit ethernet — the fix that matters most

Every image built before 2026-08-22, **including Radxa's own**, sets the RGMII
transmit delay to the vendor value of `12`. Real traffic only survives at `9`,
`10` or `11`, so transmitted frames get corrupted — and the loss climbs with
frame size, reaching 42% at 1200 bytes.

It does not look like a network fault. The link reports 1000/full with zero
`tx_errors`, short pings reply normally, and receive is perfect — but SSH hangs
straight after key exchange and `apt` stalls. It reads like a bad cable, and it
is not: it reproduces across cables.

The corruption is **data-dependent**, which is why it went unnoticed for so
long. At the vendor's setting, a payload of one repeated byte passes with
**zero loss at every frame size** while random data loses up to 42%. Test with
random data or you will "prove" a broken board healthy.

Fixed in these images. On any other image:

```sh
echo 9 | sudo tee /sys/class/net/end0/device/tx_delay     # now, no reboot
```

Permanently: install `linux-dtb-6.6.98-a7a` from the packages release.

**[Every one of the 32 delay values, measured →](docs/ETHERNET-TX-DELAY.md)** —
the full sweep, both payload types, with and without the vendor PHY driver, and
the raw data. A reproducer is also in [`packaging/README.md`](packaging/README.md).

---

## Updating safely

The kernel and boot configuration live **outside apt**. These images carry pins
in `/etc/apt/preferences.d/99-a7a-custom-kernel` that block the three package
classes which would break the board — stock `linux-image-*`, `u-boot-menu`, and
`flash-kernel`. Normal updates are safe; a full `apt upgrade` is tested as part
of building every image.

On older images, or to verify the boot chain every time, use
[`scripts/safe-update.sh`](scripts/safe-update.sh) — it restores the pins,
backs up the kernel and `extlinux.conf`, upgrades, then checks nothing moved.

---

## Card won't boot?

If you flashed an image from before 2026-08-10, the system on your card is
probably fine — the boot chain had two defects (wrong U-Boot variant, empty EFI
partition). **[boot-fix/](boot-fix/) repairs it in place in about five minutes**,
no re-download needed.

---

## Documentation

| | |
|---|---|
| [docs/THE-JOURNEY.md](docs/THE-JOURNEY.md) | How this project came about, and what each problem turned out to be |
| [docs/PACKAGES.md](docs/PACKAGES.md) | Installing on an existing system, and what each package does |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | Every measured number, with dates and method |
| [docs/HARDWARE.md](docs/HARDWARE.md) | Specs, overclocking, boot config, tuning, known limits |
| [docs/BUILDING.md](docs/BUILDING.md) | Building the kernel, GPU module, wifi and NPU from source |
| [docs/MODELS.md](docs/MODELS.md) | Choosing a model for `a7a-llm` |
| [packaging/README.md](packaging/README.md) | How the `.deb`s are built, and the ethernet reproducer |

---

## Known limitations

- **3.5 mm audio jack** — the AC101B codec is not physically populated on this board.
- **Hardware GL only outside X.** The desktop runs `AccelMethod "none"` (software
  2D) because glamor on the PowerVR DDK produces cursor trails. Hardware GLES is
  reachable through KMS/GBM — that is how `a7a-game` runs SuperTuxKart.
- **Boot logo colours are swapped.** The R/B fix corrects the GPU desktop, which
  is what you look at all day; the CPU-drawn fbcon logo inherits the inverse.
- **RAM above 2136 MHz refuses training** on this 12 GB silicon (2400 tested,
  three configurations).
- **HDMI through a KVM** may not pass HPD/EDID. Connect directly, or force the
  mode with `modetest -M sunxi-drm -s 146@99:1920x1080`.
- **No UFS on SD-boot boards.** The controller probes and `ufshcd_async_scan`
  fails — the chip is not populated on this variant.

---


## Verifying releases

Release assets are signed with GPG. The signature proves two things: the file is
byte-identical to what was published, and it was signed by the holder of this
key.

**Fingerprint** — check this against the key you import, not just the signature:

```
C9E8 FC3E 6B94 6616 B0BB  B09B EF82 43C0 E3AD C6EA
```

Import the key and verify:

```bash
gpg --import Rabs9-public-key.asc          # from this repository
gpg --fingerprint EF8243C0E3ADC6EA

# then, having downloaded a release asset and its .asc:
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS

# or verify an image directly
gpg --verify a7a-standard-20260825.img.xz.asc a7a-standard-20260825.img.xz
```

A good signature prints `Good signature from "Rabs9 <...>"`. You will also see a
warning that the key is not certified with a trusted signature — that is normal
and expected. It means nobody else has vouched for the key, not that anything is
wrong. **What matters is that the fingerprint matches the one above.**

That check is the whole point: an attacker who replaced both a file and its
signature would also have to make the fingerprint match, and they cannot.

The key never expires. If it is ever compromised, a revocation certificate will
be published here and at the same fingerprint.

---

## License

Original work here — kernel patches, device trees, scripts, packaging, docs —
is **GPL-2.0**, see [LICENSE](LICENSE). Copyright © 2026 Rabs9.

Provenance, the identity chain across earlier commits, and the archive
reference are in [AUTHORS.md](AUTHORS.md).

- Kernel patches: GPL-2.0 (required, derived from Linux).
- BSP drivers: as shipped by Allwinner (GPL) and Imagination (proprietary DDK blob).
- Released images bundle Debian packages under their own upstream licenses.

Use, modify and redistribute under GPL-2.0 — **please keep attribution to this
repository as the original source.** This is the upstream; improvements are
welcome as pull requests.
