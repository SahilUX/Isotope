import Foundation
import IsotopeCore

/// Runs version checks for every catalog channel (DESIGN §4.2).
///
/// One `TaskGroup` task per channel, each with its own 15 s budget (PRD N5), so a
/// slow or broken source can never block or fail the rest of the sweep (PRD F14).
/// Results are streamed back as they land rather than collected at the end, so
/// the UI fills in progressively.
actor CatalogService {
    /// Per-source ceiling covering the whole provider run, including an index
    /// step's extra request — the HTTP client's own timeout is per request.
    static let sourceTimeout: TimeInterval = 15

    private let resolver: VersionProvider

    init(resolver: VersionProvider = VersionResolver()) {
        self.resolver = resolver
    }

    enum Outcome: Sendable {
        case success(Release)
        case failure(String)
    }

    /// Checks every channel of every entry. `report` is called once per channel.
    func check(entries: [CatalogEntry],
               report: @escaping @Sendable (ReleaseKey, Outcome) async -> Void) async {
        let jobs: [(ReleaseKey, ProviderConfig)] = entries.flatMap { entry in
            entry.channels.map { (ReleaseKey(entryID: entry.id, channelID: $0.id), $0.provider) }
        }
        await withTaskGroup(of: Void.self) { group in
            for (key, config) in jobs {
                group.addTask { [resolver] in
                    let outcome = await Self.run(resolver: resolver, config: config)
                    await report(key, outcome)
                }
            }
        }
    }

    func checkOne(config: ProviderConfig) async -> Outcome {
        await Self.run(resolver: resolver, config: config)
    }

    private static func run(resolver: VersionProvider, config: ProviderConfig) async -> Outcome {
        do {
            let release = try await withThrowingTaskGroup(of: Release.self) { group -> Release in
                group.addTask { try await resolver.fetchLatest(config: config) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(sourceTimeout * 1_000_000_000))
                    throw CatalogCheckError.timedOut
                }
                guard let first = try await group.next() else { throw CatalogCheckError.timedOut }
                group.cancelAll()
                return first
            }
            return .success(release)
        } catch {
            return .failure(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        if let providerError = error as? ProviderError, let text = providerError.errorDescription {
            return text
        }
        if error is CatalogCheckError {
            return "The source did not answer within \(Int(sourceTimeout)) seconds."
        }
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        return error.localizedDescription
    }
}

enum CatalogCheckError: Error {
    case timedOut
}
