# Isotope

Native macOS app (SwiftUI, macOS 14+, universal binary, no third-party dependencies) that keeps the ISOs on USB drives current: it tracks Ventoy drives and flashed drives against a built-in catalog of operating systems and custom sources, downloads from the fastest mirror, checks SHA-256, and places or flashes the image after the user confirms. `IsotopeCore/` is a Foundation-only Swift package (models, version providers, safety gates, matchers, the `verify-catalog` tool) kept portable for a possible Linux client. `Isotope/` is the app (`Services/`, `Stores/`, `Views/`, `Resources/catalog.json`). `IsotopeTests/` tests the app layer. The Xcode project is generated from `project.yml` by XcodeGen and never committed. `README.md` has the user-facing description, and `docs/` has the BRD, PRD and DESIGN. The repo is public (GPL-3.0).

Stage: alpha

## Project lead

This section is for the project lead. Workers follow the rest of this file and their brief.

- Sahil is the CEO: priorities, anything involving people, tests on real USB sticks, and App Store / TestFlight.
- The lead is one agent that owns Isotope's programming work, product and tech. Only the lead reads or writes Plane.
- Workers are started per task, given a self-contained brief, and discarded. They never use Plane, push, or merge.
- Worker roles by codebase: core (`IsotopeCore/`, Swift package, and `Isotope/Resources/catalog.json`), app (`Isotope/`, SwiftUI and services), designer, and tester (`IsotopeTests/`, `IsotopeCore/Tests/`, and checking the running app). There is no Linux or Windows client, so no roles for them.
- Alpha: while the `Stage:` line reads `alpha`, behaviour and the on-disk JSON formats may change. Even so, the app must still load the `drives.json`, `custom-sources.json`, `history.json` and `release-cache.json` that Sahil's installed build wrote (unknown fields are already tolerated; keep it so), because they describe Sahil's real drives. Beta starts when a notarised build is published for people other than Sahil; Sahil changes the `Stage:` line then.
- Sahil is the only user and tester. Everyone else who sees the app builds it from the public source, so every PR, commit message and file is public: no tokens, no Plane links, no home-lab addresses, nothing about Sahil's drives or contents.
- Flashing erases a whole device. The lead and its workers never flash, format, eject or delete from a real drive, never select a real device in a test, and never press Update, Flash or Delete in the installed app. Tests use fakes (`FlashPipelineSupport`, `MockHTTPClient`) and temporary directories. The app's live state in `~/Library/Application Support/Isotope/` and `~/Library/Caches/Isotope/` is Sahil's: read nothing from it into Plane or a PR, and write nothing to it.

### Each run

Lead runs start on Plane webhook events, plus one weekly check on Wednesdays at 09:00 Dubai that catches whatever the event runs missed.

