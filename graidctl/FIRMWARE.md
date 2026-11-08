# Controller firmware notes

> **2026-11-08 update (deeper RE pass).** The big new tool: a small 8051 emulator
> (`firmware/scratch/emu8051.py`) that runs firmware functions against controlled XDATA, plus a
> fragment inliner (`scratch/inline.py`). Every Q1–Q8 answer below was checked by executing the
> actual code, and the capacity formula reproduces the real unit's captured reply exactly.
>
> **What should change in the app:**
> 1. **Show exact capacity estimates before a mode change** (Q1, confirmed): RAID 0 =
>    `2 × (smaller disk − 32 MiB)`, rounded down to a 32 MiB boundary; RAID 1 =
>    `smaller disk − 32 MiB`, rounded down to 32 MiB; SPAN = `Σ(disk_i − 32 MiB)` exactly, with
>    **no** alignment mask (see "SPAN details"). With mismatched disks RAID 0/RAID 1 silently
>    use the **smaller** disk — safe, but the app should say so. (All in 512-B blocks: reserve
>    0x10000/disk, SPAN 0x10000 per member, RAID 0/1 mask ~0xFFFF.)
> 2. **Rebuild guidance** (Q3): the old Configurator's Rebuild button is just a ModeChange with
>    mode 2 and a member order that names the **source disk first** — the destination is
>    rewritten. The app can offer "rebuild from bay 1 → bay 2" with that exact packet shape, and
>    must warn that everything on the destination is destroyed. (Firmware detail, confirmed: the
>    rebuild bit at payload[0x0A]=0x81 makes the create skip member re-init, so the **source** member's data is preserved; see Rebuild.)
> 3. **Rebuild progress isn't in the RAID-status reply** (Q3): this firmware never fills TagLBA,
>    so `PROTOCOL.md`'s "progress = TagLBA/TotalBlocks" doesn't hold. *Second review:* the
>    position does live in controller memory (X:0x04AC–0x04BB) and the read-only GetRegister
>    command can read it, so a progress bar is probably possible; see Rebuild.
> 4. **The Unique ID is stable** (Q2): a mode change does **not** regenerate it. It is generated
>    once (from hardware register 0xF570) when the enclosure's flash config is first built and is
>    copied through every later rewrite. The app may use it as a persistent unit identity.
> 5. **Drive health** (Q5): SMART READ DATA is passed through to one physical drive (bay 1, per
>    the second review); there is no host command that returns per-drive SMART or an error log.
>
> **2026-11-08 second review (decompilation).** Corrections, details in each section:
> rebuilds **do** start on their own when a drive is inserted into a degraded RAID 1, including a
> drive that isn't a member (ID Mismatch), so the app should warn before you insert one; the
> volume-status mapping was wrong (0x054F = Rebuilding *Paused*; "Rebuilding" is the default
> when the array isn't in sync); there is no "copy engine" (0xF8C0/F8C1 are a timer, and the
> 0xCA0B–0xD053 code is part of Get Disk Status); X:0x0540/0544 is the LBA of the disk command
> being translated, not a rebuild checkpoint (the real position is at X:0x04AC–0x04BB and can be
> read with GetRegister); X:0x0A72:73 is the self-reset delay after a mode change, not a standby
> timer; the controller reports no temperature (bytes 44–46 hard-coded to 0xFF); SMART and
> IDENTIFY are forwarded to bay 1.
> Re-checked against the code and found correct: the opcode table and handlers, the mode-to-level
> mapping and payload byte 0x0A, the rebuild flag's skip of 0x834D, the RAID 0 capacity against the
> captured reply, the Unique ID source and copy loop, the flash signature and ALIGN flag, the CFG
> table, 0x21's 3-byte reply, 0xC1's constant, and the old app's Rebuild payload. **Not
> re-checked** (taken from the emulator pass as written): the SPAN formula and creation loop, the
> RAID 1 40-bit gate, the on-disk-metadata conclusion, and the SMART sub-command table.
>
> **2026-11-08 Ghidra cross-check pass.** The whole firmware was re-analysed with REA driving
> Ghidra 12.1.4 (language `8051:BE:16:default`, base 0, our symbol file pre-applied as seeds):
> 1067/1067 functions decompiled into `firmware/scratch/rea_decomp/` (one `.c` per function +
> `index.md`). Every Q1–Q8 answer below was re-checked against that decompilation; it also
> produced four corrections, folded in below: the rebuild payload table's 0x0C–0x1B row, what a
> rebuild actually does differently (it is **not** just a re-create — see Rebuild), the SPAN
> per-member rounding (now confirmed numerically, no alignment mask), and the origin of the
> RAID 1 40-bit gate bit (see Capacity).

From a read-only dump of the user's G-RAID with Thunderbolt (ASMedia ASM1092R, firmware
140827300211), taken 2026-11-08 with `graidctl firmware-dump`. Image and tools are in
`graid/firmware/` (`tools/dis8051.py` disassembler, `tools/cases.py` switch-table lister,
`fw.asm` output, `tools/symbols.txt` names; analysis helpers in `firmware/scratch/`, including
`emu8051.py`, a small 8051 emulator used to execute single firmware functions offline).
Addresses below are 8051 code addresses (file offset − 0xB0) unless they are XDATA (`X:`).

