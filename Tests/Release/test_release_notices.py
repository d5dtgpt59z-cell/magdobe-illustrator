"""Release notices must retain the actual license, not just a vendor label."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("magdobe_release_notices", ROOT / "script/release_notices.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class ReleaseNoticeTests(unittest.TestCase):
    def test_renderer_rejects_missing_short_or_modified_license(self):
        with tempfile.TemporaryDirectory() as directory:
            checker = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "complete GNU AGPL"):
                notices.renderer_agpl_license(checker)
            license_path = checker / "PressCheck-LICENSE.txt"
            license_path.write_text("Dual Licensed - GNU AFFERO GPL 3.0 or Artifex Commercial License\n")
            with self.assertRaisesRegex(RuntimeError, "complete GNU AGPL"):
                notices.renderer_agpl_license(checker)
            license_path.write_bytes((ROOT / "script/licenses/AGPL-3.0.txt").read_bytes() + b"modified")
            with self.assertRaisesRegex(RuntimeError, "complete GNU AGPL"):
                notices.renderer_agpl_license(checker)

    def test_collector_keeps_vendor_notice_and_full_license_in_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            output = base / "Contents/Resources/ThirdPartyNotices"
            checker = base / "Contents/Helpers/PressCheckWorker.app/Contents/Resources"
            checker.mkdir(parents=True)
            canonical = (ROOT / "script/licenses/AGPL-3.0.txt").read_bytes()
            (checker / "PressCheck-LICENSE.txt").write_bytes(canonical)
            (checker / "source-revision.json").write_text(json.dumps({"revision": "a"*40}))
            vendor = base / "wheel/pymupdf-2.1.dist-info/COPYING"
            vendor.parent.mkdir(parents=True)
            vendor.write_text("Dual Licensed - GNU AFFERO GPL 3.0 or Artifex Commercial License\n")
            python = base / "python/install"
            (python / "lib").mkdir(parents=True)
            (python / "lib/LICENSE.txt").write_text("Python license fixture")
            upstream = python.parent / "redistribution-notices"
            upstream.mkdir()
            (upstream / "LICENSE-fixture.txt").write_text("Portable interpreter notice fixture")
            binaries = base / "binaries.json"
            binaries.write_text("[]")
            class Distribution:
                version = "2.1"
                files = [Path("pymupdf-2.1.dist-info/COPYING")]
                def locate_file(self, entry):
                    return base / "wheel" / entry
            with patch.object(notices, "PACKAGES", ("PyMuPDF",)), \
                 patch.object(notices.importlib.metadata, "distribution", return_value=Distribution()), \
                 patch.object(notices.sysconfig, "get_path", return_value=str(python / "lib")), \
                 patch.object(notices.sys, "base_prefix", str(python)):
                notices.collect(output, binaries)
            self.assertEqual((output / "PyMuPDF/AGPL-3.0.txt").read_bytes(), canonical)
            self.assertEqual((output / "PyMuPDF/pymupdf-2.1.dist-info/COPYING").read_bytes(), vendor.read_bytes())
            manifest = json.loads((output / "manifest.json").read_text())
            renderer = next(c for c in manifest["components"] if c["name"] == "PyMuPDF")
            self.assertEqual(renderer["version"], "2.1")
            recorded = next(n for n in renderer["notices"] if n["path"] == "PyMuPDF/AGPL-3.0.txt")
            self.assertEqual(recorded["sha256"], hashlib.sha256(canonical).hexdigest())
            self.assertEqual(recorded["sha256"], notices.AGPL_SHA256)


if __name__ == "__main__":
    unittest.main()
