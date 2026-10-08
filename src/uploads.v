module main

import db.sqlite
import json2 as json
import net
import os
import time
import veb

const upload_limit = 16 * 1024 * 1024

fn safe_mime(data string, declared string) string {
	b := data.bytes()
	if b.len >= 8 && b[..8] == [u8(137), 80, 78, 71, 13, 10, 26, 10] { return 'image/png' }
	if b.len >= 3 && b[..3] == [u8(255), 216, 255] { return 'image/jpeg' }
	if data.starts_with('GIF87a') || data.starts_with('GIF89a') { return 'image/gif' }
	if b.len >= 12 && data[..4] == 'RIFF' && data[8..12] == 'WEBP' { return 'image/webp' }
	if b.len >= 12 && data[4..8] == 'ftyp' {
		return if declared.starts_with('audio/') { 'audio/mp4' } else { 'video/mp4' }
	}
	if b.len >= 4 && b[..4] == [u8(26), 69, 223, 163] {
		return if declared.starts_with('audio/') { 'audio/webm' } else { 'video/webm' }
	}
	if data.starts_with('OggS') { return 'audio/ogg' }
	if data.starts_with('ID3') || (b.len > 2 && b[0] == 255 && (b[1] & 224) == 224) {
		return 'audio/mpeg'
	}
	if data.starts_with('%PDF-') { return 'application/pdf' }
	return 'application/octet-stream'
}

fn upload_from(r sqlite.Row) Upload {
	return Upload{ id: r.get_int('id'), name: r.get_string('name'), mime: r.get_string('mime'), size: r.get_string('size').i64(), thumb: r.get_string('thumb'), width: r.get_int('width'), height: r.get_int('height'), duration: r.get_string('duration').f64() }
}

fn require_image_upload(db &Database, owner int, id int) ! {
	r := one(db, 'SELECT mime FROM uploads WHERE id=? AND owner_id=?', id.str(), owner.str())!
	if !r.get_string('mime').starts_with('image/') {
		return error_with_code('Choose a PNG, JPEG, GIF, or WebP image.', 422)
	}
}

fn store_upload(app &App, db &Database, user_id int, name string, data string, mime string) !Upload {
	if data.len == 0 || data.len > upload_limit {
		return error_with_code('Files must be between 1 byte and 16 MiB.', 413)
	}
	key := token()
	filename := os.file_name(name.replace('\\', '/')).replace('\r', '').replace('\n', '')
	if filename == '' || filename.len > 240 {
		return error_with_code('Use a shorter filename.', 422)
	}
	file := os.join_path(app.data_dir, 'uploads', key)
	os.write_file(file, data)!
	mut saved := false
	defer { if !saved { os.rm(file) or {} } }
	db.exec('BEGIN IMMEDIATE')!
	defer { db.exec('ROLLBACK') or {} }
	execute(db, 'INSERT INTO uploads(owner_id,key,name,mime,size,created_at) VALUES(?,?,?,?,?,?)', user_id.str(), key, filename, safe_mime(data, mime), data.len.str(), time.now().unix().str())!
	id := int(db.last_insert_rowid())
	queue_job(db, 'media', id.str())!
	db.exec('COMMIT')!
	saved = true
	return upload_from(one(db, 'SELECT * FROM uploads WHERE id=?', id.str())!)
}

@['/api/uploads'; post]
pub fn (app &App) uploads_create(mut ctx Context) veb.Result {
	return respond(mut ctx, app, create_upload, false)
}

fn create_upload(mut ctx Context, app &App, db &Database) !string {
	files := ctx.files['file'] or { return error_with_code('Choose a file.', 422) }
	if files.len != 1 { return error_with_code('Upload one file at a time.', 422) }
	file := files[0]
	upload := store_upload(app, db, ctx.user.id, file.filename, file.data, file.content_type)!
	ctx.res.set_status(.created)
	return json.encode(upload)
}

fn can_download(db &Database, user_id int, upload_id int) bool {
	return exists(db, 'SELECT 1 FROM uploads a WHERE a.id=? AND (a.owner_id=? OR EXISTS(SELECT 1 FROM messages m JOIN memberships k ON k.room_id=m.room_id WHERE m.upload_id=a.id AND k.user_id=?) OR EXISTS(SELECT 1 FROM link_previews p JOIN messages m ON m.id=p.message_id JOIN memberships k ON k.room_id=m.room_id WHERE p.image_id=a.id AND k.user_id=?) OR EXISTS(SELECT 1 FROM users u WHERE u.avatar_id=a.id) OR EXISTS(SELECT 1 FROM account WHERE logo_id=a.id))', upload_id.str(), user_id.str(), user_id.str(), user_id.str())
}

@['/uploads/:id'; get; head]
pub fn (app &App) upload_download(mut ctx Context, id int) veb.Result {
	db := app.database.session()
	authenticate(mut ctx, db) or { return ctx.problem(err) }
	if !can_download(db, ctx.user.id, id) {
		return ctx.problem(error_with_code('File not found.', 404))
	}
	r := one(db, 'SELECT * FROM uploads WHERE id=?', id.str()) or { return ctx.problem(err) }
	return serve_upload(mut ctx, app, r, ctx.query['thumb'] == '1')
}

