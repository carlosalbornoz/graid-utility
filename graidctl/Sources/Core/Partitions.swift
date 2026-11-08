// Every partition on a G-RAID disk, sorted into volumes, system partitions, and partitions macOS
// can't read. Built from IORegistry and DiskArbitration descriptions only: nothing here reads
// the disk, so listing partitions doesn't wake the drives.

import DiskArbitration
import Foundation
import IOKit

enum PartitionKind: String, Equatable {
    case volume       // a file system the user works with (APFS, Mac OS Extended, exFAT, FAT, NTFS)
    case system       // EFI, Microsoft Reserved, Apple_Boot, APFS Preboot/Recovery/VM…
    case unreadable   // ext4, Linux swap, unformatted, anything macOS has no file system for
}

struct Partition: Identifiable, Equatable {
    var id: String { bsd }
    let bsd: String              // disk4s2, or disk5s1 for a volume inside an APFS container
    let physicalDisk: String     // the G-RAID whole disk it lives on (disk4)
    let parentDisk: String       // its whole disk: disk4, or the APFS container disk (disk5)
    let name: String
    let size: Double
    let format: String
    let kind: PartitionKind
    let mountable: Bool
    let mountURL: URL?
    let used: Double
    let total: Double
    let readOnly: Bool

    var isMounted: Bool { mountURL != nil }
    var isAPFS: Bool { parentDisk != physicalDisk }
}

// Partition type GUIDs (and the older Apple partition-map names) that hold no user data.
private let systemContent: Set<String> = [
    "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI",                   // EFI system partition
    "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", "Microsoft Reserved",    // Microsoft Reserved
    "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC",                          // Windows Recovery
    "426F6F74-0000-11AA-AA11-00306543ECAC", "Apple_Boot",            // Apple_Boot (Recovery HD)
    "69646961-6700-11AA-AA11-00306543ECAC",                          // Apple_APFS_ISC
    "52637672-7900-11AA-AA11-00306543ECAC",                          // Apple_APFS_Recovery
]
let apfsContainerContent = "7C3457EF-0000-11AA-AA11-00306543ECAC"
/// APFS volume roles that are part of a startup disk rather than user data.
private let systemAPFSRoles: Set<String> = ["System", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Prelogin", "Installer"]

private let contentNames: [String: String] = [
    "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI",
    "E3C9E316-0B5C-4DB8-817D-F92DF00215AE": "Microsoft Reserved",
    "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC": "Windows Recovery",
    "426F6F74-0000-11AA-AA11-00306543ECAC": "Apple Boot",
    "69646961-6700-11AA-AA11-00306543ECAC": "APFS ISC",
    "52637672-7900-11AA-AA11-00306543ECAC": "APFS Recovery",
    "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux file system",
    "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": "Linux swap",
    "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Unknown format",
    "48465300-0000-11AA-AA11-00306543ECAC": "Mac OS Extended (damaged?)",
]

func classifyPartition(content: String, volumeKind: String?, apfsRoles: [String]) -> PartitionKind {
    if systemContent.contains(content.uppercased()) || systemContent.contains(content) { return .system }
    if apfsRoles.contains(where: systemAPFSRoles.contains) { return .system }
    return volumeKind == nil ? .unreadable : .volume
}

func formatName(volumeType: String?, volumeKind: String?, content: String) -> String {
    if let t = volumeType, !t.isEmpty { return t }
    switch volumeKind {
    case "apfs": return "APFS"
    case "hfs": return "Mac OS Extended"
    case "exfat": return "ExFAT"
    case "msdos": return "FAT"
    case "ntfs": return "NTFS"
    case let k?: return k.uppercased()
    case nil: return contentNames[content.uppercased()] ?? (content.isEmpty ? "Unknown" : content)
    }
}

/// All partitions on a G-RAID whole disk, including volumes inside APFS containers, in disk order.
func partitions(onWholeDisk bsd: String) -> [Partition] {
    guard let session = DASessionCreate(kCFAllocatorDefault),
          let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return [] }
    let whole = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard whole != 0 else { return [] }
    defer { IOObjectRelease(whole) }

    func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // Walk everything below the whole disk: partitions, and for APFS the container's volumes.
    var found: [(bsd: String, parent: String, roles: [String])] = []
    var currentWhole = bsd
    var it: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(whole, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        guard IOObjectConformsTo(e, "IOMedia") != 0, let name = prop(e, "BSD Name") as? String else { continue }
        if (prop(e, "Whole") as? Bool) == true { currentWhole = name; continue }   // APFS container disk
        if (prop(e, "Content") as? String)?.uppercased() == apfsContainerContent { continue } // shown as its volumes
        if name.range(of: #"^disk\d+s\d+s\d+"#, options: .regularExpression) != nil { continue } // APFS snapshots
        let roles: [String]
        switch prop(e, "Role") {
        case let a as [String]: roles = a
        case let s as String: roles = [s]
        default: roles = []
        }
        found.append((name, name.hasPrefix(bsd + "s") ? bsd : currentWhole, roles))
    }

    return found.compactMap { f in
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, f.bsd),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let content = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let kind = desc[kDADiskDescriptionVolumeKindKey as String] as? String
        let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL
        let size = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.doubleValue ?? 0
        let volName = desc[kDADiskDescriptionVolumeNameKey as String] as? String
        let mediaName = desc[kDADiskDescriptionMediaNameKey as String] as? String
        let partKind = classifyPartition(content: content, volumeKind: kind, apfsRoles: f.roles)
        var name = volName ?? ""
        if name.isEmpty { name = partKind == .system ? (contentNames[content.uppercased()] ?? mediaName ?? f.bsd) : (mediaName ?? f.bsd) }
        var used = 0.0, total = 0.0, readOnly = false
        if let url {
            let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey])
            total = Double(v?.volumeTotalCapacity ?? 0)
            used = max(0, total - Double(v?.volumeAvailableCapacity ?? 0))
            readOnly = v?.volumeIsReadOnly ?? false
        }
        return Partition(bsd: f.bsd, physicalDisk: bsd, parentDisk: f.parent, name: name, size: size,
                         format: formatName(volumeType: desc["DAVolumeType"] as? String, volumeKind: kind, content: content),
                         kind: partKind, mountable: (desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool) ?? false,
                         mountURL: url, used: used, total: total, readOnly: readOnly)
    }
}

/// Whether a disk or partition with this BSD name is currently attached (IORegistry only).
func diskExists(_ bsd: String) -> Bool {
    guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return false }
    let s = IOServiceGetMatchingService(kIOMainPortDefault, match)
    if s != 0 { IOObjectRelease(s); return true }
    return false
}
