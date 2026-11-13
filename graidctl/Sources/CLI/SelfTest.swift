// graidctl selftest: checks of the protocol code and the logic built on it. No hardware needed.
// Lives with the CLI so the app binary does not carry it.

import Foundation

func selfTest() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); ok = ok && cond }

    check("crc32 check value", crc32(Array("123456789".utf8)) == 0xCBF4_3926)

    let id = Command.identify
    check("identify packet length", id.lbas.count == 16)
    check("identify header/control/command", Array(id.lbas.prefix(12)) ==
          [0x43, 0x71, 0xA7, 0xDF, 0x100, 0x104, 0x1EF, 0x1FF, 0x210, 0x2CF, 0x2DF, 0x2EF])
    check("identify crc tag", id.lbas.suffix(4).allSatisfy { $0 & 0xF00 == 0x400 })
    check("identify crc matches zlib over 16 bytes", id.crcInput.count == 16)

    let mc = Command.modeChange(payload: [UInt8](repeating: 0, count: 128))
    check("mode change packet length", mc.lbas.count == 144)
    check("mode change crc covers 0x90 bytes", mc.crcInput.count == 0x90)
    // Control "00 00" (0x100,0x100) repeats once, and 128 zero data bytes (0x300) repeat 127 times.
    let seq = mc.wireSequence
    check("separator inserted for repeated sectors", seq.filter { $0 == separatorLBA }.count == 128)

    // Parse a synthetic ack sector.
    var sec = [UInt8](repeating: 0, count: 512)
    sec.replaceSubrange(0..<16, with: Array("__ASMEDIA2109A__".utf8))
    sec.replaceSubrange(0x1F0..<0x200, with: Array("_PORTMULTIPLIER_".utf8))
    sec[0x30] = 0x20
    var caps = [UInt8](repeating: 0, count: 0x48)
    caps.replaceSubrange(8..<16, with: [0, 0, 0x16, 0x05, 0x24, 0x00, 0x01, 0x02])
    caps[36] = 2
    caps.replaceSubrange(49..<55, with: Array("G-RAID".utf8))
    let c = Capabilities(raw: caps)
    check("firmware string", c.firmware == "160524000102")
    check("mode decode", modeText(c.currentMode) == "Protected - RAID 1")
    check("set name decode", c.raidSetName == "G-RAID")
    check("ack status normalization", normalizeAck(0x33) == 0xF4 && normalizeAck(0x20) == 0x20)

    var port = [UInt8](repeating: 0, count: 76)
    port.replaceSubrange(4..<12, with: Array("GHTS0100".utf8)) // "HGST1000" byte-swapped per word
    port.replaceSubrange(66..<68, with: [0x02, 0x00])          // 512
    port.replaceSubrange(68..<76, with: [0, 0, 0, 0, 0x74, 0x70, 0x6D, 0xB0]) // 1953525168 blocks
    let p = Port(index: 0, raw: port)
    check("ATA string swap", p.model == "HGST1000")
    check("disk capacity", abs(p.capacityBytes - 1_000_204_886_016) < 1)

    // Firmware keeps the first 12 hex digits, like the original app.
    var caps2 = [UInt8](repeating: 0, count: 0x48)
    caps2.replaceSubrange(8..<16, with: [0x12, 0x34, 0x27, 0x30, 0x02, 0x11, 0x00, 0x00])
    check("firmware keeps leading digits", Capabilities(raw: caps2).firmware == "123427300211")

    // Seen on real hardware: 2 disks, an Empty slot, then zero-filled slots reading as "Online".
    var ds = [UInt8](repeating: 0, count: 0x180)
    ds[1] = 5; ds[2] = 2
    ds.replaceSubrange(4..<80, with: port)
    ds.replaceSubrange(80..<156, with: port)
    ds[4 + 2 * 76] = 2
    let st = DiskStatus(raw: ds)
    check("zero-filled slots are not disks", st.presentPorts.map(\.index) == [0, 1])
    check("spin state: spinning", describeSpinState([0.011, 0.009, 0.027]).hasPrefix("The drives are spinning"))
    check("spin state: RAID 0 drives wake one at a time", describeSpinState([13.6, 14.6, 0.027]).contains("woke one at a time (13.6 s and 14.6 s)"))

    // --- Simulated controller: the real protocol code against a controller model ---
    let sim = ControllerSimulator()
    sim.staleReads = 3   // the first reads after each command return the previous reply
    let sdev = Device(simulator: sim)
    let idOK = (try? sdev.execute(.identify))?.status == 0x00
    check("simulator: identify", idOK)
    if let (c3, r3, d3) = try? fetchAll(sdev) {
        check("simulator: stale replies rejected, firmware from captured caps", c3.firmware == "140827300211")
        check("simulator: model registry picks TB2", DeviceModel.identify(c3) == .graidTB2)
        check("simulator: ASMedia vendor ID", c3.vendorID == 0x1B21)
        check("simulator: RAID 0 volume size", Double(r3.volume(0).bytesPerBlock) * Double(r3.volume(0).totalBlocks) == 8_001_490_518_016)
        check("simulator: two HGST disks", d3.presentPorts.map(\.model) == ["HGST HUS724040ALE640", "HGST HUS724040ALE640"])
        let payload = modeChangePayload(mode: .raid1, name: "MIRROR", disks: d3)
        let outcome = try? performModeChange(dev: sdev, bsdNames: [], payload: payload)
        check("simulator: mode change accepted", outcome == .accepted)
        check("device: remembers the last command fully sent", sdev.sentOpcode == 0xB0)
        check("guard: known firmware, same enclosure is allowed", controllerProblem(caps: c3, expectedID: c3.uniqueID) == nil)
        check("guard: a different enclosure on the same disk is refused", controllerProblem(caps: c3, expectedID: "1122334455667788") != nil)
        if let (c4, r4, _) = try? fetchAll(sdev) {
            check("simulator: now RAID 1 named MIRROR", c4.currentMode == 2 && c4.raidSetName == "MIRROR")
            check("simulator: RAID 1 size follows the firmware formula", r4.volume(0).totalBlocks == 7_813_922_816)
        } else { check("simulator: read after mode change", false) }
    } else {
        check("simulator: fetchAll", false)
    }
    var tb3caps = ControllerSimulator.capturedCaps
    tb3caps.replaceSubrange(8..<10, with: [0x16, 0x05])
    check("model registry picks TB3 for firmware 16…", DeviceModel.identify(Capabilities(raw: tb3caps)) == .graidTB3)
    tb3caps.replaceSubrange(8..<10, with: [0x99, 0x00])
    check("unknown firmware is status-only", !DeviceModel.identify(Capabilities(raw: tb3caps)).canChangeMode)
    check("guard: unknown firmware is refused", controllerProblem(caps: Capabilities(raw: tb3caps)) != nil)

    // --- Event diff ---
    func diskStatus(_ ports: [UInt8]) -> DiskStatus {
        var d = ControllerSimulator.capturedDisks
        for (i, s) in ports.enumerated() { d[4 + i * 76] = s }
        return DiskStatus(raw: d)
    }
    func snap(mode: UInt8 = 2, vol: UInt8 = 0, ports: [UInt8] = [0, 0]) -> UnitSnapshot {
        var c = ControllerSimulator.capturedCaps; c[36] = mode
        var r = ControllerSimulator.capturedRaid; r[4] = vol
        var d = ControllerSimulator.capturedDisks
        for (i, s) in ports.enumerated() { d[4 + i * 76] = s }
        return UnitSnapshot(id: "u", name: "G-RAID", caps: Capabilities(raw: c), raid: RaidStatus(raw: r), disks: DiskStatus(raw: d))
    }
    let base = ["u": snap()]
    check("diff: no change, no events", diffSnapshots(old: base, new: base, confirmedGone: []).isEmpty)
    check("diff: connect", diffSnapshots(old: [:], new: base, confirmedGone: []).first?.category == .connection)
    let degraded = diffSnapshots(old: base, new: ["u": snap(vol: 1, ports: [0, 3])], confirmedGone: [])
    check("diff: degraded array is critical", degraded.contains { $0.category == .array && $0.severity == .critical })
    check("diff: missing disk is critical", degraded.contains { $0.title == "Disk 2 missing" && $0.severity == .critical })
    let predictive = diffSnapshots(old: base, new: ["u": snap(ports: [7, 0])], confirmedGone: [])
    check("diff: predictive failure", predictive.first?.title == "Disk 1 predicts failure")
    let done = diffSnapshots(old: ["u": snap(vol: 2)], new: base, confirmedGone: [])
    check("diff: rebuild finished", done.first?.title == "Rebuild finished")
    let tb4 = 4.0e12, tb2 = 2.0e12
    let hgst: UInt64 = 7_814_037_167, tb8: UInt64 = 15_628_053_168, tb2b: UInt64 = 3_907_029_168
    check("capacity: RAID 0 matches the real unit", arrayBlocks(.raid0, members: [hgst, hgst]) == 15_627_911_168)
    check("capacity: RAID 1 is one disk less the reserve, rounded", arrayBlocks(.raid1, members: [hgst, hgst]) == 7_813_922_816)
    check("capacity: mismatched RAID 0 uses 2x the smaller disk", arrayBlocks(.raid0, members: [hgst, tb8]) == 15_627_911_168)
    check("capacity: mismatched RAID 1 is the smaller disk", arrayBlocks(.raid1, members: [tb2b, hgst]) == (tb2b - 0x10000) & ~0xFFFF)
    check("capacity: individual keeps everything", arrayBlocks(.individual, members: [hgst, tb2b]) == hgst + tb2b)
    check("capacity: a member smaller than the reserve gives nothing", arrayBlocks(.raid0, members: [hgst, 0x8000]) == 0)
    check("capacity: unused part of the larger disk", modeCapacity(.raid1, members: [tb2b, hgst]).unused == Double((hgst - tb2b) * 512))
    let one = unitNames([(id: "68ca4ea78d27834a", arrayName: "Studio", product: "G-RAID with Thunderbolt")])
    check("names: array name when set", one["68ca4ea78d27834a"] == "Studio")
    let two = unitNames([(id: "68ca4ea78d27834a", arrayName: "G-RAID", product: "G-RAID with Thunderbolt"),
                         (id: "1122334455667788", arrayName: "G-RAID", product: "G-RAID with Thunderbolt")])
    check("names: same names get their ID's last digits", two["68ca4ea78d27834a"] == "G-RAID (834A)" && two["1122334455667788"] == "G-RAID (7788)")
    let clash = unitNames([(id: "69ca4ea78d27834a", arrayName: "G-RAID", product: "P"), (id: "6aca4ea78d17834a", arrayName: "G-RAID", product: "P")])
    check("names: longer suffix when the last digits match", clash["69ca4ea78d27834a"] == "G-RAID (27834A)" && clash["6aca4ea78d17834a"] == "G-RAID (17834A)")
    let ind = unitNames([(id: "68ca4ea78d27834a", arrayName: "", product: "G-RAID with Thunderbolt"),
                         (id: "1122334455667788", arrayName: "Backup", product: "G-RAID with Thunderbolt")])
    check("names: Individual mode uses the product name", ind["68ca4ea78d27834a"] == "G-RAID with Thunderbolt" && ind["1122334455667788"] == "Backup")
    check("replace: a returning drive is being checked", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [6, 0]) == .checking(bay: 0))
    check("replace: a set-aside drive needs a manual rebuild", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [0, 4]) == .needsRebuild(bay: 1))
    check("names: Blank is shown as Not in use", diskStatusDisplay(4) == "Not in use" && diskStatusText(4) == "Blank")
    do {
        var d = ControllerSimulator.capturedDisks
        d[4] = 0; d[4 + 76] = 4          // bay 1 Online, bay 2 Blank
        let ds = DiskStatus(raw: d)
        let active = soleActiveMember(mode: 2, volumeStatus: 1, disks: ds)
        let serials = ds.presentPorts.map(\.serial)
        check("swap: the sole Online member is found", active?.bay == 0 && active?.serial == serials[0])
        check("swap: running on another drive while the old one is set aside", isMemberSwap(previousSerial: serials[1], now: active, disks: ds))
        check("swap: same drive is no swap", !isMemberSwap(previousSerial: serials[0], now: active, disks: ds))
        check("swap: no sole member while both are Online", soleActiveMember(mode: 2, volumeStatus: 0, disks: DiskStatus(raw: ControllerSimulator.capturedDisks)) == nil)
    }
    check("replace: missing copy asks for a drive", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [0, nil]) == .insert(bay: 1))
    check("replace: failed drive must come out first", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [8, 0]) == .remove(bay: 0))
    check("replace: a foreign drive waits for the copy", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [0, 5]) == .waiting(bay: 1))
    check("replace: copying names the receiving bay", computeReplaceStep(mode: 2, volumeStatus: 2, bays: [0, 1]) == .copying(bay: 1))
    check("replace: paused and failed", computeReplaceStep(mode: 2, volumeStatus: 8, bays: [0, 0x11]) == .paused(bay: 1) && computeReplaceStep(mode: 2, volumeStatus: 3, bays: [0, 0]) == .failed(bay: nil))
    check("replace: nothing to do when online", computeReplaceStep(mode: 2, volumeStatus: 0, bays: [0, 0]) == nil)
    check("replace: no guide when no copy survives", computeReplaceStep(mode: 2, volumeStatus: 0x11, bays: [8, nil]) == nil)
    // --- RAM reads (GetRegister) ---
    let gr = Command.getRegister(address: 0x060B)
    check("getRegister packet", gr.control == [0x00, 0x04, 0x00, 0x00] && gr.command == [0x50, 0xCF, 0x06, 0x0B] && gr.replyLength == 1)
    let ramSim = ControllerSimulator()
    let ramDev = Device(simulator: ramSim)
    let ram = try? readRAM(dev: ramDev, addresses: [0x04BF, 0x060B, 0x0629])
    check("readRAM: simulator degraded on port 0", ram?[0x04BF] == 1 && ram?[0x060B] == 0x01 && ram?[0x0629] == 2)
    let sentBefore = ramSim.executedOpcodes.filter { $0 == 0x50 }.count
    let refused: Bool = { do { _ = try readRAM(dev: ramDev, addresses: [0x060B, 0xE000]); return false } catch { return true } }()
    check("readRAM: hardware registers refused before anything is sent", refused && ramSim.executedOpcodes.filter { $0 == 0x50 }.count == sentBefore)
    check("readRAM: watch list is RAM only", raid1WatchFields.allSatisfy { $0.addresses.allSatisfy { $0 < ramLimit } })

    // --- Rebuild position (live bytes from 2026-11-08) ---
    let pos = decodeRebuildPosition([0x02, 0x8f, 0xcb, 0x00, 0, 0, 0, 0, 0xd1, 0xbf, 0x00, 0x00, 0, 0, 0, 0x01])
    check("rebuild position: live bytes decode", pos?.position == 42_978_048 && pos?.end == 7_813_922_816)
    check("rebuild position: fraction", abs((pos?.fraction ?? 0) - 0.0055) < 0.0001)
    check("rebuild position: garbage rejected", decodeRebuildPosition([UInt8](repeating: 0xFF, count: 8) + [0, 0, 0, 1, 0, 0, 0, 0]) == nil)
    let t0 = Date(timeIntervalSince1970: 0)
    let left = rebuildTimeLeft(first: (t0, 0), now: (t0.addingTimeInterval(600), 600 * 270_000), end: 7_813_922_816)
    check("rebuild time left: ~7.9 h at 138 MB/s", left.map { abs($0 / 3600 - 7.87) < 0.05 } ?? false)
    check("rebuild time left: needs a minute of movement", rebuildTimeLeft(first: (t0, 0), now: (t0.addingTimeInterval(30), 1000), end: 2000) == nil)

    let t1 = Date(timeIntervalSince1970: 0)
    let sp = rebuildSpeed(last: (t1, 0), now: (t1.addingTimeInterval(10), 3_183_594), previous: nil)
    check("rebuild speed: 163 MB/s from two readings", sp.map { abs($0 / 1e6 - 163) < 0.5 } ?? false)
    check("rebuild speed: smoothed", rebuildSpeed(last: (t1, 0), now: (t1.addingTimeInterval(10), 0), previous: 150e6) == 150e6)
    check("rebuild speed text", speedText(163.4e6).hasPrefix("163") && speedText(163.4e6).hasSuffix("/s"))

    // --- Manual rebuild ---
    func rebuildSnap(mode: UInt8 = 2, vol: UInt8 = 1, ports: [UInt8]) -> (caps: Capabilities, raid: RaidStatus, disks: DiskStatus) {
        var c = ControllerSimulator.capturedCaps; c[36] = mode
        var r = ControllerSimulator.capturedRaid; r[4] = vol
        let blocks: UInt64 = 7_813_922_816   // RAID 1 of two 4 TB drives
        for i in 0..<8 { r[4 + 8 + i] = UInt8((blocks >> (56 - 8 * UInt64(i))) & 0xFF) }
        var d = ControllerSimulator.capturedDisks
        for (i, st) in ports.enumerated() { d[4 + i * 76] = st }
        return (Capabilities(raw: c), RaidStatus(raw: r), DiskStatus(raw: d))
    }
    func rebuildCheck(_ u: (caps: Capabilities, raid: RaidStatus, disks: DiskStatus), source: Int) -> String? { rebuildProblem(caps: u.caps, raid: u.raid, disks: u.disks, source: source) }
    check("rebuild: Blank bay 1 from Online bay 2 is allowed", rebuildCheck(rebuildSnap(ports: [4, 0]), source: 1) == nil)
    check("rebuild: never from the stale or blank drive", rebuildCheck(rebuildSnap(ports: [4, 0]), source: 0) != nil)
    check("rebuild: refused when the array is Online", rebuildCheck(rebuildSnap(vol: 0, ports: [0, 0]), source: 1) != nil)
    check("rebuild: refused outside RAID 1", rebuildCheck(rebuildSnap(mode: 1, ports: [4, 0]), source: 1) != nil)
    check("rebuild: refused onto a Failed drive", rebuildCheck(rebuildSnap(ports: [8, 0]), source: 1) != nil)
    check("rebuild: refused while a copy is running", rebuildCheck(rebuildSnap(vol: 2, ports: [1, 0]), source: 1) != nil)
    let rp = rebuildPayload(source: 1, name: "G-RAID", disks: rebuildSnap(ports: [4, 0]).disks)
    check("rebuild payload: RAID 1 with the rebuild flag", rp[0x08] == 2 && rp[0x09] == 0x80 && rp[0x0A] == 0x81)
    check("rebuild payload: source bay 2 onto bay 1", rp[0x1C] == 1 && rp[0x1D] == 0 && Array(rp[0x1E...0x20]) == [2, 5, 5])
    check("rebuild payload: rest as a mode change", Array(rp[0x0C..<0x14]) == [UInt8](repeating: 0, count: 8)
          && Array(rp[0x14..<0x1C]) == [UInt8](repeating: 0xFF, count: 8) && String(decoding: rp[0x5C..<0x62], as: UTF8.self) == "G-RAID")
    check("replace: not for RAID 0", computeReplaceStep(mode: 1, volumeStatus: 0x11, bays: [0, nil]) == nil)
    check("replace: minimum size covers the reserve", arrayBlocks(.raid1, members: [replacementMinBlocks(volumeBlocks: 7_813_922_816)]) == 7_813_922_816)
    check("replace: 4 TB mirror takes about 8 hours", abs(rebuildEstimate(volumeBytes: 4.0e12) - 8 * 3600) < 1)
    check("capacity: same-model disks a few sectors apart aren't mismatched", !disksMismatched([4_000_787_030_016, 4_000_785_104_896]))
    check("capacity: 4 TB + 2 TB is mismatched", disksMismatched([tb4, tb2]))

    // Gaps found in the original Configurator (2026-11-08).
    let twoOnline = diskStatus([0, 0])
    check("name: forbidden characters rejected for RAID", modeChangeProblem(mode: .raid1, name: "My,Array", disks: twoOnline) != nil)
    check("name: plain name accepted", modeChangeProblem(mode: .raid0, name: "Studio-01", disks: twoOnline) == nil)
    check("name: ignored for Individual", modeChangeProblem(mode: .individual, name: "a$b", disks: twoOnline) == nil)
    check("spare: accepted for RAID 1", modeChangeProblem(mode: .raid1, name: "G-RAID", disks: diskStatus([0, 9])) == nil)
    check("spare: refused for Individual", modeChangeProblem(mode: .individual, name: "", disks: diskStatus([0, 9])) != nil)
    check("raid1 status: Online with a Missing member reads Degraded", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 3]) == 1)
    check("raid1 status: no surviving member reads Broken", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [3, 3]) == 0x11)
    check("raid1 status: healthy stays Online", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 0]) == 0)
    check("raid1 status: Online with a Failed member reads Degraded", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 8]) == 1)
    check("raid1 status: failing-but-readable copy keeps it Degraded, not Broken", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [7, 8]) == 1)
    check("raid1 status: predictive failure alone stays Online", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [7, 0]) == 0)
    check("raid0 status: untouched", effectiveVolumeStatus(mode: 1, volumeStatus: 0, portStatuses: [0, 3]) == 0)
    let rf = Command.readFlash(address: 0x1F80)
    check("flash read: query class, opcode 0x20, address >> 7", rf.control == [0x00, 0x04, 0xEF, 0xFF] && rf.command == [0x20, 0x00, 0x00, 0x3F])
    let dump = (try? readFlash(dev: sdev, size: 0x400)) ?? []
    check("flash read: simulator returns 1 KB that matches its flash", dump.count == 0x400 && dump == Array(ControllerSimulator.flash.prefix(0x400)))
    check("flash read: no erase or write commands were sent", !sim.executedOpcodes.contains(where: { $0 == 0x23 || $0 == 0x25 }))
    check("wake: simulator answers identify", wakeDisks(primary: sdev, otherPaths: []) == ["simulator"])
    check("partition: EFI is system", classifyPartition(content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", volumeKind: "msdos", apfsRoles: []) == .system)
    check("partition: Microsoft Reserved is system", classifyPartition(content: "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", volumeKind: nil, apfsRoles: []) == .system)
    check("partition: Apple_Boot by name is system", classifyPartition(content: "Apple_Boot", volumeKind: "hfs", apfsRoles: []) == .system)
    check("partition: exFAT data is a volume", classifyPartition(content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", volumeKind: "exfat", apfsRoles: []) == .volume)
    check("partition: APFS Data role is a volume", classifyPartition(content: "41504653-0000-11AA-AA11-00306543ECAC", volumeKind: "apfs", apfsRoles: ["Data"]) == .volume)
    check("partition: APFS Preboot role is system", classifyPartition(content: "41504653-0000-11AA-AA11-00306543ECAC", volumeKind: "apfs", apfsRoles: ["Preboot"]) == .system)
    check("partition: ext4 is unreadable", classifyPartition(content: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", volumeKind: nil, apfsRoles: []) == .unreadable)
    check("partition: format name for Linux swap", formatName(volumeType: nil, volumeKind: nil, content: "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F") == "Linux swap")
    check("partition: format name prefers DA volume type", formatName(volumeType: "MS-DOS (FAT32)", volumeKind: "msdos", content: "") == "MS-DOS (FAT32)")
    check("drive model: vendor word split", splitDriveModel("HGST HUS724040ALE640 ") == ("HGST", "HUS724040ALE640"))
    check("drive model: multi-word rest", splitDriveModel("Samsung SSD 870 EVO 1TB") == ("Samsung", "SSD 870 EVO 1TB"))
    check("drive model: no vendor word", splitDriveModel("ST4000DM004-2CV104") == (nil, "ST4000DM004-2CV104"))
    check("drive model: leading word with digits is not a vendor", splitDriveModel("CT500 MX500SSD1") == (nil, "CT500 MX500SSD1"))
    check("drive size: 4 TB drive", driveSizeText(7_814_037_168 * 512) == "4 TB")
    check("drive size: tenths for comparison", driveSizeText(7_814_037_168 * 512, tenths: true) == "4.0 TB" && driveSizeText(3.94e12, tenths: true) == "3.9 TB")
    check("drive size: 500 GB and 12 TB", driveSizeText(500.1e9) == "500 GB" && driveSizeText(12.0004e12) == "12 TB")
    check("diff: disconnect only when confirmed", diffSnapshots(old: base, new: [:], confirmedGone: []).isEmpty
          && diffSnapshots(old: base, new: [:], confirmedGone: ["u"]).first?.title == "Disconnected")

    // Release check
    let v = { (s: String) in AppVersion(s)! }
    check("version: v-prefix and trailing zeros", v("v2.1") == v("2.1.0") && v("V2") == v("2.0"))
    check("version: numeric, not text, order", v("2.10") > v("2.9") && v("2.0.1") > v("2.0"))
    check("version: suffix ignored, junk rejected", v("2.1-beta") == v("2.1") && AppVersion("latest") == nil && AppVersion("2..1") == nil)
    let releasesJSON = """
    [{"tag_name":"v2.2","name":"G-RAID Utility 2.2","body":"## What's new\\n\\n**Back up first.** Adds [update checks](https://x) and `graidctl rebuild`.","html_url":"https://github.com/a/b/releases/tag/v2.2","prerelease":true,"draft":false,"published_at":"2026-12-01T10:00:00Z","assets":[{"name":"graidctl-2.2-macos.zip","browser_download_url":"https://x/c.zip"},{"name":"G-RAID-Utility-2.2.zip","browser_download_url":"https://x/a.zip"}]},
     {"tag_name":"v2.1","name":null,"body":null,"html_url":"https://github.com/a/b/releases/tag/v2.1","prerelease":false,"draft":false,"published_at":"2026-11-20T10:00:00Z","assets":[]},
     {"tag_name":"v3.0","name":"draft","body":"","html_url":"https://github.com/a/b/releases/tag/v3.0","prerelease":false,"draft":true,"published_at":null,"assets":[]},
     {"tag_name":"nightly","name":"n","body":"","html_url":"https://github.com/a/b/releases/tag/nightly","prerelease":false,"draft":false,"published_at":null,"assets":[]}]
    """
    let rels = (try? decodeReleases(Data(releasesJSON.utf8))) ?? []
    check("releases: decode GitHub's list", rels.count == 4 && rels[0].published != nil && rels[1].notes == nil)
    check("releases: newest full release, drafts skipped", newerRelease(than: v("2.0"), in: rels, includePrereleases: false)?.tag == "v2.1")
    check("releases: pre-releases when asked", newerRelease(than: v("2.0"), in: rels, includePrereleases: true)?.tag == "v2.2")
    check("releases: nothing when up to date", newerRelease(than: v("2.2"), in: rels, includePrereleases: true) == nil)
    check("releases: app zip preferred, else the page", rels[0].downloadURL.absoluteString == "https://x/a.zip"
          && rels[1].downloadURL == rels[1].page)
    check("releases: summary skips headings and strips Markdown",
          releaseSummary(rels[0].notes) == "Back up first. Adds update checks and graidctl rebuild.")
    check("releases: summary cut at a word", releaseSummary(String(repeating: "word ", count: 60), limit: 20) == "word word word word…")

    // Setup
    check("places: one, two, duplicates", placesText(["Downloads"]) == "in Downloads"
          && placesText(["Downloads", "Applications", "Downloads"]) == "in Downloads and Applications")
    check("places: many and none", placesText(["a", "b", "c"]) == "in 3 places" && placesText([]) == "")

    // --- Units missing from a scan ---
    do {
        var misses: [String: Int] = [:]
        let names = ["a": ["disk4"], "b": ["disk5"], "c": ["disk6", "disk7"]]
        let first = resolveMissingUnits(["a", "b", "c"], diskNames: names, ejected: ["disk6", "disk7"], present: ["disk4", "disk6", "disk7"], missCount: &misses)
        check("missing: one failed read with the disk attached is a glitch", first.glitch == ["a"] && misses["a"] == 1)
        check("missing: a unit whose disk is gone is gone at once", first.gone == ["b"] && misses["b"] == nil)
        check("missing: ejected and still attached keeps its state, uncounted", first.ejected == ["c"] && misses["c"] == nil)
        let second = resolveMissingUnits(["a"], diskNames: names, ejected: [], present: ["disk4"], missCount: &misses)
        check("missing: a second failed read in a row is gone", second.gone == ["a"] && second.glitch.isEmpty && misses["a"] == nil)
        let partly = resolveMissingUnits(["c"], diskNames: names, ejected: ["disk6"], present: ["disk6", "disk7"], missCount: &misses)
        check("missing: only one of two disks ejected is not an eject", partly.ejected.isEmpty && partly.glitch == ["c"])
        let unknown = resolveMissingUnits(["z"], diskNames: names, ejected: [], present: ["disk4"], missCount: &misses)
        check("missing: a unit with no known disk is gone", unknown.gone == ["z"])
    }

    // --- Event log file ---
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("graid-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(url: dir.appendingPathComponent("events.jsonl"))
        func event(_ n: Int) -> GRAIDEvent { GRAIDEvent(unitID: "u", unitName: "G-RAID", category: .disk, severity: .info, title: "event \(n)", detail: "a \"quoted\", detail") }
        check("log: empty when there's no file", log.load().isEmpty)
        check("log: the first write creates the file", log.append([event(1), event(2)]) && log.load().map(\.title) == ["event 1", "event 2"])
        check("log: later writes add to the end", log.append([event(3)]) && log.load().map(\.title) == ["event 1", "event 2", "event 3"])
        check("log: only the newest are loaded", log.load(limit: 2).map(\.title) == ["event 2", "event 3"] && log.load().count == 3)
        log.append((4...9).map(event))
        check("log: a file past twice the limit is cut back", log.load(limit: 4).map(\.title) == ["event 6", "event 7", "event 8", "event 9"] && log.load().count == 4)
        if let h = try? FileHandle(forWritingTo: log.url) { h.seekToEndOfFile(); h.write(Data("not json\n".utf8)); try? h.close() }
        check("log: a damaged line is skipped", log.load().count == 4)
        check("log: a file that can't be written reports it", !EventLog(url: dir.appendingPathComponent("missing/events.jsonl")).append([event(1)]))
        let csv = EventLog.csv([event(1)])
        check("log: CSV quotes text", csv.hasPrefix("date,device,category,severity,event,detail\n") && csv.contains("\"a \"\"quoted\"\", detail\""))
        log.clear()
        check("log: clear removes the file", log.load().isEmpty && !FileManager.default.fileExists(atPath: log.url.path))
    }

    // --- Device error paths (simulated faults) ---
    do {
        let fsim = ControllerSimulator()
        let fdev = Device(simulator: fsim)
        fsim.forcedStatuses = [0xE0]
        let retried = try? fdev.execute(.capabilities)
        check("device: a CRC error is retried and the retry succeeds", retried?.status == 0x20 && retried?.reply.count == 0x48 && fsim.forcedStatuses.isEmpty)
        fsim.forcedStatuses = [0xE0, 0xE0, 0xE0, 0xE0]
        let gaveUp = try? fdev.execute(.raidStatus)
        check("device: three failures in a row give up with the status and no reply", gaveUp?.status == 0xE0 && gaveUp?.reply.isEmpty == true && fsim.forcedStatuses.count == 1)
        fsim.forcedStatuses = [0x33, 0x33, 0x33]
        let unknown = try? fdev.execute(.capabilities)
        check("device: a status outside the known set reads as Invalid Status", unknown?.status == 0xF4)
        fsim.forcedStatuses = [0xFF, 0xFF, 0xFF]
        check("device: fetchAll throws when a read keeps failing", (try? fetchAll(fdev)) == nil)
        fsim.forcedStatuses = []
        fsim.busyReads = 3
        let settled = try? fdev.execute(.diskStatus)
        check("device: waits through 'in process' for the final reply", settled?.status == 0x20 && settled?.reply == fsim.disks)
        fsim.busyReads = 0
        // The result sector still holds the disk status reply; a controller that stops answering
        // must time out once (no retries), not pass that old reply off as this command's.
        fsim.silent = true
        let t0 = Date()
        let timedOut = try? fdev.execute(.identify)
        let waited = Date().timeIntervalSince(t0)
        check("device: no answer is a timeout, tried once", timedOut?.status == 0xF2 && waited >= 1.4 && waited < 3)
        check("device: discovery ignores a controller that doesn't answer", (try? fetchAll(fdev)) == nil)
        fsim.silent = false
        check("device: answers again afterwards", (try? fdev.execute(.identify))?.status == 0x00)
        let missing: Bool = { do { _ = try Device(path: "/nonexistent/graid-selftest"); return false } catch { return "\(error)".contains("cannot open") } }()
        check("device: a path that can't be opened is an error, not a crash", missing)
    }

    // --- Command line ---
    do {
        func parse(_ line: String) -> Arguments? { try? Arguments(line.split(separator: " ").map(String.init)) }
        let a = parse("set-mode raid1 disk4 --name Studio --yes-erase-all-data -v")
        check("cli: options anywhere, positionals in order", a?.positional == ["set-mode", "raid1", "disk4"] && a?.name == "Studio" && a?.eraseConfirmed == true && a?.verbose == true && a?.overwriteConfirmed == false)
        check("cli: defaults", parse("status")?.name == "G-RAID" && parse("status")?.interval == 5 && parse("status")?.from == nil && parse("status")?.simulate == false)
        check("cli: an option without its value is an error, not a disk name", parse("set-mode raid1 --name") == nil && parse("set-mode raid1 --name --yes-erase-all-data") == nil)
        check("cli: numbers are checked", parse("rebuild --from two") == nil && parse("watch-ram --interval fast") == nil && parse("watch-ram --count 0") == nil && parse("rebuild --from 2")?.from == 2)
        check("cli: unknown options are refused", parse("status --jsno") == nil && parse("set-mode raid1 --yes") == nil)
        check("cli: the two confirmations are separate", parse("rebuild --from 1 --yes-erase-all-data")?.overwriteConfirmed == false)
        check("cli: sizes in hex and decimal", parse("firmware-dump --size 0x1F000")?.size == 0x1F000 && parse("firmware-dump --size 4096")?.size == 4096 && parse("firmware-dump --size big") == nil)
        check("cli: disk names", isDiskArgument("disk4") && isDiskArgument("/dev/rdisk12") && !isDiskArgument("disk-notes.bin") && !isDiskArgument("/tmp/disk4.img") && !isDiskArgument("disk4s1"))
        check("cli: BSD name and raw path", bsdName("/dev/rdisk4") == "disk4" && bsdName("rdisk4") == "disk4" && devicePath("disk4") == "/dev/rdisk4" && devicePath("/dev/disk4") == "/dev/rdisk4" && devicePath("/tmp/fake.img") == "/tmp/fake.img")
        check("cli: help is a command", parse("--help")?.command == "--help" && parse("")?.command == nil)
    }
    return ok
}


