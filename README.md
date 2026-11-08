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

## Status

Personal project, tested on one G-RAID with Thunderbolt (firmware 140827300211). Status,
monitoring, eject, speed test and drive sleep are verified on that unit; RAID mode changes and
drive replacement are built and self-tested but not yet exercised on hardware. Changing the
RAID mode erases both drives. Back up first.

The tool never writes the controller's flash or memory: the flash erase/write and memory-write
commands are deliberately not implemented.

## Not affiliated

Not affiliated with or endorsed by G-Technology or Western Digital. "G-Technology", "G-RAID"
and related names are their trademarks. Their artwork isn't included; see
[graidctl/Resources/README.md](graidctl/Resources/README.md).
