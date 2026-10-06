"""Install upstream V and its official bootstrap dependencies without source patches."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VROOT = ROOT / '.build/v'
V = VROOT / 'v'
PINS = json.loads((ROOT / 'toolchains/v.lock.json').read_text())


def run(command, cwd=ROOT, **kwargs):
    subprocess.run(list(map(str, command)), cwd=cwd, check=True, **kwargs)


def checkout(directory, pin, update=False):
    if not (directory / '.git').exists():
        directory.mkdir(parents=True, exist_ok=True)
        run(['git', 'init', '-q', directory])
        run(['git', 'remote', 'add', 'origin', pin['url']], cwd=directory)
        run(['git', 'fetch', '-q', '--depth=1', 'origin', pin['commit']], cwd=directory)
        run(['git', 'checkout', '-q', '--detach', 'FETCH_HEAD'], cwd=directory)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory, text=True).strip()
    if subprocess.check_output(['git', 'diff', 'HEAD', '--'], cwd=directory):
        raise SystemExit(f'Toolchain source must remain unmodified: {directory}')
    if head != pin['commit']:
        if not update:
            raise SystemExit(f'Unexpected toolchain revision in {directory}: {head}; run mise run setup.')
        run(['git', 'fetch', '-q', '--depth=1', 'origin', pin['commit']], cwd=directory)
        run(['git', 'checkout', '-q', '--detach', pin['commit']], cwd=directory)


def main():
    if not os.environ.get('VAMPFIRE_RESOURCE_GUARD'):
        raise SystemExit('Use mise run setup for the bounded toolchain build.')
    for name, directory in [('v', VROOT), ('vc', VROOT / 'vc'), ('tcc', VROOT / 'thirdparty/tcc')]:
        checkout(directory, PINS[name], update=True)
    stamp = ROOT / '.build/v-bootstrap-commit'
    if not V.exists() or not stamp.exists() or stamp.read_text().strip() != PINS['vc']['commit']:
        temporary = VROOT / 'v.bootstrap.next'
        run(['gcc', '--param', 'ggc-min-expand=10', '--param', 'ggc-min-heapsize=16384',
             '-DCUSTOM_DEFINE_v1_fallback', '-std=c99', '-w', '-o', temporary,
             VROOT / 'vc/v.c', '-lm', '-lpthread'], cwd=VROOT)
        temporary.replace(V)
        stamp.write_text(PINS['vc']['commit'] + '\n')
    dest = VROOT / 'thirdparty/sqlite'
    if not (dest / 'sqlite3.c').exists():
        pin = PINS['sqlite']
        data = urllib.request.urlopen(pin['url'], timeout=60).read()
        assert hashlib.sha3_256(data).hexdigest() == pin['sha3_256']
        dest.mkdir(exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.namelist():
                name = Path(member).name
                if name in ('sqlite3.h', 'sqlite3.c', 'sqlite3ext.h'):
                    (dest / name).write_bytes(archive.read(member))
    run([V, 'version'])
    print('Upstream V sources verified; no patches applied.')
    print('Compiler: official vc portable bootstrap. Exact-main self-hosting exceeds this workspace memory cap; see docs/toolchain.md.')


if __name__ == '__main__':
    main()
