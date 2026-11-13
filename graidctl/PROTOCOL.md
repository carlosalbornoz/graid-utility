# G-RAID with Thunderbolt: controller protocol

Reverse-engineered from `G-RAID with Thunderbolt Configurator.app` 1.1 (build 52,
SHA-256 of the executable `6063b8df96a9f193a425188a5fce7ded72924bb589c7c8daa90e6589153bcb4a`).
Everything below comes from the shipped binary. Status commands (Identify, GetCapabilities,
GetRAIDStatus, GetDiskStatus) were confirmed on a real unit on 2026-11-07: G-RAID with
Thunderbolt (Thunderbolt 2), firmware 140827300211, RAID 0 over two HGST HUS724040ALE640.
ModeChange has not been sent to real hardware.

## Transport

There is no driver and no IOKit user client. The bridge firmware (it identifies
itself as `__ASMEDIA2109A__`) watches the **sequence of sector numbers that are read**
from the disk and decodes commands from it. The host never writes to the disk.

- The original app opens `/dev/diskN` read-only after making it world-readable with
  `sudo chmod o+r`. `graidctl` opens `/dev/rdiskN` (raw, uncached) as root instead, so
  every read reaches the device.
- Every read is 512 bytes at offset `LBA * 512`.

### Sending a packet (`SendPacket` / `SendPhysicalLBA`)

The packet is a list of LBAs, each carrying one byte plus a tag in bits 8–10:

| Packet bytes            | LBA value               |
|-------------------------|-------------------------|
| header (4 × u16)        | `0x43, 0x71, 0xA7, 0xDF` |
| control (4 bytes)       | `byte | 0x100`          |
| command (4 bytes)       | `byte | 0x200`          |
| data (128 bytes, long packets only) | `byte | 0x300` |
| CRC (4 bytes)           | `byte | 0x400`          |

If an LBA equals the previous one (the previous value starts at 0), sector `0x5FFF` is
read first as a separator, so the controller sees two distinct reads.

Control bytes: `[flags, class, cascade, port]`. `flags` = 1 for long packets with a
data block. `class` = 4 for read/query commands and 5 for state-changing ones.

Command bytes: `[opcode, 0xCF, p1, p2]`.

CRC: standard CRC-32 (zlib, reflected 0xEDB88320) computed over the in-memory packet:
the header as four little-endian u16 (`43 00 71 00 A7 00 DF 00`), then control and
command, then the data block if present. The CRC is sent most significant byte first.

### Acknowledgement (`GetAckData`)

The host repeatedly reads LBA `0x11` until the 512-byte sector contains
`__ASMEDIA2109A__` at offset 0 and `_PORTMULTIPLIER_` at offset `0x1F0`.

- Status byte: offset `0x30`
- Echo of the request: offset `0x40`–`0x4F` holds the 16-byte packet that produced the
  reply (header, control, command). Seen on hardware, not used by the original app.
- Response payload: offset `0x50`

The controller has a single result sector that keeps its signatures between commands, and
each reply only overwrites its own length. A read right after sending can return the
previous command's reply (seen on hardware). `graidctl` only accepts a sector whose echo
matches the command it sent. The original app does not check this.

Status values: `0x00` success, `0x10` in progress, `0x20` complete (data valid),
`0xC0` blocked, `0xD0` subcommand mismatch, `0xE0` CRC error, `0xF0` unsupported,
`0xFF` failure. Host-side codes: `0xF1` read failure, `0xF2` ack timeout,
`0xF4` invalid status, `0xF6` invalid parameters.

## Commands

| Name             | ctrl (flags,class,cascade,port) | cmd                    | Reply |
|------------------|----------------------------------|------------------------|-------|
| Identify         | 00 04 EF FF                      | 10 CF DF EF            | status only |
| GetCapabilities  | 00 04 00 00                      | 11 CF DF EF            | 0x48 bytes |
| GetRAIDStatus    | 00 04 00 00                      | 15 CF DF EF            | 0xA4 bytes |
| GetDiskStatus    | 00 04 00 00                      | 17 CF DF EF            | 0x180 bytes |
| GetRegister      | 00 04 00 00                      | 50 CF + addr           | 1 byte (not used by graidctl) |
| Reset            | 00 05 00 00                      | F0 CF hi lo            | status (not used by graidctl) |
| ModeChange       | 01 05 00 00                      | B0 CF 13 88            | status; 128-byte data block |
| ReadFlashRom     | 00 04 EF FF                      | 20 sel hi lo           | 128 bytes of SPI flash at `(hi<<8 \| lo) << 7`; `sel` = 0 in the original. Used by `graidctl firmware-dump` |
| EraseFlashRomSector | 00 05 EF FF                   | 23 sel hi lo           | erases 4 KB. **Not implemented, on purpose** |
| WriteFlashRom    | 01 05 EF FF                      | 25 sel hi lo           | writes 128 bytes from the data block. **Not implemented, on purpose** |

