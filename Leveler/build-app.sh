#!/bin/bash
# Baut Leveler.app in ./build
#   ./build-app.sh            – für diesen Mac
#   ./build-app.sh --install  – zusätzlich nach /Applications kopieren
#   UNIVERSAL=1 ./build-app.sh – Universal-App (Apple Silicon + Intel, braucht Xcode)
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Kompiliere (Release)…"
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/Leveler.app"
echo "▸ Erstelle $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Leveler" "$APP/Contents/MacOS/Leveler"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.png ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "▸ Signiere (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installiere nach /Applications…"
  pkill -x Leveler 2>/dev/null || true
  rm -rf /Applications/Leveler.app
  cp -R "$APP" /Applications/
  open /Applications/Leveler.app
  echo "✓ Leveler läuft jetzt – Symbol oben rechts in der Menüleiste."
else
  echo "✓ Fertig: $APP  (starten mit: open $APP)"
fi
