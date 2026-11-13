#!/usr/bin/env python3
"""Fetch the pinned portable build interpreter; never install into the user's OS."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def download(record, archive):
    if not archive.is_file():
        subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--max-time", "180", "--output", str(archive), record["url"]], check=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != record["sha256"]:
        raise RuntimeError("Portable Python checksum mismatch; nothing was installed or executed.")


def fetch_notices(directory, record):
    target = directory / "redistribution-notices"
    receipt = target / "source.json"
    if receipt.is_file() and json.loads(receipt.read_text()) == record and list(target.glob("LICENSE*.txt")):
        return
    if target.exists():
        raise RuntimeError("Incomplete Python notice cache. Move it aside before retrying: " + str(target))
    cache = ROOT / ".build/release-downloads"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (record["sha256"] + ".tar.zst")
    print("Fetching portable Python redistribution notices…", file=sys.stderr)
    download(record, archive)
    listing = subprocess.check_output(["/usr/bin/tar", "-tf", str(archive)], text=True).splitlines()
    members = [name for name in listing if name.startswith("python/licenses/LICENSE") and Path(name).name == name[len("python/licenses/"):]]
    if not members:
        raise RuntimeError("The upstream Python archive is missing its license inventory.")
    with tempfile.TemporaryDirectory(prefix="release-notices-", dir=directory) as temporary:
        stage = Path(temporary)
        subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(stage)] + members, check=True)
        notices = stage / "python/licenses"
        (notices / "source.json").write_text(json.dumps(record, indent=2) + "\n")
        notices.rename(target)


def fetch(architecture):
    lock = json.loads((ROOT / "script/release-python.json").read_text())
    specification = lock["architectures"][architecture]
    record = {name: specification[name] for name in ("url", "sha256")}
    directory = ROOT / ".build" / ("release-python-" + lock["version"] + "-" + lock["build"] + "-" + architecture)
    receipt = directory / "download.json"
    executable = directory / "python/bin/python3.11"
    if executable.is_file() and receipt.is_file() and json.loads(receipt.read_text()) == record:
        fetch_notices(directory, specification["licenseArchive"])
        return executable
    if directory.exists():
        raise RuntimeError("Incomplete portable Python download. Move this cache aside before retrying: " + str(directory))
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-python-", dir=directory.parent) as temporary:
        stage = Path(temporary)
        archive = stage / "python.tar.gz"
        print("Fetching pinned portable Python " + lock["version"] + " for " + architecture + "…", file=sys.stderr)
        download(record, archive)
        # Only the exact pinned, authenticated vendor archive is extracted.
        subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(stage)], check=True)
        archive.unlink()
        if not (stage / "python/bin/python3.11").is_file():
            raise RuntimeError("The portable Python archive has an unexpected layout.")
        (stage / "download.json").write_text(json.dumps(record, indent=2) + "\n")
        stage.rename(directory)
    fetch_notices(directory, specification["licenseArchive"])
    return executable


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], required=True)
    args = parser.parse_args()
    print(fetch(args.arch))
