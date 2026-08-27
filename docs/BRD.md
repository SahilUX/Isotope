# Business Requirements Document: Isotope

**Version:** 1.0 (draft for approval)
**Date:** 2026-08-17
**Owner:** Sahil

## 1. Background

Bootable USB drives go stale. A Ventoy drive prepared six months ago carries Ubuntu 24.04.1 when 24.04.3 is out, an old Fedora, an outdated SystemRescue. Refreshing them today is manual: check each distro's website, download the ISO, verify the checksum (usually skipped), find the drive, replace the file. Multiply by several drives and a dozen ISOs and it stops happening. The drives are out of date when they're needed.

## 2. Business objective

A native macOS app that keeps registered USB drives' ISOs current with minimal effort. It knows which ISOs live on which drives, detects when newer versions are released, and, after one confirmation, downloads, verifies, and places the new ISO on the drive.

## 3. Goals & success criteria

| Goal | Success criterion |
|---|---|
| Eliminate manual version checking | App reports staleness for every tracked ISO without user research |
| Safe updates | Every downloaded ISO is SHA-256 verified before it touches a drive |
| Low effort | Updating a stale drive takes one confirmation click after plugging it in |
| Coverage | Popular Linux distros, utility ISOs, and Windows are trackable out of the box; anything else via custom sources |
| Native feel | Real macOS app (SwiftUI), respects notifications, sandboxing, and system conventions |

## 4. Scope

### In scope (v1)
- Ventoy-style drives: updating = replacing `.iso` files on the drive's filesystem.
- Built-in catalog of popular Linux distros, utility/rescue ISOs, and Windows.
- Custom user-defined sources (URL/GitHub/checksum-file based).
- Drive registration, per-drive ISO assignments, staleness dashboard.
- Notify-then-confirm update flow; downloads with checksum verification.

### In scope (v1.1 addendum, approved 2026-08-17 after v1 completion)
- Raw flashing of drives (dd/balenaEtcher-style re-imaging) for single-ISO USB sticks. Consequence accepted: the app drops App Sandbox (personal distribution) and uses Apple's `authopen` for per-flash admin authorization, with no root daemon installed. Read-back verification on by default.

### Out of scope (v2 candidates)
- Background agent / menu-bar presence. v1 is a regular windowed app; checks happen while it runs.
- Installing or upgrading Ventoy itself on a drive.
- Fully automated Windows ISO download, which Microsoft session-gates. v1 does best-effort, see PRD §5.4.
- Multi-user / sync / any server component.

## 5. Stakeholders

Single stakeholder: the user (owner-operator, technically expert). No compliance, licensing, or monetization requirements. Distribution is personal, built from source or via Developer ID rather than the App Store, though the design stays App-Store-compatible where that is free.

## 6. Constraints & assumptions

- macOS 14+ (Sonoma) or later; Apple Silicon and Intel.
- Drives are already Ventoy-prepared (exFAT data partition); the app never partitions or formats.
- Internet access required for version checks and downloads; the app must degrade gracefully offline.
- ISO downloads are large (2–7 GB), so downloads must be resumable and cached.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Distro websites/endpoints change format | Version checks silently break | Prefer stable machine-readable endpoints (JSON APIs, checksum files); catalog is data-driven and updatable without recompiling |
| Windows download links are session-gated | Can't fully automate Windows | Track version; hand off download to browser with clear guidance (PRD §5.4) |
| User reformats/renames a registered drive | App mis-identifies it | Identify drives by volume UUID; surface a clear "drive changed" state |
| Checksum unavailable for a custom source | Unverified ISO | Mark as unverified in UI; never claim verification that didn't happen |
