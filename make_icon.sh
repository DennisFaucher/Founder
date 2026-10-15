#!/bin/bash
# Regenerates Assets/Founder.icns from Assets/icon-source.png.
# The source is padded to a square (transparent) so non-square art is not distorted.
set -euo pipefail

cd "$(dirname "$0")"

SRC="Assets/icon-source.png"
OUT="Assets/Founder.icns"
SET="$(mktemp -d)/Founder.iconset"

[ -f "$SRC" ] || { echo "Missing $SRC"; exit 1; }

WIDTH=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/{print $2}')
HEIGHT=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')
SIDE=$(( WIDTH > HEIGHT ? WIDTH : HEIGHT ))

mkdir -p "$SET"
SQUARE="$(dirname "$SET")/square.png"
sips --padToHeightWidth "$SIDE" "$SIDE" "$SRC" --out "$SQUARE" >/dev/null

for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
            "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
            "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -z "$1" "$1" "$SQUARE" --out "$SET/$2" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
echo "Wrote $OUT"
