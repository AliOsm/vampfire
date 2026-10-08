module main

import db.sqlite
import time

fn one(db &Database, statement string, values ...string) !sqlite.Row {
	rows := query(db, statement, ...values)!
	if rows.len == 0 { return error_with_code('Not found.', 404) }
	return rows[0]
}

fn execute(db &Database, statement string, values ...string) ! {
	query(db, statement, ...values)!
}

fn exists(db &Database, statement string, values ...string) bool {
	rows := query(db, statement, ...values) or { return false }
	return rows.len > 0
}

fn migrate(db &Database) ! {
	version := db.q_int('PRAGMA user_version')!
	if version > 1 { return error('Database is newer than this application.') }
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	for statement in $embed_file('schema.sql').to_string().split(';') {
		if statement.trim_space() != '' { db.exec(statement)! }
	}
	db.exec('COMMIT')!
}

fn user_from(row sqlite.Row) User {
	return User{
		id:        row.get_int('id')
		name:      row.get_string('name')
		email:     row.get_string('email')
		bio:       row.get_string('bio')
		role:      row.get_string('role')
		status:    row.get_string('status')
		avatar_id: row.get_int('avatar_id')
	}
}

fn load_account(db &Database) !Account {
	r := one(db, 'SELECT * FROM account WHERE id=1')!
	return Account{
		name:           r.get_string('name')
		join_code:      r.get_string('join_code')
		restrict_rooms: r.get_int('restrict_rooms') == 1
		logo_id:        r.get_int('logo_id')
	}
}

fn load_user(db &Database, id int) !User {
	return user_from_values(one(db, 'SELECT id,name,email,bio,role,status,avatar_id FROM users WHERE id=?', id.str())!.vals)
}

fn require_admin(user User) ! {
	if user.role != 'administrator' {
		return error_with_code('Administrator access is required.', 403)
	}
}

fn room_for(db &Database, user_id int, room_id int) !Room {
	r := one(db, 'SELECT r.*,m.involvement,m.read_id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?', room_id.str(), user_id.str())!
	mut room := Room{
		id:          r.get_int('id')
		name:        r.get_string('name')
		kind:        r.get_string('kind')
		creator_id:  r.get_int('creator_id')
		involvement: r.get_string('involvement')
	}
	for member in query(db, 'SELECT user_id FROM memberships WHERE room_id=? ORDER BY user_id', room_id.str())! {
		room.members << member.get_int('user_id')
	}
	if room.kind == 'direct' {
		mut names := []string{}
		for person in query(db, 'SELECT u.name FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.id!=? ORDER BY lower(u.name)', room_id.str(), user_id.str())! {
			names << person.get_string('name')
		}
		room.name = if names.len > 0 { names.join(', ') } else { 'Just you' }
	}
	return room
}

fn require_room_admin(user User, room Room) ! {
	if user.role != 'administrator' && user.id != room.creator_id {
		return error_with_code('Only the room creator or an administrator can do that.', 403)
	}
}

fn queue_job(db &Database, kind string, payload string) ! {
	execute(db, 'INSERT INTO jobs(kind,payload,available_at) VALUES(?,?,?)', kind, payload, time.now().unix().str())!
	db.wake_job(kind)
}

fn sql_placeholders(count int) string { return []string{len: count, init: '?'}.join(',') }

fn require_membership(db &Database, user_id int, room_id int) ! {
	one(db, 'SELECT 1 FROM memberships WHERE room_id=? AND user_id=?', room_id.str(), user_id.str())!
}

fn user_from_values(values []string) User {
	return User{ id: values[0].int(), name: values[1], email: values[2], bio: values[3], role: values[4], status: values[5], avatar_id: values[6].int() }
}
