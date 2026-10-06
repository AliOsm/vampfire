module main

import crypto.sha1
import db.sqlite
import encoding.base64
import json2 as json
import net.websocket
import sync
import time
import veb

struct Event {
	kind       string
	room_id    int
	message_id int
	user_id    int
	name       string
	users      []int
	message    ChatMessage
}

struct Peer {
	client  &websocket.ReactorClient
	user_id int
	session string
mut:
	room_id int
	seen    i64
}

@[heap]
struct Hub {
mut:
	mu    sync.Mutex
	peers map[string]Peer
}

struct Command {
	client_id string
	text      string
	closed    bool
	room_id   int
}

struct SocketInput {
	type    string
	room_id int
}

fn socket_message(mut client websocket.ReactorClient, frame &websocket.Message, ref voidptr) {
	if frame.opcode != .text_frame { return }
	app := unsafe { &App(ref) }
	// Reactor payloads are borrowed. Clone before crossing to the application worker.
	command := Command{ client_id: client.id, text: frame.payload.bytestr().clone() }
	select {
		app.commands <- command {
		}
		else {
			client.close(1013, 'Try again shortly.') or {}
		}
	}
}

fn socket_closed(mut client websocket.ReactorClient, _code int, _reason string, ref voidptr) {
	app := unsafe { &App(ref) }
	mut hub := app.hub
	hub.mu.lock()
	room_id := if peer := hub.peers[client.id] { peer.room_id } else { 0 }
	hub.peers.delete(client.id)
	hub.mu.unlock()
	if room_id > 0 {
		select {
			app.commands <- Command{ closed: true, room_id: room_id } {
			}
			else {
			}
		}
	}
}

