#!/usr/bin/env python3
"""Stage the shared native bundle without launching or signing it."""
import argparse
import json
import plistlib
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def stage(binary, output, runtime_python=None, build_number="3"):
    contents = output / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    (resources / "Artwork").mkdir(parents=True, exist_ok=True)
    target = contents / "MacOS/MagnusVector"
    temporary = target.with_suffix(".next")
    shutil.copy2(binary, temporary)
    temporary.chmod(0o755)
    temporary.replace(target)
    for name in ("artwork_worker.py", "provider_api.py"):
        shutil.copy2(ROOT / "Resources/Artwork" / name, resources / "Artwork" / name)
    shutil.copy2(ROOT / "Resources/AppIcon/Magdobe.icns", resources / "Magdobe.icns")
    runtime = resources / "runtime.json"
    if runtime_python:
        # Development builds only. Distributed builds use the nested helper.
        runtime.write_text(json.dumps({"python": str(runtime_python), "codex": ""}))
    elif runtime.exists():
        runtime.unlink()
    info = {
        "CFBundleExecutable": "MagnusVector",
        "CFBundleIdentifier": "com.builtbymagnus.vector-editor",
        "CFBundleName": "Magdobe Illustrator",
        "CFBundleDisplayName": "Magdobe Illustrator",
        "CFBundleVersion": str(build_number),
        "CFBundleShortVersionString": (ROOT / "VERSION").read_text().strip(),
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "14.0",
        "NSPrincipalClass": "NSApplication",
        "CFBundleIconFile": "Magdobe",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Copyright © 2026 Built by Magnus. MIT-licensed source.",
        "UTExportedTypeDeclarations": [{
            "UTTypeIdentifier": "com.builtbymagnus.vector",
            "UTTypeDescription": "Magdobe Illustrator Project",
            "UTTypeConformsTo": ["public.json"],
            "UTTypeTagSpecification": {"public.filename-extension": ["mvector"]},
        }],
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Magdobe Illustrator Project",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Owner",
            "LSItemContentTypes": ["com.builtbymagnus.vector"],
        }],
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime-python", type=Path)
    parser.add_argument("--build-number", default="3")
    args = parser.parse_args()
    stage(args.binary, args.output, args.runtime_python, args.build_number)
