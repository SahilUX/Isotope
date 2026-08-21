# Isotope

**Alpha.** The shape is settled and the internals are covered by tests, but this has had one pair of eyes on it, ships no notarised build, and its catalog is only as current as the last `verify-catalog.sh` run. Read [Alpha status](#alpha-status) before pointing it at a drive you care about.

A native macOS app that keeps the ISOs on your USB drives up to date.

Isotope tracks which operating systems live on which of your USB sticks, notices when new releases ship, and — after you confirm — downloads, verifies, and installs them. It handles both **Ventoy drives** (where updating means replacing `.iso` files) and **flashed drives** (where updating means re-imaging the whole device, balenaEtcher-style).

Requires macOS 14 or later. Universal binary (Apple Silicon + Intel). No third-party dependencies.

---

## What it does

**Tracks 56 operating systems across 106 channels**, grouped by organization:

| | |
|---|---|
| **Ubuntu** | Ubuntu Desktop, Ubuntu Server, Kubuntu, Xubuntu, Lubuntu, Ubuntu MATE, Ubuntu Budgie, Ubuntu Studio, Ubuntu Cinnamon, Ubuntu Unity, Ubuntu Kylin, Edubuntu (LTS + Latest channels) |
| **Debian family** | Debian (netinst + DVD), Debian Live (6 desktops), Linux Mint Cinnamon/MATE/Xfce, LMDE, Pop!_OS (Intel + NVIDIA), Kali Linux (installer, netinst, live, everything, purple), MX Linux (Xfce, KDE, Fluxbox), Parrot OS |
| **Fedora** | Workstation, KDE Plasma, Server (DVD + netinst), Everything, Silverblue, Kinoite, and a Spins entry covering Xfce, Cinnamon, MATE, LXQt, LXDE, Sway, Budgie, i3 and COSMIC |
| **Enterprise** | Rocky Linux, AlmaLinux (Minimal/DVD/Boot), CentOS Stream (DVD + Boot), Proxmox VE, Proxmox Backup Server, Proxmox Mail Gateway, Proxmox Datacenter Manager |
| **Arch family** | Arch Linux, Manjaro (KDE, GNOME, Xfce), CachyOS (desktop + handheld) |
| **Independents** | openSUSE Leap, openSUSE Tumbleweed, NixOS (graphical + minimal), Alpine (standard, extended, virt), Void Linux (glibc + musl), Gentoo (minimal + LiveGUI), Qubes OS |
| **BSD & storage** | FreeBSD (disc1 + DVD), GhostBSD, TrueNAS |
| **Tools & rescue** | SystemRescue, GParted Live, Clonezilla Live, Memtest86+, Tails |
| **Microsoft** | Windows 11, Windows 10 (tracked by feature release *and* exact build — see below; download is browser-assisted) |

An entry ships only when its version can be resolved from a stable machine-readable source **and** the publisher publishes a SHA-256 Isotope can parse. That rule is why some popular distributions are missing: EndeavourOS and ShredOS publish SHA-512/SHA-1 only, Zorin OS and elementary OS put their downloads behind scripts rather than links, Devuan and Deepin ship no parsable sums file, XCP-ng publishes no checksums beside its ISOs. Each of those is one `catalog.json` entry away the moment that changes.

Anything not in the catalog can be added as a **custom source** — four detection mechanisms, each with a live "Test" button so you can see exactly what it parses before saving.

**Keeps updates safe:**

- Every ISO is SHA-256 verified against the publisher's checksum before it touches a drive. Sources without a published checksum are labelled **unverified** rather than silently trusted.
- Copies land under a temporary name and are renamed on completion — a half-written ISO never appears on your drive.
- Only the specific old ISO being replaced is ever deleted; nothing else on the drive is touched.
- Free-space pre-flight (counting the reclaimable old ISO) fails with the exact shortfall rather than running out mid-copy.
- Updates **always** require explicit confirmation. Nothing is ever flashed or replaced automatically.
- Downloaded ISOs are **deleted as soon as they are on the drive** (on by default). The cache is there to save a second download, not to keep a second copy of what you are already carrying on a stick — an image another queued drive still needs is kept until that drive has it too, and a failed copy keeps its download for the retry.

**Handles the awkward cases honestly:**

- **Windows** ISOs can't be hotlinked (Microsoft's links are session-generated), so Isotope tracks the current feature release, opens the official download page, then verifies and places the file you downloaded.
- **Windows builds** are read out of the image, not guessed from its name. `Win11_25H2_English_x64.iso` is the name Microsoft gives every 25H2 ISO, refreshed media included, so Isotope mounts the image read-only and reads the `<BUILD>`/`<SPBUILD>` pair out of `sources/install.wim`. Rows then read *25H2 (build 26200.6584) → 25H2 (build 26200.9168)* instead of *25H2 → 25H2*.
- **Memtest86+** ships only a zipped ISO upstream; Isotope unzips it before placing.
- Where a version genuinely can't be determined, the app says "unknown" instead of guessing.

