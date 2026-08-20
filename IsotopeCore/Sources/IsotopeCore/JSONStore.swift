import Foundation

/// JSON persistence for the app's small, human-readable state files (PRD N6).
public enum JSONStore {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Loads `T` from `url`. Returns nil when the file does not exist; throws on
    /// malformed content so corruption is visible rather than silently reset.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try makeDecoder().decode(T.self, from: data)
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL, default fallback: T) -> T {
        ((try? load(type, from: url)) ?? nil) ?? fallback
    }

    /// Atomic write: encodes, creates the parent directory if needed, writes via
    /// a temp file + rename so a crash never leaves a truncated state file.
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try makeEncoder().encode(value)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public static func loadJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(T.self, from: data)
    }
}

/// The set of state files under `Application Support/Isotope/` (DESIGN §3).
public struct StoreLocations: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var drives: URL { root.appendingPathComponent("drives.json") }
    public var customSources: URL { root.appendingPathComponent("custom-sources.json") }
    public var releaseCache: URL { root.appendingPathComponent("release-cache.json") }
    public var history: URL { root.appendingPathComponent("history.json") }

    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
