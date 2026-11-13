"""Integration checks against an actual relocated distribution bundle.

Run after build_release.sh. Uses no real credentials or external HTTP services.
"""
import base64
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import ssl
import struct
import subprocess
import tempfile
import threading
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
APP = Path(os.environ.get("MAGDOBE_TEST_APP", ROOT / "dist/release/Magdobe Illustrator.app"))


def fixture_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = []
    for y in range(64):
        pixels = bytearray()
        for x in range(64):
            color = (245, 230, 200)
            if (x - 23) ** 2 + (y - 31) ** 2 < 18 ** 2:
                color = (190, 40, 65)
            if 37 <= x <= 55 and 10 <= y <= 54:
                color = (20, 95, 170)
            pixels.extend(color)
        rows.append(b"\0" + bytes(pixels))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


@contextmanager
def image_api(context=None):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            self.respond({"data": [{"id": "fixture-image"}]})

        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.path, data.get("model")))
            self.respond({"data": [{"b64_json": base64.b64encode(fixture_png()).decode()}]})

        def respond(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if context:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, requests
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


@unittest.skipUnless(APP.is_dir(), "Build the distribution app first, or set MAGDOBE_TEST_APP")
class FrozenBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="Magdobe Install Test ")
        cls.directory = Path(cls.temporary.name)
        cls.app = cls.directory / "Relocated Folder/Magdobe Illustrator.app"
        cls.app.parent.mkdir()
        subprocess.run(["/usr/bin/ditto", str(APP), str(cls.app)], check=True)
        cls.worker = cls.app / "Contents/Helpers/MagdobeArtworkWorker.app/Contents/MacOS/MagdobeArtworkWorker"
        cls.home = cls.directory / "Fresh User"
        cls.home.mkdir()
        cls.env = {"HOME": str(cls.home), "PATH": "/usr/bin:/bin", "TMPDIR": str(cls.directory)}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_worker(self, mode, name, request=None, provider=None, extra_env=None):
        job = self.directory / name
        job.mkdir()
        arguments = [str(self.worker), mode, "--job", str(job)]
        if request is not None:
            request_file = job / "request.json"
            request_file.write_text(json.dumps(request))
            arguments += ["--request", str(request_file)]
        env = dict(self.env)
        if provider:
            env["MAGDOBE_PROVIDER_CONFIG"] = json.dumps(provider)
            env["MAGDOBE_PROVIDER_API_KEY"] = "fixture-key-not-a-real-credential"
        env.update(extra_env or {})
        result = subprocess.run(arguments, cwd=self.directory, env=env, capture_output=True, text=True, timeout=90)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        return result, events, job

    def assert_editable(self, result, events, job):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[-1]["stage"], "done")
        project = json.loads((job / "artwork.mvector").read_text())
        self.assertEqual((project["width"], project["height"]), (64, 64))
        self.assertGreaterEqual(len(project["shapes"]), 3)
        self.assertEqual(len({shape["id"] for shape in project["shapes"]}), len(project["shapes"]))
        self.assertTrue(any("incoming" in anchor or "outgoing" in anchor for shape in project["shapes"] for anchor in shape["anchors"]))
        for shape in project["shapes"]:
            self.assertEqual(shape["kind"], "path")
            for anchor in shape["anchors"]:
                for coordinate in anchor["point"].values():
                    self.assertTrue(math.isfinite(coordinate))
        self.assertEqual((job / "source.png").read_bytes(), fixture_png())

    def test_relocated_offline_vectorization_without_python_or_cli(self):
        source = self.directory / "Original Source.png"
        source.write_bytes(fixture_png())
        result, events, job = self.run_worker("trace", "offline", {"image": str(source), "detail": "Detailed"})
        self.assert_editable(result, events, job)
        self.assertFalse((self.home / "Library/Application Support/Magdobe Illustrator/Runtime").exists())

    def test_relocated_api_generation_to_editable_vectors(self):
        with image_api() as (port, requests):
            result, events, job = self.run_worker("generate", "image-api", {"prompt": "Original geometric study", "detail": "Detailed"},
                {"provider": "compatible", "model": "fixture-image", "baseURL": f"http://127.0.0.1:{port}/v1"})
        self.assert_editable(result, events, job)
        self.assertIn(("/v1/images/generations", "fixture-image"), requests)
        self.assertNotIn("fixture-key-not-a-real-credential", result.stdout + result.stderr)

    def test_frozen_https_validates_certificates_and_respects_user_ca(self):
        certificate, key = self.directory / "fixture-ca.pem", self.directory / "fixture-key.pem"
        config = self.directory / "fixture-openssl.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-config", str(config), "-keyout", str(key), "-out", str(certificate)], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        with image_api(context) as (port, requests):
            provider = {"provider": "compatible", "model": "fixture-image", "baseURL": f"https://localhost:{port}/v1"}
            rejected, events, _ = self.run_worker("check", "untrusted-https", provider=provider)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("CERTIFICATE_VERIFY_FAILED", events[-1]["message"])
            accepted, events, _ = self.run_worker("check", "trusted-https", provider=provider, extra_env={"SSL_CERT_FILE": str(certificate)})
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            self.assertEqual(events[-1]["stage"], "connected")
            self.assertEqual(len(requests), 1)


if __name__ == "__main__":
    unittest.main()
