# Technical Design Document — Isotope

**Version:** 1.0 (draft for approval)
**Implements:** PRD.md v1.0

## 1. Stack & project shape

- **Language/UI:** Swift 5.10+, SwiftUI, macOS 14 deployment target. Xcode project (`Isotope.xcodeproj`) generated via XcodeGen (`project.yml`), app target + unit-test target.
- **Portability split (future Linux version):** platform-agnostic logic lives in a local Swift package **`IsotopeCore`** — data models, `ProviderConfig`/`VersionProvider` implementations, version parsing/comparison, checksum-line parsing, catalog loading. Core depends on Foundation (+ FoundationNetworking-compatible URLSession use) only — no SwiftUI, AppKit, CryptoKit, or DiskArbitration. Hashing is abstracted behind a small `Hasher` protocol (macOS app injects a CryptoKit implementation; Linux would inject swift-crypto). The app target owns UI, DriveMonitor, DownloadManager, UpdateEngine, notifications. A future Linux client reuses IsotopeCore wholesale.
- **Concurrency:** Swift structured concurrency (`async/await`, actors). `@MainActor` observable stores feed the UI.
- **Persistence:** Plain JSON via `Codable` (PRD N6). No SwiftData/Core Data — the data set is tiny and human-readable files aid debugging.
- **Sandbox/entitlements:** App Sandbox ON; `com.apple.security.network.client`; `com.apple.security.files.user-selected.read-write` + security-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`) for drive access; UserNotifications.
- **Dependencies:** none (Foundation `URLSession`, `CryptoKit` for SHA-256, `DiskArbitration`/`NSWorkspace` for volumes). Zero third-party packages.

## 2. Architecture overview

```
┌────────────────────────── SwiftUI Views ─────────────────────────┐
│  DrivesView · DriveDetailView · CatalogView · CustomSourceSheet  │
│  ActivityView · SettingsView                                     │
└───────────────┬──────────────────────────────────────────────────┘
                │ observes (@Observable stores, MainActor)
┌───────────────▼──────────────┐
│          AppStore            │  drives, catalog, releases, tasks
└──┬────────┬────────┬─────────┘
   │        │        │
┌──▼─────┐┌─▼──────┐┌─▼─────────┐   ┌───────────────┐
│Catalog ││Update  ││ Drive     │   │ Notification  │
│Service ││Engine  ││ Monitor   │   │ Service       │
└──┬─────┘└─┬──┬───┘└─┬─────────┘   └───────────────┘
   │        │  │      │ NSWorkspace mount/unmount + volume UUID
┌──▼──────┐ │ ┌▼──────▼─┐
│Version  │ │ │ Drive   │  security-scoped bookmark, file ops
│Providers│ │ │ Access  │
└─────────┘ │ └─────────┘
        ┌───▼────────┐
        │ Download   │  URLSession bg-style downloads, resume,
        │ Manager    │  SHA-256 verify, cache (LRU)
        └────────────┘
                 Persistence: JSON files (Application Support)
```

## 3. Data model

```swift
struct CatalogEntry: Codable, Identifiable {
    var id: String                  // "ubuntu-desktop", "custom-<uuid>"
    var name: String
    var kind: Kind                  // .linux, .tool, .windows, .custom
    var homepage: URL?
    var channels: [Channel]         // ≥1; single "default" channel if N/A
    var isBuiltIn: Bool
}

struct Channel: Codable, Identifiable {
    var id: String                  // "lts", "latest", "netinst"
    var name: String
    var provider: ProviderConfig    // how to resolve the latest Release
}

enum ProviderConfig: Codable {     // discriminated union, PRD §5
    case checksumFile(url: URL, filePattern: String)      // regex w/ version capture
    case gitHubReleases(repo: String, assetPattern: String)
    case staticURL(url: URL, checksumURL: URL?)           // ETag/Last-Modified
    case pageScrape(url: URL, linkPattern: String)        // regex w/ version capture
    case windowsManual(infoURL: URL, downloadPage: URL)   // PRD §5.4
}

struct Release: Codable {          // resolved "latest" for a channel
    var version: VersionToken      // semantic parts or change-date
    var isoURL: URL?
    var fileName: String
    var sha256: String?
    var sizeBytes: Int64?
    var checkedAt: Date
}

