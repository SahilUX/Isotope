import Foundation
import IsotopeCore

/// The on-disk half of the download cache (PRD F20). All eviction *policy* lives
/// in `IsotopeCore.CacheIndex`; this actor owns the files, the index file and
/// the "don't evict what a copy is reading right now" holds.
actor ISOCache {
    private let locations: CacheLocations
    private var index: CacheIndex
    /// Keys currently being copied to a drive — never evicted underneath us.
    private var holds: [String: Int] = [:]

    init(locations: CacheLocations, capacityBytes: Int64 = CacheIndex.defaultCapacityBytes) {
        self.locations = locations
        var loaded = (try? JSONStore.load(CacheIndex.self, from: locations.index)) ?? nil
            ?? CacheIndex(capacityBytes: capacityBytes)
        loaded.capacityBytes = capacityBytes
        self.index = loaded
        try? locations.ensureDirectoriesExist()
    }

    // MARK: - Reads

    var snapshot: CacheIndex { index }

    var totalBytes: Int64 { index.totalBytes }

    func fileURL(_ artifact: CachedArtifact) -> URL {
        locations.isos.appendingPathComponent(artifact.fileName)
    }

    /// PRD F20 cache-hit test. A hit whose file has vanished (user emptied
    /// `~/Library/Caches`, macOS purged it) self-heals into a miss.
    func hit(sourceURL: URL?, sha256: String?, at date: Date = Date()) -> CachedArtifact? {
        guard let candidate = index.lookup(sourceURL: sourceURL, sha256: sha256) else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL(candidate).path) else {
            index.remove(key: candidate.key)
            persist()
            return nil
        }
        index.touch(key: candidate.key, at: date)
        persist()
        return index.artifact(key: candidate.key)
    }

    func artifact(key: String) -> CachedArtifact? {
        guard let artifact = index.artifact(key: key),
              FileManager.default.fileExists(atPath: fileURL(artifact).path) else { return nil }
        return artifact
    }

    func extracted(fromKey key: String) -> CachedArtifact? {
        guard let child = index.derived(fromKey: key) else { return nil }
        return artifact(key: child.key)
    }

    // MARK: - Writes

    /// Moves a finished download (or an extracted ISO) into the cache and
    /// enforces the cap, deleting whatever the index evicts.
    @discardableResult
    func adopt(fileAt source: URL, key: String, fileName: String,
               sha256: String?, sourceURL: URL?, derivedFromKey: String? = nil,
               at date: Date = Date()) throws -> CachedArtifact {
        try locations.ensureDirectoriesExist()
        let storedName = DownloadArtifact.cacheFileName(key: key, fileName: fileName)
        let destination = locations.isos.appendingPathComponent(storedName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Same volume in practice (both under ~/Library), but fall back to a
        // copy so a temp dir on another volume still works.
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let artifact = CachedArtifact(key: key, fileName: storedName, sizeBytes: size,
                                      sha256: sha256, sourceURL: sourceURL,
                                      derivedFromKey: derivedFromKey,
                                      addedAt: date, lastUsedAt: date)
        let evicted = index.insert(artifact, protecting: Set(holds.keys))
        delete(evicted)
        persist()
        return artifact
    }

    func touch(key: String, at date: Date = Date()) {
        index.touch(key: key, at: date)
        persist()
    }

    func forget(key: String) {
        if let removed = index.remove(key: key) { delete([removed]) }
        persist()
    }

    /// Settings' "Clear cache" (PRD F20). Returns the bytes reclaimed.
    @discardableResult
    func clear() -> Int64 {
        let removed = index.clear(protecting: Set(holds.keys))
        let freed = removed.reduce(0) { $0 + $1.sizeBytes }
        delete(removed)
        persist()
        return freed
    }

    func setCapacity(_ bytes: Int64) {
        index.capacityBytes = bytes
        delete(index.evictBeyondCapacity(protecting: Set(holds.keys)))
        persist()
    }

    // MARK: - Holds

    func retain(key: String) { holds[key, default: 0] += 1 }

    func release(key: String) {
        guard let count = holds[key] else { return }
        if count <= 1 {
            holds[key] = nil
            // A copy just finished; the cap may have been exceeded while it ran.
            delete(index.evictBeyondCapacity(protecting: Set(holds.keys)))
            persist()
        } else {
            holds[key] = count - 1
        }
    }

    // MARK: - Internals

    private func delete(_ artifacts: [CachedArtifact]) {
        for artifact in artifacts {
            try? FileManager.default.removeItem(at: fileURL(artifact))
        }
    }

    private func persist() {
        try? JSONStore.save(index, to: locations.index)
    }
}

extension CacheLocations {
    /// `~/Library/Caches/Isotope/` (PRD N6).
    static func userCaches() -> CacheLocations {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CacheLocations(root: base.appendingPathComponent("Isotope", isDirectory: true))
    }
}
