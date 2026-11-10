#!/bin/sh
# muguet - make-app.sh
# Constantin Clerc (c22dev) - 0.1

set -eu
cd "$(dirname "$0")"
APP="$PWD/build/V4Mac.app"
GAME="${1:-}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/home --remap-path-prefix=$PWD=/v4mac"

cargo build --release
BIN=target/release/v4mac
EMBEDDED=false
if [ -n "$GAME" ]; then
  mkdir -p target/mac-game
  case "$GAME" in
    *.zip)
      ENTRY="$(unzip -Z1 "$GAME" | grep -E '(^|/)b/[^/]+/game\.wasm$' | head -1)"
      [ -n "$ENTRY" ] || { echo "$GAME has no b/<build>/game.wasm"; exit 1; }
      unzip -p "$GAME" "$ENTRY" > target/mac-game/game.wasm ;;
    *) cp "$GAME" target/mac-game/game.wasm ;;
  esac
  ./target/release/v4mac --precompile target/mac-game/game.wasm target/mac-game/game.cwasm
  rm target/mac-game/game.wasm
  MUGUET_GAME_CODE="$PWD/target/mac-game/game.cwasm" cargo build --release --no-default-features --target-dir target/embed
  BIN=target/embed/release/v4mac
  EMBEDDED=true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" target/release/v4mac-server "$APP/Contents/MacOS/"
swiftc -O -parse-as-library -target arm64-apple-macos14 launcher/Launcher.swift -o "$APP/Contents/MacOS/Launcher"
cp assets/*.mp3 assets/launcher-bg.jpg assets/v4mac-logo.png "$APP/Contents/Resources/"

if xcrun --find actool >/dev/null 2>&1 && xcrun actool assets/v4mac.icon --compile "$APP/Contents/Resources" --app-icon v4mac --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null 2>&1; then
  :
else
  IS="$(mktemp -d)/v4mac.iconset"; mkdir -p "$IS"
  for s in 16 32 64 128 256; do sips -z $s $s assets/v4mac.icon/Assets/90037.png --out "$IS/icon_${s}x${s}.png" >/dev/null; done
  cp "$IS/icon_32x32.png" "$IS/icon_16x16@2x.png"; cp "$IS/icon_64x64.png" "$IS/icon_32x32@2x.png"
  cp "$IS/icon_256x256.png" "$IS/icon_128x128@2x.png"; rm "$IS/icon_64x64.png"
  iconutil -c icns "$IS" -o "$APP/Contents/Resources/v4mac.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>V4Mac</string>
  <key>CFBundleDisplayName</key><string>V4Mac</string>
  <key>CFBundleIdentifier</key><string>com.offspace.v4mac</string>
  <key>CFBundleExecutable</key><string>Launcher</string>
  <key>CFBundleIconFile</key><string>v4mac</string>
  <key>CFBundleIconName</key><string>v4mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>GCSupportsGameMode</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Multiplayer connects to a game server on your local network.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><false/>
  <key>V4MacEmbeddedCode</key><EMBEDDED/>
</dict>
</plist>
PLIST
sed -i '' "s|<EMBEDDED/>|<$EMBEDDED/>|" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "built: $APP ($(du -sh "$APP" | cut -f1))"
