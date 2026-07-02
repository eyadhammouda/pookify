#!/bin/bash
# Builds "Pookify.app" from the SwiftPM executables (no Xcode required) and
# ad-hoc signs it. Optionally packages a distributable zip with: ./scripts/build.sh --zip
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Pookify"                       # internal binary/target name (the process name)
APP_NAME="Pookify"     # user-facing app name (bundle + Finder)
BUNDLE_ID="com.pookify.app"
VERSION="0.1.0"
APP="build/$APP_NAME.app"

# Pin the deployment target so the binary isn't stamped with the build machine's newer OS
# (which would make it refuse to launch on older systems despite LSMinimumSystemVersion).
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "Building release (arm64)…"
swift build -c release --arch arm64
BIN_DIR=".build/release"

# To also run natively on Intel Macs, build x86_64 and lipo the two together. We do arm64 by
# default (Apple Silicon); add x86_64 if a universal build is requested.
if [[ "${UNIVERSAL:-}" == "1" ]]; then
  echo "Building release (x86_64) for a universal binary…"
  swift build -c release --arch x86_64
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

assemble_binary() {
  local exe="$1"
  if [[ "${UNIVERSAL:-}" == "1" ]]; then
    lipo -create \
      ".build/arm64-apple-macosx/release/$exe" \
      ".build/x86_64-apple-macosx/release/$exe" \
      -output "$APP/Contents/MacOS/$exe"
  else
    cp "$BIN_DIR/$exe" "$APP/Contents/MacOS/$exe"
  fi
  chmod +x "$APP/Contents/MacOS/$exe"
}

# Ship both the app and the hook helper inside the bundle (helper sits next to the main binary
# in Contents/MacOS so the app can copy it to its stable support-dir location on first launch).
assemble_binary "$NAME"
assemble_binary "island-hook"

# Optional app icon (drop an AppIcon.icns into assets/ to brand the app). Only declare
# CFBundleIconFile when the icon is actually present, so the bundle never points at a missing file.
ICON_PLIST_LINE=""
if [[ -f assets/AppIcon.icns ]]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST_LINE="  <key>CFBundleIconFile</key>             <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>           <string>$NAME</string>
  <key>CFBundleVersion</key>              <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
$ICON_PLIST_LINE
  <key>LSMinimumSystemVersion</key>       <string>14.0</string>
  <key>LSUIElement</key>                  <true/>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ship the license + third-party notices inside the bundle so the required MIT/CC0 notices travel
# with every distributed copy (the source comments don't survive compilation into the binary).
for doc in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$doc" ]] && cp "$doc" "$APP/Contents/Resources/$doc"
done

# Strip stray extended attributes (codesign rejects Finder info / quarantine on nested files),
# then ad-hoc sign. Ad-hoc signing is effectively required on Apple Silicon even for local runs.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || echo "warning: ad-hoc codesign failed — the app may be blocked by Gatekeeper on first launch."
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p build
  ZIP="build/$APP_NAME.zip"
  rm -f "$ZIP"
  # ditto preserves the bundle layout and resource forks correctly (zip -r does not).
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packaged $ZIP"
fi
