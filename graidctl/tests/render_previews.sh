#!/bin/sh
# Renders the GUI's screens with sample data into build/previews/.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/previews
swiftc -swift-version 5 -parse-as-library Sources/Core/*.swift Sources/App/Model.swift Sources/App/GRAIDApp.swift Sources/App/Services.swift Sources/App/MonitorViews.swift Sources/App/Phase2.swift Sources/App/MainUI.swift Sources/App/ReplaceDrive.swift \
  tests/preview/RenderPreviews.swift -o build/previews/render 2>&1 | grep -v '^ld: warning' || true
# Bundle resources sit next to the executable for Bundle.main lookups.
for f in Resources/*.png; do if [ -e "$f" ]; then cp "$f" build/previews/; fi; done
(cd build/previews && ./render "$(pwd)")
