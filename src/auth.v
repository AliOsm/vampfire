module main

import crypto.bcrypt
import crypto.rand
import crypto.sha256
import json2 as json
import time
import veb

fn token() string {
	return (rand.bytes(32) or { panic('Operating system random source failed.') }).hex()
}

fn digest(value string) string { return sha256.sum(value.bytes()).hex() }

fn authenticate(mut ctx Context, db &Database) ! {
	raw := ctx.get_cookie('vampfire_session') or { return error_with_code('Please sign in.', 401) }
	if raw.len != 64 { return error_with_code('Please sign in.', 401) }
	row := one(db, "SELECT u.*,s.csrf,s.token,s.active_at FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND s.expires_at>? AND u.status='active' AND u.role!='bot'", digest(raw), time.now().unix().str()) or {
		return error_with_code('Please sign in.', 401)
	}
	ctx.user = user_from(row)
	ctx.session_hash = row.get_string('token')
	ctx.csrf = row.get_string('csrf')
	if row.get_string('active_at').i64() < time.now().unix() - 600 {
		execute(db, 'UPDATE sessions SET active_at=? WHERE token=?', time.now().unix().str(), ctx.session_hash)!
	}
}

fn start_session(mut ctx Context, db &Database, user_id int) ! {
	raw := token()
	now := time.now().unix()
	csrf := token()
	execute(db, 'INSERT INTO sessions(token,user_id,csrf,ip,agent,created_at,active_at,expires_at) VALUES(?,?,?,?,?,?,?,?)', digest(raw), user_id.str(), csrf, ctx.client_ip, ctx.user_agent(), now.str(), now.str(), (now + 630720000).str())!
	ctx.set_cookie(
		name:      'vampfire_session'
		value:     raw
		path:      '/'
		http_only: true
		secure:    ctx.secure_cookie
		same_site: .same_site_lax_mode
		max_age:   630720000
	)
	ctx.user = load_user(db, user_id)!
	ctx.csrf = csrf
	ctx.session_hash = digest(raw)
}

struct Credentials {
	name         string
	email        string
	password     string
	account_name string
	join_code    string
}

fn validate_credentials(input Credentials) ! {
	if input.name.trim_space().len < 1 || input.name.len > 100 {
		return error_with_code('Enter a name of up to 100 characters.', 422)
	}
	if !input.email.contains('@') || input.email.len > 254 || input.email.contains(' ') {
		return error_with_code('Enter a valid email address.', 422)
	}
	if input.password.len < 8 || input.password.len > 72 {
		return error_with_code('Use a password between 8 and 72 bytes.', 422)
	}
}

@['/api/setup'; post]
pub fn (app &App) setup(mut ctx Context) veb.Result {
	return respond(mut ctx, app, setup_account, true)
}

fn setup_account(mut ctx Context, app &App, db &Database) !string {
	input := body[Credentials](ctx)!
	validate_credentials(input)!
	if exists(db, 'SELECT 1 FROM account') {
		return error_with_code('This workspace is already set up.', 409)
	}
	hash := bcrypt.generate_from_password(input.password.bytes(), 12)!
	now := time.now().unix_milli().str()
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	if exists(db, 'SELECT 1 FROM account') {
		return error_with_code('This workspace is already set up.', 409)
	}
	name := if input.account_name.trim_space() != '' {
		input.account_name.trim_space()
	} else {
		'Vampfire'
	}
	if name.len > 100 {
		return error_with_code('Use a workspace name of up to 100 characters.', 422)
	}
	execute(db, 'INSERT INTO account(id,name,join_code) VALUES(1,?,?)', name, token()[..24])!
	execute(db, "INSERT INTO users(name,email,password,role,created_at) VALUES(?,?,?,'administrator',?)", input.name.trim_space(), input.email.trim_space().to_lower(), hash, now)!
	user_id := int(db.last_insert_rowid())
	execute(db, "INSERT INTO rooms(name,kind,creator_id,created_at,updated_at) VALUES('All Talk','open',?,?,?)", user_id.str(), now, now)!
	execute(db, 'INSERT INTO memberships(room_id,user_id) VALUES(?,?)', db.last_insert_rowid().str(), user_id.str())!
	start_session(mut ctx, db, user_id)!
	db.exec('COMMIT')!
	ctx.res.set_status(.created)
	return bootstrap_data(mut ctx, app, db)
}

@['/api/session'; post]
pub fn (app &App) login(mut ctx Context) veb.Result {
	return respond(mut ctx, app, login_user, true)
}

