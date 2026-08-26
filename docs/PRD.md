# Product Requirements Document — Isotope

**Version:** 1.0 (draft for approval)
**Depends on:** BRD.md (scope), DESIGN.md (technical design)

## 1. Product summary

Isotope is a windowed native macOS app (SwiftUI) that manages a set of registered Ventoy USB drives, each with assigned operating-system ISOs, and keeps those ISOs at the latest version: check → notify → confirm → download → verify → copy.

## 2. Core concepts

- **Catalog entry** — a trackable ISO source: e.g. "Ubuntu Desktop LTS", "Fedora Workstation", "SystemRescue", or a user-created custom source. Knows how to answer: *what is the latest version, where is the ISO, what is its SHA-256?*
- **Channel** — a variant within an entry where relevant (Ubuntu: *LTS* vs *Latest*; Debian: *netinst* vs *DVD*).
- **Release** — a concrete resolved version: version string, ISO URL, file size, SHA-256 (when available), release date.
- **Managed drive** — a registered USB volume (identified by volume UUID) with a list of **assignments**.
- **Assignment** — (drive, catalog entry, channel) plus what's currently installed: filename and version.

## 3. User stories

1. As a user, I register a plugged-in Ventoy drive and assign "Ubuntu LTS", "Fedora Workstation", and "SystemRescue" to it.
2. When I open the app, it checks all tracked entries and shows me which drives/ISOs are stale.
3. When I plug in a registered drive and an update is known, I get a macOS notification; clicking it opens the app ready to update.
4. I confirm; the app downloads the ISO (resumable, verified), copies it to the drive, removes the old one, and tells me when it's safe to eject.
5. I add a custom source for an ISO the catalog doesn't know, picking one of the supported detection mechanisms, and it behaves like a built-in entry.
6. I remove a drive or an assignment at any time; the app never touches files it didn't place (except the specific old ISO it's replacing, with confirmation).

## 4. Functional requirements

### 4.1 Drive management
- **F1** Register a currently-mounted volume as a managed drive via a standard open panel (grants sandbox access; stored as security-scoped bookmark). App records volume UUID, name, capacity.
- **F2** Show all managed drives with status: connected / not connected, last seen, up-to-date / N updates available / unknown.
- **F3** Detect mount/unmount of managed drives live while the app runs.
- **F4** Warn (not fail silently) when a mounted volume's UUID no longer matches a registration (reformatted drive).
- **F5** Unregister a drive (removes tracking only; never deletes files).
- **F6** Per-drive setting: ISO destination folder on the drive (default: root); on update, **replace** old ISO (default) or **keep** old versions.
- **F7** Scan a registered drive's ISO folder on connect and reconcile: recognize assigned ISOs by filename pattern, flag unknown/missing files informationally.

### 4.2 Catalog
- **F8** Built-in catalog (data-driven, bundled JSON) covering at minimum:
  - **Linux:** Ubuntu Desktop (LTS + Latest channels), Fedora Workstation, Debian (netinst + DVD), Arch, Linux Mint (Cinnamon), openSUSE Leap, Pop!_OS.
  - **Tools/rescue:** SystemRescue, GParted Live, Clonezilla Live, Memtest86+, Tails.
  - **Windows:** Windows 11 (and Windows 10 while Microsoft publishes it) — see §5.4 for the download caveat.
- **F9** Each built-in entry shows: name, logo/glyph, channels, latest known version, release date, ISO size, link to project page.
- **F10** User can create, edit, delete **custom sources** (§5) with a "Test" button that runs the check immediately and shows the parsed result before saving.
- **F11** Assignments reference catalog entries; deleting a custom source warns if assigned anywhere.

### 4.3 Version checking
- **F12** Check all entries: on app launch, on manual refresh, and on a timer while the app runs (default every 6 h, configurable).
- **F13** Checks are network-light: use JSON endpoints / checksum files / HTTP headers, never download the ISO to learn its version.
- **F14** Per-entry check status: OK (version + checked time), failed (with readable error), checking. A failing source never blocks other checks.
- **F15** Version comparison handles distro-style versions (24.04.3, 41, 12.7.0, 2026.08.01) with a documented normalization scheme; ETag-based sources compare by change-date instead (§5.3).

