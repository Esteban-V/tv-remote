#!/bin/sh
# Builds TVRemote.app (universal, menu-bar only). Locally it also installs to /Applications.
set -e
cd "$(dirname "$0")"
APP=TVRemote.app
VERSION=${VERSION:-1.0}
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp icons/* AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos14 -swift-version 5 -parse-as-library TVRemote.swift -o build/TVRemote-$arch
done
lipo -create build/TVRemote-* -output "$APP/Contents/MacOS/TVRemote"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tvremote</string>
  <key>CFBundleName</key><string>TV Remote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>TVRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Sends remote-control commands to your Samsung TV.</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "Built $APP"
if [ -z "$CI" ]; then
  rm -rf /Applications/TVRemote.app && cp -R "$APP" /Applications/
  echo "Installed to /Applications"
fi