Confidence: **confirmed** = read directly from the code (many results this pass were verified by
emulating the code against the captured disk sizes); **likely** = consistent reading of the
code, not traced end to end; **unknown** = not determined.

## Image layout (confirmed)

| File offset | Contents |
|---|---|
| 0x0000–0x007F | Unit configuration ("CFG table"): IDs 1B21:2109, ATA model "ASMT109x", placeholder serial "0123456789". The original updater preserves this block |
| 0x0080 | "ASMT" header, firmware version 14 08 27 30 02 11 at 0x009C |
| 0x00B0 | 8051 code, address 0: reset `LJMP 0x064C`, INT0 → 0x3031, INT1 → 0x1D15 |
| … ~0xF000 | Code and init data (Keil C51; strings such as the ack signatures live in the init-data table and are copied to XDATA) |
| 0xF000– | Erased (0xFF) in the dump. **The live unit keeps its RAID configuration in the SPI flash at this address** (see "Flash config block" below), so the dump cannot contain it |

Keil runtime helpers: 0x0329 unsigned-long compare, 0x033A long shift right, 0x034D long shift
left, 0x0360 store long to XDATA, 0x036C store inline constant long, 0x039D `switch` (case table
follows the call), 0x0F97 load long from XDATA, 0x00E6 block copy. Per-port state is an array of
0xC2-byte structs at X:0x0000. The compiler split several functions into many small
register-shuffle fragments that call each other; `scratch/inline.py` linearizes them.

## Flash config block (confirmed)

The unit's persistent RAID configuration is a 0x200-byte block in the SPI flash at **0xF000**
(0x1F000 on dual-image units; selector `[0x0FFE]`, helper 0x5F3D). It is read into XDATA
**0x3DE8–0x3FE7** (0x5675), parsed/applied by 0x34F0+ and 0xAD27+, and rewritten by ModeChange
and RAID_CREATE (write step 0x5A74, registers 0xF780–0xF79B). Known fields:

| Image offset | Meaning |
|---|---|
| +0x00–0x09 | Array state header — **zeroed by every mode change** (loop 0xD7EF–0xD810) |
| +0x0A, +0x0B | Validity signature `0x10 0x06` (checked at 0xAD4E–0xAD56) |
| +0x21–0x28 | **Unique ID** (8 bytes), live copy at X:0x0A85 |
| +0x96… | Per-port records (checked around 0x3520–0x3535) |
| +0xD5 bit 4 | **ALIGN_FLAG** → runtime X:0x049B (applied at 0x353D–0x3542). This unit: clear |
| name, level, member list | parsed into X:0x0A8D etc. by 0xAD27 (TLV walk) |

## Host command dispatcher (confirmed)

The received packet is at X:0x4E60 (control X:0x4E68, opcode X:0x4E6C, parameters
X:0x4E6D–6F, 128-byte data block X:0x4E70). Replies are built at X:0x4E70. The switch at 0xD56C
accepts exactly these opcodes:

