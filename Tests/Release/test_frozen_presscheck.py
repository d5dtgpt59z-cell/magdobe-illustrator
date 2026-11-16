"""Exercise the actual relocated checker with no developer runtime or credentials.

Set MAGDOBE_TEST_APP to a built 0.9+ app. No UI, external service or real artwork
is used; the default fixture contains 2,199 independently editable vector paths.
"""
import base64
from contextlib import contextmanager
import hashlib
import http.client
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP = ROOT / "dist/release-0.9.0/Magdobe Illustrator.app"
if not DEFAULT_APP.is_dir():
    DEFAULT_APP = ROOT / "dist/release/Magdobe Illustrator.app"
APP = Path(os.environ.get("MAGDOBE_TEST_APP", DEFAULT_APP))
CHECKER_APP = APP / "Contents/Helpers/PressCheckWorker.app"
CHECKER = CHECKER_APP / "Contents/MacOS/PressCheckWorker"


def svg_fixture():
    paths = []
    for index in range(2199):
        x, y = index % 47 * 12, index // 47 * 14
        paths.append(
            f'<path id="object-{index:04}" transform="translate({x} {y})" '
            'd="M0 0 C2 -2 8 -2 10 0 L10 10 L0 10 Z" '
            f'fill="#{index*7919 % 0xffffff:06x}" stroke="#182231" stroke-width="2"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" version="1.1" overflow="hidden" '
            'width="69.85mm" height="95.25mm" viewBox="0 0 698.5 952.5">'
            '<g data-production-role="artwork" transform="translate(30 40)">'
            + ''.join(paths) + '</g></svg>').encode()


def job_fixture():
    return {"schema_version": 1, "workflow": "trading_card", "name": 'Synthetic & <printer> "proof"',
            "trim_width_mm": 63.5, "trim_height_mm": 88.9, "bleed_mm": 3.175,
            "safe_mm": 3.175, "min_stroke_mm": .15, "bleed_intent": "full_bleed",
            "color_policy": "review_rgb", "supplier_confirmed": False, "placement": "fill_bleed"}


def multipart(svg, job):
    boundary = "MagdobeFrozenWorkerFixtureBoundary"
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="Synthetic-2199.svg"\r\n'
            'Content-Type: image/svg+xml\r\n\r\n').encode() + svg
    body += (f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="job"\r\n'
             'Content-Type: application/json\r\n\r\n').encode() + json.dumps(job).encode()
    return body + f'\r\n--{boundary}--\r\n'.encode(), f'multipart/form-data; boundary={boundary}'


class AssetLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        value = attributes.get("src") if tag == "script" else attributes.get("href") if tag == "link" else None
        if value and urlsplit(value).path.endswith((".js", ".css")):
            self.assets.append(value)


