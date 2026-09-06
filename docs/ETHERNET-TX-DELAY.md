# Gigabit ethernet on the Radxa Cubie A7A: the RGMII TX delay

The vendor device tree sets the MAC-side RGMII TX delay to **12**. On this board
that value is outside the range where the link carries real traffic, and the way
it fails is unusually good at hiding.

This page is the measurement, not the anecdote. Every number below comes from a
sweep of all 32 possible delay values, run twice on the same cable and switch.

---

## What it looks like when it goes wrong

Nothing that points at the network:

- The link negotiates **1000 Mb/s full duplex**.
- `ethtool -S` shows **no TX errors, no dropped frames**.
- `ping` to the gateway replies normally.
- But **SSH hangs immediately after key exchange**, and `apt` stalls part-way
  through a download and never recovers.

Every symptom points at a cable. Replacing the cable changes nothing.

## The measurement

`tx_delay` is exposed at runtime, so all 32 values can be tested without
rebuilding anything:

```sh
echo 9 | sudo tee /sys/class/net/end0/device/tx_delay
```

At each value, 50 ICMP echoes were sent per frame size, and a reply counted only
if the payload returned **byte-identical**. Two payload types were used at every
point:

| payload | what it is | why |
|---|---|---|
| **random** | `os.urandom()` | high transition density — representative of SSH, TLS, compressed HTTP, or anything already encrypted |
| **constant** | one repeated byte | low transition density — and a control: ICMP rate limiting, a bad cable or a busy peer would hit both payload types equally |

Frame payloads: 64, 300, 700 and 1200 bytes. Target: the default gateway, one
hop away, with its ARP entry pinned so a broken data path could not be measured
as an ARP failure.

## Result

Loss percentage, generic PHY driver — the configuration every shipped image uses:

| tx_delay | random 64 | random 300 | random 700 | random 1200 | constant 64 | constant 300 | constant 700 | constant 1200 |
|---|---|---|---|---|---|---|---|---|
| 0–5 | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| 6 | 100 | 100 | 100 | 100 | 76 | 50 | 64 | 54 |
| 7 | 60 | 100 | 100 | 100 | 6 | 2 | 0 | 0 |
| 8 | 2 | 10 | 20 | **32** | 0 | 0 | 0 | 0 |
| **9** | **0** | **0** | **0** | **0** | 0 | 0 | 0 | 0 |
| 10 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 0 |
| 11 | 0 | 0 | 4 | 6 | 0 | 0 | 0 | 0 |
| **12** *(vendor)* | 4 | 8 | 24 | **42** | **0** | **0** | **0** | **0** |
| 13 | 22 | 86 | 86 | 100 | 0 | 0 | 0 | 0 |
| 14 | 96 | 100 | 100 | 100 | 2 | 4 | 0 | 14 |
| 15 | 94 | 100 | 100 | 100 | 42 | 30 | 50 | 24 |
| 16 | 100 | 100 | 100 | 100 | 64 | 90 | 100 | 100 |
| 17–31 | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |

### Three things fall out of this

**1. The usable range for real traffic is 9–11, and only 9 is completely clean.**
It's a cliff, not a slope. One step below the window (8) already loses 32% of
1200-byte frames; one step above the vendor's value (13) loses everything.

**2. Loss scales with frame size.** At delay 12, 64-byte frames lose 4% while
1200-byte frames lose 42%. This is why `ping` succeeds and `apt` does not:
small packets mostly get through, so every quick test passes.

**3. A constant-byte payload passes over a window nearly twice as wide.** At the
vendor's setting of 12, constant-byte traffic shows **zero loss at every frame
size**, while random traffic at the same setting loses up to 42%.

Point 3 is the one that matters. The obvious way to test a link — push a big
predictable buffer through it and see whether it arrives — **passes perfectly at
the broken setting.** Anyone validating this board with a simple generated
payload would conclude the network was fine.

## Is the missing PHY driver the real cause?

It is a fair question. This board's PHY is a Maxio part, and the kernel has a
driver for it that the BSP does not enable.

```
phy_id  0x7b744412   →  drivers/net/phy/maxio.c:  "MAE0621A/B-Q3C(I) Gigabit Ethernet"
config  # CONFIG_MAXIO_PHY is not set
bound   Generic PHY
```

`maxio_mae0621aq3ci_config_init()` writes 27 vendor tuning registers that
therefore never run, two of them squarely in the signal-integrity path
(`TXCST OFF`, `IO DS=1` — pad drive strength). If those were the missing piece,
enabling the driver should make the vendor's 12 work.

It does the opposite. Building `CONFIG_MAXIO_PHY` as a module, loading it, and
repeating the identical sweep:

| | usable for random traffic | at vendor delay 12 (random, 64/300/700/1200) |
|---|---|---|
| generic PHY | 9, 10, 11 | 4 / 8 / 24 / 42 |
| **vendor Maxio driver** | 8, 9 | **0 / 90 / 100 / 100** |

The vendor driver **narrows** the usable window and makes 12 substantially
worse. Whatever its register set does to the timing, it moves the eye further
from where 12 sits, not closer. The delay value is the fault; the missing PHY
driver is a separate matter.

Under the vendor driver the constant-byte payload still passes cleanly from 7 to
13 — so the trap in point 3 is a property of the board, not of which driver is
loaded.

## The fix

```dts
/* RGMII tx-delay: the vendor value of 12 is outside this board's working
 * window; 9 is the only value with zero loss on random payloads. */
tx-delay = <9>;
```

At runtime, without rebooting:

```sh
echo 9 | sudo tee /sys/class/net/end0/device/tx_delay
```

9 is chosen rather than 10 or 11 because it is the only value measuring zero
loss at every frame size, and it sits in the middle of the usable range, so a
board with slightly different trace characteristics has margin either side.

## If you test this yourself

**Use random payloads.** A test that repeats one byte, or sends a simple counter,
will tell you the link is perfect at a setting that cannot carry an SSH session.
That's not hypothetical, it is the measured behaviour in the table above.

## One board, one cable

That is the honest scope of this. One board, one cable, one switch, 50 packets
per cell, a single run. Run it again and individual cells move by a few percent.
What does not move is the shape: where the window sits, the cliff on both sides,
loss climbing with frame size, and the gap between random and constant payloads.

The raw sweep output for both passes is in
[`data/tx-delay-sweep/`](data/tx-delay-sweep/), and the script that produced it
is beside them. If you have one of these boards, I would like to know whether
yours lands in the same place.

Measured 2026-09-06 on Linux 6.6.98, Allwinner A733 (`sun60iw2p1`), PHY
`0x7b744412` (Maxio MAE0621A/B-Q3C(I)), link 1000 Mb/s full duplex.
