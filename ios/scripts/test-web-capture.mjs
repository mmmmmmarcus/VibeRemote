// Exercise the actual bundled capture script with controllable media promises.
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const swift=readFileSync(new URL('../Dictation/WebAudioCapture.swift',import.meta.url),'utf8');
const script=swift.split('<script>')[1].split('</script>')[0];
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve()};
function harness({deferResume=false}={}){
 let time=0;const events=[],requests=[],contexts=[],timers=new Map(),listeners={},resumes=[];let timer=0;
 class AudioContext{
  constructor(){this.state='suspended';this.sampleRate=48000;contexts.push(this)}
  async resume(){if(deferResume)await new Promise(r=>resumes.push(r));if(this.state!=='closed')this.state='running'}
  close(){this.state='closed';return Promise.resolve()}
  createScriptProcessor(){return this.processor={connect(){},disconnect(){},onaudioprocess:null}}
  createGain(){return{gain:{value:1},connect(){},disconnect(){}}}
  createMediaStreamSource(){return{connect(){},disconnect(){}}}
 }
 const audioSession={type:'auto',state:'active'};
 const window={webkit:{messageHandlers:{capture:{postMessage:m=>events.push(m)}}},addEventListener:(n,f)=>listeners[n]=f};
 const document={hidden:false,addEventListener:(n,f)=>listeners[n]=f};
 const sandbox={window,document,AudioContext,navigator:{audioSession,mediaDevices:{getUserMedia:()=>new Promise(r=>requests.push(r))}},performance:{now:()=>time},setInterval:f=>{timers.set(++timer,f);return timer},clearInterval:n=>timers.delete(n),btoa:s=>Buffer.from(s,'binary').toString('base64'),Int16Array,Uint8Array,Number,Math};
 vm.runInNewContext(script,sandbox);
 const grant=async i=>{const track={stopped:false,stop(){this.stopped=true}};requests[i]({getTracks:()=>[track],getAudioTracks:()=>[track]});await flush();return track};
 return{window,document,events,requests,contexts,timers,listeners,resumes,audioSession,grant,advance:ms=>{time+=ms;for(const f of [...timers.values()])f()}};
}
{
 const h=harness();assert.equal(h.contexts.length,0);assert.equal(h.requests.length,0);
 h.window.startCapture('a');h.window.stopCapture('a');const track=await h.grant(0);
 assert.ok(track.stopped);assert.equal(h.contexts.length,0);assert.equal(h.audioSession.type,'auto');assert.equal(h.timers.size,0);
}
{
 const h=harness({deferResume:true});h.window.startCapture('a');const a=await h.grant(0);
 h.window.stopCapture('a');h.window.startCapture('b');const b=await h.grant(1);
 h.resumes[0]();await flush();assert.ok(a.stopped);assert.equal(h.contexts[0].state,'closed');assert.equal(h.audioSession.type,'play-and-record');
 h.resumes[1]();await flush();assert.ok(h.contexts[1].processor);
 h.window.stopCapture('a');assert.equal(b.stopped,false);h.window.stopCapture('b');assert.ok(b.stopped);assert.equal(h.audioSession.type,'auto');
}
{
 const h=harness();h.window.startCapture('pcm');const track=await h.grant(0);
 const samples=new Float32Array(1024).fill(.25);
 for(let i=0;i<3;i++)h.contexts[0].processor.onaudioprocess({inputBuffer:{getChannelData:()=>samples}});
 const audio=h.events.filter(e=>e.type==='audio');assert.equal(audio.length,3);
 assert.equal(audio.reduce((n,e)=>n+Buffer.from(e.data,'base64').length,0),2048);
 assert.ok(audio.every(e=>e.id==='pcm'&&e.rms===.25));
 h.advance(3100);assert.ok(track.stopped);assert.equal(h.audioSession.type,'auto');assert.equal(h.timers.size,0);assert.equal(h.events.at(-1).type,'interrupted');
}
for(const event of ['pagehide','visibilitychange']){
 const h=harness();h.window.startCapture(event);const track=await h.grant(0);
 h.document.hidden=true;h.listeners[event]();assert.ok(track.stopped);assert.equal(h.contexts[0].state,'closed');assert.equal(h.timers.size,0);
}
console.log('Passed: no idle audio, release during permission/resume, stale hold isolation, PCM/rms, watchdog, dismissal cleanup.');