### 4.4 Update flow
- **F16** When a managed drive is connected and any assignment is stale → local notification ("Ubuntu 24.04.3 available for 'SanDisk 64GB'"). Clicking focuses the app on that drive.
- **F17** Updates always require explicit confirmation (per BRD decision). Batch confirmation allowed ("Update all 3").
- **F18** Download pipeline: download to local cache → verify SHA-256 against the source's published checksum → pre-flight free-space check on the drive (new ISO size vs free space + reclaimable old ISO) → copy to drive → verify copied size → delete old ISO (per F6) → mark assignment current.
- **F19** Downloads are resumable, show progress (speed, ETA), survive app relaunch (resume data persisted), and can be paused/cancelled. Max 2 concurrent downloads (configurable).
- **F20** Downloaded ISOs are cached; updating a second drive with the same ISO must not re-download. Cache is size-capped (default 20 GB, LRU eviction) and clearable in Settings.
- **F21** If no checksum is available for a source, the UI labels the ISO **unverified** at confirmation time; the user can proceed knowingly.
- **F22** Never modify the drive outside the configured ISO folder; only ever delete the specific old ISO being replaced.
- **F23** After updates complete, offer one-click eject (only if no operations are in flight).

### 4.5 Activity & errors
- **F24** Activity view: current downloads/copies with progress, plus a persistent history log (what was updated, when, on which drive).
- **F25** All failures produce actionable messages (e.g. "Checksum mismatch — the download was corrupted or the source's checksum file is stale. The file was discarded; try again.") and never leave a half-copied ISO on the drive (copy to temp name, rename on completion).

## 5. Custom sources — how version detection works

The open question from planning: *"maybe .iso urls? but how would we know what version it is?"* — answered by offering four mechanisms; the user picks one per custom source. Each built-in catalog entry internally uses the same mechanisms, so custom sources are first-class.

### 5.1 Checksum-file watch (recommended when available)
User supplies the URL of a `SHA256SUMS`-style file (nearly every distro publishes one at a stable URL, e.g. `.../current/SHA256SUMS`) plus a filename-match regex with a version capture group.
The app fetches the small text file, finds the matching line → gets **filename, version (from capture group), and SHA-256** in one request. Cheapest and most reliable; verification comes free.

### 5.2 GitHub Releases
User supplies `owner/repo` + an asset-name regex. The app uses the GitHub Releases API: version = release tag, ISO URL = matching asset, checksum = sibling `.sha256`/checksum asset if present.

### 5.3 Static URL + change detection
User supplies a direct `.iso` URL that stays constant but whose content changes (e.g. `.../latest/foo.iso`). The app sends a `HEAD` request and compares `ETag` / `Last-Modified` / `Content-Length`. There is no semantic version — the app displays the version as the change date ("updated 2026-08-02") and flags staleness when the header changes. No published checksum → downloads marked unverified (F21) unless the user also provides a checksum URL.

### 5.4 Page/directory scrape
User supplies a listing or download-page URL + a link-match regex with a version capture group (e.g. matching `ubuntu-(\d+\.\d+(\.\d+)?)-desktop-amd64\.iso`). The app parses anchors from the HTML, picks the highest version. Most fragile; the "Test" button (F10) makes the regex debuggable at creation time.

