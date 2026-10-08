module main

import json2 as json
import time
import veb

struct BotInput {
	name      string
	webhook   string
	avatar_id int
	action    string
}

struct Bot {
	user    User
	key     string
	webhook string
}

struct WebhookJob {
	message_id int
	bot_id     int
}

@['/api/bots']
pub fn (app &App) bots_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, list_bots, false)
}

fn list_bots(mut ctx Context, _app &App, db &Database) !string {
	require_admin(ctx.user)!
	mut bots := []Bot{}
	for r in query(db, "SELECT * FROM users WHERE role='bot' AND status='active' ORDER BY lower(name)")! {
		bots << Bot{ user: user_from(r), key: r.get_string('bot_key'), webhook: r.get_string('webhook') }
	}
	return json.encode(bots)
}

@['/api/bots'; post]
pub fn (app &App) bots_create(mut ctx Context) veb.Result {
	return respond(mut ctx, app, create_bot, false)
}

fn create_bot(mut ctx Context, app &App, db &Database) !string {
	require_admin(ctx.user)!
	input := body[BotInput](ctx)!
	validate_bot(input)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	if input.avatar_id > 0 { require_image_upload(db, ctx.user.id, input.avatar_id)! }
	key := token()
	execute(db, "INSERT INTO users(name,role,bot_key,webhook,avatar_id,created_at) VALUES(?,'bot',?,?,?,?)", input.name.trim_space(), key, input.webhook, input.avatar_id.str(), time.now().unix_milli().str())!
	id := int(db.last_insert_rowid())
	execute(db, "INSERT INTO memberships(room_id,user_id) SELECT id,? FROM rooms WHERE kind='open'", id.str())!
	db.exec('COMMIT')!
	app.publish_users(db)
	ctx.res.set_status(.created)
	return json.encode(Bot{ user: load_user(db, id)!, key: key, webhook: input.webhook })
}

fn validate_bot(input BotInput) ! {
	if input.name.trim_space() == '' || input.name.len > 100 {
		return error_with_code('Give the bot a name.', 422)
	}
	if input.webhook != '' { validate_url(input.webhook, false)! }
}

@['/api/bots/:id'; patch]
pub fn (app &App) bots_update(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, update_bot, false)
}

fn update_bot(mut ctx Context, app &App, db &Database) !string {
	require_admin(ctx.user)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	existing := one(db, "SELECT id,avatar_id FROM users WHERE id=? AND role='bot' AND status='active'", ctx.entity_id.str())!
	input := body[BotInput](ctx)!
	if input.action == 'rotate' {
		execute(db, 'UPDATE users SET bot_key=? WHERE id=?', token(), ctx.entity_id.str())!
	} else {
		validate_bot(input)!
		if input.avatar_id > 0 && input.avatar_id != existing.get_int('avatar_id') {
			require_image_upload(db, ctx.user.id, input.avatar_id)!
		}
		execute(db, 'UPDATE users SET name=?,webhook=?,avatar_id=? WHERE id=?', input.name.trim_space(), input.webhook, input.avatar_id.str(), ctx.entity_id.str())!
	}
	r := one(db, 'SELECT * FROM users WHERE id=?', ctx.entity_id.str())!
	db.exec('COMMIT')!
	app.publish_users(db)
	return json.encode(Bot{ user: user_from(r), key: r.get_string('bot_key'), webhook: r.get_string('webhook') })
}

fn bot_request(mut ctx Context, app &App, key string, room_id int, method string, message_id int, boost_id int) veb.Result {
	db := app.database.session()
	r := one(db, "SELECT * FROM users WHERE bot_key=? AND role='bot' AND status='active'", key) or { return ctx.problem(error_with_code('Invalid bot key.', 401)) }
	ctx.user = user_from(r)
	room_for(db, ctx.user.id, room_id) or { return ctx.problem(err) }
	ctx.entity_id = room_id
	result := perform_bot(mut ctx, app, db, method, message_id, boost_id) or { return ctx.problem(err) }
	return ctx.send_response_to_client('application/json', result)
}

