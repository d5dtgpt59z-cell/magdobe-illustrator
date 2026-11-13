# Build-time only: a console worker in a standard nested macOS app bundle.
import os
import json
from pathlib import Path
from PyInstaller.utils.hooks import copy_metadata

root = Path(SPECPATH).parent
metadata = []
for package in ("vtracer", "svgpathtools", "numpy", "scipy", "svgwrite", "certifi"):
    # Upstream wheel SBOMs can contain their builder's personal filesystem paths.
    # Runtime metadata and licenses remain; our own notice manifest lists versions.
    for source, target in copy_metadata(package):
        directory = Path(source)
        for file in directory.rglob("*"):
            relative = file.relative_to(directory)
            if file.is_file() and "sboms" not in relative.parts:
                metadata.append((str(file), str(Path(target) / relative.parent)))

a = Analysis(
    [str(root / "Resources/Artwork/artwork_worker.py")],
    pathex=[str(root / "Resources/Artwork")],
    binaries=[],
    datas=metadata,
    hiddenimports=["certifi"],
    hookspath=[],
    runtime_hooks=[str(root / "script/frozen_artwork_runtime.py")],
    excludes=["tkinter", "matplotlib", "IPython", "pytest", "unittest", "pydoc"],
    noarchive=False,
    optimize=1,
)
(root / ".build/frozen-artwork-work/bundled-binaries.json").write_text(json.dumps(list(a.binaries)))
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="MagdobeArtworkWorker",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    argv_emulation=False,
    target_arch=os.environ.get("MAGDOBE_RELEASE_ARCH", "arm64"),
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="MagdobeArtworkWorker")
app = BUNDLE(
    coll,
    name="MagdobeArtworkWorker.app",
    bundle_identifier="com.builtbymagnus.vector-editor.artwork-worker",
    version=(root / "VERSION").read_text().strip(),
    info_plist={"LSUIElement": True, "LSMinimumSystemVersion": "14.0"},
)
