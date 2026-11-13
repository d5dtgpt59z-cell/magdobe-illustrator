"""User-owned image APIs. Standard-library transport; credentials are never persisted.

Schema references:
https://developers.openai.com/api/reference/resources/images/methods/generate
https://developers.openai.com/api/reference/resources/images/methods/edit
https://aistudio.google.com/docs/image-generation
https://aistudio.google.com/api-reference/generate-content
https://openrouter.ai/docs/guides/overview/multimodal/image-generation
https://platform.claude.com/docs/en/api/messages/create
"""
import base64
import binascii
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

MAX_IMAGE_BYTES = 50 * 1024 * 1024
MAX_REFERENCE_BYTES = 20 * 1024 * 1024
MAX_RESPONSE_BYTES = 80 * 1024 * 1024
MAX_PIXELS = 64_000_000
DEFAULTS = {
    'openai': ('gpt-image-2.5-flare', 'https://api.openai.com/v1'),
    'gemini': ('gemini-nano-banana-2.1', 'https://generativelanguage.googleapis.com/v1beta'),
    'openrouter': ('google/gemini-2.5-flash-image', 'https://openrouter.ai/api/v1'),
    'anthropic': ('claude-opus-5-5', 'https://api.anthropic.com/v1'),
}
NAMES = {'openai': 'OpenAI', 'gemini': 'Gemini', 'openrouter': 'OpenRouter',
         'compatible': 'Compatible provider', 'anthropic': 'Claude'}


class ProviderError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a provider credential to a location supplied by a server.
        return None


def _loopback(host):
    if host.lower() == 'localhost':
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_base_url(value):
    value = (value or '').strip().rstrip('/')
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError:
        raise ProviderError('Enter a valid provider API base URL.') from None
    if (not parsed.hostname or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or any(ord(c) < 32 for c in value)
            or '\\' in value or '..' in parsed.path.split('/')):
        raise ProviderError('Use a provider API base URL without credentials, query parameters, or fragments.')
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and _loopback(parsed.hostname)):
        raise ProviderError('Provider connections require HTTPS. HTTP is supported only for a local loopback server.')
    return value


def _configuration(provider, api_key, model, base_url):
    if provider not in NAMES:
        raise ProviderError('Choose a supported provider in Settings.')
    default_model, default_url = DEFAULTS.get(provider, ('', ''))
    base = validate_base_url(base_url or default_url)
    model = (model or default_model).strip()
    if not model or len(model) > 256 or any(ord(c) < 32 for c in model):
        raise ProviderError('Enter the provider model ID in Settings.')
    key = (api_key or '').strip()
    if len(key) > 8192 or any(ord(c) < 33 or ord(c) > 126 or c in '\"\\' for c in key):
        raise ProviderError('The API key contains invalid characters. Save it again in Settings.')
    if not key and not (provider == 'compatible' and _loopback(urllib.parse.urlsplit(base).hostname)):
        raise ProviderError('Add your own ' + NAMES[provider] + ' API key in Settings.')
    return model, base, key


def _headers(provider, key):
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json',
               'User-Agent': 'Magdobe-Illustrator'}
    if provider == 'gemini':
        headers['x-goog-api-key'] = key
    elif key:
        headers['Authorization'] = 'Bearer ' + key
    if provider == 'anthropic':
        headers['anthropic-version'] = '2026-10-21'
    return headers


def _redact(value, key, limit=1000):
    value = str(value)
    if key:
        value = value.replace(key, '[redacted]')
    # Handle common credential echoes without printing an entire HTTP response.
    value = re.sub(r'(?i)(authorization\s*[:=]\s*bearer\s+)\S+', r'\1[redacted]', value)
    return value[:limit]


def _open(request, timeout):
    return urllib.request.build_opener(_NoRedirect()).open(request, timeout=timeout)


def _read_response(response, limit):
    length = response.headers.get('Content-Length')
    if length:
        try:
            if int(length) > limit:
                raise ProviderError('The provider response is too large to import safely.')
        except ValueError:
            pass
    data = response.read(limit + 1)
    if len(data) > limit:
        raise ProviderError('The provider response is too large to import safely.')
    return data


