#!/bin/sh
# Builds release archives from the committed code only (git archive HEAD), so nothing
# untracked gets in: no G-Technology artwork, no firmware, no local settings.
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
(cd "$WORK/graidctl" && ./build.sh >/dev/null && build/graidctl selftest >/dev/null && tests/fake_device.sh >/dev/null)
echo "Built and tested $COMMIT (version $VERSION)"

APP="$WORK/graidctl/build/G-RAID Utility.app"
if ls "$APP/Contents/Resources/" | grep -q .; then
  echo "Refusing to package: the app contains resources that shouldn't ship:"; ls "$APP/Contents/Resources/"; exit 1
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
