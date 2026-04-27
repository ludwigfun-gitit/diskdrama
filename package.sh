#!/bin/bash
# package.sh — builds a universal .app bundle and zips it for distribution
# Run from the DiskDrama project directory.

set -e

APP_NAME="DiskDrama"
BUNDLE="$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
BUILD=".build"

mkdir -p "$BUILD"

echo "▶ Compiling arm64…"
swiftc "$APP_NAME.swift" \
  -o "$BUILD/$APP_NAME-arm64" \
  -framework Cocoa \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -Onone

echo "▶ Compiling x86_64…"
swiftc "$APP_NAME.swift" \
  -o "$BUILD/$APP_NAME-x86_64" \
  -framework Cocoa \
  -sdk "$SDK" \
  -target x86_64-apple-macosx13.0 \
  -Onone

echo "▶ Creating universal binary…"
lipo -create \
  "$BUILD/$APP_NAME-arm64" \
  "$BUILD/$APP_NAME-x86_64" \
  -output "$BUILD/$APP_NAME-universal"

echo "▶ Assembling .app bundle…"
rm -rf "$BUILD/$BUNDLE"
mkdir -p "$BUILD/$BUNDLE/Contents/MacOS"
mkdir -p "$BUILD/$BUNDLE/Contents/Resources"

cp "$BUILD/$APP_NAME-universal" "$BUILD/$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUILD/$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUILD/$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DiskDrama</string>
  <key>CFBundleDisplayName</key>       <string>DiskDrama</string>
  <key>CFBundleIdentifier</key>        <string>com.unruly.diskdrama</string>
  <key>CFBundleVersion</key>           <string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>        <string>DiskDrama</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSUIElement</key>               <true/>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>  <string>© 2025 Unruly Software</string>
</dict>
</plist>
PLIST

echo "▶ Zipping…"
cd "$BUILD"
zip -r --symlinks "../$APP_NAME.zip" "$BUNDLE"
cd ..

echo ""
echo "✓ Done: $APP_NAME.zip"
echo "  $(du -sh "$APP_NAME.zip" | cut -f1)  — drag $BUNDLE to /Applications on any Mac (macOS 13+, arm64 + x86_64)"
echo ""
echo "  To clear Gatekeeper quarantine after copying:"
echo "  xattr -cr /Applications/$BUNDLE"
