"""Offline release gates: no signing identities, Keychain profiles, or network calls."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('magdobe_release', ROOT / 'script/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='magdobe-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Magdobe Illustrator.app'
        self.main = self.app / 'Contents/MacOS/MagnusVector'
        self.helper = self.app / release.HELPER
        for path in [self.main, self.helper]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
            path.chmod(0o755)
        self.info = {'CFBundleExecutable': 'MagnusVector', 'CFBundleIdentifier': 'com.example.magdobe',
                     'CFBundleVersion': '8', 'CFBundleShortVersionString': '0.8.0', 'LSMinimumSystemVersion': '14.0'}
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        notices = self.app / 'Contents/Resources/ThirdPartyNotices'; notices.mkdir(parents=True)
        for name, value in [('manifest.json', '{"dependencies":["python"]}'), ('Magdobe-LICENSE.txt', 'MIT fixture'), ('Python-LICENSE.txt', 'PSF fixture')]:
            (notices / name).write_text(value)

    def fake_tools(self, args, check=True):
        command = [str(a) for a in args]
        output = ''
        if command[0].endswith('lipo'):
            output = 'arm64\n'
        elif command[1] == '-l':
            output = 'Load command 1\n cmd LC_BUILD_VERSION\n cmdsize 32\n platform MACOS\n minos 14.0\n sdk 26.5\n'
        elif command[1] == '-L':
            output = command[-1] + ':\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
        return subprocess.CompletedProcess(command, 0, output, '')

    def test_preview_layout_is_portable_but_not_reported_distribution_ready(self):
        with patch.object(release, 'run', side_effect=self.fake_tools) as commands:
            report = release.verify(self.app, arch='arm64')
        self.assertFalse(report['distributionReady'])
        self.assertEqual(report['nativeCodeFiles'], 2)
        self.assertEqual(report['architectures'], ['arm64'])
        self.assertFalse(any('codesign' in str(call) or 'notarytool' in str(call) for call in commands.call_args_list))

    def test_flat_developer_app_is_rejected_without_embedded_worker(self):
        self.helper.unlink()
        with self.assertRaisesRegex(release.ReleaseError, 'bundled artwork worker'):
            release.inspect_layout(self.app)

    def test_private_paths_secrets_and_user_artwork_cannot_be_packaged(self):
        resources = self.app / 'Contents/Resources'
        for filename, data in [('runtime.json', b'{"python":"/Users/developer/Runtime/bin/python"}'),
                               ('credentials.txt', b'-----BEGIN PRIVATE KEY-----'),
                               ('drawing.mvector', b'{}'), ('request.json', b'{}')]:
            path = resources / filename; path.write_bytes(data)
            with self.subTest(filename=filename), self.assertRaises(release.ReleaseError):
                release.inspect_layout(self.app)
            path.unlink()

    def test_main_executable_private_source_paths_are_rejected_beyond_metadata_size_limit(self):
        with self.main.open('ab') as stream:
            stream.write(b'\0' * 2_000_001 + b'/Users/developer/private/source/Canvas.swift')
        with self.assertRaisesRegex(release.ReleaseError, 'main app executable'):
            release.inspect_layout(self.app)

    def test_current_build_home_is_rejected_from_other_native_libraries(self):
        with self.helper.open('ab') as stream:
            stream.write(str(Path.home()).encode() + b'/private/build/source.c')
        with self.assertRaisesRegex(release.ReleaseError, 'build-user home'):
            release.inspect_layout(self.app)

    def test_absolute_and_escaping_symlinks_are_rejected(self):
        path = self.app / 'Contents/Resources/linked'
        for destination in ['/usr/bin/python3', '../../../../outside']:
            path.symlink_to(destination)
            with self.subTest(destination=destination), self.assertRaisesRegex(release.ReleaseError, 'symlink'):
                release.inspect_layout(self.app)
            path.unlink()

    def test_missing_license_notice_is_a_release_failure(self):
        (self.app / 'Contents/Resources/ThirdPartyNotices/Python-LICENSE.txt').unlink()
        with self.assertRaisesRegex(release.ReleaseError, 'license'):
            release.inspect_layout(self.app)

    def test_architecture_mismatch_in_nested_code_is_rejected(self):
        def tools(args, check=True):
            if str(args[0]).endswith('lipo') and Path(args[-1]).resolve() == self.helper.resolve():
                return subprocess.CompletedProcess(args, 0, 'x86_64\n', '')
            return self.fake_tools(args, check)
        with patch.object(release, 'run', side_effect=tools), self.assertRaisesRegex(release.ReleaseError, 'Architecture mismatch'):
            release.verify(self.app, arch='arm64')

    def test_dependency_cannot_require_newer_macos_than_the_app_declares(self):
        def tools(args, check=True):
            result = self.fake_tools(args, check)
            if str(args[0]).endswith('otool') and args[1] == '-l' and Path(args[-1]).resolve() == self.helper.resolve():
                result.stdout = result.stdout.replace('minos 14.0', 'minos 26.0')
            return result
        with patch.object(release, 'run', side_effect=tools), self.assertRaisesRegex(release.ReleaseError, 'newer macOS'):
            release.verify(self.app)

    def test_external_or_unresolved_native_dependencies_are_rejected(self):
        for dependency in ['/opt/homebrew/lib/libpython3.dylib', '@rpath/missing.dylib']:
            def tools(args, check=True):
                if str(args[0]).endswith('otool') and args[1] == '-L':
                    return subprocess.CompletedProcess(args, 0, str(args[-1]) + ':\n\t' + dependency + ' (compatibility version 1.0.0)\n', '')
                return self.fake_tools(args, check)
            with self.subTest(dependency=dependency), patch.object(release, 'run', side_effect=tools), self.assertRaisesRegex(release.ReleaseError, 'dependency'):
                release.verify(self.app)

    def test_signing_order_places_nested_code_before_outer_app(self):
        framework = self.app / 'Contents/Helpers/MagdobeArtworkWorker.app/Contents/Frameworks/Example.framework'
        binary = framework / 'Versions/A/Example'; binary.parent.mkdir(parents=True); binary.write_bytes(b'\xcf\xfa\xed\xfefixture')
        resource_bundle = self.app / 'Contents/Resources/OnlyData.bundle'; resource_bundle.mkdir()
        targets = release.signing_targets(self.app, [self.main, self.helper, binary])
        self.assertEqual(targets[-1], self.app)
        self.assertLess(targets.index(binary), targets.index(framework))
        helper_bundle = self.app / 'Contents/Helpers/MagdobeArtworkWorker.app'
        self.assertLess(targets.index(framework), targets.index(helper_bundle))
        self.assertNotIn(resource_bundle, targets)

    def test_distribution_signature_gate_rejects_ad_hoc_without_stapling(self):
        with patch.object(release, 'run', side_effect=self.fake_tools) as commands, patch.object(release, 'signature_details', return_value='Signature=adhoc\nTeamIdentifier=not set\n'):
            with self.assertRaisesRegex(release.ReleaseError, 'Developer ID'):
                release.verify(self.app, 'ready')
        self.assertFalse(any('stapler' in str(call) for call in commands.call_args_list))

    def test_identity_preflight_rejects_wrong_or_ambiguous_certificates_before_signing(self):
        developer = 'A' * 40
        other = 'B' * 40
        name = 'Developer ID Application: Test Release (TESTTEAMID)'
        listing = '  1) ' + developer + ' "' + name + '"\n  2) ' + other + ' "Apple Development: Test Developer"\n'
        with patch.object(release, 'run', return_value=subprocess.CompletedProcess([], 0, listing, '')) as commands:
            self.assertEqual(release.developer_identity(name), developer)
            self.assertEqual(release.developer_identity(developer.lower()), developer)
            for identity in ['Apple Development: Test Developer', other, 'Developer ID Application: Not Installed (OTHERTEAM)']:
                with self.subTest(identity=identity), self.assertRaisesRegex(release.ReleaseError, 'no files were signed'):
                    release.sign(self.app, identity)
            self.assertTrue(all(call.args[0][0] == '/usr/bin/security' for call in commands.call_args_list))
        ambiguous = listing + '  3) ' + 'C' * 40 + ' "' + name + '"\n'
        with patch.object(release, 'run', return_value=subprocess.CompletedProcess([], 0, ambiguous, '')):
            with self.assertRaisesRegex(release.ReleaseError, 'uniquely'):
                release.developer_identity(name)

    def test_release_commands_require_explicit_credentials_and_preview_label(self):
        with patch.object(release, 'run') as commands:
            with self.assertRaises(release.ReleaseError): release.sign(self.app, '-')
            with self.assertRaises(release.ReleaseError): release.notarize(self.app, '')
            with self.assertRaises(release.ReleaseError): release.package(self.app, Path(self.temp.name) / 'Release.dmg')
        commands.assert_not_called()
        with patch.object(release, 'verify', return_value={}), self.assertRaisesRegex(release.ReleaseError, 'PREVIEW'):
            release.package(self.app, Path(self.temp.name) / 'Release.dmg', preview=True)


if __name__ == '__main__':
    unittest.main()
