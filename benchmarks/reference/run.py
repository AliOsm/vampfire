"""Run the upstream Campfire workloads on unchanged Rust and V applications."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import signal
import sqlite3
import subprocess
import threading
import time

from container import Container

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = ROOT.parent/'once-campfire-rust'
WORK = ROOT/'.build/comparison'
LOADGEN = WORK/'loadgen/target/release/loadgen'
RUST_IMAGE = 'ghcr.io/basecamp/once-campfire-rust@sha256:9fc900c999bcfefe6ba4362d5245a92bb45445a2a04656017b6a5d3d2f034b1c'
SERVER_CPUS = '0-3'
CLIENT_CPUS = '4-5'
PORT = 4390


def write(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def process_stats(pid):
    """Process plus descendants; include reaped media workers in accumulated CPU time."""
    cpu, rss, peak = 0., 0, 0
    pending = [pid]
    seen = set()
    while pending:
        current = pending.pop()
        if current in seen: continue
        seen.add(current)
        try:
            proc = Path('/proc')/str(current)
            f = (proc/'stat').read_text().split(') ',1)[1].split()
            cpu += sum(int(f[x]) for x in (11,12,13,14))/os.sysconf('SC_CLK_TCK')
            status = dict(line.split(':',1) for line in (proc/'status').read_text().splitlines())
            rss += int(status.get('VmRSS','0 kB').split()[0])*1024
            peak += int(status.get('VmHWM','0 kB').split()[0])*1024
            for task in (proc/'task').iterdir():
                pending.extend(map(int,(task/'children').read_text().split()))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return {'cpu_seconds':cpu,'rss_bytes':rss,'hwm_bytes':peak}


class App:
    def __init__(self, name, directory, bind='127.0.0.1'):
        self.name, self.directory = name, directory
        self.container = self.process = None
        self.pid = 0
        self.failure = None
        self.samples = []
        self.stop = threading.Event()
        self.base = f'http://127.0.0.1:{PORT}'
        seed = WORK/('reference-seed' if name=='rust' else 'vampfire-seed')
        self.storage = directory/'storage'
        shutil.copytree(seed,self.storage)
        self.labels = json.loads((seed/'labels.json').read_text())
        self.database = self.storage/('db/production.sqlite3' if name=='rust' else 'vampfire.sqlite3')
        if name=='rust':
            with sqlite3.connect(self.database) as db:
                db.execute("UPDATE push_subscriptions SET endpoint='https://127.0.0.1:9/push/'||id")
                db.execute("UPDATE webhooks SET url='http://127.0.0.1:9/hook/'||id")
        start = time.perf_counter()
        try:
            if name=='rust' and os.environ.get('CAMPFIRE_BENCH_RUST_CONTAINER')=='1':
                self.container = Container([
                    '--network','host','--cpuset-cpus',SERVER_CPUS,
                    '--user',f'{os.getuid()}:{os.getgid()}',
                    '--env-file',str(REFERENCE/'parity/.env.reference'),
                    '-e',f'HTTP_PORT={PORT}','-e',f'TARGET_PORT={PORT+1}',
                    '-e','JOB_CONCURRENCY=3','-e','RAILS_MAX_THREADS=5','-e','RAILS_LOG_LEVEL=warn',
                    '-v',f'{self.storage}/db:/rails/storage/db',
                    '-v',f'{self.storage}/storage:/rails/storage/files',
                    RUST_IMAGE,
                ], directory/'server.log',timeout=900)
                self.pid = self.container.pid
            else:
                env = {k:v for k,v in os.environ.items() if not k.startswith('VAPID_')}
                for line in (REFERENCE/'parity/.env.reference').read_text().splitlines():
                    if line and not line.startswith('#') and '=' in line:
                        k,v=line.split('=',1);env[k]=v
                if name=='rust':
                    runtime=WORK/'rust-runtime'
                    env.update(HTTP_PORT=str(PORT),TARGET_PORT=str(PORT+1),JOB_CONCURRENCY='3',RAILS_MAX_THREADS='5',RAILS_LOG_LEVEL='warn',
                        CAMPFIRE_STORAGE_PATH=str(self.storage),CAMPFIRE_DATABASE_PATH=str(self.database),
                        CAMPFIRE_FILES_PATH=str(self.storage/'storage'),
                        LD_LIBRARY_PATH=f'{runtime}/lib:{runtime}/deps',PATH=f'{runtime}/bin:'+env['PATH'])
                    command=[str(runtime/'bin/campfire'),'server']
                else:
                    env.update(PORT=str(PORT),BIND=bind,BASE_URL=self.base,VAMPFIRE_DATA=str(self.storage))
                    command=[str(ROOT/'.build/vampfire')]
                self.process = subprocess.Popen(['taskset','-c',SERVER_CPUS,*command],
                    cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
                self.logger=threading.Thread(target=self.collect_log,daemon=True)
                self.logger.start()
                self.pid = self.process.pid
            self.monitor = threading.Thread(target=self.sample,daemon=True)
            self.monitor.start()
            until = time.monotonic()+40
            while time.monotonic()<until:
                self.check()
                try:
                    status,_,_ = request('/up')
                    if status==200: break
                except (OSError,http.client.HTTPException): pass
                time.sleep(.02)
            else: raise RuntimeError('server did not become ready')
            self.cold_ms = (time.perf_counter()-start)*1000
        except BaseException:
            self.close()
            raise

    def check(self):
        if self.failure: raise RuntimeError(self.failure)
        if self.process and self.process.poll() is not None: raise RuntimeError(f'{self.name} server exited')

    def sample(self):
        while not self.stop.wait(.1):
            try:
                row=process_stats(self.pid)
                if self.container:
                    self.container.check()
                    row['container_memory_bytes']=int((self.container.cgroup/'memory.current').read_text())
                row['time']=time.monotonic()
                row['unix_ms']=time.time_ns()//1_000_000
                wal=Path(str(self.database)+'-wal')
                row['wal_bytes']=wal.stat().st_size if wal.exists() else 0
                self.samples.append(row)
            except Exception as e:
                self.failure=str(e)
                if self.container:
                    subprocess.run(['docker','kill',self.container.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                return

    def collect_log(self):
        # Keep the original request logging behavior with a bounded, draining sink.
        os.sched_setaffinity(0,{4,5})
        path=self.directory/'server.log'
        stream=path.open('wb')
        try:
            while block:=self.process.stdout.read(65536):
                if stream.tell()+len(block)>32*1024**2:
                    stream.close()
                    path.replace(path.with_suffix('.log.1'))
                    stream=path.open('wb')
                stream.write(block)
        finally:
            stream.close()

    def close(self):
        self.stop.set()
        if hasattr(self,'monitor'): self.monitor.join(timeout=2)
        if self.container: self.container.close()
        if self.process:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired: self.process.kill();self.process.wait()
            self.logger.join(timeout=5)
        write(self.directory/'memory-samples.json',self.samples)


def request(path,cookie=''):
    c=http.client.HTTPConnection('127.0.0.1',PORT,timeout=2)
    try:
        c.request('GET',path,headers={'Cookie':cookie,'Accept-Encoding':'identity'})
        r=c.getresponse();body=r.read();headers=dict(r.getheaders())
        if r.getheader('Content-Encoding')=='gzip':body=gzip.decompress(body)
        return r.status,body,headers
    finally:c.close()


def lg(app, *args, file=None):
    app.check()
    before=process_stats(app.pid)
    usage=resource.getrusage(resource.RUSAGE_CHILDREN)
    client_before=usage.ru_utime+usage.ru_stime
    start=time.monotonic()
    command=['taskset','-c',CLIENT_CPUS,str(LOADGEN),*map(str,args),'--base',app.base,'--app',app.name]
    result=subprocess.run(command,text=True,capture_output=True,timeout=240)
    elapsed=time.monotonic()-start
    after=process_stats(app.pid)
    usage=resource.getrusage(resource.RUSAGE_CHILDREN)
    client_cpu=usage.ru_utime+usage.ru_stime-client_before
    if file:
        (app.directory/(file+'.stderr')).write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f'loadgen {args[0]} failed: {result.stderr[-2000:]}')
    app.check()
    value=json.loads(result.stdout)
    recent=[s for s in app.samples if s['time']>=start]
    value['resources']={
        'wall_seconds':elapsed,'server_cpu_seconds':max(0,after['cpu_seconds']-before['cpu_seconds']),
        'server_cpu_percent_one_core':max(0,after['cpu_seconds']-before['cpu_seconds'])/elapsed*100,
        'client_cpu_seconds':client_cpu,'client_cpu_percent_one_core':client_cpu/elapsed*100,
        'server_rss_after_bytes':after['rss_bytes'],
        'server_sampled_peak_rss_bytes':max([s['rss_bytes'] for s in recent]+[after['rss_bytes']]),
    }
    if file:write(app.directory/(file+'.json'),value)
    return value


def routes(app):
    l=app.labels;room=l['rooms.watercooler'];before=l['messages.busy_060']
    if app.name=='rust':
        return [
            ('room_show',['--path',f'/rooms/{room}']),
            ('messages_page',['--path',f'/rooms/{room}/messages?before={before}']),
            ('sidebar',['--path','/users/me/sidebar']),('search',['--path','/searches?q=coffee']),
            ('avatar',['--path',f'/users/{l["avatar_tokens.jason"]}/avatar']),
            ('static_css',['--path',app.session['css']]),('up',['--path','/up']),
            ('post_message',['--post-room',l['rooms.hq'],'--csrf',app.session['csrf']]),
        ]
    return [
        ('room_show',['--path',f'/rooms/{room}','--extra-paths',f'/api/bootstrap,/api/rooms,/api/users,/api/rooms/{room}/messages']),
        ('messages_page',['--path',f'/api/rooms/{room}/messages?before={before}']),
        ('sidebar',['--path','/api/rooms']),('search',['--path','/api/search?q=coffee']),
        ('avatar',['--path',f'/avatar/{l["users.jason"]}']),('static_css',['--path','/assets/app.css']),
        ('up',['--path','/up']),('post_message',['--post-room',l['rooms.hq'],'--csrf',app.session['csrf']]),
    ]


def validation(app):
    """Record actual response work, not just status 200, before timing it."""
    import re
    checks=[]
    for name,args in routes(app):
        if name=='post_message':continue
        path=args[1]
        status,body,headers=request(path,app.session['cookie'])
        assert status<400,(name,status,body[:200])
        (app.directory/(name+'.response')).write_bytes(body)
        row={'route':name,'path':path,'status':status,'identity_bytes':len(body),
             'content_type':next((v for k,v in headers.items() if k.lower()=='content-type'),''),
             'sha256':hashlib.sha256(body).hexdigest()}
        if name=='room_show' and app.name=='vampfire':
            row['requests']=1
            for extra in args[3].split(','):
                extra_status,extra_body,_=request(extra,app.session['cookie'])
                assert extra_status==200,(extra,extra_status)
                row['identity_bytes']+=len(extra_body);row['requests']+=1
                if extra.endswith('/messages'):
                    data=json.loads(extra_body)
                    row['message_ids']=[m['id'] for m in data]
                    row['messages']=len(data)
        elif name=='room_show':
            row['message_ids']=list(dict.fromkeys(map(int,re.findall(rb'data-message-id="(\d+)"',body))))
            row['messages']=len(row['message_ids']);row['requests']=1
        if name in ('messages_page','search'):
            if app.name=='vampfire':
                data=json.loads(body)
                messages=data if isinstance(data,list) else data['messages']
                row['messages']=len(messages)
                row['message_ids']=[m['id'] for m in messages]
                row['plain_text']=[m['plain'] for m in messages]
            else:
                row['message_ids']=list(dict.fromkeys(map(int,re.findall(rb'data-message-id="(\d+)"',body))))
                row['messages']=len(row['message_ids'])
            assert row['messages']==(40 if name=='messages_page' else 13),row
        checks.append(row)
    write(app.directory/'validation.json',checks)
    return checks


def compare_responses(out,rep):
    data={name:json.loads((out/f'{name}-{rep}/validation.json').read_text()) for name in ['rust','vampfire']}
    mapping=json.loads((WORK/'vampfire-seed/translation.json').read_text())['message_id_mapping']
    for route in ['room_show','messages_page','search']:
        rust=next(r for r in data['rust'] if r['route']==route)
        v=next(r for r in data['vampfire'] if r['route']==route)
        mapped=[mapping[str(i)] for i in rust['message_ids']]
        assert (sorted(mapped)==sorted(v['message_ids']) if route=='search' else mapped==v['message_ids']),(route,rust,v)
    print(f'Repetition {rep}: room/history order matches; search returns the same 13 messages (Rust ascending, V descending).',flush=True)


def run_app(name,rep,out,smoke):
    directory=out/f'{name}-{rep}';directory.mkdir()
    app=App(name,directory)
    report={'app':name,'rep':rep,'cold_start_ms':app.cold_ms,'load_average_start':os.getloadavg(),'http':[],'cable':[]}
    try:
        time.sleep(1 if smoke else 10)
        report['idle']=process_stats(app.pid)
        logged=lg(app,'login','--email',app.labels['emails.david'],'--password',app.labels['passwords.all'])
        app.session=lg(app,'scrape','--cookie',logged['cookie'],'--room',app.labels['rooms.watercooler'])
        app.session['cookie']=logged['cookie'];app.session['csrf']=app.session['csrf'] or ''
        report['validation']=validation(app)
        cookie=app.session['cookie']
        for name,args in routes(app):
            if not smoke:lg(app,'http','--cookie',cookie,*args,'--conc',4,'--duration',2)
            for conc in ([1] if smoke else [1,16,64]):
                res=lg(app,'http','--cookie',cookie,*args,'--conc',conc,'--duration',1 if smoke else 8,file=f'http-{name}-{conc}')
                res['route']=name;report['http'].append(res)
                assert res['errors']==0 and all(int(k)<400 for k in res['statuses']),res
                print(f'{app.name} {rep}: {name} c={conc}: {res["rps"]} ops/s p99={res["latency"].get("p99_ms")} ms',flush=True)
                write(directory/'result.json',report)
        for count in ([10] if smoke else [100,500,1000]):
            res=lg(app,'cable','--cookie',cookie,'--room',app.labels['rooms.watercooler'],
                '--csrf',app.session['csrf'],'--streams',','.join(app.session['streams']),
                '--clients',count,'--tput-secs',1 if smoke else 15,'--posters',4,
                '--latency-msgs',3 if smoke else 30,'--interval-ms',200,file=f'cable-{count}')
            report['cable'].append(res)
            write(directory/'result.json',report)
            print(f'{app.name} {rep}: fanout {count}: ready={res["ready"]}, paced={res["latency"]["complete"]}, saturated={res["throughput"]["complete"]}/{res["throughput"]["posted"]}, {res["throughput"]["delivered_msgs_per_sec"]} messages/s',flush=True)
            assert res['ready']==count and res['failed']==0 and res['post_errors']==0,res
            assert res['latency']['complete']==res['latency']['messages'],res
            assert res['throughput']['complete']==res['throughput']['posted'],res
            time.sleep(2)
        report['upload']=lg(app,'upload','--cookie',cookie,'--room',app.labels['rooms.hq'],
            '--csrf',app.session['csrf'],'--file',REFERENCE/'reference/test/fixtures/files/black_hole.jpg',
            '--reps',1 if smoke else 5,file='upload')
        assert all(r.get('thumb_status')==200 for r in report['upload']['runs']),report['upload']
        if app.name=='rust':
            report['upload_actual_thumbnail']=lg(app,'upload','--cookie',cookie,'--room',app.labels['rooms.hq'],
                '--csrf',app.session['csrf'],'--file',REFERENCE/'reference/test/fixtures/files/black_hole.jpg',
                '--reps',1 if smoke else 5,'--actual-thumbnail',1,file='upload-actual-thumbnail')
            assert all(r.get('thumb_status')==200 for r in report['upload_actual_thumbnail']['runs']),report['upload_actual_thumbnail']
        with sqlite3.connect(app.database) as db:
            report['final_message_count']=db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
            if app.name=='vampfire':report['pending_jobs_at_end']=db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0]
        report['peak_sampled_rss_bytes']=max(s['rss_bytes'] for s in app.samples)
        report['final']=process_stats(app.pid)
        report['load_average']=os.getloadavg()
        write(directory/'result.json',report)
    except Exception as error:
        report['error']=str(error)
        raise
    finally:
        report['peak_sampled_rss_bytes']=max((s['rss_bytes'] for s in app.samples),default=0)
        report['peak_wal_bytes']=max((s['wal_bytes'] for s in app.samples),default=0)
        report['final']=process_stats(app.pid)
        try:
            with sqlite3.connect(app.database,timeout=2) as db:
                report['final_message_count']=db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
                if app.name=='vampfire':
                    report['pending_jobs_by_attempt']=[{'attempts':a,'count':n} for a,n in db.execute('SELECT attempts,count(*) FROM jobs GROUP BY attempts')]
        except sqlite3.Error as error:
            report['final_database_error']=str(error)
        write(directory/'result.json',report)
        app.close()
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke',action='store_true')
    parser.add_argument('--out',type=Path)
    args=parser.parse_args()
    assert os.environ.get('VAMPFIRE_RESOURCE_GUARD'), 'Use scripts/resource_guard.py.'
    build=json.loads((ROOT/'.build/vampfire.build.json').read_text())
    assert build['mode']=='release'
    assert hashlib.sha256((ROOT/'.build/vampfire').read_bytes()).hexdigest()==build['binary_sha256']
    digest=hashlib.sha256()
    for path in sorted([*(ROOT/'src').glob('*'),*(ROOT/'public').rglob('*')]):
        if path.is_file():digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes())
    assert digest.hexdigest()==build['source_sha256'],'Application sources do not match the benchmark binary.'
    prefix='smoke-' if args.smoke else 'full-'
    out=(args.out or WORK/(prefix+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))).resolve()
    out.mkdir(parents=True,exist_ok=False)
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    metadata={
        'date':datetime.now(timezone.utc).isoformat(),'smoke':args.smoke,
        'rust_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REFERENCE,text=True).strip(),
        'vampfire_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'vampfire_build':build,'rust_image':RUST_IMAGE,
        'rust_runtime':json.loads((WORK/'rust-runtime/ready.json').read_text()),
        'image_metadata':json.loads(subprocess.check_output(['docker','image','inspect',RUST_IMAGE]))[0]['Config']['Labels'],
        'loadgen_sha256':hashlib.sha256(LOADGEN.read_bytes()).hexdigest(),
        'seed_translation':json.loads((WORK/'vampfire-seed/translation.json').read_text()),
        'cpu':next(line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
        'platform':platform.platform(),'server_cpus':SERVER_CPUS,'client_cpus':CLIENT_CPUS,
        'conditions':{'http_seconds':8,'http_concurrency':[1,16,64],'http_warmup_seconds':2,'http_warmup_concurrency':4,
            'cable_clients':[100,500,1000],'cable_latency_messages':30,'cable_interval_ms':200,'cable_throughput_seconds':15,
            'cable_posters':4,'upload_repetitions':5,'repetitions':3,'network':'HTTP/1.1 loopback, keepalive, Accept-Encoding gzip; uncompressed WebSockets',
            'server_processes':'Both native; Rust official production executable and media libraries extracted from the pinned image, using host glibc',
            'cold_start':'Native process start until /up, warm filesystem cache',
            'safety':'1536 MiB/no swap guard, memory.high=768 MiB, proactive stop at 1152 MiB; apps run sequentially'},
    }
    write(out/'environment.json',metadata)
    for rep in range(1,2 if args.smoke else 4):
        for name in (['rust','vampfire'] if rep%2 else ['vampfire','rust']):
            if not args.smoke:
                waited=0
                while os.getloadavg()[0]>=1.5 and waited<60:
                    time.sleep(10);waited+=10
                print(f'Load cooldown: {waited}s; load {os.getloadavg()}',flush=True)
            print(f'Starting {name} repetition {rep}, load average {os.getloadavg()}',flush=True)
            try:
                run_app(name,rep,out,args.smoke)
            except Exception as error:
                print(f'{name} repetition {rep} failed: {error}',flush=True)
                if args.smoke:raise
        compare_responses(out,rep)
    print('Finished:',out,flush=True)


if __name__=='__main__':
    main()