fn login_user(mut ctx Context, app &App, db &Database) !string {
	rate_limit(db, 'login:${ctx.client_ip}', 10, 180)!
	if exists(db, 'SELECT 1 FROM bans WHERE ip=?', ctx.client_ip) {
		return error_with_code('Sign-in is unavailable.', 403)
	}
	input := body[Credentials](ctx)!
	rows := query(db, "SELECT * FROM users WHERE email=? AND status='active' AND role!='bot'", input.email.trim_space().to_lower())!
	if rows.len == 0 {
		bcrypt.compare_hash_and_password(input.password.bytes(), app.dummy_password.bytes()) or {}
		return error_with_code('Email or password is incorrect.', 401)
	}
	bcrypt.compare_hash_and_password(input.password.bytes(), rows[0].get_string('password').bytes()) or { return error_with_code('Email or password is incorrect.', 401) }
	start_session(mut ctx, db, rows[0].get_int('id'))!
	return bootstrap_data(mut ctx, app, db)
}

@['/api/join'; post]
pub fn (app &App) signup(mut ctx Context) veb.Result {
	return respond(mut ctx, app, join_account, true)
}

fn join_account(mut ctx Context, app &App, db &Database) !string {
	rate_limit(db, 'join:${ctx.client_ip}', 10, 180)!
	if exists(db, 'SELECT 1 FROM bans WHERE ip=?', ctx.client_ip) {
		return error_with_code('Sign-up is unavailable.', 403)
	}
	input := body[Credentials](ctx)!
	validate_credentials(input)!
	account := load_account(db)!
	if input.join_code != account.join_code {
		return error_with_code('This invitation is no longer valid.', 404)
	}
	if exists(db, 'SELECT 1 FROM users WHERE email=?', input.email.trim_space()) {
		return error_with_code('This email is already registered. Sign in instead.', 409)
	}
	hash := bcrypt.generate_from_password(input.password.bytes(), 12)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	if !exists(db, 'SELECT 1 FROM account WHERE join_code=?', input.join_code) {
		return error_with_code('This invitation is no longer valid.', 404)
	}
	execute(db, 'INSERT INTO users(name,email,password,created_at) VALUES(?,?,?,?)', input.name.trim_space(), input.email.trim_space().to_lower(), hash, time.now().unix_milli().str())!
	uid := int(db.last_insert_rowid())
	execute(db, "INSERT INTO memberships(room_id,user_id) SELECT id,? FROM rooms WHERE kind='open'", uid.str())!
	start_session(mut ctx, db, uid)!
	db.exec('COMMIT')!
	app.publish_users(db)
	ctx.res.set_status(.created)
	return bootstrap_data(mut ctx, app, db)
}

@['/api/session'; delete]
pub fn (app &App) logout(mut ctx Context) veb.Result {
	return respond(mut ctx, app, logout_user, false)
}

fn logout_user(mut ctx Context, app &App, db &Database) !string {
	execute(db, 'DELETE FROM sessions WHERE token=?', ctx.session_hash)!
	ctx.set_cookie(name: 'vampfire_session', value: '', path: '/', http_only: true, max_age: -1)
	app.disconnect_session(ctx.session_hash)
	return json.encode(Success{})
}

@['/api/transfers'; post]
pub fn (app &App) transfer_create(mut ctx Context) veb.Result {
	return respond(mut ctx, app, create_transfer, false)
}

fn create_transfer(mut ctx Context, _app &App, db &Database) !string {
	value := token()
	execute(db, 'INSERT INTO transfers(token,user_id,expires_at) VALUES(?,?,?)', digest(value), ctx.user.id.str(), (time.now().unix() + 14400).str())!
	return json.encode({
		'token': value
	})
}

struct TransferInput {
	token string
}

@['/api/transfers/redeem'; post]
pub fn (app &App) transfer_redeem(mut ctx Context) veb.Result {
	return respond(mut ctx, app, redeem_transfer, true)
}

fn redeem_transfer(mut ctx Context, app &App, db &Database) !string {
	rate_limit(db, 'transfer:${ctx.client_ip}', 10, 180)!
	input := body[TransferInput](ctx)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	r := one(db, "SELECT t.user_id FROM transfers t JOIN users u ON u.id=t.user_id WHERE t.token=? AND t.expires_at>? AND u.status='active'", digest(input.token), time.now().unix().str()) or { return error_with_code('This sign-in link has expired or was already used.', 400) }
	execute(db, 'DELETE FROM transfers WHERE token=?', digest(input.token))!
	start_session(mut ctx, db, r.get_int('user_id'))!
	db.exec('COMMIT')!
	return bootstrap_data(mut ctx, app, db)
}
