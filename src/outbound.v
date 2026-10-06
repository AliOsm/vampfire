module main

import net
import net.urllib
import os
import time

struct HttpResult {
	status  int
	body    string
	headers map[string]string
	url     string
}

fn validate_url(raw string, public_only bool) !urllib.URL {
	if raw.len > 2048 || raw.contains('\r') || raw.contains('\n') {
		return error_with_code('Invalid URL.', 422)
	}
	u := urllib.parse(raw) or { return error_with_code('Invalid URL.', 422) }
	userinfo := u.user or { urllib.Userinfo{} }
	if u.scheme !in ['http', 'https'] || u.hostname() == '' || userinfo.username != '' || userinfo.password != '' || raw.all_after('://').all_before('/').contains('@') {
		return error_with_code('Use an HTTP or HTTPS URL without credentials.', 422)
	}
	if public_only && u.port() !in ['', '80', '443'] {
		return error_with_code('Only standard web ports are supported.', 422)
	}
	return u
}

fn public_ipv4(ip string) bool {
	parts := ip.split('.')
	if parts.len != 4 { return false }
	a := parts.map(it.int())
	for i, part in parts {
		if part == '' || !part.bytes().all(it >= `0` && it <= `9`) || a[i] < 0 || a[i] > 255 {
			return false
		}
	}
	return !(a[0] in [0, 10, 127] || a[0] >= 224 || (a[0] == 100 && a[1] >= 64 && a[1] <= 127)
		|| (a[0] == 169 && a[1] == 254) || (a[0] == 172 && a[1] >= 16 && a[1] <= 31)
		|| (a[0] == 192 && a[1] == 168) || (a[0] == 192 && a[1] == 0)
		|| (a[0] == 192 && a[1] == 88 && a[2] == 99) || (a[0] == 198 && a[1] in [18, 19, 51])
		|| (a[0] == 203 && a[1] == 0 && a[2] == 113))
}

fn pinned_address(u urllib.URL) !string {
	port := if u.port() != '' {
		u.port()
	} else if u.scheme == 'https' {
		'443'
	} else {
		'80'
	}
	addresses := net.resolve_addrs('${u.hostname()}:${port}', .ip, .tcp)!
	if addresses.len == 0 { return error('Host could not be resolved.') }
	mut chosen := ''
	for address in addresses {
		ip := address.str().all_before_last(':')
		if !public_ipv4(ip) { return error_with_code('Private network URLs are not allowed.', 422) }
		if chosen == '' { chosen = ip }
	}
	return '${u.hostname()}:${port}:${chosen}'
}

fn run_process(program string, args []string, timeout time.Duration) !string {
	executable := os.find_abs_path_of_executable(program) or { return error('${program} is required. Run mise install.') }
	// Decoders process untrusted media; bound each child independently of the server.
	media := program in ['ffmpeg', 'ffprobe']
	mut process := os.new_process(if media {
		os.find_abs_path_of_executable('prlimit')!
	} else {
		executable
	})
	process.set_args(if media {
		['--as=536870912', '--stack=2097152', '--cpu=30', '--fsize=33554432', '--', executable,
			...args]
	} else {
		args
	})
	if media {
		mut environment := os.environ()
		environment['MALLOC_ARENA_MAX'] = '2'
		environment['OMP_NUM_THREADS'] = '1'
		environment['OPENBLAS_NUM_THREADS'] = '1'
		process.set_environment(environment)
	}
	process.set_redirect_stdio()
	process.run()
	defer { process.close() }
	started := time.now()
	mut output := ''
	mut errors := ''
	for process.is_alive() {
		if process.is_pending(.stdout) { output += process.stdout_read() }
		if process.is_pending(.stderr) { errors += process.stderr_read() }
		if output.len + errors.len > 65536 || time.since(started) > timeout {
			process.signal_kill()
			process.wait()
			return error('External request or media operation exceeded its limit.')
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	output += process.stdout_slurp()
	errors += process.stderr_slurp()
	if process.code != 0 {
		return error('${program} failed (${process.code}): ${errors.limit(500)}')
	}
	return output
}

fn fetch_url(app &App, raw string, method string, payload string, headers map[string]string, public_only bool) !HttpResult {
	mut current := raw
	started := time.now()
	for _ in 0 .. 6 {
		if time.since(started) > 15 * time.second { return error('Request timed out.') }
		u := validate_url(current, public_only)!
		base := os.join_path(app.data_dir, 'tmp', token())
		defer {
			for suffix in ['.headers', '.body', '.request'] { os.rm(base + suffix) or {} }
		}
		mut args := ['--silent', '--show-error', '--noproxy', '*', '--proto', '=http,https',
			'--max-time', '10', '--connect-timeout', '4', '--max-filesize', upload_limit.str(),
			'--request', method, '--dump-header', base + '.headers', '--output', base + '.body',
			'--write-out', '%{http_code}']
		if public_only { args << ['--resolve', pinned_address(u)!] }
		for key, value in headers {
			if key.contains_any('\r\n') || value.contains_any('\r\n') {
				return error('Invalid HTTP header.')
			}
			args << ['--header', '${key}: ${value}']
		}
		if method == 'POST' {
			os.write_file(base + '.request', payload)!
			args << ['--data-binary', '@' + base + '.request']
		}
		args << ['--url', current]
		status := run_process('curl', args, 12 * time.second)!.int()
		mut response_headers := map[string]string{}
		for line in os.read_file(base + '.headers')!.split_into_lines() {
			if line.contains(':') {
				response_headers[line.all_before(':').to_lower()] = line.all_after(':').trim_space()
			}
		}
		if status in [301, 302, 303, 307, 308] && method == 'GET' {
			location := response_headers['location'] or { return error('Redirect is missing its location.') }
			current = u.parse(location)!.str()
			continue
		}
		return HttpResult{ status: status, body: os.read_file(base + '.body')!, headers: response_headers, url: current }
	}
	return error('Too many redirects.')
}
