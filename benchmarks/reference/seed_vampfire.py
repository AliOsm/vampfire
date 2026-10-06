"""Translate the reference seed's records, text and media into Vampfire's schema."""
from datetime import datetime, timezone
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import sqlite3

ROOT = Path(__file__).resolve().parents[2]


def stamp(value, millis=False):
    return int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp()*(1000 if millis else 1))


def main():
    source = ROOT/'.build/comparison/reference-seed'
    target = ROOT/'.build/comparison/vampfire-seed'
    if target.exists():
        raise SystemExit(f'Preserve existing seed: {target}')
    (target/'uploads').mkdir(parents=True)
    ref = sqlite3.connect(source/'db/production.sqlite3')
    ref.row_factory = sqlite3.Row
    out = sqlite3.connect(target/'vampfire.sqlite3')
    out.executescript((ROOT/'src/schema.sql').read_text())

    def rows(table):
        return [dict(r) for r in ref.execute(f'SELECT * FROM {table}')]

    def insert(table, **values):
        out.execute(f'INSERT INTO {table}({",".join(values)}) VALUES({",".join("?" for _ in values)})', list(values.values()))

    messages = sorted(rows('messages'), key=lambda r:(r['created_at'],r['id']))
    ids = {r['id']:i+1 for i,r in enumerate(messages)}
    labels = json.loads((source/'labels.json').read_text())
    a = rows('accounts')[0]
    insert('account', id=1, name=a['name'], join_code=a['join_code'], custom_css=a['custom_styles'] or '')
    for r in rows('users'):
        insert('users', id=r['id'], name=r['name'], email=r['email_address'], password=r['password_digest'] or '',
               bio=r['bio'] or '', role=['member','administrator','bot'][r['role']],
               status=['active','deactivated','banned'][r['status']], bot_key=r['bot_token'], created_at=stamp(r['created_at']))
    memberships = rows('memberships')
    for r in rows('rooms'):
        kind = r['type'].split('::')[-1].lower()
        members = sorted(m['user_id'] for m in memberships if m['room_id']==r['id'])
        insert('rooms', id=r['id'], name=r['name'] or '', kind=kind, creator_id=r['creator_id'],
               direct_key=','.join(map(str,members)) if kind=='direct' else None,
               created_at=stamp(r['created_at'],True), updated_at=stamp(r['updated_at'],True))
    for r in memberships:
        read = max((ids[m['id']] for m in messages if m['room_id']==r['room_id'] and
                    (not r['unread_at'] or m['created_at']<r['unread_at'])), default=0)
        insert('memberships', room_id=r['room_id'], user_id=r['user_id'], involvement=r['involvement'], read_id=read)

    blobs = {r['id']:r for r in rows('active_storage_blobs')}
    attachments = rows('active_storage_attachments')
    linked = {}
    for r in attachments:
        if r['record_type'] not in ['Message','User']: continue
        b = blobs[r['blob_id']]
        owner = r['record_id'] if r['record_type']=='User' else next(m['creator_id'] for m in messages if m['id']==r['record_id'])
        metadata = json.loads(b['metadata'])
        for blob in [b]:
            if blob:
                key = blob['key']
                shutil.copy2(source/'storage'/key[:2]/key[2:4]/key, target/'uploads'/key)
        insert('uploads', id=b['id'], owner_id=owner, key=b['key'], name=b['filename'], mime=b['content_type'],
               size=b['byte_size'], width=metadata.get('width',0),
               height=metadata.get('height',0), duration=metadata.get('duration',0), created_at=stamp(b['created_at']))
        insert('jobs',kind='media',payload=str(b['id']),available_at=0)
        if r['record_type']=='User':
            out.execute('UPDATE users SET avatar_id=? WHERE id=?',(b['id'],owner))
        else:
            linked[r['record_id']]=b['id']
    text = {r['record_id']:r['body'] or '' for r in rows('action_text_rich_texts')}
    plain = dict(ref.execute('SELECT rowid,body FROM message_search_index'))
    for r in messages:
        body = text.get(r['id'],'')
        content = plain.get(r['id'],html.unescape(re.sub('<[^>]+>','',body)))
        insert('messages', id=ids[r['id']], room_id=r['room_id'], user_id=r['creator_id'], client_id=r['client_message_id'],
               body=body, plain=content, upload_id=linked.get(r['id']), created_at=stamp(r['created_at'],True), updated_at=stamp(r['updated_at'],True))
        insert('message_fts', rowid=ids[r['id']],body=content)
    for r in rows('boosts'):
        insert('boosts', id=r['id'],message_id=ids[r['message_id']], user_id=r['booster_id'],content=r['content'],created_at=stamp(r['created_at'],True))
    for r in rows('searches'):
        insert('searches',user_id=r['user_id'],query=r['query'],updated_at=stamp(r['updated_at'],True))
    for r in rows('webhooks'):
        out.execute('UPDATE users SET webhook=? WHERE id=?',(f'http://127.0.0.1:9/hook/{r["id"]}',r['user_id']))
    # Match the reference harness: fail deliveries locally instead of contacting real providers.
    for r in rows('push_subscriptions'):
        session = hashlib.sha256(f'benchmark-only-session-{r["id"]}'.encode()).hexdigest()
        insert('sessions',token=session,user_id=r['user_id'],csrf='benchmark-only',ip='127.0.0.1',agent='benchmark seed',
               created_at=stamp(r['created_at']),active_at=stamp(r['updated_at']),expires_at=4102444800)
        insert('subscriptions',id=r['id'],user_id=r['user_id'],session_token=session,
               endpoint=f'https://127.0.0.1:9/push/{r["id"]}',p256dh=r['p256dh_key'],auth=r['auth_key'],
               agent=r['user_agent'],created_at=stamp(r['created_at']))
    for r in rows('bans'):
        insert('bans',user_id=r['user_id'],ip=r['ip_address'])
    for k in list(labels):
        if k.startswith('messages.'):
            labels[k]=ids[labels[k]]
    out.commit()
    report = {
        'users':out.execute('SELECT count(*) FROM users').fetchone()[0],
        'rooms':out.execute('SELECT count(*) FROM rooms').fetchone()[0],
        'messages':len(messages),
        'busy_room_messages':out.execute('SELECT count(*) FROM messages WHERE room_id=?',(labels['rooms.watercooler'],)).fetchone()[0],
        'message_id_mapping':ids,
        'source_database_sha256':hashlib.sha256((source/'db/production.sqlite3').read_bytes()).hexdigest(),
    }
    out.close(); ref.close()
    (target/'labels.json').write_text(json.dumps(labels,indent=2)+'\n')
    (target/'translation.json').write_text(json.dumps(report,indent=2)+'\n')
    print({k:v for k,v in report.items() if k!='message_id_mapping'})


if __name__=='__main__':
    main()
