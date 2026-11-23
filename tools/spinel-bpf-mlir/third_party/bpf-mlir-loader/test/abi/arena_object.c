/* Real registry/map declaration path, test-only span and memmove link wrappers. */
#include "abi/internal.h"
#include "load/internal.h"
#include "load/arena.h"
#include "req/from_elf.h"
#include "../arena_fixture.h"
#include <bpf/libbpf.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static unsigned char bytes[16384];
static int64_t handle;
static int do_close, busy_ok, copies, missing_map;
static void *close_thread(void *unused)
{
	(void)unused;int64_t r=bml_close(handle);
	busy_ok=bml_result_kind(r)==BML_STATE;bml_result_free(r);return NULL;
}
extern void *__real_memmove(void *,const void *,size_t);
extern struct bpf_map *__real_bpf_object__find_map_by_name(const struct bpf_object *,const char *);
struct bpf_map *__wrap_bpf_object__find_map_by_name(const struct bpf_object *o,const char *name)
{return missing_map?NULL:__real_bpf_object__find_map_by_name(o,name);}
void *__wrap_memmove(void *dst,const void *src,size_t n)
{
	if(dst==bytes || src==bytes) {
		copies++;
		if(do_close) {
			/* The copy stays paused until the other thread's close attempt returns. */
			pthread_t thread;
			if(pthread_create(&thread,NULL,close_thread,NULL)==0)
				if(pthread_join(thread,NULL))busy_ok=0;
		}
	}
	return __real_memmove(dst,src,n);
}
void *__wrap___asan_memmove(void *dst,const void *src,size_t n)
{return __wrap_memmove(dst,src,n);}
int __wrap_bml_obj_arena_span(struct bml_obj *o,struct bpf_map *map,void **base,size_t *length,char **err)
{(void)o;(void)map;*base=bytes;*length=sizeof bytes;*err=NULL;return 0;}
static int want(const char *name,int64_t result,int kind)
{
	int got=bml_result_kind(result),good=got==kind;
	printf("arena-object-%s: %s (kind %d)\n",name,good?"GREEN":"FAIL",got);
	bml_result_free(result);return !good;
}
int main(int argc,char **argv)
{
	if(argc!=2)return 2;
	int status=2;struct abi_object *o=NULL;struct bml_req_elf_error re={0};
	FILE *f=fopen(argv[1],"rb");if(!f)goto done;
	if(fseek(f,0,SEEK_END))goto done;
	long n=ftell(f);if(n<=0 || fseek(f,0,SEEK_SET))goto done;
	o=calloc(1,sizeof *o);if(!o)goto done;
	o->elf=malloc((size_t)n);o->elf_len=(size_t)n;if(!o->elf)goto done;
	if(fread(o->elf,1,(size_t)n,f)!=(size_t)n)goto done;
	fclose(f);f=NULL;
	if(bml_req_from_elf(o->elf,o->elf_len,&o->req,&re))goto done;
	o->lo=calloc(1,sizeof *o->lo);if(!o->lo)goto done;
	o->lo->obj=bpf_object__open_mem(o->elf,o->elf_len,NULL);if(!o->lo->obj)goto done;
	abi_lock();handle=abi_handle_new(H_OBJECT,o,0);abi_unlock();if(handle<0)goto done;
	const char *decl="{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024,\"map_extra\":" E061_ARENA_ADDRESS_JSON "}";
	const char *unknown="{\"name\":\"unknown\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024,\"map_extra\":" E061_ARENA_ADDRESS_JSON "}";
	unsigned char buf[4]={1,2,3,4};int bad=0;
	bad+=want("unknown-declaration",bml_arena_write(handle,unknown,strlen(unknown),0,4,buf,4),BML_MAP_MISMATCH);
	missing_map=1;
	bad+=want("loaded-map-missing",bml_arena_write(handle,decl,strlen(decl),0,4,buf,4),BML_STATE);
	missing_map=0;bad+=copies!=0;
	do_close=1;
	bad+=want("copy-close-busy",bml_arena_write(handle,decl,strlen(decl),0,4,buf,4),BML_OK);
	bad+=!busy_ok || copies!=1 || memcmp(bytes,buf,4) || o->inflight!=0;
	do_close=0;
	bad+=want("close-after-copy",bml_close(handle),BML_OK);
	bad+=want("closed-zero-copy",bml_arena_read(handle,decl,strlen(decl),0,0,NULL,0),BML_STATE);
	bad+=copies!=1;
	status=bad?1:0;
done:
	if(f)fclose(f);
	if(o) {
		if(handle>0){int64_t r=bml_close(handle);bml_result_free(r);abi_lock();abi_handle_take(handle,H_OBJECT);abi_unlock();}
		else {bml_obj_close(o->lo);bml_requirements_free(o->req);free(o->elf);}
		free(o);
	}
	bml_req_elf_error_free(&re);return status;
}