@['/ws']
pub fn (mut app App) websocket_upgrade(mut ctx Context) veb.Result {
	db := <-app.connections
	defer { app.connections <- db }
	authenticate(mut ctx, db) or { return ctx.problem(err) }
	origin := ctx.get_header(.origin) or { '' }
	host := ctx.get_header(.host) or { '' }
	if origin !in ['http://${host}', 'https://${host}'] {
		return ctx.problem(error_with_code('WebSocket origin rejected.', 403))
	}
	key := ctx.get_header(.sec_websocket_key) or { '' }
	connection_tokens := (ctx.get_header(.connection) or { '' }).to_lower().split(',').map(it.trim_space())
	if base64.decode(key).len != 16 || 'upgrade' !in connection_tokens || (ctx.get_header(.upgrade) or { '' }).to_lower() != 'websocket' || (ctx.get_custom_header('Sec-WebSocket-Version') or { '' }) != '13' {
		return ctx.problem(error_with_code('Invalid WebSocket handshake.', 400))
	}
	ctx.takeover_conn()
	accept := base64.encode(sha1.sum((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').bytes()))
	response := 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n'
	mut hub := app.hub
	hub.mu.lock()
	client := app.reactor.attach(mut ctx.conn, response) or {
		hub.mu.unlock()
		ctx.conn.close() or {}
		return veb.no_result()
	}
	hub.peers[client.id] = Peer{ client: client, user_id: ctx.user.id, session: ctx.session_hash, seen: time.now().unix() }
	hub.mu.unlock()
	return veb.no_result()
}

fn (app &App) deliver(users []int, event Event) {
	text := json.encode(event)
	mut hub := app.hub
	hub.mu.lock()
	defer { hub.mu.unlock() }
	for _, peer in hub.peers {
		if peer.user_id in users {
			mut client := peer.client
			client.write_string(text) or {
				client.close(1013, 'Connection is too slow.') or {}
				0
			}
		}
	}
}

fn (app &App) publish_room(db sqlite.DB, room_id int, event Event) {
	rows := query(db, "SELECT m.user_id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND u.status='active'", room_id.str()) or { return }
	app.deliver(rows.map(it.get_int('user_id')), event)
}

fn (app &App) publish_users(db sqlite.DB) {
	rows := query(db, "SELECT id FROM users WHERE status='active' AND role!='bot'") or { return }
	app.deliver(rows.map(it.get_int('id')), Event{ kind: 'users' })
}

fn (app &App) disconnect_user(id int) {
	mut hub := app.hub
	hub.mu.lock()
	defer { hub.mu.unlock() }
	for key, peer in hub.peers {
		if peer.user_id == id {
			mut client := peer.client
			client.close(4001, 'Access changed. Please reconnect.') or {}
			hub.peers.delete(key)
		}
	}
}

fn (app &App) disconnect_session(session string) {
	mut hub := app.hub
	hub.mu.lock()
	defer { hub.mu.unlock() }
	for key, peer in hub.peers {
		if peer.session == session {
			mut client := peer.client
			client.close(4001, 'Signed out.') or {}
			hub.peers.delete(key)
		}
	}
}

fn (app &App) active_users(room_id int) []int {
	mut result := []int{}
	mut hub := app.hub
	hub.mu.lock()
	defer { hub.mu.unlock() }
	for _, peer in hub.peers {
		if peer.room_id == room_id && peer.seen > time.now().unix() - 60 && peer.user_id !in result {
			result << peer.user_id
		}
	}
	return result
}

fn socket_worker(app &App) {
	for {
		command := <-app.commands or { return }
		process_command(app, command) or { eprintln('WebSocket command: ${err}') }
	}
}

fn process_command(app &App, command Command) ! {
	if command.closed {
		db := <-app.connections
		defer { app.connections <- db }
		app.publish_room(db, command.room_id, Event{ kind: 'presence', room_id: command.room_id, users: app.active_users(command.room_id) })
		return
	}
	mut hub := app.hub
	hub.mu.lock()
	peer := hub.peers[command.client_id] or {
		hub.mu.unlock()
		return
	}
	hub.mu.unlock()
	input := json.decode[SocketInput](command.text) or { return }
	db := <-app.connections
	defer { app.connections <- db }
	if !exists(db, "SELECT 1 FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status='active' AND s.expires_at>?", peer.session, time.now().unix().str()) {
		app.disconnect_session(peer.session)
		return
	}
	if input.type == 'subscribe' {
		if input.room_id > 0 {
			room_for(db, peer.user_id, input.room_id) or {
				mut client := peer.client
				client.write_string(json.encode(Event{ kind: 'forbidden', room_id: input.room_id })) or {}
				return
			}
		}
		hub.mu.lock()
		if mut current := hub.peers[command.client_id] {
			current.room_id = input.room_id
			current.seen = time.now().unix()
			hub.peers[command.client_id] = current
		}
		hub.mu.unlock()
		if input.room_id > 0 {
			app.publish_room(db, input.room_id, Event{ kind: 'presence', room_id: input.room_id, users: app.active_users(input.room_id) })
		}
		if peer.room_id > 0 && peer.room_id != input.room_id {
			app.publish_room(db, peer.room_id, Event{ kind: 'presence', room_id: peer.room_id, users: app.active_users(peer.room_id) })
		}
	} else if input.type == 'ping' {
		hub.mu.lock()
		if mut current := hub.peers[command.client_id] {
			current.seen = time.now().unix()
			hub.peers[command.client_id] = current
		}
		hub.mu.unlock()
		mut client := peer.client
		client.write_string('{"kind":"pong"}') or {}
		if peer.room_id > 0 {
			app.publish_room(db, peer.room_id, Event{ kind: 'presence', room_id: peer.room_id, users: app.active_users(peer.room_id) })
		}
	} else if input.type in ['typing', 'stop_typing'] && peer.room_id > 0 {
		room_for(db, peer.user_id, peer.room_id) or { return }
		user := load_user(db, peer.user_id)!
		app.publish_room(db, peer.room_id, Event{ kind: input.type, room_id: peer.room_id, user_id: peer.user_id, name: user.name })
	}
}
