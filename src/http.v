module main

import json2 as json
import net
import net.http
import time
import veb

pub struct Context {
	veb.Context
pub mut:
	user          User
	session_hash  string
	csrf          string
	entity_id     int
	parent_id     int
	client_ip     string
	secure_cookie bool
}

type Handler = fn (mut Context, &App, &Database) !string

fn (mut ctx Context) problem(err IError) veb.Result {
	mut status := err.code()
	if status < 400 || status > 599 {
		eprintln('Request failed: ${err}')
		status = 500
	}
	ctx.res.set_status(unsafe { http.Status(status) })
	return ctx.json(ApiError{
		error: if status == 500 {
			'Something went wrong. Please try again.'
		} else {
			err.msg()
		}
	})
}

fn body[T](ctx &Context) !T {
	if ctx.req.data.len > 65536 { return error_with_code('Request is too large.', 413) }
	return json.decode[T](ctx.req.data) or { return error_with_code('Invalid JSON request.', 400) }
}

fn respond(mut ctx Context, app &App, handler Handler, public bool) veb.Result {
	ctx.client_ip = request_ip(ctx, app)
	ctx.secure_cookie = app.base_url.starts_with('https://')
	db := app.database.session()
	if !public {
		authenticate(mut ctx, db) or { return ctx.problem(err) }
		if ctx.user.role == 'bot' {
			return ctx.problem(error_with_code('Bots must use the bot API.', 403))
		}
		if ctx.req.method !in [.get, .head] {
			if (ctx.get_custom_header('X-CSRF-Token') or { '' }) != ctx.csrf {
				return ctx.problem(error_with_code('Refresh the page and try again.', 403))
			}
		}
	}
	result := handler(mut ctx, app, db) or { return ctx.problem(err) }
	return ctx.send_response_to_client('application/json', result)
}

fn request_ip(ctx &Context, app &App) string {
	mut peer := ''
	if ctx.conn != unsafe { nil } {
		peer = ctx.conn.peer_ip() or { '' }
	} else if ctx.client_fd >= 0 {
		address := net.peer_addr_from_socket_handle(ctx.client_fd) or { return '' }.str()
		peer = if address.contains(']:') {
			address.all_before(']:').all_after('[')
		} else {
			address.all_before(':')
		}
	}
	if peer in app.trusted_proxies {
		forwarded := (ctx.get_header(.x_forwarded_for) or { '' }).split(',').map(it.trim_space())
		// Walk from the trusted immediate peer towards the original client.
		for i := forwarded.len - 1; i >= 0; i-- {
			if forwarded[i] != '' && forwarded[i] !in app.trusted_proxies { return forwarded[i] }
		}
	}
	return peer
}

fn request_headers(mut ctx Context) bool {
	ctx.set_header(.cache_control, 'no-store')
	ctx.set_custom_header('X-Content-Type-Options', 'nosniff') or {}
	ctx.set_custom_header('Referrer-Policy', 'same-origin') or {}
	ctx.set_custom_header('X-Frame-Options', 'DENY') or {}
	ctx.set_custom_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'") or {}
	if ctx.req.method !in [.get, .head, .options] {
		origin := ctx.get_header(.origin) or { '' }
		host := ctx.get_header(.host) or { '' }
		fetch_site := ctx.get_custom_header('Sec-Fetch-Site') or { '' }
		if fetch_site == 'cross-site' || (origin != '' && origin !in [
			'http://${host}',
			'https://${host}',
		]) {
			ctx.problem(error_with_code('Cross-origin request rejected.', 403))
			return false
		}
	}
	return true
}

@['/up']
pub fn (app &App) health(mut ctx Context) veb.Result {
	return ctx.json(Success{})
}

@['/api/bootstrap']
pub fn (app &App) bootstrap(mut ctx Context) veb.Result {
	return respond(mut ctx, app, bootstrap_data, true)
}

struct Bootstrap {
	setup    bool
	account  Account
	user     User
	csrf     string
	push_key string
}

fn bootstrap_data(mut ctx Context, app &App, db &Database) !string {
	if !exists(db, 'SELECT 1 FROM account') { return json.encode(Bootstrap{ setup: true }) }
	account := load_account(db)!
	authenticate(mut ctx, db) or {}
	return json.encode(Bootstrap{
		account:  Account{
			name:           account.name
			logo_id:        account.logo_id
			restrict_rooms: account.restrict_rooms
		}
		user:     ctx.user
		csrf:     ctx.csrf
		push_key: app.push_public
	})
}

fn rate_limit(db &Database, key string, limit int, seconds int) ! {
	now := time.now().unix()
	execute(db, 'INSERT INTO rate_limits(key,count,reset_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN reset_at<? THEN 1 ELSE count+1 END, reset_at=CASE WHEN reset_at<? THEN excluded.reset_at ELSE reset_at END', key, (now + seconds).str(), now.str(), now.str())!
	r := one(db, 'SELECT count FROM rate_limits WHERE key=?', key)!
	if r.get_int('count') > limit {
		return error_with_code('Too many attempts. Please wait a few minutes.', 429)
	}
}
