#!/bin/bash
# Type-checks the macOS app target on Linux against API stubs of the Apple frameworks it
# uses (Scripts/maccheck/stubs). Catches Swift-level mistakes; it cannot validate the real
# SDK behavior. Run from the package root after `swift build` (needs BladeCore's module).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.build/maccheck"
SRC="$OUT/src"
rm -rf "$SRC"; mkdir -p "$OUT" "$SRC"
STUBS="$ROOT/Scripts/maccheck/stubs"
build() { swiftc -emit-module -parse-as-library -module-name "$1" "$STUBS/$1.swift" -I "$OUT" -o "$OUT/$1.swiftmodule"; }
for m in CoreGraphics CoreText Metal QuartzCore AppKit MetalKit MetalFX GameController AVFoundation; do build $m; done
# No Objective-C runtime on Linux: #selector(...) becomes a stub Selector("...").
for f in $(find "$ROOT/Sources/BladeRush" -name '*.swift'); do
    python3 -c "import re,sys; s=open(sys.argv[1]).read(); s=re.sub(r'#selector\(((?:[^()]|\([^()]*\))*)\)', lambda m: 'Selector(\"'+m.group(1)+'\")', s); open(sys.argv[2],'w').write(s)" "$f" "$SRC/$(basename "$f")"
done
MODS=$(dirname "$(find "$ROOT/.build" -name 'BladeCore.swiftmodule' -path '*debug*' | head -1)")
swiftc -typecheck -I "$OUT" -I "$MODS" "$SRC"/*.swift
echo "macOS target type-check passed"
