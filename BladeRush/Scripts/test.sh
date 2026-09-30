#!/bin/bash
# Full verification: unit tests (combat timing, render math), built-in self tests, data
# validation, a headless fight simulation, Metal shader type-check (clang shim) and, on
# Linux, a type-check of the macOS app target against framework stubs.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
swift build -c release --product BladeSim
BIN="$(swift build -c release --show-bin-path)"
"$BIN/BladeSim" selftest
"$BIN/BladeSim" validate
"$BIN/BladeSim" simulate gorrik 60
if command -v clang++ >/dev/null 2>&1; then
    python3 Scripts/mslcheck/check_msl.py
fi
if [[ "$(uname)" != "Darwin" ]]; then
    Scripts/maccheck/check_mac.sh
fi
echo "All checks passed."
