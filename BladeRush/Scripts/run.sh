#!/bin/bash
# Builds and runs the game straight from the source tree. Data/*.json and the Metal shaders
# are read from the repository, so edits hot-reload while the game is running.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname)" != "Darwin" ]]; then
    echo "The game window needs macOS. On this system try: swift run BladeSim simulate all" >&2
    exit 1
fi
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product BladeRush
exec "$(swift build -c "$CONFIG" --show-bin-path)/BladeRush" "$@"
