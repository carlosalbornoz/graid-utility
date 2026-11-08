# G-RAID Utility and graidctl

A native replacement for **G-RAID with Thunderbolt Configurator 1.1** (HGST/WD, 2017,
Intel-only), as both a Mac app and a command-line tool. Both run natively on Apple
Silicon and need no driver, kext or DEXT. They talk to the enclosure's ASMedia bridge
the same way the original app does: by reading specific sectors in a specific order
(see [PROTOCOL.md](PROTOCOL.md)).

> **Status:** status reading is verified on a real G-RAID with Thunderbolt (RAID 0,
> 2 × HGST 4 TB, macOS 27). Changing the RAID mode has **not** been tried on hardware.

## Build

```sh
./build.sh                  # → build/G-RAID Utility.app and build/graidctl (both universal)
build/graidctl selftest     # protocol encoding/parsing checks
tests/fake_device.sh        # end-to-end run against a fake controller image
tests/render_previews.sh    # renders the app's screens with sample data → build/previews/
```

Building needs only the Command Line Tools (`xcode-select --install`). Xcode isn't required.
If a code-signing identity named "G-RAID Utility Local Signing" exists in the keychain,
`build.sh` signs with it. A stable identity keeps Full Disk Access across rebuilds;
without it the build is ad-hoc signed and Full Disk Access must be re-enabled after each build.
arm64 targets macOS 13+ and x86_64 targets macOS 14+.

## The app

Copy `build/G-RAID Utility.app` to `/Applications` and open it. It uses the original
Configurator's icon and status artwork.

- **Full Disk Access (required):** macOS blocks raw disk reads, even as root, unless the
  app has Full Disk Access. Turn it on for G-RAID Utility in System Settings → Privacy &
  Security → Full Disk Access. For the CLI, the terminal app running it needs it.

- **First run per connection:** the app shows a lock screen. Click **Allow Access…** and
  enter an administrator password. The bundled `graidctl` helper confirms which disks
  are G-RAIDs, then makes only those raw disks readable by your account (read-only).
  macOS resets this when the drive disconnects, so you'll be asked again after
  unplugging the drive or changing its mode. The original app instead made the raw
  disks readable by every account.
- **Main window:** an overview panel on the left (the enclosure, health and status,
  capacity, mode, firmware, name, mounted volumes, Speed Test and Report) and three
  sections on the right, switched in the toolbar or with ⌘1–3. It refreshes every 15 seconds,
  when disks come and go, and with ⌘R.
  - **Array:** the mode in plain words with its RAID chip and a one-line summary of what it
    means for your data. Each bay is drawn as a 3.5-inch drive whose label shows the vendor
    word (when the model text starts with one), the model, the size as drives are sold
    ("4 TB"), status, role ("Disk 1 of 2 · RAID 0", "Copy 2 of 2 · RAID 1") and serial. Nothing
    comes from a table of known drives, so any vendor's drive looks the same. A brace over
    the bays names the volume they form. Missing drives are drawn dashed and still named
    (the app remembers the last drive seen in each bay), failed drives get a red label edge,
    and a rebuilding drive says it is receiving the copy. When a RAID 1 needs a new drive, the empty bay warns that
    any drive put there is erased for the copy (the controller starts copying by itself), and
    **Replace a Drive…** walks through removing the failed drive, inserting one of the right
    size, and following the copy, with a time estimate. A note appears under a drive only when it
    needs something: the size a replacement needs, which drive limits a mismatched array,
    an expected failure. Click a drive for its full model, serial (with Copy) and exact size.
  - **Volumes:** a partition map per disk, volume rows, and the system partitions in a
    collapsed group. Open Disk Utility sits beside the heading.
  - **Activity:** recent events as a timeline, newest first, and the last speed test as
    measured bars.
- **Change RAID Mode…** (Array section) opens a two-step sheet:
  1. The current mode is shown on its own with a green check, then "Switch to" lists only
     the other modes. Each shows what you'd get with your disks (for example
     "8.00 TB in one volume") and a picture of where a file's blocks land on the two disks;
     picking a mode plays the blocks landing in write order (skipped with Reduce Motion).
  2. Review: how much data on the volume will be erased, the new layout and the disks.
     Type `ERASE`, then click the red **Erase and Set Up …** button. Afterwards the app
     offers to open Disk Utility to create the new volume.

  The button is unavailable while a rebuild or verify is running.

### Device tools

- **Eject** (header button or ⌘E): unmounts and ejects, then shows "Ejected · safe to
  unplug". While ejected the app stops reading from the G-RAID; **Mount Again** brings
  the volume back without unplugging. If an app is using the volume, it says which.
