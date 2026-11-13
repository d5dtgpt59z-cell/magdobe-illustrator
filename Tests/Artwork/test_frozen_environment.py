"""External provider CLIs must not inherit the bundled Python loader environment."""
import importlib.util
import os
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('frozen_environment_worker', ROOT / 'Resources/Artwork/artwork_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class FrozenEnvironmentTests(unittest.TestCase):
    def test_source_worker_preserves_the_existing_cli_environment(self):
        environment = {'PATH': '/user/tools:/usr/bin', 'PYTHONPATH': '/user/python', 'SSL_CERT_FILE': '/user/ca.pem'}
        with patch.dict(os.environ, environment, clear=True), patch.object(worker.sys, 'frozen', False, create=True):
            self.assertEqual(worker.external_process_environment(), environment)

    def test_frozen_worker_restores_external_loader_paths_and_removes_its_private_state(self):
        environment = {'PATH': '/user/tools:/usr/bin', 'PYTHONHOME': '/bundle/python', 'PYTHONPATH': '/bundle/modules',
                       'PYTHONEXECUTABLE': '/bundle/python', '__PYVENV_LAUNCHER__': '/bundle/python',
                       'PYTHONNOUSERSITE': '1', '_PYI_APPLICATION_HOME_DIR': '/bundle', '_PYI_ARCHIVE_FILE': '/bundle/archive',
                       'DYLD_LIBRARY_PATH': '/bundle/lib', 'DYLD_LIBRARY_PATH_ORIG': '/user/lib',
                       'DYLD_FALLBACK_LIBRARY_PATH': '/bundle/fallback', 'LD_LIBRARY_PATH': '/bundle/lib',
                       'SSL_CERT_FILE': '/bundle/certifi/cacert.pem', 'UNRELATED_SETTING': 'kept'}
        with patch.dict(os.environ, environment, clear=True), patch.object(worker.sys, 'frozen', True, create=True), \
             patch.object(worker.sys, '_MEIPASS', '/bundle', create=True):
            result = worker.external_process_environment()
            self.assertEqual(result, {'PATH': '/user/tools:/usr/bin', 'DYLD_LIBRARY_PATH': '/user/lib', 'UNRELATED_SETTING': 'kept'})
            self.assertEqual(dict(os.environ), environment)

    def test_frozen_worker_removes_its_certificate_through_macos_bundle_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            frameworks=root/'Contents/Frameworks'; frameworks.mkdir(parents=True)
            resources=root/'Contents/Resources/certifi'; resources.mkdir(parents=True)
            (resources/'cacert.pem').write_text('fixture CA')
            (frameworks/'certifi').symlink_to(resources,target_is_directory=True)
            environment={'SSL_CERT_FILE':str(frameworks/'certifi/cacert.pem')}
            with patch.dict(os.environ,environment,clear=True),patch.object(worker.sys,'frozen',True,create=True), \
                 patch.object(worker.sys,'_MEIPASS',str(frameworks),create=True):
                self.assertNotIn('SSL_CERT_FILE',worker.external_process_environment())

    def test_frozen_worker_preserves_a_user_certificate_file_outside_the_bundle(self):
        environment = {'SSL_CERT_FILE': '/user/custom/ca.pem', 'PATH': '/usr/bin'}
        with patch.dict(os.environ, environment, clear=True), patch.object(worker.sys, 'frozen', True, create=True), \
             patch.object(worker.sys, '_MEIPASS', '/bundle', create=True):
            self.assertEqual(worker.external_process_environment(), environment)


if __name__ == '__main__':
    unittest.main()
