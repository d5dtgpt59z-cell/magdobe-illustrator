#!/usr/bin/env python3
"""Stage the separate AGPL CLI in an unsigned/ad-hoc PressCheck build helper.

Does not sign, publish, replace existing Ghostscript files or alter an approved
Developer ID artifact. The release builder signs nested code after staging.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from build_ghostscript import reuse


def stage(prefix, helper):
    if not (helper / "Contents/MacOS").is_dir() or not (helper / "Contents/Resources").is_dir():
        raise ValueError("Choose a staged PressCheckWorker.app with MacOS and Resources directories")
    signature = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=2", str(helper)], capture_output=True, text=True)
    if "Authority=Developer ID" in signature.stderr:
        raise ValueError("Refusing to change a Developer ID signed helper; stage a fresh release build")
    executable = helper / "Contents/MacOS/ghostscript-gs"
    resources = helper / "Contents/Resources/Ghostscript"
    if executable.exists() or resources.exists():
        raise ValueError("Ghostscript is already staged; use a fresh helper instead of overwriting it")
    source = reuse(prefix)
    with tempfile.TemporaryDirectory(prefix="magdobe-gs-stage-") as temporary:
        staged = Path(temporary)
        metadata = staged / "Ghostscript"
        metadata.mkdir()
        for name in ("notices", "corresponding-source"):
            shutil.copytree(prefix / name, metadata / name)
        for name in ("manifest.json", "README.txt"):
            shutil.copy2(prefix / name, metadata / name)
        try:
            shutil.copy2(source, executable)
            executable.chmod(0o755)
            shutil.copytree(metadata, resources)
        except Exception:
            executable.unlink(missing_ok=True)
            if resources.exists(): shutil.rmtree(resources)
            raise
    return {"executable": str(executable), "resources": str(resources), "signing": "Sign nested code before the enclosing helper/app"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(stage(args.prefix.resolve(), args.helper.resolve()), indent=2))
