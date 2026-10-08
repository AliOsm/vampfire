"""Response contracts and persisted-write audits adapted from the shared harness.

Expected windows/content are selected from SQLite, never inferred from responses.
See basecamp/once-campfire-verification, bench/contracts.rb and validate_acks.rb.
"""
import html
import json
from pathlib import Path
import re
import sqlite3
import subprocess


def decode_image(body):
    result = subprocess.run(['ffprobe', '-v', 'error', '-threads', '1', '-count_frames',
        '-show_entries', 'stream=width,height,nb_read_frames', '-of', 'json', '-i', 'pipe:0'],
        input=body, capture_output=True, timeout=15, check=True)
    errors = result.stderr.decode().splitlines()
    allowed = re.compile(r'^\[webp @ 0x[0-9a-f]+\] invalid TIFF header in (?:EXIF|Exif) data(?:: Invalid data found when processing input)?\s*$')
    assert all(allowed.fullmatch(line) for line in errors), errors
    assert any(s.get('width', 0) > 0 and s.get('height', 0) > 0 and int(s.get('nb_read_frames', 0)) > 0
               for s in json.loads(result.stdout)['streams']), 'Image pixels did not decode'


def prepare(app, preflight, request):
    folder = app.directory/'contracts'; folder.mkdir()
    v = app.name == 'vampfire'
    labels = app.labels
    room, anchor = labels['rooms.watercooler'], labels['messages.busy_060']
    with sqlite3.connect(app.database) as db:
        user = db.execute('SELECT id FROM users WHERE ' + ('email' if v else 'email_address') + '=?', (labels['emails.david'],)).fetchone()[0]
        if v:
            windows = {
                'room_show': [r[0] for r in db.execute('SELECT id FROM messages WHERE room_id=? ORDER BY id DESC LIMIT 40', (room,))][::-1],
                'messages_page': [r[0] for r in db.execute('SELECT id FROM messages WHERE room_id=? AND id<? ORDER BY id DESC LIMIT 40', (room, anchor))][::-1],
                'search': [r[0] for r in db.execute("SELECT m.id FROM messages m JOIN message_fts f ON f.rowid=m.id JOIN memberships k ON k.room_id=m.room_id WHERE k.user_id=? AND message_fts MATCH 'coffee' ORDER BY m.id DESC LIMIT 40", (user,))],
            }
            text_query = 'SELECT plain FROM messages WHERE id=?'
            names = [r[0] for r in db.execute("SELECT r.name FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND r.kind='open'", (user,))]
        else:
            windows = {
                'room_show': [r[0] for r in db.execute('SELECT id FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40', (room,))][::-1],
                'messages_page': [r[0] for r in db.execute('SELECT id FROM messages WHERE room_id=? AND created_at<(SELECT created_at FROM messages WHERE id=?) ORDER BY created_at DESC LIMIT 40', (room, anchor))][::-1],
                'search': [r[0] for r in db.execute("SELECT m.id FROM messages m JOIN message_search_index f ON f.rowid=m.id JOIN memberships k ON k.room_id=m.room_id WHERE k.user_id=? AND f.body MATCH 'coffee' ORDER BY m.id DESC LIMIT 100", (user,))][::-1],
            }
            text_query = 'SELECT body FROM message_search_index WHERE rowid=?'
            names = [html.escape(r[0], quote=False) for r in db.execute("SELECT r.name FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND r.type='Rooms::Open' AND m.involvement<>'invisible'", (user,))]
        contracts = {}
        for row in preflight:
            kind = row['route']
            contract = {'kind': kind, 'content_type': row['content_type'].split(';')[0], 'required': []}
            if kind in windows:
                assert row['message_ids'] == windows[kind], (kind, row['message_ids'], windows[kind])
                contract['message_ids'] = windows[kind]
                contract['message_content'] = [re.findall(r'[A-Za-z0-9_]+', db.execute(text_query, (mid,)).fetchone()[0]) for mid in windows[kind]]
                if v: contract['content_type'] = 'application/json'
            elif kind == 'sidebar': contract['required'] = names + ([] if v else ['shared_rooms'])
            elif kind in ('avatar', 'static_css'):
                body = (app.directory/(kind+'.response')).read_bytes()
                if kind == 'avatar': decode_image(body)
                contract['exact_body'] = list(body)
            elif kind == 'up' and not v: contract['required'] = ['background-color: green']
            path = folder/(kind+'.json'); path.write_text(json.dumps(contract))
            contracts[kind] = path
        post = {'kind': 'post_message', 'content_type': 'application/json' if v else 'text/vnd.turbo-stream.html', 'required': []}
        if not v:
            status, body, _ = request(f'/rooms/{labels["rooms.hq"]}', app.session['cookie'])
            targets = re.findall(rb'id="(messages_(?:rooms_[a-z]+|room)_' + str(labels['rooms.hq']).encode() + rb')"', body)
            assert status == 200 and len(targets) == 1, 'Write-room target is missing'
            post['required'] = ['action="append"', 'target="' + targets[0].decode() + '"']
        path = folder/'post_message.json'; path.write_text(json.dumps(post)); contracts['post_message'] = path
    return contracts


def audit(app, path, expected):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
    assert len(rows) == expected, (len(rows), expected)
    assert len({r['id'] for r in rows}) == expected, 'Repeated acknowledgement ID'
    assert len({r['token'] for r in rows}) == expected, 'Repeated request token'
    with sqlite3.connect(app.database) as db:
        for r in rows:
            assert re.fullmatch(r'bench write [0-9a-f]+', r['token'])
            if app.name == 'vampfire':
                found = db.execute('SELECT m.room_id,m.plain,f.body FROM messages m JOIN message_fts f ON f.rowid=m.id WHERE m.id=?', (r['id'],)).fetchone()
            else:
                found = db.execute("SELECT m.room_id,r.body,f.body FROM messages m JOIN action_text_rich_texts r ON r.record_id=m.id AND r.record_type='Message' AND r.name='body' JOIN message_search_index f ON f.rowid=m.id WHERE m.id=?", (r['id'],)).fetchone()
            assert found and found[0] == int(app.labels['rooms.hq']), r
            stored = found[1] if app.name == 'vampfire' else html.unescape(re.sub(r'<[^>]*>', '', found[1])).strip()
            assert stored == r['token'] and found[2].strip() == r['token'], r
    return {'verified': True, 'acknowledged': expected}
