#!/usr/bin/env python3
"""Build the pinned, separately licensed local checker; never use user project data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run([str(v) for v in command], check=True, **kwargs)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_tree(override=None):
    lock = json.loads((ROOT / "script/presscheck-source.json").read_text())
    revision = lock["revision"]
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise RuntimeError("Pin a verified PressCheck source revision before packaging")
    source = Path(override).resolve() if override else ROOT / ".build/presscheck-source"
    if not override:
        if not (source / ".git").is_dir():
            run(["git", "clone", "--no-checkout", "--filter=blob:none", lock["repository"], source])
        run(["git", "fetch", "origin", revision], cwd=source)
        run(["git", "checkout", "--detach", revision], cwd=source)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True)
    if actual != revision or dirty:
        raise RuntimeError("PressCheck must be a clean checkout of the pinned source revision")
    return source, revision


def browser_notices(frontend, output):
    """Retain upstream notices, including Next's compiled runtime components."""
    modules = frontend / "node_modules"
    destination = output / "ThirdPartyNotices/npm"
    records = []
    for file in sorted(modules.rglob("*")):
        if not file.is_file() or not file.name.lower().startswith(("license", "copying", "notice", "copyright")):
            continue
        relative = file.relative_to(modules)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, target)
        records.append({"path": relative.as_posix(), "sha256": sha256(target)})
    for package in ("next", "react", "react-dom", "scheduler"):
        if not any(item["path"].startswith(package + "/") for item in records):
            raise RuntimeError("Missing browser runtime notice for " + package)
    (destination / "manifest.json").write_text(json.dumps({"notices": records}, indent=2) + "\n")
    shutil.copyfile(frontend / "package-lock.json", destination / "package-lock.json")


def upstream_sources(output):
    """Ship verified source archives for the independently licensed renderer."""
    manifest = json.loads((ROOT / "script/third-party-sources.json").read_text())
    destination = output / "ThirdPartySources"
    destination.mkdir(parents=True, exist_ok=True)
    cache = ROOT / ".build/release-downloads"
    cache.mkdir(parents=True, exist_ok=True)
    for record in manifest["sources"]:
        url, expected = record["url"], record["sha256"]
        parsed = urllib.parse.urlsplit(url)
        filename = Path(parsed.path).name
        if parsed.scheme != "https" or not filename.endswith(".tar.gz") or not re.fullmatch(r"[a-f0-9]{64}", expected):
            raise RuntimeError("Invalid pinned upstream source record")
        archive = cache / filename
        if not archive.is_file() or sha256(archive) != expected:
            temporary = archive.with_suffix(".download")
            try:
                with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as stream:
                    if urllib.parse.urlsplit(response.url).scheme != "https":
                        raise RuntimeError("Upstream source redirect must use HTTPS")
                    size = 0
                    while chunk := response.read(1024 * 1024):
                        size += len(chunk)
                        if size > 2 * 1024 ** 3:
                            raise RuntimeError("Upstream source exceeds the archive limit")
                        stream.write(chunk)
                digest = sha256(temporary)
                if digest != expected:
                    raise RuntimeError("Upstream source checksum does not match " + record["name"])
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
        shutil.copyfile(archive, destination / filename)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (destination / "README.txt").write_text(
        "Exact upstream renderer source archives used by the separately licensed PressCheck worker.\n"
        "Versions, official download locations and SHA-256 checksums are in manifest.json.\n"
        "The worker's complete application source and build instructions are in ../PressCheck-source.zip;\n"
        "the Magdobe build scripts and pinned dependencies are available in the public Magdobe repository.\n"
        "GNU AGPL-3.0 and original vendor notices are retained in the application notice inventory.\n")


def build(output, override=None):
    source, revision = source_tree(override)
    if output.exists():
        raise RuntimeError("The PressCheck destination already exists; previous bundles are preserved")
    environment = dict(os.environ, PRESSCHECK_DESKTOP_EXPORT="1", NEXT_TELEMETRY_DISABLED="1")
    run(["npm", "ci", "--ignore-scripts"], cwd=source / "frontend", env=environment)
    run(["npm", "run", "build"], cwd=source / "frontend", env=environment)
    if not (source / "frontend/out/production/index.html").is_file():
        raise RuntimeError("The static production workspace did not build")
    environment["MAGDOBE_PRESSCHECK_SOURCE"] = str(source)
    run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--distpath", ROOT / ".build/frozen-presscheck",
         "--workpath", ROOT / ".build/frozen-presscheck-work", ROOT / "script/PressCheckWorker.spec"], env=environment)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / ".build/frozen-presscheck/PressCheckWorker.app", output, symlinks=True)
    resources = output / "Contents/Resources"
    (resources / "source-revision.json").write_text(json.dumps({"repository": "https://github.com/d5dtgpt59z-cell/presscheck", "revision": revision}) + "\n")
    # Ship the exact source used to build this independent AGPL helper.
    run(["git", "archive", "--format=zip", "--output", resources / "PressCheck-source.zip", revision], cwd=source)
    shutil.copyfile(source / "LICENSE", resources / "PressCheck-LICENSE.txt")
    browser_notices(source / "frontend", resources)
    upstream_sources(resources)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    build(args.output, args.source)
