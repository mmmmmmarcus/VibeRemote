#!/usr/bin/env python3
"""Bounded macOS diagnostic for the confirmed 026D / 0A00 glass remote.

Default: read-only Feature E1 (LOCK). Explicit --zero-duration also sends exactly
31 10 00 00 00 00, only after E1 01; firmware discards its zero duration before
changing button state. No unlock, persistent write, or audio-start capability.
Quit VibeRemote before use to release its exclusive HID ownership, and relaunch
it in a caller's finally block. Use a fresh registry ID from ioreg, not a saved ID.
The caller must impose a process timeout. Bluetooth GetReport may internally
select a keyhole report, although this script calls only GetReport by default.
See FirstGenerationMicrophoneControl.md E13 for evidence and limits.
"""
import ctypes as c, json, time
from datetime import datetime
CF=c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
IO=c.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
def fn(lib,n,ret,*args):
 f=getattr(lib,n);f.restype=ret;f.argtypes=args;return f
P=c.c_void_p; U=c.c_uint32; L=c.c_long
snew=fn(CF,'CFStringCreateWithCString',P,P,c.c_char_p,U)
release=fn(CF,'CFRelease',None,P)
num=fn(CF,'CFNumberGetValue',c.c_bool,P,c.c_int,P)
strget=fn(CF,'CFStringGetCString',c.c_bool,P,P,L,U)
prop=fn(IO,'IOHIDDeviceGetProperty',P,P,P)
match=fn(IO,'IORegistryEntryIDMatching',P,c.c_uint64)
service=fn(IO,'IOServiceGetMatchingService',U,U,P)
orelease=fn(IO,'IOObjectRelease',c.c_int,U)
create=fn(IO,'IOHIDDeviceCreate',P,P,U)
open_=fn(IO,'IOHIDDeviceOpen',c.c_int,P,U)
close=fn(IO,'IOHIDDeviceClose',c.c_int,P,U)
get=fn(IO,'IOHIDDeviceGetReport',c.c_int,P,c.c_int,L,P,P)
def property(d,key,numeric=False):
 k=snew(None,key.encode(),0x8000100)
 try:
  v=prop(d,k)
  if not v:return None
  if numeric:
   out=L();return out.value if num(v,4,c.byref(out)) else None
  out=c.create_string_buffer(512);return out.value.decode() if strget(v,out,len(out),0x8000100) else None
 finally:release(k)
def read(entry,report=0xe1, zero_duration=False):
 s=service(0,match(entry))
 if not s:raise RuntimeError('No matching registry entry')
 d=create(None,s);orelease(s)
 if not d:raise RuntimeError('Could not create HID device')
 opened=False
 try:
  identity={k:property(d,k,k in ['VendorID','ProductID','PrimaryUsagePage','PrimaryUsage']) for k in ['VendorID','ProductID','PrimaryUsagePage','PrimaryUsage','Transport','kBTHardwareRevisionKey','kBTFirmwareRevisionKey']}
  if not (identity['VendorID']==76 and identity['ProductID']==621 and identity['kBTHardwareRevisionKey']=='0A00' and identity['Transport']=='Bluetooth Low Energy' and identity['PrimaryUsagePage']==0xff00 and identity['PrimaryUsage']==0x0b and identity['kBTFirmwareRevisionKey']=='B000750001001801300033022000040431001800C1000100'):
   raise RuntimeError(f'Unrecognized device/interface/firmware; no probe: {identity}')
  result=open_(d,0);opened=result==0
  print(json.dumps({'time':datetime.now().isoformat(),'entry':entry,'identity':identity,'open':hex(result&0xffffffff)}),flush=True)
  if result:return
  b=(c.c_ubyte*209)();b[0]=report;l=L(209);start=time.monotonic()
  r=get(d,2,report,b,c.byref(l))
  print(json.dumps({'time':datetime.now().isoformat(),'report':hex(report),'result':hex(r&0xffffffff),'length':l.value,'data':bytes(b[:max(0,min(209,l.value))]).hex(' ') if r==0 else None,'seconds':round(time.monotonic()-start,3)}),flush=True)
  if zero_duration:
   if not (report == 0xe1 and r == 0 and l.value == 2 and bytes(b[:2]) == bytes([0xe1,1])):
    raise RuntimeError('LOCK=1 not confirmed; skipping write')
   setter=fn(IO,'IOHIDDeviceSetReport',c.c_int,P,c.c_int,L,P,L)
   payload=(c.c_ubyte*6)(0x31,0x10,0,0,0,0)
   start=time.monotonic();status=setter(d,2,0x31,payload,6)
   print(json.dumps({'time':datetime.now().isoformat(),'operation':'zero-duration-31','bytes':bytes(payload).hex(' '),'result':hex(status&0xffffffff),'seconds':round(time.monotonic()-start,3)}),flush=True)
   b=(c.c_ubyte*209)();b[0]=0xe1;l=L(209)
   status=get(d,2,0xe1,b,c.byref(l))
   print(json.dumps({'operation':'LOCK-read-after','result':hex(status&0xffffffff),'length':l.value,'data':bytes(b[:max(0,min(209,l.value))]).hex(' ') if status==0 else None}),flush=True)
 finally:
  if opened:close(d,0)
  release(d)
if __name__ == '__main__':
 import argparse
 parser = argparse.ArgumentParser(description=__doc__)
 parser.add_argument('registry_id', type=int)
 parser.add_argument('--report', type=lambda value: int(value, 0), choices=(0xe1, 0xff), default=0xe1)
 parser.add_argument('--zero-duration', action='store_true', help='One fixed zero-duration 31 request, only after reading LOCK=1')
 args = parser.parse_args()
 if args.zero_duration and args.report != 0xe1:
  parser.error('--zero-duration requires --report 0xe1')
 read(args.registry_id, args.report, args.zero_duration)
