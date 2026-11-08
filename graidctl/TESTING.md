# Hardware test plan

Unit: G-RAID with Thunderbolt, firmware 140827300211, 2 × HGST HUS724040ALE640 (4 TB,
7,814,037,168 sectors each). Started 2026-11-08.

**Backup:** checked 2026-11-08 against the NAS: all 3,295 files present
with matching sizes, 717.3 GB. Not copied: `.VolumeIcon.icns`, `G-RAID_TB+USB_removable.ico` and
`autorun.inf` (the drive's custom icon).

**Rules:** you click every destructive button in the app yourself; Claude only watches and reads.
No spare drive, so "replacing" a drive means pulling Bay 2 and putting the same drive back.

Fill in **Result** as each check runs.

## 1. Before erasing (the data is still there)

| Check | Expect | Result |
|---|---|---|
| Capacity formula, RAID 0 | 15,627,911,168 sectors | **Pass**: diskutil reports exactly that |
| Health report (Report in the overview) | Saves as PDF and as .txt; device, array, partitions, disks, events, raw replies | **Pass**: both saved; 2-page A4 PDF renders cleanly. (No SMART section: by design, SMART only reaches bay 1) |
| Speed Test sheet (redone 2026-11-08) | Separate write and read results, saved to Activity | **Pass**: 285 MB/s write, 306 MB/s read (was 224 / 310 on 2026-11-07); saved per unit |
| EFI partition mount (Device → Partitions) | Asks for an admin password, mounts, unmounts | **Mounted** at /Volumes/EFI (empty FAT32), but read-write: macOS wrote `.fseventsd` and `.Spotlight-V100` onto it. **Fixed**: system partitions now mount read-only by default, with a Settings toggle. Unmount with password: **Pass**. Mounted again on the new build: **Pass**, read-only flag set, writes refused, nothing new written. (A `.Spotlight-V100` folder left from the 2026-11-07 mount remains; harmless) |

## 2. Mode change, RAID 0 → RAID 1 (erases everything)

The first ModeChange ever sent to this hardware.

| Check | Expect | Result |
|---|---|---|
| Confirmation step | Shows ~718 GB to be erased, 4.00 TB new size, both disks; needs ERASE typed | **Pass** (run 2026-11-08 13:28; you confirmed the summary) |
| Command sent | Volume ejected, the controller rebuilds the array, the unit drops off | **Pass**: sent 13:28:47, disk gone 13:28:51 |
| Reconnect | Back within ~30–40 s without a power cycle; the app says so | **Pass, faster**: back at 13:28:58, **7 s** after dropping off (the 30–40 s seen before is for a cable replug) |
| New size | **7,813,922,816 sectors** (4,000,728,481,792 bytes), per the firmware formula | **Pass, exact**: diskutil and the controller (0x1D1BF0000) both report it |
| Status | RAID 1, Online, both disks in sync (no initial copy expected; to be confirmed) | **Pass**: Online, both disks Online, no copy. So RAID 1 creation doesn't copy disk 1 onto disk 2: sectors never written since can differ between the disks |
| Array name | Kept as typed in the sheet | **Pass**: G-RAID |
| Activity / notification | Mode change event recorded | **Pass**: "RAID mode change sent", Disconnected, Connected as RAID 1. Unique ID unchanged (4a83278da74eca68); the array ID in the replies is new |
| Starting-up screen | Seen while the unit reconnects | **Pass**: seen (your screenshot), with the "RAID mode changed" banner and Open Disk Utility. Banner layout to be redone (mockups in build/mock/banner-*.png) |

Then create a volume in Disk Utility (exFAT or APFS) and copy about 20 GB of test files from the
NAS. Their checksums get compared after each step below.

**Done 2026-11-08:** exFAT volume "G-RAID" created in Disk Utility. 42 files (20.1 GB) copied from
the NAS to `raid-test/` in 248 s while hashing the source (SHA-256). Re-read from the G-RAID with
the cache bypassed: **42 match, 0 mismatch** (147 s, about 137 MB/s). Hashes in `/tmp/rt/source.sha`;
re-check with `/tmp/rt/verify.sh`.

## 3. Degraded: pull a drive while running (Bay 1 was pulled)

| Check | Expect | Result |
|---|---|---|
| Status | Degraded within a few seconds, Bay 2 empty | **Pass**: the **bottom** drive was pulled, which is **Bay 1** (port 0, PK1334PEHT4U9S); the top slot is Bay 2. Events "Array degraded (Online → Degraded)" and "Disk 1 missing" at 13:56:01, within seconds |
| Notification | "Degraded" notification delivered (never seen on hardware yet) | **Pass**: delivered (you confirmed) — first notification seen on hardware |
| Empty-bay warning | Bay 2 note: any drive put here is erased for the copy | **Pass**: shown on the Bay 1 card (you confirmed) |
| Replace a Drive guide | Opens at "Insert a drive", minimum size shown | **Pass**: button appeared, guide opened at "Insert a drive" for Bay 1 (you confirmed) |
| Volume | Still mounted and readable; checksums match | **Pass**: still mounted; 42 match, 0 mismatch, read from Bay 2 alone (133 s) |

## 4. Rebuild: put the same drive back in Bay 1 (bottom slot)

The controller starts copying by itself (FIRMWARE.md "Rebuild"). Estimated about 8 hours for 4 TB.

| Check | Expect | Result |
|---|---|---|
| Copy starts by itself | Status Rebuilding within a minute, Bay 2 receiving | **No: it was re-admitted without a copy.** Reinserted ~14:00:40. 14:00:46 "Disk 1 rejected" (Missing → Rejected, status 6), then 14:01:01 "Disk 1 online" and "Array online" (Degraded → Online). No Rebuilding state at all. The firmware's auto-copy path (0x636A) only runs for status 1 or 5, and a returning member reports 6, so this matches the code once the status is known. Nothing visible was written to the volume while degraded (no file or `.fseventsd` change 13:55–14:01; Spotlight's folder unreadable), so the mirror is most likely still identical |
| Guide | Moves to the copy step, "seen since" time, about 8 hours estimate | |
| Rebuild position (research) | GetRegister reads of RAM 0x04AC–0x04BB grow as the copy runs | |
| Volume during copy | Usable; checksums match | |
| Finish | Back to Online, completion notification, guide says complete | |
| Time taken | Note it, to correct the estimate | |
| After | Checksums match | |