- **Check Drive Spin State** (Device menu): times reads of random sectors to tell whether
  the drives are spinning. After Eject they're spun down (about 14 s per drive to wake);
  mounted, reads take milliseconds.
- **Starting up:** when the enclosure is on Thunderbolt but its disk hasn't appeared yet
  (it takes about 30 seconds after connecting), the window says so instead of
  "No G-RAID detected", and warns if the disk hasn't shown up after 90 seconds.
- **Speed Test…:** writes and reads a temporary 1, 4 or 8 GB file with caching off, then
  deletes it. Shows write and read MB/s.
- **Health Report…** (⇧⌘E): saves a PDF or text summary of the model, firmware, array,
  disks, recent events and raw controller replies.

### Optional background features (Settings, ⌘,; all off by default)

- **Monitor in the background:** adds a menu bar icon (green, orange or red), keeps
  checking every minute after you close the window, and opens at login. Notifications are
  grouped as disk problems, array health, connect and disconnect, and RAID mode changes,
  and each group can be switched on or off.
- **Unlock automatically when connected:** installs a small root service
  (`/Library/PrivilegedHelperTools/local.graid.unlockd`, launchd label
  `local.graid.unlockd`) with one password prompt. When a disk appears it unlocks G-RAID
  disks only, read-only, for your account. It needs Full Disk Access once; Settings shows
  its state and the steps. Switching it off removes it.
- **Event history** (Window → Event History, ⌘Y): connects, disconnects, mode changes,
  and array and disk state changes, stored in
  `~/Library/Application Support/G-RAID Utility/events.jsonl`, exportable as CSV.

### Supported models

| Model | Status |
|---|---|
| G-RAID with Thunderbolt (firmware 14…) | Verified |
| G-RAID with Thunderbolt 3 (firmware 16…) | Same protocol, untested |
| Unrecognised firmware answering the protocol | Status only |
| Any of these connected over USB | Shown as "connect with Thunderbolt to manage" |

## The command-line tool

Every command that touches the disk needs `sudo`.

```sh
sudo graidctl list                 # which disk is the G-RAID
sudo graidctl status               # firmware, RAID mode/state, both disks
sudo graidctl status disk4 -v      # pick a disk; print every sector read and ack status
sudo graidctl status --json        # raw reply bytes, useful for troubleshooting
sudo graidctl set-mode raid1 --name G-RAID --yes-erase-all-data
graidctl status --simulate         # try it against the built-in controller simulator
sudo graidctl firmware-dump        # read-only backup of the controller firmware (reads twice, saves if both match)
```

## Source layout

| Path | What |
|------|------|
| `Sources/Core/GRAIDCore.swift` | Protocol, parsing, discovery, mode change (shared) |
| `Sources/Core/Simulator.swift` | Model registry and the controller simulator (replies captured from a real unit) |
| `Sources/Core/Events.swift` | Snapshot diff, event log |
| `Sources/CLI/main.swift` | `graidctl` |
| `Sources/App/` | SwiftUI app: `AppMain.swift` (scenes), `Model.swift`, `GRAIDApp.swift` (main window), `MonitorViews.swift` (Settings, menu bar, history), `Services.swift` (unlock service, login item, notifications), `ReplaceDrive.swift` (Replace a Drive guide) |
| `Resources/` | Icon and images copied from the original Configurator |
| `tests/` | Fake-device test and the preview renderer (`tests/preview/RenderPreviews.swift`: sample units for every drive state) |
| `PROTOCOL.md`, `FIRMWARE.md` | Host protocol; controller firmware findings (from the dump in `../firmware/`) |

The views use `@StateObject` instead of `@State`, because the Command Line Tools ship
without the SwiftUI macro plugin.

## Unplugging and reconnecting

Eject in Finder (or unmount in Disk Utility) before unplugging. After you plug the
Thunderbolt cable back in, the G-RAID takes **about 30 seconds** to reappear while it
starts up; there's no need to switch it off and on. Measured 2026-11-07: 30–39 seconds
from cable-in to disk-back, the same after an eject or an unmount.

## Not included (on purpose)

- **Firmware flashing.** A mistake can brick the controller. Use the original app under
  Rosetta if you ever need it.
- Update checks. The old G-Technology update URLs are gone.

## Artwork

The icon and status images in `Resources/` come from Western Digital's Configurator.
They're fine for your own copy, but don't redistribute the app with them.

## First test on real hardware

1. Connect the G-RAID and confirm it mounts normally.
2. Open G-RAID Utility, click **Allow Access…**, and enter your password.
3. Compare with the original app under Rosetta: firmware, unique ID, mode, and disk
   models and serials should match.
4. If anything differs, run `sudo build/graidctl status -v --json` and keep the output.
