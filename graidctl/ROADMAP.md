# Roadmap

How to build the next features.

**Firmware disassembled 2026-11-08 (see FIRMWARE.md):** SPAN is fully implemented in the
controller (mode 3 → internal level 6, reported back as mode 3); the controller accepts 17
command opcodes including an arbitrary memory write (0x51, never implement) and several
unknown ones; member sizes are rounded down to 8 or 64 MiB boundaries.

**Deeper firmware analysis done (2026-11-08):** a separate agent worked through
`graid/firmware/HANDOFF.md` offline, first with an 8051 emulator, then cross-checked against a
full Ghidra decompilation through REA (`graid/firmware/scratch/rea_decomp/`). Its findings and
the app changes they call for are at the top of `FIRMWARE.md`. Reviewed the same day; applied:
- **Exact capacity:** `arrayBlocks` (core) uses the firmware formula: 32 MiB reserved per disk,
  RAID 0 = 2 × (smaller − reserve) and RAID 1 = smaller − reserve, both rounded down to 32 MiB.
  It reproduces the real unit's RAID 0 size to the block. The Change RAID Mode sheet no longer
  calls its sizes estimates, and the simulator sizes RAID 1 the same way.
- **No rebuild percentage from TagLBA:** the firmware never fills it, so the progress bar on the
  drive label and overview and the CLI's percentage are gone. A rebuilding drive says "Receiving
  the copy" and the overview shows the status only. (The position can probably be read another
  way; see "Rebuild progress" under Phase 5.)
- **Unique ID is stable** across mode changes and rebuilds, so `knownDrives.<uniqueID>` is safe.
- **Second review of the decompilation** (same day) corrected FIRMWARE.md and `symbols.txt`:
  a drive inserted into a degraded RAID 1 starts a rebuild by itself, **even a drive that isn't a
  member**; volume status 8 (Rebuilding Paused) comes from the flag the agent read as
  "Rebuilding"; there is no "copy engine" (its registers are a timer and its code is part of Get
  Disk Status); the "checkpoint" X:0x0544 is the LBA of the disk command in flight, and the real
  rebuild position is at X:0x04AC–0x04BB; the "standby timer" is the self-reset delay after a
  mode change; SMART and IDENTIFY go to bay 1; no temperature sensor. Still open: how the copy
  itself is driven, SPAN on hardware.

**SPAN: the 2017 Configurator never offered it** (checked in the shipped app, 2026-11-07):
- The mode picker users saw is in `Sheet.nib` (outlet `rbRaidModeSelect`) and has exactly three
  options: "Performance - RAID 0" (tag 1), "Protected - RAID 1" (tag 2) and
  "Individual Disks - JBOD" (tag 0). The tag is the mode number sent to the controller.
- `MainMenu.nib` contains a leftover four-row radio group (Normal, RAID 0, RAID 1, SPAN) with
  template tags (1, 0, 0, 0) and no outlet or action connected: dead UI, never wired up.
- `-[AppDelegate ModeChange_thread]` only proceeds when the selected mode is 0–2; any higher
  value (SPAN is 3) exits without sending a command.
- The binary does contain SPAN *status* strings ("SPAN", "SPAN Created", "plug in SPAN"),
  because the shared controller firmware family can report that mode.
- The controller itself reports `ModeSupported = 0x000F` (bits for modes 0–3), so SPAN may be
  possible at the firmware level, but G-Technology never shipped or tested it on these models.
  Treat it as unsupported; if it's ever added, label its chip "SPAN", not "JBOD".
- Mismatched disk sizes don't change this: the sheet's picker is fixed at three cells (the
  binary never calls `addRow`, `insertRow`, `putCell`, `cellAtRow:column:` or `setTitle:`; it only
  selects by tag and enables or hides the whole group), and the app has no capacity comparison
  or size-mismatch message (its "mismatched" strings are controller status for disk identity).
  The ModeChange payload carries no sizes either, so the controller decides the resulting
  capacity. Mismatched sizes are exactly where SPAN would help (use all of both disks).
- Fixed 2026-11-07, made exact 2026-11-08: the Change RAID Mode sheet's sizes come from
  `arrayBlocks` / `modeCapacity` (core, self-tested), the firmware's own formula (see above). With
  disks more than 1 % apart the text says how much of the larger disk goes unused. The current
  mode shows the controller's real capacity. Mismatched disks are confirmed from the firmware,
  not yet from a real mode change.

