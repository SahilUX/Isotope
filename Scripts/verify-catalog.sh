#!/bin/sh
# Runs every catalog channel against its live endpoint and prints what each
# provider resolved. Exits non-zero if any channel fails (DESIGN §7).
#
# The implementation lives in IsotopeCore/Sources/VerifyCatalog/main.swift so it
# can import IsotopeCore; SwiftPM cannot own sources outside the package root,
# which is why this wrapper — rather than a standalone Scripts/verify-catalog.swift —
# is the entry point.
#
#   Scripts/verify-catalog.sh [path/to/catalog.json]
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="${1:-$root/Isotope/Resources/catalog.json}"
exec swift run --package-path "$root/IsotopeCore" verify-catalog "$catalog"
