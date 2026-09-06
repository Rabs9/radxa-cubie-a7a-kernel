#!/usr/bin/env python3
"""Sweep every RGMII tx_delay value and measure frame loss.

Two payload types at each point:

  random   - os.urandom(), high transition density, representative of real
             traffic (SSH, TLS, compressed HTTP, anything already encrypted
             or compressed).
  constant - one repeated byte. Low transition density. If this passes where
             random fails, the fault is data-dependent, and it also rules out
             the boring explanations: ICMP rate limiting, a duff cable, or the
             far end being busy would hit both payload types equally.

Packets are sent as a paced batch and replies collected afterwards, rather than
ping-pong per packet. A serialised test spends one timeout per lost packet,
which makes a 100%-loss cell take a minute; batching makes every cell cost the
same regardless of loss, so a 32-value sweep finishes in minutes.

A reply counts only if the payload comes back byte-identical. Corruption that
still elicits a reply is a failure, not a pass.
"""
import os, select, socket, struct, sys, time

IFACE = sys.argv[1]
TARGET = sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 50
SIZES = (64, 300, 700, 1200)
DELAY_NODE = "/sys/class/net/%s/device/tx_delay" % IFACE


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF


def batch(sock, ident, size, count, random_payload):
    """Send `count` echoes, then collect. Returns the number verified good."""
    sent = {}
    base = (int(time.time() * 1000) & 0x7FFF) << 1
    for i in range(count):
        seq = (base + i) & 0xFFFF
        payload = os.urandom(size) if random_payload else bytes([0x5A]) * size
        hdr = struct.pack("!BBHHH", 8, 0, 0, ident, seq)
        pkt = struct.pack("!BBHHH", 8, 0, checksum(hdr + payload), ident, seq) + payload
        sent[seq] = payload
        try:
            sock.sendto(pkt, (TARGET, 0))
        except OSError:
            pass
        time.sleep(0.004)

    good = 0
    deadline = time.time() + 0.5
    while time.time() < deadline and good < count:
        r, _, _ = select.select([sock], [], [], max(0, deadline - time.time()))
        if not r:
            break
        try:
            data, _ = sock.recvfrom(2048)
        except OSError:
            break
        ihl = (data[0] & 0x0F) * 4
        icmp = data[ihl:]
        if len(icmp) < 8 or icmp[0] != 0:
            continue
        rid, rseq = struct.unpack("!HH", icmp[4:8])
        if rid != ident:
            continue
        want = sent.pop(rseq, None)
        if want is not None and icmp[8:8 + len(want)] == want:
            good += 1
    return good


sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
sock.setsockopt(socket.SOL_SOCKET, 25, IFACE.encode())   # SO_BINDTODEVICE
sock.setblocking(False)
ident = os.getpid() & 0xFFFF

hdr = ["delay"]
for s in SIZES:
    hdr.append("r%d" % s)
for s in SIZES:
    hdr.append("c%d" % s)
print("\t".join(hdr))

for d in range(0, 32):
    try:
        open(DELAY_NODE, "w").write(str(d))
    except OSError:
        print("%d\tSETFAIL" % d)
        continue
    time.sleep(0.8)
    # drain anything still arriving from the previous setting
    while True:
        r, _, _ = select.select([sock], [], [], 0)
        if not r:
            break
        try:
            sock.recvfrom(2048)
        except OSError:
            break

    row = [str(d)]
    for rnd in (True, False):
        for size in SIZES:
            good = batch(sock, ident, size, N, rnd)
            row.append("%.0f" % (100.0 * (N - good) / N))
    print("\t".join(row))
    sys.stdout.flush()

open(DELAY_NODE, "w").write("9")