| Opcode | Handler | Meaning | Notes |
|---|---|---|---|
| 0x10 | 0xD6A1 | Identify | used |
| 0x11 | 0xDA14 | Get Capabilities | used |
| 0x15 | 0xDBD2 | Get RAID Status | used |
| 0x17 | 0xDDAD | Get Disk Status | used |
| 0x20 / 0x23 / 0x25 | 0xD5A6 | Flash read / erase 4 KB / write | read used by `firmware-dump`; erase and write never implemented |
| 0x21 | 0xE025 | Read 3 bytes from X:0x07BF | **confirmed read-only**; X:0x07BF holds the SPI-flash ID triple (emulation: reply = the 3 bytes verbatim). Unused by any tool |
| 0x50 | 0xD6B4 | Get register (read one XDATA byte) | |
| 0x51 | 0xD6B4 | **Set register: writes any XDATA byte** | never implement |
| 0x60 | 0xD8D7 | Start a per-port operation | consumes cmd params, writes X:0x0A76–0x0A7C (52 writes in emulation). State-changing; don't send |
| 0x61 | 0xD950 | Poll results of 0x60 | reply = per-port bytes, 0xFF = no result yet (emulation). Read-only but meaningless without 0x60 |
| 0xA0 | 0xD8BB | Set deferred-action value | sets flag X:0x0A6F and calls 0xD434, which stores cmd P2:P3 as a 16-bit value at X:0x0A72:73 **clamped to 100**. State-changing; don't send |
| 0xB0 | 0xD739 | Mode change | used |
| 0xC1 | 0xD8A2 | Per-port op with wait | cmd param 1 = **port mask** (bit walk at 0xD33A); sets X:0x0A71=1 (busy), X:0x0A72:73 = 60, then spins at 0xE127–0xE130 until the background op clears 0x0A71. The constant 60 goes to XDATA, **not** into the reply (corrects the earlier note). State-changing; don't send |
| 0xF0 | 0xD72E | Reset | |
| 0xF9 | 0xD8C6 | Set flag X:0x0B5F, ack | state-changing; don't send |

The original Configurator used only 0x10, 0x11, 0x15, 0x17, 0x20, 0x23, 0x25, 0x50, 0xB0 and
0xF0. X:0x0A72:73 (the 16-bit value A0/C1 write, max 100, C1's default 60; ModeChange also
sets it through 0xD434 at 0xD896) is the **delay before the controller resets itself**, not a
standby timer (corrected): the background task (0x6BD0 / 0xB6B3) calls 0xBFDF, which loads it
into the hardware timer and waits (0x1F84 polls X:0xF8F0 bit 0), and then sets the reset bits in
X:0xF92D / X:0xF91E (0x0FAD) and spins. X:0x0A70 = 1 (set after a mode change and by Reset) is
the "reset pending" flag. This is why the unit re-enumerates after a mode change. 0x60 programs
the per-port SATA PHY blocks (X:0xEA42/0xEC42/0xEE42, link-speed choice in X:0x0A78) and looks
like a factory link test; 0xF9 sets X:0x0B5F, which turns off a fallback in the ATA and SMART
dispatchers (0xBCE0 / 0xB9C5), meaning still unknown. None of these are useful to the app.

## RAID levels and SPAN (confirmed)

The mode-change handler reads the mode from payload byte 8 (X:0x4E78) and maps it to an
internal level passed to the array-creation routine 0xA84E:

| Mode sent | Internal level (X:0x04F0) | Reported back by Get RAID Status |
|---|---|---|
| 0 Individual | 0xFD | 0 |
| 1 RAID 0 | 0x00 | 1 |
| 2 RAID 1 | 0x01 | 2 |
| **3 SPAN** | **0x06** | **3** |
| 4 or more | ignored | — |

Get RAID Status also maps internal level 4 to reported mode 4 and any other level to mode 5.
The old Configurator's mode names (`modeText`) call these "SideWinder" and "Split Volumes";
the mode-change handler can't create either, so they're leftovers of the wider ASMedia
firmware family.

**SPAN is fully implemented** (creation loop 0xAC07, size path 0xA651, hot-plug paths treat
level 0 and 6 together). G-Technology simply never offered it. Untested on hardware.

## Capacity (confirmed — reproduces the real unit's reply exactly)

Inputs: each port struct keeps the disk's block count as **port+5..+8 = low dword (big-endian)
and port+9..+0xC = high dword** — this is what Get Disk Status serialises into the reply's
TotalBlocks (verified by marker emulation of 0xDDAD). The size computation is
`COMPUTE_ARRAY_SIZE` at **0x9FBE**: level in R7, generic pointer to the member port-index list
(X:0x0A28) in R3:R2:R1. Callers: 0x4944 (RAID 1), 0x4A67 (RAID 0), 0x4AC4/0xAC44 (SPAN).

