"""Extract the official release executable and media libraries for a native comparison."""
import json
import os
from pathlib import Path
import subprocess
import uuid
from run import ROOT, WORK, RUST_IMAGE


def main():
    assert os.environ.get('VAMPFIRE_RESOURCE_GUARD')
    destination=WORK/'rust-runtime-2e392fe'
    if (destination/'ready.json').exists():
        print('Official Rust runtime already extracted.');return
    destination.mkdir(parents=True,exist_ok=True)
    name='vampfire-benchmark-extract-'+uuid.uuid4().hex[:10]
    subprocess.run(['docker','create','--name',name,RUST_IMAGE],check=True,stdout=subprocess.DEVNULL)
    try:
        for remote,local in [('/usr/local/bin','bin'),('/usr/local/lib','lib'),('/usr/lib/x86_64-linux-gnu','deps')]:
            subprocess.run(['docker','cp',f'{name}:{remote}',str(destination/local)],check=True)
        # Both native applications use this host's glibc. Do not mix a second
        # glibc's private interfaces with the host's ELF interpreter.
        excluded=['libc.so.6','libm.so.6','libdl.so.2','libpthread.so.0','librt.so.1','libresolv.so.2',
                  'libutil.so.1','libanl.so.1','ld-linux-x86-64.so.2']
        for file in excluded:(destination/'deps'/file).unlink(missing_ok=True)
        env={**os.environ,'LD_LIBRARY_PATH':f'{destination}/lib:{destination}/deps'}
        libraries=subprocess.check_output(['ldd',str(destination/'bin/campfire')],env=env,text=True)
        assert 'not found' not in libraries,libraries
        (destination/'ldd.txt').write_text(libraries)
        import hashlib
        (destination/'ready.json').write_text(json.dumps({'image':RUST_IMAGE,
            'campfire_sha256':hashlib.sha256((destination/'bin/campfire').read_bytes()).hexdigest(),
            'host_glibc':subprocess.check_output(['getconf','GNU_LIBC_VERSION'],text=True).strip(),
            'excluded_host_libs':excluded},indent=2)+'\n')
        print('Extracted official release binary and native media libraries:',destination)
    finally:
        subprocess.run(['docker','rm',name],stdout=subprocess.DEVNULL)


if __name__=='__main__':main()
