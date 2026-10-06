module main

import db.sqlite
import json2 as json
import time
import veb

const message_select = 'SELECT m.*,u.name,u.avatar_id,a.id AS attachment_id,a.name AS filename,a.mime,a.size,a.thumb,a.width,a.height,a.duration FROM messages m JOIN users u ON u.id=m.user_id LEFT JOIN uploads a ON a.id=m.upload_id '

fn messages_from(db sqlite.DB, rows []sqlite.Row) ![]ChatMessage {
	mut messages := []ChatMessage{}
	mut indices := map[int]int{}
	mut ids := []string{}
	for r in rows {
		id := r.get_int('id')
		indices[id] = messages.len
		ids << id.str()
		messages << ChatMessage{
			id:         id
			room_id:    r.get_int('room_id')
			user_id:    r.get_int('user_id')
			name:       r.get_string('name')
			avatar_id:  r.get_int('avatar_id')
			client_id:  r.get_string('client_id')
			body:       r.get_string('body')
			plain:      r.get_string('plain')
			reply_id:   r.get_int('reply_id')
			created_at: r.get_string('created_at').i64()
			updated_at: r.get_string('updated_at').i64()
			attachment: Upload{
				id:       r.get_int('attachment_id')
				name:     r.get_string('filename')
				mime:     r.get_string('mime')
				size:     r.get_string('size').i64()
				thumb:    r.get_string('thumb')
				width:    r.get_int('width')
				height:   r.get_int('height')
				duration: r.get_string('duration').f64()
			}
		}
	}
	if ids.len > 0 {
		for r in query(db, 'SELECT * FROM link_previews WHERE message_id IN (${ids.join(',')})')! {
			messages[indices[r.get_int('message_id')]].preview = LinkPreview{ url: r.get_string('url'), title: r.get_string('title'), description: r.get_string('description'), image_id: r.get_int('image_id') }
		}
		// IDs originate from SQLite integer columns; user input is always bound.
		for r in query(db, 'SELECT b.*,u.name FROM boosts b JOIN users u ON u.id=b.user_id WHERE b.message_id IN (${ids.join(',')}) ORDER BY b.id')! {
			idx := indices[r.get_int('message_id')]
			messages[idx].boosts << Boost{ id: r.get_int('id'), user_id: r.get_int('user_id'), name: r.get_string('name'), content: r.get_string('content') }
		}
	}
	return messages
}

fn message_by_id(db sqlite.DB, user_id int, id int) !ChatMessage {
	rows := query(db, message_select + 'JOIN memberships k ON k.room_id=m.room_id WHERE m.id=? AND k.user_id=?', id.str(), user_id.str())!
	if rows.len == 0 { return error_with_code('Message not found.', 404) }
	return messages_from(db, rows)![0]
}

@['/api/rooms/:id/messages']
pub fn (app &App) messages_index(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, list_messages, false)
}

fn list_messages(mut ctx Context, _app &App, db sqlite.DB) !string {
	room_for(db, ctx.user.id, ctx.entity_id)!
	before := ctx.query['before'].int()
	after := ctx.query['after'].int()
	around := ctx.query['around'].int()
	mut rows := []sqlite.Row{}
	if around > 0 {
		one(db, 'SELECT id FROM messages WHERE room_id=? AND id=?', ctx.entity_id.str(), around.str())!
		rows = query(db, message_select + 'WHERE m.room_id=? AND m.id<=? ORDER BY m.id DESC LIMIT 41', ctx.entity_id.str(), around.str())!
		rows.reverse_in_place()
		rows << query(db, message_select + 'WHERE m.room_id=? AND m.id>? ORDER BY m.id LIMIT 40', ctx.entity_id.str(), around.str())!
	} else if after > 0 {
		rows = query(db, message_select + 'WHERE m.room_id=? AND m.id>? ORDER BY m.id LIMIT 40', ctx.entity_id.str(), after.str())!
	} else {
		rows = query(db, message_select + 'WHERE m.room_id=? AND (CAST(? AS INTEGER)=0 OR m.id<?) ORDER BY m.id DESC LIMIT 40', ctx.entity_id.str(), before.str(), before.str())!
		rows.reverse_in_place()
	}
	return json.encode(messages_from(db, rows)!)
}

struct MessageInput {
	body      string
	client_id string
	upload_id int
	reply_id  int
}

@['/api/rooms/:id/messages'; post]
pub fn (app &App) messages_create(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, create_message, false)
}

fn create_message(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[MessageInput](ctx)!
	message := save_message(db, ctx.user, ctx.entity_id, input)!
	app.publish_room(db, ctx.entity_id, Event{ kind: 'message', room_id: ctx.entity_id, message: message })
	ctx.res.set_status(.created)
	return json.encode(message)
}

