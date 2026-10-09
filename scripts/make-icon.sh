#!/usr/bin/env bash
# Renders design/icon/icon.html with WebKit and writes Resources/AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/render" "$ROOT/design/icon/render.swift"
# Full-bleed square artwork: macOS 26+ applies its own icon mask and edge treatment, whereas a
# pre-masked icon whose shape doesn't exactly match gets boxed in a grey compatibility frame.
"$WORK/render" "$ROOT/design/icon/icon.html" "$WORK/icon-1024.png" 1024 bleed

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$WORK/icon-1024.png" "$ROOT/design/icon/icon-1024.png"
echo "Wrote Resources/AppIcon.icns"