fn perform_bot(mut ctx Context, app &App, db &Database, method string, id int, boost_id int) !string {
	room_id := ctx.entity_id
	if method == 'list' {
		ctx.set_custom_header('X-Total-Count', one(db, 'SELECT count(*) AS n FROM messages WHERE room_id=?', room_id.str())!.get_int('n').str())!
		result := list_messages(mut ctx, app, db)!
		messages := json.decode[[]ChatMessage](result)!
		if messages.len > 0 {
			after := ctx.query['after'].int() > 0
			cursor := if after { messages.last().id } else { messages[0].id }
			comparison := if after { '>' } else { '<' }
			if exists(db, 'SELECT 1 FROM messages WHERE room_id=? AND id${comparison}?', room_id.str(), cursor.str()) {
				ctx.set_custom_header('Link', '<${ctx.req.url.all_before('?')}?${if after {
					'after'
				} else {
					'before'
				}}=${cursor}>; rel="next"')!
			}
		}
		return result
	}
	if method == 'create' {
		content_type := ctx.get_header(.content_type) or { '' }
		mut input := MessageInput{
			body: if content_type.starts_with('text/html') {
				ctx.req.data
			} else {
				escape(ctx.req.data)
			}
		}
		if (ctx.get_header(.content_type) or { '' }).starts_with('application/json') {
			input = body[MessageInput](ctx)!
		}
		for field in ['file', 'attachment'] {
			if files := ctx.files[field] {
				if files.len > 0 {
					upload := store_upload(app, db, ctx.user.id, files[0].filename, files[0].data, files[0].content_type)!
					input = MessageInput{ upload_id: upload.id }
					break
				}
			}
		}
		message := save_message(db, ctx.user, room_id, input)!
		app.publish_room(db, room_id, Event{ kind: 'message', room_id: room_id, message: message })
		ctx.res.set_status(.created)
		ctx.set_header(.location, '/rooms/${room_id}?at=${message.id}')
		return json.encode(message)
	}
	message := message_by_id(db, ctx.user.id, id)!
	if message.room_id != room_id { return error_with_code('Message not found.', 404) }
	ctx.entity_id = id
	if method == 'delete' { return delete_message(mut ctx, app, db) }
	if method == 'update' {
		if !(ctx.get_header(.content_type) or { '' }).starts_with('application/json') {
			ctx.req.data = json.encode(MessageInput{
				body: if (ctx.get_header(.content_type) or { '' }).starts_with('text/html') {
					ctx.req.data
				} else {
					escape(ctx.req.data)
				}
			})
		}
		return update_message(mut ctx, app, db)
	}
	if method == 'boost' {
		if !(ctx.get_header(.content_type) or { '' }).starts_with('application/json') {
			ctx.req.data = json.encode(BoostInput{ content: ctx.req.data })
		}
		return create_boost(mut ctx, app, db)
	}
	one(db, 'SELECT id FROM boosts WHERE id=? AND message_id=? AND user_id=?', boost_id.str(), id.str(), ctx.user.id.str())!
	ctx.entity_id = boost_id
	return delete_boost(mut ctx, app, db)
}

@['/api/bot/:key/rooms/:room/messages']
pub fn (app &App) bot_messages_index(mut ctx Context, key string, room int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'list', 0, 0)
}

@['/api/bot/:key/rooms/:room/messages'; post]
pub fn (app &App) bot_messages_create(mut ctx Context, key string, room int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'create', 0, 0)
}

@['/api/bot/:key/rooms/:room/messages/:id'; patch]
pub fn (app &App) bot_messages_update(mut ctx Context, key string, room int, id int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'update', id, 0)
}

@['/api/bot/:key/rooms/:room/messages/:id'; delete]
pub fn (app &App) bot_messages_delete(mut ctx Context, key string, room int, id int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'delete', id, 0)
}

@['/api/bot/:key/rooms/:room/messages/:id/boosts'; post]
pub fn (app &App) bot_boosts_create(mut ctx Context, key string, room int, id int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'boost', id, 0)
}

@['/api/bot/:key/rooms/:room/messages/:id/boosts/:boost'; delete]
pub fn (app &App) bot_boosts_delete(mut ctx Context, key string, room int, id int, boost int) veb.Result {
	return bot_request(mut ctx, app, key, room, 'unboost', id, boost)
}
