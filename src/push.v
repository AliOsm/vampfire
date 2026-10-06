module main

import crypto.aes
import crypto.ecdsa
import crypto.hkdf
import crypto.rand
import crypto.sha256
import db.sqlite
import encoding.base64
import json2 as json
import net.urllib
import time
import math
import veb

struct PushInput {
	endpoint string
	p256dh   string
	auth     string
}

struct Subscription {
	id         int
	endpoint   string
	agent      string
	created_at i64
}

struct Notification {
	title string
	body  string
	path  string
}

fn validate_subscription(input PushInput) ! {
	u := validate_url(input.endpoint, true)!
	if u.scheme != 'https' || u.port() !in ['', '443'] {
		return error_with_code('Push endpoints must use HTTPS.', 422)
	}
	host := u.hostname().to_lower()
	mut allowed := false
	for name in ['jmt17.google.com', 'fcm.googleapis.com', 'updates.push.services.mozilla.com',
		'web.push.apple.com', 'notify.windows.com'] {
		if host == name || host.ends_with('.' + name) { allowed = true }
	}
	if !allowed { return error_with_code('Unsupported browser push service.', 422) }
	if base64.url_decode(input.p256dh).len != 65 || base64.url_decode(input.auth).len != 16 {
		return error_with_code('Invalid push encryption keys.', 422)
	}
	mut public := ecdsa.PublicKey.from_uncompressed_bytes(base64.url_decode(input.p256dh),
		nid: .prime256v1
	) or { return error_with_code('Invalid push encryption key.', 422) }
	public.free()
}

@['/api/subscriptions']
pub fn (app &App) subscriptions_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, list_subscriptions, false)
}

fn list_subscriptions(mut ctx Context, _app &App, db sqlite.DB) !string {
	mut result := []Subscription{}
	for r in query(db, 'SELECT * FROM subscriptions WHERE user_id=? ORDER BY id DESC', ctx.user.id.str())! {
		result << Subscription{ id: r.get_int('id'), endpoint: r.get_string('endpoint'), agent: r.get_string('agent'), created_at: r.get_string('created_at').i64() }
	}
	return json.encode(result)
}

@['/api/subscriptions'; post]
pub fn (app &App) subscriptions_create(mut ctx Context) veb.Result {
	return respond(mut ctx, app, create_subscription, false)
}

fn create_subscription(mut ctx Context, app &App, db sqlite.DB) !string {
	if app.push_public == '' || app.push_private == '' {
		return error_with_code('Push notifications are not configured on this server.', 503)
	}
	input := body[PushInput](ctx)!
	validate_subscription(input)!
	execute(db, 'INSERT INTO subscriptions(user_id,session_token,endpoint,p256dh,auth,agent,created_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(endpoint) DO UPDATE SET user_id=excluded.user_id,session_token=excluded.session_token,p256dh=excluded.p256dh,auth=excluded.auth,agent=excluded.agent', ctx.user.id.str(), ctx.session_hash, input.endpoint, input.p256dh, input.auth, ctx.user_agent(), time.now().unix().str())!
	return json.encode(Success{})
}

@['/api/subscriptions/:id'; delete]
pub fn (app &App) subscriptions_delete(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, delete_subscription, false)
}

fn delete_subscription(mut ctx Context, _app &App, db sqlite.DB) !string {
	execute(db, 'DELETE FROM subscriptions WHERE id=? AND user_id=?', ctx.entity_id.str(), ctx.user.id.str())!
	return json.encode(Success{})
}

@['/api/subscriptions/:id/test'; post]
pub fn (app &App) subscriptions_test(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, queue_test_push, false)
}

fn queue_test_push(mut ctx Context, _app &App, db sqlite.DB) !string {
	one(db, 'SELECT id FROM subscriptions WHERE id=? AND user_id=?', ctx.entity_id.str(), ctx.user.id.str())!
	queue_job(db, 'push_test', ctx.entity_id.str())!
	return json.encode(Success{})
}

fn test_push(app &App, db sqlite.DB, id int) ! {
	r := one(db, 'SELECT * FROM subscriptions WHERE id=?', id.str()) or { return }
	send_push(app, db, r, Notification{ title: 'Vampfire', body: 'Notifications are working.', path: '/' })!
}

fn notify_message(app &App, db sqlite.DB, id int) ! {
	if app.push_public == '' || app.push_private == '' { return }
	r := one(db, 'SELECT m.*,u.name,r.name AS room_name,r.kind FROM messages m JOIN users u ON u.id=m.user_id JOIN rooms r ON r.id=m.room_id WHERE m.id=?', id.str()) or { return }
	room_id := r.get_int('room_id')
	active := app.active_users(room_id)
	notification := Notification{
		title: if r.get_string('kind') == 'direct' {
			r.get_string('name')
		} else {
			r.get_string('room_name')
		}
		body:  if r.get_string('kind') == 'direct' {
			r.get_string('plain')
		} else {
			r.get_string('name') + ': ' + r.get_string('plain')
		}
		path:  '/rooms/${room_id}?at=${id}'
	}
	for subscription in notification_recipients(db, room_id, r.get_int('user_id'), id, active)! {
		send_push(app, db, subscription, notification)!
	}
}