@unittest.skipUnless(CHECKER.is_file(), "Build the 0.9+ checker app or set MAGDOBE_TEST_APP")
class FrozenPressCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="Magdobe Frozen Checker ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.relocated = cls.directory / "Relocated Only Checker/PressCheckWorker.app"
        cls.relocated.parent.mkdir()
        shutil.copytree(CHECKER_APP, cls.relocated, symlinks=True)
        cls.worker = cls.relocated / "Contents/MacOS/PressCheckWorker"
        if not (cls.relocated / "Contents/Resources/web/production/index.html").is_file():
            raise AssertionError("The relocated checker app is missing its static workspace")
        cls.home = cls.directory / "Fresh Home"
        cls.home.mkdir(mode=0o700)
        cls.working = cls.directory / "Empty Working Directory"
        cls.working.mkdir()
        traps = cls.directory / "Unavailable Developer Tools"
        traps.mkdir()
        cls.runtime_trap = cls.directory / "unexpected-runtime-execution.txt"
        for executable in ("python", "python3", "node", "npm", "uv", "codex"):
            path = traps / executable
            path.write_text('#!/bin/sh\necho unexpected-external-runtime >> "$MAGDOBE_TEST_RUNTIME_TRAP"\nexit 77\n')
            path.chmod(0o755)
        cls.env = {"HOME": str(cls.home), "PATH": str(traps) + ":/usr/bin:/bin",
                   "TMPDIR": str(cls.directory), "LANG": "en_US.UTF-8",
                   "PYTHONNOUSERSITE": "1", "MAGDOBE_TEST_RUNTIME_TRAP": str(cls.runtime_trap)}

    def assert_no_external_runtime(self):
        self.assertFalse(self.runtime_trap.exists(), "The frozen checker invoked an external developer runtime")
        self.assertFalse((self.relocated / "node_modules").exists())
        self.assertFalse((self.home / "Library/Application Support/Magdobe Illustrator/Runtime").exists())

    def assert_png(self, content):
        self.assertTrue(content.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height = struct.unpack(">II", content[16:24])
        self.assertGreater(min(width, height), 0)
        self.assertLessEqual(max(width, height), 1600)

    @contextmanager
    def server(self, data):
        process = subprocess.Popen([str(self.worker), "serve", "--port", "0", "--data", str(data)],
                                   cwd=self.working, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            readable, _, _ = select.select([process.stdout], [], [], 20)
            self.assertTrue(readable, "The relocated checker did not announce its local workspace")
            line = process.stdout.readline()
            self.assertTrue(line, "The relocated checker exited before startup")
            startup = json.loads(line)
            address = urlsplit(startup["url"])
            self.assertEqual(address.scheme, "http")
            self.assertEqual(address.hostname, "127.0.0.1")
            self.assertEqual(address.path, "/production/")
            token = parse_qs(address.query)["token"][0]

            def request(method, path, body=None, content_type=None, authorized=True, host=None):
                headers = {}
                if authorized:
                    headers["Authorization"] = "Bearer " + token
                if host:
                    headers["Host"] = host
                if isinstance(body, dict):
                    body = json.dumps(body).encode()
                    content_type = "application/json"
                if content_type:
                    headers["Content-Type"] = content_type
                connection = http.client.HTTPConnection("127.0.0.1", address.port, timeout=30)
                try:
                    connection.request(method, path, body=body, headers=headers)
                    response = connection.getresponse()
                    return response.status, dict(response.getheaders()), response.read()
                finally:
                    connection.close()
            yield request
        finally:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)

    def test_relocated_cli_preserves_2199_vectors_and_physical_size(self):
        source = svg_fixture()
        input_path = self.directory / "Synthetic-2199.svg"
        input_path.write_bytes(source)
        job = self.directory / "synthetic-job.json"
        job_bytes = json.dumps(job_fixture()).encode()
        job.write_bytes(job_bytes)
        output = self.directory / "CLI Report"
        result = subprocess.run([str(self.worker), "preflight", "--input", str(input_path),
                                 "--job", str(job), "--output", str(output)], cwd=self.working,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        receipt = json.loads(result.stdout)
        report_path = Path(receipt["report_path"])
        self.assertEqual(report_path, (output / "report.json").resolve())
        report = json.loads(report_path.read_text())
        self.assertEqual(report["id"], receipt["id"])
        self.assertEqual(report["source"]["sha256"], hashlib.sha256(source).hexdigest())
        self.assertEqual(report["source"]["vector_objects"], 2199)
        self.assertEqual(report["source"]["element_counts"]["path"], 2199)
        self.assertEqual(report["source"]["name"], input_path.name)
        self.assertFalse(report["source"]["has_raster"])
        self.assertAlmostEqual(report["source"]["width_mm"], 69.85)
        self.assertAlmostEqual(report["source"]["height_mm"], 95.25)
        self.assertEqual(report["source"]["object_bounds_mm"]["object-0000"], [3, 3.8, 4, 5])
        self.assertTrue(all(math.isfinite(v) for box in report["source"]["object_bounds_mm"].values() for v in box))
        self.assertEqual(report["status"], "incomplete")
        self.assertTrue(any(f["rule_id"] == "job.supplier" and f["status"] == "requires_spec" for f in report["findings"]))
        self.assertEqual(report["report_url"], "report.html")
        self.assertEqual((output / "original.svg").read_bytes(), source)
        self.assertEqual(input_path.read_bytes(), source)
        self.assertEqual(job.read_bytes(), job_bytes)
        self.assertLess(report_path.stat().st_size, 4*1024*1024)
        self.assert_png((output / "preview.png").read_bytes())
        self.assertNotIn("<printer>", (output / "report.html").read_text())
        self.assert_no_external_runtime()

    def test_bundled_static_workspace_authenticated_preflight_and_structure(self):
        with self.server(self.directory / "HTTP Workspace") as request:
            status, _, page = request("GET", "/production/", authorized=False)
            self.assertEqual(status, 200)
            parser = AssetLinks()
            parser.feed(page.decode())
            self.assertTrue(parser.assets, "The static workspace has no bundled client assets")
            for asset in dict.fromkeys(parser.assets):
                self.assertFalse(urlsplit(asset).netloc, "The workspace depends on an external client asset")
                status, _, content = request("GET", asset, authorized=False)
                self.assertEqual(status, 200)
                self.assertTrue(content)
            self.assertEqual(request("GET", "/api/health", authorized=False)[0], 401)
            self.assertEqual(request("GET", "/api/health", host="attacker.invalid")[0], 403)
            self.assertEqual(request("POST", "/api/structures", {}, authorized=False)[0], 401)
            status, _, body = request("POST", "/api/structures", {"name": "Frozen carton fixture"})
            self.assertEqual(status, 200, body[:500])
            structure = json.loads(body)
            self.assertEqual(structure["status"], "prototype_unverified")
            self.assertEqual(structure["project"]["version"], 2)
            self.assertIn("cut", {node["productionRole"] for node in structure["project"]["hierarchy"]})
            self.assertFalse(structure["job"]["supplier_confirmed"])
            self.assertEqual(ET.fromstring(structure["svg"]).tag, "{http://www.w3.org/2000/svg}svg")
            self.assert_png(base64.b64decode(structure["preview_png"].split(",", 1)[1]))
            source = svg_fixture()
            body, kind = multipart(source, job_fixture())
            status, _, response = request("POST", "/api/preflights", body, kind)
            self.assertEqual(status, 201, response[:500])
            report = json.loads(response)
            self.assertEqual(report["source"]["vector_objects"], 2199)
            self.assertEqual(report["source"]["sha256"], hashlib.sha256(source).hexdigest())
            status, headers, original = request("GET", report["original_url"])
            self.assertEqual(status, 200)
            self.assertEqual(original, source)
            self.assertIn("attachment", headers["Content-Disposition"])
            self.assertEqual(headers["Content-Type"], "application/octet-stream")
            status, _, downloaded = request("GET", report["report_url"])
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(downloaded), report)
            self.assertEqual(request("GET", report["original_url"], authorized=False)[0], 401)
            self.assert_png(request("GET", report["preview_url"])[2])
        self.assert_no_external_runtime()

    def test_supplier_profiles_persist_across_authenticated_workspace_restarts(self):
        data = self.directory / "Profile Workspace"
        profile_job = {**job_fixture(), "profile_name": "Fixture printer", "printer_notes": "Needs physical proof", "spec_source": "Manual fixture"}
        profiles = {"schema_version": 1, "profiles": [{"id": "fixture-printer", "name": "Fixture printer", "job": profile_job}]}
        with self.server(data) as request:
            self.assertEqual(request("GET", "/api/profiles", authorized=False)[0], 401)
            self.assertEqual(request("PUT", "/api/profiles", profiles, authorized=False)[0], 401)
            self.assertEqual(json.loads(request("GET", "/api/profiles")[2]), {"schema_version": 1, "profiles": []})
            status, _, body = request("PUT", "/api/profiles", profiles)
            self.assertEqual(status, 200, body[:500])
            saved = json.loads(body)
            self.assertEqual(saved["profiles"][0]["job"]["profile_name"], "Fixture printer")
            self.assertFalse(saved["profiles"][0]["job"]["supplier_confirmed"])
        persisted = (data / "printer-profiles.json").read_bytes()
        self.assertEqual((data / "printer-profiles.json").stat().st_mode & 0o077, 0)
        with self.server(data) as request:
            self.assertEqual(json.loads(request("GET", "/api/profiles")[2]), saved)
            invalid = json.loads(json.dumps(profiles))
            invalid["profiles"][0]["job"]["api_key"] = "fixture-not-a-real-secret"
            self.assertEqual(request("PUT", "/api/profiles", invalid)[0], 422)
            self.assertEqual((data / "printer-profiles.json").read_bytes(), persisted)
            self.assertEqual(json.loads(request("GET", "/api/profiles")[2]), saved)
        self.assert_no_external_runtime()


if __name__ == "__main__":
    unittest.main()
