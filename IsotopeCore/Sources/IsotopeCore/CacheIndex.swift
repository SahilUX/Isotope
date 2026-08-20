import Foundation

/// One file held in the local ISO cache (`Caches/Isotope/isos/`, DESIGN §3).
///
/// `key` is both the index identity and the on-disk stem, so the index alone is
/// enough to find, evict or re-verify a file without walking the directory.
public struct CachedArtifact: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    /// Name on disk inside the cache folder (already unique via `key`).
    public var fileName: String
    public var sizeBytes: Int64
    /// Verified SHA-256 of this file, when the source published one (PRD F21).
    public var sha256: String?
    /// The URL this artifact was downloaded from — half of the (URL, sha256)
    /// cache-hit test in PRD F20.
    public var sourceURL: URL?
    /// The artifact this one was extracted from, if any (Memtest86+ ships a zip).
    public var derivedFromKey: String?
    public var addedAt: Date
    public var lastUsedAt: Date

    public var id: String { key }

    public init(key: String, fileName: String, sizeBytes: Int64, sha256: String? = nil,
                sourceURL: URL? = nil, derivedFromKey: String? = nil,
                addedAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.key = key
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.derivedFromKey = derivedFromKey
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// The size-capped LRU index behind the download cache (PRD F20).
///
/// Pure value type: it decides *what* should be evicted, it never touches the
/// filesystem. The app layer applies the returned eviction list by deleting
/// files. That split keeps the policy testable and Linux-portable (DESIGN §1).
public struct CacheIndex: Codable, Sendable, Equatable {
    /// PRD F20 default. `<= 0` means "no cap".
    public static let defaultCapacityBytes: Int64 = 20 * 1024 * 1024 * 1024

    public var capacityBytes: Int64
    public private(set) var artifacts: [CachedArtifact]

    public init(capacityBytes: Int64 = CacheIndex.defaultCapacityBytes,
                artifacts: [CachedArtifact] = []) {
        self.capacityBytes = capacityBytes
        self.artifacts = artifacts
    }

    // MARK: - Reads

    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.sizeBytes } }

    public var isEmpty: Bool { artifacts.isEmpty }

    public func artifact(key: String) -> CachedArtifact? {
        artifacts.first { $0.key == key }
    }

    /// PRD F20 cache-hit test. A published checksum is the stronger identity —
    /// the same ISO served from two mirrors is one cache entry — so it is tried
    /// first; unverified sources fall back to matching the download URL.
    public func lookup(sourceURL: URL?, sha256: String?) -> CachedArtifact? {
        if let sha256, !sha256.isEmpty {
            let wanted = sha256.lowercased()
            if let hit = artifacts.first(where: { $0.sha256?.lowercased() == wanted }) { return hit }
        }
        guard let sourceURL else { return nil }
        // Only trust a URL match when neither side claims a conflicting hash.
        return artifacts.first { candidate in
            guard candidate.sourceURL == sourceURL else { return false }
            guard let want = sha256?.lowercased(), let have = candidate.sha256?.lowercased()
            else { return true }
            return want == have
        }
    }

    /// The extracted child of `key`, e.g. the `.iso` unpacked from a `.iso.zip`.
    public func derived(fromKey key: String) -> CachedArtifact? {
        artifacts.first { $0.derivedFromKey == key }
    }

    // MARK: - Mutations

    /// Marks an artifact as just used, which moves it to the back of the
    /// eviction queue. No-op for unknown keys.
    public mutating func touch(key: String, at date: Date = Date()) {
        guard let index = artifacts.firstIndex(where: { $0.key == key }) else { return }
        artifacts[index].lastUsedAt = date
    }

    /// Inserts (or replaces) an artifact and enforces the cap. The artifact just
    /// inserted is never the one evicted — it was downloaded because it is
    /// needed right now, even if it alone exceeds the cap.
    @discardableResult
    public mutating func insert(_ artifact: CachedArtifact,
                                protecting: Set<String> = []) -> [CachedArtifact] {
        artifacts.removeAll { $0.key == artifact.key }
        artifacts.append(artifact)
        return evictBeyondCapacity(protecting: protecting.union([artifact.key]))
    }

    @discardableResult
    public mutating func remove(key: String) -> CachedArtifact? {
        guard let index = artifacts.firstIndex(where: { $0.key == key }) else { return nil }
        // Dropping a parent archive orphans its extracted child; drop both.
        let removed = artifacts.remove(at: index)
        artifacts.removeAll { $0.derivedFromKey == key }
        return removed
    }

    /// Settings' "Clear cache" (PRD F20): returns everything so the caller can
    /// delete the files.
    @discardableResult
    public mutating func clear(protecting: Set<String> = []) -> [CachedArtifact] {
        let removed = artifacts.filter { !protecting.contains($0.key) }
        artifacts.removeAll { !protecting.contains($0.key) }
        return removed
    }

    /// Least-recently-used eviction down to `capacityBytes`. Keys in
    /// `protecting` (in-flight copies) are never evicted; an extracted child is
    /// evicted with its parent so the pair never half-survives.
    @discardableResult
    public mutating func evictBeyondCapacity(protecting: Set<String> = []) -> [CachedArtifact] {
        guard capacityBytes > 0, totalBytes > capacityBytes else { return [] }
        var evicted: [CachedArtifact] = []
        // Oldest use first; ties broken by insertion time for determinism.
        let order = artifacts.sorted {
            $0.lastUsedAt == $1.lastUsedAt ? $0.addedAt < $1.addedAt : $0.lastUsedAt < $1.lastUsedAt
        }
        for candidate in order {
            guard totalBytes > capacityBytes else { break }
            guard !protecting.contains(candidate.key) else { continue }
            guard artifacts.contains(where: { $0.key == candidate.key }) else { continue }
            // Never strand a child whose parent is protected, and vice versa.
            if let parent = candidate.derivedFromKey, protecting.contains(parent) { continue }
            let family = artifacts.filter { $0.key == candidate.key || $0.derivedFromKey == candidate.key }
            guard !family.contains(where: { protecting.contains($0.key) }) else { continue }
            artifacts.removeAll { $0.key == candidate.key || $0.derivedFromKey == candidate.key }
            evicted.append(contentsOf: family)
        }
        return evicted
    }
}

/// Where cached downloads live (PRD N6: `~/Library/Caches/Isotope/`).
public struct CacheLocations: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var isos: URL { root.appendingPathComponent("isos", isDirectory: true) }
    public var index: URL { root.appendingPathComponent("cache-index.json") }
    /// Persisted `URLSession` resume data + its manifest (PRD F19).
    public var resume: URL { root.appendingPathComponent("resume", isDirectory: true) }
    public var resumeManifest: URL { resume.appendingPathComponent("interrupted.json") }

    public func ensureDirectoriesExist() throws {
        for directory in [root, isos, resume] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