**Other old-Configurator behaviour checked 2026-11-08.** The gaps marked Fixed were fixed the same day (self-tested; not yet exercised by a real mode change):
- **Wakes the drives before a mode change.** `btnModeChange:` calls `-[AppDelegate WakeUpDisk]`
  (an ATA IDENTIFY to every disk node: one for RAID 0, both members for RAID 1, each disk in
  JBOD), and pauses its status timer, before queuing `ModeChange_thread`. Fixed: `performModeChange`
  calls `wakeDisks` on every node (one retry after 2 s) and stops if the controller doesn't answer.
- **RAID set name characters.** For RAID 0/1 the old app rejects any of `!@#$%^&*(){}"',`
  ("RAID set name has invalid character(s)…"). Fixed in `modeChangeProblem`; Individual mode skips
  the name check, as the original disables the field.
- **Spare disks.** For RAID 0/1 it accepts Disk 2 in Online, Rebuilding, Spare or Blank. Fixed:
  Spare (status 9) is allowed for RAID 0/1.
- **One copy at a time.** `checkGTC1_0_running` warns when another Configurator is running.
  Two programs writing the same control sectors would interleave commands. Fixed:
  `oldConfiguratorRunning()` (by executable path) blocks mode changes in the app and CLI.
- **Mode change errors.** Replies ≥ 0xF3 show "Failed to change RAID mode! Please try again
  (err: …)". Ours already throws on anything except 0x00/0x20/0xF2. ✓
- **Same mode.** The Configure button is disabled when the selection equals the current mode.
  Ours omits the current mode from the choices. ✓
- **RAID 1 health override.** `CheckRaidStatus` treats a RAID 1 whose volume reads Online as
  Degraded when a member port reads Missing (order 1) and Broken when the primary (order 0) is
  Missing. Fixed: `effectiveVolumeStatus` reports Degraded (a member is still Online) or Broken (none is),
  used by the app's status text and health.
- **Rebuild offered** only when the volume is Degraded and the controller sees two disks.
- **After a mode change** it says "It will be reconnected shortly". Unverified whether the
  Unique ID changes: if it does, our event log records the old unit as Disconnected (warning),
  and per-unit memory (last speed test, remembered volumes) starts fresh.
- Access: it ran `sudo chmod -R o+r /dev/rdisk*` with your password (every raw disk readable by
  everyone until reconnect). Our unlock service scopes this to the G-RAID's nodes only. ✓

## The controller chip (identified 2026-11-08)

The Capabilities reply carries VendorID `0x1B21` (ASMedia) and DeviceID `0x1092`: an
**ASMedia ASM1092R**, a SATA 6 Gb/s RAID port multiplier (one host port, two drive ports;
ASMedia's "Hydra" RAID). It sits behind an ASMedia ASM1062 AHCI host controller (PCI
`1b21:0625`) on the Thunderbolt bridge. The full datasheet and command reference aren't public
(ASMedia only publishes a product brief); everything below is from that brief, StarTech
datasheets for other ASM1092R products, and G-Technology's G-RAID manuals.

What the vendor documents say, and what it means for us:
- **Modes: RAID 0, RAID 1, JBOD and Span (BIG).** SPAN is a real chip mode, matching
  `ModeSupported = 0x000F`. G-Technology just never exposed it. Still untested on this firmware.
- **Automatic background rebuild.** The G-RAID manuals: insert a replacement disk in a degraded
  RAID 1 and the rebuild starts by itself; the volume stays usable; about 2 hours per TB (so
  ~8 h for a 4 TB mirror). Phase 5 is therefore mostly *watching* a rebuild, with Rebuild as a
  fallback when it doesn't start, and the ETA can start from 2 h/TB.
- **Auto recovery from checkpoint.** An interrupted rebuild resumes from where it stopped. The
  position is saved into each member's record and the flash config (0x9249 → 0x8435). TagLBA
  stays zero, but the position can probably be read with GetRegister (Phase 5).
- **Failed/degraded drive detection and a RAID error log.** The log isn't read by the old app.
  Research item: find the vendor command that reads it.
- **SMART drive monitoring** in the chip, and pass-through of vendor-specific commands.
  Research item: SMART health per disk through the controller (StarTech notes SMART is limited
  in RAID modes).