On this unit ALIGN_FLAG (X:0x049B, loaded from flash config image+0xD5 bit 4) is **clear**,
which selects:

- **RAID 0** (path 0xA338): member = `min(raw_i) − 0x10000` (32 MiB reserve per disk,
  subtracted at 0xA49E–0xA4A9); total = `2 × member`; the low dword of the total is masked with
  `0xFFFF0000` (32 MiB granularity), carries propagate into the high dword.
- **RAID 1** (path 0x9FF2): total = `(min(raw_i) − 0x10000) & 0xFFFF0000`. Requires bit 2 of
  X:0x06A4 set (40-bit size support); with the bit clear the high dword is dropped and a >2 TiB
  volume would report a truncated size (emulated: 0xD1BF0000 instead of 0x1D1BF0000). Ghidra
  pass: **bit 2's origin is confirmed** — the per-port enumeration routine 0x483B sets
  X:0x06A4 = 0x74 (bit 2 set) at 0x4911, then walks the members and **clears bit 2 at 0x492C if
  any drive fails the probe at 0x7746** (`X:0x04F0 == 1` → fail). The same routine clamps a
  per-member exponent to 7/15/31 (X:0x069B — classic LBA-width selection) and refreshes
  X:0x049B via 0x4FF0, i.e. 0x483B is the capability-flag enumeration: bit 2 means "every
  attached member passed the probe" (≈ all members 40-bit-LBA capable).
- **SPAN** (path 0xA651): total = `Σ(raw_i − 0x10000)` — a 32 MiB reserve **per member**, **no
  alignment mask** (the odd low bits survive). Numerically confirmed this pass by emulating
  0x9FBE with level 6: members 0x1D1C0BEAF/0x1D1C0BEAF → 0x3A37F7D5E exactly, and
  0x1D1C0B000/0x100000000 → 0x2D1BEB000 exactly (both equal Σ(raw−0x10000)). The sum is
  40-bit: the accumulator is the 5 bytes at X:06AF–06B3, serialized through the per-member
  table at X:0xA7CC+ before `F_STORE_ARRAY_SIZE`. The mask-shaped tail (0xA6E6+, helpers
  0xE3A2/0xE422) only applies under the ALIGN_FLAG=1 / >2³³ clamp conditions and did not fire
  in either emulation.

Mismatched disks: RAID 0 and RAID 1 use the **smaller** disk (a true 40-bit compare — verified
with a 4 TB + 8 TB pair), and RAID 0 sizes to `2 × smaller`, not to the sum. Tiny members
(< reserve) take a mask-only branch and collapse toward zero.

Check against the captured unit (2 × 7,814,037,167 blocks = 0x1D1C0BEAF each):
`2 × (0x1D1C0BEAF − 0x10000) = 0x3A37F7D5E`, masked → **0x3A37F0000 = 15,627,911,168 blocks,
exactly the value in `capturedRaid`**. The 64-bit result is stored as two longs:
X:0x0502 = high dword, X:0x0506 = low dword.

If ALIGN_FLAG were set (other units), the reserve becomes 0x2000 and the mask 0xFFFFE000
(8 MiB granularity) for RAID 0/SPAN; RAID 1 then rounds to 64 MiB (emulated 0x1D1C00000 for a
4 TB member).

## Unique ID (confirmed: a mode change does NOT create a new one)

- The 8 Capabilities-reply bytes 64–71 come from live XDATA **0x0A85–0x0A8C** (copy loop in the
  0x11 handler at 0xDBA9–0xDBCD), which mirrors flash config image+0x21 (0x3E09–0x3E10).
- The ID is generated only when the config block is **built fresh** (routine 0x5DD9, entered
  when the signature check fails): two 32-bit reads of hardware register **0xF570** (0x5E1A and
  0x5E26) are expanded into the 8 bytes (loops 0x5E31–0x5E66) and written into the image and the
  live copy. This looks like a per-chip random/unique source.
- Mode change (both branches of 0xD767: the metadata path 0xD76F and MODE_TO_LEVEL 0xD830) reads
  the existing block, zeroes image[0..9], patches the array fields and writes it back.
  **Emulation with a seeded ID shows both the image and live ID pass through unchanged.**
