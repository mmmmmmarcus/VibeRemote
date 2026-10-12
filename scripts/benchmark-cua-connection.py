#!/usr/bin/env python3
"""Compare fresh MCP setup with tools/list on the same initialized connection.
No desktop actions or model calls; the installed VibeRemote policy proxy remains in path.
"""
import json,os,pathlib,queue,statistics,subprocess,tempfile,threading,time
APP='/Applications/VibeRemote.app/Contents/MacOS/VibeRemote'
DRIVER='/Applications/CuaDriver.app/Contents/MacOS/cua-driver'
def sample():
    with tempfile.TemporaryDirectory(prefix='viberemote-connection-') as directory:
        began=time.monotonic()
        p=subprocess.Popen([APP,'--command-mcp-proxy',DRIVER,directory,str(os.getpid())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
        q=queue.Queue()
        def read():
            for line in p.stdout:
                try:q.put(json.loads(line))
                except ValueError:pass
        threading.Thread(target=read,daemon=True).start()
        def request(ident,method,params):
            p.stdin.write(json.dumps(dict(jsonrpc='2.0',id=ident,method=method,params=params))+'\n');p.stdin.flush()
            end=time.monotonic()+10
            while time.monotonic()<end:
                r=q.get(timeout=max(.01,end-time.monotonic()))
                if r.get('id')==ident:
                    if r.get('error'):raise RuntimeError('MCP request failed')
                    return r
            raise TimeoutError()
        try:
            request(1,'initialize',{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'viberemote_connection_benchmark','version':'1'}})
            p.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n');p.stdin.flush()
            request(2,'tools/list',{})
            ready=time.monotonic();request(3,'tools/list',{});done=time.monotonic()
            return {'fresh_seconds':round(ready-began,4),'warm_seconds':round(done-ready,4)}
        finally:
            pathlib.Path(directory,'cancelled').touch();p.terminate()
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait()
if __name__=='__main__':
    rows=[sample() for _ in range(5)]
    print(json.dumps({'samples':rows,'fresh_median':statistics.median(r['fresh_seconds'] for r in rows),'warm_median':statistics.median(r['warm_seconds'] for r in rows),'scope':'MCP connection/schema discovery only; not an end-to-end agent benchmark'},indent=2))
