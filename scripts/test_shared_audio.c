// Exercises the production ring in anonymous shared memory; no root/system files.
#include "../SharedAudio/VRSharedAudio.c"
#include <assert.h>
#include <sys/wait.h>
int main(void) {
    VRRegion *r=mmap(NULL,sizeof(*r),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANON,-1,0);
    assert(r!=MAP_FAILED);
    VRSharedHandle *writer=calloc(1,sizeof(*writer)),*reader=calloc(1,sizeof(*reader));
    writer->region=reader->region=r;writer->writer=1;reader->sampleTime=NAN;
    reader->staleTicks=UINT64_MAX;atomic_flag_clear(&reader->rendering);
    float input[]={0.25f,-0.5f,NAN,2},out[16];
    assert(vr_audio_read(reader,0,out,4,2)==0);
    vr_audio_begin(writer);vr_audio_write(writer,input,4);
    assert(vr_audio_read(reader,0,out,6,2)==1);
    assert(out[0]==0.25f&&out[1]==0.25f&&out[2]==-0.5f&&out[4]==0&&out[6]==1&&out[8]==0);
    assert(vr_audio_consumed(writer)==4);
    vr_audio_write(writer,input,4);
    vr_audio_read(reader,0,out,6,2);assert(vr_audio_consumed(writer)==4); // second client, same quantum
    vr_audio_read(reader,6,out,4,1);assert(vr_audio_consumed(writer)==8);
    vr_audio_begin(writer);assert(vr_audio_consumed(writer)==0);
    vr_audio_read(reader,10,out,4,1);assert(out[0]==0&&vr_audio_consumed(writer)==0);
    // Ring wrap and overflow must never expose slots from an older sequence.
    float *large=calloc(VR_AUDIO_CAPACITY+4,sizeof(float));
    large[4]=0.75f;large[VR_AUDIO_CAPACITY]=0.5f;
    vr_audio_write(writer,large,VR_AUDIO_CAPACITY+4);
    vr_audio_read(reader,14,out,4,1);assert(out[0]==0.75f);
    assert(vr_audio_consumed(writer)==8);
    free(large);
    // A stale acknowledgement tagged with an earlier generation is ignored.
    uint64_t oldGeneration=atomic_load(&r->generation);
    vr_audio_begin(writer);atomic_store(&r->consumed,(oldGeneration<<32)|99);
    assert(vr_audio_consumed(writer)==0);
    // Writer and reader run in separate processes, just like decoder and coreaudiod.
    vr_audio_begin(writer);
    pid_t child=fork();assert(child>=0);
    if(child==0) {vr_audio_write(writer,input,4);_exit(0);}
    int status;waitpid(child,&status,0);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);
    vr_audio_read(reader,18,out,4,1);assert(out[0]==0.25f&&vr_audio_consumed(writer)==4);
    atomic_store(&r->heartbeat,0);assert(vr_audio_read(reader,22,out,4,1)==0);
    free(writer);free(reader);munmap(r,sizeof(*r));
    puts("Shared audio: silence, clamping, multicast cache, reset, wrap, stale ack and cross-process tests passed");
}