- So the ID is stable across mode changes (and across rebuilds, which are mode changes). (The
  dump's file name embeds the ID only because our own `graidctl firmware-dump` named it that
  way — it is not independent evidence the ID is unit-specific. The two reads of HW 0xF570 at
  config build are the actual per-chip source.)

## Rebuild (button confirmed; create path and copy-engine kick-off confirmed)

What the old Configurator's Rebuild button sends (`-[AppDelegate Rebuild_thread]`, payload
built at app 0x10000d524–0xd5f1, sent through `_ModeChange` → `_IFCmdModeChange`, 3 retries,
5 s timeout): a **normal ModeChange (opcode 0xB0) with**

| payload byte | value |
|---|---|
| 0x01 | disk count |
| 0x02 | 1 |
| 0x08 | 2 (RAID 1) |
| 0x09 | 0x80 |
| **0x0A** | **0x81** (normal mode change sends 0x80 — the rebuild variant bit; 0xE5F0 computes `payload[0x0A] ^ 0x80`, i.e. 0x80 → flag 0, anything else → flag 1) |
| 0x0C–0x13 | 0x00 (8 bytes) |
| 0x14–0x1B | 0xFF (8 bytes) — *(corrected this pass: the old app's `Rebuild_thread` stores an all-ones xmm after `pslldq $8`, so bytes 0x0C–0x13 are 0x00 and 0x14–0x1B are 0xFF — the same layout a plain mode change sends, not 16×0xFF as previously written)* |
| **0x1C, 0x1D** | **source port, other port** (the copy direction; the radio button picks the source) |
| 0x1E–0x20 | 02 05 05 |
| 0x5C… | current RAID set name |

So there is **no separate rebuild opcode**: rebuild = a ModeChange whose payload[0x0A] carries
the rebuild bit. What the firmware does with it (rewritten 2026-11-08 after a second review of
the decompilation; the Ghidra pass's "copy engine" reading was wrong, see the end of this
section):

- **0xD830 MODE_TO_LEVEL** (confirmed): mode (payload[8], X:0x4E78) 0→0xFD, 1→0, 2→1, 3→6.
  0xE5F0 computes `payload[0x0A] ^ 0x80`, so 0x80 gives flag 0 and anything else flag 1. The
  flag is passed in R3 to **RAID_CREATE 0xA84E**, which stores R7/R5/R3 at X:0x0A22/0A23/0A24
  (0x47E4): X:0x0A22 = disk count, X:0x0A23 = internal level, **X:0x0A24 = rebuild flag**.
  This path is only taken when the current level isn't Individual (0xD767: X:0x0B5D ≠ 0xFD).
- **With the flag set, RAID_CREATE skips 0x834D** (0xA857, confirmed). 0x834D is the loop a
  fresh create runs over member ports whose status is 1 or 5: it clears the internal ATA
  sub-state, issues a per-port probe and records the port's new status. Skipping it means the
  members keep their state and **the source member's data isn't re-initialised** (confirmed).
- 0xACDF (called at 0xAA82/0xAAF9/0xAB70 inside RAID_CREATE) returns X:0x0A24, so the flag also
  short-circuits RAID_CREATE's per-member slot sequence (confirmed that it's read; the exact
  effect is likely as described by the Ghidra pass: slot pinned to 1, straight to the size
  write-out).
- Everything else in RAID_CREATE runs as for a create: member selection, size computation,
  writing sizes into each member's port struct, and the 0x8435 epilogue that rebuilds the flash
  config image. The rebuild itself then runs in the background like an automatic one (below).
- How the copy is driven (which routine issues the reads and writes) is **unknown**.

**App-facing summary:** a rebuild keeps the source member's data, rewrites the flash config like
a create, and the array then rebuilds onto the other member. The destination is rewritten.

Background rebuild (main loop):

- **Starts by itself when a drive is inserted** (likely, strong; matches the G-RAID manual).
  The main loop (0x1E5C–0x1EC0) checks the hot-plug register X:0xF963 for each port and, on an
  insertion (0x1FE1), calls **0x636A**. When the inserted port's status is **1 (Rebuilding) or
  5 (ID Mismatch, a drive that isn't a member)** it sets up the pair (X:0x0629 = 0,
  X:0x0498/0499 = 2) and calls **0x9165**, which clears X:0x04BF ("in sync") and seeds the
  rebuild position at X:0x04AC. No host command is involved. 0x9165 is also reached from
  0xBFF6 (main loop) and its twin 0x916A from 0xADD4. Practical meaning: **any drive inserted
  into a degraded RAID 1, even one that isn't a member, is overwritten without asking.** The
  vendor's Rebuild button is a fallback.
