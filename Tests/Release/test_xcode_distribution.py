"""Offline application-target generation; no signing keys or uploads are used."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('magdobe_xcode_distribution', ROOT / 'script/create_xcode_distribution.py')
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
release = distribution.release
PUBLIC_CERTIFICATE_FINGERPRINT = distribution.certificate_fingerprint


class XcodeDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='magdobe-xcode-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source checkout'
        self.sources = self.root / 'Sources/MagnusVector'
        self.sources.mkdir(parents=True)
        (self.sources / 'App.swift').write_text('import SwiftUI\n@main struct Example: App { var body: some Scene { WindowGroup { Text("Fixture") } } }\n')
        (self.sources / 'Model.swift').write_text('struct Model {}\n')
        self.app = Path(self.temp.name) / 'Magdobe & Fixture.app'
        self.info = {'CFBundleExecutable': 'MagnusVector', 'CFBundlePackageType': 'APPL',
                     'CFBundleIdentifier': 'com.example.magdobe', 'CFBundleVersion': '37',
                     'CFBundleShortVersionString': '1.2.3', 'LSMinimumSystemVersion': '14.2'}
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/_CodeSignature').mkdir()
        (self.app / 'Contents/Helpers').mkdir()
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.app / 'Contents/MacOS/MagnusVector').write_bytes(b'fixture main')
        (self.app / 'Contents/_CodeSignature/CodeResources').write_bytes(b'fixture signed seal')
        self.output = Path(self.temp.name) / 'new local distribution'
        self.fingerprint = 'A' * 40
        self.validation = {'architectures': ['x86_64']}
        self.patches = [
            patch.object(release, 'verify', return_value=self.validation),
            patch.object(release, 'developer_identity', return_value=self.fingerprint),
            patch.object(distribution, 'certificate_fingerprint', return_value=self.fingerprint),
            patch.object(release, 'signature_details', return_value='Authority=Developer ID Application: Fixture\nTeamIdentifier=ABC123DE45\n'),
        ]
        self.mocks = [item.start() for item in self.patches]
        for item in self.patches:
            self.addCleanup(item.stop)

    def generate(self):
        return distribution.generate(self.app, self.fingerprint, self.output, root=self.root)

    def test_application_target_uses_actual_metadata_and_explicit_identity_without_signing(self):
        with patch.object(release, 'run') as command:
            result = self.generate()
        command.assert_not_called()
        self.mocks[0].assert_called_once_with(self.app.resolve(), mode='signed')
        self.mocks[1].assert_called_once_with(self.fingerprint)
        self.assertEqual(result['architectures'], ['x86_64'])
        self.assertEqual((result['version'], result['build'], result['minimum_macos']), ('1.2.3', '37', '14.2'))
        self.assertEqual(result['swift_source_files'], 2)
        self.assertFalse(result['built'] or result['notarized'])
        text = (Path(result['project']) / 'project.pbxproj').read_text()
        for expected in ['isa = PBXNativeTarget', 'com.apple.product-type.application',
                         'PRODUCT_MODULE_NAME = "MagnusVector"', 'EXECUTABLE_NAME = "MagnusVector"',
                         'ARCHS = "x86_64"', 'SKIP_INSTALL = "NO"', 'INSTALL_PATH = "/Applications"',
                         'ENABLE_HARDENED_RUNTIME = "YES"', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = "NO"',
                         f'CODE_SIGN_IDENTITY = "{self.fingerprint}"', 'DEVELOPMENT_TEAM = "ABC123DE45"',
                         '-debug-prefix-map', '-file-prefix-map', 'STRIP_INSTALLED_PRODUCT = "YES"']:
            self.assertIn(expected, text)
        self.assertNotIn('PBXAggregateTarget', text)
        self.assertNotIn('PBXLegacyTarget', text)
        self.assertNotIn('notarytool', text)
        scheme = ET.parse(Path(result['project']) / 'xcshareddata/xcschemes/MagdobeDistribution.xcscheme')
        self.assertEqual(scheme.find('.//BuildableReference').attrib['BuildableName'], self.app.name)
        self.assertEqual(plistlib.loads((self.output / 'Distribution-Info.plist').read_bytes()), self.info)
        self.assertFalse(Path(result['archive']).exists())

    def test_recorded_hashes_guard_sources_and_original_sealed_payload(self):
        self.generate()
        manifest = self.output / 'InputHashes.sha256'
        lines = manifest.read_text().splitlines()
        self.assertEqual(len(lines), 5)
        for line in lines:
            digest, filename = line.split('  ', 1)
            self.assertEqual(digest, hashlib.sha256(Path(filename).read_bytes()).hexdigest())
        subprocess.run(['/usr/bin/shasum', '-a', '256', '-c', str(manifest)], check=True, capture_output=True)
        (self.sources / 'Model.swift').write_text('struct Changed {}\n')
        changed = subprocess.run(['/usr/bin/shasum', '-a', '256', '-c', str(manifest)], capture_output=True)
        self.assertNotEqual(changed.returncode, 0)
        text = (self.output / 'MagdobeDistribution.xcodeproj/project.pbxproj').read_text()
        self.assertIn('/usr/bin/codesign --verify --deep --strict', text)
        self.assertIn('Contents/Helpers', text)
        self.assertIn('Contents/Resources', text)
        self.assertNotIn('ditto \\\"$SOURCE_APP\\\"', text)

    def test_existing_output_and_escaping_locations_are_rejected_before_validation(self):
        self.output.mkdir()
        sentinel = self.output / 'keep.txt'
        sentinel.write_text('keep')
        with self.assertRaisesRegex(release.ReleaseError, 'never replaced'):
            self.generate()
        self.assertEqual(sentinel.read_text(), 'keep')
        self.mocks[0].assert_not_called()
        for output in [self.app / 'new', self.sources / 'new']:
            with self.subTest(output=output), self.assertRaisesRegex(release.ReleaseError, 'outside'):
                distribution.generate(self.app, self.fingerprint, output, root=self.root)
            self.assertFalse(output.exists())

    def test_rejects_wrong_identity_unsigned_input_and_missing_sources_without_output(self):
        self.mocks[2].return_value = 'B' * 40
        with self.assertRaisesRegex(release.ReleaseError, 'certificate exactly'):
            self.generate()
        self.assertFalse(self.output.exists())
        self.mocks[2].return_value = self.fingerprint
        self.mocks[0].side_effect = release.ReleaseError('Unsigned fixture')
        with self.assertRaisesRegex(release.ReleaseError, 'Unsigned'):
            self.generate()
        self.assertFalse(self.output.exists())
        self.mocks[0].side_effect = None
        for path in self.sources.glob('*.swift'):
            path.unlink()
        with self.assertRaisesRegex(release.ReleaseError, 'Swift sources'):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_public_certificate_extraction_never_requests_a_private_key(self):
        certificate_bytes = b'public certificate fixture'
        def public_extract(args, **kwargs):
            self.assertEqual(args[:2], ['/usr/bin/codesign', '--display'])
            self.assertTrue(args[2].startswith('--extract-certificates='))
            Path(args[2].split('=', 1)[1] + '0').write_bytes(certificate_bytes)
            return subprocess.CompletedProcess(args, 0, '', '')
        with patch.object(release, 'run', side_effect=public_extract) as command:
            self.assertEqual(PUBLIC_CERTIFICATE_FINGERPRINT(self.app), hashlib.sha1(certificate_bytes).hexdigest().upper())
        self.assertEqual(command.call_count, 1)

    def test_invalid_metadata_is_rejected_before_any_output_is_created(self):
        for key, value in [('CFBundleIdentifier', 123), ('CFBundleVersion', 37),
                           ('LSMinimumSystemVersion', '14.0; OTHER_FLAG=YES')]:
            with self.subTest(key=key):
                invalid = dict(self.info, **{key: value})
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(invalid))
                with self.assertRaises(release.ReleaseError):
                    self.generate()
                self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
