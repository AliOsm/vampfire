"""Bounded loopback benchmark of the complete application, not a language shootout."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import time

from support import Client, PASSWORD, ROOT, Server


def process_stats(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()
    status = dict(line.split(':', 1) for line in Path(f'/proc/{pid}/status').read_text().splitlines())
    return {
        'cpu_seconds': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
        'rss_mib': int(status['VmRSS'].split()[0]) / 1024,
        'peak_rss_mib': int(status['VmHWM'].split()[0]) / 1024,
    }


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def measure(server, name, operation, count=800, concurrency=8):
    for index in range(20):
        operation(-index - 1)
    before = process_stats(server.process.pid)
    started = time.perf_counter()

    def worker(worker_id):
        durations = []
        for index in range(worker_id, count, concurrency):
            begin = time.perf_counter_ns()
            operation(index)
            durations.append((time.perf_counter_ns() - begin) / 1_000_000)
        return durations

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        samples = [sample for batch in pool.map(worker, range(concurrency)) for sample in batch]
    elapsed = time.perf_counter() - started
    after = process_stats(server.process.pid)
    cpu_seconds = after['cpu_seconds'] - before['cpu_seconds']
    result = {
        'scenario': name, 'operations': count, 'concurrency': concurrency,
        'seconds': round(elapsed, 4), 'operations_per_second': round(count / elapsed, 1),
        'p50_ms': round(percentile(samples, .50), 3),
        'p95_ms': round(percentile(samples, .95), 3),
        'p99_ms': round(percentile(samples, .99), 3),
        'server_cpu_seconds': round(cpu_seconds, 3),
        'server_cpu_percent_one_core': round(cpu_seconds / elapsed * 100, 1),
        'server_rss_mib': round(after['rss_mib'], 2),
        'server_peak_rss_mib': round(after['peak_rss_mib'], 2),
        'errors': 0,
    }
    print(json.dumps(result), flush=True)
    return result


def main():
    if not os.environ.get('VAMPFIRE_RESOURCE_GUARD'):
        raise SystemExit('Use mise run bench.')
    build = json.loads((ROOT / '.build/vampfire.build.json').read_text())
    if build['mode'] != 'release':
        raise SystemExit('Run mise run build first: benchmarks require a release binary.')
    if hashlib.sha256((ROOT / '.build/vampfire').read_bytes()).hexdigest() != build['binary_sha256']:
        raise SystemExit('Binary does not match its build metadata.')
    server = Server()
    try:
        alice, bob = Client(server.port), Client(server.port)
        alice.post('/api/setup', {'name': 'Benchmark sender', 'email': 'sender@example.test',
                   'password': PASSWORD, 'account_name': 'Isolated benchmark'}, expected=201)
        code = alice.get('/api/account')['account']['join_code']
        bob.post('/api/join', {'name': 'Benchmark recipient', 'email': 'recipient@example.test',
                 'password': PASSWORD, 'join_code': code}, expected=201)
        for index in range(500):
            alice.message(1, f'<p>Project checkpoint {index}: A short chat message with <strong>formatting</strong>.</p>')
        idle = process_stats(server.process.pid)
        rows = []
        for repeat in range(3):
            rows.append(measure(server, f'history_40_run_{repeat + 1}', lambda _: bob.get('/api/rooms/1/messages')))
            rows.append(measure(server, f'search_40_run_{repeat + 1}', lambda _: bob.get('/api/search?q=checkpoint')))
            rows.append(measure(server, f'persist_message_run_{repeat + 1}',
                        lambda index: alice.message(1, f'Work update {repeat} / {index}: the next release is ready.'), count=400))
        with bob.socket() as recipient:
            recipient.send({'type': 'subscribe', 'room_id': 1})
            recipient.until('presence')

            def roundtrip(index):
                sent = alice.message(1, f'Live delivery {index}: A short message to another user.')
                recipient.until('message', lambda event: event['message']['id'] == sent['id'])

            for repeat in range(3):
                rows.append(measure(server, f'http_to_websocket_run_{repeat + 1}', roundtrip, count=200, concurrency=1))
        cpu = next(line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name'))
        report = {
            'measured_at': datetime.now(timezone.utc).isoformat(), 'build': build,
            'host': {'cpu': cpu, 'logical_cpus': os.cpu_count(), 'platform': platform.platform(),
                     'python': platform.python_version(), 'load_average': os.getloadavg()},
            'conditions': {'transport': 'HTTP and WebSocket on IPv4 loopback, new HTTP connection per request',
                           'database': 'SQLite WAL, synchronous=NORMAL, four HTTP connections plus background worker',
                           'initial_messages': 500, 'initial_idle_process': idle, 'warmups_per_scenario': 20,
                           'repetitions': 3, 'client': 'Python stdlib threads on the same shared host',
                           'limitations': 'Application smoke benchmark; client and connection overhead included. No TLS, external push, media or remote bots. Not saturation capacity or a comparison to Rust/Rails.'},
            'results': rows,
        }
        destination = ROOT / 'docs/benchmarks' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.json')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('x') as stream:
            json.dump(report, stream, indent=2)
            stream.write('\n')
        print('Evidence:', destination)
    finally:
        server.close()


if __name__ == '__main__':
    main()