- **Rebuild position** (likely): two 64-bit big-endian values in XDATA. 0x8BA9 compares
  X:0x04B0/0x04B8 and X:0x04AC/0x04B4 pairwise with C_ULCMP; when the position reaches the
  end it sets X:0x04BF = 1 (back in sync) and rewrites the flash config (0x8435) for each
  member. 0x9249 copies the position into each member's port struct before 0x8435 saves it,
  which is how an interrupted rebuild resumes from where it stopped. Exact field split
  (which bytes are "current" and which "end") needs one read during a real rebuild.
- **TagLBA is never written** by Get RAID Status (confirmed: no reference to the position
  variables in 0xDBD2–0xDDAC), so the reply can't give progress. **But GetRegister (opcode
  0x50, read-only, used by the old app) reads any XDATA byte** (0xD6B4: address from the
  parameters, opcode 0x50 reads, only 0x51 writes), so the app can read X:0x04AC–0x04BB
  directly and compute a percentage. Not yet tried; needs a real RAID 1 rebuild to confirm
  the fields.

Volume status (Get RAID Status reply+4, built at 0xDC3D–0xDCF0, confirmed from the code):

- Base value: X:0x04BF == 1 (in sync) → **0 Online**, or **1 Degraded** if X:0x0629 == 2.
  Otherwise X:0x054F == 1 → **8 Rebuilding Paused**; else X:0x054E == 1 → **3 Rebuild Failed**;
  else **2 Rebuilding**. "Rebuilding" is simply "not in sync and not paused or failed".
- Then one-byte flags override it, last one wins: 0xE744() == 0x20/0x12 → 0x10 Not Configured,
  X:0x0551 → 0x11 Broken, X:0x054D → 1 Degraded, X:0x0552 → 5 Migrating, X:0x0550 → 4 Data
  Lost, X:0x0553 → 6 Verifying, X:0x0554 → 7 Verify Failed, X:0x0555 → 9 Verifying Paused.
  The app's status texts already match these numbers.

What the Ghidra pass got wrong here (kept for the record):

- "0x260C programs the hardware RAID copy engine (X:0xF8C0 = 7, X:0xF8C1 = 0xD0)": those are
  the reload registers of the timer block. 0x261E stops the timer through 0x1633 (clears X:0xF8E0
  bit 0 and the X:0xF8F0 expiry flag, the registers the delay loop 0x1F84 waits on) and loads
  0x07D0, a 2000-tick timer. 0x44F8's argument is a port number in the overlaid X:0x0A24 slot
  (1 → X:0xEC98, 0 → X:0xEA98), and 0x429B runs from the main loop, not from RAID_CREATE.
- "0xCA0B–0xD053 is the copy/verify engine and 0xE9C4 selects source→destination": 0xCDFC is
  called only from 0xE01A inside the **Get Disk Status** handler (0xDDAD–0xE024), and 0xE9C4
  (called only at 0xCE6B/0xCE7E in that code) is the reply loop's port index × 0xC2.
- "X:0x0544 is the rebuild checkpoint and X:0x0540 its target": 0x4C6F–0x4D21 assembles
  X:0x0540:0544 from the ATA register bytes X:0x0B3B–0x0B41, and 0x76E1 writes it back as an
  ATA LBA (X:0x0B24 = 0xE0 | LBA bits 27–24). It's the 64-bit LBA of the disk command being
  translated, not a rebuild position.
- The status mapping (054F alone = Rebuilding) and "probably no automatic rebuild".

## Temperature and fans (confirmed: not reported)

The Capabilities handler (0xDA14) hard-codes reply bytes 44–46 (TemperatureReport,
FanSpeedReport, FanSpeedControl) to 0xFF, matching the captured reply. The controller has no
temperature or fan reporting, so a temperature probe is pointless.

## Drive health and SMART (confirmed structure)

ATA SMART (0xB0) from the host lands at 0xB9C5: the feature register (X:0x0B44) selects one of
12 handlers through the LJMP table at 0xB9DA:

