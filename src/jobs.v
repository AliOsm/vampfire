module main

import json2 as json
import net.html
import net.urllib
import os
import time
import veb

fn start_jobs(app &App) {
	db := app.database.session()
	execute(db, 'UPDATE jobs SET locked_at=0 WHERE locked_at>0') or { eprintln(err) }
	// Keep external services and media from blocking each other. Media remains
	// single-worker because its subprocess has a separate bounded memory budget.
	for kind in ['media', 'notify', 'preview', 'push_test'] { spawn job_worker(app, kind) }
	for _ in 0 .. 2 {
		spawn job_worker(app, 'webhook')
		spawn job_worker(app, 'push')
	}
	spawn maintenance_worker(app)
}

fn maintenance_worker(app &App) {
	db := app.database.session()
	for {
		maintain_store(app, db) or { eprintln('Maintenance: ${err}') }
		time.sleep(3600 * time.second)
	}
}

fn job_worker(app &App, kind string) {
	db := app.database.session()
	wake := db.pool.job_wakes[kind] or { return }
	for {
		worked := run_next_job(app, db, kind) or {
			eprintln('Job worker: ${err}')
			false
		}
		if !worked {
			// A commit wakes the right workers immediately; the timeout catches
			// retries becoming due and work inserted by an external SQLite client.
			select {
				_ := <-wake {
				}
				1 * time.second {
				}
			}
		}
	}
}

fn run_next_job(app &App, db &Database, kind string) !bool {
	// Claim atomically: two workers must never execute the same queued attempt.
	// A read probe avoids a no-op write/commit on every idle poll.
	if !exists(db, 'SELECT 1 FROM jobs WHERE kind=? AND locked_at=0 AND attempts<5 AND available_at<=? LIMIT 1', kind, time.now().unix().str()) {
		return false
	}
	rows := query(db, 'UPDATE jobs SET locked_at=?,attempts=attempts+1 WHERE id=(SELECT id FROM jobs WHERE kind=? AND locked_at=0 AND attempts<5 AND available_at<=? ORDER BY id LIMIT 1) AND locked_at=0 RETURNING *', time.now().unix().str(), kind, time.now().unix().str())!
	if rows.len == 0 { return false }
	r := rows[0]
	id := r.get_int('id')
	execute_job(app, db, r.get_string('kind'), r.get_string('payload')) or {
		attempts := r.get_int('attempts')
		execute(db, 'UPDATE jobs SET locked_at=0,error=?,available_at=? WHERE id=?', err.msg().limit(500), (time.now().unix() + if attempts >= 5 {
			86400
		} else {
			attempts * 30
		}).str(), id.str())!
		return true
	}
	execute(db, 'DELETE FROM jobs WHERE id=?', id.str())!
	return true
}

fn maintain_store(app &App, db &Database) ! {
	now := time.now().unix()
	execute(db, 'DELETE FROM transfers WHERE expires_at<?', now.str())!
	execute(db, 'DELETE FROM sessions WHERE expires_at<?', now.str())!
	execute(db, 'DELETE FROM rate_limits WHERE reset_at<?', (now - 3600).str())!
	// Keep unclaimed uploads for a day so an interrupted send can be retried.
	for row in query(db, 'SELECT id,key,thumb FROM uploads a WHERE created_at<? AND NOT EXISTS(SELECT 1 FROM messages WHERE upload_id=a.id) AND NOT EXISTS(SELECT 1 FROM users WHERE avatar_id=a.id) AND NOT EXISTS(SELECT 1 FROM account WHERE logo_id=a.id) AND NOT EXISTS(SELECT 1 FROM link_previews WHERE image_id=a.id) LIMIT 100', (now - 86400).str())! {
		execute(db, 'DELETE FROM uploads AS a WHERE id=? AND NOT EXISTS(SELECT 1 FROM messages WHERE upload_id=a.id) AND NOT EXISTS(SELECT 1 FROM users WHERE avatar_id=a.id) AND NOT EXISTS(SELECT 1 FROM account WHERE logo_id=a.id) AND NOT EXISTS(SELECT 1 FROM link_previews WHERE image_id=a.id)', row.get_int('id').str())!
		if !exists(db, 'SELECT 1 FROM uploads WHERE id=?', row.get_int('id').str()) {
			for field in ['key', 'thumb'] {
				if row.get_string(field) != '' {
					os.rm(os.join_path(app.data_dir, 'uploads', row.get_string(field))) or {}
				}
			}
		}
	}
}

