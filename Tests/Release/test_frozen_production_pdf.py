"""Actual frozen CMYK/PDF-X workflow, relocated and without developer runtimes.

Set MAGDOBE_TEST_APP to the built 0.10+ app. All artwork is synthetic: 2,199
independent vector paths and a test-only upstream Ghostscript CMYK profile.
These generated-vector checks are not independent ISO PDF/X certification.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP = ROOT / "dist/release-0.10.0/Magdobe Illustrator.app"
if not DEFAULT_APP.is_dir(): DEFAULT_APP = ROOT / "dist/release/Magdobe Illustrator.app"
APP = Path(os.environ.get("MAGDOBE_TEST_APP", DEFAULT_APP))
CHECKER_APP = APP / "Contents/Helpers/PressCheckWorker.app"
WORKER = CHECKER_APP / "Contents/MacOS/PressCheckWorker"
GS = CHECKER_APP / "Contents/MacOS/ghostscript-gs"
SOURCE_SHA256 = "c20492bc8ebb96c87fa2e52a0926e1cda8cde95d66145e018ac713fed5da38cf"
PROFILE_MEMBER = "ghostscript-10.08.0/iccprofiles/default_cmyk.icc"


def sha(data): return hashlib.sha256(data).hexdigest()


def pdf_fixture():
    """Exactly 2,199 outlined RGB vector paints, with a real transparency group."""
    shapes = []
    for index in range(2199):
        x, y = 12 + index % 47 * 3.6, 12 + index // 47 * 5
        r, g, b = ((index * factor) % 251 / 250 for factor in (13, 37, 79))
        shapes.append(f"{r:.5f} {g:.5f} {b:.5f} rg {x:.2f} {y:.2f} m {x+1:.2f} {y-1:.2f} {x+2:.2f} {y-1:.2f} {x+3:.2f} {y:.2f} c {x+3:.2f} {y+3:.2f} l {x:.2f} {y+3:.2f} l h f\n")
    stream = ("q /GS1 gs\n" + "".join(shapes) + "Q\n").encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 198 270] /CropBox [0 0 198 270] /TrimBox [9 9 189 261] /BleedBox [0 0 198 270] /Contents 4 0 R /Group << /S /Transparency /CS /DeviceRGB >> /Resources << /ExtGState << /GS1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
        b"<< /Type /ExtGState /ca 0.5 /CA 0.5 >>"]
    data = b"%PDF-1.6\n%\xe2\xe3\xcf\xd3\n"; offsets = []
    for number, value in enumerate(objects, 1):
        offsets.append(len(data)); data += str(number).encode() + b" 0 obj\n" + value + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
    return data + f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()


def job_fixture(profile, target):
    return {"schema_version": 1, "workflow": "trading_card", "name": "Synthetic 2199 CMYK / TEST ONLY",
        "trim_width_mm": 63.5, "trim_height_mm": 88.9, "bleed_mm": 3.175, "safe_mm": 3.175,
        "bleed_intent": "full_bleed", "color_policy": "cmyk", "supplier_confirmed": False,
        "placement": "fill_bleed", "printer_notes": "Synthetic test only; not a supplier-approved print condition",
        "pdf": {"schema_version": 1, "target": target,
            "icc_profile": {"sha256": sha(profile), "name": "TEST ONLY - Ghostscript default CMYK"},
            "output_condition_identifier": "Magdobe-fixture-NOT-PRODUCTION", "output_condition": "TEST FIXTURE ONLY",
            "registry_name": "", "rendering_intent": "relative_colorimetric", "black_point_compensation": False,
            "black_policy": "icc", "text_mode": "outlines"}}


@unittest.skipUnless(WORKER.is_file() and GS.is_file(), "Build the 0.10+ Ghostscript distribution or set MAGDOBE_TEST_APP")
class FrozenProductionPDFTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try: import pikepdf
        except ImportError as error: raise RuntimeError("Run release integration tests with the pinned release build environment (pikepdf required)") from error
        cls.pikepdf = pikepdf
        cls.temporary = tempfile.TemporaryDirectory(prefix="Magdobe Frozen CMYK ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.relocated = cls.directory / "Relocated Production Only/PressCheckWorker.app"
        cls.relocated.parent.mkdir()
        shutil.copytree(CHECKER_APP, cls.relocated, symlinks=True)
        cls.worker = cls.relocated / "Contents/MacOS/PressCheckWorker"
        cls.home = cls.directory / "Fresh Home"; cls.home.mkdir(mode=0o700)
        cls.working = cls.directory / "Empty Working Directory"; cls.working.mkdir()
        traps = cls.directory / "Unavailable Developer Tools"; traps.mkdir()
        cls.trap = cls.directory / "unexpected-runtime.txt"
        for name in ("python", "python3", "node", "npm", "uv", "codex", "gs", "ghostscript"):
            path = traps / name
            path.write_text('#!/bin/sh\necho unexpected-runtime >> "$MAGDOBE_TEST_RUNTIME_TRAP"\nexit 77\n')
            path.chmod(0o755)
        cls.env = {"HOME": str(cls.home), "PATH": str(traps) + ":/usr/bin:/bin", "LANG": "en_US.UTF-8",
                   "TMPDIR": str(cls.directory), "PYTHONNOUSERSITE": "1", "MAGDOBE_TEST_RUNTIME_TRAP": str(cls.trap)}
        archive = cls.relocated / "Contents/Resources/Ghostscript/corresponding-source/ghostscript-10.08.0.tar.xz"
        digest = hashlib.sha256()
        with archive.open("rb") as stream:
            for block in iter(lambda: stream.read(1024*1024), b""): digest.update(block)
        if digest.hexdigest() != SOURCE_SHA256: raise AssertionError("Test-only profile source archive is not the pinned upstream source")
        # Never extract paths from the archive. Read this one known regular member,
        # bounded before and after reading, and label the profile test-only.
        with tarfile.open(archive, "r:xz") as source:
            member = source.getmember(PROFILE_MEMBER)
            if not member.isfile() or not 128 <= member.size <= 16*1024*1024: raise AssertionError("Invalid test ICC archive member")
            with source.extractfile(member) as stream: cls.profile = stream.read(16*1024*1024+1)
        if len(cls.profile) != member.size or cls.profile[12:16] != b"prtr" or cls.profile[16:20] != b"CMYK" or cls.profile[36:40] != b"acsp":
            raise AssertionError("The upstream test fixture is not a CMYK printer profile")

    def inputs(self, name, target="pdfx4", profile=None):
        folder = self.directory / name; folder.mkdir(mode=0o700)
        content = pdf_fixture(); profile = self.profile if profile is None else profile
        files = {"draft.pdf": content, "printer.icc": profile, "job.json": json.dumps(job_fixture(profile, target)).encode()}
        for name, data in files.items(): (folder/name).write_bytes(data)
        output = folder / "Output"; output.mkdir(mode=0o700)
        return folder, files, output

    def finalize(self, folder, output):
        return subprocess.run([str(self.worker), "finalize-pdf", "--input", str(folder/"draft.pdf"), "--icc", str(folder/"printer.icc"),
                               "--job", str(folder/"job.json"), "--output", str(output)], cwd=self.working, env=self.env,
                              capture_output=True, text=True, timeout=180)

    def unchanged(self, folder, files):
        for name, content in files.items(): self.assertEqual((folder/name).read_bytes(), content, name)
        self.assertFalse(self.trap.exists(), "The frozen finalizer searched PATH for an external runtime/tool")
        self.assertFalse((self.home/"Library/Application Support/Magdobe Illustrator/Runtime").exists())

    def assert_actual_pdf(self, path, target):
        pikepdf = self.pikepdf
        with pikepdf.open(path) as pdf:
            self.assertEqual(len(pdf.pages), 1)
            intent = pdf.Root.OutputIntents[0]
            self.assertEqual(str(intent.S), "/GTS_PDFX")
            self.assertEqual(sha(intent.DestOutputProfile.read_bytes()), sha(self.profile))
            self.assertEqual(int(intent.DestOutputProfile.N), 4)
            page = pdf.pages[0]
            for key, expected in (("/MediaBox", [0,0,198,270]), ("/TrimBox", [9,9,189,261]), ("/BleedBox", [0,0,198,270])):
                for measured, wanted in zip(page.obj[key], expected): self.assertAlmostEqual(float(measured), wanted, places=3)
            paints, alphas = 0, []
            visited = set()
            def inspect(container):
                nonlocal paints
                ident = tuple(container.objgen)
                if ident != (0,0):
                    if ident in visited: return
                    visited.add(ident)
                group = container.get("/Group", {})
                if "/CS" in group: self.assertIn(str(group["/CS"]), ("/DeviceCMYK", "/DeviceGray"))
                resources = container.get("/Resources", {})
                self.assertFalse(resources.get("/Font", {}), "Generated draft text should already be outlined")
                for state in resources.get("/ExtGState", {}).values():
                    if "/ca" in state: alphas.append(float(state["/ca"]))
                for instruction in pikepdf.parse_content_stream(container):
                    operator = str(instruction.operator)
                    self.assertNotIn(operator, ("rg", "RG", "BI"), "RGB painting or inline raster survived CMYK finalization")
                    if operator in ("f", "F", "f*", "S", "s", "B", "B*", "b", "b*"): paints += 1
                for xobject in resources.get("/XObject", {}).values():
                    self.assertNotEqual(str(xobject.get("/Subtype", "")), "/Image", "Vector artwork was rasterized")
                    if str(xobject.get("/Subtype", "")) == "/Form": inspect(xobject)
            inspect(page.obj)
            self.assertGreaterEqual(paints, 2199)
            self.assertTrue(any(abs(value-.5) < .001 for value in alphas), "Live transparency was lost")
            if target == "pdfx4":
                self.assertEqual(str(pdf.pdf_version), "1.6")
                self.assertEqual(str(pdf.docinfo["/GTS_PDFXVersion"]), "PDF/X-4")
                self.assertIn(b"PDF/X-4", pdf.Root.Metadata.read_bytes())
                self.assertIn("/Trapped", pdf.docinfo)
                self.assertIn("/ID", pdf.trailer)

    def success(self, target):
        folder, files, output = self.inputs("Success " + target, target)
        result = self.finalize(folder, output)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        receipt = json.loads(result.stdout)
        report_path = Path(receipt["report_path"]).resolve()
        pdf_path = Path(receipt["pdf_path"]).resolve()
        self.assertTrue(report_path.is_relative_to(output.resolve()))
        self.assertTrue(pdf_path.is_relative_to(output.resolve()))
        report = json.loads(report_path.read_text())
        self.assertEqual(report["id"], receipt["id"])
        self.assertEqual(report["status"], "pass_supported_checks")
        self.assertEqual(report["source"]["sha256"], sha(files["draft.pdf"]))
        self.assertEqual(report["output"]["sha256"], sha(pdf_path.read_bytes()))
        self.assertEqual(report["output"]["icc_sha256"], sha(self.profile))
        self.assertGreaterEqual(report["output"]["vector_paths"], 2199)
        self.assertEqual(report["output"]["raster_objects"], 0)
        self.assertEqual(report["output"]["text_objects"], 0)
        self.assertTrue(report["limitations"])
        self.assert_actual_pdf(pdf_path, target)
        self.unchanged(folder, files)

    def test_relocated_frozen_cmyk_pdf_preserves_2199_vectors(self): self.success("cmyk_pdf")
    def test_relocated_frozen_pdfx4_preserves_icc_boxes_and_transparency(self): self.success("pdfx4")

    def test_rejected_profile_and_existing_output_preserve_all_inputs(self):
        folder, files, output = self.inputs("Invalid profile", profile=b"not an ICC profile")
        result = self.finalize(folder, output)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        receipt = json.loads(result.stdout)
        self.assertIsNone(receipt.get("pdf_path"))
        report_path = Path(receipt["report_path"]).resolve()
        self.assertTrue(report_path.is_relative_to(output.resolve()))
        report = json.loads(report_path.read_text())
        self.assertEqual(report["id"], receipt["id"])
        self.assertEqual(report["status"], "fail")
        self.assertTrue(any(finding["status"] == "fail" for finding in report["findings"]))
        self.assertEqual(report["source"]["sha256"], sha(files["draft.pdf"]))
        self.assertNotIn("output", report)
        self.assertTrue((output/"report.html").is_file())
        self.assertFalse((output/"production.pdf").exists())
        self.unchanged(folder, files)
        folder, files, output = self.inputs("Existing destination")
        previous = output / "production.pdf"; previous.write_bytes(b"existing user document")
        result = self.finalize(folder, output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(previous.read_bytes(), b"existing user document")
        self.unchanged(folder, files)


if __name__ == "__main__": unittest.main()
