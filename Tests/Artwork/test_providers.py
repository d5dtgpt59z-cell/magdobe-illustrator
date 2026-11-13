"""Offline HTTP and image-safety checks. No live provider requests or credentials."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import zlib

from test_detail import write_test_png

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('provider_api', ROOT / 'Resources/Artwork/provider_api.py')
providers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(providers)
KEY = 'test-secret-do-not-persist-123456789'


class Response(io.BytesIO):
    def __init__(self, value, headers=None):
        super().__init__(value if isinstance(value, bytes) else json.dumps(value).encode())
        self.headers = headers or {}


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.reference = self.root / 'reference.png'
        write_test_png(self.reference)
        self.png = self.reference.read_bytes()
        self.encoded = base64.b64encode(self.png).decode('ascii')
        self.job = self.root / 'job'

    def generate(self, provider, response, **kwargs):
        with patch.object(providers, '_open', return_value=Response(response)) as opened:
            source = providers.generate_image(provider, 'A tiny red robot', self.job, KEY,
                                              kwargs.pop('model', ''), kwargs.pop('base_url', ''), **kwargs)
        self.assertEqual(source, self.job / 'source.png')
        self.assertEqual(source.read_bytes(), self.png)
        self.assertEqual(self.reference.read_bytes(), self.png)
        return opened.call_args.args[0]

    def payload(self, request):
        return json.loads(request.data)

    def test_openai_images_api_returns_editable_pipeline_source_without_persisting_key(self):
        request = self.generate('openai', {'data': [{'b64_json': self.encoded}]}, format='portrait')
        self.assertEqual(request.full_url, 'https://api.openai.com/v1/images/generations')
        self.assertEqual(request.get_header('Authorization'), 'Bearer ' + KEY)
        self.assertEqual(self.payload(request), {'model': 'gpt-image-2.5-flare', 'prompt': 'A tiny red robot',
                                               'n': 1, 'size': '1024x1536', 'output_format': 'png'})
        self.assertNotIn(KEY.encode(), request.data)
        self.assertEqual([p.name for p in self.job.iterdir()], ['source.png'])

    def test_openai_reference_uses_multipart_without_changing_reference_or_serializing_key(self):
        request = self.generate('openai', {'data': [{'b64_json': self.encoded}]}, reference=self.reference)
        self.assertEqual(request.full_url, 'https://api.openai.com/v1/images/edits')
        self.assertIn('multipart/form-data', request.get_header('Content-type'))
        self.assertIn(b'name="image"; filename="reference.png"', request.data)
        self.assertIn(self.png, request.data)
        self.assertNotIn(KEY.encode(), request.data)

    def test_gemini_current_interactions_request_and_response(self):
        request = self.generate('gemini', {'output_image': {'data': self.encoded, 'mime_type': 'image/png'}},
                                reference=self.reference, format='landscape')
        self.assertEqual(request.full_url, 'https://generativelanguage.googleapis.com/v1beta/interactions')
        self.assertEqual(request.get_header('X-goog-api-key'), KEY)
        self.assertNotIn('key=', request.full_url)
        self.assertEqual(request.get_header('Api-revision'), '2026-05-20')
        body = self.payload(request)
        self.assertEqual(body['model'], 'gemini-nano-banana-2.1')
        self.assertEqual(body['input'][1], {'type': 'image', 'mime_type': 'image/png', 'data': self.encoded})
        self.assertEqual(body['response_format'], {'type': 'image', 'aspect_ratio': '3:2'})

    def test_gemini_older_generate_content_response_is_supported(self):
        response = {'candidates': [{'content': {'parts': [{'inlineData': {'mimeType': 'image/png', 'data': self.encoded}}]}}]}
        request = self.generate('gemini', response, model='gemini-2.5-flash-image')
        self.assertEqual(request.full_url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent')
        self.assertEqual(self.payload(request)['generationConfig']['responseModalities'], ['TEXT', 'IMAGE'])

    def test_openrouter_images_api_accepts_optional_reference_and_data_url_legacy_result(self):
        response = {'choices': [{'message': {'images': [{'image_url': {'url': 'data:image/png;base64,' + self.encoded}}]}}]}
        request = self.generate('openrouter', response, reference=self.reference)
        self.assertEqual(request.full_url, 'https://openrouter.ai/api/v1/images')
        body = self.payload(request)
        self.assertEqual(body['model'], 'google/gemini-2.5-flash-image')
        self.assertEqual(body['input_references'][0]['image_url']['url'], 'data:image/png;base64,' + self.encoded)

    def test_compatible_model_and_explicit_base_url_are_used_without_guessing(self):
        request = self.generate('compatible', {'data': [{'b64_json': self.encoded}]},
                                base_url='https://images.example.test/custom/v1/', model='my-image-model')
        self.assertEqual(request.full_url, 'https://images.example.test/custom/v1/images/generations')
        self.assertEqual(self.payload(request)['model'], 'my-image-model')
        self.assertEqual(self.payload(request)['response_format'], 'b64_json')

    def test_local_compatible_provider_can_run_without_an_api_key(self):
        with patch.object(providers, '_open', return_value=Response({'data': [{'b64_json': self.encoded}]})) as opened:
            providers.generate_image('compatible', 'A red robot', self.job, '', 'local-model', 'http://127.0.0.1:1234/v1')
        self.assertIsNone(opened.call_args.args[0].get_header('Authorization'))

    def test_http_failure_and_provider_error_never_expose_the_key(self):
        for error in [urllib.error.HTTPError('https://example.test', 401, 'Unauthorized', {}, io.BytesIO(json.dumps({'error': {'message': 'Rejected key ' + KEY}}).encode())),
                      None]:
            with self.subTest(error=error):
                kwargs = {'side_effect': error} if error else {'return_value': Response({'error': {'message': 'Rejected ' + KEY}})}
                with patch.object(providers, '_open', **kwargs):
                    with self.assertRaises(providers.ProviderError) as caught:
                        providers.generate_image('openai', 'A red robot', self.job, KEY, '', '')
                self.assertIn('[redacted]', str(caught.exception))
                self.assertNotIn(KEY, str(caught.exception))
                self.assertFalse((self.job / 'source.png').exists())

    def test_authentication_redirect_is_rejected_instead_of_forwarding_credentials(self):
        error = urllib.error.HTTPError('https://api.openai.com', 307, 'Redirect', {'Location': 'https://other.example'}, io.BytesIO(b''))
        with patch.object(providers, '_open', side_effect=error):
            with self.assertRaisesRegex(providers.ProviderError, 'credentials were not forwarded'):
                providers.check_connection('openai', KEY, '', '')
        self.assertIsNone(providers._NoRedirect().redirect_request(None, None, 307, 'Redirect', {}, 'https://other.example'))

    def test_url_validation_rejects_plaintext_remote_urls_and_embedded_credentials(self):
        for url in ['http://api.example.test/v1', 'https://user:password@example.test/v1', 'https://example.test/v1?key=123',
                    'https://example.test/v1#fragment', 'file:///tmp/server', 'https://example.test/../v1', 'https://example.test\\other/v1']:
            with self.subTest(url=url), self.assertRaises(providers.ProviderError):
                providers.validate_base_url(url)
        self.assertEqual(providers.validate_base_url('http://localhost:1234/v1/'), 'http://localhost:1234/v1')
        self.assertEqual(providers.validate_base_url('http://[::1]:1234/v1'), 'http://[::1]:1234/v1')

    def test_remote_image_download_does_not_receive_provider_authorization(self):
        with patch.object(providers, '_open', side_effect=[Response({'data': [{'url': 'https://cdn.example.test/result.png?signature=demo'}]}), Response(self.png)]) as opened:
            source = providers.generate_image('compatible', 'A robot', self.job, KEY, 'image-model', 'https://api.example.test/v1')
        requests = [call.args[0] for call in opened.call_args_list]
        self.assertEqual(requests[0].get_header('Authorization'), 'Bearer ' + KEY)
        self.assertIsNone(requests[1].get_header('Authorization'))
        self.assertEqual(source.read_bytes(), self.png)
        with self.assertRaisesRegex(providers.ProviderError, 'must use HTTPS'):
            providers._download_image('http://cdn.example.test/result.png')

    def test_no_image_and_safety_rejections_are_meaningful(self):
        for response, expected in [({'candidates': []}, 'returned no image'),
                                   ({'promptFeedback': {'blockReason': 'SAFETY'}}, 'safety system'),
                                   ({'data': [{'b64_json': 'invalid base64!?'}]}, 'invalid base64')]:
            with self.subTest(response=response), patch.object(providers, '_open', return_value=Response(response)):
                with self.assertRaisesRegex(providers.ProviderError, expected):
                    providers.generate_image('gemini', 'A robot', self.job, KEY, '', '')
                self.assertFalse((self.job / 'source.png').exists())

    def test_invalid_png_preserves_an_existing_source(self):
        self.job.mkdir(); target = self.job / 'source.png'; target.write_bytes(self.png)
        damaged = bytearray(self.png); damaged[50] ^= 1
        with self.assertRaisesRegex(providers.ProviderError, 'damaged PNG'):
            providers._save_image(bytes(damaged), self.job)
        self.assertEqual(target.read_bytes(), self.png)
        self.assertEqual([p.name for p in self.job.iterdir()], ['source.png'])

    def test_image_pixel_and_response_size_limits_are_enforced(self):
        oversized = bytearray(self.png)
        oversized[16:24] = struct.pack('>II', 100000, 100000)
        oversized[29:33] = struct.pack('>I', zlib.crc32(oversized[12:29]) & 0xffffffff)
        with self.assertRaisesRegex(providers.ProviderError, '64-million-pixel'):
            providers._save_image(bytes(oversized), self.job)
        with self.assertRaisesRegex(providers.ProviderError, 'too large'):
            providers._read_response(Response(b'x', {'Content-Length': str(providers.MAX_RESPONSE_BYTES + 1)}), providers.MAX_RESPONSE_BYTES)

    def test_claude_refines_prompt_without_tools_or_artwork_generation(self):
        long_text = 'A red robot with careful detail. ' * 50
        with patch.object(providers, '_open', return_value=Response({'content': [{'type': 'text', 'text': long_text}], 'stop_reason': 'end_turn'})) as opened:
            result = providers.improve_prompt('anthropic', 'A red robot', KEY, 'claude-opus-5-5', '')
        request = opened.call_args.args[0]; body = self.payload(request)
        self.assertEqual(request.full_url, 'https://api.anthropic.com/v1/messages')
        self.assertEqual(request.get_header('Anthropic-version'), '2026-10-21')
        self.assertNotIn('tools', body)
        self.assertEqual(body['messages'][0]['content'], 'A red robot')
        self.assertEqual(result, long_text.strip())
        with self.assertRaisesRegex(providers.ProviderError, 'refines artwork briefs'):
            providers.generate_image('anthropic', 'A red robot', self.job, KEY, '', '')

    def test_claude_refusal_keeps_the_original_prompt(self):
        with patch.object(providers, '_open', return_value=Response({'stop_reason': 'refusal', 'content': []})):
            with self.assertRaisesRegex(providers.ProviderError, 'original prompt has been kept'):
                providers.improve_prompt('anthropic', 'A robot', KEY, '', '')

    def test_connection_checks_do_not_make_billed_generation_requests(self):
        for provider, suffix in [('openai', '/models'), ('gemini', '/models?pageSize=1'), ('openrouter', '/key'), ('anthropic', '/models?limit=1')]:
            with self.subTest(provider=provider), patch.object(providers, '_open', return_value=Response({'data': []})) as opened:
                message = providers.check_connection(provider, KEY, '', '')
                request = opened.call_args.args[0]
                self.assertEqual(request.get_method(), 'GET')
                self.assertIsNone(request.data)
                self.assertTrue(request.full_url.endswith(suffix))
                self.assertIn('connection accepted', message)

    def test_large_reference_is_rejected_before_any_network_request(self):
        with self.reference.open('wb') as file:
            file.truncate(providers.MAX_REFERENCE_BYTES + 1)
        with patch.object(providers, '_open') as opened:
            with self.assertRaisesRegex(providers.ProviderError, 'smaller than 20 MB'):
                providers.generate_image('openai', 'A robot', self.job, KEY, '', '', self.reference)
            opened.assert_not_called()


if __name__ == '__main__':
    unittest.main()
