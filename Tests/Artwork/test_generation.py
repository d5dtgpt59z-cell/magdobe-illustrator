"""Offline app-server event regressions; no account or image-generation calls."""
import base64
import collections
import contextlib
import importlib.util
import io
from pathlib import Path
import queue
import tempfile
import unittest
from unittest.mock import Mock

from test_detail import write_test_png

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('generation_worker', ROOT / 'Resources/Artwork/artwork_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

THREAD = 'thread-main'
TURN = 'turn-main'


def item_completed(item, thread=THREAD, turn=TURN):
    return {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}}


def turn_completed(status='completed', error=None, thread=THREAD, turn=TURN):
    value = {'id': turn, 'status': status}
    if error is not None:
        value['error'] = {'message': error}
    return {'method': 'turn/completed', 'params': {'threadId': thread, 'turn': value}}


def image_item(**values):
    return dict({'id': 'image-main', 'type': 'imageGeneration', 'status': 'completed'}, **values)


class GenerationTests(unittest.TestCase):
    def client(self, events):
        client = worker.Codex.__new__(worker.Codex)
        client.check = Mock(return_value={'type': 'chatgpt'})
        def call(method, _params):
            if method == 'thread/start':
                return {'thread': {'id': THREAD}}
            if method == 'turn/start':
                return {'turn': {'id': TURN, 'status': 'inProgress'}}
            self.fail('Unexpected RPC: ' + method)
        client.call = Mock(side_effect=call)
        client.receive = Mock(side_effect=events)
        return client

    def generate(self, job, events):
        client = self.client(events)
        with contextlib.redirect_stdout(io.StringIO()):
            return client.generate(job, {'prompt': 'A detailed red toy robot', 'style': 'Painted detail', 'format': 'square'})

    def test_completed_image_uses_absolute_or_job_relative_saved_path(self):
        for relative in (False, True):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as tmp:
                job = Path(tmp)
                generated = job / 'generated.png'; write_test_png(generated)
                before = generated.read_bytes()
                result = self.generate(job, [
                    item_completed(image_item(savedPath='generated.png' if relative else str(generated))),
                    turn_completed(),
                ])
                self.assertEqual(result, job / 'source.png')
                self.assertEqual(result.read_bytes(), before)
                self.assertEqual(generated.read_bytes(), before)

    def test_completed_image_uses_inline_png_or_data_url(self):
        for data_url in (False, True):
            with self.subTest(data_url=data_url), tempfile.TemporaryDirectory() as tmp:
                job = Path(tmp); original = job / 'expected.png'; write_test_png(original)
                expected = original.read_bytes(); encoded = base64.b64encode(expected).decode('ascii')
                value = 'data:image/png;base64,' + encoded if data_url else encoded
                result = self.generate(job, [item_completed(image_item(result=value)), turn_completed()])
                self.assertEqual(result.read_bytes(), expected)

    def test_native_usage_limit_failure_is_not_reported_as_missing_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            events = [
                item_completed(image_item(status='failed', failure={'type': 'usageLimitExceeded', 'limitId': 'images', 'resetsAt': 1900000000}, result='')),
                turn_completed(),
            ]
            with self.assertRaisesRegex(RuntimeError, '(?i)usage limit'):
                self.generate(job, events)
            self.assertFalse((job / 'source.png').exists())

    def test_assistant_explanation_survives_completion_without_an_image(self):
        explanation = 'The image service is temporarily unavailable. Please try again later.'
        events = [item_completed({'id': 'answer', 'type': 'agentMessage', 'phase': 'final', 'text': explanation}), turn_completed()]
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'image service is temporarily unavailable'):
                self.generate(Path(tmp), events)

    def test_failed_turn_surfaces_the_actual_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'Image service returned HTTP 503'):
                self.generate(Path(tmp), [turn_completed('failed', 'Image service returned HTTP 503')])

    def test_other_threads_cannot_finish_the_requested_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp); original = job / 'generated.png'; write_test_png(original)
            expected = original.read_bytes()
            events = [
                turn_completed('failed', 'Unrelated request failed', thread='thread-other', turn='turn-other'),
                item_completed(image_item(savedPath=str(original))),
                turn_completed(),
            ]
            result = self.generate(job, events)
            self.assertEqual(result.read_bytes(), expected)

    def test_file_reference_only_reports_missing_attachment_explicitly(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = [item_completed(image_item(fileId='file-image-only', result='', savedPath=None)), turn_completed()]
            with self.assertRaisesRegex(RuntimeError, '(?i)file reference'):
                self.generate(Path(tmp), events)

    def test_safety_rejection_is_clear_and_keeps_the_support_request_id(self):
        explanation = 'http 400 moderation_blocked: Your request was rejected by the safety system. Include request ID abc123-test in a support request.'
        with tempfile.TemporaryDirectory() as tmp:
            events = [item_completed(image_item(status='failed', failure=None)),
                      item_completed({'type': 'agentMessage', 'text': explanation}), turn_completed()]
            with self.assertRaises(RuntimeError) as error:
                self.generate(Path(tmp), events)
            self.assertIn('image safety system rejected', str(error.exception))
            self.assertIn('abc123-test', str(error.exception))
            self.assertNotIn('account or runtime', str(error.exception))

    def test_invalid_image_data_is_never_saved_as_source_png(self):
        with tempfile.TemporaryDirectory() as tmp:
            job=Path(tmp)
            invalid=base64.b64encode(b'Not an image' * 20).decode('ascii')
            events=[item_completed(image_item(result=invalid)),turn_completed()]
            with self.assertRaisesRegex(RuntimeError,'invalid PNG'):
                self.generate(job,events)
            self.assertFalse((job/'source.png').exists())

    def test_rpc_preserves_notifications_received_before_its_response(self):
        client = worker.Codex.__new__(worker.Codex)
        client.q = queue.Queue(); client.counter = 0; client.pending = collections.deque()
        client.send = Mock()
        notification = item_completed(image_item(savedPath='/example/generated.png'))
        client.q.put(notification)
        client.q.put({'id': 1, 'result': {'turn': {'id': TURN, 'status': 'inProgress'}}})
        response = client.call('turn/start', {'threadId': THREAD, 'input': []})
        self.assertEqual(response['turn']['id'], TURN)
        self.assertEqual(client.receive(timeout=0.01), notification)
        client.send.assert_called_once_with({'id': 1, 'method': 'turn/start', 'params': {'threadId': THREAD, 'input': []}})


if __name__ == '__main__':
    unittest.main()