enum VersionToken: Codable, Comparable {
    case semantic([Int], raw: String)   // "24.04.3" → [24,4,3]
    case date(Date, raw: String)        // ETag sources / arch "2026.08.01"
}

struct ManagedDrive: Codable, Identifiable {
    var id: UUID
    var volumeUUID: String
    var displayName: String
    var bookmark: Data              // security-scoped
    var isoFolder: String           // relative path on drive, default ""
    var keepOldVersions: Bool       // default false (replace)
    var assignments: [Assignment]
    var lastSeenAt: Date?
    var capacityBytes: Int64?
}

struct Assignment: Codable, Identifiable {
    var id: UUID
    var entryID: String
    var channelID: String
    var installed: InstalledISO?    // nil = not yet placed
}

struct InstalledISO: Codable {
    var fileName: String
    var version: VersionToken?      // nil = unrecognized
    var placedByApp: Bool           // discovered vs. app-written (PRD F7/F22)
    var updatedAt: Date
}
```

**Files:** `Application Support/Isotope/drives.json`, `custom-sources.json`, `release-cache.json`, `history.json`; bundled `catalog.json` (built-in entries); `Caches/Isotope/isos/<sha256-or-name>.iso` + `cache-index.json`.

## 4. Key components

### 4.1 VersionProvider protocol
```swift
protocol VersionProvider {
    func fetchLatest(config: ProviderConfig) async throws -> Release
}
```
Four implementations mapping to PRD §5 (`ChecksumFileProvider`, `GitHubReleasesProvider`, `StaticURLProvider`, `PageScrapeProvider`) plus `WindowsInfoProvider`. All are pure network+parse (no UI, no disk) → unit-testable with fixture data. Shared helpers: version regex extraction → `VersionToken`, HTML anchor extraction (lightweight regex over `href=` attributes — no HTML parser dependency), checksum-line parsing (`<hash>  <filename>` and `SHA256 (<file>) = <hash>` formats).

**Built-in catalog wiring (all use the generic providers):**
| Entry | Mechanism |
|---|---|
| Ubuntu Desktop (LTS/Latest) | checksumFile on `releases.ubuntu.com/<series>/SHA256SUMS`; series resolved from `changelogs.ubuntu.com/meta-release` |
| Fedora Workstation | Fedora's `releases.json` endpoint (small dedicated parser, same protocol) |
| Debian netinst/DVD | checksumFile on `cdimage.debian.org/debian-cd/current/...SHA256SUMS` |
| Arch | `archlinux.org/releng/releases/json/` |
| Mint / openSUSE / Pop!_OS | checksumFile or pageScrape on their stable "current" URLs |
| SystemRescue / GParted / Clonezilla / Memtest86+ | gitHubReleases or checksumFile |
| Tails | Tails' published JSON (`tails.net/install/v2/…`) |
| Windows 11 | windowsManual (PRD §5.4) |
Exact URLs are data in `catalog.json`, verified at build time; format drift is fixed by editing JSON, not code (BRD risk #1).

### 4.2 CatalogService (actor)
Merges bundled + custom entries; runs checks (`TaskGroup`, per-source 15 s timeout, failures isolated per PRD F14); caches `Release`s with `checkedAt`; publishes results to `AppStore`. Triggers: launch, manual, 6 h timer, drive-mount (checks only that drive's entries if cache is stale).

### 4.3 DriveMonitor
`NSWorkspace.shared.notificationCenter` mount/unmount notifications + initial enumeration of `/Volumes`. Resolves volume UUID via `URLResourceValues.volumeUUIDString`. Matches against `ManagedDrive.volumeUUID`; UUID mismatch on a bookmark-resolved volume → "drive changed" state (PRD F4). On mount of a managed drive: start bookmark access, scan ISO folder (F7), reconcile assignments (match filenames against each entry's known filename patterns), report staleness → NotificationService.

### 4.4 DownloadManager (actor)
`URLSession` download tasks; resume data persisted to disk on failure/quit (PRD F19); max-2 semaphore; progress via delegate → `AppStore`. On completion: stream-hash with `CryptoKit.SHA256` (incremental, memory-safe for 6 GB files), compare to `Release.sha256`, move into cache, update LRU index, evict beyond cap. Cache hit check by (URL, sha256) before downloading (F20).

### 4.5 UpdateEngine (actor)
Orchestrates one `UpdateOperation` per confirmed assignment:
1. Resolve target drive path via bookmark (`startAccessingSecurityScopedResource`).
2. Free-space pre-flight: `volumeAvailableCapacityForImportantUsage` + reclaimable old ISO size (F18).
3. Ensure ISO in cache (delegate to DownloadManager).
4. Copy to drive as `.<name>.iso.part`, then atomic-ish rename to final name (F25). Copy uses chunked streaming with progress.
5. Delete old ISO (unless keepOldVersions).
6. Update `Assignment.installed`, append history, notify completion.
Failure at any step rolls back the `.part` file and surfaces a typed `UpdateError` with the PRD's actionable messages.

### 4.6 NotificationService
`UNUserNotificationCenter`; permission requested on first drive registration (in context, N2). One notification per drive-connect summarizing available updates (F16); action deep-links to the drive via `AppStore.selectedDrive`.

## 5. UI design

`NavigationSplitView`, standard macOS styling (no custom chrome).

- **Sidebar:** Drives (with per-drive status dot: green up-to-date / orange N updates / grey disconnected), Catalog, Activity, Settings.
- **DriveDetailView:** header (name, capacity bar, connected state, Eject) · assignment list rows: entry icon, name+channel, installed version → latest version, per-row Update button or ✓ · "Update All" when >1 stale · Add Assignment (picker over catalog) · drive settings (folder, keep-old).
- **CatalogView:** grid/list of entries with latest version + checked time; built-in vs custom sections; "+ Custom Source".
- **CustomSourceSheet:** name, mechanism picker (segmented, with one-line explanation each — PRD §5), mechanism-specific fields, **Test** button showing the live parse result (resolved version, filename, hash found?) before Save (F10).
- **ActivityView:** in-flight operations with progress/pause/cancel; history list below.
- **Empty states:** first-run guidance (PRD §7 step 1).

## 6. Edge cases & policies

| Case | Behavior |
|---|---|
| Drive unplugged mid-copy | Operation fails cleanly; `.part` file abandoned on drive is deleted on next connect |
| App quit mid-download | Resume data persisted; offered on relaunch |
| Checksum mismatch | Discard file, keep resume-less retry available, actionable error (F25) |
| Two drives need same ISO | Single download, two copies (F20) |
| Custom source regex matches nothing | Test button and check status show "no match" with the fetched context snippet |
| Same entry assigned twice to one drive | Prevented at assignment time |
| Drive full even after reclaiming old ISO | Pre-flight fails with exact shortfall figure |
| Volume is not writable / read-only mount | Detected at pre-flight; surfaced clearly |

## 7. Testing

- **Unit (XCTest):** version parsing/comparison table tests; each provider against bundled fixture files (checksum files, GitHub API JSON, HTML listings, Fedora/Arch/Tails JSON); checksum-line parser formats; LRU cache eviction; free-space math; assignment reconciliation from a fake file listing.
- **Integration (manual script):** a `make`-style checklist against a real Ventoy stick covering PRD §7.
- **Network fixtures over live tests:** CI-safe; live endpoint verification is a separate developer script (`Scripts/verify-catalog.swift`) run when editing `catalog.json`.

## 8. Build plan (execution phases)

1. **Skeleton:** Xcode project, entitlements, data models, JSON persistence, AppStore, navigation shell.
2. **Catalog & providers:** provider protocol + 4 implementations + tests + `catalog.json` with verified URLs; CatalogView; CustomSourceSheet with Test.
3. **Drives:** DriveMonitor, registration/bookmarks, scan & reconcile, DriveDetailView.
4. **Pipeline:** DownloadManager (resume, hash, cache), UpdateEngine, ActivityView, notifications.
5. **Polish:** empty states, settings, history, edge-case passes, PRD §7 acceptance walkthrough.

Each phase compiles and is demoable on its own; Opus 5 agents execute phases sequentially with review between phases.

## 9. v1.1 addendum — flashing (implements PRD §8)

### Entitlements change
`com.apple.security.app-sandbox` is removed (raw device access is incompatible). Keep hardened-runtime-compatible code; keep bookmark code paths (harmless, no longer required). Downloads entitlement becomes unnecessary; plain file access suffices.

### Model changes (IsotopeCore — stays Foundation-only)
- `ManagedDrive.kind: DriveKind` (`ventoy` / `flashed`, default `ventoy` on decode for migration of existing drives.json).
- `ManagedDrive.hardwareID: HardwareID?` — struct of USB `vendorID`, `productID`, `serialNumber` (serial may be absent → fall back to vendor+product+capacity heuristic and mark identity "weak" in UI). Primary identity for flashed drives (PRD F27); Ventoy drives keep volume-UUID identity.
- Flashed drive invariant: exactly one `Assignment`; enforced at model level (helper) and in UI.
- Flash eligibility on `CatalogEntry`/`ProviderConfig`: `windowsManual` ⇒ not flashable (PRD F32).

### App-layer components
- **DeviceEnumerator** (app): lists candidate physical devices via DiskArbitration/IOKit — BSD name (`diskN`), whole-disk only, `deviceInternal == false`, removable/USB protocol, size, vendor/product/serial, current volume label(s). Also maps a `HardwareID` → currently attached `diskN`, and detects attach/detach (feeds DriveMonitor for flashed drives, which have no mounted-volume requirement).
- **FlashEngine** (actor, app): pipeline per PRD F29 —
  1. Safety gates (re-run at flash time, not just registration): external, removable, USB, not boot disk (`diskN` of `/`), attached, `deviceSize ≥ isoSize`. Typed `FlashError` per gate.
  2. Confirmation is collected by UI beforehand; engine asserts a fresh confirmation token.
  3. `diskutil unmountDisk force? no — plain unmountDisk` via `Process`, parse exit.
  4. Acquire fd: spawn `/usr/libexec/authopen -stdoutpipe -o <O_WRONLY> /dev/rdiskN` style invocation — receive the file descriptor over the socketpair (SCM_RIGHTS). macOS shows the admin auth prompt. Wrap in `AuthopenClient` with a small C-shim-free Swift implementation (CMSG parsing via `recvmsg`).
  5. Stream-write cached ISO → fd in 4 MiB chunks aligned writes; hash while writing; progress (bytes, speed, ETA) → AppStore operations list (reuse `UpdateOperationState` phases; add `.flashing`, `.verifyingDevice`).
  6. Read-back verify (default on, `AppSettings.flashVerification`): reopen device read-only via authopen (or reuse fd if seekable — reopen is cleaner), read written byte count, SHA-256, compare to ISO hash.
  7. `diskutil eject` (or remount to read new volume UUID first: mount → read `volumeUUIDString` → record → optional eject per F23-style offer).
  8. Update `ManagedDrive` (new volumeUUID, `installed` version, `placedByApp: true`), append `HistoryEvent`, notify.
- **Failure handling**: device detached mid-write (write returns ENXIO/EIO) → clean fail, actionable message, drive marked "flash failed — reflash required" state (the stick is in an undefined state; staleness shows as such). Verify mismatch → same state + suggest retry/replace stick.
- **UI**: registration sheet gains kind picker; flashed-drive registration lists DeviceEnumerator candidates (name, size, label). Flashed `DriveDetailView`: single assignment, device info, "Flash update" (or "Flash now" when never flashed) → confirmation dialog naming device + size + "erases everything on it", then admin prompt appears during pipeline. Assignment picker filters non-flashable entries.
- **Testing**: safety-gate logic, HardwareID matching/fallback, flash-state machine with a fake device writer (protocol over the fd operations), chunk/hash math — all unit-testable without hardware or root. `AuthopenClient` gets a manual integration path only (documented in code); never invoked in tests.

### Explicitly not done
No auto-flash ever (PRD F30); no internal-disk override; no Windows flashing (F32); no persistent privilege (each flash re-prompts).

## 10. v1.6 addendum — exact Windows builds (implements PRD F46)

### Split, as usual, along the portability line
- **IsotopeCore — `WindowsImageReader`** owns the format and no I/O: `xmlResource(header:)` reads the 208-byte `WIMHEADER_V1_PACKED` and returns the (offset, size) of the XML resource; `decodeXML` handles UTF-16LE + BOM; `identity(xml:)` regex-extracts `<BUILD>`/`<SPBUILD>` (highest across images — a multi-edition ISO carries one `<IMAGE>` per edition) and `<EDITIONID>`s. The caller supplies bytes, which is what makes it testable from a synthetic 208-byte header instead of a 6 GB ISO, and portable to a Linux loop mount later.
- **App — `WindowsISOInspector`** is the platform glue: `hdiutil attach -readonly -nobrowse -noverify -noautoopen -plist`, locate `sources/install.{wim,esd,swm}` case-insensitively, two bounded reads, `hdiutil detach`. Reachable through `DriveProbe.windowsBuild`, so app tests answer it without a mount.

Refusals are structural, not stylistic: a non-WIM magic, a compressed XML resource (never seen in Microsoft's media, and this reader implements no decompressor), a resource larger than 16 MiB or an offset inside the header all return nil rather than a guess.

### Model
- `InstalledISO.build: String?` — the build the image on the drive recorded inside itself; `displayVersion` renders "25H2 (build 26200.6584)". Optional, so `drives.json` written before this loads unchanged.
- `Release.build: String?` replaces the stored `displayDetail`, which becomes computed. Structured because it is now compared, not just printed; a stale `release-cache.json` simply loses the detail until the next check.
- `Staleness.buildBehind`, with `needsUpdate == false` and `isCurrent == true`. The build comparison only runs once the release comparison came out level, and only when both sides have a `.semantic` build — feature release and build number remain different namespaces (F43).

### Scheduling
`refreshWindowsBuilds(driveID:)` runs after `scanAndReconcile` and after a placement. It filters to `kind == .windows` assignments with an installed file and no recorded build, skips any (assignment, file) already attempted (`AppStore.windowsBuildAttempts`), and does the mount in a detached utility-priority task. The write back to the drive re-checks that the file it read is still the installed one — an unplug or an update between mount and answer must not stamp a build onto a different ISO.

## 11. v1.6.1 addendum — discard after placement (implements PRD F47)

- **`ISOCache.discardIfUnused(key:)`** — removes the artifact from the index and deletes the file, refusing while `holds[key]` exists, and taking a parent archive with it when nothing else derives from it. Returns bytes reclaimed.
- **`DownloadManager.endUse(cacheKey:discard:)`** — release the hold, then (when asked) discard. Releasing is already the moment the file becomes deletable, so it is the natural place for the decision. The `ISOProviding` protocol carries the `discard` flag so `UpdateEngine` can be tested against a fake.
- **`UpdateEngine.queuedCacheKeys`** — a counted set of the cache keys the queue still has work for, incremented at `enqueue` (the key is derivable from the release before the operation runs) and decremented when each operation ends. `shouldDiscard` requires the count to be ≤ 1, which is what stops the first of two sticks from deleting the ISO the second is queued for.
- **`FlashEngine`** sets `flashed = true` only on the success path; the `defer` reads it when it fires, so a failed flash keeps its download.
- **`AppSettings.discardAfterPlacement`** defaults to `true`; `AppStore.discardsCacheAfterPlacement` exposes it to the two actors, which cannot touch the `@MainActor` store's properties directly.

`PlacedISO.reclaimedCacheBytes` carries the freed size back to the store for the history line, so the deletion is reported rather than merely done.

## 12. v1.7 addendum — media revisions and request coalescing (implements PRD F48–F50)

### Core
- **`WindowsMediaName`** — the release/revision pair out of a `ProductDisplayName` (`Windows 11 25H2__V2`, `Windows 10 22H2_v1` — the separator differs by product) and the revision out of a filename (`…_x64v2.iso` → 2, no suffix → 1, anything not Microsoft-shaped → nil). The release pattern deliberately uses a lookbehind rather than `\b`: an underscore is a word character, so `\b` would refuse to match `25H2__V2` at all.
- **`WindowsMediaCatalog`** — `url`, `productEditionID` (3321 / 2618, renumbered every feature release, hence data), `language`, `profile`. Builds the request and reads the SKU response. Attached to `ProviderConfig.windowsManual` as `mediaCatalog`.
- **`Release.mediaRevision`**, `Release.displayRelease` ("25H2 v2"), `InstalledISO.mediaRevision` derived from the filename. `Staleness` compares revisions only after the releases come out level, and returns `.stale` — the build check that follows still yields `.buildBehind`.
- **`CoalescingHTTPClient`** — actor wrapping any `HTTPClient`; in-flight coalescing plus a 120 s success-only memory, keyed by (method, URL, headers). `VersionResolver(http:coalescing:)` wraps by default; provider tests that count requests pass `coalescing: false`.

### App
- **`WindowsDownloadResolver`** — the F49 attempt: session registration, SKU lookup, link request. The response is mined for an `https://…​.iso` value and a 64-hex sibling **by shape, not by key name**, because Microsoft has renamed those fields more than once and a hard-coded key fails silently the day it changes. A rejection payload contains neither and falls out as nil with no special-casing.
- **`AppStore.resolveWindowsDownload(for:)` / `startResolvedWindowsDownload(_:for:)`** — patches the resolved URL/name/checksum into the release and enqueues an ordinary update; nothing downstream is special-cased. `WindowsManualSheet` runs the attempt on appear and shows one of three states.
- **`AppSettings.attemptWindowsAutoDownload`** (default false); `CatalogService.check` resets the coalescing memory before a sweep.

