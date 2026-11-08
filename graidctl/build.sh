#!/bin/sh
# Builds graidctl (CLI) and "G-RAID Utility.app" (GUI), both universal.
# arm64 targets macOS 13+; x86_64 targets macOS 14+ (current toolchains no longer ship
# the x86_64 back-compat libraries for older targets).
set -e
cd "$(dirname "$0")"
OUT=build
APP="$OUT/G-RAID Utility.app"
SWIFTC="swiftc -O -swift-version 5"
mkdir -p "$OUT/obj"

build_universal() { # name, output, sources...
  name=$1; out=$2; shift 2
  $SWIFTC -target arm64-apple-macos13  "$@" -o "$OUT/obj/$name-arm64"
  $SWIFTC -target x86_64-apple-macos14 "$@" -o "$OUT/obj/$name-x86_64"
  lipo -create "$OUT/obj/$name-arm64" "$OUT/obj/$name-x86_64" -output "$out"
}

build_universal graidctl "$OUT/graidctl" Sources/Core/*.swift Sources/CLI/main.swift
build_universal app "$OUT/obj/app" -parse-as-library Sources/Core/*.swift Sources/App/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/obj/app" "$APP/Contents/MacOS/G-RAID Utility"
cp "$OUT/graidctl" "$APP/Contents/MacOS/graidctl"
# G-Technology's artwork isn't in the repository; tools/fetch-artwork.sh copies it from your own
# copy of the original Configurator. Without it the app uses system symbols instead.
for f in Resources/*.png Resources/*.icns; do if [ -e "$f" ]; then cp "$f" "$APP/Contents/Resources/"; fi; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>G-RAID Utility</string>
  <key>CFBundleDisplayName</key><string>G-RAID Utility</string>
  <key>CFBundleExecutable</key><string>G-RAID Utility</string>
  <key>CFBundleIdentifier</key><string>local.graid.utility</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Native replacement for G-RAID with Thunderbolt Configurator 1.1. Artwork © Western Digital.</string>
</dict>
</plist>
PLIST
# Sign with the local self-signed identity if present: a stable identity keeps the app's
# Full Disk Access across rebuilds (ad-hoc signatures change with every build).
IDENTITY="G-RAID Utility Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then SIGN="$IDENTITY"; else SIGN=-; fi
echo "Signing with: $SIGN"
codesign --force --sign "$SIGN" "$APP/Contents/MacOS/graidctl"
codesign --force --sign "$SIGN" "$APP"
codesign --force --sign "$SIGN" "$OUT/graidctl"
rm -rf "$OUT/obj"
echo "Built $(pwd)/$OUT/graidctl"
echo "Built $(pwd)/$APP"
