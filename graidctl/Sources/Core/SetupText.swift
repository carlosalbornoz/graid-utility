import Foundation

/// Bundle identifier of G-Technology's 2017 "G-RAID with Thunderbolt Configurator".
let oldConfiguratorBundleID = "com.G-RAID-with-Thunderbolt-Configurator"

/// "in Downloads", "in Downloads and Applications", "in 3 places": where copies of an app are,
/// from the names of the folders holding them.
func placesText(_ folders: [String]) -> String {
    var seen: [String] = []
    for f in folders where !seen.contains(f) { seen.append(f) }
    switch seen.count {
    case 0: return ""
    case 1: return "in \(seen[0])"
    case 2: return "in \(seen[0]) and \(seen[1])"
    default: return "in \(seen.count) places"
    }
}
