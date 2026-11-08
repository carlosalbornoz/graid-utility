import Foundation

// MARK: - Release check (GitHub Releases)
//
// The app asks GitHub for the project's releases and compares the newest one with its own
// version. It only reads public release data; nothing about the Mac or the G-RAID is sent.

let releaseRepository = "carlosalbornoz/graid-utility"
let releasesAPI = URL(string: "https://api.github.com/repos/\(releaseRepository)/releases?per_page=20")!
let releasesPage = URL(string: "https://github.com/\(releaseRepository)/releases")!

/// A version like "2.0", "2.1.3" or a tag like "v2.1", compared number by number
/// ("2.10" is newer than "2.9", "2.1" equals "2.1.0").
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // Ignore a suffix such as "-beta" or "+build"; GitHub's pre-release flag says that.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) { s = String(s[..<cut]) }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        var p = nums.map { $0! }
        while p.count > 1 && p.last == 0 { p.removeLast() }
        parts = p
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The parts of a GitHub release the app uses.
struct ReleaseInfo: Decodable, Equatable {
    let tag: String
    let name: String?
    let notes: String?
    let page: URL
    let prerelease: Bool
    let draft: Bool
    let published: Date?
    let assets: [Asset]

    struct Asset: Decodable, Equatable {
        let name: String
        let url: URL
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
    }

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, notes = "body", page = "html_url", prerelease, draft
        case published = "published_at", assets
    }

    var version: AppVersion? { AppVersion(tag) }
    var title: String { "G-RAID Utility \(version?.description ?? tag)" }

    /// The app download ("G-RAID-Utility-2.1.zip"), else the release page.
    var downloadURL: URL {
        assets.first { $0.name.hasPrefix("G-RAID-Utility") && $0.name.hasSuffix(".zip") }?.url ?? page
    }
}

func decodeReleases(_ data: Data) throws -> [ReleaseInfo] {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try d.decode([ReleaseInfo].self, from: data)
}

/// The newest release that is newer than `current`, skipping drafts, tags that aren't versions,
/// and pre-releases unless asked for.
func newerRelease(than current: AppVersion, in releases: [ReleaseInfo], includePrereleases: Bool) -> ReleaseInfo? {
    releases
        .filter { !$0.draft && (includePrereleases || !$0.prerelease) }
        .compactMap { r in r.version.map { (r, $0) } }
        .filter { $0.1 > current }
        .max { $0.1 < $1.1 }?.0
}

/// The first real sentence of the release notes, for the notice bar: skips headings, bold
/// warnings and list markers, drops Markdown emphasis and links, and keeps it short.
func releaseSummary(_ notes: String?, limit: Int = 140) -> String? {
    guard let notes else { return nil }
    for raw in notes.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("```") { continue }
        for marker in ["- ", "* ", "> "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
        // [text](url) → text
        while let open = line.range(of: "["), let mid = line.range(of: "](", range: open.upperBound..<line.endIndex),
              let close = line.range(of: ")", range: mid.upperBound..<line.endIndex) {
            line.replaceSubrange(open.lowerBound..<close.upperBound, with: line[open.upperBound..<mid.lowerBound])
        }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.count <= limit { return line }
        let cut = line.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
    return nil
}

/// Fetches the release list. Throws a readable error for offline, rate limits and bad replies.
func fetchReleases(timeout: TimeInterval = 15) async throws -> [ReleaseInfo] {
    var req = URLRequest(url: releasesAPI, timeoutInterval: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("G-RAID-Utility", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 200: return try decodeReleases(data)
    case 403, 429: throw ToolError("GitHub is limiting requests right now. Try again in an hour.")
    default: throw ToolError("GitHub answered with status \(code).")
    }
}