fn save_message(db sqlite.DB, user User, room_id int, input MessageInput) !ChatMessage {
	content := room_rich_text(db, room_id, input.body)!
	if content.plain.trim_space() == '' && input.upload_id == 0 {
		return error_with_code('Write a message or attach a file.', 422)
	}
	if input.client_id.len > 100 { return error_with_code('Invalid message identifier.', 422) }
	client_id := if input.client_id == '' { token() } else { input.client_id }
	now := time.now().unix_milli().str()
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	room := room_for(db, user.id, room_id)!
	old := query(db, 'SELECT id,room_id FROM messages WHERE user_id=? AND client_id=?', user.id.str(), client_id)!
	if old.len > 0 {
		if old[0].get_int('room_id') != room_id {
			return error_with_code('Message identifier already used.', 409)
		}
		return message_by_id(db, user.id, old[0].get_int('id'))!
	}
	if input.reply_id > 0 && !exists(db, 'SELECT 1 FROM messages WHERE id=? AND room_id=?', input.reply_id.str(), room_id.str()) {
		return error_with_code('Reply target is unavailable.', 422)
	}
	if input.upload_id > 0 && !exists(db, 'SELECT 1 FROM uploads WHERE id=? AND owner_id=?', input.upload_id.str(), user.id.str()) {
		return error_with_code('Attachment is unavailable.', 422)
	}
	plain := if content.plain == '' && input.upload_id > 0 {
		one(db, 'SELECT name FROM uploads WHERE id=?', input.upload_id.str())!.get_string('name')
	} else {
		content.plain
	}
	execute(db, "INSERT INTO messages(room_id,user_id,client_id,body,plain,upload_id,reply_id,created_at,updated_at) VALUES(?,?,?,?,?,nullif(?,'0'),nullif(?,'0'),?,?)", room_id.str(), user.id.str(), client_id, content.html, plain, input.upload_id.str(), input.reply_id.str(), now, now)!
	id := int(db.last_insert_rowid())
	execute(db, 'INSERT INTO message_fts(rowid,body) VALUES(?,?)', id.str(), plain)!
	for uid in content.mentions {
		if uid in room.members {
			execute(db, 'INSERT INTO mentions(message_id,user_id) VALUES(?,?)', id.str(), uid.str())!
		}
	}
	execute(db, 'UPDATE rooms SET updated_at=? WHERE id=?', now, room_id.str())!
	execute(db, 'UPDATE memberships SET read_id=? WHERE room_id=? AND user_id=?', id.str(), room_id.str(), user.id.str())!
	queue_job(db, 'notify', id.str())!
	if content.html.contains('href=') { queue_job(db, 'preview', id.str())! }
	if user.role != 'bot' {
		for bot in query(db, "SELECT u.id FROM users u JOIN memberships k ON k.user_id=u.id WHERE k.room_id=? AND u.role='bot' AND u.status='active' AND u.webhook!='' AND (?='direct' OR u.id IN(SELECT user_id FROM mentions WHERE message_id=?))", room_id.str(), room.kind, id.str())! {
			queue_job(db, 'webhook', json.encode(WebhookJob{ message_id: id, bot_id: bot.get_int('id') }))!
		}
	}
	db.exec('COMMIT')!
	return message_by_id(db, user.id, id)
}

@['/api/messages/:id'; patch]
pub fn (app &App) messages_update(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, update_message, false)
}

fn update_message(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[MessageInput](ctx)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	message := message_by_id(db, ctx.user.id, ctx.entity_id)!
	content := room_rich_text(db, message.room_id, input.body)!
	if ctx.user.role != 'administrator' && message.user_id != ctx.user.id {
		return error_with_code('You cannot edit this message.', 403)
	}
	if content.plain == '' && message.attachment.id == 0 {
		return error_with_code('Write a message.', 422)
	}
	execute(db, 'UPDATE messages SET body=?,plain=?,updated_at=? WHERE id=?', content.html, content.plain, time.now().unix_milli().str(), message.id.str())!
	execute(db, 'UPDATE message_fts SET body=? WHERE rowid=?', content.plain, message.id.str())!
	execute(db, 'DELETE FROM link_previews WHERE message_id=?', message.id.str())!
	if content.html.contains('href=') { queue_job(db, 'preview', message.id.str())! }
	execute(db, 'DELETE FROM mentions WHERE message_id=?', message.id.str())!
	for uid in content.mentions {
		if exists(db, 'SELECT 1 FROM memberships WHERE room_id=? AND user_id=?', message.room_id.str(), uid.str()) {
			execute(db, 'INSERT INTO mentions(message_id,user_id) VALUES(?,?)', message.id.str(), uid.str())!
		}
	}
	db.exec('COMMIT')!
	updated := message_by_id(db, ctx.user.id, message.id)!
	app.publish_room(db, message.room_id, Event{ kind: 'message_updated', room_id: message.room_id, message: updated })
	return json.encode(updated)
}

@['/api/messages/:id'; delete]
pub fn (app &App) messages_delete(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, delete_message, false)
}

