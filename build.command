#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p 'PolarPAP.app/Contents/MacOS' 'PolarPAP.app/Contents/Resources'
cache_dir="${TMPDIR:-/tmp}/polarpap-swift-build-cache"
mkdir -p "$cache_dir"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$cache_dir" Sources/SignalCore.swift Sources/TimeShift.swift Sources/Sessions.swift Sources/PolarPAP.swift Sources/AppUI.swift -o PolarPAP.app/Contents/MacOS/PolarPAP
cp Resources/PolarPAP.icns PolarPAP.app/Contents/Resources/PolarPAP.icns
cat > PolarPAP.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PolarPAP</string>
<key>CFBundleIdentifier</key><string>org.ecgpolar.recordingsystem</string>
<key>CFBundleName</key><string>PolarPAP</string>
<key>CFBundleDisplayName</key><string>PolarPAP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>PolarPAP</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>PolarPAP connects to your Polar H10 to record ECG, heart rate and RR intervals locally on your Mac.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Connect to your Polar H10 heart rate sensor.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier org.ecgpolar.recordingsystem PolarPAP.app
printf 'Built %s/PolarPAP.app\n' "$PWD"
