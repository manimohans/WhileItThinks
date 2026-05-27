#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WhileItThinks"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

cargo build --release --bins
swift build -c release --package-path macos

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

ICONSET_DIR="$RESOURCES_DIR/WhileItThinksRaccoon.iconset"
python3 "$ROOT_DIR/scripts/generate-icon.py" "$ICONSET_DIR" "$RESOURCES_DIR"
iconutil -c icns -o "$RESOURCES_DIR/WhileItThinksRaccoon.icns" "$ICONSET_DIR"
rm -rf "$ICONSET_DIR"

cp "$ROOT_DIR/macos/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/target/release/whileitthinks" "$MACOS_DIR/whileitthinks-cli"
cp "$ROOT_DIR/target/release/whileitthinks-hook" "$MACOS_DIR/whileitthinks-hook"
cp "$ROOT_DIR/target/release/whileitthinksd" "$MACOS_DIR/whileitthinksd"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/whileitthinks-cli" "$MACOS_DIR/whileitthinks-hook" "$MACOS_DIR/whileitthinksd"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>WhileItThinks</string>
  <key>CFBundleIdentifier</key>
  <string>com.whileitthinks.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>WhileItThinks</string>
  <key>CFBundleIconFile</key>
  <string>WhileItThinksRaccoon.icns</string>
  <key>CFBundleIconName</key>
  <string>WhileItThinksRaccoon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 WhileItThinks</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "Built $APP_DIR"
