"""Separate AGPL PressCheck executable, with a static local production console."""
import json
import os
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, copy_metadata

root = Path(SPECPATH).parent
source = Path(os.environ["MAGDOBE_PRESSCHECK_SOURCE"])
datas = [(str(source / "frontend/out"), "web")]
binaries = []
hidden = ["presscheck.structure", "presscheck.production_pdf", "presscheck.pdfx_audit", "pikepdf", "lxml.etree"]
for module in ("pymupdf",):
    d, b, h = collect_all(module, filter_submodules=lambda name: not name.startswith("pymupdf.layout"),
                          exclude_datas=["layout/**", "**/layout/**"])
    datas += d; binaries += b; hidden += h
for package in ("defusedxml", "pydantic", "pydantic_core", "Pillow", "PyMuPDF", "pikepdf", "lxml"):
    for original, destination in copy_metadata(package):
        directory = Path(original)
        for file in directory.rglob("*"):
            relative = file.relative_to(directory)
            if file.is_file() and "sboms" not in relative.parts:
                datas.append((str(file), str(Path(destination) / relative.parent)))

a = Analysis([str(source / "scripts/desktop_entry.py")], pathex=[str(source / "backend")],
    binaries=binaries, datas=datas, hiddenimports=hidden, hookspath=[], runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "IPython", "pytest", "unittest", "cv2", "pytesseract",
              "fastapi", "sqlalchemy", "uvicorn", "numpy", "scipy", "pymupdf4llm", "pymupdf.layout", "onnxruntime"],
    noarchive=False, optimize=1)
(root / ".build/frozen-presscheck-work/bundled-binaries.json").write_text(json.dumps(list(a.binaries)))
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="PressCheckWorker", debug=False,
    bootloader_ignore_signals=False, strip=False, upx=False, console=True,
    target_arch=os.environ.get("MAGDOBE_RELEASE_ARCH", "arm64"), codesign_identity=None)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="PressCheckWorker")
app = BUNDLE(coll, name="PressCheckWorker.app", bundle_identifier="com.builtbymagnus.vector-editor.presscheck-worker",
    version=(root / "VERSION").read_text().strip(),
    info_plist={"LSUIElement": True, "LSMinimumSystemVersion": "14.0"})
