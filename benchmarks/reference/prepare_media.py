"""Let the unchanged V worker generate its own seed previews before measurement."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
seed = ROOT/'.build/comparison/vampfire-seed'
assert os.environ.get('VAMPFIRE_RESOURCE_GUARD'), 'Use the resource guard.'
with (ROOT/'.build/comparison/seed-media.log').open('w') as log:
    process = subprocess.Popen(['taskset','-c','0-3',str(ROOT/'.build/vampfire')],cwd=ROOT,
        env={**os.environ,'PORT':'4392','BIND':'127.0.0.1','VAMPFIRE_DATA':str(seed)},stdout=log,stderr=subprocess.STDOUT)
    try:
        until=time.monotonic()+90
        with sqlite3.connect(seed/'vampfire.sqlite3') as db:
            while time.monotonic()<until:
                if process.poll() is not None:raise RuntimeError('seed media worker exited')
                jobs=db.execute('SELECT id,attempts,error FROM jobs').fetchall()
                if not jobs:break
                assert all(attempts<2 for _,attempts,_ in jobs),jobs
                time.sleep(.2)
            else:raise RuntimeError('seed media timed out')
            media=[dict(zip(['id','mime','thumb','width','height'],r)) for r in db.execute('SELECT id,mime,thumb,width,height FROM uploads')]
            (seed/'media.json').write_text(json.dumps(media,indent=2)+'\n')
            print('Native V media ready:',len(media),'uploads')
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
