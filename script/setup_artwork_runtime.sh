#!/usr/bin/env bash
set -euo pipefail
RUNTIME_DIR="$HOME/Library/Application Support/Magdobe Illustrator/Runtime"
if [[ ! -x "$RUNTIME_DIR/bin/python" ]]; then
  python3 -m venv "$RUNTIME_DIR"
fi
if ! "$RUNTIME_DIR/bin/python" -c 'import vtracer,svgpathtools' >/dev/null 2>&1; then
  "$RUNTIME_DIR/bin/python" -m pip install --disable-pip-version-check vtracer==0.6.15 svgpathtools==1.8.0
fi
