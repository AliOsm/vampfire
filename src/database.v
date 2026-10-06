module main

import db.sqlite
import os
import time

fn query(db sqlite.DB, statement string, values ...string) ![]sqlite.Row {
	return db.exec_param_many(statement, values)
}

fn one(db sqlite.DB, statement string, values ...string) !sqlite.Row {
	rows := query(db, statement, ...values)!
	if rows.len == 0 { return error_with_code('Not found.', 404) }
	return rows[0]
}

fn execute(db sqlite.DB, statement string, values ...string) ! {
	query(db, statement, ...values)!
}

fn exists(db sqlite.DB, statement string, values ...string) bool {
	rows := query(db, statement, ...values) or { return false }
	return rows.len > 0
}

fn open_database(directory string) !sqlite.DB {
	os.mkdir_all(directory)!
	db := sqlite.connect(os.join_path(directory, 'vampfire.sqlite3'))!
	db.busy_timeout(5000)
	db.exec('PRAGMA journal_mode=WAL')!
	db.exec('PRAGMA foreign_keys=ON')!
	db.exec('PRAGMA synchronous=NORMAL')!
	db.exec('PRAGMA cache_size=-4096')!
	return db
}

fn migrate(db sqlite.DB) ! {
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

fn load_account(db sqlite.DB) !Account {
	r := one(db, 'SELECT * FROM account WHERE id=1')!
	return Account{
		name:           r.get_string('name')
		join_code:      r.get_string('join_code')
		restrict_rooms: r.get_int('restrict_rooms') == 1
		logo_id:        r.get_int('logo_id')
	}
}

fn load_user(db sqlite.DB, id int) !User {
	return user_from(one(db, 'SELECT * FROM users WHERE id=?', id.str())!)
}

fn require_admin(user User) ! {
	if user.role != 'administrator' {
		return error_with_code('Administrator access is required.', 403)
	}
}

fn room_for(db sqlite.DB, user_id int, room_id int) !Room {
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

fn queue_job(db sqlite.DB, kind string, payload string) ! {
	execute(db, 'INSERT INTO jobs(kind,payload,available_at) VALUES(?,?,?)', kind, payload, time.now().unix().str())!
}
