module main

import crypto.ecdsa
import encoding.base64
import os
import time

// RFC 8291 section 5 and Appendix A. This checks the wire representation against
// a published independent vector, including ECDH, HKDF, AES-GCM and framing.
fn test_web_push_rfc8291() ! {
	mut private := ecdsa.new_key_from_seed(base64.url_decode('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'),
		nid: .prime256v1
	)!
	defer { private.free() }
	result := encrypt_push_record('When I grow up, I want to be a watermelon'.bytes(),
		base64.url_decode('BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4'),
		base64.url_decode('BTBZMqHH6r4Tts7J_aSIgg'), private, base64.url_decode('DGv6ra1nlYgDCS1FRnbzlw'))!
	assert base64.url_encode(result).trim_right('=') == 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN'
}

fn test_jose_p256_signature_width() ! {
	mut private := ecdsa.new_key_from_seed([]u8{len: 32, init: 1}, nid: .prime256v1)!
	defer { private.free() }
	for _ in 0 .. 16 {
		assert jose_signature(private.sign('payload'.bytes())!)!.len == 64
	}
}

fn test_outbound_network_policy() {
	for ip in ['127.0.0.1', '10.1.1.1', '192.168.1.1', '169.254.169.254', '100.70.1.1', '172.16.0.1',
		'0.0.0.0', '224.0.0.1', '192.0.2.3', '198.51.100.1', '203.0.113.5', '1.2.3.999', '1.2.3.-1',
		'1.2.3.4x', '::1'] {
		assert !public_ipv4(ip)
	}
	assert public_ipv4('8.8.8.8')
	assert public_ipv4('1.1.1.1')
}

fn test_rich_text_fragments() ! {
	assert unescape_html('A&nbsp;B &#x1f680; &#128640; &amp;lt; & plain &') == 'A B 🚀 🚀 &lt; & plain &'
	assert unescape_html('&#; &; &#x; &#1114112; &unknown;') == '&#; &; &#x; &#1114112; &unknown;'
	assert rich_text('before <b>bold</b> after')!.plain == 'before bold after'
	assert rich_text('<p>first</p><p>second</p>')!.plain == 'first\nsecond'
	assert rich_text('<p>hello <em>there</em> friend</p>')!.plain == 'hello there friend'
	assert rich_text('<img src=x onerror=alert(1)>safe')!.plain == 'safe'
	assert rich_text('<svg onload=alert(1)></svg><p>safe</p>')!.html.contains('<p>safe</p>')
}

fn test_notification_targeting_and_session_cleanup() ! {
	directory := os.join_path(os.temp_dir(), 'vampfire-notification-' + token())
	db := open_database(directory)!
	defer {
		db.close() or {}
		os.rmdir_all(directory) or {}
	}
	db.exec('PRAGMA foreign_keys=ON')!
	migrate(db)!
	for id in 1 .. 10 {
		execute(db, 'INSERT INTO users(id,name,created_at) VALUES(?,?,0)', id.str(), 'Person ${id}')!
		execute(db, "INSERT INTO sessions(token,user_id,csrf,ip,agent,created_at,active_at,expires_at) VALUES(?,?,'csrf','127.0.0.1','test',0,0,?)", 'session-${id}', id.str(), (time.now().unix() + 3600).str())!
		execute(db, "INSERT INTO subscriptions(user_id,session_token,endpoint,p256dh,auth,agent,created_at) VALUES(?,?,?,'key','auth','test',0)", id.str(), 'session-${id}', 'https://example.test/${id}')!
	}
	execute(db, "INSERT INTO rooms(id,name,kind,creator_id,created_at,updated_at) VALUES(1,'Room','closed',1,0,0)")!
	for id, involvement in {
		1: 'everything'
		2: 'everything'
		3: 'mentions'
		4: 'nothing'
		5: 'invisible'
		6: 'everything'
		7: 'everything'
		8: 'everything'
	} {
		execute(db, 'INSERT INTO memberships(room_id,user_id,involvement) VALUES(1,?,?)', id.str(), involvement)!
	}
	execute(db, "INSERT INTO messages(id,room_id,user_id,client_id,body,plain,created_at,updated_at) VALUES(1,1,1,'m','Hello','Hello',0,0)")!
	execute(db, 'INSERT INTO mentions(message_id,user_id) VALUES(1,3)')!
	execute(db, "UPDATE users SET status='banned' WHERE id=8")!
	execute(db, 'DELETE FROM sessions WHERE user_id=7')!
	assert !exists(db, 'SELECT 1 FROM subscriptions WHERE user_id=7')
	mut ids := notification_recipients(db, 1, 1, 1, [6])!.map(it.get_int('user_id'))
	ids.sort()
	assert ids == [2, 3]
	execute(db, 'DELETE FROM mentions WHERE message_id=1')!
	assert notification_recipients(db, 1, 1, 1, [6])!.map(it.get_int('user_id')) == [2]
	execute(db, 'UPDATE sessions SET expires_at=0 WHERE user_id=2')!
	assert notification_recipients(db, 1, 1, 1, [6])!.len == 0
}

fn test_database_sessions_commit_rollback_and_cached_bindings() ! {
	directory := os.join_path(os.temp_dir(), 'vampfire-sqlite-' + token())
	db := open_database(directory)!
	defer {
		db.close() or {}
		os.rmdir_all(directory) or {}
	}
	db.exec('CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT UNIQUE)')!
	writer := db.session()
	reader := db.session()
	before := reader.generation()!
	writer.exec('BEGIN IMMEDIATE')!
	execute(writer, 'INSERT INTO sample(value) VALUES(?)', 'first')!
	first_id := writer.last_insert_rowid()
	assert one(reader, 'SELECT count(*) AS n FROM sample')!.get_int('n') == 0
	writer.exec('COMMIT')!
	assert reader.generation()! > before
	assert one(reader, 'SELECT value FROM sample WHERE id=?', first_id.str())!.vals[0] == 'first'
	writer.exec('BEGIN IMMEDIATE')!
	execute(writer, 'INSERT INTO sample(value) VALUES(?)', 'discarded')!
	writer.exec('ROLLBACK')!
	assert one(reader, 'SELECT count(*) AS n FROM sample')!.get_int('n') == 1
	for value in ['second', 'Unicode 🚀', 'embedded\x00zero', ''] {
		execute(writer, 'INSERT INTO sample(value) VALUES(?)', value)!
		assert one(reader, 'SELECT value FROM sample WHERE id=?', writer.last_insert_rowid().str())!.vals[0] == value
	}
	// An evicted statement can be prepared again, without retaining old bindings.
	for i in 0 .. 270 {
		assert one(reader, 'SELECT ${i}')!.vals[0].int() == i
	}
	assert one(reader, 'SELECT value FROM sample WHERE id=?', first_id.str())!.vals[0] == 'first'
}