---

## Drive types

### Ventoy drives

Register a mounted Ventoy volume, assign the ISOs you want tracked, and Isotope replaces them in place as new releases ship. It identifies drives by volume UUID and warns if a registered drive is reformatted.

**Auto-detect:** ISOs already sitting on the drive are matched against the catalog and offered under "Found on this drive" — one click to start tracking one, or to pin it. Files it can't identify are listed but never touched.

### Flashed drives

Register a physical USB device (identified by USB vendor/product/serial, since flashing destroys the volume identity), assign one image, and Isotope re-images the whole device when a new release ships.

Flashing runs a safety gate every time — external, removable, USB-attached, not the boot disk, large enough — then requires a confirmation naming the exact device before macOS prompts for your administrator password via Apple's `authopen`. **No root daemon is installed and no privileges are stored**; every flash re-prompts. After writing, the device is read back and hash-compared by default.

**Auto-detect:** a flashed stick's volume label (and, where available, a small marker file such as `/.disk/info`) is read to identify what's on it and which version — no admin rights, no raw reads.

---

## Pinning: choosing what updates

Every assignment has an update policy:

- **Track latest** — the default. Counts toward staleness, gets update prompts.
- **Keep as is** — pinned. Never counted as stale, never updated, its file never touched.

Because of this, **one Ventoy drive can hold several versions of the same OS**: one tracking the latest release, plus any number pinned. When you confirm an update, each item offers *"Keep current version on the drive as a pinned copy"* — instead of deleting the outgoing ISO, it becomes its own pinned assignment. That's the intended way to accumulate versions deliberately.

---

## Windows: release *and* build

Windows is the one entry where the filename does not identify the file. Microsoft names every 25H2 ISO `Win11_25H2_English_x64.iso` and reissues it under that same name, so two sticks with identical filenames can hold months of difference.

Isotope reads the truth out of the image: it mounts the ISO read-only (no administrator rights, no writes) and reads the build recorded in `sources/install.wim`. Two versions then appear side by side:

- **Feature release** — 25H2, 24H2, 22H2. This is what staleness compares, because it is the identity that means something across media.
- **Build** — 26200.6584. Shown on both sides, compared only once the releases match.

When the drive holds the current release at an older build, the row says **“Newer build shipped”** and is *not* counted as an update. That is deliberate: Microsoft services Windows monthly but refreshes the downloadable ISO rarely, so a newer build usually cannot be downloaded — prompting for it would send you to fetch the file you already have. The information is there; the decision is yours.

An image that will not identify itself (an unusual container, a custom ISO) simply shows no build. Nothing is inferred from the filename.

---

