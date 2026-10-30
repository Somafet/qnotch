#!/usr/bin/env python3
"""Isolated normal-app consumer checks. Stops only processes created here; no account credentials."""
import concurrent.futures
import ctypes
import json
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[4]
BINARY = Path(os.environ.get('QNOTCH_CONSUMER_TEST_BINARY', str(REPO / 'dist/macos/QNotch.app/Contents/MacOS/QNotch')))
MODULES = ['media','stats','timer','volume','search','note','colorpicker','capture','filetray','clipboard','notifications','agents','weather','github','ai','terminal','scheduled']

def main():
    with tempfile.TemporaryDirectory(prefix='qn-cli-', dir='/tmp') as folder:
        root = Path(folder)
        env = dict(os.environ, QNOTCH_MAC_DATA_DIR=folder)
        def cli(*args, code=0):
            p = subprocess.run([str(BINARY), *args], env=env, capture_output=True, timeout=4)
            assert p.returncode == code, (args, p.returncode, p.stderr)
            assert not (p.stderr if code == 0 else p.stdout), (p.stdout, p.stderr)
            return json.loads((p.stdout if code == 0 else p.stderr).decode('utf-8'))
        cli('usage', '--json', code=3)
        for args in [('usage','--bad'), ('agents','--provider','claude'), ('usage','--json','--json')]:
            cli(*args, code=4)
        p = subprocess.run([str(BINARY),'usage','--help'], env=env, capture_output=True)
        assert p.returncode == 0 and not (root/'instance.lock').exists(), 'query launched GUI'
        (root/'general.json').write_text(json.dumps({'onboardingDone':True, 'showMenuBarIcon':False, 'disabledModules':[m for m in MODULES if m not in ['agents','ai']]}))
        (root/'ai.json').write_text(json.dumps({'claude':False,'codex':False}))
        before = {p.name:p.read_bytes() for p in root.glob('*.json')}
        def launch():
            return subprocess.Popen([str(BINARY),'--data-dir',folder], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        app = launch()
        try:
            deadline = time.monotonic()+10
            while not (root/'agents.sock').exists():
                assert app.poll() is None and time.monotonic()<deadline
                time.sleep(.05)
            assert not (root/'debug.sock').exists()
            before = {p.name:p.read_bytes() for p in root.glob('*.json')}
            usage = cli('usage','--json')
            assert usage['platform']=='macOS' and usage['module_status']=='ready'
            assert all(a['status']=='disabled' for a in usage['data']['accounts'])
            cli('usage','--account','missing',code=4)
            transcript = root/'synthetic.jsonl'
            transcript.write_bytes((REPO/'src/QNotch.Mac/Tests/Fixtures/consumer/transcript.jsonl').read_bytes())
            hook = {'session_id':'synthetic-session','hook_event_name':'UserPromptSubmit','cwd':'/synthetic/Café','transcript_path':str(transcript)}
            subprocess.run([str(BINARY),'agent'],env=env,input=json.dumps(hook).encode(),check=True,timeout=4)
            deadline = time.monotonic()+10
            while True:
                agents = cli('agents','--json')
                values = [u for u in agents['data']['usage'] if u['status']=='ok']
                if values: break
                assert time.monotonic()<deadline, agents
                time.sleep(.1)
            assert any(u['total']['tokens']==38 and u['total']['estimated_usd'] is None and not u['total']['pricing_complete'] for u in values)
            assert 'synthetic-session' not in json.dumps(agents) and 'Café' not in json.dumps(agents,ensure_ascii=False)
            details = cli('agents','--details')
            assert any(s['project']=='Café' for s in details['data']['sessions'])
            info = (root/'instance.lock').stat()
            path = f'/tmp/qnotch-consumer-{os.geteuid()}-{info.st_dev}-{info.st_ino}.sock'
            assert Path(path).stat().st_mode & 0o777 == 0o600
            def raw(payload):
                with socket.socket(socket.AF_UNIX) as s:
                    s.settimeout(3); s.connect(path); s.sendall(payload+b'\n')
                    return json.loads(s.recv(65536))
            assert raw(b'x'*4097)['error']['code']=='size_limit'
            assert raw(b'{"schema_version":2,"command":"usage","details":false}')['error']['code']=='unsupported_version'
            assert raw(b'{bad')['error']['code']=='invalid_arguments'
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda _: cli('agents','--json'),range(16)))
            stalled=[]
            for _ in range(4):
                s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(path); stalled.append(s)
            time.sleep(2.2)
            for s in stalled:
                assert s.recv(1)==b''; s.close()
            lib = ctypes.CDLL('/usr/lib/libproc.dylib')
            def sample():
                buf = (ctypes.c_ubyte * 512)()
                assert lib.proc_pid_rusage(app.pid, 2, ctypes.byref(buf)) == 0
                import struct
                return struct.unpack_from('QQ', bytes(buf), 16), struct.unpack_from('Q', bytes(buf), 64)[0]
            cpu0, rss0 = sample(); t0 = time.monotonic()
            time.sleep(10)
            cpu1, rss1 = sample(); elapsed = time.monotonic()-t0
            idle = {'seconds':elapsed,'cpu_percent_one_core':(sum(cpu1)-sum(cpu0))/1e9/elapsed*100,'resident_bytes_start':rss0,'resident_bytes_end':rss1,'method':'proc_pid_rusage v2; two endpoints; collapsed, AI providers disabled, Agents enabled, T3 may observe this active conversation'}
            samples=[]
            for _ in range(40):
                start=time.perf_counter(); cli('agents','--json'); samples.append((time.perf_counter()-start)*1000)
            assert all((root/name).read_bytes()==data for name,data in before.items())
            # Actual external JSON consumer; known fixture total and UTF-8 have already been asserted.
            consumer = subprocess.run(['python3','-c','import json,sys; d=json.load(sys.stdin); assert d["schema_version"]==1'],input=json.dumps(agents).encode(),check=True)
            report={'platform':platform.platform(),'machine':platform.machine(),'idle':idle,'sample_count':len(samples),'latency_ms':{'median':statistics.median(samples),'p95':sorted(samples)[37],'max':max(samples)},'checks':'passed','limitations':'Synthetic disabled-provider configuration; no live quota accuracy or matched pre-change idle baseline.'}
        finally:
            app.terminate(); app.wait(timeout=5)
        # Fully disabled modules: no provider sockets or module settings constructed.
        (root/'general.json').write_text(json.dumps({'onboardingDone':True,'showMenuBarIcon':False,'disabledModules':MODULES}))
        (root/'agents.sock').unlink(missing_ok=True)
        app=launch()
        try:
            deadline=time.monotonic()+10
            while True:
                try:
                    state=cli('agents','--json'); break
                except AssertionError:
                    assert time.monotonic()<deadline; time.sleep(.05)
            assert state['module_status']=='disabled' and state['data'] is None
            assert cli('usage','--account','unresolved')['module_status']=='disabled'
            assert not (root/'agents.sock').exists()
        finally:
            app.terminate(); app.wait(timeout=5)
        # A same-user peer that accepts and stalls exercises the CLI's connected timeout/exit 1.
        info = (root/'instance.lock').stat()
        path = f'/tmp/qnotch-consumer-{os.geteuid()}-{info.st_dev}-{info.st_ino}.sock'
        Path(path).unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path); server.listen(1)
            try:
                start=time.monotonic()
                failure=cli('usage','--json',code=1)
                assert failure['error']['code']=='timeout' and time.monotonic()-start < 3
            finally:
                Path(path).unlink(missing_ok=True)
        with tempfile.TemporaryDirectory(prefix='qn-other-',dir='/tmp') as other:
            result=subprocess.run([str(BINARY),'usage','--data-dir',other],capture_output=True,timeout=3)
            assert result.returncode==3 and not result.stdout

        output=REPO/'dist/macos/consumer-cli'; output.mkdir(exist_ok=True)
        (output/'integration.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))

if __name__=='__main__': main()
