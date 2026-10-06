"""Start an isolated copy of either seed for unmeasured browser validation."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import time
from run import App, WORK

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',choices=['rust','vampfire'])
parser.add_argument('--check',action='store_true',help='Run the local Playwright fallback when the T3 browser is unavailable')
args=parser.parse_args()
assert os.environ.get('VAMPFIRE_RESOURCE_GUARD'), 'Use the resource guard.'
directory=WORK/f'browser-{args.app}-{time.time_ns()}'
directory.mkdir()
signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
app=App(args.app,directory,bind='0.0.0.0')
try:
    print('Browser server ready on port 4390:',args.app,flush=True)
    if args.check:
        subprocess.run(['node',str(Path(__file__).with_name('browser_check.cjs')),
                        args.app,str(directory),str(app.storage/'labels.json')],check=True,timeout=180)
    else:
        stop=WORK/'browser-stop'
        stop.unlink(missing_ok=True)
        until=time.monotonic()+240
        while time.monotonic()<until and not stop.exists():
            app.check()
            time.sleep(.2)
finally:
    app.close()