fn delete_message(mut ctx Context, app &App, db sqlite.DB) !string {
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	message := message_by_id(db, ctx.user.id, ctx.entity_id)!
	if ctx.user.role != 'administrator' && message.user_id != ctx.user.id {
		return error_with_code('You cannot delete this message.', 403)
	}
	execute(db, 'DELETE FROM message_fts WHERE rowid=?', message.id.str())!
	execute(db, 'DELETE FROM messages WHERE id=?', message.id.str())!
	db.exec('COMMIT')!
	app.publish_room(db, message.room_id, Event{ kind: 'message_deleted', room_id: message.room_id, message_id: message.id })
	return json.encode(Success{})
}

struct BoostInput {
	content string
}

@['/api/messages/:id/boosts'; post]
pub fn (app &App) boosts_create(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, create_boost, false)
}

fn create_boost(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[BoostInput](ctx)!
	if input.content.trim_space() == '' || input.content.runes().len > 16 {
		return error_with_code('A boost can contain 1–16 characters.', 422)
	}
	message := message_by_id(db, ctx.user.id, ctx.entity_id)!
	execute(db, 'INSERT INTO boosts(message_id,user_id,content,created_at) VALUES(?,?,?,?)', message.id.str(), ctx.user.id.str(), input.content.trim_space(), time.now().unix_milli().str())!
	updated := message_by_id(db, ctx.user.id, message.id)!
	app.publish_room(db, message.room_id, Event{ kind: 'message_updated', room_id: message.room_id, message: updated })
	ctx.res.set_status(.created)
	return json.encode(updated)
}

@['/api/boosts/:id'; delete]
pub fn (app &App) boosts_delete(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, delete_boost, false)
}

fn delete_boost(mut ctx Context, app &App, db sqlite.DB) !string {
	r := one(db, 'SELECT message_id FROM boosts WHERE id=? AND user_id=?', ctx.entity_id.str(), ctx.user.id.str())!
	message := message_by_id(db, ctx.user.id, r.get_int('message_id'))!
	execute(db, 'DELETE FROM boosts WHERE id=? AND user_id=?', ctx.entity_id.str(), ctx.user.id.str())!
	app.publish_room(db, message.room_id, Event{ kind: 'message_updated', room_id: message.room_id, message: message_by_id(db, ctx.user.id, message.id)! })
	return json.encode(Success{})
}

@['/api/search']
pub fn (app &App) searches_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, search_messages, false)
}

struct SearchResult {
	messages []ChatMessage
	recent   []string
}

fn search_messages(mut ctx Context, _app &App, db sqlite.DB) !string {
	q := ctx.query['q'].trim_space()
	if q.len > 200 { return error_with_code('Use a shorter search.', 422) }
	mut messages := []ChatMessage{}
	if q != '' {
		terms := q.split_any(' \t\r\n').filter(it != '').map('"' + it.replace('"', '""') + '"').join(' ')
		if terms != '' {
			rows := query(db, message_select + 'JOIN message_fts f ON f.rowid=m.id JOIN memberships k ON k.room_id=m.room_id WHERE message_fts MATCH ? AND k.user_id=? AND (CAST(? AS INTEGER)=0 OR m.room_id=?) AND (CAST(? AS INTEGER)=0 OR m.id<?) ORDER BY m.id DESC LIMIT 40', terms, ctx.user.id.str(), ctx.query['room'].int().str(), ctx.query['room'].int().str(), ctx.query['before'].int().str(), ctx.query['before'].int().str())!
			messages = messages_from(db, rows)!
		}
	}
	mut recent := []string{}
	for r in query(db, 'SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10', ctx.user.id.str())! {
		recent << r.get_string('query')
	}
	return json.encode(SearchResult{ messages: messages, recent: recent })
}

struct SearchInput {
	query string
}

@['/api/search'; post]
pub fn (app &App) searches_save(mut ctx Context) veb.Result {
	return respond(mut ctx, app, save_search, false)
}

fn save_search(mut ctx Context, _app &App, db sqlite.DB) !string {
	input := body[SearchInput](ctx)!
	if input.query.len > 200 || input.query.trim_space() == '' {
		return error_with_code('Enter a search query.', 422)
	}
	execute(db, 'INSERT INTO searches(user_id,query,updated_at) VALUES(?,?,?) ON CONFLICT(user_id,query) DO UPDATE SET updated_at=excluded.updated_at', ctx.user.id.str(), input.query.trim_space(), time.now().unix_milli().str())!
	execute(db, 'DELETE FROM searches WHERE user_id=? AND query NOT IN(SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10)', ctx.user.id.str(), ctx.user.id.str())!
	return json.encode(Success{})
}

@['/api/search'; delete]
pub fn (app &App) searches_clear(mut ctx Context) veb.Result {
	return respond(mut ctx, app, clear_search, false)
}

fn clear_search(mut ctx Context, _app &App, db sqlite.DB) !string {
	execute(db, 'DELETE FROM searches WHERE user_id=?', ctx.user.id.str())!
	return json.encode(Success{})
}