## Building and installing

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` — edit that, not the `.xcodeproj`.

```sh
xcodegen generate
xcodebuild -project Isotope.xcodeproj -scheme Isotope -configuration Release build
```

Then copy the built app into `/Applications`:

```sh
APP=$(xcodebuild -project Isotope.xcodeproj -scheme Isotope -configuration Release \
      -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Isotope.app
ditto "$APP" /Applications/Isotope.app
```

Or just open `Isotope.xcodeproj` in Xcode and run.

The app is **not sandboxed** — raw device access for flashing is incompatible with the App Sandbox. It's signed ad-hoc for personal use; distribution is from source or via Developer ID, not the App Store.

### Tests

```sh
swift test --package-path IsotopeCore     # portable logic
xcodebuild -project Isotope.xcodeproj -scheme Isotope test   # app layer
```

Everything runs offline against fixtures — no network, no USB device, no admin rights required.

### Checking the catalog against the live internet

```sh
./Scripts/verify-catalog.sh
```

Resolves every entry against its real source and prints the version, ISO URL, and checksum status. Run this after editing `catalog.json`, or whenever you suspect a distro changed its layout.

---

## Project layout

```
IsotopeCore/          Swift package — platform-agnostic, Foundation only
  Models/             Data model: catalog, drives, versions, policies
  Providers/          Version detection (checksum files, JSON feeds, scraping…)
  *.swift             Reconcile, staleness, safety gates, cache index, matchers
Isotope/              macOS app
  Services/           Downloads, updates, flashing, device enumeration, probes
  Stores/             AppStore (observable state) + settings
  Views/              SwiftUI
  Resources/          catalog.json — the built-in OS catalog
IsotopeTests/         App-layer tests
Scripts/              verify-catalog.sh, make-app-icon.swift
docs/                 BRD, PRD, technical design
```

**`IsotopeCore` deliberately depends on Foundation alone** — no SwiftUI, AppKit, CryptoKit, or DiskArbitration. Hashing sits behind a protocol the app fills in with CryptoKit. This keeps the entire "brain" of the app portable, so a future Linux version can reuse it and rewrite only the UI and platform glue.

**The catalog is data, not code.** Distros change their URL layouts; when that happens the fix is an edit to `catalog.json` and a run of `verify-catalog.sh`, not a recompile.

---

## Where things live at runtime

| Path | Contents |
|---|---|
| `~/Library/Application Support/Isotope/` | `drives.json`, `custom-sources.json`, `release-cache.json`, `history.json` |
| `~/Library/Caches/Isotope/` | Downloaded ISOs in `isos/`, plus `cache-index.json` and interrupted-download resume data |

All state is human-readable JSON.

**The cache does not accumulate.** By default an ISO is deleted the moment it has been copied or flashed, so `~/Library/Caches/Isotope/` stays near empty between updates; what remains is interrupted downloads and anything still in use. Turn *Delete a downloaded ISO once it is on the drive* off in Settings and ISOs are kept instead, up to the cache limit (20 GB by default, LRU, clearable in Settings) — worth it if the same image goes onto several drives on different days, since the second drive then needs no download.

No telemetry. The app talks only to the ISO sources in the catalog, their checksum files, and the GitHub API for entries that use it.

---

## Alpha status

Alpha means the shape is settled and the guts are tested — 217 unit tests in `IsotopeCore`, 149 in the app layer, all offline — but this has not been through anyone else's hands or anyone else's hardware.

What that means in practice:

- **Flashing erases a whole device.** The safety gates and the naming confirmation are real and tested, but the consequence of a bug here is somebody's disk. Read the device name in the confirmation dialog every time.
- **The catalog is only as fresh as the last verification run.** Distributions move their URLs without warning. Every entry was live-verified on 2026-08-20; if a source drifts, checks report a failure for that channel rather than a wrong version, and the fix is a `catalog.json` edit plus `Scripts/verify-catalog.sh`.
- **There is no notarised build.** Build from source; the app is signed ad-hoc.
- **No migration promises yet.** State is human-readable JSON under `~/Library/Application Support/Isotope/`, and unknown fields are tolerated, but nothing here is a stability guarantee.
- **Windows build detection has been exercised against synthetic images and real media on one machine.** Unusual media (custom or repacked ISOs) may simply report no build.

The most useful bug report names the drive type, the entry, and what the row said versus what was actually on the stick.

---

## Documentation

`docs/` holds the full specification: [BRD.md](docs/BRD.md) (scope and rationale), [PRD.md](docs/PRD.md) (numbered requirements, including every addendum), and [DESIGN.md](docs/DESIGN.md) (architecture and technical decisions).
