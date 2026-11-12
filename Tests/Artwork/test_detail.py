"""Real VTracer regression tests; only the application's pinned Python dependencies."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('artwork_worker', ROOT / 'Resources/Artwork/artwork_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def write_test_png(path):
    width = height = 192
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            color = (30, 35, 45)
            # Tiny highlights on a subtly shaded colored field.
            if 15 < x < 175 and 80 < y < 175:
                color = (80 + x // 3, 90 + y // 3, 160)
            if 8 <= x % 18 <= 10 and 8 <= y % 18 <= 10:
                color = (240, 150 + (x // 18) * 8, 40)
            row.extend(color)
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


class DetailTests(unittest.TestCase):
    def trace(self, source, job, detail):
        job.mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            worker.trace(source, job, detail)
        return json.loads((job / 'artwork.mvector').read_text())

    def test_ultra_keeps_small_highlights_and_color_variation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source.png'; write_test_png(source)
            before = source.read_bytes()
            balanced = self.trace(source, root / 'balanced', 'Balanced')
            ultra = self.trace(source, root / 'ultra', 'Ultra')
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual((ultra['width'], ultra['height']), (192, 192))
            self.assertGreater(len(ultra['shapes']), len(balanced['shapes']) * 2)
            colors = lambda project: {tuple(shape['fill'].values()) for shape in project['shapes']}
            self.assertGreater(len(colors(ultra)), len(colors(balanced)))
            svg = ET.parse(root / 'ultra/artwork.svg').getroot()
            self.assertEqual(len(svg.findall('{http://www.w3.org/2000/svg}path')), len(ultra['shapes']))
            self.assertEqual(svg.findall('.//{http://www.w3.org/2000/svg}image'), [])
            info = json.loads((root / 'ultra/trace-info.json').read_text())
            self.assertEqual(info['objects'], len(ultra['shapes']))
            self.assertEqual(info['detail'], 'Ultra')
            self.assertTrue(all(s['kind'] == 'path' and s['closed'] for s in ultra['shapes']))

    def test_four_decimal_curve_coordinates_survive_import(self):
        # Isolate conversion to ensure the native model cannot round away SVG detail.
        svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><path fill="#123456" transform="translate(1.2345,2.3456)" d="M0.1111,0.2222 C1.3333,0.4444 2.5555,1.6666 3.7777,2.8888 L0.1111,0.2222 Z"/></svg>'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def fake(_source, target, **_kwargs): Path(target).write_text(svg)
            with patch('vtracer.convert_image_to_svg_py', side_effect=fake):
                p = self.trace(root / 'unused.png', root / 'trace', 'Ultra')
            anchor = p['shapes'][0]['anchors'][0]
            self.assertAlmostEqual(anchor['point']['x'], 1.3456, places=12)
            self.assertAlmostEqual(anchor['point']['y'], 2.5678, places=12)
            self.assertAlmostEqual(anchor['outgoing']['x'], 2.5678, places=12)
            self.assertEqual(len(p['shapes'][0]['anchors']), 2)

    def test_complexity_error_leaves_existing_native_result_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source.png'; write_test_png(source)
            job = root / 'trace'; job.mkdir(); previous = job / 'artwork.mvector'; previous.write_text('previous-result')
            with patch.object(worker, 'MAX_TRACE_OBJECTS', 1), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, 'previous result is unchanged'):
                    worker.trace(source, job, 'Ultra')
            self.assertEqual(previous.read_text(), 'previous-result')

    def test_invalid_preset_is_explicit_and_presets_are_not_mutated(self):
        with self.assertRaises(ValueError): worker.trace_options('Unknown')
        first = worker.trace_options('Ultra'); first['path_precision'] = 0
        self.assertEqual(worker.trace_options('Ultra')['path_precision'], 4)


if __name__ == '__main__': unittest.main()