## 5. Optional, then finish

| Check | Expect | Result |
|---|---|---|
| Individual mode | Two volumes, one per disk; sizes per the formula | |
| Final mode | Your choice (decided later) | |
| Restore | Copy the files back from the NAS and compare names and sizes again | |

## Open question from step 4: is a stale member re-admitted?

If the controller also re-admits a drive that missed writes, pulling a drive, working on, and
pushing it back silently splits the mirror. Proposed test (test data only, backup on the NAS):
1. Pull Bay 1 (bottom) again.
2. Write a marker file and change one test file while degraded.
3. Put Bay 1 back. Rebuilding means the controller tracks this; Online within seconds means it doesn't.
4. If it went straight to Online: pull Bay 2 (top) and read from Bay 1 alone. A missing marker
   proves the bottom drive is stale. Put Bay 2 back afterwards and watch for a copy.

### Result 2026-11-08 14:06–14:07: the stale member is caught, not re-admitted

Bay 1 pulled at 14:06:01 (Degraded). While it was out: `raid-test/MARKER-degraded.txt`, a 512 MB
`raid-test/new-while-degraded.bin`, and 8 MB overwritten in place at the start of
one test file, flushed (hashes in `/tmp/rt/degraded-*.sha`). Bay 1 pushed back:
14:07:01 "Disk 1 rejected" (Missing → Rejected), **14:07:16 "Disk 1 blank" (Rejected → Blank,
status 4)**, array **still Degraded**. So the controller does track missed writes: a member that
missed writes is demoted to Blank instead of re-admitted. **No copy started** (status 4 isn't one
that triggers the automatic copy on insertion, 1 or 5). The earlier clean re-admission (step 4)
was because nothing had changed while it was out.

Pulled and reinserted again at 14:13: Missing → Rejected → **Blank** (14:13:46), still Degraded,
no copy. Reinserting doesn't help once a drive is marked Blank, so the Replace guide's "take it
out and insert it again" advice is wrong for this case. Next: the manual rebuild (the old app's
Rebuild button: ModeChange with payload[0x0A] = 0x81, source port at 0x1C).

### Result 2026-11-08 ~14:20–14:42: the controller rolled back to the stale drive by itself

- ~14:20 `graidctl rebuild --from 2` preview (read-only): Bay 1 (bottom, PK1334PEHT4U9S) **Blank**,
  Bay 2 (top, PK1334PEHNVSSS) **Online**, array Degraded. Matches the app's events from 14:13.
- G-RAID Utility was quit from then on; the first real attempt never ran (wrong folder).
- ~14:36 the real attempt refused: "Bay 2 is Blank". `graidctl status` confirmed the swap:
  **Disk 1 (bottom, stale) Online, Disk 2 (top, up to date) Blank with order 0xFF** (no longer a
  member), array Degraded. The disk never disappeared (no DISK change in the log) and the volume
  stayed mounted.
- Reading with the cache bypassed: `MARKER-degraded.txt` and `new-while-degraded.bin` are gone,
  one test file is back to its original hash, and all 42 files match their pre-test hashes.
  **The volume is now served from the drive that missed the writes; the writes made while degraded
  were silently lost.**
- No command was sent between the two readings: only read-only status queries (the preview).
  What triggered the swap is unknown.

Raw replies at 14:36 (`graidctl status --json`): disk status port 0 `00 00 …` (Online),
port 1 `04 ff …` (Blank, order 0xFF); RAID status volume `01` (Degraded).

**Practical meaning:** after a drive is pulled and the array keeps being written, putting the
old drive back can, some minutes later, make the controller switch to the old drive's data
without any warning. The app must warn about this, and must never suggest reinserting a drive
that was out while the volume was in use.
