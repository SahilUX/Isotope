import Foundation
import IsotopeCore

// Developer script (DESIGN §7): runs every catalog channel against the live
// endpoints and prints what each provider resolved. Unit tests stay offline and
// fixture-driven; this is what you run after editing catalog.json.
//
//   swift run --package-path IsotopeCore verify-catalog [path/to/catalog.json]
//   Scripts/verify-catalog.sh

let arguments = CommandLine.arguments
let catalogPath = arguments.count > 1
    ? arguments[1]
    : FileManager.default.currentDirectoryPath + "/Isotope/Resources/catalog.json"

let catalogURL = URL(fileURLWithPath: catalogPath)
guard let data = try? Data(contentsOf: catalogURL) else {
    FileHandle.standardError.write(Data("Cannot read catalog at \(catalogURL.path)\n".utf8))
    exit(2)
}

let entries: [CatalogEntry]
do {
    entries = try JSONStore.loadJSON([CatalogEntry].self, from: data)
} catch {
    FileHandle.standardError.write(Data("Malformed catalog: \(error)\n".utf8))
    exit(2)
}

struct Row: Sendable {
    let label: String
    let mechanism: String
    let release: Release?
    let failure: String?
    /// PRD F73: alternates checked, how many did not match, and why.
    var mirrors = MirrorCheck()
}

struct MirrorCheck: Sendable {
    var checked = 0
    var mismatched = 0
    var warnings: [String] = []
}

let resolver = VersionResolver()

/// What a HEAD request says about a file: enough to tell whether a mirror is
/// serving the same thing the origin is.
struct HeadInfo: Sendable {
    let status: Int?
    let contentLength: Int64?
    let acceptsRanges: Bool
    let error: String?
}

func head(_ url: URL) async -> HeadInfo {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "HEAD"
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return HeadInfo(status: nil, contentLength: nil, acceptsRanges: false, error: "not HTTP")
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
        return HeadInfo(status: http.statusCode, contentLength: length, acceptsRanges: ranges, error: nil)
    } catch {
        return HeadInfo(status: nil, contentLength: nil, acceptsRanges: false,
                        error: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}

/// PRD F73: every alternate must answer 200 with the origin's Content-Length
/// and accept byte ranges. Anything else is a *warning* — mirrors go stale and
/// come back, and the app already skips one that does not measure up, so a
/// mirror must never be what fails catalog verification. The origin still is.
func checkMirrors(entry: CatalogEntry, channel: Channel, isoURL: URL) async -> MirrorCheck {
    let alternates = Array(entry.downloadCandidates(for: isoURL, channelID: channel.id).dropFirst())
    guard !alternates.isEmpty else { return MirrorCheck() }
    let origin = await head(isoURL)
    var check = MirrorCheck()
    check.checked = alternates.count
    if origin.contentLength == nil {
        check.warnings.append("origin sent no Content-Length; mirror sizes not compared")
    }
    let results = await withTaskGroup(of: (URL, HeadInfo).self) { group in
        for url in alternates { group.addTask { (url, await head(url)) } }
        var collected: [URL: HeadInfo] = [:]
        for await (url, info) in group { collected[url] = info }
        return collected
    }
    for url in alternates {
        guard let info = results[url] else { continue }
        let host = url.host ?? url.absoluteString
        let problem: String?
        if let error = info.error {
            problem = error
        } else if info.status != 200 {
            problem = "HTTP \(info.status.map(String.init) ?? "?")"
        } else if let expected = origin.contentLength, info.contentLength != expected {
            problem = "Content-Length \(info.contentLength.map(String.init) ?? "none"), origin \(expected)"
        } else if !info.acceptsRanges {
            problem = "no Accept-Ranges: bytes"
        } else {
            problem = nil
        }
        if let problem {
            check.mismatched += 1
            check.warnings.append("\(host): \(problem)")
        }
    }
    return check
}

let rows: [Row] = await withTaskGroup(of: Row.self) { group in
    for entry in entries {
        for channel in entry.channels {
            let label = entry.channels.count > 1 ? "\(entry.name) / \(channel.name)" : entry.name
            group.addTask {
                do {
                    let release = try await resolver.fetchLatest(config: channel.provider)
                    var row = Row(label: label, mechanism: channel.provider.mechanism.rawValue,
                                  release: release, failure: nil)
                    if let isoURL = release.isoURL {
                        row.mirrors = await checkMirrors(entry: entry, channel: channel, isoURL: isoURL)
                    }
                    return row
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    return Row(label: label, mechanism: channel.provider.mechanism.rawValue,
                               release: nil, failure: message)
                }
            }
        }
    }
    var collected: [Row] = []
    for await row in group { collected.append(row) }
    return collected.sorted { $0.label < $1.label }
}

var failures = 0
var mirrorWarnings = 0
print("Catalog: \(catalogURL.path)")
print(String(repeating: "=", count: 72))
for row in rows {
    if let release = row.release {
        let hash = release.sha256.map { String($0.prefix(16)) + "…" } ?? "none (unverified)"
        let size = release.sizeBytes.map { "\($0 / 1_048_576) MB" } ?? "unknown"
        print("OK   \(row.label)  [\(row.mechanism)]")
        print("     version : \(release.displayVersion)")
        print("     file    : \(release.fileName.isEmpty ? "(manual download)" : release.fileName)")
        print("     url     : \(release.isoURL?.absoluteString ?? "(none — manual download)")")
        print("     sha256  : \(hash)")
        print("     size    : \(size)")
        if row.mirrors.checked > 0 {
            let good = row.mirrors.checked - row.mirrors.mismatched
            print("     mirrors : \(good)/\(row.mirrors.checked) match the origin")
            for warning in row.mirrors.warnings { print("     WARN    : \(warning)") }
            mirrorWarnings += row.mirrors.warnings.count
        }
    } else {
        let message = row.failure ?? "unknown error"
        failures += 1
        print("FAIL \(row.label)  [\(row.mechanism)]")
        print("     \(message)")
    }
    print(String(repeating: "-", count: 72))
}
print("\(rows.count - failures)/\(rows.count) channels resolved.")
if mirrorWarnings > 0 {
    // Reported, never fatal: see `checkMirrors`.
    print("\(mirrorWarnings) mirror warning(s); they do not affect the exit status.")
}
exit(failures == 0 ? 0 : 1)