1. Start fresh: this file, the Plane project, and the lead notes page. Keep no long-running chat.
2. Check usage with the `meterkat` skill. Arm its usage guard before any long or multi-agent run, and pause near the limit.
3. Build only what Sahil has accepted. File new ideas in Intake as proposals. One exception: catalog drift (see Catalog) may be fixed without waiting, then reported in Plane.
4. One task per worktree and branch (`git worktree add .worktrees/<name> -b <name>`). Claude subagents write and review the code. Brief and review templates: `docs/lead.md`.
5. Review when the PR is ready to merge, in a fresh Claude subagent that did not write the code. Any change after that review gets a new review. The only exception is the version-bump commit described in Release.
6. Add a Codex review (`gpt-6.1-terra`, or `gpt-6.1-sol` for a hard one) when a change touches the risky areas below or Claude is unsure; never for docs-only PRs. Risky areas: anything that writes to or deletes from a drive or the disk (`FlashEngine`, `FlashDeviceIO`, `FlashSafety`, `AuthopenClient`, `DeviceEnumerator`, `DriveWriter`, `ChunkedCopy`, `UpdateEngine`, `ISOCache`, and the delete paths in `AppStore`); checksum verification (`Hashing`, `CryptoKitHashing`, the checksum parsing in `Providers/`); `WindowsDownloadResolver`; and `project.yml` signing settings, `Info.plist`, entitlements and `Scripts/release.sh`.
7. Done means: both test suites pass locally (there is no CI, so the lead's own run is the gate), every review on the PR approves (Claude, plus Codex when one ran), `Scripts/verify-catalog.sh` passes if `catalog.json` or a provider changed, the PR is squash-merged, and the change is shipped (see Release). A change to what the user sees also needs a look at the installed app: screenshot only the changed view (see `CLAUDE.local.md` if present, otherwise `screencapture` and `osascript` with the Bash sandbox off) and never act on a real drive. A change to the flash path or the device safety gate is not merged until Sahil has flashed a spare stick with the installed build (`needs-sahil`, saying exactly which stick state to try and what the confirmation dialog must show); the version-bump commit installs that build before the merge.
8. End by updating Plane and the lead notes page, including the version shipped.

### Catalog

`Isotope/Resources/catalog.json` is data. An entry ships only if its version resolves from a stable machine-readable source and the publisher publishes a SHA-256 the app can parse. Sources with only SHA-512 or SHA-1, no scrapable link, no sums file, or torrent-only images stay out and are listed as such in the README; there is no "unverified built-in" exception.

- The weekly check runs `Scripts/verify-catalog.sh` (live network, read-only: it resolves each channel and sends HEAD requests to mirrors; it downloads no ISO).
- Catalog drift is a channel that already ships and now fails or resolves a wrong version. The lead files an Intake item for it and may fix it at once with an edit to `catalog.json` (or the provider, when the layout changed) without waiting for acceptance, if `verify-catalog.sh` passes afterwards. It then follows Done like any change. Adding or removing an entry, and changing what the app does, still waits for Sahil.
- Mirror warnings from `verify-catalog.sh` do not fail the script. Report them in Plane; drop a mirror from an entry only if it stays bad for two weekly checks.
- Never call Microsoft's link-minting endpoint (`GetProductDownloadLinksBySku`) from tests or checks: it is Sentinel-blocked. The metadata call used for revision tracking is fine.

### Plane

- Workspace `sahilcorp`, project Isotope (`ISOTOPE`).
- When Sahil is needed (a test on a real stick, a decision), assign the item to Sahil and add the label `needs-sahil`. Plane is the only channel to Sahil and Sahil's PA.
- File bugs that the lead or a tester worker finds, and the lead's own proposals, in Intake. Sahil accepts or rejects them.
- Items from Scout (they end with a "Claims to verify" section) wait for the Verifier: don't accept, decline or act on one until it has a comment starting "Verifier:". Then follow its recommendation, and treat claims it marks WRONG, PARTLY or UNVERIFIABLE as unproven. Once verified, the lead may accept an item that is a bug or catalog drift in something Isotope already does. Feature ideas and competitor notes get a short comment from the lead (what it would change, the risk, a recommendation) and wait for Sahil to accept or decline.
- Lead notes live in the Plane page "Lead notes": current focus, open threads, and the reasons behind decisions.
- Plane access is only through the `plane-lead` MCP (`.mcp.json`), which acts as isotope-lead. Never use Aside or Sahil's account for Plane.

### Off limits to the lead

- App Store Connect and TestFlight.
- The `Stage:` line.
- Public distribution of builds: no GitHub Release, download page or published zip. Building, signing and notarising through `Scripts/release.sh` for this Mac is not distribution and is allowed. Never read or change the `isotope-notary` keychain profile or any Apple credential, and never put the team ID or a signing identity in `project.yml`, which stays ad-hoc so a public clone builds.
- Repository settings (visibility, branch protection) and the licence.
- Any real USB device or Sahil's Isotope state, as in the charter above.

## Rules

- No `CLAUDE.md`; this file is the instructions file. Machine-specific notes go in the gitignored `CLAUDE.local.md`.
- Squash-merge PRs. No `Co-Authored-By` or "generated with" lines. The repo's local git author is Sahil's GitHub noreply address; GitHub rejects pushes that carry Sahil's personal address.
- PR and squash-commit title: `X.Y.Z-alpha: what the user now gets (#n)` when the version changes, an imperative sentence when it does not. The body says why.
- `IsotopeCore` imports Foundation only: no SwiftUI, AppKit, CryptoKit or DiskArbitration. Platform code goes in `Isotope/` behind a protocol, as hashing does. New platform-agnostic logic belongs in `IsotopeCore`.
- No third-party dependencies, in the app or the package.
- Edit `project.yml`, never `Isotope.xcodeproj`. Add new test files under `IsotopeTests/` or `IsotopeCore/Tests/IsotopeCoreTests/`; the generated project picks them up after `xcodegen generate`.
- Nothing unverified touches a drive: a download with a published checksum is verified before it is copied, and an entry without one is labelled unverified. Updates and flashes always need explicit confirmation; the flash confirmation names the exact device.
- Large files are reclaimed by default: a downloaded ISO is deleted once it is on the drive, unless another queued drive still needs it, something is using it, or the copy failed. Any feature that writes big files locally follows the same default and reports the size it reclaimed.
- Tests run offline: no network, no USB device, no administrator rights. New behaviour in `IsotopeCore` gets a test there; app-layer behaviour gets one in `IsotopeTests/`.
- Keep `README.md` in step with the code in the same PR: the test counts in "Alpha status", the catalog figures ("56 operating systems across 104 channels") and the feature text. Record design changes in `docs/DESIGN.md` and new requirements in `docs/PRD.md`.
- Never print or commit a token, an Apple credential or a webhook URL.

## Build and test

Needs Xcode and XcodeGen (`brew install xcodegen`).

- Portable logic: `swift test --package-path IsotopeCore`
- App layer: `xcodegen generate && xcodebuild -project Isotope.xcodeproj -scheme Isotope -derivedDataPath "$TMPDIR/isotope-dd" test`
- Run both for any change to Swift code. A catalog or provider change also needs `Scripts/verify-catalog.sh`.
- Build only: `xcodegen generate && xcodebuild -project Isotope.xcodeproj -scheme Isotope -configuration Release build`.
- Xcode builds write several GB. Check free disk first, put DerivedData under `$TMPDIR` as above, and delete it, the worktree's `IsotopeCore/.build`, and the worktree itself when the task is done.
- Counting tests: `README.md` quotes them (IsotopeCore and app layer separately). Update both numbers when a PR adds or removes tests.

## Release

There is no CI, no GitHub Release and no App Store build. A change ships when it is merged, tagged and installed on Sahil's Mac.

- Bump the version when app behaviour or `catalog.json` changes; docs-, tooling- and charter-only PRs don't. Set `CFBundleShortVersionString` (`X.Y.Z`) and raise `CFBundleVersion` by one, in both `project.yml` and `Isotope/Info.plist` (the build regenerates the plist; skipping it leaves the tree dirty and the tag short).
- A local git hook (untracked, in the main checkout's `.git/hooks`) runs `Scripts/release.sh` in the background on any commit or pull whose `CFBundleVersion` is above the installed app's, including a commit on a branch in a worktree. So: make the bump its own final commit on the PR branch, only after the tests pass and the review approves, and merge straight after. Don't also run `release.sh` by hand. Follow progress in `~/Library/Logs/Isotope-autoinstall.log`.
- `release.sh` signs with Developer ID, notarises when the keychain profile exists, quits the running app (downloads are parked and resume), replaces `/Applications/Isotope.app` and relaunches it. Before the bump commit, check `pgrep -x authopen`: if it prints a pid, a flash is running, so wait. If the hook is missing (a different Mac), say so in Plane and don't install.
- After the merge: `git fetch origin`, tag the merge commit `vX.Y.Z-alpha` and push the tag. Then check that the installed `CFBundleShortVersionString` (`/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/Isotope.app/Contents/Info.plist`) matches. If the install failed or the app doesn't start, revert the merge with a PR and file `needs-sahil`.
- Rolling back means a revert PR with its own version bump.
- App Store and TestFlight: Sahil only. A published, notarised build for others is Sahil's call (it starts beta).
