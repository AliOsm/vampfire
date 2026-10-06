module main

import db.sqlite
import json2 as json
import time
import veb

@['/api/rooms']
pub fn (app &App) rooms_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, list_rooms, false)
}

fn list_rooms(mut ctx Context, _app &App, db sqlite.DB) !string {
	rows := query(db, "SELECT r.*,m.involvement,(SELECT count(*) FROM messages x WHERE x.room_id=r.id AND x.id>m.read_id AND x.user_id!=m.user_id) AS unread,(SELECT coalesce(max(id),0) FROM messages x WHERE x.room_id=r.id) AS last_id,(SELECT group_concat(user_id) FROM memberships WHERE room_id=r.id) AS members,(SELECT group_concat(u.name, ', ') FROM users u JOIN memberships k ON k.user_id=u.id WHERE k.room_id=r.id AND u.id!=m.user_id) AS direct_name FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.kind,lower(r.name),r.id", ctx.user.id.str())!
	mut rooms := []Room{}
	for r in rows {
		mut room := Room{
			id:          r.get_int('id')
			name:        r.get_string('name')
			kind:        r.get_string('kind')
			creator_id:  r.get_int('creator_id')
			involvement: r.get_string('involvement')
			unread:      r.get_int('unread')
			last_id:     r.get_int('last_id')
		}
		for id in r.get_string('members').split(',') { if id != '' { room.members << id.int() } }
		if room.kind == 'direct' { room.name = r.get_string('direct_name') }
		if room.name == '' { room.name = 'Just you' }
		rooms << room
	}
	return json.encode(rooms)
}

struct RoomInput {
	name        string
	kind        string
	members     []int
	involvement string
}

@['/api/rooms'; post]
pub fn (app &App) rooms_create(mut ctx Context) veb.Result {
	return respond(mut ctx, app, create_room, false)
}

fn create_room(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[RoomInput](ctx)!
	if input.kind !in ['open', 'closed', 'direct'] {
		return error_with_code('Choose a room type.', 422)
	}
	if input.kind != 'direct' && (input.name.trim_space() == '' || input.name.len > 120) {
		return error_with_code('Enter a room name of up to 120 characters.', 422)
	}
	account := load_account(db)!
	if input.kind != 'direct' && account.restrict_rooms { require_admin(ctx.user)! }
	mut members := [ctx.user.id]
	for id in input.members { if id !in members { members << id } }
	if members.len > 500 { return error_with_code('Select at most 500 people.', 422) }
	members.sort()
	key := members.map(it.str()).join(',')
	now := time.now().unix_milli().str()
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	for id in members {
		if !exists(db, "SELECT 1 FROM users WHERE id=? AND status='active'", id.str()) {
			return error_with_code('One of those people is no longer available.', 422)
		}
	}
	if input.kind == 'direct' {
		rows := query(db, 'SELECT id FROM rooms WHERE direct_key=?', key)!
		if rows.len > 0 {
			execute(db, "UPDATE memberships SET involvement='everything' WHERE room_id=? AND user_id=? AND involvement='invisible'", rows[0].get_int('id').str(), ctx.user.id.str())!
			db.exec('COMMIT')!
			return json.encode(room_for(db, ctx.user.id, rows[0].get_int('id'))!)
		}
	}
	execute(db, "INSERT INTO rooms(name,kind,creator_id,direct_key,created_at,updated_at) VALUES(?,?,?,nullif(?,''),?,?)", input.name.trim_space(), input.kind, ctx.user.id.str(), if input.kind == 'direct' {
		key
	} else {
		''
	}, now, now)!
	id := int(db.last_insert_rowid())
	if input.kind == 'open' {
		execute(db, "INSERT INTO memberships(room_id,user_id) SELECT ?,id FROM users WHERE status='active'", id.str())!
	} else {
		for member in members {
			execute(db, 'INSERT INTO memberships(room_id,user_id,involvement) VALUES(?,?,?)', id.str(), member.str(), if input.kind == 'direct' {
				'everything'
			} else {
				'mentions'
			})!
		}
	}
	db.exec('COMMIT')!
	app.publish_room(db, id, Event{ kind: 'rooms', room_id: id })
	ctx.res.set_status(.created)
	return json.encode(room_for(db, ctx.user.id, id)!)
}

