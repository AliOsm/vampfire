module main

import crypto.bcrypt
import json2 as json
import veb

@['/api/users'; get; head]
pub fn (app &App) users_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, list_users, false)
}

fn list_users(mut ctx Context, _app &App, db &Database) !string {
	q := ctx.query['q']
	if q.len > 100 { return error_with_code('Use a shorter name.', 422) }
	page := ctx.query['page'].int()
	if page < 0 || page > 100000 { return error_with_code('Invalid directory page.', 422) }
	mut users := []User{}
	for r in query(db, "SELECT * FROM users WHERE (status='active' OR ?='administrator') AND name LIKE ? ORDER BY lower(name),id LIMIT 500 OFFSET ?", ctx.user.role, '%${q}%', (page * 500).str())! {
		mut user := user_from(r)
		if ctx.user.role != 'administrator' && user.id != ctx.user.id { user.email = '' }
		users << user
	}
	return json.encode(users)
}

struct ProfileInput {
	name      string
	email     string
	bio       string
	password  string
	avatar_id int
}

@['/api/profile'; patch]
pub fn (app &App) profile_update(mut ctx Context) veb.Result {
	return respond(mut ctx, app, update_profile, false)
}

fn update_profile(mut ctx Context, app &App, db &Database) !string {
	input := body[ProfileInput](ctx)!
	if input.name.trim_space() == '' || input.name.len > 100 || input.bio.len > 500 || !input.email.contains('@') || input.email.len > 254 {
		return error_with_code('Check your name, email, and bio.', 422)
	}
	if exists(db, 'SELECT 1 FROM users WHERE email=? AND id!=?', input.email.trim_space(), ctx.user.id.str()) {
		return error_with_code('That email is already in use.', 409)
	}
	mut hash := ''
	if input.password != '' {
		if input.password.len < 8 || input.password.len > 72 {
			return error_with_code('Use a password between 8 and 72 bytes.', 422)
		}
		hash = bcrypt.generate_from_password(input.password.bytes(), 12)!
	}
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	if input.avatar_id > 0 { require_image_upload(db, ctx.user.id, input.avatar_id)! }
	execute(db, 'UPDATE users SET name=?,email=?,bio=?,avatar_id=? WHERE id=?', input.name.trim_space(), input.email.trim_space().to_lower(), input.bio, input.avatar_id.str(), ctx.user.id.str())!
	if hash != '' {
		execute(db, 'UPDATE users SET password=? WHERE id=?', hash, ctx.user.id.str())!
		execute(db, 'DELETE FROM sessions WHERE user_id=? AND token!=?', ctx.user.id.str(), ctx.session_hash)!
		execute(db, 'DELETE FROM transfers WHERE user_id=?', ctx.user.id.str())!
	}
	db.exec('COMMIT')!
	if hash != '' { app.disconnect_user(ctx.user.id) }
	app.publish_users(db)
	return json.encode(load_user(db, ctx.user.id)!)
}

struct AccountInput {
	name           string
	restrict_rooms bool
	logo_id        int
	custom_css     string
}

struct AccountDetails {
	account    Account
	custom_css string
}

@['/api/account']
pub fn (app &App) account_show(mut ctx Context) veb.Result {
	return respond(mut ctx, app, show_account, false)
}

fn show_account(mut _ctx Context, _app &App, db &Database) !string {
	return json.encode(AccountDetails{ account: load_account(db)!, custom_css: one(db, 'SELECT custom_css FROM account WHERE id=1')!.get_string('custom_css') })
}

@['/api/account'; patch]
pub fn (app &App) account_update(mut ctx Context) veb.Result {
	return respond(mut ctx, app, update_account, false)
}

fn update_account(mut ctx Context, app &App, db &Database) !string {
	require_admin(ctx.user)!
	input := body[AccountInput](ctx)!
	if input.name.trim_space() == '' || input.name.len > 100 || input.custom_css.len > 16000 {
		return error_with_code('Check the workspace name and stylesheet size.', 422)
	}
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	if input.logo_id > 0 && input.logo_id != load_account(db)!.logo_id {
		require_image_upload(db, ctx.user.id, input.logo_id)!
	}
	execute(db, 'UPDATE account SET name=?,restrict_rooms=?,logo_id=?,custom_css=? WHERE id=1', input.name.trim_space(), int(input.restrict_rooms).str(), input.logo_id.str(), input.custom_css)!
	db.exec('COMMIT')!
	return show_account(mut ctx, app, db)
}

@['/api/account/invitation'; post]
pub fn (app &App) invitation_reset(mut ctx Context) veb.Result {
	return respond(mut ctx, app, reset_invitation, false)
}

