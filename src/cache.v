module main

import compress.gzip
import os
import sync
import time
import veb

const response_cache_limit = 16 * 1024 * 1024

struct CachedResponse {
	body       string
	compressed string
	etag       string
	created    i64
}

@[heap]
struct ResponseCache {
mut:
	mu         sync.Mutex
	generation u64
	entries    map[string]CachedResponse
	bytes      int
}

fn (mut cache ResponseCache) get(key string, generation u64) ?CachedResponse {
	cache.mu.lock()
	defer { cache.mu.unlock() }
	if cache.generation != generation { return none }
	entry := cache.entries[key] or { return none }
	if time.now().unix() - entry.created >= 15 { return none }
	return entry
}

fn (mut cache ResponseCache) put(key string, generation u64, entry CachedResponse) {
	size := key.len + entry.body.len + entry.compressed.len + entry.etag.len + 128
	if size > response_cache_limit / 4 { return }
	cache.mu.lock()
	defer { cache.mu.unlock() }
	if generation < cache.generation { return }
	if generation != cache.generation || cache.bytes + size > response_cache_limit {
		cache.entries.clear()
		cache.bytes = 0
		cache.generation = generation
	}
	if old := cache.entries[key] {
		cache.bytes -= key.len + old.body.len + old.compressed.len + old.etag.len + 128
	}
	cache.entries[key] = entry
	cache.bytes += size
}

fn cacheable(ctx &Context, public bool) bool {
	if public || ctx.req.method !in [.get, .head] { return false }
	path := ctx.req.url.all_before('?')
	return path in ['/api/rooms', '/api/search', '/api/users']
		|| (path.starts_with('/api/rooms/') && path.ends_with('/messages'))
}

// Honor explicit exclusions, including gzip;q=0 overriding a wildcard.
fn accepts_gzip(value string) bool {
	mut wildcard := false
	for item in value.to_lower().split(',') {
		parts := item.split(';').map(it.trim_space())
		if parts[0] !in ['gzip', '*'] { continue }
		mut quality := f64(1)
		for part in parts[1..] {
			if part.starts_with('q=') { quality = part[2..].f64() }
		}
		if parts[0] == 'gzip' { return quality > 0 && quality <= 1 }
		wildcard = quality > 0 && quality <= 1
	}
	return wildcard
}

fn encoded_response(body string) CachedResponse {
	compressed := if body.len >= 512 {
		(gzip.compress(body.bytes()) or { []u8{} }).bytestr()
	} else {
		''
	}
	return CachedResponse{ body: body, compressed: if compressed.len < body.len {
		compressed
	} else {
		''
	}, etag: 'W/"' + digest(body) + '"', created: time.now().unix() }
}

fn send_cached(mut ctx Context, entry CachedResponse) veb.Result {
	return send_representation(mut ctx, entry, 'application/json', 'private, no-cache')
}

fn send_representation(mut ctx Context, entry CachedResponse, mime string, policy string) veb.Result {
	ctx.set_header(.vary, 'Accept-Encoding')
	ctx.set_header(.etag, entry.etag)
	ctx.set_header(.cache_control, policy)
	if (ctx.get_header(.if_none_match) or { '' }).split(',').map(it.trim_space()).any(it == entry.etag || it == entry.etag[2..] || it == '*') {
		ctx.res.set_status(.not_modified)
		return ctx.send_response_to_client(mime, '')
	}
	compress := entry.compressed != '' && accepts_gzip(ctx.get_header(.accept_encoding) or { '' })
	data := if compress { entry.compressed } else { entry.body }
	if compress { ctx.set_header(.content_encoding, 'gzip') }
	ctx.set_header(.content_length, data.len.str())
	return ctx.send_response_to_client(mime, if ctx.req.method == .head { '' } else { data })
}

struct CachedAsset {
	response CachedResponse
	mime     string
}

fn (mut app App) cache_assets() ! {
	mut bytes := 0
	for url, path in app.static_files.clone() {
		mime := match os.file_ext(path) {
			'.js', '.mjs' { 'application/javascript' }
			'.css' { 'text/css' }
			'.svg' { 'image/svg+xml' }
			'.html' { 'text/html' }
			else { continue }
		}
		if os.file_size(path) > 1024 * 1024 { continue }
		response := encoded_response(os.read_file(path)!)
		bytes += response.body.len + response.compressed.len
		if bytes > 8 * 1024 * 1024 { break }
		app.assets[url] = CachedAsset{ response: response, mime: mime }
		app.static_files.delete(url)
	}
}

@['/assets/:path...'; get; head]
pub fn (app &App) asset_download(mut ctx Context, path string) veb.Result {
	asset := app.assets['/assets/' + path] or { return ctx.not_found() }
	return send_representation(mut ctx, asset.response, asset.mime, 'public, max-age=3600')
}
