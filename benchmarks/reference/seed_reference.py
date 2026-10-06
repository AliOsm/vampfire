"""Run the original Rails seed builder with the official pinned reference image."""
import os
from pathlib import Path
import shutil
import time
from container import Container

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = ROOT.parent/'once-campfire-rust'
IMAGE = 'ghcr.io/basecamp/once-campfire@sha256:d671ea2af4d80f68e7c65ff2dbbb122817fcd5c9ac14e7f8bebe8b906a59f8b5'


def main():
    assert os.environ.get('VAMPFIRE_RESOURCE_GUARD'), 'Use the resource guard.'
    output = ROOT/'.build/comparison/reference-seed'
    if (output/'labels.json').exists():
        print('Reference seed already exists:', output)
        return
    for sub in ['db', 'storage']:
        (output/sub).mkdir(parents=True, exist_ok=True)
    command = 'set -e\nredis-server --save "" --appendonly no --daemonize yes\nbin/rails db:prepare\nbin/rails runner /work/parity/seeds/build.rb default\n'
    container = Container([
        '--network', 'none', '--cpuset-cpus', '0-1',
        '--user', f'{os.getuid()}:{os.getgid()}',
        '--env-file', str(REFERENCE/'parity/.env.reference'),
        '-e', 'RAILS_LOG_LEVEL=warn',
        '-v', f'{REFERENCE}:/work:ro',
        '-v', f'{REFERENCE}/reference/test/fixtures:/rails/test/fixtures:ro',
        '-v', f'{output}/db:/rails/storage/db',
        '-v', f'{output}/storage:/rails/storage/files',
        IMAGE, 'bash', '-c', command,
    ], ROOT/'.build/comparison/seed.log')
    try:
        while container.check():
            if not container.state()['Running']:
                break
            time.sleep(.1)
        state = container.state()
        assert state['ExitCode'] == 0 and not state['OOMKilled'], state
        shutil.copy2(output/'db/labels.json', output/'labels.json')
        print('Reference seed generated:', output, flush=True)
    finally:
        container.close()


if __name__ == '__main__':
    main()
