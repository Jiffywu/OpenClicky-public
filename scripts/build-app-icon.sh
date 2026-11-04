#!/bin/zsh
# Regenerate the macOS icon from the original ImageGen PNG.
set -euo pipefail
ROOT=${0:A:h:h}
SOURCE="$ROOT/Resources/Artwork/AppIcon-source.png"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/openclicky-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$ROOT/Resources/App"

for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  RETINA=$((SIZE * 2))
  sips -z "$RETINA" "$RETINA" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/App/AppIcon.icns"
echo "Built Resources/App/AppIcon.icns"
