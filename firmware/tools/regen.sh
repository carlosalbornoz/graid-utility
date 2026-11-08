#!/bin/sh
# Rebuild fw.asm from the image: collect every switch-table target, then disassemble.
set -e
cd "$(dirname "$0")/.."
IMG=G-RAID-firmware-140827300211-4a83278da74eca68.bin
echo "5cbe3058ccc544db281cf8a19446bcebaabc4050ac0dd29a42ce3c3d6aaf1f00  $IMG" | shasum -a 256 -c -
python3 -I tools/cases.py "$IMG" > switches.txt 2>/dev/null
ENTRIES=$(grep -o 'L_[0-9A-F]\{4\}' switches.txt | sed 's/L_//' | sort -u | paste -sd, -)
python3 -I tools/dis8051.py "$IMG" --entry "$ENTRIES" > fw.asm
echo "fw.asm and switches.txt regenerated"
