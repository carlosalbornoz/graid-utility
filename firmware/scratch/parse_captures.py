#!/usr/bin/env python3 -I
"""Parse the captured real-unit replies, extracting the hex straight from Simulator.swift."""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', '..', 'graidctl', 'Sources', 'Core', 'Simulator.swift')

text = open(SRC).read()
caps_s, raid_s, disks_s = re.findall(r'captured(Caps|Raid|Disks) = hexBytes\(\s*((?:"[^"]*"\s*\+?\s*)+)', text)
caps = bytes.fromhex(re.sub(r'[^0-9a-fA-F]', '', caps_s[1]))
raid = bytes.fromhex(re.sub(r'[^0-9a-fA-F]', '', raid_s[1]))
disks = bytes.fromhex(re.sub(r'[^0-9a-fA-F]', '', disks_s[1]))


def u16(b, o):
    return (b[o] << 8) | b[o + 1]


def u64(b, o):
    v = 0
    for i in range(8):
        v = (v << 8) | b[o + i]
    return v


def ata(b, o, n):
    return bytes(x for i in range(0, n - 1, 2) for x in (b[o + i + 1], b[o + i])).decode('ascii', 'replace')


print(f"caps {len(caps)}B, raid {len(raid)}B, disks {len(disks)}B")
print("\n== Disk status (ports at 4 + i*76) ==")
for p in range(5):
    o = 4 + p * 76
    blk = disks[o:o + 76]
    print(f" Port{p}: Status {blk[0]:02x} Order {blk[1]} Model {ata(blk,4,40)!r} Serial {ata(blk,44,20)!r}")
    print(f"         DiskType {blk[64]:02x} BytesPerBlock {u16(blk,66)} TotalBlocks {u64(blk,68):#018x} = {u64(blk,68)}")

print("\n== RAID status (volumes at 4 + i*40) ==")
for v in range(4):
    o = 4 + v * 40
    blk = raid[o:o + 40]
    print(f" Vol{v}: Status {blk[0]:02x} Mode {blk[1]:02x} Stripe {blk[2]:02x} BytesPerBlock {u16(blk,6)} "
          f"TotalBlocks {u64(blk,8):#018x} = {u64(blk,8)}\n        Start {u64(blk,16):#x} End {u64(blk,24):#x} Tag {u64(blk,32):#x}")

d0 = u64(disks, 4 + 68)
d1 = u64(disks, 4 + 76 + 68)
vol = u64(raid, 12)
print(f"\n== Arithmetic ==")
print(f" disk0 {d0:#x} ({d0}), disk1 {d1:#x} ({d1}), diff {d0 - d1}")
print(f" raid0 vol  {vol:#x} ({vol})")
print(f" 2*disk0 - vol = {2 * d0 - vol:#x} = {(2 * d0 - vol) / 2048:.3f} MiB total, {(2 * d0 - vol) / 2 / 2048:.3f} MiB per disk")
print(f" disk0 - vol/2 = {d0 - vol // 2:#x} = {(d0 - vol // 2) / 2048:.3f} MiB ({(d0 - vol // 2) / 2048 / 64:.4f} x64MiB)")
print(f" vol % 0x4000 = {vol % 0x4000:#x}; vol % 0x20000 = {vol % 0x20000:#x}")
print(f" (disk0 - 0xC000) & ~0xFFFFC000 ... variants:")
for resv, mask, name in ((0, 0xFFFFC000, "8MiB"), (0, 0xFFFE0000, "64MiB")):
    per = (d0 - resv) & mask
    print(f"   resv {resv:#x} mask {name}: per {per:#x} 2x {2 * per:#x} diff {2 * per - vol:+#x}")
