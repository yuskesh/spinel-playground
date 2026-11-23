/* E061: real ELF/libbpf open, anonymous replacement stands in for arena mmap.
 * No bpf_object__load call; kernel info and initial_value are link-wrapped. */
#define _GNU_SOURCE
#include "load/internal.h"
#include "load/arena.h"
#include "../arena_fixture.h"
#include <bpf/libbpf.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

static void *mapped;
static struct bpf_map *arena;
static int info_bad, info_calls, unmaps;
extern void *__real_bpf_map__initial_value(struct bpf_map *,size_t *);
void *__wrap_bpf_map__initial_value(struct bpf_map *m,size_t *size)
{
	if(m!=arena)return __real_bpf_map__initial_value(m,size);
	*size=0;return mapped;
}
int __wrap_bpf_obj_get_info_by_fd(int fd,void *out,uint32_t *len)
{
	(void)fd;info_calls++;
	if(info_bad==6)return -1;
	if(*len<sizeof(struct bpf_map_info))return -1;
	*(struct bpf_map_info *)out=(struct bpf_map_info){.type=BPF_MAP_TYPE_ARENA,
		.max_entries=info_bad==3?3:4,.map_flags=info_bad==4?1025:1024,
		.map_extra=E061_ARENA_ADDRESS+(info_bad==2?4096:0)};
	return 0;
}
extern void __real_bpf_object__close(struct bpf_object *);
void __wrap_bpf_object__close(struct bpf_object *o)
{
	__real_bpf_object__close(o);
	if(mapped){munmap(mapped,16384);mapped=NULL;unmaps++;}
}
int main(int argc,char **argv)
{
	if(argc!=2)return 2;
	int status=2,bad=0;void *elf=NULL;struct bml_obj *o=NULL;
	struct bml_load_result r={0};
	FILE *f=fopen(argv[1],"rb");if(!f)goto done;
	if(fseek(f,0,SEEK_END))goto done;
	long size=ftell(f);
	if(size<=0 || fseek(f,0,SEEK_SET))goto done;
	elf=malloc((size_t)size);if(!elf)goto done;
	if(fread(elf,1,(size_t)size,f)!=(size_t)size)goto done;
	fclose(f);f=NULL;
	for(int arm=0;arm<8;arm++) {
		o=calloc(1,sizeof *o);if(!o)goto done;
		o->obj=bpf_object__open_mem(elf,(size_t)size,NULL);if(!o->obj)goto done;
		arena=bpf_object__find_map_by_name(o->obj,"ar");if(!arena)goto done;
		if(lb_arena_prepare(o,elf,(size_t)size,&r)) {fprintf(stderr,"prepare: %s\n",r.msg);goto done;}
		if(arm) {
			mapped=mmap(arm==5?NULL:(void *)(uintptr_t)E061_ARENA_ADDRESS,16384,PROT_READ|PROT_WRITE,
				MAP_PRIVATE|MAP_ANONYMOUS|(arm==5?0:MAP_FIXED),-1,0);
			if(mapped==MAP_FAILED){mapped=NULL;goto done;}
			lb_arena_observe(o);info_bad=arm;
			if(arm!=7) {
				int rc=lb_arena_check(o,&r);
				int good=arm==1 ? rc==0 : rc!=0 && r.stage==(arm==6?BML_LOAD_ENV:BML_LOAD_ARENA);
				printf("arena-transaction-postguard-%d: %s\n",arm,good?"GREEN":"FAIL");bad+=!good;
				if(arm==1) {
					void *base;size_t length;char *err=NULL;
					good=!bml_obj_arena_span(o,arena,&base,&length,&err) && base==mapped && length==16384;
					printf("arena-transaction-size-not-initial: %s\n",good?"GREEN":"FAIL");bad+=!good;free(err);
				}
			}
		}
		bml_obj_close(o);o=NULL;bml_load_result_free(&r);
		void *p=mmap((void *)(uintptr_t)E061_ARENA_ADDRESS,16384,PROT_NONE,
			MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
		int good=p==(void *)(uintptr_t)E061_ARENA_ADDRESS;
		printf("arena-transaction-cleanup-%d: %s\n",arm,good?"GREEN":"FAIL");bad+=!good;
		if(p!=MAP_FAILED)munmap(p,16384);
	}
	bad+=unmaps!=7 || info_calls!=6;status=bad?1:0;
done:
	if(f)fclose(f);
	bml_obj_close(o);bml_load_result_free(&r);free(elf);return status;
}
