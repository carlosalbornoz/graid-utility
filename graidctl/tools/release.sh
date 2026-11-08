#!/bin/sh
# Builds release archives from the committed code only (git archive HEAD), plus the app's
# artwork from Resources/ (the enclosure picture and the icon, made from G-Technology's
# artwork by tools/fetch-artwork.sh). The artwork ships in the app; it stays out of the
# repository. Nothing else untracked gets in: no firmware, no local settings.
#   tools/release.sh            → build/release/G-RAID-Utility-<version>.zip,
#                                 graidctl-<version>-macos.zip and SHA256SUMS.txt
set -e
cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel)
VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' build.sh)
COMMIT=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- .)" ]; then
  echo "Note: uncommitted changes in graidctl/ are not in this release (building $COMMIT)."
fi

WORK=$(mktemp -d -t graid-release)
trap 'rm -rf "$WORK"' EXIT
git -C "$ROOT" archive HEAD graidctl | tar -x -C "$WORK"
ARTWORK="AppIcon.icns Img_Device_GRAID.png"
for f in $ARTWORK; do
  [ -e "Resources/$f" ] || { echo "Missing Resources/$f: run tools/fetch-artwork.sh first."; exit 1; }
  cp "Resources/$f" "$WORK/graidctl/Resources/"
done
(cd "$WORK/graidctl" && ./build.sh >/dev/null && build/graidctl selftest >/dev/null && tests/fake_device.sh >/dev/null)
echo "Built and tested $COMMIT (version $VERSION)"

APP="$WORK/graidctl/build/G-RAID Utility.app"
# Only the artwork above may be in the app's resources.
EXTRA=$(ls "$APP/Contents/Resources/" | grep -vxF -e AppIcon.icns -e Img_Device_GRAID.png || true)
if [ -n "$EXTRA" ]; then
  echo "Refusing to package: unexpected resources in the app:"; echo "$EXTRA"; exit 1
fi
codesign --verify --strict "$APP"

OUT=build/release
rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/G-RAID-Utility-$VERSION.zip"
mkdir "$WORK/cli" && cp "$WORK/graidctl/build/graidctl" "$WORK/cli/"
ditto -c -k "$WORK/cli" "$OUT/graidctl-$VERSION-macos.zip"
(cd "$OUT" && shasum -a 256 *.zip > SHA256SUMS.txt)
echo "Release files in $(pwd)/$OUT:"
(cd "$OUT" && ls -l && cat SHA256SUMS.txt)
