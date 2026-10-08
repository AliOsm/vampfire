"""Behavior tests against a real isolated V HTTP/WebSocket process and SQLite store."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import queue
import sqlite3
import struct
import subprocess
import tempfile
from pathlib import Path
import sys
import threading
import time
import unittest
import zlib
from support import Client, PASSWORD, Server
from support import ROOT
sys.path.insert(0, str(ROOT / 'scripts'))
from backup import backup


class Parity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = Server()
        cls.admin = Client(cls.server.port)
        assert cls.admin.get('/api/bootstrap')['setup']
        cls.admin.post('/api/setup', {'name': 'Alex Admin', 'email': 'alex@example.test', 'password': PASSWORD, 'account_name': 'Test workspace'}, expected=201)
        cls.code = cls.admin.get('/api/account')['account']['join_code']
        cls.bob = cls.join('Bob Member', 'bob@example.test')
        cls.cara = cls.join('Cara Member', 'cara@example.test')

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    @classmethod
    def join(cls, name, email):
        client = Client(cls.server.port)
        client.post('/api/join', {'name': name, 'email': email, 'password': PASSWORD, 'join_code': cls.code}, expected=201)
        return client

    def test_setup_and_auth_boundaries(self):
        visitor = Client(self.server.port)
        visitor.get('/api/rooms', expected=401)
        self.admin.post('/api/setup', {'name': 'Other', 'email': 'other@example.test', 'password': PASSWORD}, expected=409)
        visitor.post('/api/session', {'email': 'alex@example.test', 'password': 'incorrect'}, expected=401)
        visitor.post('/api/session', {'email': 'ALEX@example.test', 'password': PASSWORD})
        self.assertEqual(visitor.user['id'], self.admin.user['id'])
        visitor.post('/api/rooms', {'kind': 'open', 'name': 'No CSRF'}, headers={'X-CSRF-Token': ''}, expected=403)
        visitor.post('/api/rooms', {'kind': 'open', 'name': 'Bad origin'}, headers={'Origin': 'https://attacker.test'}, expected=403)
        visitor.get('/ws', expected=400)
        visitor.delete('/api/session')
        visitor.get('/api/rooms', expected=401)

    def test_open_and_private_membership(self):
        room = self.bob.room(kind='open')
        self.assertIn(room['id'], [r['id'] for r in self.cara.get('/api/rooms')])
        self.cara.patch(f'/api/rooms/{room["id"]}', {'name': 'Changed', 'kind': 'open'}, expected=403)
        secret = self.admin.room('Secret', members=[self.bob.user['id']])
        self.admin.message(secret['id'], 'private quartz conversation')
        self.cara.get(f'/api/rooms/{secret["id"]}/messages', expected=404)
        self.assertFalse(self.cara.get('/api/search?q=quartz')['messages'])
        with self.bob.socket() as socket:
            socket.send({'type': 'subscribe', 'room_id': secret['id']})
            socket.until('presence')
            self.admin.patch(f'/api/rooms/{secret["id"]}', {'name': 'Secret', 'kind': 'closed', 'members': [self.admin.user['id']]})
            socket.until('closed')
        self.bob.get(f'/api/rooms/{secret["id"]}/messages', expected=404)
        self.admin.patch(f'/api/rooms/{secret["id"]}', {'name': 'Public now', 'kind': 'open'})
        self.assertEqual(len(self.cara.get(f'/api/rooms/{secret["id"]}/messages')), 1)
        self.bob.delete(f'/api/rooms/{secret["id"]}', expected=403)
        self.admin.delete(f'/api/rooms/{secret["id"]}')
        self.admin.get(f'/api/rooms/{secret["id"]}/messages', expected=404)

    def test_room_creator_can_remove_themselves(self):
        room = self.admin.room('Leaving', members=[self.bob.user['id']])
        self.admin.patch(f'/api/rooms/{room["id"]}', {'name': 'Leaving', 'kind': 'closed', 'members': [self.bob.user['id']]})
        self.admin.get(f'/api/rooms/{room["id"]}/messages', expected=404)
        self.assertEqual(self.bob.get(f'/api/rooms/{room["id"]}/messages'), [])

    def test_directory_pagination(self):
        with closing(sqlite3.connect(self.server.data / 'vampfire.sqlite3')) as db:
            db.executemany('INSERT INTO users(name,created_at) VALUES(?,0)', [(f'Crowd person {i:04}',) for i in range(505)])
            db.commit()
        try:
            first = self.bob.get('/api/users?q=Crowd&page=0')
            second = self.bob.get('/api/users?q=Crowd&page=1')
            self.assertEqual((len(first), len(second)), (500, 5))
            self.assertFalse({u['id'] for u in first} & {u['id'] for u in second})
        finally:
            with closing(sqlite3.connect(self.server.data / 'vampfire.sqlite3')) as db:
                db.execute("DELETE FROM users WHERE name LIKE 'Crowd person %'")
                db.commit()

    def test_direct_singleton_and_immutability(self):
        room = self.bob.room(kind='direct', members=[self.cara.user['id']])
        same = self.cara.post('/api/rooms', {'kind': 'direct', 'members': [self.bob.user['id']]})
        self.assertEqual(room['id'], same['id'])
        self.admin.get(f'/api/rooms/{room["id"]}/messages', expected=404)
        self.bob.patch(f'/api/rooms/{room["id"]}', {'kind': 'open', 'name': 'Oops'}, expected=422)
        self.cara.delete(f'/api/rooms/{room["id"]}')

    def test_rich_text_and_xss(self):
        room = self.bob.room()
        source = 'Before <strong>bold &amp; nice</strong> after<br><em>next</em>'
        message = self.bob.message(room['id'], source)
        self.assertEqual(message['plain'], 'Before bold & nice after\nnext')
        for payload in [
            '<p onclick="alert(1)">safe<script>alert(1)</script></p>',
            '<svg onload="alert(1)"></svg><p>safe</p>',
            '<a href="jav&#x61;script:alert(1)">safe</a>',
            '<img src=x onerror=alert(1)>safe',
            '<math><mtext><table><mglyph><style><!--</style><img title="--><img src=1 onerror=alert(1)>">safe',
            '<a href="https://example.test/\" onmouseover=\"alert(1)">safe</a>',
        ]:
            with self.subTest(payload=payload):
                cleaned = self.bob.message(room['id'], payload)['body']
                self.assertNotIn('<script', cleaned)
                self.assertNotIn('<img', cleaned)
                self.assertNotIn('<svg', cleaned)
                self.assertNotIn(' onclick=', cleaned)
                self.assertNotIn(' onerror=', cleaned)
                self.assertNotIn(' onmouseover=', cleaned)
                self.assertNotIn('href="javascript:', cleaned)
        self.bob.message(room['id'], '<span data-mention="1">@Alex</span> hi')
        self.bob.post(f'/api/rooms/{room["id"]}/messages', {'body': '<script>bad()</script>'}, expected=422)
        canonical = self.bob.message(room['id'], f'<span data-mention="{self.bob.user["id"]}">@Wrong name</span> hello')
        self.assertEqual(canonical['plain'], '@Bob Member hello')
        entities = self.bob.message(room['id'], 'A&nbsp;B &mdash; &#x1f680; &#128640; &amp;lt; & plain &')
        self.assertEqual(entities['plain'], 'A\u00a0B — 🚀 🚀 &lt; & plain &')
        code = self.bob.message(room['id'], '<pre data-language="rust" onclick="bad()"><code>fn main() { println!("hello"); }</code></pre><p><u>underlined</u> <mark>highlight</mark></p><table><tr><th>Heading</th></tr><tr><td>Cell</td></tr></table>')
        self.assertIn('data-language="rust"', code['body'])
        self.assertNotIn('onclick', code['body'])
        self.assertIn('<table>', code['body'])
        self.assertIn('<mark>highlight</mark>', code['body'])

    def test_messages_edits_replies_boosts_and_search(self):
        room = self.bob.room(kind='open')
        message = self.bob.message(room['id'], '<p>salt AND pepper</p>', client_id='idempotency-test')
        repeat = self.bob.message(room['id'], '<p>salt AND pepper</p>', client_id='idempotency-test')
        self.assertEqual(message['id'], repeat['id'])
        self.assertEqual(len(self.bob.get(f'/api/rooms/{room["id"]}/messages')), 1)
        self.assertIn(message['id'], [m['id'] for m in self.bob.get('/api/search?q=AND')['messages']])
        self.cara.patch(f'/api/messages/{message["id"]}', {'body': 'hijack'}, expected=403)
        self.bob.patch(f'/api/messages/{message["id"]}', {'body': 'edited-juniper'})
        self.assertIn(message['id'], [m['id'] for m in self.bob.get('/api/search?q=juniper')['messages']])
        reply = self.cara.message(room['id'], 'A reply', reply_id=message['id'])
        boosted = self.cara.post(f'/api/messages/{message["id"]}/boosts', {'content': 'Great! 🙌'}, expected=201)
        boost = boosted['boosts'][0]
        self.bob.delete(f'/api/boosts/{boost["id"]}', expected=404)
        self.cara.delete(f'/api/boosts/{boost["id"]}')
        self.cara.delete(f'/api/messages/{message["id"]}', expected=403)
        self.admin.delete(f'/api/messages/{message["id"]}')
        self.assertFalse(self.bob.get('/api/search?q=juniper')['messages'])
        self.assertEqual(self.bob.get(f'/api/rooms/{room["id"]}/messages')[0]['reply_id'], 0)
        self.assertGreater(reply['id'], message['id'])

    def test_pagination(self):
        room = self.admin.room()
        messages = [self.admin.message(room['id'], f'page {i}') for i in range(85)]
        latest = self.admin.get(f'/api/rooms/{room["id"]}/messages')
        self.assertEqual([m['id'] for m in latest], [m['id'] for m in messages[-40:]])
        earlier = self.admin.get(f'/api/rooms/{room["id"]}/messages?before={latest[0]["id"]}')
        self.assertEqual(len(earlier), 40)
        around = self.admin.get(f'/api/rooms/{room["id"]}/messages?around={messages[42]["id"]}')
        self.assertEqual(len(around), 81)
        after = self.admin.get(f'/api/rooms/{room["id"]}/messages?after={messages[0]["id"]}')
        self.assertEqual(len(after), 40)
        self.assertEqual(after[0]['id'], messages[1]['id'])
        matches = self.admin.get(f'/api/search?q=page&room={room["id"]}')['messages']
        self.assertEqual(len(matches), 40)
        more = self.admin.get(f'/api/search?q=page&room={room["id"]}&before={matches[-1]["id"]}')['messages']
        self.assertEqual(len(more), 40)
        self.assertFalse({m['id'] for m in matches} & {m['id'] for m in more})

    def test_backup_restore(self):
        upload = self.admin.upload('backup.txt', b'Keep this data')
        room = self.admin.room('Restorable')
        message = self.admin.message(room['id'], 'Restorable message', upload_id=upload['id'])
        destination = backup(self.server.data, self.server.data / 'test-backup')
        restored = Server(seed=destination)
        try:
            client = Client(restored.port)
            client.post('/api/session', {'email': 'alex@example.test', 'password': PASSWORD})
            self.assertEqual(client.get(f'/uploads/{upload["id"]}'), b'Keep this data')
            self.assertEqual(client.get(f'/api/rooms/{room["id"]}/messages')[0]['id'], message['id'])
        finally:
            restored.close()

    def test_realtime_typing_edits_and_unread(self):
        room = self.bob.room(members=[self.cara.user['id']])
        with self.bob.socket() as bob, self.cara.socket() as cara:
            for sock in [bob, cara]:
                sock.send({'type': 'subscribe', 'room_id': room['id']})
            cara.until('presence', lambda e: len(e['users']) == 2)
            bob.send({'type': 'typing'})
            self.assertEqual(cara.until('typing')['user_id'], self.bob.user['id'])
            sent = self.bob.message(room['id'], 'Delivered over WebSocket')
            self.assertEqual(cara.until('message')['message']['body'], sent['body'])
            self.assertEqual(next(r for r in self.cara.get('/api/rooms') if r['id'] == room['id'])['unread'], 1)
            self.cara.post(f'/api/rooms/{room["id"]}/read')
            cara.until('read')
            self.bob.patch(f'/api/messages/{sent["id"]}', {'body': 'Updated live'})
            self.assertEqual(cara.until('message_updated')['message']['plain'], 'Updated live')
            self.bob.delete(f'/api/messages/{sent["id"]}')
            self.assertEqual(cara.until('message_deleted')['message_id'], sent['id'])

    def test_involvement(self):
        room = self.bob.room()
        for involvement in ['invisible', 'nothing', 'mentions', 'everything']:
            self.bob.patch(f'/api/rooms/{room["id"]}/involvement', {'involvement': involvement})
            self.assertEqual(next(r for r in self.bob.get('/api/rooms') if r['id'] == room['id'])['involvement'], involvement)
        self.bob.patch(f'/api/rooms/{room["id"]}/involvement', {'involvement': 'nope'}, expected=422)

    def test_upload_permissions_ranges_and_mime(self):
        room = self.bob.room(members=[self.cara.user['id']])
        uploaded = self.bob.upload('notes.txt', b'0123456789', 'text/html')
        self.assertEqual(uploaded['mime'], 'application/octet-stream')
        self.cara.get(f'/uploads/{uploaded["id"]}', expected=404)
        self.bob.message(room['id'], '', upload_id=uploaded['id'])
        self.assertEqual(self.cara.get(f'/uploads/{uploaded["id"]}'), b'0123456789')
        data, headers = self.cara.request('GET', f'/uploads/{uploaded["id"]}', headers={'Range': 'bytes=2-5'}, expected=206)
        self.assertEqual(data, b'2345')
        self.assertEqual(headers['Content-Range'], 'bytes 2-5/10')
        self.assertEqual(self.cara.get(f'/uploads/{uploaded["id"]}', headers={'Range': 'bytes=-3'}, expected=206), b'789')
        self.cara.get(f'/uploads/{uploaded["id"]}', headers={'Range': 'bytes=100-'}, expected=416)
        self.cara.get(f'/uploads/{uploaded["id"]}', headers={'Range': 'bytes=oops-2'}, expected=416)
        self.cara.post(f'/api/rooms/{room["id"]}/messages', {'upload_id': uploaded['id']}, expected=422)
        self.admin.get(f'/uploads/{uploaded["id"]}', expected=404)

    def test_media_thumbnail_and_avatar(self):
        def chunk(kind, data):
            return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
        png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 32, 32, 8, 2, 0, 0, 0))
        png += chunk(b'IDAT', zlib.compress((b'\x00' + b'\xc8\x68\x40' * 32) * 32)) + chunk(b'IEND', b'')
        uploaded = self.bob.upload('avatar.png', png, 'image/png')
        room = self.bob.room(members=[self.cara.user['id']])
        self.bob.message(room['id'], '', upload_id=uploaded['id'])
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            attachment = self.bob.get(f'/api/rooms/{room["id"]}/messages')[0]['attachment']
            if attachment['thumb']:
                break
            with closing(sqlite3.connect(self.server.data / 'vampfire.sqlite3')) as connection:
                failures = connection.execute("SELECT error FROM jobs WHERE kind='media' AND payload=? AND error<>''", (str(uploaded['id']),)).fetchall()
                self.assertFalse(failures, str(failures))
            time.sleep(.1)
        self.assertEqual(attachment['width'], 32)
        self.assertEqual(attachment['height'], 32)
        self.assertTrue(attachment['thumb'])
        image = self.cara.get(f'/uploads/{uploaded["id"]}?thumb=1')
        self.assertTrue(image.startswith(b'\xff\xd8\xff'))
        self.bob.patch('/api/profile', {'name': 'Bob Member', 'email': 'bob@example.test', 'avatar_id': uploaded['id']})
        self.assertTrue(self.cara.get(f'/avatar/{self.bob.user["id"]}').startswith(b'\xff\xd8\xff'))

    def test_audio_and_video_processing(self):
        room = self.bob.room(members=[self.cara.user['id']])
        video = self.server.data / 'test-video.mp4'
        environment = {**os.environ, 'OPENBLAS_NUM_THREADS': '1', 'OMP_NUM_THREADS': '1', 'MALLOC_ARENA_MAX': '2'}
        subprocess.run(['prlimit', '--as=536870912', '--stack=2097152', '--cpu=10', '--', 'ffmpeg',
                        '-nostdin', '-v', 'error', '-threads', '1', '-filter_threads', '1',
                        '-f', 'lavfi', '-i', 'color=c=0xC86840:s=64x48:r=10:d=0.4',
                        '-c:v', 'libx264', '-threads', '1', '-pix_fmt', 'yuv420p', str(video)],
                       env=environment, check=True, timeout=15)
        audio = ROOT / 'public/sounds/bell.mp3'
        for path, mime in [(video, 'video/mp4'), (audio, 'audio/mpeg')]:
            with self.subTest(mime=mime):
                uploaded = self.bob.upload(path.name, path.read_bytes(), mime)
                self.assertEqual(uploaded['mime'], mime)
                message = self.bob.message(room['id'], '', upload_id=uploaded['id'])
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    attachment = next(m['attachment'] for m in self.bob.get(f'/api/rooms/{room["id"]}/messages') if m['id'] == message['id'])
                    if attachment['duration'] > 0 and (mime.startswith('audio') or attachment['thumb']):
                        break
                    time.sleep(.1)
                self.assertGreater(attachment['duration'], 0)
                if mime.startswith('video'):
                    self.assertEqual((attachment['width'], attachment['height']), (64, 48))
                    self.assertTrue(self.cara.get(f'/uploads/{uploaded["id"]}?thumb=1').startswith(b'\xff\xd8\xff'))

    def test_realtime_presence_disconnect_and_directory(self):
        room = self.bob.room(members=[self.cara.user['id']])
        with self.bob.socket() as bob:
            cara = self.cara.socket()
            try:
                for sock in [bob, cara]:
                    sock.send({'type': 'subscribe', 'room_id': room['id']})
                bob.until('presence', lambda event: len(event['users']) == 2)
            finally:
                cara.close()
            bob.until('presence', lambda event: event['users'] == [self.bob.user['id']])
            self.admin.post('/api/bots', {'name': 'Directory Bot'}, expected=201)
            bob.until('users')

    def test_transfer_and_session_revocation(self):
        token = self.bob.post('/api/transfers')['token']
        device = Client(self.server.port)
        device.post('/api/transfers/redeem', {'token': token})
        self.assertEqual(device.user['id'], self.bob.user['id'])
        Client(self.server.port).post('/api/transfers/redeem', {'token': token}, expected=400)
        session = next(s for s in device.get('/api/sessions') if s['current'])
        with device.socket() as socket:
            self.bob.delete('/api/sessions', {'token': session['token']})
            socket.until('closed')
        device.get('/api/rooms', expected=401)

    def test_profile_and_admin_permissions(self):
        updated = self.bob.patch('/api/profile', {'name': 'Bob Member', 'email': 'bob@example.test', 'bio': 'Testing together'})
        self.assertEqual(updated['bio'], 'Testing together')
        self.bob.patch('/api/account', {'name': 'Hijack'}, expected=403)
        self.bob.get('/api/bots', expected=403)
        self.bob.patch(f'/api/users/{self.cara.user["id"]}', {'action': 'role', 'role': 'administrator'}, expected=403)
        self.admin.patch('/api/account', {'name': 'Test workspace', 'restrict_rooms': True, 'custom_css': ':root { --test: 1; }'})
        self.bob.post('/api/rooms', {'name': 'No', 'kind': 'open'}, expected=403)
        self.assertIn(b'--test: 1', self.bob.get('/custom.css'))
        self.admin.patch('/api/account', {'name': 'Test workspace', 'restrict_rooms': False})

    def test_shared_administration_preserves_existing_images(self):
        image = self.admin.upload('workspace.png', (ROOT / 'public/app-icon-192.png').read_bytes(), 'image/png')
        self.admin.patch('/api/account', {'name': 'Test workspace', 'logo_id': image['id']})
        bot = self.admin.post('/api/bots', {'name': 'Shared admin bot', 'avatar_id': image['id']}, expected=201)
        self.admin.patch(f'/api/users/{self.bob.user["id"]}', {'action': 'role', 'role': 'administrator'})
        try:
            self.bob.patch('/api/account', {'name': 'Test workspace', 'logo_id': image['id']})
            changed = self.bob.patch(f'/api/bots/{bot["user"]["id"]}', {'name': 'Renamed by another admin', 'avatar_id': image['id']})
            self.assertEqual(changed['user']['avatar_id'], image['id'])
        finally:
            self.admin.patch(f'/api/users/{self.bob.user["id"]}', {'action': 'role', 'role': 'member'})
            self.admin.patch('/api/account', {'name': 'Test workspace', 'logo_id': 0})

    def test_search_history(self):
        for i in range(12):
            self.bob.post('/api/search', {'query': f'query-{i}'})
        self.assertEqual(len(self.bob.get('/api/search')['recent']), 10)
        self.bob.delete('/api/search')
        self.assertEqual(self.bob.get('/api/search')['recent'], [])

    def test_bot_api(self):
        bot = self.admin.post('/api/bots', {'name': 'Build Bot'}, expected=201)
        room = self.admin.room(kind='closed', members=[bot['user']['id']])
        client = Client(self.server.port)
        path = f'/api/bot/{bot["key"]}/rooms/{room["id"]}/messages'
        sent = client.post(path, b'<p>Build succeeded</p>', expected=201, headers={'Content-Type': 'text/html'})
        self.assertEqual(sent['user_id'], bot['user']['id'])
        self.assertEqual(len(client.get(path)), 1)
        edited = client.patch(path + '/' + str(sent['id']), b'Build <passed>', headers={'Content-Type': 'text/plain'})
        self.assertEqual(edited['plain'], 'Build <passed>')
        boosted = client.post(path + '/' + str(sent['id']) + '/boosts', b'Nice', expected=201, headers={'Content-Type': 'text/plain'})
        client.delete(path + f'/{sent["id"]}/boosts/{boosted["boosts"][0]["id"]}')
        client.delete(path + '/' + str(sent['id']))
        self.admin.patch(f'/api/bots/{bot["user"]["id"]}', {'action': 'rotate'})
        client.get(path, expected=401)

    def test_concurrent_message_idempotency(self):
        room = self.bob.room()
        with ThreadPoolExecutor(max_workers=4) as pool:
            messages = list(pool.map(lambda _: self.bob.message(room['id'], 'sent once', client_id='concurrent-id'), range(4)))
        self.assertEqual(len({message['id'] for message in messages}), 1)
        self.assertEqual(len(self.bob.get(f'/api/rooms/{room["id"]}/messages')), 1)

    def test_slow_webhook_does_not_block_media_or_duplicate_claims(self):
        entered, release = threading.Event(), threading.Event()
        delivered = queue.Queue()

        class Webhook(BaseHTTPRequestHandler):
            def do_POST(handler):
                payload = json.loads(handler.rfile.read(int(handler.headers['Content-Length'])))
                delivered.put(payload['message']['id'])
                entered.set()
                release.wait(8)
                handler.send_response(204)
                handler.end_headers()

            def log_message(handler, *_):
                pass

        remote = ThreadingHTTPServer(('127.0.0.1', 0), Webhook)
        thread = threading.Thread(target=remote.serve_forever, daemon=True)
        thread.start()
        try:
            bot = self.admin.post('/api/bots', {'name': 'Slow worker bot', 'webhook': f'http://127.0.0.1:{remote.server_port}/'}, expected=201)
            room = self.bob.room(kind='direct', members=[bot['user']['id']])
            first = self.bob.message(room['id'], 'Held webhook')
            self.assertTrue(entered.wait(3))
            image = self.bob.upload('independent.png', (ROOT / 'public/app-icon.png').read_bytes(), 'image/png')
            until = time.monotonic() + 4
            while time.monotonic() < until:
                with closing(sqlite3.connect(self.server.data / 'vampfire.sqlite3')) as db:
                    if db.execute('SELECT thumb FROM uploads WHERE id=?', (image['id'],)).fetchone()[0]:
                        break
                time.sleep(.025)
            else:
                self.fail('Media processing waited for an unrelated webhook')
            release.set()
            expected = {first['id']}
            for n in range(8):
                expected.add(self.bob.message(room['id'], f'Atomic claim {n}')['id'])
            received = [delivered.get(timeout=5) for _ in expected]
            self.assertEqual(set(received), expected)
            self.assertEqual(len(received), len(set(received)))
            self.admin.patch(f'/api/bots/{bot["user"]["id"]}', {'name': 'Slow worker bot', 'webhook': ''})
        finally:
            release.set()
            remote.shutdown()
            remote.server_close()
            thread.join(timeout=2)

    def test_bot_pagination_and_file_parameter(self):
        bot = self.admin.post('/api/bots', {'name': 'File Bot'}, expected=201)
        room = self.bob.room(members=[bot['user']['id']])
        client = Client(self.server.port)
        path = f'/api/bot/{bot["key"]}/rooms/{room["id"]}/messages'
        uploaded = client.upload('bot.txt', b'From a bot', path=path, field='attachment')
        self.assertEqual(uploaded['attachment']['name'], 'bot.txt')
        for i in range(41):
            self.bob.message(room['id'], f'paginated bot history {i}')
        messages, headers = client.request('GET', path)
        self.assertEqual(len(messages), 40)
        self.assertEqual(headers['X-Total-Count'], '42')
        self.assertIn('rel="next"', headers['Link'])
        following = headers['Link'].split('<')[1].split('>')[0]
        self.assertEqual(len(client.get(following)), 2)

    def test_bot_webhook_reply(self):
        received = queue.Queue()

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.put(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'Automated local reply <safe>')

            def log_message(self, *args):
                pass

        webhook = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=webhook.serve_forever, daemon=True)
        worker.start()
        try:
            bot = self.admin.post('/api/bots', {'name': 'Echo', 'webhook': f'http://127.0.0.1:{webhook.server_port}/'}, expected=201)
            room = self.bob.room(kind='direct', members=[bot['user']['id']])
            sent = self.bob.message(room['id'], 'Hello Echo')
            payload = received.get(timeout=40)
            self.assertEqual(payload['message']['id'], sent['id'])
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                messages = self.bob.get(f'/api/rooms/{room["id"]}/messages')
                if len(messages) > 1:
                    break
                time.sleep(.1)
            self.assertEqual(messages[-1]['plain'], 'Automated local reply <safe>')
        finally:
            webhook.shutdown()
            webhook.server_close()
            worker.join()

    def test_private_url_unfurl_rejected(self):
        for url in ['http://127.0.0.1/', 'http://169.254.169.254/', 'http://10.0.0.1/', 'file:///etc/passwd', 'http://user:pass@example.com/']:
            with self.subTest(url=url):
                self.bob.post('/api/unfurl', {'url': url}, expected=422)

    def test_link_preview_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix='vampfire-preview-fixture-') as directory:
            fixture = Path(directory)
            program = fixture / 'curl'
            program.write_text(f'#!{sys.executable}\n' + (ROOT / 'tests/curl_fixture.py').read_text())
            program.chmod(0o700)
            (fixture / 'image.png').write_bytes((ROOT / 'public/app-icon-192.png').read_bytes())
            server = Server(environment={'PATH': f'{fixture}:{os.environ["PATH"]}', 'VAMPFIRE_TEST_CURL_FIXTURE': str(fixture)})
            try:
                user = Client(server.port)
                user.post('/api/setup', {'name': 'Preview owner', 'email': 'preview@example.test', 'password': PASSWORD}, expected=201)
                room = user.room('Private previews')
                message = user.message(room['id'], '<a href="https://93.184.216.34/page">Project</a>')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    result = user.get(f'/api/rooms/{room["id"]}/messages')[0]
                    if result['preview']['image_id']:
                        break
                    time.sleep(.05)
                self.assertEqual(result['preview']['title'], 'Project preview')
                image = result['preview']['image_id']
                self.assertGreater(image, 0)
                outsider = Client(server.port)
                outsider.post('/api/join', {'name': 'Outside', 'email': 'outside@example.test', 'password': PASSWORD,
                              'join_code': user.get('/api/account')['account']['join_code']}, expected=201)
                outsider.get(f'/uploads/{image}', expected=404)
                user.patch(f'/api/messages/{message["id"]}', {'body': 'Link removed'})
                self.assertFalse(user.get(f'/api/rooms/{room["id"]}/messages')[0]['preview']['title'])
                slow = user.message(room['id'], '<a href="https://93.184.216.34/slow">Slow project</a>')
                deadline = time.monotonic() + 5
                while not (fixture / 'started').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue((fixture / 'started').exists())
                user.patch(f'/api/messages/{slow["id"]}', {'body': 'Changed while fetching'})
                (fixture / 'release').touch()
                with closing(sqlite3.connect(server.data / 'vampfire.sqlite3')) as db:
                    deadline = time.monotonic() + 5
                    while db.execute("SELECT 1 FROM jobs WHERE kind='preview' AND payload=?", (str(slow['id']),)).fetchone() and time.monotonic() < deadline:
                        time.sleep(.03)
                    self.assertIsNone(db.execute('SELECT 1 FROM link_previews WHERE message_id=?', (slow['id'],)).fetchone())
            finally:
                server.close()

    def test_job_retry_limit(self):
        with closing(sqlite3.connect(self.server.data / 'vampfire.sqlite3')) as db:
            job_id = db.execute("INSERT INTO jobs(kind,payload,attempts,available_at) VALUES('push','{',4,0)").lastrowid
            db.commit()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                attempts, error = db.execute('SELECT attempts,error FROM jobs WHERE id=?', (job_id,)).fetchone()
                if attempts == 5 and error:
                    break
                time.sleep(.03)
            self.assertEqual(attempts, 5)
            self.assertTrue(error)
            db.execute('UPDATE jobs SET available_at=0 WHERE id=?', (job_id,))
            db.commit()
            time.sleep(.6)
            self.assertEqual(db.execute('SELECT attempts FROM jobs WHERE id=?', (job_id,)).fetchone()[0], 5)
            db.execute('DELETE FROM jobs WHERE id=?', (job_id,))
            db.commit()

    def test_pwa(self):
        self.assertIn(b'push', self.admin.get('/service-worker.js'))
        manifest = self.admin.get('/webmanifest')
        if isinstance(manifest, bytes):
            manifest = json.loads(manifest)
        self.assertEqual(manifest['display'], 'standalone')

    def test_z_moderation_and_invitation_rotation(self):
        member = self.join('Moderation target', 'target@example.test')
        sent = member.message(1, 'remove-this-on-ban')
        with member.socket() as socket:
            self.admin.patch(f'/api/users/{member.user["id"]}', {'action': 'ban'})
            socket.until('closed')
        member.get('/api/rooms', expected=401)
        self.assertFalse(self.admin.get('/api/search?q=remove-this-on-ban')['messages'])
        self.admin.patch(f'/api/users/{member.user["id"]}', {'action': 'unban'})
        self.admin.patch(f'/api/users/{member.user["id"]}', {'action': 'deactivate'})
        Client(self.server.port).post('/api/session', {'email': 'target@example.test', 'password': PASSWORD}, expected=401)
        new_code = self.admin.post('/api/account/invitation')['account']['join_code']
        self.assertNotEqual(new_code, self.code)
        Client(self.server.port).post('/api/join', {'name': 'Late', 'email': 'late@example.test', 'password': PASSWORD, 'join_code': self.code}, expected=404)

    def test_zz_rate_limit_does_not_trust_client_headers(self):
        connection = sqlite3.connect(self.server.data / 'vampfire.sqlite3')
        connection.execute("DELETE FROM rate_limits WHERE key LIKE 'login:%'")
        connection.commit()
        connection.close()
        for i in range(11):
            Client(self.server.port).post('/api/session', {'email': 'nobody@example.test', 'password': 'wrong'},
                expected=401 if i < 10 else 429, headers={'X-Forwarded-For': f'8.8.8.{i+1}', 'CF-Connecting-IP': f'1.1.1.{i+1}'})


if __name__ == '__main__':
    if not os.environ.get('VAMPFIRE_RESOURCE_GUARD'):
        raise SystemExit('Run with mise run test or scripts/resource_guard.py.')
    unittest.main(verbosity=2)