fn execute_job(app &App, db &Database, kind string, payload string) ! {
	match kind {
		'media' { process_media(app, db, payload.int())! }
		'webhook' { deliver_webhook(app, db, json.decode[WebhookJob](payload)!)! }
		'notify' { notify_message(app, db, payload.int())! }
		'push' { deliver_notification(app, db, json.decode[PushJob](payload)!)! }
		'push_test' { test_push(app, db, payload.int())! }
		'preview' { preview_message(app, db, payload.int())! }
		else { return error('Unknown job kind.') }
	}
}

fn process_media(app &App, db &Database, id int) ! {
	r := one(db, 'SELECT * FROM uploads WHERE id=?', id.str()) or { return }
	mime := r.get_string('mime')
	if !mime.starts_with('image/') && !mime.starts_with('video/') && !mime.starts_with('audio/') {
		return
	}
	input := os.join_path(app.data_dir, 'uploads', r.get_string('key'))
	if mime in ['image/png', 'image/jpeg', 'image/gif'] {
		thumb := r.get_string('key') + '.jpg'
		if metadata := run_process(os.executable(), ['thumbnail', input,
			os.join_path(app.data_dir, 'uploads', thumb)], 15 * time.second) {
			info := json.decode[MediaInfo](metadata)!
			record_media(app, db, id, thumb, info.streams[0].width, info.streams[0].height, '')!
			return
		}
	}
	metadata := run_process('ffprobe', ['-v', 'error', '-max_alloc', '33554432', '-protocol_whitelist',
		'file,pipe', '-threads', '1', '-show_entries', 'stream=width,height:format=duration', '-of',
		'json', input], 10 * time.second)!
	info := json.decode[MediaInfo](metadata)!
	width := if info.streams.len > 0 { info.streams[0].width } else { 0 }
	height := if info.streams.len > 0 { info.streams[0].height } else { 0 }
	if width > 8192 || height > 8192 || i64(width) * height > 20000000 {
		return error('Image dimensions exceed the preview limit.')
	}
	mut thumb := ''
	if !mime.starts_with('audio/') {
		thumb = r.get_string('key') + '.jpg'
		output := os.join_path(app.data_dir, 'uploads', thumb)
		run_process('ffmpeg', ['-nostdin', '-v', 'error', '-max_alloc', '67108864', '-threads',
			'1', '-filter_threads', '1', '-protocol_whitelist', 'file,pipe', '-i', input, '-frames:v',
			'1', '-vf', "scale='min(1200,iw)':'min(800,ih)':force_original_aspect_ratio=decrease",
			'-threads', '1', '-y', output], 30 * time.second)!
	}
	record_media(app, db, id, thumb, width, height, info.format.duration)!
}

fn record_media(app &App, db &Database, id int, thumb string, width int, height int, duration string) ! {
	execute(db, 'UPDATE uploads SET thumb=?,width=?,height=?,duration=? WHERE id=?', thumb, width.str(), height.str(), duration, id.str())!
	for row in query(db, 'SELECT id,user_id,room_id FROM messages WHERE upload_id=?', id.str())! {
		message := message_by_id(db, row.get_int('user_id'), row.get_int('id')) or { continue }
		app.publish_room(db, row.get_int('room_id'), Event{ kind: 'message_updated', room_id: row.get_int('room_id'), message: message })
	}
}

struct MediaStream {
	width  int
	height int
}

struct MediaFormat {
	duration string
}

struct MediaInfo {
	streams []MediaStream
	format  MediaFormat
}

struct WebhookUser {
	id   int
	name string
}

struct WebhookRoom {
	id   int
	name string
	path string
}

struct WebhookBody {
	html  string
	plain string
}

struct WebhookMessage {
	id   int
	body WebhookBody
	path string
}

struct WebhookPayload {
	user    WebhookUser
	room    WebhookRoom
	message WebhookMessage
}

