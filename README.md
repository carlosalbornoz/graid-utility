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
Unzip `G-RAID-Utility-<version>.zip`, move the app to Applications, and open it.

**The first time, macOS blocks it.** The app isn't notarized by Apple, so macOS says it can't
verify it. Click **Done**, open System Settings → Privacy & Security, scroll down to
Security, and click **Open Anyway** next to "G-RAID Utility". Confirm with your password.
You only need to do this once per version.

Then turn on **Full Disk Access** for G-RAID Utility in System Settings → Privacy & Security →
Full Disk Access. macOS doesn't allow raw disk reads without it, even for administrators.

## Status

Personal project, tested on one G-RAID with Thunderbolt (firmware 140827300211, 2 × 4 TB).
Verified on that unit:

- Status, monitoring, eject, speed test, drive sleep and the health report
- Changing the RAID mode (RAID 0 → RAID 1): exact new size, reconnects by itself in seconds
- Detecting a pulled drive in RAID 1: Degraded status, notification, volume stays readable
- The manual rebuild command (`graidctl rebuild`): accepted and copying

Not yet verified: a rebuild running to completion, Individual (JBOD) mode, SPAN.
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
