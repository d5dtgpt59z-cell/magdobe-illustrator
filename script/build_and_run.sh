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
CONFIGURATION=release
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then CONFIGURATION=debug; fi
swift build -c "$CONFIGURATION"
BUILD_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
python3 "$ROOT_DIR/script/app_bundle.py" --binary "$BUILD_BINARY" --output "$APP_BUNDLE" \
  --runtime-python "$HOME/Library/Application Support/Magdobe Illustrator/Runtime/bin/python"
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