- **Staggered spin-up, per-drive power-down, SATA Partial/Slumber.** Explains what
  `spin-check` measured (the RAID 0 drives wake one at a time) and supports letting the drives
  sleep.
- **Fan control** exists in the chip, but this enclosure reports the fan and temperature flags as
  `0xFF`: almost certainly not wired. Phase 4's sensor probe is low value.
- **JBOD needs a port-multiplier-aware host** to show both disks (StarTech, Delock). Individual
  mode depends on macOS's AHCI driver handling the ASM1092R as a port multiplier. The old app
  expected up to three disk nodes, so it worked on 2014 macOS; it's **unverified on current
  macOS / Apple Silicon**. Check with spare disks before anyone relies on Individual mode.
- Not covered anywhere public: mismatched disk sizes, whether a mode change makes a new Unique
  ID, and the command set. ASMedia gives the datasheet only under NDA.

## Which devices we can support

The old Configurator recognises any disk whose control sectors answer with the
`__ASMEDIA2109A__` signature. It picks the model name from the first two hex digits of the
firmware version (`-[AppDelegate AddDevlist_thread:]`):

| Device | How it's recognised | Icon in `G-Technology_Icons` | Support |
|---|---|---|---|
| G-RAID with Thunderbolt (2014, Thunderbolt 2 + USB 3, removable bays) | firmware `14…` | `G-RAID_TB+USB_removable` | **Verified** on hardware |
| G-RAID with Thunderbolt 3 (2016) | firmware `16…` | none exact; `G-RAID_removable` is the same enclosure | Same protocol per the old app, untested |
| Either of the above connected over **USB** | ASMedia reply, but DiskArbitration protocol `USB` | as above | The old app refused ("USB not support"). Show a "connect with Thunderbolt to manage" card. Whether the commands pass through USB is a research item |
| Unknown firmware prefix answering the protocol | signature only | `G-RAID_removable` | Read-only until confirmed |
| G-RAID with Thunderbolt (2011–13), G-RAID (2013), G-RAID mini, G-RAID Studio, G-DRIVE, G-SPEED, G-DOCK, G-RACK, ArmorATD | no ASMedia controller | their own icons | Nothing to configure. Optional: list them as "Other G-Technology drives" with icon, capacity, volume and Eject |

## Phase 0: foundations — done (2026-11-07)

1. **Model registry.** One table: name, firmware prefix, icon, verified flag, allowed
   actions (status, mode change, rebuild). Unknown models get status only. Replaces the
   hard-coded name and image.
2. **Simulated controller.** Put device I/O behind a small `SectorIO` protocol and add a
   simulator that answers like the real controller. It echoes the request at 0x40, keeps
   the stale-buffer behaviour, and replays the reply bytes captured from the real unit.
   This lets us test monitoring, notifications, mode change and rebuild flows without
   touching hardware. The current fake image can't vary its reply per command.
3. **Settings window (⌘,).** All new background behaviour lives here and is **off by
   default**.
4. **Event store.** Append-only JSON lines in
   `~/Library/Application Support/G-RAID Utility/events.jsonl`.

## Phase 1: optional monitoring (roadmap items 1–3) — done; verified on hardware 2026-11-07 (menu bar, login item, unlock service with Full Disk Access, unplug/replug unlocked in 1 s with no prompt, Disconnected/Connected events). Notification delivery not yet seen: no disk problem has occurred, and connect notifications are off by default

Two independent switches in Settings, both off by default:

**A. "Unlock G-RAID automatically when connected"** (removes the password prompt after
every reconnect)
- On enable, one admin prompt installs a tiny root service:
  `/Library/PrivilegedHelperTools/local.graid.unlockd` (the existing `graidctl`, signed
  with the local identity) and `/Library/LaunchDaemons/local.graid.unlockd.plist`
  (`KeepAlive`).
- It listens for DiskArbitration "disk appeared" events and runs the same
  `grantAccess` logic as today: G-RAID disks only, owner read-only.
- Needs Full Disk Access once (macOS treats a daemon as its own app). Settings shows
  whether it's granted and links to the pane. The stable signing identity keeps the
  permission across updates.
- On disable, one admin prompt removes both files. Uses a plain launchd plist rather than
  `SMAppService.daemon`, which expects Developer ID signing.

**B. "Monitor in the background"**
- When on: the app registers itself as a login item (`SMAppService.mainApp`), adds a
  menu bar icon (`MenuBarExtra`) showing green, orange or red, and keeps running when its
  window closes (switching to an accessory app). When off: no menu bar icon, the app quits
  normally, and the login item is removed.