def _request(url, headers, payload=None, timeout=180, key='', limit=MAX_RESPONSE_BYTES, content_type=None):
    if isinstance(payload, dict):
        payload = json.dumps(payload, separators=(',', ':')).encode('utf-8')
    headers = dict(headers)
    if content_type:
        headers['Content-Type'] = content_type
    request = urllib.request.Request(url, data=payload, headers=headers, method='POST' if payload is not None else 'GET')
    try:
        with _open(request, timeout) as response:
            return _read_response(response, limit)
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            raise ProviderError('The provider redirected this request. Use its final API base URL in Settings; credentials were not forwarded.') from None
        try:
            raw = error.read(65536)
            parsed = json.loads(raw)
            detail = parsed.get('error', parsed)
            if isinstance(detail, dict):
                message = detail.get('message') or detail.get('detail') or detail.get('code')
            else:
                message = detail
        except (ValueError, OSError, AttributeError):
            message = None
        if message is None:
            message = 'The provider rejected the request.'
        raise ProviderError('Provider HTTP ' + str(error.code) + ': ' + _redact(message, key)) from None
    except (urllib.error.URLError, TimeoutError, socket.timeout) as error:
        raise ProviderError('Could not reach the provider: ' + _redact(getattr(error, 'reason', error), key)) from None


def _json_request(url, headers, payload=None, timeout=180, key='', content_type=None):
    raw = _request(url, headers, payload, timeout, key, content_type=content_type)
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise ProviderError('The provider returned an unreadable JSON response. Check its API base URL.') from None
    if not isinstance(value, dict):
        raise ProviderError('The provider returned an unsupported response format.')
    if value.get('error'):
        error = value['error']
        detail = error.get('message', error.get('code', 'Request failed.')) if isinstance(error, dict) else error
        raise ProviderError(_redact(detail, key))
    return value


def _prompt(prompt):
    prompt = (prompt or '').strip()
    if not prompt:
        raise ProviderError('Describe the artwork you want to create.')
    if len(prompt) > 32000:
        raise ProviderError('Keep the artwork brief under 32,000 characters.')
    return prompt


def _reference(path):
    if not path:
        return None
    path = Path(path)
    if path.stat().st_size > MAX_REFERENCE_BYTES:
        raise ProviderError('Choose a reference image smaller than 20 MB.')
    data = path.read_bytes()
    mime = _image_type(data)
    if not mime:
        raise ProviderError('Choose a PNG, JPEG, or WebP reference image.')
    return data, mime


def _image_type(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'image/png'
    if data.startswith(b'\xff\xd8\xff'):
        return 'image/jpeg'
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        return 'image/webp'
    return None


def _decode_image(encoded):
    if not isinstance(encoded, str) or len(encoded) > (MAX_IMAGE_BYTES * 4 // 3 + 4096):
        raise ProviderError('The provider image data is missing or too large.')
    if encoded.startswith('data:'):
        if not re.match(r'^data:image/(png|jpeg|webp);base64,', encoded, re.IGNORECASE):
            raise ProviderError('The provider returned an unsupported image format. Choose a PNG, JPEG, or WebP image model.')
        encoded = encoded.split(',', 1)[1]
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ProviderError('The provider returned invalid base64 image data.') from None
    if len(data) > MAX_IMAGE_BYTES or not _image_type(data):
        raise ProviderError('The provider returned invalid or unsupported image data.')
    return data


def _download_image(url):
    try:
        parsed = urllib.parse.urlsplit(url)
    except (ValueError, TypeError):
        raise ProviderError('The provider returned an invalid image URL.') from None
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or _loopback(parsed.hostname)
            or any(ord(c) < 32 for c in url)):
        raise ProviderError('The provider image URL must use HTTPS without credentials.')
    # A generated image URL may be a signed CDN URL; do not send provider auth.
    return _request(url, {'Accept': 'image/png,image/jpeg,image/webp'}, timeout=90, limit=MAX_IMAGE_BYTES)


def _png_dimensions(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) < 45:
        raise ProviderError('The provider returned an invalid PNG image.')
    offset = 8
    dimensions = None
    found_end = False
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ProviderError('The provider returned a truncated PNG image.')
        body = data[offset + 8:offset + 8 + length]
        crc = struct.unpack('>I', data[offset + 8 + length:end])[0]
        if zlib.crc32(kind + body) & 0xffffffff != crc:
            raise ProviderError('The provider returned a damaged PNG image.')
        if dimensions is None:
            if kind != b'IHDR' or length != 13:
                raise ProviderError('The provider returned an invalid PNG image header.')
            dimensions = struct.unpack('>II', body[:8])
        if kind == b'IEND':
            found_end = True
            break
        offset = end
    if not found_end or not dimensions or min(dimensions) <= 0:
        raise ProviderError('The provider returned an incomplete PNG image.')
    if dimensions[0] * dimensions[1] > MAX_PIXELS:
        raise ProviderError('The generated image exceeds the 64-million-pixel import limit.')
    return dimensions


def _save_image(data, job):
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ProviderError('The provider image is empty or larger than 50 MB.')
    job = Path(job)
    job.mkdir(parents=True, exist_ok=True)
    target = job / 'source.png'
    temporary = job / ('.provider-' + uuid.uuid4().hex + '.png')
    original = None
    try:
        mime = _image_type(data)
        if mime == 'image/png':
            _png_dimensions(data)
            temporary.write_bytes(data)
        elif mime in ('image/jpeg', 'image/webp'):
            if sys.platform != 'darwin' or not Path('/usr/bin/sips').is_file():
                raise ProviderError('Converting this provider image to PNG requires macOS. Choose PNG output from the provider.')
            original = job / ('.provider-' + uuid.uuid4().hex + ('.jpg' if mime == 'image/jpeg' else '.webp'))
            original.write_bytes(data)
            info = subprocess.run(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(original)], capture_output=True, text=True, timeout=30)
            sizes = re.findall(r'pixel(?:Width|Height):\s*(\d+)', info.stdout)
            if info.returncode or len(sizes) != 2 or min(map(int, sizes)) <= 0 or int(sizes[0]) * int(sizes[1]) > MAX_PIXELS:
                raise ProviderError('The provider image is unreadable or exceeds the 64-million-pixel import limit.')
            converted = subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(original), '--out', str(temporary)], capture_output=True, timeout=60)
            if converted.returncode or not temporary.is_file() or temporary.stat().st_size > MAX_IMAGE_BYTES:
                raise ProviderError('The provider image could not be converted into PNG.')
            _png_dimensions(temporary.read_bytes())
        else:
            raise ProviderError('The provider returned an unsupported image format. Choose a PNG, JPEG, or WebP image model.')
        os.replace(temporary, target)
        return target
    finally:
        temporary.unlink(missing_ok=True)
        if original:
            original.unlink(missing_ok=True)


