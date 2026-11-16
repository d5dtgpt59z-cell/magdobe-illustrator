#!/usr/bin/env python3
"""Build the pinned AGPL Ghostscript CLI with ROM resources and system-only dylibs.

This developer-only recipe downloads authenticated source and never installs into
macOS, Homebrew or a signed app. The output carries the exact corresponding source
archive, unmodified license texts and this complete recipe. Release signing remains
an explicit later step. No upstream source patches are applied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "script/ghostscript-source.json"
OPTIONS = ["--prefix=/magdobe/ghostscript", "--without-x", "--disable-cups", "--disable-fontconfig",
           "--disable-dbus", "--disable-gtk", "--without-tesseract", "--without-libidn", "--without-libpaper",
           "--without-ijs", "--without-urf", "--without-so", "--without-cal", "--without-pdftoraster",
           "--enable-compile-inits", "--enable-mkromfs-quiet", "--with-fontpath="]


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""): digest.update(block)
    return digest.hexdigest()


def run(command, *, cwd=None, env=None, log=None):
    if log:
        with log.open("w") as stream:
            try: subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
            except subprocess.CalledProcessError as error:
                print(log.read_text(errors="replace")[-12000:], file=sys.stderr)
                raise RuntimeError("Ghostscript build failed; inspect " + str(log)) from error
    else: subprocess.run(command, cwd=cwd, env=env, check=True)


def target_architecture(value=None):
    architecture = value or os.environ.get("MAGDOBE_RELEASE_ARCH", platform.machine())
    if architecture not in ("arm64", "x86_64"): raise RuntimeError("Choose the native arm64 or x86_64 release architecture")
    return architecture


def portable_env(architecture):
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    # Do not inherit SDK search paths, package-manager flags, provider secrets or GS_LIB.
    flags = "-O2 -arch " + architecture + " -mmacosx-version-min=14.0 -isysroot " + sdk + " -ffile-prefix-map=" + str(ROOT) + "=. -fdebug-prefix-map=" + str(ROOT) + "=."
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "TMPDIR": "/tmp",
            "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++", "CFLAGS": flags, "CXXFLAGS": flags,
            "LDFLAGS": "-arch " + architecture + " -mmacosx-version-min=14.0 -isysroot " + sdk,
            "MACOSX_DEPLOYMENT_TARGET": "14.0", "SDKROOT": sdk, "PKG_CONFIG": "/usr/bin/false"}


def verify(executable, record, expected_architecture=None):
    expected_architecture = target_architecture(expected_architecture)
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).strip()
    if architecture != expected_architecture: raise RuntimeError("Ghostscript must contain only the selected native " + expected_architecture + " architecture")
    libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(executable)], text=True)
    dependencies = [line.strip().split(" (", 1)[0] for line in libraries.splitlines()[1:]]
    if not dependencies or any(not path.startswith(("/usr/lib/", "/System/Library/")) for path in dependencies):
        raise RuntimeError("Ghostscript has a non-system dynamic dependency: " + libraries)
    loads = subprocess.check_output(["/usr/bin/otool", "-l", str(executable)], text=True)
    match = re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([0-9.]+)", loads)
    if not match or tuple(map(int, match.group(1).split("."))) > (14, 0):
        raise RuntimeError("Ghostscript's macOS deployment target exceeds 14.0")
    version = subprocess.check_output([str(executable), "--version"], env={"PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"}, text=True).strip()
    if version != record["version"]: raise RuntimeError("Unexpected Ghostscript version: " + version)
    with tempfile.TemporaryDirectory(prefix="magdobe-gs-portable-") as directory:
        # A copied executable has no adjacent source, fonts or initialization files.
        relocated = Path(directory) / "gs"
        shutil.copy2(executable, relocated)
        probe = "(%rom%Resource/Init/gs_init.ps) (r) file closefile (%rom%iccprofiles/default_cmyk.icc) (r) file closefile /Helvetica findfont pop quit"
        subprocess.run([str(relocated), "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=nullpage", "-c", probe], cwd=directory,
                       env={"PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"}, check=True, capture_output=True)
    return {"architecture": architecture, "minimum_macos": match.group(1), "dependencies": dependencies,
            "version": version, "executable_sha256": sha(executable), "rom_resource_probe": "pass"}


def collect_resource_notices(source, notices):
    # CMap redistribution notices are embedded in each resource's comment header,
    # rather than a file called LICENSE. Preserve them with their original paths.
    records = []
    for directory, prefix in (("CMap", b"%%Copyright:"), ("Font", b"% Copyright")):
        for path in sorted((source / "Resource" / directory).iterdir()):
            if not path.is_file(): continue
            header = path.read_bytes()[:24000].splitlines()
            lines = [line for line in header if line.startswith(prefix)]
            if lines:
                records.append("Resource/" + directory + "/" + path.name + "\n" + b"\n".join(lines).decode("utf-8", errors="replace"))
    (notices / "RESOURCE-COPYRIGHTS.txt").write_text("\n\n".join(records) + "\n", encoding="utf-8")


def reuse(output, architecture=None):
    record = json.loads(LOCK.read_text())
    receipt = json.loads((output / "manifest.json").read_text())
    if receipt["source"] != record: raise RuntimeError("Cached Ghostscript source receipt differs from the pinned version")
    executable = output / "bin/gs"
    if sha(executable) != receipt["executable_sha256"]: raise RuntimeError("Cached Ghostscript executable changed; use a fresh build directory")
    if sha(output / "corresponding-source" / (record["source_root"] + ".tar.xz")) != record["sha256"]:
        raise RuntimeError("Cached Ghostscript corresponding-source archive changed")
    if not (output / "notices/doc/COPYING").is_file() or not (output / "notices/LICENSE").is_file():
        raise RuntimeError("Cached Ghostscript redistribution licenses are missing")
    verify(executable, record, architecture)
    return executable


def build(output, jobs, architecture=None):
    architecture = target_architecture(architecture)
    if platform.system() != "Darwin" or platform.machine() != architecture:
        raise RuntimeError("Build this recipe on a matching native " + architecture + " Mac; cross-compilation is not supported")
    if output.exists(): raise RuntimeError("Output already exists; use a new output directory instead of replacing a release artifact")
    record = json.loads(LOCK.read_text())
    cache = ROOT / ".build/release-downloads"; cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (record["source_root"] + ".tar.xz")
    if not archive.is_file():
        temporary = archive.with_suffix(".download")
        run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--retry", "3", "--connect-timeout", "20", "--max-time", "600", "--output", str(temporary), record["url"]])
        if sha(temporary) != record["sha256"]: temporary.unlink(); raise RuntimeError("Ghostscript source checksum mismatch; nothing was executed")
        temporary.rename(archive)
    if sha(archive) != record["sha256"]: raise RuntimeError("Cached Ghostscript source checksum mismatch; nothing was executed")
    work = ROOT / ".build" / (record["source_root"] + "-" + architecture)
    if work.exists(): raise RuntimeError("Build work already exists; move it aside before retrying: " + str(work))
    work.mkdir(parents=True)
    run(["/usr/bin/tar", "-xJf", str(archive), "-C", str(work)])
    source = work / record["source_root"]
    environment = portable_env(architecture)
    options = [*OPTIONS, "--with-drivers=" + ",".join(record["devices"])]
    print("Configuring Ghostscript " + record["version"] + "…", file=sys.stderr, flush=True)
    run(["./configure", *options], cwd=source, env=environment, log=work / "configure.log")
    print("Building Ghostscript with bundled libraries and ROM resources…", file=sys.stderr, flush=True)
    run(["/usr/bin/make", "-j" + str(jobs)], cwd=source, env=environment, log=work / "make.log")
    with tempfile.TemporaryDirectory(prefix="ghostscript-stage-", dir=work) as temporary:
        stage = Path(temporary)
        executable = stage / "bin/gs"; executable.parent.mkdir()
        shutil.copy2(source / "bin/gs", executable)
        run(["/usr/bin/xcrun", "strip", "-S", "-x", str(executable)])
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)])
        receipt = verify(executable, record, architecture)
        notices = stage / "notices"; notices.mkdir()
        # Exact source includes all upstream and bundled third-party license texts.
        # A convenient expanded notice inventory is also provided for reviewers.
        for path in source.rglob("*"):
            if path.is_file() and path.name.lower().startswith(("license", "copying", "copyright", "notice")) and not any(part in ("obj", "bin", ".git") for part in path.relative_to(source).parts):
                target = notices / path.relative_to(source); target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, target)
        shutil.copy2(source / "DroidSansFallback.NOTICE", notices / "DroidSansFallback.NOTICE")
        collect_resource_notices(source, notices)
        corresponding = stage / "corresponding-source"; corresponding.mkdir()
        shutil.copy2(archive, corresponding / archive.name)
        shutil.copy2(Path(__file__), corresponding / Path(__file__).name)
        shutil.copy2(LOCK, corresponding / LOCK.name)
        for name in ("stage_ghostscript.py", "test_ghostscript_pdfx4.py"):
            if (ROOT / "script" / name).is_file(): shutil.copy2(ROOT / "script" / name, corresponding / name)
        (corresponding / "BUILD.txt").write_text("Ghostscript " + record["version"] + "\nUnmodified official source archive, SHA-256 " + record["sha256"] + "\nBuild on a matching native " + architecture + " Mac with Apple command-line tools and Python 3.9+.\nPlace the two recipe files in an empty repository's script/ directory and run:\n  python3 script/build_ghostscript.py --arch " + architecture + " --output /absolute/new/prefix\nNo cross-compilation is supported. Only the actual built architecture is verified.\nNo Homebrew or other third-party build libraries are required.\nThe embedded ICC defaults are engine resources, not an approved printing condition.\nUse a supplier-specified output profile for actual print jobs.\n", encoding="utf-8")
        receipt.update({"source": record, "configure_options": options, "compiler": "/usr/bin/clang", "source_patches": [], "resources": "ROM embedded Resource/ and iccprofiles/", "signing": "local ad-hoc; release signing is separate"})
        (stage / "manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
        (stage / "README.txt").write_text("Ghostscript CLI for Magdobe/PressCheck\nGNU AGPL v3 or later; see notices/LICENSE and notices/doc/COPYING.\nBundled source, third-party notices and complete build recipe: corresponding-source/.\nPDF/X output must still be independently validated; a successful conversion is not certification.\nNo end-user Python, Homebrew or Xcode dependency.\n")
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stage, output)
    return output / "bin/gs"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default=target_architecture())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument("--verify", type=Path, help="Verify an existing standalone executable instead of building")
    parser.add_argument("--reuse", action="store_true", help="Reuse only a verified, unchanged cached prefix; otherwise build if absent")
    args = parser.parse_args()
    args.output = args.output or ROOT / (".build/portable-ghostscript-" + args.arch)
    if not 1 <= args.jobs <= 32: parser.error("Use 1–32 build jobs")
    try:
        if args.verify: print(json.dumps(verify(args.verify, json.loads(LOCK.read_text()), args.arch), indent=2))
        elif args.reuse and args.output.exists(): print(reuse(args.output.resolve(), args.arch))
        else: print(build(args.output.resolve(), args.jobs, args.arch))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr); raise SystemExit(1)