fn deliver_webhook(app &App, db &Database, job WebhookJob) ! {
	bot := one(db, "SELECT * FROM users WHERE id=? AND role='bot' AND status='active'", job.bot_id.str()) or { return }
	message := message_by_id(db, job.bot_id, job.message_id) or { return }
	room := room_for(db, job.bot_id, message.room_id) or { return }
	url := bot.get_string('webhook')
	if url == '' { return }
	payload := WebhookPayload{ user: WebhookUser{ id: message.user_id, name: message.name }, room: WebhookRoom{ id: room.id, name: room.name, path: '/api/bot/${bot.get_string('bot_key')}/rooms/${room.id}/messages' }, message: WebhookMessage{ id: message.id, body: WebhookBody{ html: message.body, plain: message.plain.replace('@' + bot.get_string('name'), '').trim_space() }, path: '/rooms/${room.id}?at=${message.id}' } }
	response := fetch_url(app, url, 'POST', json.encode(payload), {
		'Content-Type': 'application/json'
	}, false)!
	if response.status >= 500 { return error('Webhook returned ${response.status}.') }
	if response.status != 200 || response.body == '' { return }
	content_type := (response.headers['content-type'] or { 'application/octet-stream' }).all_before(';')
	mut input := MessageInput{ client_id: 'webhook-${job.bot_id}-${job.message_id}' }
	if content_type in ['text/plain', 'text/html'] {
		input = MessageInput{
			...input
			body: if content_type == 'text/plain' {
				escape(response.body)
			} else {
				response.body
			}
		}
	} else {
		file := store_upload(app, db, job.bot_id, 'bot-attachment', response.body, content_type)!
		input = MessageInput{ ...input, upload_id: file.id }
	}
	reply := save_message(db, user_from(bot), room.id, input)!
	app.publish_room(db, room.id, Event{ kind: 'message', room_id: room.id, message: reply })
}

struct UnfurlInput {
	url string
}

struct LinkPreview {
	url         string
	title       string
	description string
	image_id    int
}

@['/api/unfurl'; post]
pub fn (app &App) links_unfurl(mut ctx Context) veb.Result {
	return respond(mut ctx, app, unfurl_link, false)
}

fn unfurl_link(mut ctx Context, app &App, db &Database) !string {
	rate_limit(db, 'unfurl:${ctx.user.id}', 20, 60)!
	input := body[UnfurlInput](ctx)!
	preview := fetch_preview(app, db, input.url, ctx.user.id, false)!
	return json.encode(preview)
}

fn fetch_preview(app &App, db &Database, url string, owner_id int, with_image bool) !LinkPreview {
	response := fetch_url(app, url, 'GET', '', {}, true)!
	if response.status != 200 || !(response.headers['content-type'] or { '' }).contains('text/html') {
		return LinkPreview{ url: url }
	}
	if response.body.len > 1024 * 1024 {
		return error_with_code('This page is too large to preview.', 422)
	}
	dom := html.parse(response.body)
	mut title := ''
	mut description := ''
	mut image_url := ''
	for tag in dom.get_tags(name: 'title') {
		title = unescape_html(tag.text()).limit(200)
		break
	}
	for tag in dom.get_tags(name: 'meta') {
		property := tag.attributes['property'] or { tag.attributes['name'] or { '' } }
		if property == 'og:title' {
			title = unescape_html(tag.attributes['content'] or { '' }).limit(200)
		}
		if property in ['og:description', 'description'] {
			description = unescape_html(tag.attributes['content'] or { '' }).limit(400)
		}
		if property == 'og:image' { image_url = unescape_html(tag.attributes['content'] or { '' }) }
	}
	mut image_id := 0
	if with_image && image_url != '' {
		base := urllib.parse(response.url)!
		absolute := base.parse(image_url)!
		if image_response := fetch_url(app, absolute.str(), 'GET', '', {}, true) {
			mime := safe_mime(image_response.body, '')
			if image_response.status == 200 && mime.starts_with('image/') {
				upload := store_upload(app, db, owner_id, 'link-preview', image_response.body, mime)!
				image_id = upload.id
			}
		}
	}
	return LinkPreview{ url: url, title: title, description: description, image_id: image_id }
}

fn preview_message(app &App, db &Database, id int) ! {
	row := one(db, 'SELECT user_id FROM messages WHERE id=?', id.str()) or { return }
	message := message_by_id(db, row.get_int('user_id'), id) or { return }
	dom := html.parse('<vampfire-root>${message.body}</vampfire-root>')
	for tag in dom.get_tags(name: 'a') {
		url := tag.attributes['href'] or { continue }
		if !url.starts_with('http://') && !url.starts_with('https://') { continue }
		preview := fetch_preview(app, db, url, message.user_id, true) or { return }
		if preview.title == '' && preview.description == '' { return }
		// The message may have changed while the remote page was being fetched.
		execute(db, "INSERT OR REPLACE INTO link_previews(message_id,url,title,description,image_id) SELECT id,?,?,?,nullif(?,'0') FROM messages WHERE id=? AND body=? AND updated_at=?", preview.url, preview.title, preview.description, preview.image_id.str(), id.str(), message.body, message.updated_at.str())!
		updated := message_by_id(db, message.user_id, id) or { return }
		app.publish_room(db, message.room_id, Event{ kind: 'message_updated', room_id: message.room_id, message: updated })
		return
	}
}
