"""Reproduce the pinned reference seed and adapted upstream load generator."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
REFERENCE=ROOT/'.build/comparison/rust-source'
REVISION='2e392fe1c839541c3cbfcf0b980ea36310a37393'
VERIFICATION_REVISION='8c7570427490fa7e19311b81837c63162c763494'
WORK=ROOT/'.build/comparison'


def run(*args,cwd=ROOT):
    subprocess.run(list(map(str,args)),cwd=cwd,check=True)


def guarded(*args,timeout=600):
    run(sys.executable,'scripts/resource_guard.py','--report-dir','.build/resource-reports',
        '--timeout',timeout,'--',*args)


def main():
    if not REFERENCE.exists():
        run('git','clone','https://github.com/basecamp/once-campfire-rust',REFERENCE)
        run('git','checkout','--detach',REVISION,cwd=REFERENCE)
    actual=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REFERENCE,text=True).strip()
    assert actual==REVISION,f'Expected reference revision {REVISION}, found {actual}; preserve this checkout and select the pinned revision separately.'
    run('git','submodule','update','--init','reference',cwd=REFERENCE)
    config=WORK/'docker-config';config.mkdir(parents=True,exist_ok=True)
    from run import RUST_IMAGE
    from seed_reference import IMAGE as RAILS_IMAGE
    for image in [RUST_IMAGE,RAILS_IMAGE]:
        if subprocess.run(['docker','image','inspect',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
            run('docker','--config',config,'pull',image)
    guarded(sys.executable,'benchmarks/reference/extract_rust.py',timeout=120)
    verification=WORK/'verification'
    if not verification.exists():
        run('git','clone','https://github.com/basecamp/once-campfire-verification',verification)
        run('git','checkout','--detach',VERIFICATION_REVISION,cwd=verification)
    assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=verification,text=True).strip()==VERIFICATION_REVISION
    loadgen=WORK/'loadgen-verified'
    (loadgen/'src').mkdir(parents=True,exist_ok=True)
    for file in ['Cargo.toml','Cargo.lock','src/main.rs','src/validation.rs']:
        shutil.copy2(verification/'loadgen'/file,loadgen/file)
    run('patch','-p1','--input',ROOT/'benchmarks/reference/loadgen.patch',cwd=loadgen)
    shutil.copy2(ROOT/'benchmarks/reference/vampfire.rs',loadgen/'src/vampfire.rs')
    run('mise','exec','rust@1.98.1','--','cargo','fmt','--manifest-path',loadgen/'Cargo.toml')
    guarded('mise','exec','rust@1.98.1','--','cargo','build','--release','--locked','-j1','--manifest-path',loadgen/'Cargo.toml')
    guarded(sys.executable,'benchmarks/reference/seed_reference.py',timeout=630)
    if not (WORK/'vampfire-seed').exists():
        run(sys.executable,'benchmarks/reference/seed_vampfire.py')
    guarded(sys.executable,'benchmarks/reference/prepare_media.py',timeout=120)
    print('Comparison inputs ready. The app binary must already be a validated release build.')


if __name__=='__main__':main()
