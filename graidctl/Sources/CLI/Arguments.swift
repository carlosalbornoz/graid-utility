// graidctl's command line, parsed into values before any command runs. Kept apart from main.swift
// so `graidctl selftest` can check it.

import Foundation

struct Arguments: Equatable {
    var verbose = false
    var json = false
    var anyProtocol = false
    var simulate = false
    var eraseConfirmed = false       // --yes-erase-all-data (set-mode)
    var overwriteConfirmed = false   // --yes-overwrite-other-bay (rebuild)
    var ports = false                // --ports (watch-ram)
    var from: Int?                   // --from (rebuild): the bay holding the good copy
    var interval: Double = 5         // --interval (watch-ram), seconds
    var count: Int?                  // --count (watch-ram)
    var name = "G-RAID"              // --name (set-mode)
    var uid: String?                 // --uid (grant-access, unlock-daemon)
    var size: UInt32?                // --size (firmware-dump)
    /// The command and what follows it, in order, with the options taken out.
    var positional: [String] = []

    var command: String? { positional.first }
    var rest: [String] { Array(positional.dropFirst()) }

    /// Options may come anywhere on the line. An option that needs a value and has none, a value
    /// that isn't a number where one is needed, and an option nobody knows are all errors: none
    /// of them is quietly taken for a disk name or replaced with a default.
    init(_ argv: [String]) throws {
        var i = 0
        func value(_ option: String) throws -> String {
            guard i + 1 < argv.count, !argv[i + 1].hasPrefix("--") else { throw ToolError("\(option) needs a value") }
            i += 1
            return argv[i]
        }
        func number<T>(_ option: String, _ parse: (String) -> T?, _ what: String) throws -> T {
            let v = try value(option)
            guard let n = parse(v) else { throw ToolError("\(option) needs \(what), not '\(v)'") }
            return n
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "-v", "--verbose": verbose = true
            case "--json": json = true
            case "--any-protocol": anyProtocol = true
            case "--simulate": simulate = true
            case "--yes-erase-all-data": eraseConfirmed = true
            case "--yes-overwrite-other-bay": overwriteConfirmed = true
            case "--ports": ports = true
            case "--from": from = try number(a, { Int($0) }, "a bay number, 1 or 2")
            case "--interval": interval = try number(a, { Double($0).flatMap { $0 > 0 ? $0 : nil } }, "a number of seconds")
            case "--count": count = try number(a, { Int($0).flatMap { $0 > 0 ? $0 : nil } }, "a whole number above 0")
            case "--name": name = try value(a)
            case "--uid": uid = try value(a)
            case "--size": size = try number(a, parseSize, "a number such as 0x1F000")
            case "-h", "--help": positional.append(a)
            default:
                if a.hasPrefix("-") && a.count > 1 { throw ToolError("unknown option '\(a)'") }
                positional.append(a)
            }
            i += 1
        }
    }
}

/// "0x1F000" or "126976".
func parseSize(_ s: String) -> UInt32? {
    let hex = s.hasPrefix("0x") || s.hasPrefix("0X")
    return UInt32(hex ? String(s.dropFirst(2)) : s, radix: hex ? 16 : 10)
}

/// True for the ways a disk is named on the command line: disk4, rdisk4, /dev/disk4, /dev/rdisk4.
/// Anything else (a file called disk-notes.bin, a fake image's path) is not a disk name.
func isDiskArgument(_ s: String) -> Bool {
    s.range(of: #"^(/dev/)?r?disk[0-9]+$"#, options: .regularExpression) != nil
}

/// The BSD name of a disk argument: "/dev/rdisk4" → "disk4". Other text comes back unchanged.
func bsdName(_ s: String) -> String {
    guard isDiskArgument(s) else { return s }
    let name = s.hasPrefix("/dev/") ? String(s.dropFirst(5)) : s
    return name.hasPrefix("r") ? String(name.dropFirst()) : name
}

/// The path to open for a device argument: the raw node for a disk name, and the text itself
/// for anything else (the image file tests/fake_device.sh uses).
func devicePath(_ s: String) -> String {
    isDiskArgument(s) ? "/dev/r" + bsdName(s) : s
}
