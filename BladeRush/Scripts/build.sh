#!/bin/bash
# Release build of every product (BladeRush app binary on macOS, BladeSim everywhere).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
echo "Built: $(swift build -c release --show-bin-path)"
