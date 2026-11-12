#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="MagnusVector"
BUNDLE_ID="com.builtbymagnus.vector-editor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
APP_BUNDLE="$ROOT_DIR/dist/Magdobe Illustrator.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
./script/setup_artwork_runtime.sh
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
mkdir -p "$APP_CONTENTS/MacOS"
cp "$BUILD_BINARY" "$APP_BINARY.next"
chmod +x "$APP_BINARY.next"
mv -f "$APP_BINARY.next" "$APP_BINARY"
mkdir -p "$APP_CONTENTS/Resources/Artwork"
cp "$ROOT_DIR/Resources/Artwork/artwork_worker.py" "$APP_CONTENTS/Resources/Artwork/"
cp "$ROOT_DIR/Resources/AppIcon/Magdobe.icns" "$APP_CONTENTS/Resources/"
python3 - "$APP_CONTENTS/Resources/runtime.json" <<'PYCONFIG'
import json,os,shutil,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'python':str(Path.home()/'Library/Application Support/Magdobe Illustrator/Runtime/bin/python'),'codex':shutil.which('codex') or '/opt/homebrew/bin/codex'}))
PYCONFIG
cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Magdobe Illustrator</string>
<key>CFBundleDisplayName</key><string>Magdobe Illustrator</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>Magdobe</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.builtbymagnus.vector</string>
<key>UTTypeDescription</key><string>Magdobe Illustrator Project</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mvector</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Magdobe Illustrator Project</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>LSItemContentTypes</key><array><string>com.builtbymagnus.vector</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP_BUNDLE" >/dev/null
case "$MODE" in
 --build-only|build-only) echo "Magdobe Illustrator built; current app session left running." ;;
 run) /usr/bin/open -n "$APP_BUNDLE" ;;
 --debug|debug) lldb -- "$APP_BINARY" ;;
 --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
 --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
 --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "Magdobe Illustrator built and launched." ;;
 *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
