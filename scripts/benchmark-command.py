#!/usr/bin/env python3
"""Opt-in local Codex/Cua latency study. Stores only timing/correctness metadata.
Uses the installed foreground gate. Never approves a pending foreground operation.
An exec prewarm delays stdin delivery; warmup is reported separately, never hidden.
"""
import argparse, json, os, pathlib, queue, re, signal, subprocess, sys, tempfile, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path.home()/'.local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex'
DRIVER = '/Applications/CuaDriver.app/Contents/MacOS/cua-driver'
APP = '/Applications/VibeRemote.app/Contents/MacOS/VibeRemote'
STOP = False
def request_stop(*_):
    global STOP
    STOP = True

def proxy(directory, owner):
    child = subprocess.Popen([APP, '--command-mcp-proxy', DRIVER, directory, owner], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    lock = threading.Lock(); pending = {}; observed_buttons = {}
    def record(row):
        with lock, open(pathlib.Path(directory)/'timing.jsonl','a') as f:
            f.write(json.dumps(dict(t=time.monotonic(),**row))+'\n')
    def receive():
        for line in child.stdout:
            try:
                value=json.loads(line); ident=str(value.get('id'))
                if ident in pending:
                    method,tool=pending.pop(ident)
                    row=dict(event='response',method=method,tool=tool,error=bool(value.get('error') or value.get('result',{}).get('isError')))
                    if tool=='jev_click_sequence':
                        batch=value.get('result',{}).get('structuredContent',{})
                        row['jev_clicks']=len(batch.get('clicked_labels',[]))
                        row['jev_labels']=[label for label in batch.get('clicked_labels',[]) if label in set('0123456789') | {'All Clear','Clear','Delete','Percent','Divide','Multiply','Subtract','Add','Change Sign','Point','Equals'}]
                        row['jev_handoff']=batch.get('status')=='handoff'
                        row['jev_reason']=batch.get('reason','')
                        if batch.get('sequence_dispatched') and batch.get('observed_at_unix'):
                            match=re.search(r'AXStaticText = "([0-9,]+)" \(Edit field\)',batch.get('observed_tree',''))
                            if match:
                                row['display']=match.group(1).replace(',','')
                                row['post_action_snapshot']=True
                    if tool=='get_window_state':
                        payload=value.get('result',{})
                        parts=[payload.get('structuredContent',{})]
                        for block in payload.get('content',[]):
                            if block.get('type')=='text':
                                try:parts.append(json.loads(block.get('text','')))
                                except ValueError:pass
                        for part in parts:
                            if not isinstance(part,dict):continue
                            # Driver indexes actionable rows only; Calculator display is static text.
                            match=re.search(r'AXStaticText = "([0-9,]+)" \(Edit field\)',part.get('tree_markdown',''))
                            if match:row['display']=match.group(1).replace(',','')
                            if part.get('app_name') == 'Calculator':
                                observed_buttons.clear()
                                for e in part.get('elements',[]):
                                    if e.get('role') == 'AXButton' and e.get('label') in set('0123456789') | {'All Clear','Clear','Delete','Percent','Divide','Multiply','Subtract','Add','Change Sign','Point','Equals'}:
                                        observed_buttons[str(e.get('element_token'))] = e['label']
                                        observed_buttons[str(e.get('element_index'))] = e['label']
                            for element in part.get('elements',[]):
                                if element.get('label')=='Edit field' and isinstance(element.get('value'),str):
                                    digits=re.sub(r'[^0-9]','',element['value'])
                                    if digits and len(digits)<=12:row['display']=digits
                        for part in parts:
                            if isinstance(part,dict) and part.get('degraded'):
                                row['degraded_reason']=part.get('degraded_reason','unknown')
                                # An unresolved target alone does not prove the Mac is locked.
                                if part.get('degraded_reason') in ('screen_locked','session_locked'):
                                    pathlib.Path(directory,'environment-invalid').touch()
                    record(row)
            except (ValueError,AttributeError): pass
            sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
    threading.Thread(target=receive,daemon=True).start()
    try:
        for line in sys.stdin.buffer:
            try:
                value=json.loads(line); method=value.get('method',''); tool=value.get('params',{}).get('name','') if method=='tools/call' else ''
                if 'id' in value:pending[str(value['id'])]=(method,tool)
                row=dict(event='request',method=method,tool=tool)
                if tool=='click':
                    args=value.get('params',{}).get('arguments',{})
                    label=observed_buttons.get(str(args.get('element_token',args.get('element_index'))))
                    if label:row['button']=label
                record(row)
            except (ValueError,AttributeError):pass
            child.stdin.write(line);child.stdin.flush()
    finally:
        child.terminate()
        try:child.wait(timeout=3)
        except subprocess.TimeoutExpired:child.kill();child.wait()

TASKS={
 'read':('只在后台找到 macOS 计算器，读取当前显示的结果。不要计算、不要改变内容、不要显示到前台。最后只回复读到的数字。','4608'),
 'calculate':('只操作 macOS 计算器，在后台先清零，再计算 128 × 36，只能点击界面上的数字和运算按钮，读取界面验证结果。不要切到前台。最后只回复核实后的结果数字。','4608'),
}

def arguments(directory,model):
    source=(ROOT/'CommandExecution.swift').read_text()
    instruction=re.search(r'let instructions = """\n(.*?)\n        """',source,re.S).group(1)
    instruction='\n'.join(x.strip() for x in instruction.splitlines()).replace('\\(target)','Calculator (com.apple.calculator)')
    tools=json.loads('['+re.search(r'static let tools = \[(.*?)\]',source,re.S).group(1)+']')
    if model == 'hybrid':
        batch=(ROOT/'CommandJevBatch.swift').read_text()
        extra=re.search(r'static let instructions = """\n(.*?)\n    """',batch,re.S).group(1)
        instruction+='\n'+extra
        tools.append('jev_click_sequence')
        pathlib.Path(directory,'jev-enabled').touch()
    args=[str(CLI),'exec','--ignore-user-config','--ephemeral','--skip-git-repo-check','--json','--color','never','-C',directory,'-s','read-only']
    for feature in ['shell_tool','apps','browser_use','multi_agent']:args+=['--disable',feature]
    args+=['--enable','skip_host_skill_discovery']
    cfg={'suppress_unstable_features_warning':True,'project_doc_max_bytes':0,'web_search':'disabled','approval_policy':'on-request','approvals_reviewer':'auto_review','developer_instructions':instruction,'mcp_servers.cua.command':sys.executable,'mcp_servers.cua.args':[str(pathlib.Path(__file__).resolve()),'--proxy',directory,str(os.getpid())],'mcp_servers.cua.required':True,'mcp_servers.cua.startup_timeout_sec':30,'mcp_servers.cua.tool_timeout_sec':1200,'mcp_servers.cua.enabled_tools':tools}
    if model not in ('baseline','hybrid'):cfg.update(model=model,model_reasoning_effort='low')
    for k,v in cfg.items():args+=['-c',k+'='+json.dumps(v,ensure_ascii=False)]
    return args+['-']

def run(model,task,warm):
    prompt,expected=TASKS[task]
    with tempfile.TemporaryDirectory(prefix='viberemote-benchmark-') as directory:
        started=time.monotonic()
        proc=subprocess.Popen(arguments(directory,model),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1,start_new_session=True)
        q=queue.Queue()
        def read():
            for line in proc.stdout:
                try:q.put((time.monotonic(),json.loads(line)))
                except ValueError:pass
            q.put((time.monotonic(),None))
        threading.Thread(target=read,daemon=True).start()
        if warm:time.sleep(warm)
        submitted=time.monotonic();proc.stdin.write(prompt);proc.stdin.close()
        first_event=first_tool=None; final=''; completed=False;blocked=False;errors=0;requests=0
        while not STOP and time.monotonic()-submitted<120:
            if (pathlib.Path(directory)/'foreground-request.json').exists():blocked=True;break
            if (pathlib.Path(directory)/'environment-invalid').exists():break
            try:t,event=q.get(timeout=.1)
            except queue.Empty:continue
            if event is None:break
            if first_event is None:first_event=t
            if event.get('type')=='turn.completed':completed=True
            if event.get('type') in ('turn.failed','error'):errors+=1
            item=event.get('item',{})
            if item.get('type')=='mcp_tool_call' and event.get('type')=='item.started':
                requests+=1
                if first_tool is None:first_tool=t
            if item.get('type')=='agent_message' and event.get('type')=='item.completed':final=item.get('text','')
        ended=time.monotonic()
        invalid=(pathlib.Path(directory)/'environment-invalid').exists()
        (pathlib.Path(directory)/'cancelled').touch()
        if proc.poll() is None:
            os.killpg(proc.pid,signal.SIGTERM)
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
        trace=pathlib.Path(directory)/'timing.jsonl'
        rows=[json.loads(x) for x in trace.read_text().splitlines()] if trace.exists() else []
        init=[r['t'] for r in rows if r['method']=='initialize' and r['event']=='response']
        pairing={};tool_total=0;tool_errors=0;calls=[]
        for row in rows:
            key=(row['method'],row['tool'])
            if row['event']=='request':pairing[key]=row['t']
            elif row['method']=='tools/call' and key in pairing:
                elapsed=row['t']-pairing[key];tool_total+=elapsed;tool_errors+=row['error'];calls.append({'tool':row['tool'],'seconds':round(elapsed,3),'error':row['error']})
        metrics_path=pathlib.Path(directory)/"timing.json"
        driver_metrics=json.loads(metrics_path.read_text()) if metrics_path.exists() else {}
        elapsed=ended-submitted
        # Expected arithmetic/display output; no model-generated judgement of its own correctness.
        observations=[r for r in rows if r.get('display')]
        mutations=[r for r in rows if r['event']=='response' and r['tool'] in ['click','press_key','hotkey','type_text','set_value','jev_click_sequence'] and not r.get('error')]
        verified=bool(observations and observations[-1]['display']==expected)
        if task=='calculate':verified=bool(verified and mutations and (observations[-1]['t']>mutations[-1]['t'] or (observations[-1]['t']==mutations[-1]['t'] and observations[-1].get('post_action_snapshot'))))
        action_sequence=[]
        for row in rows:
            if 'button' in row:action_sequence.append(row['button'])
            action_sequence.extend(row.get('jev_labels',[]))
        steps_verified=task!='calculate' or (bool(action_sequence) and action_sequence[0] in ('Clear','All Clear') and [x for x in action_sequence if x not in ('Clear','All Clear')]==['1','2','8','Multiply','3','6','Equals'])
        correct=steps_verified and completed and not blocked and not invalid and not STOP and re.sub(r'[^0-9]','',final)==expected and (verified if task=='calculate' else True)
        result=dict(action_sequence=action_sequence,steps_verified=steps_verified,driver_metrics=driver_metrics,model=model,task=task,prewarm_seconds=warm,total_seconds=round(elapsed,3),launch_to_finish_seconds=round(ended-started,3),first_event_seconds=round(first_event-submitted,3) if first_event else None,mcp_ready_seconds=round(init[0]-submitted,3) if init else None,first_tool_seconds=round(first_tool-submitted,3) if first_tool else None,tool_seconds=round(tool_total,3),other_seconds=round(elapsed-tool_total,3),tool_calls=requests,tool_errors=tool_errors,correct=correct,display_verified=verified,completed=completed,foreground_blocked=blocked,environment_invalid=invalid,interrupted=STOP,errors=errors,calls=calls,buttons=[r['button'] for r in rows if 'button' in r],jev_clicks=sum(r.get('jev_clicks',0) for r in rows),jev_reasons=[r['jev_reason'] for r in rows if 'jev_reason' in r])
        return result

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--proxy':proxy(sys.argv[2],sys.argv[3]);sys.exit()
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--models',default='baseline,gpt-6-luna');parser.add_argument('--tasks',default='read');parser.add_argument('--repeats',type=int,default=3);parser.add_argument('--prewarm',type=float,default=0);parser.add_argument('--output',required=True)
    a=parser.parse_args()
    signal.signal(signal.SIGINT,request_stop);signal.signal(signal.SIGTERM,request_stop)
    for i in range(a.repeats):
        models=a.models.split(',');models=models if i%2==0 else list(reversed(models))
        for task in a.tasks.split(','):
            for model in models:
                result=run(model,task,a.prewarm);result['repeat']=i+1
                with open(a.output,'a') as f:f.write(json.dumps(result)+'\n')
                print(json.dumps(result),flush=True)
                if STOP or result['environment_invalid']:raise SystemExit('Benchmark stopped: interrupted or desktop fixture unavailable. Do not score this as model accuracy.')