### A concurrency note worth keeping
`UpdateEngine.shouldDiscard` (F47) reads the setting *before* releasing the operation's claim on a cache key. Awaiting the main actor between the release and the check let two drives finishing the same ISO both release, both resume, and both conclude they were last — deleting a file the other still wanted. Claims are also registered for the whole batch up front, because `beginOperation` suspends and the first operation could otherwise finish before the second was counted. Both were caught by a test that failed one run in three; the fix is ordering, not retries.

## 13. v1.7.1 addendum — observable settings, a visible attempt (implements PRD F51–F53)

`AppSettings` is now an `@Observable final class`. The macro instruments *stored* properties only, and every property here is computed over `UserDefaults`, so each one calls `access(keyPath:)` in its getter and `withMutation(keyPath:)` in its setter by hand — that is what makes a read inside a view body register a dependency. All of its readers are already on the main actor (`AppStore` is `@MainActor`; the two engines go through `AppStore.discardsCacheAfterPlacement`), so the reference type costs nothing in isolation.

`AppSettingsObservationTests` asserts the observation itself with `withObservationTracking`, not the storage — storage was never the part that broke.

`WindowsDownloadResolving` returns `WindowsDownloadAttempt` (`.resolved` / `.refused(String)` / `.failed(String)`) instead of an optional. The distinction is the feature: a refusal is Microsoft saying no and is expected, a failure is everything else, and an optional could express neither. `WindowsDownloadResolver.refusal(in:)` lifts `Errors[].Value` out of the payload so the UI quotes rather than paraphrases.

