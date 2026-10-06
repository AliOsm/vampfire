"""Create a complete restorable backup. Stop the app first to keep files consistent."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sqlite3


def backup(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if destination.exists():
        raise ValueError(f'Destination already exists: {destination}')
    destination.mkdir(parents=True, mode=0o700)
    try:
        with closing(sqlite3.connect(f'file:{source / "vampfire.sqlite3"}?mode=ro', uri=True)) as database:
            with closing(sqlite3.connect(destination / 'vampfire.sqlite3')) as snapshot:
                database.backup(snapshot)
                if snapshot.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                    raise ValueError('Database integrity check failed')
        shutil.copytree(source / 'uploads', destination / 'uploads')
        if (source / 'push.env').exists():
            shutil.copy2(source / 'push.env', destination / 'push.env')
        (destination / 'backup.json').write_text(json.dumps({'created_at': datetime.now(timezone.utc).isoformat(), 'application': 'vampfire', 'schema_version': 1}, indent=2) + '\n')
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', default=os.environ.get('VAMPFIRE_DATA', '.data'))
    parser.add_argument('--output', default='.backups/' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    args = parser.parse_args()
    print('Backup saved:', backup(args.data, args.output))