def _multipart(fields, reference):
    boundary = 'Magdobe' + uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"\r\n\r\n' + str(value) + '\r\n').encode())
    data, mime = reference
    suffix = {'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp'}[mime]
    parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="image"; filename="reference.' + suffix + '"\r\nContent-Type: ' + mime + '\r\n\r\n').encode() + data + b'\r\n')
    parts.append(('--' + boundary + '--\r\n').encode())
    return b''.join(parts), 'multipart/form-data; boundary=' + boundary


def _first_image(response, provider):
    # OpenAI Images, OpenRouter Images, and compatible image endpoints.
    for item in response.get('data') or []:
        if not isinstance(item, dict):
            continue
        if item.get('b64_json'):
            return _decode_image(item['b64_json'])
        if item.get('url'):
            return _download_image(item['url'])
    # Current Gemini Interactions API.
    interaction = response.get('interaction', response)
    if not isinstance(interaction, dict): interaction = {}
    image = interaction.get('output_image') or interaction.get('outputImage')
    if isinstance(image, dict) and image.get('data'):
        return _decode_image(image['data'])
    for output in interaction.get('outputs') or []:
        if isinstance(output, dict) and output.get('type') == 'image' and output.get('data'):
            return _decode_image(output['data'])
    # Older Gemini GenerateContent models.
    for candidate in response.get('candidates') or []:
        if not isinstance(candidate, dict): continue
        content = candidate.get('content') or {}
        if not isinstance(content, dict): continue
        for part in content.get('parts') or []:
            if not isinstance(part, dict): continue
            image = part.get('inlineData') or part.get('inline_data')
            if isinstance(image, dict) and image.get('data'):
                return _decode_image(image['data'])
    # Legacy OpenRouter chat/image response compatibility.
    for choice in response.get('choices') or []:
        if not isinstance(choice, dict): continue
        message = choice.get('message') or {}
        if not isinstance(message, dict): continue
        for image in message.get('images') or []:
            if not isinstance(image, dict): continue
            value = image.get('image_url', {}).get('url') if isinstance(image.get('image_url'), dict) else image.get('url')
            if value:
                if not isinstance(value, str): raise ProviderError('The provider returned an invalid image URL.')
                return _decode_image(value) if value.startswith('data:') else _download_image(value)
    feedback = response.get('promptFeedback') or response.get('prompt_feedback') or {}
    if isinstance(feedback, dict) and (feedback.get('blockReason') or feedback.get('block_reason')):
        raise ProviderError(NAMES[provider] + ' rejected this image request through its safety system. Try a different brief.')
    raise ProviderError(NAMES[provider] + ' returned no image. Check that the selected model supports image output and that the request was accepted.')