### Windows caveat
Microsoft's ISO download links are session-generated and expire; stable hotlinks don't exist. v1 behavior: the Windows entry **tracks** the latest build (via Microsoft's public release info) and shows staleness like any entry, but "Update" opens the official download page in the browser with instructions; once the user's download lands in a watched folder (~/Downloads), the app offers to verify (hash shown for manual comparison) and place it on the drive. Fully-automated fetch (Fido-style API dance) is a stretch goal, not a commitment.

## 6. Non-functional requirements

- **N1** Native SwiftUI, macOS 14+, universal binary. No Electron, no bundled runtimes.
- **N2** Sandboxed; drive access via user-granted security-scoped bookmarks; network client entitlement; notifications permission requested in context.
- **N3** No privileged helper, no kernel extensions (v1 never needs raw device access).
- **N4** Responsive under load: UI never blocks during downloads/copies/checks (all async).
- **N5** A full catalog check completes in < 15 s on a normal connection; individual source timeout 15 s.
- **N6** All state in `~/Library/Application Support/Isotope/`; cache in `~/Library/Caches/`. Human-readable JSON; no database server.
- **N7** No telemetry. Network calls only to ISO sources, checksum files, and the GitHub API.

## 7. v1 acceptance walkthrough

1. Fresh launch → empty state explains: register a drive, assign ISOs.
2. Plug in a Ventoy USB → register it → assign Ubuntu LTS + SystemRescue → app checks versions and shows both as "not installed / unknown" → scan recognizes an existing `ubuntu-24.04.1-desktop-amd64.iso` and records it as installed 24.04.1.
3. Catalog shows 24.04.3 as latest → drive shows "1 update" → confirm → download with progress → checksum verified → copied → old ISO removed → drive shows up-to-date → eject offered.
4. Add a custom source (SystemRescue via checksum-file watch) with Test → assign → behaves identically.
5. Quit, relaunch, replug drive later after a new release → notification arrives → flow repeats.

## 8. v1.1 addendum — flashed drives (approved 2026-08-17)

A **flashed drive** is a USB stick whose entire device is an ISO image (balenaEtcher-style), as opposed to a Ventoy drive holding ISO files. Updating one means re-imaging the whole device.

### Functional requirements
- **F26** A managed drive has a kind: `ventoy` (existing behavior) or `flashed`. Chosen at registration; a flashed drive has exactly **one** assignment.
- **F27** Flashed drives are identified by **hardware identity** (USB vendor/product/serial via IOKit), not volume UUID — flashing destroys and recreates the volume, so volume UUID cannot be the key. Volume UUID is re-recorded after each flash for informational display.
- **F28** Registration of a flashed drive: pick the physical device from a list of eligible external USB disks (name, size, current volume label); no folder/bookmark involved.
- **F29** Flash pipeline: download+verify ISO to cache (identical to F18) → safety gates (device is external, removable, USB-attached, not the boot/internal disk, still present, size ≥ ISO) → explicit confirmation dialog stating the device name/size and that **all data on it will be erased** → `diskutil unmountDisk` → open `/dev/rdiskN` write handle via `/usr/libexec/authopen` (macOS admin password prompt, per flash, no stored privileges) → stream-write in chunks with progress/speed/ETA → **read-back verification** (re-read written range, compare SHA-256; default on, Settings toggle) → eject or remount → update drive record (new volume UUID, installed version) → history entry.
- **F30** Staleness/notification/confirmation semantics are identical to Ventoy drives (F16/F17); the confirmation is never skipped for flashing regardless of any future auto-update setting.
- **F31** Safety: the app must refuse to flash any device that fails a safety gate, with the specific reason; a mid-flash device disappearance fails cleanly with an actionable message; the app never flashes without the F29 confirmation in the same session.
- **F32** Windows ISOs and any entry with no direct ISO (`windowsManual`) are **not flashable** — assignment pickers for flashed drives exclude them (plain dd of a Windows ISO does not produce a bootable stick).

### Consequence for the app
- The App Sandbox is removed (raw device access is incompatible with it). Security-scoped bookmark code remains but is no longer load-bearing. Distribution stays personal (Developer ID / from source).

## 9. v1.2 addendum — per-assignment update policy (approved 2026-08-17)

Lets some ISOs on a drive stay put while others track the latest release, including multiple versions of the same OS coexisting on one Ventoy drive.

- **F33** Each assignment has an **update policy**: `trackLatest` (default, existing behavior) or `keepAsIs` (pinned: never counted as stale, never updated, its file never touched; shown with a "Pinned" badge and its installed version).
- **F34** A drive may hold **multiple assignments of the same entry+channel** provided at most one of them is `trackLatest` (duplicate prevention relaxes accordingly). Reconcile must keep matching each assignment to its own recorded filename and never attribute one file to two assignments.
- **F35** In the update confirmation, each replaced ISO offers **"Keep current version on the drive as a pinned copy"** — instead of deleting the old file, the app converts it into a new `keepAsIs` assignment. This is the primary way multiple versions of one OS accumulate deliberately.
- **F36** "Update All", staleness counts, and drive-connect notifications consider only `trackLatest` assignments. Switching a pinned assignment back to `trackLatest` re-evaluates staleness normally.
- **F37** Flashed drives support the policy too (`keepAsIs` = never prompts to reflash); the single-assignment invariant is unchanged.

## 10. v1.3 addendum — catalog expansion, grouping, flash auto-detect (approved 2026-08-17)

- **F38** Catalog entries gain an **organization/family** (e.g. "Microsoft", "Ubuntu", "Linux Mint", "Fedora", "Arch", "Debian", "Tools & rescue"); the Catalog view groups by it. Flavours are entries within their family (Kubuntu under Ubuntu).
- **F39** Catalog expansion (every URL live-verified at build time, same rules as F8/F13): **Proxmox VE**; **Windows 10** (if Microsoft still publishes ISOs post-EOL — otherwise the entry states that honestly); **Ubuntu flavours** (Kubuntu, Xubuntu, Lubuntu, Ubuntu MATE); and a researched set of other major current distros (candidates: Kali, Manjaro, EndeavourOS, Zorin, elementary, MX Linux, Rocky, AlmaLinux, NixOS, openSUSE Tumbleweed — include those with stable machine-readable sources, note any excluded and why).
- **F40** **Flashed-USB auto-detect**: dd-flashed sticks retain their ISO's volume label. Entries may carry a `volumeLabelPattern` (regex, version capture group 1). During flashed-drive registration, the device list shows what each stick appears to contain and preselects the matching entry + installed version. On attach of a registered flashed drive whose label no longer matches its record (re-flashed elsewhere), update the installed version when parseable, else flag "contents changed". No admin privileges required (labels come from DiskArbitration; no raw reads).

## 11. v1.4 addendum — Ventoy content auto-detect + status-dot fix (2026-08-17)

- **F41** Ventoy scan auto-detect: unknown `.iso` files found on a registered Ventoy drive are matched against the catalog's filename patterns (same machinery as reconcile pass 2, across ALL entries, not just assigned ones). Recognized files are offered in the drive detail as "Found on drive: Ubuntu 24.04.1 — Track it?" with one-click assignment creation (policy chosen by the user: track latest, or keep-as-is pinned at the detected version). Unrecognized files remain listed informationally. Never auto-create assignments silently.
- **F42** Sidebar status dot (bug fix, refines DESIGN §5): grey strictly means *not connected*. A connected drive shows: orange when ≥1 tracked assignment is stale, green when connected and no tracked assignment is stale (including all-pinned or not-yet-checked states — with a "checking/unknown" affinity indicator acceptable but never grey while connected).

## 12. v1.5 addendum — version detection for Windows and flashed drives (2026-08-18)

Both fix "Unknown" staleness where a real comparison is possible.

- **F43** Windows entries track the **feature release** (22H2, 25H2), not the build number: that is the identity a bootable install ISO actually carries, and it is what Microsoft's filenames encode. `VersionToken` gains parsing for `NNHN` tokens so `25H2 > 22H2` compares correctly; the build number (19045.7663) stays as display detail only. Filename patterns capture the release token, so an adopted `Win11_25H2_English_x64_v2.iso` compares equal to the latest release.
- **F44** Flashed-drive **content probe**: after a flashed drive mounts, the app may read small marker files from the mounted (read-only) volume to determine the installed version — e.g. `/.disk/info` on Debian-derived images (Proxmox VE, Debian, Ubuntu), `/.treeinfo` or `/media.repo` on Fedora-family images. Catalog entries carry an optional ordered list of (path, regex with version capture). Read-only, no admin rights, no raw device access; failure is silent and falls back to the volume label (F40). Applies to Ventoy-hosted detection only where a file is genuinely readable — the probe is for flashed drives.

## 13. v1.6 addendum — catalog width and exact Windows builds (2026-08-20)

Both address the same complaint: the app knows less than the drive does.

- **F45** **Catalog expansion, second pass.** 26 entries / 37 channels was too narrow to be the "one place my sticks are tracked" the BRD asks for. The catalog grows to **56 entries / 106 channels**, every one of them live-verified by `Scripts/verify-catalog.sh` before it ships. New families: the remaining Ubuntu flavours (Budgie, Studio, Cinnamon, Unity, Kylin, Edubuntu), Mint MATE/Xfce and LMDE, Debian Live, six more Fedora variants plus a nine-channel Spins entry, CentOS Stream, the rest of the Proxmox family (Backup Server, Mail Gateway, Datacenter Manager), Manjaro, CachyOS, Alpine, Void, Gentoo, Qubes OS, Parrot OS, FreeBSD, GhostBSD and TrueNAS, plus Kali's live/purple/everything images, MX's KDE and Fluxbox spins and boot ISOs for Rocky and AlmaLinux.

  The admission rule is unchanged and is what bounds the list: an entry ships only if its version can be resolved from a stable machine-readable source **and** the publisher ships a SHA-256 the app can parse. Excluded for that reason, not for lack of demand: EndeavourOS and ShredOS (SHA-512/SHA-1 only), Zorin OS and elementary OS (no scrapable link), Devuan and Deepin (no parsable sums file), XCP-ng (no checksums published beside the ISOs).

- **F46** **Windows media reports its exact build.** F43 was right that the *comparable* identity is the feature release, but it left the row reading "25H2 → 25H2 (build 26200.9168)", which says nothing about the ISO on the drive: Microsoft reissues media under the same filename, so `Win11_25H2_English_x64.iso` may be any build of 25H2.

  Isotope now reads the build out of the image itself — the `<BUILD>`/`<SPBUILD>` pair in the XML resource of `sources/install.wim` (or `.esd`/`.swm`) — by mounting the ISO read-only. No administrator rights, no writes, and no guessing: an image that will not say is displayed as it was before. Both sides of the row then carry a build, and the comparison gains one state:

  - **`buildBehind`** — same feature release, older build on the drive. Displayed ("Newer build shipped"), and deliberately **not** counted as an update: Microsoft services Windows monthly but refreshes the download rarely, so a newer build often cannot be downloaded at all, and prompting for it would send the user to fetch the file they already have.

  Mounting a multi-gigabyte image is slow, so it runs after the scan, off the main actor, once per (assignment, file); a reconnect retries anything that could not be read.

## 14. v1.6.1 addendum — the cache stops hoarding (2026-08-21)

- **F47** **Delete a downloaded ISO once it is on the drive.** F20 gave the cache a 20 GB LRU cap, which means it happily sits at 19 GB of ISOs the user is already carrying on a USB stick. The cache exists to save a *second* download, not to keep a second copy of everything.

  New setting, **on by default**: as soon as an ISO has been copied to a Ventoy drive or flashed onto a device, its cached copy is deleted. When an ISO was extracted from an archive (Memtest86+), the archive goes with it.

  Three cases must not delete, and are tested as such:
  - **Something is still using the file.** The existing cache holds already forbid eviction under a running copy; discard respects them.
  - **Another queued operation needs the same ISO.** "Update All" across two sticks holding the same distro deletes only after the last one has it.
  - **The operation failed.** A failed copy or flash keeps the download, so a retry does not mean fetching several gigabytes again.

  Turning the setting off restores the F20 behaviour exactly: ISOs stay cached up to the limit. The reclaimed size is written into the history line ("…· freed 5.7 GB of cache") so the space going away is visible rather than mysterious. The Windows manual path is untouched — that file lives in the user's Downloads folder and is theirs, not Isotope's, to delete.

## 15. v1.7 addendum — Windows media revisions, an opt-in download attempt (2026-08-26)

Asked directly: can Windows be handled like Linux, without the manual download? The endpoints were tested against the live service before answering, and the answer is "partly, and here is exactly which part".

- **F48** **Track the media revision.** Microsoft reissues the media for a feature release without changing the release: 25H2 has shipped as the original ISO and again as `25H2__V2`. Their download connector answers `getskuinformationbyproductedition` to *any* client — no login, no fingerprint, one plain GET — with a `ProductDisplayName` naming both. Their own filenames carry the same thing (`Win11_25H2_English_x64v2.iso`, the original having no suffix), so both sides of the comparison have it.

  A newer revision is therefore a **plain update** (`.stale`), not the advisory F46 introduced: unlike a servicing build, a reissue is genuinely downloadable today. Precedence, highest first: feature release → media revision → servicing build. Where the file is not named the way Microsoft names its media, no revision is claimed, and nothing is inferred.

- **F49** **Opt-in automatic download, honest about its odds.** The sibling call that mints a real download link (`GetProductDownloadLinksBySku`) is guarded: it answers `"Sentinel marked this request as rejected"` to anything that does not look like a browser session. That is measured, not assumed — it refused a correctly sequenced, correctly headed request from an ordinary residential connection, twice, during development.

  So Isotope can *try*, behind a setting that is **off by default**. On, the hand-off sheet attempts the resolve and says which of the two things happened: "Microsoft answered — downloading …" or "Microsoft refused the automated request", with the manual steps right there underneath. A link that does come back carries its SHA-256, so a resolved download is verified like any other; the manual path is unchanged and remains the supported one.

- **F50** **One request per URL per check.** The catalog now has 106 channels and many of them legitimately share a URL — 24 Ubuntu-family channels behind two `changelogs.ubuntu.com` index files, 16 Fedora channels behind one `releases.json`, Kali's five images and Debian Live's six each behind a single `SHA256SUMS`. Fanning out one request per *channel* earned an HTTP 429 and reported six Ubuntu flavours as failing when nothing was wrong with them. Requests are now coalesced per (method, URL, headers) — in-flight requests join, successful answers are reused for 120 s, failures never are — and a user-initiated check clears that memory first.

## 16. v1.7.1 addendum — Settings that respond, and a way to see F49 work (2026-08-26)

- **F51** **Settings controls reflect what they do.** Every toggle and picker in Settings wrote its value straight through to `UserDefaults` and then carried on drawing the old one: the value changed, SwiftUI was never told, and the control snapped back. Reported as "toggling makes no difference", which is precisely what it looked like. `AppSettings` becomes an observable reference type so a control redraws when its own value changes. Nothing about the storage or the defaults moves.

- **F52** **"Test Now" for the Windows attempt (F49).** A setting whose whole point is that it may not work has to be able to say whether it works. Settings gains a **Test Now** button that runs the real attempt against the first Windows channel in the catalog — the same code path an update takes — and reports one of three outcomes, quoting Microsoft where they said anything:
  - *Microsoft answered with a link* — with the filename and whether a checksum came with it.
  - *Microsoft refused* — with their own words ("Sentinel marked this request as rejected."), and the note that downloads will use the browser instead.
  - *The attempt could not be made* — a network failure or a changed response shape, told apart from a refusal.

  It works with the setting off, because "does this work?" is the question you ask *before* deciding to turn it on. The hand-off sheet shows the same reason text instead of a bare "refused".

- **F53** **The pin button shows its action, not its state**, and says it once. An unpinned row drew `pin.slash` while its tooltip offered "Pin this version"; a pinned row drew `pin.fill` while offering to unpin. The icons are swapped so the button says what pressing it does.

  A pinned Ventoy row then said the same thing three times — "· kept as is" in the version line, a "Pinned" status label, and the button — so the status label is dropped for that state. The flashed-drive row keeps its label: there the pin control is a checkbox further down the panel, not an icon on the row, so the label is the only inline indicator.
