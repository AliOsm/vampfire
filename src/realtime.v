module main

import crypto.sha1
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
	mu       sync.Mutex
	peers    map[string]Peer
	by_user  map[int][]string
	by_room  map[int][]string
	presence map[int][]int
	close_failures int
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

fn socket_closed(mut client websocket.ReactorClient, code int, reason string, ref voidptr) {
	app := unsafe { &App(ref) }
	mut hub := app.hub
	hub.mu.lock()
	room_id := if peer := hub.peers[client.id] { peer.room_id } else { 0 }
	if code !in [1000, 1001] { hub.close_failures++ }
	log_failure := code !in [1000, 1001] && hub.close_failures <= 5
	hub.remove(client.id)
	hub.mu.unlock()
	if log_failure { eprintln('WebSocket closed: ${code} ${reason}') }
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
	db := app.database.session()
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
	hub.by_user[ctx.user.id] << client.id
	hub.mu.unlock()
	return veb.no_result()
}

fn (app &App) deliver(users []int, event Event) {
	text := json.encode(event)
	mut clients := []&websocket.ReactorClient{}
	mut hub := app.hub
	hub.mu.lock()
	for user_id in users {
		for key in hub.by_user[user_id] {
			if peer := hub.peers[key] { clients << peer.client }
		}
	}
	hub.mu.unlock()
	// Reactor commands can wake callbacks; never enqueue while holding hub.mu.
	for client in clients { send_event(client, text) }
}

fn send_event(client &websocket.ReactorClient, text string) {
	mut socket := unsafe { &websocket.ReactorClient(client) }
	socket.write_string(text) or {
		socket.close(1013, 'Connection is too slow.') or {}
		0
	}
}

// Caller owns hub.mu. Remove stale index entries as well as the peer.
fn (mut hub Hub) remove(key string) {
	if peer := hub.peers[key] {
		hub.by_user[peer.user_id] = hub.by_user[peer.user_id].filter(it != key)
		if hub.by_user[peer.user_id].len == 0 { hub.by_user.delete(peer.user_id) }
		if peer.room_id > 0 {
			hub.by_room[peer.room_id] = hub.by_room[peer.room_id].filter(it != key)
			if hub.by_room[peer.room_id].len == 0 { hub.by_room.delete(peer.room_id) }
		}
		hub.peers.delete(key)
	}
}

fn (app &App) publish_room(db &Database, room_id int, event Event) {
	rows := query(db, "SELECT m.user_id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND u.status='active'", room_id.str()) or { return }
	app.deliver(rows.map(it.get_int('user_id')), event)
}

fn (app &App) publish_users(db &Database) {
	rows := query(db, "SELECT id FROM users WHERE status='active' AND role!='bot'") or { return }
	app.deliver(rows.map(it.get_int('id')), Event{ kind: 'users' })
}

fn (app &App) disconnect_user(id int) { app.disconnect(id, '') }

fn (app &App) disconnect_session(session string) { app.disconnect(0, session) }

fn (app &App) disconnect(id int, session string) {
	mut hub := app.hub
	mut peers := []Peer{}
	hub.mu.lock()
	for key, peer in hub.peers {
		if (id > 0 && peer.user_id == id) || (session != '' && peer.session == session) {
			peers << peer
			hub.remove(key)
		}
	}
	hub.mu.unlock()
	for peer in peers {
		mut client := peer.client
		client.close(4001, 'Access changed. Please reconnect.') or {}
		if peer.room_id > 0 {
			select {
				app.commands <- Command{ closed: true, room_id: peer.room_id } {
				}
				else {
				}
			}
		}
	}
}

fn (app &App) active_users(room_id int) []int {
	mut result := []int{}
	mut seen := map[int]bool{}
	mut hub := app.hub
	now := time.now().unix()
	hub.mu.lock()
	defer { hub.mu.unlock() }
	for key in hub.by_room[room_id] {
		if peer := hub.peers[key] {
			if peer.seen > now - 60 && peer.user_id !in seen {
				result << peer.user_id
				seen[peer.user_id] = true
			}
		}
	}
	result.sort()
	return result
}

fn (app &App) publish_presence(db &Database, room_id int, subscriber string) {
	users := app.active_users(room_id)
	mut hub := app.hub
	hub.mu.lock()
	changed := (room_id in hub.presence && hub.presence[room_id] != users) || (room_id !in hub.presence && users.len > 0)
	if users.len == 0 { hub.presence.delete(room_id) } else { hub.presence[room_id] = users }
	peer := hub.peers[subscriber] or { Peer{ client: unsafe { nil } } }
	hub.mu.unlock()
	event := Event{ kind: 'presence', room_id: room_id, users: users }
	if changed {
		app.publish_room(db, room_id, event)
	} else if peer.client != unsafe { nil } {
		send_event(peer.client, json.encode(event))
	}
}

fn socket_worker(app &App) {
	for {
		command := <-app.commands or { return }
		process_command(app, command) or { eprintln('WebSocket command: ${err}') }
	}
}

fn process_command(app &App, command Command) ! {
	if command.closed {
		db := app.database.session()
		app.publish_presence(db, command.room_id, '')
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
	db := app.database.session()
	if !exists(db, "SELECT 1 FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status='active' AND s.expires_at>?", peer.session, time.now().unix().str()) {
		app.disconnect_session(peer.session)
		return
	}
	if input.type == 'subscribe' {
		if input.room_id > 0 {
			require_membership(db, peer.user_id, input.room_id) or {
				mut client := peer.client
				client.write_string(json.encode(Event{ kind: 'forbidden', room_id: input.room_id })) or {}
				return
			}
		}
		hub.mu.lock()
		if mut current := hub.peers[command.client_id] {
			if current.room_id != input.room_id {
				hub.by_room[current.room_id] = hub.by_room[current.room_id].filter(it != command.client_id)
				if hub.by_room[current.room_id].len == 0 { hub.by_room.delete(current.room_id) }
				if input.room_id > 0 { hub.by_room[input.room_id] << command.client_id }
			}
			current.room_id = input.room_id
			current.seen = time.now().unix()
			hub.peers[command.client_id] = current
		}
		hub.mu.unlock()
		if input.room_id > 0 {
			app.publish_presence(db, input.room_id, command.client_id)
		}
		if peer.room_id > 0 && peer.room_id != input.room_id {
			app.publish_presence(db, peer.room_id, '')
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
			app.publish_presence(db, peer.room_id, '')
		}
	} else if input.type in ['typing', 'stop_typing'] && peer.room_id > 0 {
		require_membership(db, peer.user_id, peer.room_id) or { return }
		user := load_user(db, peer.user_id)!
		app.publish_room(db, peer.room_id, Event{ kind: input.type, room_id: peer.room_id, user_id: peer.user_id, name: user.name })
	}
}
