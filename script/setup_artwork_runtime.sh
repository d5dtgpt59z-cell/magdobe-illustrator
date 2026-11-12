#!/usr/bin/env bash
set -euo pipefail
RUNTIME_DIR="$HOME/Library/Application Support/Magdobe Illustrator/Runtime"
PYTHON_COMMAND="${MAGDOBE_PYTHON:-python3}"
if [[ -x "$RUNTIME_DIR/bin/python" ]]; then
  PYTHON_COMMAND="$RUNTIME_DIR/bin/python"
fi
# VTracer 0.6.15 can build on newer Python versions yet crash when tracing.
# Keep a working existing runtime, and fail clearly before creating an unsafe one.
if ! "$PYTHON_COMMAND" -c 'import sys; sys.exit(not ((3, 9) <= sys.version_info[:2] < (3, 15)))' >/dev/null 2>&1; then
  echo "Magdobe vector tracing requires Python 3.9–3.14; Python 3.11 is recommended." >&2
  echo "For a new runtime, set MAGDOBE_PYTHON to a supported Python executable and rebuild." >&2
  echo "If the existing Runtime uses another version, move it aside first; keep the neighboring Artwork folder." >&2
  exit 1
fi
if [[ ! -x "$RUNTIME_DIR/bin/python" ]]; then
  "$PYTHON_COMMAND" -m venv "$RUNTIME_DIR"
fi
if ! "$RUNTIME_DIR/bin/python" -c 'import vtracer,svgpathtools' >/dev/null 2>&1; then
  "$RUNTIME_DIR/bin/python" -m pip install --disable-pip-version-check vtracer==0.6.15 svgpathtools==1.8.0
fi