## Reply structures (packed; multi-byte fields big-endian)

**Capabilities (72 bytes):** ChipID u8 @0, DevicePort u8 @1, VendorID u16 @2 (0x1B21 ASMedia),
DeviceID u16 @4 (0x1092: the ASM1092R RAID port multiplier), FirmwareVersion u64 @8 (shown as the first 12 hex digits),
SerialNumber u64 @16, CurrentImage @28, DualImage @29, BIST @30, Cascade @31,
CurrentMode @36, SWModeChange @37, ModeSupported u16 @38, FunctionSupported @40,
TemperatureReport @44, FanSpeedReport @45, FanSpeedControl @46,
RaidSetName[15] @49, UniqueID[8] @64 (the app shows it as a little-endian u64 in `%016llx`).

**RAID status (164 bytes):** (on the test unit only the first 20 bytes were filled in for a
RAID 0 volume; the rest was left over from earlier replies) Mode @0, Disks @1, Volumes @2, VHDD_Reason @3, then
4 × Volume (40 bytes): Status @0, Mode @1, StripeSize @2, BytesPerBlock u16 @6,
TotalBlocks u64 @8, StartLBA @16, EndLBA @24, TagLBA @32 (rebuild position in the generic
ASMedia layout; this firmware never fills it. The position is read from controller memory with
GetRegister instead, confirmed on hardware 2026-11-08, see FIRMWARE.md "Rebuild").

**Disk status (384 bytes):** Mode @0, Ports @1, Disks @2, then 5 × Port (76 bytes):
Status @0, Order @1, ModelNumber[40] @4 and SerialNumber[20] @44 (ATA strings, so each
16-bit word is byte-swapped), DiskType @64, BytesPerBlock u16 @66, TotalBlocks u64 @68.

## ModeChange payload (128 bytes, as built by `-[AppDelegate ModeChange_thread]`)

| Offset | Value |
|--------|-------|
| 0x00 | 0 |
| 0x01 | number of disks (`DiskStatus.Disks` in RAID mode; the app's own count of individual disks otherwise) |
| 0x02 | 1 |
| 0x08 | target mode (0 Individual, 1 RAID 0, 2 RAID 1) |
| 0x09, 0x0A | 0x80, 0x80 |
| 0x0C–0x13 | 0x00 |
| 0x14–0x1B | 0xFF |
| 0x1C–0x20 | 00 01 02 05 05 |
| 0x5C–0x6A | RAID set name (15 bytes, zero-padded) |

The app offers only modes 0, 1 and 2 on this 2-bay model. For RAID 0 and RAID 1 it
requires both disks to be Online, Rebuilding or Blank.

On macOS 13 and later (confirmed on macOS 27), opening `/dev/rdiskN` fails with EPERM,
even as root, unless the process that started it has **Full Disk Access**.

## Code tables

Mode: 0 Individual Disk, 1 RAID 0, 2 RAID 1, 3 SPAN, 4 SideWinder, 5 Split Volumes, 0xF VHDD.

Volume status: 0 Online, 1 Degraded, 2 Rebuilding, 3 Rebuild Failed, 4 Data Lost,
5 Migrating, 6 Verifying, 7 Verify Failed, 8 Rebuilding Paused, 9 Verifying Paused,
0x10 Not Configured, 0x11 Broken.

Disk status: 0 Online, 1 Rebuilding, 2 Empty, 3 Missing, 4 Blank, 5 ID Mismatch,
6 Rejected, 7 Predictive Failure, 8 Failed, 9 Spare, 0xA Not Participating,
0xB Verifying, 0xC Migrating, 0x11 Rebuilding Paused, 0x1B Verifying Paused.

VHDD reason: 0 No ATA disk connected, 0x10 RAID 0 Offline, 0x11 Normal crashed,
0x12 RAID 1 disk mismatched, 0x13 RAID 1 missing, 0x14 SideWinder disk mismatched,
0x15 Rejected, 0x20 RAID type mismatched, 0x30 Force VHDD.

## Flash layout (from the original updater, `WriteFirmwareFile`)

The image is 0xF000 bytes (0x1F000 on dual-image units). Before writing, the updater reads the
first 128 bytes at address 0 (the "CFG table", unit-specific) and writes them back over the
start of the new image, so a firmware file never replaces a unit's own configuration. Erase
works in 4 KB sectors; reads and writes in 128-byte blocks, 3 tries each, 2 s ack timeout.
