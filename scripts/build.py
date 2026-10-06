"""Separate V code generation from GCC to bound peak memory."""
import os
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from toolchain import ROOT, VROOT, V, PINS, checkout, run


def compile_v(source, output, release=True):
    checkout(VROOT, PINS['v'])
    with tempfile.TemporaryDirectory(prefix='compile-', dir=ROOT / '.build') as directory:
        project = Path(directory) / 'c'
        flags = ['-new-compiler', '-cc', 'gcc', '-gc', 'boehm', '-nocache',
                 '-d', 'veb_max_http_post_size_bytes=17825792',
                 '-cflags', '--param ggc-min-expand=10 --param ggc-min-heapsize=16384 -DSQLITE_ENABLE_FTS5']
        if release:
            flags += ['-prod']
        run([V, *flags, '-path', str(ROOT / 'src') + '|' + str(VROOT / 'vlib'),
             '-generate-c-project', project, source], cwd=VROOT,
            env={**os.environ, 'VEXE': str(V)})
        run(['sh', 'build.sh'], cwd=project)
        temporary = output.with_suffix('.next')
        shutil.copy2(project / (source.stem if source.is_file() else source.name), temporary)
        temporary.replace(output)
        if source == ROOT / 'src':
            manifest = hashlib.sha256()
            for path in sorted([*source.glob('*'), * (ROOT / 'public').rglob('*')]):
                if path.is_file():
                    manifest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
            metadata = {
                'built_at': datetime.now(timezone.utc).isoformat(),
                'mode': 'release' if release else 'debug',
                'v_sources': PINS['v']['commit'],
                'bootstrap_snapshot': PINS['vc']['commit'],
                'compiler': subprocess.check_output([V, 'version'], text=True).strip(),
                'compiler_origin': 'unmodified official vc portable bootstrap; not self-hosted from pinned main',
                'gcc': subprocess.check_output(['gcc', '-dumpfullversion'], text=True).strip(),
                'flags': flags,
                'binary_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'source_sha256': manifest.hexdigest(),
            }
            output.with_suffix('.build.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    if not os.environ.get('VAMPFIRE_RESOURCE_GUARD'):
        raise SystemExit('Use mise tasks to keep builds resource bounded.')
    compile_v(ROOT / 'src', ROOT / '.build/vampfire', release='--debug' not in sys.argv)