def generate_image(provider, prompt, job, api_key, model, base_url, reference=None, format='square'):
    if provider == 'anthropic':
        raise ProviderError('Claude refines artwork briefs. Choose an image provider to generate an illustration.')
    model, base, key = _configuration(provider, api_key, model, base_url)
    prompt = _prompt(prompt)
    reference = _reference(reference)
    headers = _headers(provider, key)
    ratio = {'square': '1:1', 'portrait': '2:3', 'landscape': '3:2'}.get(str(format).lower(), '1:1')
    size = {'square': '1024x1024', 'portrait': '1024x1536', 'landscape': '1536x1024'}.get(str(format).lower(), '1024x1024')
    if provider in ('openai', 'compatible'):
        payload = {'model': model, 'prompt': prompt, 'n': 1, 'size': size}
        if provider == 'openai':
            payload['output_format'] = 'png'
        else:
            payload['response_format'] = 'b64_json'
        if reference:
            body, content_type = _multipart(payload, reference)
            response = _json_request(base + '/images/edits', headers, body, timeout=600, key=key, content_type=content_type)
        else:
            response = _json_request(base + '/images/generations', headers, payload, timeout=600, key=key)
    elif provider == 'gemini':
        if model.startswith('gemini-nano-banana-'):
            inputs = [{'type': 'text', 'text': prompt}]
            if reference:
                inputs.append({'type': 'image', 'mime_type': reference[1], 'data': base64.b64encode(reference[0]).decode('ascii')})
            headers['Api-Revision'] = '2026-05-20'
            payload = {'model': model, 'input': inputs, 'response_format': {'type': 'image', 'aspect_ratio': ratio}}
            response = _json_request(base + '/interactions', headers, payload, timeout=600, key=key)
        else:
            parts = [{'text': prompt}]
            if reference:
                parts.append({'inlineData': {'mimeType': reference[1], 'data': base64.b64encode(reference[0]).decode('ascii')}})
            payload = {'contents': [{'role': 'user', 'parts': parts}], 'generationConfig': {'responseModalities': ['TEXT', 'IMAGE'], 'imageConfig': {'aspectRatio': ratio}}}
            model_path = urllib.parse.quote(model.removeprefix('models/'), safe='')
            response = _json_request(base + '/models/' + model_path + ':generateContent', headers, payload, timeout=600, key=key)
    elif provider == 'openrouter':
        payload = {'model': model, 'prompt': prompt, 'aspect_ratio': ratio, 'output_format': 'png'}
        if reference:
            uri = 'data:' + reference[1] + ';base64,' + base64.b64encode(reference[0]).decode('ascii')
            payload['input_references'] = [{'type': 'image_url', 'image_url': {'url': uri}}]
        response = _json_request(base + '/images', headers, payload, timeout=600, key=key)
    else:
        raise ProviderError('Choose a supported image provider in Settings.')
    return _save_image(_first_image(response, provider), job)


def check_connection(provider, api_key, model, base_url):
    model, base, key = _configuration(provider, api_key, model, base_url)
    headers = _headers(provider, key)
    if provider == 'openrouter':
        path = '/key'
    elif provider == 'gemini':
        path = '/models?pageSize=1'
    elif provider == 'anthropic':
        path = '/models?limit=1'
    else:
        path = '/models'
    _json_request(base + path, headers, timeout=30, key=key)
    return NAMES[provider] + ' API connection accepted. Image or model access is checked when you generate.'


def improve_prompt(provider, prompt, api_key, model, base_url):
    if provider != 'anthropic':
        raise ProviderError('Choose Claude as the prompt assistant in Settings.')
    model, base, key = _configuration(provider, api_key, model, base_url)
    prompt = _prompt(prompt)
    payload = {
        'model': model, 'max_tokens': 1200,
        'system': 'Refine the user artwork brief for an image-generation tool. Preserve the requested subject, characters, exact text, style, and composition. Do not add unrelated subjects or invent new requirements. Return only one polished image brief, without explanations or Markdown. If the brief is already specific, make only small clarity improvements.',
        'messages': [{'role': 'user', 'content': prompt}],
    }
    result = _json_request(base + '/messages', _headers(provider, key), payload, timeout=180, key=key)
    if result.get('stop_reason') == 'refusal' or (result.get('stop_details') or {}).get('type') == 'refusal':
        raise ProviderError('Claude declined this brief. Your original prompt has been kept.')
    text = '\n'.join(item.get('text', '') for item in result.get('content', []) if isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str)).strip()
    if not text:
        raise ProviderError('Claude returned no prompt suggestion. Your original prompt has been kept.')
    if len(text) > 32000:
        raise ProviderError('Claude’s suggestion was too long. Your original prompt has been kept.')
    return _redact(text, key, limit=32000)
