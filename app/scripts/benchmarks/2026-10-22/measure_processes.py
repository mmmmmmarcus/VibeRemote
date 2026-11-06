#!/usr/bin/env python3
"""Read-only short CPU/capture-volume comparison; no editor text or captured packets."""
import argparse,json,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--seconds',type=float,default=30); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
def snapshot():
 rows={}
 for line in subprocess.check_output(['ps','-axo','pid=,time=,rss=,comm='],text=True).splitlines():
  values=line.strip().split(None,3)
  if len(values)!=4: continue
  pid,cpu,rss,path=values
  if path.endswith('/Contents/MacOS/VibeRemote'): name='app'
  elif path.endswith('/VibeRemoteVoiceBridge'): name='voice'
  elif path.endswith('/packetlogger'): name='capture'
  elif 'Core Audio Driver (VibeRemoteAudio.driver)' in path: name='audio_driver'
  elif path.endswith('/VibeRemoteHelper'): name='helper'
  else: continue
  parts=cpu.split(':'); seconds=float(parts[-1])+int(parts[-2])*60+(int(parts[-3])*3600 if len(parts)>2 else 0)
  rows[name]={'pid':int(pid),'cpu_seconds':seconds,'rss_kib':int(rss)}
 return rows
capture=Path.home()/'Library/Application Support/VibeRemote/MicrophoneBridge/packets.log'
start_size=capture.stat().st_size if capture.exists() else None
before=snapshot(); start=time.monotonic(); time.sleep(a.seconds); after=snapshot(); elapsed=time.monotonic()-start
end_size=capture.stat().st_size if capture.exists() else None
result={'duration_seconds':round(elapsed,3),'processes':{}}
for name,old in before.items():
 new=after.get(name)
 if new and new['pid']==old['pid']: result['processes'][name]={'pid':new['pid'],'cpu_percent_one_core':round(100*(new['cpu_seconds']-old['cpu_seconds'])/elapsed,3),'rss_mib':round(new['rss_kib']/1024,2)}
result['capture_bytes_per_second']=round((end_size-start_size)/elapsed,1) if start_size is not None and end_size is not None and end_size>=start_size else None
result['notes']='Live short sample, no forced idle and no hardware interaction. RSS excludes compressed memory; not a leak assessment.'
a.output.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result,indent=2))
