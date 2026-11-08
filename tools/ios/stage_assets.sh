#!/bin/zsh
# Stages YOUR OWN Forecast Channel WAD and Wii common key for the iPhone build, then generates the app icon and
# the Settings page. Everything it writes lands in gitignored folders — no Nintendo data is ever committed.
#
#   tools/ios/stage_assets.sh [--wad path/to/HAFE.wad] [--key path/to/common-key.bin]
#
# Without arguments it uses ~/Library/Application Support/ForecastChannel/{HAFE.wad,common-key.bin} (where the Mac
# build looks too). Given paths are copied there as well, so the Mac tools (fcdump, ForecastMac) find them.
set -e
ROOT="$(cd "$(dirname $0)/../.." && pwd)"
SUPPORT="$HOME/Library/Application Support/ForecastChannel"
WAD="$SUPPORT/HAFE.wad"; KEY="$SUPPORT/common-key.bin"
while [ $# -gt 0 ]; do
  case "$1" in
    --wad) WAD="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    *) echo "usage: $0 [--wad HAFE.wad] [--key common-key.bin]"; exit 1 ;;
  esac
done
[ -f "$WAD" ] || { echo "missing WAD: $WAD (provide your own Forecast Channel WAD with --wad)"; exit 1; }
[ -f "$KEY" ] || { echo "missing common key: $KEY (provide your own with --key)"; exit 1; }

mkdir -p "$SUPPORT"
[ "$WAD" -ef "$SUPPORT/HAFE.wad" ] || cp "$WAD" "$SUPPORT/HAFE.wad"
[ "$KEY" -ef "$SUPPORT/common-key.bin" ] || cp "$KEY" "$SUPPORT/common-key.bin"

DST="$ROOT/iOS/Resources/Nintendo"
mkdir -p "$DST"
cp "$SUPPORT/HAFE.wad" "$SUPPORT/common-key.bin" "$DST/"

# Optional: AI-upscaled textures made by `swift run -c release fcupscale all` (needs Real-ESRGAN, see tools/upscale).
if [ -d "$SUPPORT/upscaled" ]; then
  rm -rf "$DST/upscaled"; cp -R "$SUPPORT/upscaled" "$DST/upscaled"
  echo "staged upscaled textures: $(ls "$DST/upscaled" | grep -c png)"
else
  echo "no upscaled textures (optional) — the app uses the original textures"
fi
echo "staged: $(ls "$DST" | tr '\n' ' ')"

# Tools for the next two steps.
(cd "$ROOT" && swift build -c release --product fcdump && swift build -c release --product fcdata)

# App icon: rendered from your WAD (the channel's hub gradient + its sunny icon).
ICONS="$ROOT/iOS/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONS"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$ROOT/iOS/Resources/Assets.xcassets/Contents.json"
cat > "$ICONS/Contents.json" <<'JSON'
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
JSON
FC_UPSCALE=1 "$ROOT/.build/release/fcdump" --icon "$ICONS/icon-1024.png" --scale 3.2

# iOS Settings page (units + the city list from the GeoNames-based catalog; no Nintendo data).
"$ROOT/.build/release/fcdata" settings-bundle "$ROOT/iOS/ForecastPhone/Settings.bundle/Root.plist"
echo "done — next: cd iOS && xcodegen && open ForecastPhone.xcodeproj"
