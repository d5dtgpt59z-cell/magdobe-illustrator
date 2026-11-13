#!/usr/bin/env bash
# Creates a self-contained, locally signed preview. Developer ID signing is separate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
RELEASE_DIR="$ROOT_DIR/dist/release"
if [[ -e "$RELEASE_DIR/Magdobe Illustrator.app" ]]; then
  echo "Release app already exists. Move it aside before rebuilding; signed artifacts are never overwritten." >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export MAGDOBE_RELEASE_ARCH="${MAGDOBE_RELEASE_ARCH:-$(uname -m)}"
case "$MAGDOBE_RELEASE_ARCH" in arm64|x86_64) ;; *) echo "Build on an Apple Silicon or Intel Mac with a matching Python 3.11 runtime." >&2; exit 1;; esac
BUILD_PYTHON="${MAGDOBE_BUILD_PYTHON:-$(python3 script/fetch_release_python.py --arch "$MAGDOBE_RELEASE_ARCH")}"
BUILD_ENV="$ROOT_DIR/.build/distribution-build-env"
"$BUILD_PYTHON" -c 'import sys; assert sys.version_info[:2] == (3, 11), "Release packaging requires Python 3.11"'
if [[ ! -x "$BUILD_ENV/bin/python" ]]; then "$BUILD_PYTHON" -m venv "$BUILD_ENV"; fi
"$BUILD_ENV/bin/python" -c 'import pathlib,sys; assert pathlib.Path(sys.base_prefix).resolve() == pathlib.Path(sys.argv[1]).resolve(), "Build environment uses another Python; move .build/distribution-build-env aside"' "$("$BUILD_PYTHON" -c 'import sys; print(sys.base_prefix)')"
"$BUILD_ENV/bin/python" -c 'import platform,os; assert platform.machine() == os.environ["MAGDOBE_RELEASE_ARCH"], "Python architecture must match release architecture"'
"$BUILD_ENV/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: -r script/release-requirements.txt
swift build -c release --arch "$MAGDOBE_RELEASE_ARCH" \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=." \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."
BUILD_BINARY="$(swift build -c release --arch "$MAGDOBE_RELEASE_ARCH" --show-bin-path)/MagnusVector"
STAGE="$ROOT_DIR/.build/distribution-stage"
if [[ -d "$STAGE" ]]; then rm -rf "$STAGE"; fi
mkdir -p "$STAGE"
APP="$STAGE/Magdobe Illustrator.app"
"$BUILD_ENV/bin/python" script/app_bundle.py --binary "$BUILD_BINARY" --output "$APP" --build-number "${MAGDOBE_BUILD_NUMBER:-3}"
# Distribution binaries do not need local symbols or builder/source paths.
/usr/bin/xcrun strip -S -x "$APP/Contents/MacOS/MagnusVector"
"$BUILD_ENV/bin/python" -m PyInstaller --noconfirm --clean --distpath "$ROOT_DIR/.build/frozen-artwork" --workpath "$ROOT_DIR/.build/frozen-artwork-work" script/ArtworkWorker.spec
mkdir -p "$APP/Contents/Helpers"
/usr/bin/ditto "$ROOT_DIR/.build/frozen-artwork/MagdobeArtworkWorker.app" "$APP/Contents/Helpers/MagdobeArtworkWorker.app"
"$BUILD_ENV/bin/python" script/release_notices.py --output "$APP/Contents/Resources/ThirdPartyNotices"
# Developer tools and package caches may have owner-only permissions.
/bin/chmod -R a+rX "$APP"
"$BUILD_ENV/bin/python" script/prepare_portable_bundle.py --app "$APP"
"$BUILD_ENV/bin/python" script/release.py verify --app "$APP" --mode preview --arch "$MAGDOBE_RELEASE_ARCH" --json
mkdir -p "$RELEASE_DIR"
/bin/mv "$APP" "$RELEASE_DIR/Magdobe Illustrator.app"
echo "Prepared $RELEASE_DIR/Magdobe Illustrator.app"
echo "This is an ad-hoc preview. Follow docs/macos-distribution.md to sign and notarize before public download."
