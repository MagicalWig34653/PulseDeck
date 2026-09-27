#!/usr/bin/env bash
# Builds a PulseDeck disk image with a custom background.
# Usage: scripts/build-dmg.sh <path/to/PulseDeck.app> <version> <output.dmg>
# Requires macOS (AppKit for the background, tiffutil, hdiutil) and python3.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <path/to/PulseDeck.app> <version> <output.dmg>" >&2
    exit 64
fi

app="$1"
version="$2"
output="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Rendering background"
swift "$root/packaging/dmg/render-background.swift" "$work"
# Combine 1x and 2x into one multi-resolution TIFF so Finder uses the Retina variant.
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff"

echo "==> Installing dmgbuild"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6,<2"
"$work/venv/bin/pip" show dmgbuild | grep -E '^(Name|Version)'

echo "==> Building $output"
rm -f "$output"
"$work/venv/bin/dmgbuild" \
    -s "$root/packaging/dmg/settings.py" \
    -D app="$app" \
    -D background="$work/background.tiff" \
    "PulseDeck $version" \
    "$output"

hdiutil verify "$output"
echo "==> Done: $output"
