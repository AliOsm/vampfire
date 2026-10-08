module main

import json2 as json
import veb

struct ManifestIcon {
	src     string
	sizes   string
	@type   string
	purpose string
}

struct Manifest {
	name             string
	short_name       string
	start_url        string
	scope            string
	display          string
	background_color string
	theme_color      string
	icons            []ManifestIcon
}

@['/webmanifest']
pub fn (app &App) manifest(mut ctx Context) veb.Result {
	db := app.database.session()
	account := load_account(db) or { Account{ name: 'Vampfire' } }
	return ctx.send_response_to_client('application/manifest+json', json.encode(Manifest{
		name:             account.name
		short_name:       account.name
		start_url:        '/'
		scope:            '/'
		display:          'standalone'
		background_color: '#ffffff'
		theme_color:      '#a43b28'
		icons:            [
			ManifestIcon{ src: '/assets/app-icon.png', sizes: '512x512', @type: 'image/png', purpose: 'any' },
			ManifestIcon{ src: '/assets/app-icon-192.png', sizes: '192x192', @type: 'image/png', purpose: 'any' },
		]
	}))
}

@['/service-worker.js']
pub fn (app &App) service_worker(mut ctx Context) veb.Result {
	ctx.set_custom_header('Service-Worker-Allowed', '/') or {}
	return ctx.send_response_to_client('text/javascript', $embed_file('../public/service-worker.js').to_string())
}
