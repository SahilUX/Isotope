import Foundation

/// Runs one iteration of a chunked read loop inside its own autorelease pool.
///
/// On Darwin, `FileHandle.read(upToCount:)` hands back `Data` bridged from an
/// autoreleased `NSData`. A loop on a background thread never drains the
/// surrounding pool, so every chunk read stays alive until the loop returns:
/// copying a 9 GB ISO in 4 MB chunks held 2,066 buffers — 8.3 GB of RAM —
/// at the moment the copy was 8.67 GB in. Draining per chunk keeps the
/// footprint at one chunk, whatever the file size.
///
/// Linux has no autorelease pools, so there it just runs `body`.
@inlinable
public func withChunkScope<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
