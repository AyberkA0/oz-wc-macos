#!/bin/bash
# Builds build/Oz.app (release). Signs with "Oz Local Signing" (see
# scripts/create-signing-cert.sh) when it exists, so macOS keeps the Accessibility and
# Screen Recording permissions across rebuilds; otherwise ad-hoc. Override with SIGN_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/OzWC"

APP=build/Oz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OzWC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp scripts/trackpad-gestures.sh "$APP/Contents/Resources/trackpad-gestures.sh"
chmod +x "$APP/Contents/Resources/trackpad-gestures.sh"

if [ -z "${SIGN_ID:-}" ]; then
  if security find-certificate -c "Oz Local Signing" >/dev/null 2>&1; then
    SIGN_ID="Oz Local Signing"
  else
    SIGN_ID="-"
  fi
fi
codesign --force --sign "$SIGN_ID" --identifier dev.oz.wc "$APP"
echo "signed with: $SIGN_ID"
echo "built $APP"
