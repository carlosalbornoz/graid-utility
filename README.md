# G-RAID Utility

A native macOS replacement for G-Technology's 2017 "G-RAID with Thunderbolt Configurator":
a SwiftUI app and the `graidctl` command-line tool for the G-RAID with Thunderbolt
(ASMedia ASM1092R controller). It shows the array and both drives, changes the RAID mode,
watches for problems, unlocks the disk at login, runs speed tests, and guides drive
replacement.

- [`graidctl/`](graidctl/): the app and CLI. Start with [graidctl/README.md](graidctl/README.md).
  Protocol notes in [PROTOCOL.md](graidctl/PROTOCOL.md), firmware findings in
  [FIRMWARE.md](graidctl/FIRMWARE.md), plans in [ROADMAP.md](graidctl/ROADMAP.md).
- [`firmware/`](firmware/): tools used to study the controller firmware offline (8051
  disassembler, switch-table lister, a small emulator). The firmware image itself isn't
  included; `graidctl firmware-dump` reads your own unit's (read-only).

## Download

Get the latest version from [Releases](https://github.com/carlosalbornoz/graid-utility/releases).
Unzip `G-RAID-Utility-<version>.zip`, move the app to Applications, and open it. A setup
checklist then walks you through Full Disk Access and connecting the G-RAID.

> [!IMPORTANT]
> **The first time, macOS will refuse to open G-RAID Utility. That's expected, and the app is
> fine.** macOS only opens downloaded apps without asking when the developer pays Apple for a
> Developer ID ($99 a year) and sends every build to Apple to be checked ("notarized"). This is a
> free, open-source project, so it isn't notarized. All the code is here to read, and you can
> build the app yourself instead (see [graidctl/README.md](graidctl/README.md)).

**If macOS says "Apple could not verify G-RAID Utility is free of malware":**

1. Click **Done** (not Move to Trash).
2. Open System Settings → Privacy & Security, scroll down to **Security**, and click
   **Open Anyway** next to "G-RAID Utility".
3. Confirm with your password or Touch ID, then click **Open**.

You only need to do this once per version.

**If macOS says "G-RAID Utility is damaged and can't be opened":** the app isn't broken. This
message means its signature didn't survive the download, which some browsers, archive tools and
cloud-synced folders cause. Delete it, download the zip again, and unzip it by double-clicking it
in Finder. If it still says damaged, run this in Terminal, then open the app again:

```sh
xattr -dr com.apple.quarantine "/Applications/G-RAID Utility.app"
```

That removes the "downloaded from the internet" flag, so macOS stops checking the app. Only do it
for a copy you got from this page.

## Status

Personal project, tested on one G-RAID with Thunderbolt (firmware 140827300211, 2 × 4 TB).
Verified on that unit:

- Status, monitoring, eject, speed test, drive sleep and the health report
- Changing the RAID mode (RAID 0 → RAID 1): exact new size, reconnects by itself in seconds
- Detecting a pulled drive in RAID 1: Degraded status, notification, volume stays readable
- A manual rebuild (`graidctl rebuild`) run to completion: 4 TB in about 9 hours, with live
  progress, and every test file intact afterwards

Not yet verified: Individual (JBOD) mode, SPAN, and a power cut during a rebuild.
See [graidctl/TESTING.md](graidctl/TESTING.md) for every result.

**Back up before you use it.** Changing the RAID mode erases both drives, and a rebuild erases
the drive it copies onto.

**Don't put a pulled drive back into a RAID 1 that was written to while it was out.** In
testing, the controller marked that drive Blank and then, minutes later and with no command
sent, switched the volume over to the old drive's data. Everything written while degraded was
lost silently. Insert a new or blank drive instead, or rebuild from the up-to-date bay with
`graidctl rebuild` and check which bay that is first.

The tool never writes the controller's flash or memory: the flash erase/write and memory-write
commands are deliberately not implemented.

## Not affiliated

Not affiliated with or endorsed by G-Technology or Western Digital. "G-Technology", "G-RAID"
and related names are their trademarks. Their artwork (the enclosure picture and the app icon)
isn't in this repository, but the release downloads include it; see
[graidctl/Resources/README.md](graidctl/Resources/README.md).
