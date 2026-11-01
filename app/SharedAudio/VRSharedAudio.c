#include "include/VRSharedAudio.h"
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <grp.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <mach/mach_time.h>
#define MAGIC 0x56524134u
#define MAX_RENDER 16384u
typedef struct {
    uint32_t magic, version, capacity, sampleRate;
    _Atomic uint64_t generation, written, consumed, heartbeat, underruns;
    _Atomic uint64_t slots[VR_AUDIO_CAPACITY];
} VRRegion;
struct VRSharedHandle {
    VRRegion *region;
    int fd, writer;
    uint64_t generation, cursor, staleTicks;
    double sampleTime;
    uint32_t cachedFrames;
    atomic_flag rendering;
    float cache[MAX_RENDER];
};
static int safe_directory(const char *path) {
    if (mkdir(path, 0755) && errno != EEXIST) return -1;
    struct stat s;
    if (lstat(path,&s) || !S_ISDIR(s.st_mode) || s.st_uid != 0 || (s.st_mode & 0022)) { errno=EPERM; return -1; }
    return 0;
}
static void path_for(uid_t uid, char *path, size_t length) {
    snprintf(path,length,VR_AUDIO_DIRECTORY "/%u.pcm",uid);
}
int vr_audio_prepare(uid_t uid) {
    if (geteuid()!=0 || uid<500) { errno=EPERM; return -1; }
    if (safe_directory("/Library/Application Support/VibeRemote") || safe_directory(VR_AUDIO_DIRECTORY)) return -1;
    struct group *group=getgrnam("_coreaudiod");
    if (!group) { errno=ENOENT; return -1; }
    char path[512]; path_for(uid,path,sizeof(path));
    int fd=open(path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) return -1;
    struct stat s; int result=-1;
    if (fstat(fd,&s) || !S_ISREG(s.st_mode) || s.st_nlink!=1 || (s.st_uid!=0 && s.st_uid!=uid)) goto done;
    // Existing files are never resized while mapped by a running audio server.
    if (s.st_size!=0 && s.st_size!=sizeof(VRRegion)) { errno=EINVAL; goto done; }
    if (s.st_size==0 && ftruncate(fd,sizeof(VRRegion))) goto done;
    if (s.st_size==0) {
        VRRegion *r=mmap(NULL,sizeof(*r),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
        if(r==MAP_FAILED) goto done;
        r->version=1;r->capacity=VR_AUDIO_CAPACITY;r->sampleRate=VR_AUDIO_RATE;r->magic=MAGIC;
        munmap(r,sizeof(*r));
    }
    if (fchown(fd,uid,group->gr_gid) || fchmod(fd,0660)) goto done;
    result=0;
done: close(fd); return result;
}
VRSharedHandle *vr_audio_open(uid_t uid,int writer) {
    char path[512]; path_for(uid,path,sizeof(path));
    int fd=open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) return NULL;
    struct stat s; struct group *group=getgrnam("_coreaudiod");
    if(fstat(fd,&s) || !group || !S_ISREG(s.st_mode) || s.st_uid!=uid || s.st_gid!=group->gr_gid || s.st_nlink!=1 || (s.st_mode&0777)!=0660 || s.st_size!=sizeof(VRRegion)) {close(fd);errno=EPERM;return NULL;}
    VRRegion *r=mmap(NULL,sizeof(*r),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(r==MAP_FAILED){close(fd);return NULL;}
    if(writer && r->magic==0) { r->version=1;r->capacity=VR_AUDIO_CAPACITY;r->sampleRate=VR_AUDIO_RATE;r->magic=MAGIC; }
    if(r->magic!=MAGIC || r->version!=1 || r->capacity!=VR_AUDIO_CAPACITY || r->sampleRate!=VR_AUDIO_RATE){munmap(r,sizeof(*r));close(fd);errno=EINVAL;return NULL;}
    VRSharedHandle *h=calloc(1,sizeof(*h));if(!h){munmap(r,sizeof(*r));close(fd);return NULL;}
    h->region=r;h->fd=fd;h->writer=writer;h->sampleTime=NAN;atomic_flag_clear(&h->rendering);
    mach_timebase_info_data_t tb;mach_timebase_info(&tb);h->staleTicks=(uint64_t)(3e9*(double)tb.denom/tb.numer);
    if(writer) vr_audio_begin(h);
    return h;
}
void vr_audio_close(VRSharedHandle *h){if(!h)return;if(h->writer)atomic_store(&h->region->heartbeat,0);munmap(h->region,sizeof(VRRegion));close(h->fd);free(h);}
void vr_audio_heartbeat(VRSharedHandle *h){if(h&&h->writer)atomic_store_explicit(&h->region->heartbeat,mach_absolute_time(),memory_order_release);}
void vr_audio_begin(VRSharedHandle *h){
    if(!h||!h->writer)return;
    VRRegion*r=h->region;
    // Odd generation = reset in progress. A tagged read acknowledgement cannot
    // accidentally complete the next utterance when an old render overlaps reset.
    uint64_t generation=atomic_load(&r->generation);
    generation=(generation+2)&~1ULL;
    atomic_store(&r->generation,generation-1);
    atomic_store(&r->written,0);atomic_store(&r->consumed,generation<<32);
    atomic_store(&r->generation,generation);vr_audio_heartbeat(h);
}
uint64_t vr_audio_write(VRSharedHandle *h,const float *samples,uint32_t count){
    if(!h||!h->writer||!samples)return 0;VRRegion*r=h->region;uint64_t w=atomic_load(&r->written);
    for(uint32_t i=0;i<count;i++){float f=isfinite(samples[i])?fmaxf(-1,fminf(1,samples[i])):0;uint32_t bits;memcpy(&bits,&f,4);
        uint64_t value=((uint64_t)(uint32_t)(w+i+1)<<32)|bits;
        atomic_store_explicit(&r->slots[(w+i)%VR_AUDIO_CAPACITY],value,memory_order_release);}
    atomic_store_explicit(&r->written,w+count,memory_order_release);vr_audio_heartbeat(h);return w+count;
}
uint64_t vr_audio_written(VRSharedHandle*h){return h?atomic_load(&h->region->written):0;}
uint64_t vr_audio_consumed(VRSharedHandle*h){
    if(!h)return 0;uint64_t consumed=atomic_load(&h->region->consumed);
    return (consumed>>32)==(uint32_t)atomic_load(&h->region->generation)?(uint32_t)consumed:0;
}
uint64_t vr_audio_underruns(VRSharedHandle*h){return h?atomic_load(&h->region->underruns):0;}
int vr_audio_read(VRSharedHandle*h,double time,float*out,uint32_t n,uint32_t channels){
    if(!h||!out||!channels||channels>64||n>MAX_RENDER)return 0;
    VRRegion*r=h->region;uint64_t beat=atomic_load_explicit(&r->heartbeat,memory_order_acquire);
    if(!beat||mach_absolute_time()-beat>h->staleTicks)return 0;
    if(atomic_flag_test_and_set_explicit(&h->rendering,memory_order_acquire)){memset(out,0,n*channels*sizeof(float));return 1;}
    uint64_t gen=atomic_load(&r->generation),w=atomic_load_explicit(&r->written,memory_order_acquire);
    if(gen&1){memset(out,0,n*channels*sizeof(float));atomic_flag_clear(&h->rendering);return 1;}
    if(gen!=h->generation){h->generation=gen;h->cursor=w>VR_AUDIO_CAPACITY?w-VR_AUDIO_CAPACITY:0;h->sampleTime=NAN;}
    if(time!=h->sampleTime||n!=h->cachedFrames){
        if(w<h->cursor)h->cursor=w;
        if(w-h->cursor>VR_AUDIO_CAPACITY)h->cursor=w-VR_AUDIO_CAPACITY;
        uint32_t available=(uint32_t)(w-h->cursor),take=available<n?available:n;
        for(uint32_t i=0;i<take;i++){uint64_t v=atomic_load_explicit(&r->slots[(h->cursor+i)%VR_AUDIO_CAPACITY],memory_order_acquire);uint32_t bits=(uint32_t)v;
            float f=0;if((uint32_t)(v>>32)==(uint32_t)(h->cursor+i+1))memcpy(&f,&bits,4);h->cache[i]=isfinite(f)?f:0;}
        memset(h->cache+take,0,(n-take)*sizeof(float));h->cursor+=take;
        atomic_store(&r->consumed,((uint64_t)(uint32_t)gen<<32)|(uint32_t)h->cursor);if(take<n)atomic_fetch_add(&r->underruns,n-take);
        h->sampleTime=time;h->cachedFrames=n;
    }
    for(uint32_t i=0;i<n;i++)for(uint32_t c=0;c<channels;c++)out[i*channels+c]=h->cache[i];
    atomic_flag_clear_explicit(&h->rendering,memory_order_release);return 1;
}
