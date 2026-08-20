import Foundation

/// PRD F32: what may be written to a flashed drive.
///
/// A plain `dd` of a Windows ISO does not produce a bootable stick (it needs a
/// FAT32/NTFS layout Microsoft's installer expects), and a `windowsManual`
/// channel has no direct ISO to write in the first place — so those entries are
/// filtered out of a flashed drive's assignment picker rather than being offered
/// and failing later.
public extension ProviderConfig {
    var isFlashable: Bool {
        switch self {
        case .windowsManual: return false
        case .checksumFile, .gitHubReleases, .staticURL, .pageScrape, .jsonFeed: return true
        }
    }
}

public extension Channel {
    var isFlashable: Bool { provider.isFlashable }
}

public extension CatalogEntry {
    /// The channels a flashed drive may be assigned.
    var flashableChannels: [Channel] { channels.filter(\.isFlashable) }

    var hasFlashableChannel: Bool { !flashableChannels.isEmpty }
}

public enum FlashEligibility {
    /// Entries offered by a flashed drive's assignment picker: only those with
    /// at least one flashable channel (PRD F32).
    public static func flashableEntries(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.filter(\.hasFlashableChannel)
    }
}
