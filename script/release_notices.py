#!/usr/bin/env python3
"""Collect redistributable component notices without build-machine paths."""
import argparse
import hashlib
import importlib.metadata
import json
import shutil
import sys
import sysconfig
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ("vtracer", "svgpathtools", "numpy", "scipy", "svgwrite", "certifi", "pyinstaller")


def license_file(path):
    return path.name.lower().startswith(("license", "copying", "notice", "copyright")) and path.is_file()


def collect(output, binaries):
    output.mkdir(parents=True, exist_ok=True)
    components = []

    def component(name, version, files):
        records = []
        for label, source in files:
            target = output / label
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            records.append({"path": label, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
        if not records:
            raise RuntimeError("No license notice found for " + name)
        components.append({"name": name, "version": version, "notices": records})

    component("Magdobe Illustrator", (ROOT / "VERSION").read_text().strip(), [("Magdobe-LICENSE.txt", ROOT / "LICENSE")])
    python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
    component("CPython", sys.version.split()[0], [("Python-LICENSE.txt", python_license)])
    upstream_notices = Path(sys.base_prefix).parent / "redistribution-notices"
    if not upstream_notices.is_dir():
        raise RuntimeError("The portable Python redistribution notice inventory is missing. Use the pinned build interpreter from script/fetch_release_python.py.")
    component("Portable CPython distribution notices", sys.version.split()[0],
              [(str(Path("python-distribution") / p.name), p) for p in sorted(upstream_notices.glob("LICENSE*.txt"))])
    for name in PACKAGES:
        distribution = importlib.metadata.distribution(name)
        notices = []
        for entry in distribution.files or []:
            source = Path(distribution.locate_file(entry))
            if license_file(source) and not Path(entry).is_absolute() and ".." not in Path(entry).parts:
                notices.append((str(Path(name) / entry), source))
        component(name, distribution.version, notices)

    # Include licenses for non-system libraries collected from a Homebrew formula.
    # This source manifest remains in .build and is never included in the app.
    formulae = {}
    for _, source, _ in json.loads(binaries.read_text()):
        resolved = Path(source).resolve()
        parts = resolved.parts
        if "Cellar" in parts:
            index = parts.index("Cellar")
            if len(parts) > index + 2:
                formulae[parts[index + 1]] = Path(*parts[:index + 3])
    for name, directory in sorted(formulae.items()):
        # CPython and its bundled components are covered by Python-LICENSE above.
        if name.startswith("python@"):
            continue
        notices = [(str(Path("native") / name / p.name), p) for p in directory.iterdir() if license_file(p)]
        if not notices:
            notices = [(str(Path("native") / name / p.relative_to(directory)), p)
                       for p in directory.glob("share/doc/**/*") if license_file(p)]
        component(name, directory.name, notices)
    (output / "manifest.json").write_text(json.dumps({"components": components}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--binaries", default=ROOT / ".build/frozen-artwork-work/bundled-binaries.json", type=Path)
    args = parser.parse_args()
    collect(args.output, args.binaries)