- Polls every 60 s in the background (15 s with the window open), plus on disk events.
- **Notifications** (`UNUserNotificationCenter`), each toggleable: disk failed or
  predictive failure (status 7), array degraded, rebuild started or finished,
  G-RAID connected or disconnected.
- **Event history:** compare each snapshot with the last one and record changes
  (mode, disk status, connects, mode changes made in the app). A History window lists them
  and exports to CSV.

Works with B alone (you still enter the password after a reconnect) or A and B together
(fully unattended).

Verify: unit tests for the snapshot diff and notification rules against the simulator;
on hardware, unplug and replug to check the connect events and automatic unlock.

## Phase 2: reports, eject, speed test (items 4–6) — built 2026-11-07; verified on hardware: Eject, speed test (RAID 0: 224 MB/s write, 310 MB/s read). Mount Again fixed to skip the EFI partition. Eject spins the drives down (spin check: 13.6 s and 14.6 s to wake after Eject vs 9–27 ms when mounted); the disk stays listed and wakes on demand. Starting-up screen and health report not yet tried on hardware

- **Health report:** model, firmware, disks, current state, recent events and raw
  diagnostics, as text or PDF (render the SwiftUI view to PDF). Menu: File → Export
  Health Report.
- **Eject:** `DADiskUnmount` (whole disk) then `DADiskEject`. Afterwards just confirm
  "Ejected · safe to unplug". Don't assume the user will reconnect it. If something blocks
  the eject, show which app is using the volume (from the dissenter).
