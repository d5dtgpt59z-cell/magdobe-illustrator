"""Offline production proposals: provider schemas, source units and account-only routing."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

from test_providers import Response, providers

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('production_assistant_under_test', ROOT / 'Resources/Artwork/production_assistant.py')
production = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'provider_api': providers}):
    spec.loader.exec_module(production)
worker_spec = importlib.util.spec_from_file_location('production_worker_under_test', ROOT / 'Resources/Artwork/artwork_worker.py')
worker = importlib.util.module_from_spec(worker_spec)
worker_spec.loader.exec_module(worker)
KEY = 'production-test-secret-never-persist-123456789'
CURRENT = {'schema_version': 1, 'workflow': 'trading_card', 'name': 'Artist card',
           'trim_width_mm': 63.5, 'trim_height_mm': 88.9, 'bleed_mm': 3.175, 'safe_mm': 3.175,
           'placement': 'fit_trim', 'bleed_intent': 'full_bleed', 'color_policy': 'review_rgb',
           'supplier_confirmed': True}


def proposal(changes=None, sources=None, **extra):
    value = {'proposed_job': dict(CURRENT, **(changes or {})), 'unknowns': ['Confirm stock and print condition'],
             'explanation': 'Apply only the supplied printer measurements.', 'evidence': [],
             'field_evidence': sources or {}}
    value.update(extra)
    return value


class ProductionAssistantTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.job = Path(self.temp.name).resolve()
        self.request = {'instructions': 'Trim width 2.5 inches. Keep other dimensions.', 'current_job': copy.deepcopy(CURRENT)}
        previous = worker.server
        self.addCleanup(setattr, worker, 'server', previous)

    def test_each_api_uses_selected_text_model_endpoint_schema_and_header_only_key(self):
        cases = [
            ('openai', 'https://api.openai.com/v1', '/chat/completions'),
            ('gemini', 'https://generativelanguage.googleapis.com/v1beta', '/models/text-model:generateContent'),
            ('anthropic', 'https://api.anthropic.com/v1', '/messages'),
            ('openrouter', 'https://openrouter.ai/api/v1', '/chat/completions'),
            ('compatible', 'https://my-provider.example/v1', '/chat/completions')]
        raw = json.dumps(proposal())
        for provider, base, route in cases:
            with self.subTest(provider=provider):
                response = ({'content': [{'type': 'text', 'text': raw}]} if provider == 'anthropic' else
                            {'candidates': [{'content': {'parts': [{'text': raw}]}}]} if provider == 'gemini' else
                            {'choices': [{'message': {'content': raw}}]})
                with patch.object(providers, '_open', return_value=Response(response)) as opened:
                    target = production.propose(self.request, {'provider': provider, 'model': 'text-model', 'baseURL': base}, KEY, self.job)
                http = opened.call_args.args[0]
                self.assertEqual(http.full_url, base + route)
                self.assertEqual(http.method, 'POST')
                self.assertNotIn(KEY, http.full_url)
                self.assertNotIn(KEY.encode(), http.data)
                body = json.loads(http.data)
                if provider == 'gemini':
                    self.assertEqual(http.get_header('X-goog-api-key'), KEY)
                    self.assertEqual(body['generationConfig'], {'responseMimeType': 'application/json'})
                    self.assertEqual(body['systemInstruction']['parts'][0]['text'], production.SYSTEM)
                    source = json.loads(body['contents'][0]['parts'][0]['text'])
                else:
                    self.assertEqual(body['model'], 'text-model')
                    self.assertEqual(http.get_header('X-api-key') if provider == 'anthropic' else http.get_header('Authorization'), KEY if provider == 'anthropic' else 'Bearer ' + KEY)
                    if provider == 'anthropic':
                        self.assertIsNone(http.get_header('Authorization'))
                        self.assertEqual(body['system'], production.SYSTEM)
                        self.assertEqual(body['max_tokens'], 4000)
                        source = json.loads(body['messages'][0]['content'])
                    else:
                        self.assertEqual(body['messages'][0], {'role': 'system', 'content': production.SYSTEM})
                        source = json.loads(body['messages'][1]['content'])
                self.assertEqual(source['printer_instructions'], self.request['instructions'])
                self.assertEqual(source['current_job'], CURRENT)
                self.assertNotIn('tools', body)
                self.assertEqual(target, self.job / 'production-proposal.json')
                saved = json.loads(target.read_text())
                self.assertFalse(saved['proposed_job']['supplier_confirmed'])
                self.assertNotIn(KEY, target.read_text())
                self.assertEqual(self.request['current_job'], CURRENT)

    def test_empty_api_model_and_remote_http_rejected_without_request(self):
        for provider, model, base in [('openai', '', ''), ('compatible', 'text-model', 'http://remote.example/v1')]:
            with patch.object(providers, '_open') as opened, self.assertRaises(providers.ProviderError):
                production.propose(self.request, {'provider': provider, 'model': model, 'baseURL': base}, KEY, self.job)
            opened.assert_not_called()

    def test_local_compatible_text_provider_needs_no_key(self):
        raw = {'choices': [{'message': {'content': json.dumps(proposal())}}]}
        with patch.object(providers, '_open', return_value=Response(raw)) as opened:
            production.propose(self.request, {'provider': 'compatible', 'model': 'local-text', 'baseURL': 'http://127.0.0.1:1234/v1'}, '', self.job)
        self.assertIsNone(opened.call_args.args[0].get_header('Authorization'))

    def test_unit_conversion_fraction_cm_point_text_and_raster_are_evidence_bound(self):
        instructions = 'Trim width 3 inches. Height 9 cm. Bleed 1/8 inch. Safe inset 9 points. Minimum text 7 pt. Minimum line 0.2 mm. Images 300 ppi.'
        changes = {'trim_width_mm': 76.2, 'trim_height_mm': 90, 'bleed_mm': 3.175, 'safe_mm': 3.175,
                   'min_text_pt': 7, 'min_stroke_mm': 0.2, 'min_raster_ppi': 300}
        sources = {'trim_width_mm': 'Trim width 3 inches.', 'trim_height_mm': 'Height 9 cm.', 'bleed_mm': 'Bleed 1/8 inch.',
                   'safe_mm': 'Safe inset 9 points.', 'min_text_pt': 'Minimum text 7 pt.',
                   'min_stroke_mm': 'Minimum line 0.2 mm.', 'min_raster_ppi': 'Images 300 ppi.'}
        result = production.validate_proposal(proposal(changes, sources, evidence=list(sources.values())), CURRENT, instructions)
        self.assertEqual(result['proposed_job'], dict(CURRENT, **changes, supplier_confirmed=False))
        self.assertEqual(result['evidence'], list(sources.values()))
        self.assertEqual(CURRENT['supplier_confirmed'], True)
        for wrong in [25.4, 203.2]:
            with self.subTest(wrong_fraction=wrong), self.assertRaisesRegex(providers.ProviderError, 'measurement|invalid'):
                production.validate_proposal(proposal({'bleed_mm': wrong}, {'bleed_mm': 'Bleed 1/8 inch.'}), CURRENT, instructions)

    def test_mixed_units_cannot_be_cross_applied_to_unrelated_number(self):
        quote = 'Trim width 2.5 inches; bleed 3 mm.'
        for wrong in [2.5, 63.5, 76.2]:
            with self.subTest(wrong=wrong), self.assertRaises(providers.ProviderError):
                production.validate_proposal(proposal({'bleed_mm': wrong}, {'bleed_mm': quote}), CURRENT, quote)
        self.assertEqual(production.validate_proposal(proposal({'bleed_mm': 3}, {'bleed_mm': quote}), CURRENT, quote)['proposed_job']['bleed_mm'], 3)
        self.assertEqual(production._quoted_measurements('Width 2 1 / 2 inches', 'trim_width_mm'), [63.5])
        self.assertEqual(production._quoted_measurements('Size 2.5 x 3.5 inches', 'trim_width_mm'), [63.5, 88.89999999999999])
        self.assertEqual(production._quoted_measurements('Bleed 1/0 inch', 'bleed_mm'), [])

    def test_wrong_units_missing_sources_and_fabricated_evidence_are_rejected(self):
        cases = [
            (proposal({'min_text_pt': 7}, {'min_text_pt': 'Line 7 mm.'}), 'Line 7 mm.'),
            (proposal({'min_raster_ppi': 300}, {'min_raster_ppi': '300 objects.'}), '300 objects.'),
            (proposal({'bleed_mm': 4}), 'Bleed 4 mm.'),
            (proposal(evidence=['A nonexistent supplier approved it.']), 'Bleed 4 mm.'),
            (proposal({'safe_mm': 4}, {'safe_mm': 'Safe 4 mm.'}), 'No safe margin supplied.')]
        for raw, instructions in cases:
            with self.subTest(raw=raw), self.assertRaises(providers.ProviderError):
                production.validate_proposal(raw, CURRENT, instructions)

    def test_strict_json_and_numerical_or_unsupported_changes_are_rejected(self):
        cases = ['```json\n{}\n```', 'not json', [], {}, proposal({'unsupported_action': 'delete artwork'}),
                 proposal({'trim_width_mm': True}), proposal({'trim_width_mm': float('nan')}),
                 proposal({'trim_width_mm': float('inf')}), proposal({'trim_width_mm': 100000}),
                 proposal({'color_policy': 'invented'}), proposal({'workflow': 'pdfx_certified'}),
                 proposal({'safe_mm': 50}, {'safe_mm': 'Safe 50 mm.'}),
                 proposal(unknowns=['x'] * 101), proposal(explanation='x' * 8001)]
        for value in cases:
            with self.subTest(value=repr(value)[:100]), self.assertRaises(providers.ProviderError):
                production.validate_proposal(value, CURRENT, 'Safe 50 mm.')

    def test_invalid_provider_response_keeps_previous_reviewable_proposal(self):
        previous = b'previous proposal kept'
        target = self.job / 'production-proposal.json'; target.write_bytes(previous)
        responses = [b'not JSON', {}, {'choices': []}, {'choices': [{'message': {'content': 'not JSON'}}]}]
        for response in responses:
            with self.subTest(response=response), patch.object(providers, '_open', return_value=Response(response)):
                with self.assertRaises(providers.ProviderError):
                    production.propose(self.request, {'provider': 'openai', 'model': 'text-model'}, KEY, self.job)
            self.assertEqual(target.read_bytes(), previous)
            self.assertFalse(target.with_suffix('.next').exists())

    def test_provider_http_error_redacts_key_and_never_saves_response_body(self):
        error = urllib.error.HTTPError('https://api.openai.com/v1/chat/completions', 401, 'Unauthorized', {}, io.BytesIO(json.dumps({'error': {'message': 'Bad key ' + KEY}}).encode()))
        with patch.object(providers, '_open', side_effect=error), self.assertRaises(providers.ProviderError) as caught:
            production.propose(self.request, {'provider': 'openai', 'model': 'text-model'}, KEY, self.job)
        self.assertNotIn(KEY, str(caught.exception))
        self.assertIn('[redacted]', str(caught.exception))
        self.assertEqual(list(self.job.iterdir()), [])

    def test_success_response_echoing_secret_is_rejected_without_overwrite(self):
        target = self.job / 'production-proposal.json'; target.write_text('previous proposal')
        response = {'choices': [{'message': {'content': json.dumps(proposal(explanation='Internal provider echo ' + KEY))}}]}
        with patch.object(providers, '_open', return_value=Response(response)):
            with self.assertRaises(providers.ProviderError) as caught:
                production.propose(self.request, {'provider': 'openai', 'model': 'text-model'}, KEY, self.job)
        self.assertNotIn(KEY, str(caught.exception))
        self.assertEqual(target.read_text(), 'previous proposal')

    def test_account_adapter_uses_callback_and_persists_review_only(self):
        callback = Mock(return_value=json.dumps(proposal()))
        for provider in ['codex', 'claudeCLI']:
            target = production.propose(self.request, {'provider': provider, 'model': 'account-model'}, '', self.job, '/fake/codex', callback)
            args = callback.call_args.args
            self.assertEqual(args[0], provider)
            self.assertEqual(args[1], production.SYSTEM)
            self.assertEqual(json.loads(args[2])['current_job'], CURRENT)
            self.assertEqual(args[3:], (self.job, 'account-model', '/fake/codex'))
            self.assertFalse(json.loads(target.read_text())['proposed_job']['supplier_confirmed'])
        self.assertEqual(self.request['current_job'], CURRENT)

    def test_worker_print_spec_routes_ephemeral_key_without_generation_or_tracing(self):
        request_file = self.job / 'request.json'; request_file.write_text(json.dumps(self.request))
        before = request_file.read_bytes()
        config = {'provider': 'openrouter', 'model': 'text-model', 'baseURL': 'https://openrouter.ai/api/v1'}
        def make_proposal(request, passed, key, job, codex, run_cli):
            self.assertEqual(request, self.request); self.assertEqual(passed, config); self.assertEqual(key, KEY)
            self.assertNotIn('MAGDOBE_PROVIDER_API_KEY', os.environ)
            self.assertEqual(job, self.job); self.assertEqual(codex, '/fake/codex')
            self.assertIs(run_cli, worker.production_cli)
            return job / 'production-proposal.json'
        fake = Mock(); fake.propose.side_effect = make_proposal
        argv = ['artwork_worker.py', 'print-spec', '--job', str(self.job), '--request', str(request_file), '--codex', '/fake/codex']
        with patch.dict(sys.modules, {'production_assistant': fake}), patch.dict(os.environ, {'MAGDOBE_PROVIDER_CONFIG': json.dumps(config), 'MAGDOBE_PROVIDER_API_KEY': KEY}, clear=True), patch.object(sys, 'argv', argv), patch.object(worker, 'trace') as trace, patch.object(worker, 'Codex') as codex, contextlib.redirect_stdout(io.StringIO()) as output:
            worker.main()
        trace.assert_not_called(); codex.assert_not_called()
        self.assertEqual(request_file.read_bytes(), before)
        self.assertNotIn(KEY, output.getvalue())
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['stage'], 'done')

    def test_codex_and_claude_cli_keep_brief_on_stdin_and_disable_tools(self):
        for provider in ['codex', 'claudeCLI']:
            process = Mock(returncode=0)
            process.communicate.return_value = (json.dumps({'result': json.dumps(proposal())}), '')
            def launch(args, **kwargs):
                if provider == 'codex':
                    Path(args[args.index('--output-last-message') + 1]).write_text(json.dumps(proposal()))
                return process
            with self.subTest(provider=provider), patch.object(worker.shutil, 'which', return_value='/fake/claude'), patch.object(worker.subprocess, 'Popen', side_effect=launch) as opened:
                result = worker.production_cli(provider, production.SYSTEM, 'SOURCE-SPEC-ONLY', self.job, 'chosen-model', '/fake/codex')
            args = opened.call_args.args[0]
            self.assertNotIn('SOURCE-SPEC-ONLY', args)
            self.assertNotIn(KEY, ' '.join(args))
            self.assertEqual(args[args.index('--model') + 1], 'chosen-model')
            self.assertEqual(opened.call_args.kwargs['cwd'], str(self.job))
            self.assertEqual(opened.call_args.kwargs['stdin'], subprocess.PIPE)
            if provider == 'codex':
                self.assertEqual(args[:2], ['/fake/codex', 'exec'])
                self.assertEqual(args[args.index('--sandbox') + 1], 'read-only')
                for flag in ['--ignore-user-config', '--ignore-rules', '--ephemeral', '--skip-git-repo-check']:
                    self.assertIn(flag, args)
                self.assertIn('shell_tool', args); self.assertIn('apps', args)
                self.assertIn(production.SYSTEM, process.communicate.call_args.kwargs['input'])
                self.assertIn('SOURCE-SPEC-ONLY', process.communicate.call_args.kwargs['input'])
            else:
                self.assertEqual(args[args.index('--tools') + 1], '')
                self.assertIn('--strict-mcp-config', args)
                self.assertEqual(json.loads(args[args.index('--mcp-config') + 1]), {'mcpServers': {}})
                self.assertIn('--no-session-persistence', args)
                self.assertEqual(args[args.index('--setting-sources') + 1], '')
                self.assertEqual(process.communicate.call_args.kwargs['input'], 'SOURCE-SPEC-ONLY')
            self.assertEqual(json.loads(result)['proposed_job'], CURRENT)

    def test_account_failures_timeout_missing_cli_and_cancellation_are_actionable(self):
        with patch.object(worker.shutil, 'which', return_value=None), self.assertRaisesRegex(RuntimeError, 'not installed'):
            worker.production_cli('claudeCLI', production.SYSTEM, 'source', self.job, '', '')
        with self.assertRaisesRegex(RuntimeError, 'Install Codex'):
            worker.production_cli('codex', production.SYSTEM, 'source', self.job, '', None)
        process = Mock(returncode=1); process.communicate.return_value = (KEY, KEY)
        with patch.object(worker.subprocess, 'Popen', return_value=process), self.assertRaises(RuntimeError) as caught:
            worker.production_cli('codex', production.SYSTEM, 'source', self.job, '', '/fake/codex')
        self.assertNotIn(KEY, str(caught.exception))
        process.returncode = 0; process.communicate.side_effect = subprocess.TimeoutExpired('fake', 180)
        with patch.object(worker.subprocess, 'Popen', return_value=process), patch.object(worker, 'stop') as stopped, self.assertRaisesRegex(RuntimeError, 'timed out'):
            worker.production_cli('codex', production.SYSTEM, 'source', self.job, '', '/fake/codex')
        stopped.assert_called_once_with()
        process.poll.return_value = None; worker.server = process
        with self.assertRaises(SystemExit) as cancelled:
            worker.stop(signal.SIGTERM)
        self.assertEqual(cancelled.exception.code, 130)
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=3)


if __name__ == '__main__':
    unittest.main()
