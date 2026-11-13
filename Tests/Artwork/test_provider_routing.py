"""Offline worker integration: user-owned credentials never enter job files or argv."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

from test_detail import write_test_png
from test_providers import Response, providers

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('provider_routing_worker', ROOT / 'Resources/Artwork/artwork_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
KEY = 'routing-test-key-never-persist-123456789'


class ProviderRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.job = self.root / 'job'; self.job.mkdir()
        self.reference = self.root / 'reference.png'; write_test_png(self.reference)
        self.png = self.reference.read_bytes()
        self.request = self.job / 'request.json'
        self.request.write_text(json.dumps({'prompt': 'A red toy robot', 'style': 'Clean vector', 'detail': 'Detailed',
                                           'format': 'portrait', 'reference': str(self.reference)}))
        self.api = types.SimpleNamespace(check_connection=Mock(return_value='API connection accepted'),
                                         generate_image=Mock(), improve_prompt=Mock(return_value='A carefully lit red toy robot'))
        self.old_server = worker.server
        self.addCleanup(setattr, worker, 'server', self.old_server)

    def run_main(self, mode, provider='openai', model='my-image-model', base='https://images.example.test/v1', key=KEY):
        argv = ['artwork_worker.py', mode, '--codex', '/not-a-real-codex', '--job', str(self.job), '--request', str(self.request)]
        config = {'provider': provider, 'model': model, 'baseURL': base}
        environment = {'MAGDOBE_PROVIDER_CONFIG': json.dumps(config), 'MAGDOBE_PROVIDER_API_KEY': key}
        output = io.StringIO()
        with patch.dict(os.environ, environment, clear=True), patch.object(sys, 'argv', argv), \
             patch.dict(sys.modules, {'provider_api': self.api}), contextlib.redirect_stdout(output):
            worker.main()
            self.assertNotIn('MAGDOBE_PROVIDER_API_KEY', os.environ)
        self.assertNotIn(KEY, output.getvalue())
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def assert_no_key_in_job(self):
        for path in self.job.iterdir():
            if path.is_file():
                self.assertNotIn(KEY.encode(), path.read_bytes(), path.name)

    def test_api_connection_check_routes_explicit_configuration_and_key(self):
        events = self.run_main('check', provider='openrouter', model='image-model', base='https://openrouter.ai/api/v1')
        self.api.check_connection.assert_called_once_with('openrouter', KEY, 'image-model', 'https://openrouter.ai/api/v1')
        self.api.generate_image.assert_not_called()
        self.api.improve_prompt.assert_not_called()
        self.assertEqual(events, [{'stage': 'connected', 'message': 'API connection accepted'}])
        self.assert_no_key_in_job()

    def test_api_generation_routes_reference_model_format_and_ephemeral_key(self):
        def generated(*args, **kwargs):
            source = Path(args[2]) / 'source.png'
            source.write_bytes(self.png)
            self.assertNotIn('MAGDOBE_PROVIDER_API_KEY', os.environ)
            return source
        self.api.generate_image.side_effect = generated
        original_request = self.request.read_bytes()
        with patch.object(worker, 'trace') as trace, patch.object(worker, 'Codex') as codex:
            self.run_main('generate', provider='gemini', model='gemini-nano-banana-2.1', base='https://generativelanguage.googleapis.com/v1beta')
        arguments = self.api.generate_image.call_args
        self.assertEqual(arguments.args[0], 'gemini')
        self.assertIn('A red toy robot', arguments.args[1])
        self.assertIn('Clean vector', arguments.args[1])
        self.assertEqual(arguments.args[2:], (self.job, KEY, 'gemini-nano-banana-2.1', 'https://generativelanguage.googleapis.com/v1beta'))
        self.assertEqual(arguments.kwargs, {'reference': self.reference, 'format': 'portrait'})
        trace.assert_called_once_with(self.job / 'source.png', self.job, 'Detailed')
        codex.assert_not_called()
        self.assertEqual(self.request.read_bytes(), original_request)
        self.assertEqual(self.reference.read_bytes(), self.png)
        self.assert_no_key_in_job()

    def test_trace_existing_image_bypasses_provider_credentials_and_network(self):
        self.request.write_text(json.dumps({'image': str(self.reference), 'detail': 'Ultra'}))
        with patch.object(worker, 'trace') as trace, patch.object(worker, 'Codex') as codex:
            self.run_main('trace', provider='openai', key='', model='', base='')
        self.api.check_connection.assert_not_called()
        self.api.generate_image.assert_not_called()
        self.api.improve_prompt.assert_not_called()
        codex.assert_not_called()
        trace.assert_called_once_with(self.job / 'source.png', self.job, 'Ultra')
        self.assertEqual((self.job / 'source.png').read_bytes(), self.png)
        self.assert_no_key_in_job()

    def test_anthropic_improvement_saves_suggestion_separately_from_original_brief(self):
        before = self.request.read_bytes()
        events = self.run_main('improve', provider='anthropic', model='claude-opus-5-5', base='https://api.anthropic.com/v1')
        self.api.improve_prompt.assert_called_once_with('anthropic', 'A red toy robot', KEY, 'claude-opus-5-5', 'https://api.anthropic.com/v1')
        self.assertEqual((self.job / 'prompt-suggestion.txt').read_text(), 'A carefully lit red toy robot')
        self.assertEqual(self.request.read_bytes(), before)
        self.assertEqual(events[-1]['stage'], 'done')
        self.api.generate_image.assert_not_called()
        self.assert_no_key_in_job()

    def test_prompt_improvement_is_not_silently_sent_to_an_image_provider(self):
        with self.assertRaisesRegex(RuntimeError, 'Choose Claude API or Claude Code'):
            self.run_main('improve', provider='openai')
        self.api.generate_image.assert_not_called()
        self.api.improve_prompt.assert_not_called()
        self.assertFalse((self.job / 'prompt-suggestion.txt').exists())

    def test_codex_default_connection_does_not_require_an_api_key(self):
        argv = ['artwork_worker.py', 'check', '--codex', '/not-a-real-codex']
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, 'argv', argv), \
             patch.object(worker, 'Codex') as codex, contextlib.redirect_stdout(io.StringIO()) as output:
            worker.main()
        codex.assert_called_once_with('/not-a-real-codex')
        codex.return_value.check.assert_called_once_with()
        self.assertIn('signed in with ChatGPT', output.getvalue())

    def test_claude_cli_uses_stdin_and_disables_tools_mcp_and_session_persistence(self):
        process = Mock(returncode=0)
        process.communicate.return_value = (json.dumps({'result': 'A carefully lit red toy robot'}), '')
        def launch(*args, **kwargs):
            self.assertNotIn('MAGDOBE_PROVIDER_API_KEY', os.environ)
            return process
        with patch.object(worker.shutil, 'which', return_value='/fake/claude'), patch.object(worker.subprocess, 'Popen', side_effect=launch) as popen:
            events = self.run_main('improve', provider='claudeCLI', model='sonnet', base='')
        arguments = popen.call_args.args[0]
        self.assertEqual(arguments[:4], ['/fake/claude', '-p', '--output-format', 'json'])
        self.assertEqual(arguments[arguments.index('--tools') + 1], '')
        self.assertIn('--strict-mcp-config', arguments)
        self.assertEqual(json.loads(arguments[arguments.index('--mcp-config') + 1]), {'mcpServers': {}})
        self.assertIn('--no-session-persistence', arguments)
        self.assertEqual(arguments[arguments.index('--setting-sources') + 1], '')
        self.assertEqual(arguments[arguments.index('--model') + 1], 'sonnet')
        self.assertNotIn('A red toy robot', arguments)
        self.assertNotIn(KEY, ' '.join(arguments))
        process.communicate.assert_called_once_with(input='A red toy robot', timeout=180)
        self.assertEqual(popen.call_args.kwargs['stdin'], subprocess.PIPE)
        self.assertEqual(popen.call_args.kwargs['cwd'], str(self.job))
        self.assertEqual((self.job / 'prompt-suggestion.txt').read_text(), 'A carefully lit red toy robot')
        self.assertEqual(events[-1]['stage'], 'done')
        self.assert_no_key_in_job()

    def test_claude_cli_connection_check_uses_only_auth_status(self):
        process = Mock(returncode=0)
        process.communicate.return_value = ('{"loggedIn":true}', '')
        with patch.object(worker.shutil, 'which', return_value='/fake/claude'), patch.object(worker.subprocess, 'Popen', return_value=process) as popen:
            events = self.run_main('check', provider='claudeCLI', model='sonnet', base='')
        self.assertEqual(popen.call_args.args[0], ['/fake/claude', 'auth', 'status'])
        process.communicate.assert_called_once_with(input=None, timeout=25)
        self.assertIn('existing sign-in', events[0]['message'])
        self.api.check_connection.assert_not_called()
        self.api.improve_prompt.assert_not_called()

    def test_missing_claude_cli_has_a_clear_error_and_never_spawns_a_process(self):
        with patch.object(worker.shutil, 'which', return_value=None), patch.object(worker.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(RuntimeError, 'Claude Code is not installed'):
                self.run_main('check', provider='claudeCLI', key='', base='')
            popen.assert_not_called()

    def test_claude_cli_failure_does_not_echo_stderr_or_credentials(self):
        process = Mock(returncode=1)
        process.communicate.return_value = ('', 'Unauthorized ' + KEY)
        with patch.object(worker.shutil, 'which', return_value='/fake/claude'), patch.object(worker.subprocess, 'Popen', return_value=process):
            with self.assertRaises(RuntimeError) as caught:
                self.run_main('improve', provider='claudeCLI', model='sonnet', base='')
        self.assertIn('Check its sign-in', str(caught.exception))
        self.assertNotIn(KEY, str(caught.exception))
        self.assertFalse((self.job / 'prompt-suggestion.txt').exists())

    def test_api_malformed_responses_keep_an_existing_source_file(self):
        target = self.job / 'source.png'; target.write_bytes(self.png)
        damaged = bytearray(self.png); damaged[50] ^= 1
        responses = [b'not JSON', {'data': []}, {'data': [{'b64_json': base64.b64encode(bytes(damaged)).decode('ascii')}]}]
        for response in responses:
            with self.subTest(response_type=type(response).__name__), patch.object(providers, '_open', return_value=Response(response)):
                with self.assertRaises(providers.ProviderError):
                    providers.generate_image('openai', 'A red robot', self.job, KEY, '', '')
            self.assertEqual(target.read_bytes(), self.png)
            self.assert_no_key_in_job()
        self.assertEqual({p.name for p in self.job.iterdir()}, {'request.json', 'source.png'})


if __name__ == '__main__':
    unittest.main()
