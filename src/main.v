module main

import crypto.bcrypt
import db.sqlite
import net.websocket
import os
import time
import veb

@[heap]
pub struct App {
	veb.StaticHandler
	veb.Middleware[Context]
	connections     chan sqlite.DB
	commands        chan Command
	hub             &Hub
	data_dir        string
	base_url        string
	trusted_proxies []string
	dummy_password  string
	push_public     string
	push_private    string
pub mut:
	reactor &websocket.Reactor = unsafe { nil }
}

fn main() {
	data := os.getenv_opt('VAMPFIRE_DATA') or { '.data' }
	mut db := open_database(data) or { panic(err) }
	migrate(db) or { panic(err) }
	db.close() or {}
	os.mkdir_all(os.join_path(data, 'uploads')) or { panic(err) }
	os.mkdir_all(os.join_path(data, 'tmp')) or { panic(err) }
	port := (os.getenv_opt('PORT') or { '8080' }).int()
	mut app := &App{
		connections:     chan sqlite.DB{cap: 4}
		commands:        chan Command{cap: 1024}
		hub:             &Hub{}
		data_dir:        os.real_path(data)
		base_url:        os.getenv_opt('BASE_URL') or { 'http://localhost:${port}' }
		trusted_proxies: os.getenv('TRUSTED_PROXIES').split(',').map(it.trim_space()).filter(it != '')
		dummy_password:  bcrypt.generate_from_password(token().bytes(), 12) or { panic(err) }
		push_public:     os.getenv('VAPID_PUBLIC_KEY')
		push_private:    os.getenv('VAPID_PRIVATE_KEY')
	}
	for _ in 0 .. 4 { app.connections <- open_database(data) or { panic(err) } }
	app.use(handler: request_headers)
	app.mount_static_folder_at('public', '/assets') or { panic(err) }
	app.reactor = websocket.new_reactor(
		max_message_bytes: 4096
		max_connections:   2000
		max_pending_bytes: 1024 * 1024
		read_timeout:      70 * time.second
		on_message:        socket_message
		on_close:          socket_closed
		user:              app
	) or { panic(err) }
	spawn app.reactor.run()
	spawn socket_worker(app)
	spawn job_worker(app)
	println('Vampfire: ${app.base_url}')
	veb.run_at[App, Context](mut app,
		host:                    os.getenv_opt('BIND') or { '127.0.0.1' }
		port:                    port
		family:                  .ip
		nr_workers:              4
		max_request_buffer_size: 17 * 1024 * 1024
	) or { panic(err) }
}

@['/']
pub fn (app &App) index(mut ctx Context) veb.Result {
	return ctx.html($embed_file('../public/index.html').to_string())
}

@['/rooms/:id']
pub fn (app &App) room_page(mut ctx Context, id int) veb.Result { return app.index(mut ctx) }

@['/join/:code']
pub fn (app &App) join_page(mut ctx Context, code string) veb.Result { return app.index(mut ctx) }

@['/transfer/:code']
pub fn (app &App) transfer_page(mut ctx Context, code string) veb.Result {
	return app.index(mut ctx)
}

@['/search']
pub fn (app &App) search_page(mut ctx Context) veb.Result { return app.index(mut ctx) }

@['/settings']
pub fn (app &App) settings_page(mut ctx Context) veb.Result { return app.index(mut ctx) }
