#!/bin/sh
# End-to-end smoke tests without hardware: the built graidctl against a fake controller image,
# then against its built-in controller simulator, checking what it prints and how it exits.
cd "$(dirname "$0")/.."
G=${GRAIDCTL:-build/graidctl}   # GRAIDCTL=/path/to/graidctl tests another build
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# has "<name>" "<text>" "<output>": the output contains the text.
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no \"$2\" in the output)" ;; esac; }
# refuses "<name>" "<text>" <arguments…>: graidctl exits with an error that contains the text.
refuses() {
  name=$1; text=$2; shift 2
  if out=$("$G" "$@" 2>&1 </dev/null); then fail "$name (exit 0)"; else has "$name" "$text" "$out"; fi
}

# A file answers every command with the same sector, so only the first reply's fields mean
# anything: this covers the read loop, the signature check and the capabilities parsing.
img=$(mktemp -t graid-fake).img
python3 tests/make_fake.py "$img"
out=$(GRAIDCTL_TEST=1 "$G" status "$img" 2>&1)
rm -f "$img"
echo "$out"
has "fake image: firmware" "FW Version:    160524000102" "$out"
has "fake image: unique ID" "Unique ID:     0807060504030201" "$out"
has "fake image: mode" "RAID Mode:     Protected - RAID 1" "$out"
has "fake image: array name" "RAID Set Name: G-RAID" "$out"

# The simulator answers each command properly (replies captured from a real unit).
out=$("$G" status --simulate 2>&1)
has "simulator: firmware" "FW Version:    140827300211" "$out"
has "simulator: mode and state" "RAID Status:   Online" "$out"
has "simulator: capacity" "RAID Capacity: 8 TB" "$out"
has "simulator: both disks" "Disk 2: Online  HGST HUS724040ALE640" "$out"
has "simulator: disk count" "Disks:         2 of 2 ports" "$out"
out=$("$G" status --simulate --json 2>&1)
has "simulator: JSON" '"capabilities" : "0102211b' "$out"

# Erasing commands stop without their confirmation, and without the typed word.
out=$("$G" set-mode raid1 --simulate 2>&1 </dev/null)
has "set-mode: asks for the flag" "Re-run with --yes-erase-all-data" "$out"
out=$(echo no | "$G" set-mode raid1 --simulate --yes-erase-all-data 2>&1)
has "set-mode: stops unless ERASE is typed" "Cancelled." "$out"
out=$(echo ERASE | "$G" set-mode raid1 --simulate --yes-erase-all-data --name MIRROR 2>&1)
has "set-mode: goes ahead when confirmed" "Mode change accepted" "$out"
refuses "set-mode: unknown mode" "set-mode needs one of" set-mode raid5 --simulate
refuses "set-mode: bad array name" "can't contain" set-mode raid1 --simulate --name 'a,b'
refuses "rebuild: needs a bay" "rebuild needs --from" rebuild --simulate
refuses "rebuild: not for RAID 0" "only applies to Protected" rebuild --from 1 --simulate --yes-overwrite-other-bay

# Mistakes on the command line are errors.
refuses "unknown option" "unknown option" status --simulate --jsno
refuses "option without a value" "--name needs a value" set-mode raid1 --simulate --name
refuses "bad number" "--from needs" rebuild --from two --simulate
refuses "unknown command" "unknown command" frobnicate
refuses "firmware-dump: bad size" "--size must be a multiple" firmware-dump --simulate --size 100

if [ "$fails" -eq 0 ]; then echo "PASS end-to-end"; else echo "FAIL end-to-end: $fails failed"; exit 1; fi
