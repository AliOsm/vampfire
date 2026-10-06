"""Offline transport fixture used only by the link-preview integration scenario."""
import os
from pathlib import Path
import sys
import time

arguments = sys.argv[1:]


def argument(name):
    return arguments[arguments.index(name) + 1]


root = Path(os.environ['VAMPFIRE_TEST_CURL_FIXTURE'])
url = argument('--url')
assert url.startswith('https://93.184.216.34/'), url
assert argument('--resolve') == '93.184.216.34:443:93.184.216.34'
assert argument('--noproxy') == '*'
assert argument('--proto') == '=http,https'
if url.endswith('/slow'):
    (root / 'started').touch()
    deadline = time.monotonic() + 5
    while not (root / 'release').exists() and time.monotonic() < deadline:
        time.sleep(.01)
if url.endswith('/image.png'):
    content_type, content = 'image/png', (root / 'image.png').read_bytes()
else:
    content_type = 'text/html'
    content = b'''<!doctype html><html><head><title>Fallback title</title>
      <meta property="og:title" content="Project preview">
      <meta property="og:description" content="A preview fetched by the server.">
      <meta property="og:image" content="/image.png"></head><body>Page</body></html>'''
Path(argument('--dump-header')).write_text(f'HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\n\r\n')
Path(argument('--output')).write_bytes(content)
print('200', end='')
