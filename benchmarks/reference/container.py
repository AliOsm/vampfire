"""Own one bounded Docker process; never affect unrelated containers."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


class Container:
    def __init__(self, args, log, timeout=600):
        self.name = 'vampfire-benchmark-' + uuid.uuid4().hex[:12]
        self.log = Path(log)
        self.timeout = timeout
        self.started = time.monotonic()
        self.peak = 0
        self.reason = None
        subprocess.run(['docker', 'create', '--name', self.name,
                        '--memory', '1536m', '--memory-swap', '1536m',
                        '--pids-limit', '256', '--ulimit', 'nofile=65536:65536',
                        '--log-opt', 'max-size=32m', '--log-opt', 'max-file=2',
                        *args], check=True, stdout=subprocess.DEVNULL)
        try:
            subprocess.run(['docker', 'start', self.name], check=True, stdout=subprocess.DEVNULL)
            self.pid = self.state()['Pid']
            entry = next(x.split(':', 2)[2] for x in Path(f'/proc/{self.pid}/cgroup').read_text().splitlines() if x.startswith('0::'))
            self.cgroup = Path('/sys/fs/cgroup') / entry.lstrip('/')
            assert (self.cgroup/'memory.max').read_text().strip() == str(1536*1024**2)
            assert (self.cgroup/'memory.swap.max').read_text().strip() == '0'
        except BaseException:
            self.close()
            raise

    def state(self):
        return json.loads(subprocess.check_output(['docker', 'inspect', '--format', '{{json .State}}', self.name]))

    def check(self):
        try:
            used = int((self.cgroup/'memory.current').read_text())
        except FileNotFoundError:
            return False
        self.peak = max(self.peak, used)
        if used >= 1152*1024**2:
            self.reason = 'early memory stop'
        if time.monotonic()-self.started > self.timeout:
            self.reason = 'wall-clock timeout'
        if self.reason:
            raise RuntimeError(self.reason)
        return True

    def close(self):
        record = {'sampled_peak_bytes': self.peak, 'reason': self.reason}
        if hasattr(self, 'cgroup'):
            for key in ['memory.events', 'memory.peak']:
                try:
                    record[key] = (self.cgroup/key).read_text()
                except FileNotFoundError:
                    pass
        self.log.parent.mkdir(parents=True, exist_ok=True)
        try:
            with self.log.open('wb') as out:
                subprocess.run(['docker', 'logs', '--tail', '1000', self.name], stdout=out, stderr=subprocess.STDOUT,timeout=10)
        finally:
            subprocess.run(['docker', 'rm', '-f', self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,timeout=10)
            self.log.with_suffix('.resources.json').write_text(json.dumps(record, indent=2)+'\n')
