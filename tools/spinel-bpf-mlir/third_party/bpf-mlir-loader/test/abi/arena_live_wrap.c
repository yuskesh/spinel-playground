/* E062 live instrumentation: count/record only; delegate every operation unchanged. */
#define _GNU_SOURCE
#include "arena_live_instrument.h"
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <time.h>
int e062_target_loads;
static struct bpf_object *target;
static int mmap_ok,mmap_fail,munmap_ok;
static uint32_t map_ids[8],prog_ids[8];static size_t nm,np;static int capture_error;
static FILE *observation;
void e062_observe(FILE *f){observation=f;}
static int record(const char *op,const char *kind,int fd,uint32_t id,int rc,int error,
                  unsigned attempt,int64_t elapsed)
{
	if(!observation || fprintf(observation,
		"{\"operation\":\"%s\",\"kind\":\"%s\",\"fd\":%d,\"id\":%u,\"rc\":%d,\"errno\":%d,\"attempt\":%u,\"elapsed_ns\":%lld,\"deadline_ns\":15000000000}\n",
		op,kind,fd,id,rc,error,attempt,(long long)elapsed)<0 || fflush(observation) || ferror(observation)) {
		fprintf(stderr,"arena-observe: storage failure operation=%s kind=%s id=%u\n",op,kind,id);
		errno=EIO;return -1;
	}
	return 0;
}
static int reject(const char *op,const char *kind,int fd,uint32_t id,int rc,int error,
                  unsigned attempt,int64_t elapsed)
{
	(void)record(op,kind,fd,id,rc,error,attempt,elapsed);
	fprintf(stderr,"arena-observe: %s kind=%s fd=%d id=%u rc=%d errno=%d attempt=%u elapsed_ns=%lld\n",
		op,kind,fd,id,rc,error,attempt,(long long)elapsed);
	errno=error?error:EIO;return -1;
}
static void capture(const char *kind,int fd,uint32_t *ids,size_t *count)
{
	union {struct bpf_map_info map;struct bpf_prog_info prog;} info={0};
	uint32_t n=!strcmp(kind,"map")?sizeof info.map:sizeof info.prog;
	int rc=bpf_obj_get_info_by_fd(fd,&info,&n),error=rc?errno:0;
	uint32_t id=!strcmp(kind,"map")?info.map.id:info.prog.id;
	if(rc || !id || *count>=8) {
		(void)reject(rc?"capture-info":!id?"capture-zero-id":"capture-capacity",kind,fd,id,rc,error,0,0);
		capture_error=1;return;
	}
	ids[(*count)++]=id;
	if(record("capture",kind,fd,id,0,0,0,0))capture_error=1;
}
static int now(int64_t *value,int64_t *last)
{
	struct timespec ts;
	if(clock_gettime(CLOCK_MONOTONIC,&ts))return reject("clock","all",-1,0,-1,errno,0,0);
	int64_t n=(int64_t)ts.tv_sec*1000000000+ts.tv_nsec;
	if(n<*last)return reject("clock-backwards","all",-1,0,-1,ERANGE,0,n-*last);
	*last=n;*value=n;return 0;
}
static int disappeared(void)
{
	int64_t start=0,last=0,t=0;
	unsigned char gone[16]={0};size_t remaining=nm+np;
	if(now(&start,&last))return -1;
	t=start;
	for(unsigned attempt=1;attempt<=1501;attempt++) {
		for(size_t i=0;i<nm+np;i++) {
			if(gone[i])continue;
			const char *kind=i<nm?"map":"program";
			uint32_t id=i<nm?map_ids[i]:prog_ids[i-nm];
			if(now(&t,&last))return -1;
			if(t-start>=15000000000LL)return reject("deadline",kind,-1,id,-1,ETIMEDOUT,attempt,t-start);
			int fd=i<nm?bpf_map_get_fd_by_id(id):bpf_prog_get_fd_by_id(id);
			int error=fd<0?errno:0;
			if(fd>=0 && close(fd))return reject("query-close",kind,fd,id,-1,errno,attempt,t-start);
			if(now(&t,&last))return -1;
			if(record("query",kind,fd,id,fd<0?-1:0,error,attempt,t-start))return -1;
			if(t-start>=15000000000LL)return reject("deadline",kind,-1,id,-1,ETIMEDOUT,attempt,t-start);
			if(fd<0) {
				if(error!=ENOENT)return reject("query-error",kind,-1,id,-1,error,attempt,t-start);
				gone[i]=1;remaining--;
			}
		}
		if(!remaining)return record("absent","all",-1,0,0,0,attempt,t-start);
		if(attempt==1501)return reject("round-limit","all",-1,0,-1,ETIMEDOUT,attempt,t-start);
		struct timespec delay={.tv_nsec=10000000};
		if(nanosleep(&delay,NULL))return reject("wait","all",-1,0,-1,errno,attempt,t-start);
	}
	return -1;
}
extern int __real_bpf_object__load(struct bpf_object *);
int __wrap_bpf_object__load(struct bpf_object *object)
{
	if(bpf_object__find_map_by_name(object,"ar")){e062_target_loads++;target=object;}
	return __real_bpf_object__load(object);
}
extern void __real_bpf_object__close(struct bpf_object *);
void __wrap_bpf_object__close(struct bpf_object *o)
{
	if(o && o==target){
		struct bpf_map *m;struct bpf_program *p;
		bpf_object__for_each_map(m,o){int fd=bpf_map__fd(m);if(fd>=0)capture("map",fd,map_ids,&nm);}
		bpf_object__for_each_program(p,o){int fd=bpf_program__fd(p);if(fd>=0)capture("program",fd,prog_ids,&np);}
	}
	__real_bpf_object__close(o);if(o==target)target=NULL;
}
extern void *__real_mmap(void *,size_t,int,int,int,off_t);
extern void *__real_mmap64(void *,size_t,int,int,int,off64_t);
extern int __real_munmap(void *,size_t);
static void count(void *address,size_t n,void *result)
{if((uintptr_t)address==UINT64_C(35184372092928) && n==16384){if(result==MAP_FAILED)mmap_fail++;else mmap_ok++;}}
void *__wrap_mmap(void *a,size_t n,int p,int f,int fd,off_t off)
{void *r=__real_mmap(a,n,p,f,fd,off);count(a,n,r);return r;}
void *__wrap_mmap64(void *a,size_t n,int p,int f,int fd,off64_t off)
{void *r=__real_mmap64(a,n,p,f,fd,off);count(a,n,r);return r;}
int __wrap_munmap(void *a,size_t n)
{int rc=__real_munmap(a,n);if(!rc && (uintptr_t)a==UINT64_C(35184372092928) && n==16384)munmap_ok++;return rc;}
int e062_snapshot(FILE *f)
{
	if(capture_error)return reject("capture-failed","all",-1,0,-1,EIO,0,0);
	if(!target && disappeared())return -1;
	struct bpf_map_info info={0};void *base=NULL;size_t initial=0;
	if(target) {
		struct bpf_map *map=bpf_object__find_map_by_name(target,"ar");uint32_t n=sizeof info;
		if(!map)return reject("snapshot-map-missing","map",-1,0,-1,ENOENT,0,0);
		int fd=bpf_map__fd(map);
		if(bpf_obj_get_info_by_fd(fd,&info,&n))return reject("snapshot-info","map",fd,0,-1,errno,0,0);
		base=bpf_map__initial_value(map,&initial);
	}
	char line[1024];int n=snprintf(line,sizeof line,
		"{\"step\":\"map-snapshot\",\"map_type\":%u,\"flags\":%u,\"pages\":%u,\"map_extra\":%llu,\"base\":%llu,\"length\":%llu,\"initial_size\":%zu,\"mmap_ok\":%d,\"mmap_fail\":%d,\"munmap_ok\":%d}\n",
		info.type,info.map_flags,info.max_entries,(unsigned long long)info.map_extra,(unsigned long long)(uintptr_t)base,
		(unsigned long long)info.max_entries*4096,initial,mmap_ok,mmap_fail,munmap_ok);
	if(n<0 || (size_t)n>=sizeof line)return reject("snapshot-format","all",-1,0,-1,EOVERFLOW,0,0);
	errno=0;
	if(fwrite(line,1,(size_t)n,f)!=(size_t)n)return reject("snapshot-write","all",-1,0,-1,errno?errno:EIO,0,0);
	if(fflush(f))return reject("snapshot-flush","all",-1,0,-1,errno?errno:EIO,0,0);
	return 0;
}