@['/api/rooms/:id'; patch]
pub fn (app &App) rooms_update(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, update_room, false)
}

fn update_room(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[RoomInput](ctx)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	room := room_for(db, ctx.user.id, ctx.entity_id)!
	require_room_admin(ctx.user, room)!
	if room.kind == 'direct' {
		return error_with_code('A private conversation cannot change its participants or type. Start a new ping.', 422)
	}
	if input.kind !in ['open', 'closed'] || input.name.trim_space() == '' || input.name.len > 120 {
		return error_with_code('Enter a valid room name and type.', 422)
	}
	mut members := []int{}
	if input.kind == 'open' {
		for r in query(db, "SELECT id FROM users WHERE status='active'")! {
			if r.get_int('id') !in members { members << r.get_int('id') }
		}
	} else {
		for id in input.members {
			if id !in members && exists(db, "SELECT 1 FROM users WHERE id=? AND status='active'", id.str()) {
				members << id
			}
		}
	}
	execute(db, 'UPDATE rooms SET name=?,kind=?,updated_at=? WHERE id=?', input.name.trim_space(), input.kind, time.now().unix_milli().str(), room.id.str())!
	for id in members {
		execute(db, 'INSERT OR IGNORE INTO memberships(room_id,user_id) VALUES(?,?)', room.id.str(), id.str())!
	}
	for id in room.members {
		if id !in members {
			execute(db, 'DELETE FROM memberships WHERE room_id=? AND user_id=?', room.id.str(), id.str())!
		}
	}
	db.exec('COMMIT')!
	for id in room.members { if id !in members { app.disconnect_user(id) } }
	app.publish_room(db, room.id, Event{ kind: 'rooms', room_id: room.id })
	if ctx.user.id !in members {
		return json.encode(Room{ ...room, name: input.name.trim_space(), kind: input.kind, members: members })
	}
	return json.encode(room_for(db, ctx.user.id, room.id)!)
}

@['/api/rooms/:id'; delete]
pub fn (app &App) rooms_delete(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, delete_room, false)
}

fn delete_room(mut ctx Context, app &App, db sqlite.DB) !string {
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	room := room_for(db, ctx.user.id, ctx.entity_id)!
	if room.kind != 'direct' { require_room_admin(ctx.user, room)! }
	execute(db, 'DELETE FROM message_fts WHERE rowid IN(SELECT id FROM messages WHERE room_id=?)', room.id.str())!
	execute(db, 'DELETE FROM rooms WHERE id=?', room.id.str())!
	db.exec('COMMIT')!
	app.deliver(room.members, Event{ kind: 'room_deleted', room_id: room.id })
	return json.encode(Success{})
}

@['/api/rooms/:id/involvement'; patch]
pub fn (app &App) involvement_update(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, update_involvement, false)
}

fn update_involvement(mut ctx Context, app &App, db sqlite.DB) !string {
	input := body[RoomInput](ctx)!
	room_for(db, ctx.user.id, ctx.entity_id)!
	if input.involvement !in ['invisible', 'nothing', 'mentions', 'everything'] {
		return error_with_code('Unknown notification preference.', 422)
	}
	execute(db, 'UPDATE memberships SET involvement=? WHERE room_id=? AND user_id=?', input.involvement, ctx.entity_id.str(), ctx.user.id.str())!
	app.deliver([ctx.user.id], Event{ kind: 'rooms', room_id: ctx.entity_id })
	return json.encode(Success{})
}

@['/api/rooms/:id/read'; post]
pub fn (app &App) room_read(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, mark_read, false)
}

fn mark_read(mut ctx Context, app &App, db sqlite.DB) !string {
	room_for(db, ctx.user.id, ctx.entity_id)!
	execute(db, 'UPDATE memberships SET read_id=coalesce((SELECT max(id) FROM messages WHERE room_id=?),0) WHERE room_id=? AND user_id=?', ctx.entity_id.str(), ctx.entity_id.str(), ctx.user.id.str())!
	app.deliver([ctx.user.id], Event{ kind: 'read', room_id: ctx.entity_id })
	return json.encode(Success{})
}
