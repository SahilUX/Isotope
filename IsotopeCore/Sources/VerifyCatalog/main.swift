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
}

let resolver = VersionResolver()

let rows: [Row] = await withTaskGroup(of: Row.self) { group in
    for entry in entries {
        for channel in entry.channels {
            let label = entry.channels.count > 1 ? "\(entry.name) / \(channel.name)" : entry.name
            group.addTask {
                do {
                    let release = try await resolver.fetchLatest(config: channel.provider)
                    return Row(label: label, mechanism: channel.provider.mechanism.rawValue,
                               release: release, failure: nil)
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
    } else {
        let message = row.failure ?? "unknown error"
        failures += 1
        print("FAIL \(row.label)  [\(row.mechanism)]")
        print("     \(message)")
    }
    print(String(repeating: "-", count: 72))
}
print("\(rows.count - failures)/\(rows.count) channels resolved.")
exit(failures == 0 ? 0 : 1)
