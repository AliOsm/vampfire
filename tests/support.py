"""Small HTTP/WebSocket test clients, with no third-party runtime dependencies."""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import shutil
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PASSWORD = 'Test-password-2026!'


class Client:
    def __init__(self, port):
        self.port, self.cookie, self.csrf = port, '', ''
        self.user = {}

    def request(self, method, path, body=None, expected=200, headers=None):
        h = {'Origin': f'http://127.0.0.1:{self.port}', 'Cookie': self.cookie,
             'X-CSRF-Token': self.csrf}
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            h['Content-Type'] = 'application/json'
        h.update(headers or {})
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        try:
            connection.request(method, path, body, h)
            response = connection.getresponse()
            data = response.read()
            response_headers = dict(response.getheaders())
            content_type = response.getheader('Content-Type', '')
            if response.getheader('Content-Encoding') == 'gzip':
                import gzip
                data = gzip.decompress(data)
            result = json.loads(data) if data and 'application/json' in content_type else data
            if response.status != expected:
                raise AssertionError(f'{method} {path}: expected {expected}, got {response.status}: {str(result)[:800]}')
            cookie = response.getheader('Set-Cookie')
            if cookie:
                self.cookie = cookie.split(';')[0]
            if isinstance(result, dict) and result.get('csrf'):
                self.csrf, self.user = result['csrf'], result['user']
            return result, response_headers
        finally:
            connection.close()

    def get(self, path, **kwargs):
        return self.request('GET', path, **kwargs)[0]

    def post(self, path, body=None, **kwargs):
        return self.request('POST', path, body, **kwargs)[0]

    def patch(self, path, body=None, **kwargs):
        return self.request('PATCH', path, body, **kwargs)[0]

    def delete(self, path, body=None, **kwargs):
        return self.request('DELETE', path, body, **kwargs)[0]

    def upload(self, name, contents, mime='application/octet-stream', path='/api/uploads', field='file'):
        boundary = 'vampfire-test-boundary'
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{name}"\r\n'
                f'Content-Type: {mime}\r\n\r\n').encode() + contents + f'\r\n--{boundary}--\r\n'.encode()
        return self.post(path, body, expected=201, headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})

    def message(self, room, text, **kwargs):
        return self.post(f'/api/rooms/{room}/messages', {'body': text, **kwargs}, expected=201)

    def room(self, name='Test room', kind='closed', members=None):
        return self.post('/api/rooms', {'name': name, 'kind': kind, 'members': members or []}, expected=201)

    def socket(self):
        return WebSocket(self)


class WebSocket:
    def __init__(self, client):
        self.sock = socket.create_connection(('127.0.0.1', client.port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{client.port}\r\n'
                           f'Origin: http://127.0.0.1:{client.port}\r\nCookie: {client.cookie}\r\n'
                           f'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                           f'Sec-WebSocket-Key: {key}\r\n\r\n').encode())
        response = bytearray()
        while not response.endswith(b'\r\n\r\n'):
            response.extend(self.exact(1))
        assert response.startswith(b'HTTP/1.1 101'), response
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert accept in response

    def exact(self, length):
        result = bytearray()
        while len(result) < length:
            chunk = self.sock.recv(length - len(result))
            if not chunk:
                raise EOFError('WebSocket closed')
            result.extend(chunk)
        return bytes(result)

    def send(self, data, opcode=1):
        payload = json.dumps(data).encode() if isinstance(data, dict) else data
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode, 0x80 | length]) if length < 126 else bytes([0x80 | opcode, 0xfe]) + struct.pack('!H', length)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self):
        first, second = self.exact(2)
        size = second & 127
        if size == 126:
            size = struct.unpack('!H', self.exact(2))[0]
        elif size == 127:
            size = struct.unpack('!Q', self.exact(8))[0]
        assert size < 2 * 1024 * 1024
        data = self.exact(size)
        opcode = first & 15
        if opcode == 8:
            return {'kind': 'closed', 'code': struct.unpack('!H', data[:2])[0] if len(data) >= 2 else 1005}
        if opcode == 9:
            self.send(data, opcode=10)
            return self.receive()
        return json.loads(data)

    def until(self, kind, predicate=lambda data: True, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.sock.settimeout(max(.01, deadline - time.monotonic()))
            event = self.receive()
            if event['kind'] == kind and predicate(event):
                return event
        raise AssertionError(f'No {kind} event')

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class Server:
    def __init__(self, seed=None, environment=None):
        self.directory = tempfile.TemporaryDirectory(prefix='vampfire-test-')
        self.data = Path(self.directory.name)
        if seed:
            shutil.copytree(seed, self.data, dirs_exist_ok=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.log_path = ROOT / '.build' / f'test-server-{self.port}.log'
        self.log = self.log_path.open('w')
        env = {**os.environ, 'PORT': str(self.port), 'BIND': '127.0.0.1',
               'BASE_URL': f'http://127.0.0.1:{self.port}', 'VAMPFIRE_DATA': str(self.data),
               'VAPID_PUBLIC_KEY': '', 'VAPID_PRIVATE_KEY': ''}
        env.update(environment or {})
        self.process = subprocess.Popen([ROOT / '.build/vampfire'], cwd=ROOT, env=env, stdout=self.log, stderr=self.log)
        for _ in range(100):
            if self.process.poll() is not None:
                self.close()
                raise RuntimeError(f'App exited; see {self.log_path}')
            try:
                Client(self.port).get('/up')
                break
            except OSError:
                time.sleep(.05)
        else:
            self.close()
            raise RuntimeError('App did not start')

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.log.close()
        self.directory.cleanup()