- READ DATA (0xD0), READ ATTRIBUTE THRESHOLDS (0xD1), READ LOG (0xD5) → 0xBA52: the command is
  **issued to a physical drive** through the internal ATA descriptor (0x87EC → 0x7F95) and the
  512-byte reply is passed back — the controller does not synthesise SMART data.
- EXECUTE OFFLINE (0xD4), ENABLE/DISABLE (0xD8/0xD9), RETURN STATUS (0xDA) → 0xB9FB: a locally
  built response.
- WRITE LOG (0xD6) → 0xBA68: forwarded write; 0xD3/0xD7 → 0xBCE3 (rejected).

A single command reaches **one** drive: **bay 1** (likely). 0x87EC, which IDENTIFY (0xB83C), READ LOG EXT (0xBB25) and the second ATA switch use to forward a command, clears X:0x09BA, the internal descriptor's port, to 0 at 0x87F6–0x87FF before issuing it through 0x7F95. Changing that would need writing controller memory (0x51), which is off-limits; there is **no host command that
returns per-drive SMART data or an error log**. A health UI can only ever show one drive's view.

## Spin-down (partly confirmed)

- Host STANDBY IMMEDIATE (0xE0 → 0xBC3B) and IDLE with timer (0xE3 → 0xBCD6 → 0x32B0/0x326E)
  are translated into per-drive power commands through the internal descriptor at X:0x09BA
  (the debug strings `SendSpindown:`, `SendP0_Start`… at code 0x6DA+ belong to this family).
- **Corrected:** X:0x0A72:73 is not a standby timer. It is the delay before a self-reset (see
  the command table). No host command sets a drive standby timeout, and no controller-side
  inactivity timer was found, so drive sleep stays the Mac's job (Phase 2.5).

## On-disk metadata (mostly unknown; flash confirmed)

Everything confirmed so far lives in the **SPI flash** config block (see above): level, member
list, unique ID, name, ALIGN flag. In the emulated creation path no write to either member disk
was issued — the disks appear to carry plain data only, and `Id Mismatch` (port status 5) comes
from flash per-port records (0x3520–0x3535), not from on-disk signatures. What the RAID_CREATE
prelude puts at port struct +0x11 (via 0x9FAE/0x34D5) is the best lead for a per-slot marker;
whether anything is ever written to a member disk's LBA 0 is **unknown**. For data recovery:
treat the member disks as bare data (RAID 0 stripes / SPAN concatenation per the flash config)
and the enclosure's flash as the source of truth for geometry.

## SPAN details (member-0 rewrite confirmed; total confirmed numerically)

Creation (loop 0xAC07–0xAC37) walks the members in **member-list order** (the order the host
listed the disks — for the old app, payload bytes 0x1C/0x1D). A per-member size is **written
into each member's port struct +5..+8** (`C_LSTXDATA` at 0xAC31; per-member values staged from
X:0x0A2C through 0x36F8/0xADBC), and the total comes from the size path 0xA651: a 5-byte
(40-bit) accumulator at **X:06AF–06B3** sums the members, the result is serialized through the
per-member table at **X:0xA7CC+** and stored by 0xA83F/`F_STORE_ARRAY_SIZE` into
X:0x0502:0x0506. **Confirmed numerically this pass** (emulating 0x9FBE with level 6 and
synthetic members): the total is `Σ(raw_i − 0x10000)` — a 32 MiB reserve per member, **no
alignment mask** (0x1D1C0BEAF×2 → 0x3A37F7D5E; 0x1D1C0B000+0x100000000 → 0x2D1BEB000; both
exact). The earlier reading of a 32 MiB-aligned per-member value came from the port-struct
rewrite inside the create loop, not from the size formula. Nothing in the SPAN path compares
member sizes, so disks of different sizes work; only the sum matters. The mask-shaped tail at
0xA6E6+ (helpers 0xE3A2/0xE422, constants via 0x4E84/0x4E85) applies only under the
ALIGN_FLAG=1 / >2³³ clamp conditions and did not fire for either emulated case.

## Not determined

- How the rebuild copy itself is driven (not the timer at 0x260C; see Rebuild).
- What 0xF9's flag X:0x0B5F switches off.
- Whether any on-disk metadata exists (see above).
