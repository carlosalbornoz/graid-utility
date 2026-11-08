#!/bin/sh
# End-to-end smoke test without hardware: runs graidctl against a fake controller image.
set -e
cd "$(dirname "$0")/.."
img=$(mktemp -t graid-fake).img
python3 tests/make_fake.py "$img"
out=$(GRAIDCTL_TEST=1 build/graidctl status "$img")
echo "$out"
rm -f "$img"
echo "$out" | grep -q "FW Version:    160524000102" &&
echo "$out" | grep -q "Unique ID:     0807060504030201" &&
echo "$out" | grep -q "RAID Mode:     Protected - RAID 1" &&
echo "$out" | grep -q "RAID Set Name: G-RAID" && echo "PASS fake device end-to-end" || { echo "FAIL fake device"; exit 1; }