`AppStore.attemptWindowsDownload(entryID:channelID:)` is the seam Settings' Test button uses — no drive, no assignment, and no dependence on the setting being on.

## 14. v1.8 addendum — ISO sizes (implements PRD F60)

`DriveAccess.isoSizes(inFolder:)` reads `.fileSizeKey` from the same directory enumeration the listing walks, and `isoSizes(bookmark:isoFolder:)` wraps it in the security scope. It is exposed as its own `DriveProbe` member rather than by widening `listISOs` to return pairs: the existing seam — and every test that injects it — stays exactly as it was, and a probe that cannot read sizes reports none instead of failing.

`AppStore.isoSizes[driveID]` is written by `apply(_:to:)` alongside `unknownISOFiles`, so it is refreshed by every scan and dropped with the drive. `isoSize(fileName:on:)` is the single read the views use; `isoSizeText` in `DriveDetailView` renders " · 8.47 GB" or nothing at all.

## 15. v1.8.1 addendum — same-name replacement (implements PRD F61)

In `UpdateEngine.place`, `installedName` (what is on the drive), `oldName` (what is deleted afterwards — nil when it shares `finalName`) and `replacedURL` (what may be freed beforehand — nil only when the drive keeps old versions) are three separate derivations of one file. They were one, which is why a same-named replacement reported a shortfall equal to the size of the file it was replacing.

The early delete now targets `replacedURL`. Its input is always the cache or the user's Downloads folder, never the drive file, so removing it cannot take the copy's own source with it. `oldName` still drives both the post-copy delete and F35's retained pin, which is what an existing test caught when the first attempt collapsed the two.
