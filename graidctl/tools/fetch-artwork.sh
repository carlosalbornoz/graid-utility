#!/bin/sh
# Copies G-Technology's artwork into Resources/ from your own copy of the original
# "G-RAID with Thunderbolt Configurator.app" (2017). The artwork belongs to G-Technology /
# Western Digital, so it isn't in this repository.
#
#   tools/fetch-artwork.sh "/path/to/G-RAID with Thunderbolt Configurator.app" [enclosure.icns]
#
# The optional .icns (for example G-RAIDwithTB_1113.icns from G-Technology's icon pack) becomes
# the enclosure picture in the overview panel.
set -e
cd "$(dirname "$0")/.."
APP="$1"
[ -d "$APP/Contents/Resources" ] || { echo "usage: $0 <Configurator.app> [enclosure.icns]" >&2; exit 1; }
R="$APP/Contents/Resources"
for f in Img_Authentication_Lock Img_GR_Icon Img_RaidStatus_Attn Img_RaidStatus_Bad Img_RaidStatus_Good; do
    cp "$R/$f.png" Resources/
done
cp "$R/appIcons.icns" Resources/AppIcon.icns
if [ -n "$2" ]; then
    sips -s format png "$2" --out Resources/Img_Device_GRAID.png >/dev/null
fi
echo "Artwork copied to Resources/. Run ./build.sh to include it."