- **"Starting up" state (independent of Eject):** the enclosure shows up on the Thunderbolt
  bus (IORegistry `Device Vendor Name` = "G-Technology", `Device Model Name` = "G-RAID with
  Thunderbolt") about 30 seconds before its disk appears (measured 30–39 s). When the
  Thunderbolt device is present but no G-RAID disk is, show "G-RAID found · Starting up…"
  instead of "No G-RAID detected". If no disk appears after about 90 seconds, say the
  enclosure is connected but its disk hasn't appeared, and suggest checking the disks
  or power-cycling.
- **Speed test:** write then read a temporary 4 GB file on the volume with `F_NOCACHE`
  (so the RAM cache doesn't inflate results), delete it, and show MB/s. Skipped when
  free space is low. Read-only to the controller; writes only a temp file.

## Phase 2.5: let the drives sleep (found 2026-11-07) — built and verified on hardware 2026-11-07: with the window closed, checks stop while the counters are flat and resume within a minute of a file read. This Mac has `disksleep 0`, so the drives only spin down after the user turns on "Put hard disks to sleep when possible" (deliberately not encouraged: for older drives, spin-ups cause the most wear, so Settings only explains the setting and points to Eject). The AHCI driver's `CurrentPowerState` reads 0 even while the drives spin, so it can't show spin state

Controller status checks wake the drives: after a Finder eject, with the app still polling
every 15 s, the spin check found them spinning; with polling paused, they stayed spun down.
So background monitoring (every 60 s) would keep the G-RAID from ever sleeping.

- Read the disk's I/O counters from IORegistry (`IOBlockStorageDriver` → `Statistics`:
  bytes/operations read and written). This doesn't touch the disk.
- In the background, run a controller status check only when the counters moved since the
  last check (the drives are awake anyway), plus right after connecting. While the disk
  is idle, skip it so macOS's disk sleep can spin the drives down.
- With the window open, keep checking on the normal schedule (the user is looking).
- Settings toggle "Let the drives sleep when the G-RAID isn't in use" (on by default, only with background monitoring). `graidctl io-counters diskN` prints the counters.
- Done already: ejects from Finder or Disk Utility are noticed (DiskArbitration eject
  approval callback) and pause polling, like the app's own Eject.

### Partitions, including an optional EFI mount — built and verified on hardware 2026-11-07

Started as "mount EFI on request"; redesigned because an array can hold several partitions.
Every partition is listed (`Sources/Core/Partitions.swift`, from IORegistry and DiskArbitration
only, so listing never wakes the drives) and sorted into three kinds:
- **Volumes** (APFS, Mac OS Extended, exFAT, FAT, NTFS): shown in the main view, mounted or not,
  with Mount. Volumes inside APFS containers are found through the container disk.
- **System partitions** (EFI, Microsoft Reserved, Windows Recovery, Apple_Boot, APFS
  System/Preboot/Recovery/VM…): only in the **Partitions** card under More Details and in
  Device → Partitions.
- **Unreadable** (ext4, Linux swap, unformatted): listed there as "macOS can't read it".

Behaviour: Mount Again restores exactly the volumes that were mounted, never system partitions;
if they're gone it mounts the whole disk and unmounts any system partition that came up. Eject
unmounts APFS containers first, and system partitions mounted as root. Used figures count
volumes only. Speed test offers a choice when several writable volumes are mounted. The erase
review also lists unmounted volumes. No partition editing: that stays in Disk Utility.

macOS lets only an administrator mount an EFI partition (DiskArbitration "not permitted",
`diskutil mount` fails as a user), so Mount/Unmount on a system partition falls back to one
password prompt running `diskutil mount|unmount diskNsM` as root.

Verified on hardware: listing (EFI system, G-RAID exFAT), Unmount and Mount of the data volume,
Device → Partitions menu. EFI mount needs the user's password, so it was not tried by the agent.
APFS listing verified against the Mac's internal disk only.

## UI redesign: Liquid Glass — built and verified on hardware 2026-11-07

Mocked up first (`mockups/LiquidGlassMock.swift`, `mockups/render_mock.sh`), then built in
`Sources/App/MainUI.swift`. Direction: glass for controls, solid for content.
- Liquid Glass only on the navigation layer: the standard unified toolbar, the section control
  (at its own size inside the toolbar's glass capsule, so the capsule hugs the tabs) and the
  overview panel on the left. The compact toolbar was tried and rejected: too tight at the window
  edges, and hiding the capsule lost the glass. Content sits on the system background in hairline groups.
- No gradients or glows (the user rejected the first gradient-heavy mockup). One accent,
  G-Technology blue, for data and selection; system green/orange/red for status only.
- Left: always-visible overview (device, health, specs, mounted volumes, Speed Test, Report).
- Right: three sections, ⌘1–3. **Array** merges the old Disks and RAID views. Redone
  2026-11-08 (installed; checked in preview renders, not yet looked at against every state on
  hardware): the RAID 0 block diagram was teaching how striping works, which matters when
  choosing a mode, not when checking drives, and the drive sleds read as NAS trays. Now each
  bay is a neutral 3.5-inch drive whose label is the info card: vendor word on top, model,
  size as drives are sold, status, role, serial. Rules, so any drive looks right without a
  table of known models:
  - Vendor = the model's first word when it's 2–12 letters followed by more text
    (`splitDriveModel`, self-tested). "HGST", "WDC", "Samsung" qualify; Seagate's
    "ST4000DM004" has none, so the top line stays empty and the label doesn't shift. Shown as
    reported ("WDC", not "Western Digital").
  - Size = `driveSizeText`: decimal units, whole numbers from 10 up, one decimal below that
    with ".0" dropped ("4 TB", "3.9 TB", "500 GB"); one decimal kept on both drives when they
    differ by more than 1 %.
  - No open-platter drawing and no rpm: the controller doesn't say whether a drive is
    spinning disk or SSD.
  - A brace over the bays names the volume ("One 8.00 TB volume", "…, mirrored"); none in
    Individual mode. The mode's risk is the one-line summary under the heading.
  - States change the drawing: Missing dashed (named from the last drive seen in that bay,
    stored per unit in `UserDefaults` as `knownDrives.<uniqueID>`), Failed / ID Mismatch /
    Rejected with a red label edge, Rebuilding with an orange status and a "Receiving the copy" note (no progress bar: the firmware doesn't report one), an empty
    bay as "No drive".
  - Notes under a drive only when it needs something: replacement size for RAID 1 (the
    volume's size), "the volume can't be read without this drive" for RAID 0, expected
    failure, receiving the copy, and which drive limits a mismatched array.
  - Click a drive: full model, serial with Copy, exact size in bytes and sectors.
  The Individual / RAID 0 / RAID 1 pictures live in the Change RAID Mode sheet next to each
  choice (`ModeDiagram`); picking a mode animates the blocks landing in write order.
  **Volumes**: Open Disk Utility beside the heading; per-disk partition map that
  always includes system partitions as a grey slice; volume rows; the system partitions' details
  in a collapsed group.
  **Activity**: recent events as a timeline and the last speed test (saved per unit) as
  measured bars. Timeline spacing fixed 2026-11-08: rows size to their content with a 14 pt gap
  between them (they were a fixed 36 pt, leaving gaps under rows without a detail line),
  connector lines stop 4 pt from both icons, and the time shares the title's baseline.
- Preview renders (`tests/render_previews.sh`) cover the drive states: `array-raid0`,
  `array-mismatch`, `array-raid1-missing`, `array-raid1-failing`, `array-individual-empty`,
  `ready-rebuilding`, `activity`, `change-step1-selected`, `array-raid1-rebuilding`, `change-step1-mismatch`.
- Speed Test sheet redone 2026-11-08 (renders only; not yet run on hardware): separate Write
  and Read lanes. Each lane's track fills left to right with that phase's progress, the fill's
  height at each point being the speed sampled there (every 0.25 s, `SpeedSample`), with a live
  smoothed MB/s readout while it runs and the average (number plus a hairline) when it ends.
  Both lanes share one scale (100 MB/s steps, at least 400). Write average still includes
  `F_FULLFSYNC`, so it can sit a little below the live samples.
- Fixed 2026-11-08 from the renders: the overview no longer truncates "Protected" next to the
  RAID 1 chip (`ModeName` keeps the name at full width). A RAID 1 member that is Failed, ID
  Mismatch or Rejected now counts like a Missing one in `effectiveVolumeStatus` (Degraded while
  a copy survives, Broken when none does; a Predictive Failure drive still holds a copy), so the
  status no longer reads "Online" beside a failed drive. "Disks: n of 2 online" counts drives
  that still answer (Predictive Failure, Verifying, Migrating). Self-tested; not seen on hardware.

## Phase 3: create the volume after a mode change (item 7)

- After a mode change succeeds and the unit reconnects (matched by unique ID), the app
  offers "Create a volume": name, format (APFS default, exFAT for sharing with Windows,
  Mac OS Extended), GPT. It runs `diskutil eraseDisk <format> <name> GPT diskN`, once per
  disk in Individual mode.
- Can only be confirmed with a real mode change, so test it with spare disks in the
  enclosure first.

## Phase 4: firmware backup and sensor probe (items 10–11)

- **Firmware backup:** built 2026-11-08 as `sudo graidctl firmware-dump [file]` (opcode 0x20
  only, reads 0x1F000 bytes twice and saves only if both passes match, prints SHA-256; tested
  on the simulator). **Dumped from the unit 2026-11-08**: `graid/firmware/G-RAID-firmware-140827300211-4a83278da74eca68.bin`,
  SHA-256 `5cbe3058ccc544db281cf8a19446bcebaabc4050ac0dd29a42ce3c3d6aaf1f00`, both passes identical
  (4 s and 10 s). Layout: 0x000–0x07F unit config (USB-style IDs 1B21:2109, ATA model
  "ASMT109x", placeholder serial "0123456789"), 0x080 "ASMT" header with firmware version
  140827300211 at 0x09C, 8051 code (Keil C51 library patterns) up to ~0xF000, then erased
  (0xFF). Debug strings include `SendSpindown`, `COMRESET1/2`, `PlugIn`, `PlugOut`, `NoDev`,
  `Id Mismatch` and port-mapping tables, so the controller manages drive spin-down itself.
  Disassembled 2026-11-08 (8051, Keil C51; findings in FIRMWARE.md, tools in
  `graid/firmware/tools/`); the deeper pass is done (see the note at the top). An app button can come later. Erase and write commands are never exposed.
- **Temperature and fan: dropped.** The firmware hard-codes those Capabilities bytes to `0xFF`
  (0xDA14); there is no sensor to read.

## Phase 5: replace and rebuild a disk (item 8)

The firmware review changed this phase: the controller starts a rebuild on its own as soon as a
drive goes into the empty bay of a degraded RAID 1, so the app mostly guides and watches.

- **Replace-a-drive guide — built 2026-11-08** (self-tested and rendered; not yet seen on
  hardware). A "Replace a Drive…" button appears next to the status on the Array view whenever
  `computeReplaceStep` (core) finds a RAID 1 that needs or is getting a new drive. The sheet
  (`Sources/App/ReplaceDrive.swift`) sends nothing to the G-RAID; it reads the status as it
  changes and walks through: remove the failed drive (only when one is still in), insert a drive
  of at least the volume's blocks + 0x10000 (`replacementMinBlocks`, shown in TB and sectors),
  then the copy, which starts by itself. An orange warning says the inserted drive is erased
  without asking (or, once a drive is in but not copying yet, that it will be). While copying:
  the source bay, "seen since" (kept per unit in `UserDefaults` as `rebuildSeen.<uniqueID>`), an
  estimate from 2 h per TB (`rebuildEstimate`), an indeterminate bar, and a note that the
  existing notification fires when it finishes. Paused and failed copies have their own text.
  Broken arrays (no surviving copy) get no guide. Previews: `replace-remove`, `replace-insert`,
  `replace-waiting`, `replace-copying`, `replace-failed`, `array-raid1-empty-bay`. Still to do:
  a simulator scenario for "degraded RAID 1, insert a drive", then a real test on spare disks.
- **Empty-bay warning — built 2026-11-08.** While a RAID 1 needs a drive, the empty (or failed)
  bay on the Array view says any drive put there is erased for the copy, with the minimum size.
- **Rebuild progress via GetRegister.** The position and end are 64-bit values at
  X:0x04AC–0x04BB (FIRMWARE.md "Rebuild"). GetRegister (opcode 0x50) is read-only and the old
  app used it; reading 16 bytes is 16 small commands, fine every 15 s. Steps: a `graidctl
  rebuild-position` research command that prints the bytes, run it a few times during a real
  RAID 1 rebuild on spare disks to pin down which bytes are "current" and "end", then bring the
  progress bar and a real ETA back. Until then, the estimate uses the manual's 2 h per TB.
  Only RAM addresses are read; never hardware registers (0xE000 and up), whose reads can have
  side effects.
- **Manual Rebuild button** (fallback, last): for when an automatic rebuild doesn't start. The
  packet is known: a normal ModeChange with payload[0x0A] = 0x81 and the source port first at
  0x1C. It needs spare disks to test, and the same "destination is erased" confirmation.

## Feature ideas from the firmware review (2026-11-08)

In rough order of value. The first ones need no new controller commands.

1. **Replace-a-drive guide and empty-bay warning** (Phase 5 above) — built 2026-11-08.
2. **Rebuild progress through GetRegister** (Phase 5 above).
3. **Recovery card.** The array's layout lives in the enclosure's flash, not on the drives, so
   if the enclosure dies the drives alone don't say how they were combined. Save per unit, and
   include in the Report: mode, stripe size (RAID status reply), member order with model and
   serial, each drive's block count, the 32 MiB reserve, the volume size, and the Unique ID.
   Updated whenever the configuration changes. Where the reserve sits on each drive (start or
   end) is still unconfirmed, so the card says so.
4. **Drive history per unit.** The Unique ID never changes, so keep a per-unit log in Activity:
   drives seen in each bay with dates ("Bay 2: HGST … replaced by WDC …"), mode changes, and
   past speed tests for comparison. Builds on `knownDrives.<uniqueID>`.
5. **Restart after a mode change.** The controller resets itself after a mode change (delay at
   X:0x0A72:73, then 0x0FAD). The Change Mode sheet can say the G-RAID restarts and wait for it
   to reconnect (30–39 s seen on hardware), then hand over to Phase 3's "Create a volume".
6. **SPAN ("Combined")** for mismatched drives: size formula confirmed (`Σ(disk − 32 MiB)`),
   creation path present. Needs a test on spare disks before it's offered.
7. **Manual Rebuild button** (Phase 5 above).

Considered and dropped:
- **Temperature and fans:** the controller hard-codes those Capabilities bytes to 0xFF; there
  is no sensor. Drive temperatures exist only in SMART (below).
- **A drive sleep timer in the controller:** there isn't one (the value thought to be one is
  the self-reset delay). Drive sleep is the Mac's job and is already built (Phase 2.5).
- **Per-drive SMART:** SMART commands are forwarded to bay 1 only (0x87EC), and choosing the
  drive would need writing controller memory (0x51), which is off-limits. Bay 1's SMART alone
  could still be shown later, labelled as such; low priority, since the controller's own
  Predictive Failure status already covers both drives.
- **Unknown commands 0x60, 0xA0, 0xC1, 0xF9:** a factory link test, the reset delay and an
  internal switch. Nothing for users.

## Suggested order

Phase 0, then 1, then 2 and 3 (small), then 4, then 5. SPAN after research.