fn reset_invitation(mut ctx Context, app &App, db &Database) !string {
	require_admin(ctx.user)!
	execute(db, 'UPDATE account SET join_code=? WHERE id=1', token()[..24])!
	return show_account(mut ctx, app, db)
}

@['/custom.css']
pub fn (app &App) custom_styles(mut ctx Context) veb.Result {
	db := app.database.session()
	r := one(db, 'SELECT custom_css FROM account WHERE id=1') or { return ctx.send_response_to_client('text/css', '') }
	return ctx.send_response_to_client('text/css', r.get_string('custom_css'))
}

struct ManageUser {
	role   string
	action string
}

@['/api/users/:id'; patch]
pub fn (app &App) user_manage(mut ctx Context, id int) veb.Result {
	ctx.entity_id = id
	return respond(mut ctx, app, manage_user, false)
}

fn manage_user(mut ctx Context, app &App, db &Database) !string {
	require_admin(ctx.user)!
	input := body[ManageUser](ctx)!
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	user := load_user(db, ctx.entity_id)!
	if user.id == ctx.user.id {
		return error_with_code('Ask another administrator to change your access.', 422)
	}
	if input.action == 'role' {
		if input.role !in ['member', 'administrator'] || user.role == 'bot' {
			return error_with_code('Invalid role.', 422)
		}
		execute(db, 'UPDATE users SET role=? WHERE id=?', input.role, user.id.str())!
	} else if input.action == 'ban' {
		for session in query(db, 'SELECT DISTINCT ip FROM sessions WHERE user_id=?', user.id.str())! {
			if public_ipv4(session.get_string('ip')) {
				execute(db, 'INSERT OR IGNORE INTO bans(user_id,ip) VALUES(?,?)', user.id.str(), session.get_string('ip'))!
			}
		}
		execute(db, "UPDATE users SET status='banned' WHERE id=?", user.id.str())!
		execute(db, 'DELETE FROM message_fts WHERE rowid IN(SELECT id FROM messages WHERE user_id=?)', user.id.str())!
		execute(db, 'DELETE FROM messages WHERE user_id=?', user.id.str())!
	} else if input.action == 'unban' {
		execute(db, 'DELETE FROM bans WHERE user_id=?', user.id.str())!
		execute(db, "UPDATE users SET status='active' WHERE id=?", user.id.str())!
	} else if input.action == 'deactivate' {
		execute(db, "UPDATE users SET status='deactivated',email=coalesce(email,'')||'-deactivated-'||id WHERE id=?", user.id.str())!
		execute(db, "DELETE FROM memberships WHERE user_id=? AND room_id IN(SELECT id FROM rooms WHERE kind!='direct')", user.id.str())!
		execute(db, 'DELETE FROM searches WHERE user_id=?', user.id.str())!
	} else {
		return error_with_code('Unknown account action.', 422)
	}
	if input.action in ['ban', 'deactivate'] {
		execute(db, 'DELETE FROM sessions WHERE user_id=?', user.id.str())!
		execute(db, 'DELETE FROM transfers WHERE user_id=?', user.id.str())!
		execute(db, 'DELETE FROM subscriptions WHERE user_id=?', user.id.str())!
	}
	db.exec('COMMIT')!
	app.disconnect_user(user.id)
	mut ids := []int{}
	for r in query(db, "SELECT id FROM users WHERE status='active'")! { ids << r.get_int('id') }
	app.deliver(ids, Event{ kind: 'refresh' })
	return json.encode(load_user(db, user.id)!)
}

struct SessionInfo {
	token     string
	agent     string
	ip        string
	active_at i64
	current   bool
}

@['/api/sessions']
pub fn (app &App) sessions_index(mut ctx Context) veb.Result {
	return respond(mut ctx, app, list_sessions, false)
}

fn list_sessions(mut ctx Context, _app &App, db &Database) !string {
	mut result := []SessionInfo{}
	for r in query(db, 'SELECT * FROM sessions WHERE user_id=? ORDER BY active_at DESC', ctx.user.id.str())! {
		result << SessionInfo{ token: r.get_string('token'), agent: r.get_string('agent'), ip: r.get_string('ip'), active_at: r.get_string('active_at').i64(), current: r.get_string('token') == ctx.session_hash }
	}
	return json.encode(result)
}

struct RevokeSession {
	token string
}

@['/api/sessions'; delete]
pub fn (app &App) sessions_revoke(mut ctx Context) veb.Result {
	return respond(mut ctx, app, revoke_session, false)
}

fn revoke_session(mut ctx Context, app &App, db &Database) !string {
	input := body[RevokeSession](ctx)!
	execute(db, 'DELETE FROM sessions WHERE token=? AND user_id=?', input.token, ctx.user.id.str())!
	app.disconnect_session(input.token)
	return json.encode(Success{})
}
