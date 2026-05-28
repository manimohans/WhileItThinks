#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WhileItThinks"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
VERSION="${1:-}"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build-app.sh"

if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
fi

OUTPUT="$ROOT_DIR/dist/$APP_NAME-$VERSION.dmg"
CHECKSUM="$OUTPUT.sha256"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whileitthinks-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing app with $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/whileitthinks-cli"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/whileitthinks-hook"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/whileitthinksd"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/$APP_NAME"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/READ ME FIRST.txt" <<'TXT'
Install WhileItThinks

1. Drag WhileItThinks.app into Applications.
2. Open WhileItThinks from Applications.
3. Enable Claude Code and/or Codex in the app.

Why Applications?
Claude Code and Codex hooks store the app's absolute path. Installing in
Applications keeps that path stable.
TXT

rm -f "$OUTPUT" "$CHECKSUM"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$OUTPUT"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing DMG with $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "NOTARY_PROFILE requires SIGN_IDENTITY." >&2
    exit 1
  fi
  echo "Submitting DMG for notarization with keychain profile $NOTARY_PROFILE"
  xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT"
fi

hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$CHECKSUM"

echo "Built $OUTPUT"
echo "Checksum $CHECKSUM"
