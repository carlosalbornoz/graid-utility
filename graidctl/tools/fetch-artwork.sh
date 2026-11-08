#!/bin/sh
# Puts G-Technology's artwork into Resources/. It belongs to G-Technology / Western Digital, so it
# isn't in this repository. The app builds and runs without it, using system symbols instead.
#
#   tools/fetch-artwork.sh <icon pack folder or .zip> ["/path/to/G-RAID with Thunderbolt Configurator.app"]
#
# The icon pack gives the enclosure picture. WD publishes it in "How to change drive icons on macOS
# for SanDisk Professional and G-Technology":
#   https://support-en.wd.com/app/answers/detailweb/a_id/30548
#   https://downloads.wdc.com/gtech/icons/G-Technology_Icons.zip
#
# The old Configurator app, if you have it, gives the app icon: its G logo, fitted onto the macOS
# icon grid by tools/make-appicon.swift.
set -e
cd "$(dirname "$0")/.."
PACK="$1"; OLDAPP="$2"
[ -n "$PACK" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Enclosure picture.
if [ -f "$PACK" ]; then
    unzip -q "$PACK" -d "$TMP/pack"
    PACK="$TMP/pack"
fi
ICNS=$(find "$PACK" -name 'G-RAIDwithTB_1113.icns' -not -path '*__MACOSX*' | head -n 1)
[ -n "$ICNS" ] || { echo "G-RAIDwithTB_1113.icns not found in $1" >&2; exit 1; }
sips -s format png "$ICNS" --out Resources/Img_Device_GRAID.png >/dev/null
echo "Enclosure picture: Resources/Img_Device_GRAID.png"

# App icon.
if [ -n "$OLDAPP" ]; then
    LOGO="$OLDAPP/Contents/Resources/Img_GR_Icon.png"
    [ -f "$LOGO" ] || { echo "Img_GR_Icon.png not found in $OLDAPP" >&2; exit 1; }
    swift tools/make-appicon.swift "$LOGO" "$TMP/icon.png"
    SET="$TMP/AppIcon.iconset"; mkdir "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o Resources/AppIcon.icns
    echo "App icon: Resources/AppIcon.icns"
fi
echo "Run ./build.sh to include it."
