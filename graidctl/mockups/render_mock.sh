#!/bin/bash
# Builds the Liquid Glass mockup app and screenshots each tab into build/mock/.
set -e
cd "$(dirname "$0")/.."
APP="build/mock/G-RAID Mock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 mockups/LiquidGlassMock.swift -o "$APP/Contents/MacOS/G-RAID Mock"
cp Resources/*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.graid.mock</string>
<key>CFBundleName</key><string>G-RAID Mock</string>
<key>CFBundleExecutable</key><string>G-RAID Mock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign -s - -f "$APP" >/dev/null 2>&1
[ "$1" = "--build-only" ] && exit 0
shoot() {   # shoot <name> <args...>
  local name=$1; shift
  open -n "$APP" --args "$@"
  sleep 3
  local id
  id=$(swift -e 'import CoreGraphics; let ws = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as! [[String: Any]]; for w in ws where (w["kCGWindowOwnerName"] as? String) == "G-RAID Mock" && (w["kCGWindowLayer"] as? Int) == 0 { print(w["kCGWindowNumber"]!); break }' 2>/dev/null)
  screencapture -x -l"$id" "build/mock/$name.png"
  osascript -e 'tell application id "local.graid.mock" to quit' >/dev/null 2>&1 || true
  sleep 1
  echo "build/mock/$name.png"
}
for look in dark light; do
  shoot disks-$look --tab disks --appearance $look
  shoot raid-$look --tab raid --appearance $look
  shoot volumes-$look --tab volumes --appearance $look --show-system
  shoot activity-$look --tab activity --appearance $look
  # contact sheet: 2x2 of the four tabs
  swift -e '
import AppKit
let look = CommandLine.arguments[1]
let names = ["disks", "raid", "volumes", "activity"].map { "build/mock/\($0)-\(look).png" }
let imgs = names.map { NSImage(contentsOfFile: $0)! }
let w = imgs[0].size.width, h = imgs[0].size.height
let out = NSImage(size: NSSize(width: w * 2, height: h * 2)); out.lockFocus()
for (i, im) in imgs.enumerated() { im.draw(in: NSRect(x: CGFloat(i % 2) * w, y: CGFloat(1 - i / 2) * h, width: w, height: h)) }
out.unlockFocus()
try! NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/mock/sheet-\(look).png"))' $look
  sips -Z 2400 build/mock/sheet-$look.png >/dev/null
done