fn notification_recipients(db sqlite.DB, room_id int, sender_id int, message_id int, present []int) ![]sqlite.Row {
	mut recipients := []sqlite.Row{}
	for row in query(db, "SELECT s.* FROM subscriptions s JOIN sessions device ON device.token=s.session_token JOIN memberships k ON k.user_id=s.user_id JOIN users u ON u.id=s.user_id WHERE k.room_id=? AND s.user_id!=? AND u.status='active' AND device.expires_at>? AND (k.involvement='everything' OR (k.involvement='mentions' AND s.user_id IN(SELECT user_id FROM mentions WHERE message_id=?)))", room_id.str(), sender_id.str(), time.now().unix().str(), message_id.str())! {
		if row.get_int('user_id') !in present { recipients << row }
	}
	return recipients
}

// RFC 8291 / RFC 8188: one aes128gcm record with a fresh P-256 ephemeral key.
fn encrypt_push(payload []u8, receiver_key []u8, auth []u8) ![]u8 {
	mut public, mut private := ecdsa.generate_key(nid: .prime256v1)!
	defer {
		public.free()
		private.free()
	}
	return encrypt_push_record(payload, receiver_key, auth, private, rand.bytes(16)!)
}

fn encrypt_push_record(payload []u8, receiver_key []u8, auth []u8, private ecdsa.PrivateKey, salt []u8) ![]u8 {
	if payload.len > 3993 || salt.len != 16 || auth.len != 16 {
		return error('Invalid Web Push record size.')
	}
	mut receiver := ecdsa.PublicKey.from_uncompressed_bytes(receiver_key, nid: .prime256v1)!
	mut public := private.public_key()!
	defer {
		receiver.free()
		public.free()
	}
	sender := public.uncompressed_bytes()!
	secret := private.derive_shared_secret(receiver)!
	prk := hkdf.extract(sha256.new, secret, auth)!
	mut info := 'WebPush: info\x00'.bytes()
	info << receiver_key
	info << sender
	ikm := hkdf.expand(sha256.new, prk, info.bytestr(), 32)!
	key := hkdf.key(sha256.new, ikm, salt, 'Content-Encoding: aes128gcm\x00', 16)!
	nonce := hkdf.key(sha256.new, ikm, salt, 'Content-Encoding: nonce\x00', 12)!
	mut plain := payload.clone()
	plain << u8(2)
	cipher := aes.new_aes_gcm(key)!
	encrypted := cipher.encrypt(plain, nonce, [])!
	mut record := salt.clone()
	record << [u8(0), 0, 16, 0, u8(sender.len)]
	record << sender
	record << encrypted
	return record
}

struct VapidClaims {
	aud string
	exp i64
	sub string
}

fn jose_signature(der []u8) ![]u8 {
	if der.len < 8 || der[0] != 48 || der[2] != 2 { return error('Invalid ECDSA signature.') }
	rlen := int(der[3])
	spos := 4 + rlen
	if spos + 2 > der.len || der[spos] != 2 { return error('Invalid ECDSA signature.') }
	slen := int(der[spos + 1])
	if rlen < 1 || rlen > 33 || slen < 1 || slen > 33 || spos + 2 + slen != der.len {
		return error('Invalid ECDSA signature size.')
	}
	rbytes := der[if rlen == 33 { 5 } else { 4 }..4 + rlen]
	sbytes := der[if slen == 33 { spos + 3 } else { spos + 2 }..]
	if rbytes.len > 32 || sbytes.len > 32 { return error('Invalid P-256 signature.') }
	mut result := []u8{len: 64}
	for i, b in rbytes { result[32 - rbytes.len + i] = b }
	for i, b in sbytes { result[64 - sbytes.len + i] = b }
	return result
}

fn send_push(app &App, db sqlite.DB, row sqlite.Row, notification Notification) ! {
	input := PushInput{ endpoint: row.get_string('endpoint'), p256dh: row.get_string('p256dh'), auth: row.get_string('auth') }
	validate_subscription(input)!
	url := urllib.parse(input.endpoint)!
	mut private := ecdsa.new_key_from_seed(base64.url_decode(app.push_private), nid: .prime256v1)!
	defer { private.free() }
	claims := base64.url_encode_str(json.encode(VapidClaims{ aud: '${url.scheme}://${url.host}', exp: time.now().unix() + 3600, sub: app.base_url }))
	signing := base64.url_encode_str('{"typ":"JWT","alg":"ES256"}') + '.' + claims
	jwt := signing + '.' + base64.url_encode(jose_signature(private.sign(signing.bytes())!)!)
	payload := json.encode(Notification{ title: notification.title.runes()[..math.min(notification.title.runes().len, 100)].string(), body: notification.body.runes()[..math.min(notification.body.runes().len, 500)].string(), path: notification.path })
	encrypted := encrypt_push(payload.bytes(), base64.url_decode(input.p256dh), base64.url_decode(input.auth))!
	response := fetch_url(app, input.endpoint, 'POST', encrypted.bytestr(), {
		'TTL':              '86400'
		'Content-Encoding': 'aes128gcm'
		'Content-Type':     'application/octet-stream'
		'Authorization':    'vapid t=${jwt}, k=${app.push_public}'
	}, true)!
	if response.status in [404, 410] {
		execute(db, 'DELETE FROM subscriptions WHERE id=?', row.get_int('id').str())!
	} else if response.status >= 300 {
		return error('Push delivery returned ${response.status}.')
	}
}