@['/avatar/:id'; get; head]
pub fn (app &App) avatar_download(mut ctx Context, id int) veb.Result {
	db := app.database.session()
	authenticate(mut ctx, db) or { return ctx.problem(err) }
	r := one(db, 'SELECT a.* FROM uploads a JOIN users u ON u.avatar_id=a.id WHERE u.id=?', id.str()) or { return ctx.not_found() }
	return serve_upload(mut ctx, app, r, true)
}

@['/logo'; get; head]
pub fn (app &App) logo_download(mut ctx Context) veb.Result {
	db := app.database.session()
	r := one(db, 'SELECT a.* FROM uploads a JOIN account c ON c.logo_id=a.id WHERE c.id=1') or { return ctx.not_found() }
	return serve_upload(mut ctx, app, r, true)
}

fn serve_upload(mut ctx Context, app &App, r sqlite.Row, thumb bool) veb.Result {
	use_thumb := thumb && r.get_string('thumb') != ''
	key := if use_thumb { r.get_string('thumb') } else { r.get_string('key') }
	path := os.join_path(app.data_dir, 'uploads', key)
	if !os.exists(path) { return ctx.not_found() }
	size := i64(os.file_size(path))
	mime := if use_thumb { 'image/jpeg' } else { r.get_string('mime') }
	inline := mime.starts_with('image/') || mime.starts_with('audio/') || mime.starts_with('video/')
	name := r.get_string('name').replace('"', '').replace('\\', '')
	ctx.set_header(.content_disposition, '${if inline { 'inline' } else { 'attachment' }}; filename="${name}"')
	ctx.set_header(.accept_ranges, 'bytes')
	ctx.set_header(.cache_control, 'private, max-age=3600')
	etag := '"' + key + '"'
	ctx.set_header(.etag, etag)
	if (ctx.get_header(.if_none_match) or { '' }) == etag {
		ctx.res.set_status(.not_modified)
		return ctx.send_response_to_client(mime, '')
	}
	if_range := ctx.get_header(.if_range) or { etag }
	range := if if_range == etag { ctx.get_header(.range) or { '' } } else { '' }
	if range.starts_with('bytes=') && !range.contains(',') {
		parts := range[6..].split('-')
		if parts.len == 2 && parts[0].bytes().all(it >= `0` && it <= `9`) && parts[1].bytes().all(it >= `0` && it <= `9`) && parts[0].len < 12 && parts[1].len < 12 && (parts[0] != '' || parts[1] != '') {
			start := if parts[0] == '' {
				if parts[1].i64() < size { size - parts[1].i64() } else { 0 }
			} else {
				parts[0].i64()
			}
			end := if parts[0] == '' || parts[1] == '' || parts[1].i64() >= size {
				size - 1
			} else {
				parts[1].i64()
			}
			if start < 0 || start >= size || end < start {
				ctx.set_header(.content_range, 'bytes */${size}')
				return ctx.problem(error_with_code('Invalid byte range.', 416))
			}
			ctx.res.set_status(.partial_content)
			ctx.set_header(.content_range, 'bytes ${start}-${end}/${size}')
			return stream_file_range(mut ctx, app, path, mime, start, end - start + 1)
		}
		ctx.set_header(.content_range, 'bytes */${size}')
		return ctx.problem(error_with_code('Invalid byte range.', 416))
	}
	ctx.set_content_type(mime)
	return ctx.file(path)
}

// Full files use veb's sendfile path. Ranges use a bounded set of transfer
// workers with 64 KiB buffers; slow receivers cannot occupy the HTTP workers.
fn stream_file_range(mut ctx Context, app &App, path string, mime string, start i64, length i64) veb.Result {
	if ctx.req.method == .head {
		ctx.set_header(.content_length, length.str())
		return ctx.send_response_to_client(mime, '')
	}
	mut file := os.open(path) or { return ctx.not_found() }
	file.seek(start, .start) or {
		file.close()
		return ctx.not_found()
	}
	select {
		app.download_slots <- true {
		}
		else {
			file.close()
			return ctx.problem(error_with_code('Downloads are busy. Try again shortly.', 503))
		}
	}
	ctx.set_header(.content_type, mime)
	ctx.set_header(.content_length, length.str())
	ctx.set_header(.connection, 'close')
	ctx.res.http_version = '1.1'
	ctx.takeover_conn()
	spawn send_range(ctx.conn, file, int(length), ctx.res.bytes(), app.download_slots)
	return veb.no_result()
}

fn send_range(connection &net.TcpConn, source os.File, length int, headers []u8, slots chan bool) {
	mut file := source
	mut conn := unsafe { &net.TcpConn(connection) }
	defer {
		file.close()
		conn.close() or {}
		_ := <-slots
	}
	conn.set_blocking(false) or { return }
	conn.is_blocking = false
	conn.set_write_deadline(time.now().add(10 * time.second))
	conn.write(headers) or { return }
	mut remaining := length
	mut buffer := []u8{len: 65536}
	for remaining > 0 {
		wanted := if remaining < buffer.len { remaining } else { buffer.len }
		count := file.read(mut buffer[..wanted]) or { return }
		if count == 0 { return }
		conn.write(buffer[..count]) or { return }
		remaining -= count
	}
}
