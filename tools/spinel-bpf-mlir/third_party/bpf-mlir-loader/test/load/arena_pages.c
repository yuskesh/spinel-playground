/* E065: the same ELF/decl/guard/reservation/info implementation, with native load/info
 * replaced. Anonymous MAP_FIXED replaces only this test's own PROT_NONE reservation. */
#define _GNU_SOURCE
#include "abi/internal.h"
#include "load/internal.h"
#include "load/arena.h"
#include "maps/arena.h"
#include "req/from_elf.h"
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static int bad,loads,info_wrong,unmaps;
static struct bml_arena_spec spec;
static struct bpf_map *arena;
static void *mapped;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL:%d %s\n",__LINE__,#x);bad++;}}while(0)
static int yes(void *ctx,const char *name,int *value,char **msg)
{(void)ctx;(void)name;*value=1;*msg=NULL;return BML_Q_OK;}
int __wrap_bml_check(const struct bml_requirements *r,const struct bml_caps *c,struct bml_unmets *u,char **err)
{(void)r;((struct bml_caps *)c)->btf_feature=yes;memset(u,0,sizeof *u);*err=NULL;return 0;}
bool __wrap_feat_supported(void *cache,int id){(void)cache;(void)id;return true;}
int __wrap_bpf_object__load(struct bpf_object *obj)
{
	loads++;struct bpf_map *m=bpf_object__find_map_by_name(obj,"ar");
	CHECK(m && bpf_map__map_flags(m)==spec.flags && bpf_map__map_extra(m)==spec.address);
	void *p=mmap((void *)(uintptr_t)spec.address,spec.length,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
	CHECK(p==MAP_FAILED && errno==EEXIST);if(p!=MAP_FAILED)munmap(p,spec.length);
	return -EIO;
}
extern void *__real_bpf_map__initial_value(struct bpf_map *,size_t *);
void *__wrap_bpf_map__initial_value(struct bpf_map *m,size_t *n)
{if(m!=arena)return __real_bpf_map__initial_value(m,n);*n=0;return mapped;}
int __wrap_bpf_obj_get_info_by_fd(int fd,void *data,uint32_t *n)
{
	(void)fd;CHECK(*n>=sizeof(struct bpf_map_info));
	*(struct bpf_map_info *)data=(struct bpf_map_info){.type=BPF_MAP_TYPE_ARENA,.max_entries=spec.pages,
		.map_flags=info_wrong?(spec.flags^131072):spec.flags,.map_extra=spec.address};return 0;
}
extern void __real_bpf_object__close(struct bpf_object *);
void __wrap_bpf_object__close(struct bpf_object *o)
{__real_bpf_object__close(o);if(mapped){CHECK(!munmap(mapped,spec.length));mapped=NULL;unmaps++;}arena=NULL;}
static void free_range(void)
{
	void *p=mmap((void *)(uintptr_t)spec.address,spec.length,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
	CHECK(p==(void *)(uintptr_t)spec.address);if(p!=MAP_FAILED)CHECK(!munmap(p,spec.length));
}
static void one(const char *path,uint32_t flags)
{
	FILE *f=fopen(path,"rb");CHECK(f);if(!f)return;
	CHECK(!fseek(f,0,SEEK_END));long len=ftell(f);CHECK(len>0);rewind(f);
	uint8_t *elf=malloc((size_t)len);CHECK(elf);if(!elf){fclose(f);return;}
	CHECK(fread(elf,1,(size_t)len,f)==(size_t)len);CHECK(!fclose(f));
	char *err=NULL;CHECK(!bml_arena_elf(elf,(size_t)len,"ar",&spec,&err));CHECK(!err && spec.flags==flags);free(err);
	struct bml_requirements *req=NULL;struct bml_req_elf_error re={0};
	CHECK(!bml_req_from_elf(elf,(size_t)len,&req,&re));if(!req){free(elf);return;}
	char decl[256],maps[320];snprintf(decl,sizeof decl,"{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":%u,\"flags\":%u,\"map_extra\":%llu}",spec.pages,spec.flags,(unsigned long long)spec.address);
	snprintf(maps,sizeof maps,"{\"allow_undeclared\":true,\"maps\":[%s]}",decl);
	struct bml_map_decl d={0};err=NULL;CHECK(!bml_arena_map_decl_parse_one(decl,strlen(decl),&d,&err));free(err);
	struct bml_map_decls ds={.allow_undeclared=1,.has_maps=1,.maps=&d,.n_maps=1};
	for(int arm=0;arm<2;arm++){
		int before=bad;
		d.flags=arm?(spec.flags^131072):spec.flags;struct bml_map_problems problems={0};
		int rc=bml_check_arena_decls(req,elf,(size_t)len,&ds,1,&problems);
		CHECK(arm?(rc!=0 && problems.n>0):(!rc && !problems.n));bml_map_problems_free(&problems);
		printf("arena-pages-%u-declaration%d: %s\n",flags,arm,bad==before?"GREEN":"FAIL");
	}
	bml_map_decl_free(&d);
	for(int entry=0;entry<3;entry++)for(int corrupt=0;corrupt<2;corrupt++){
		int before=bad;
		const char *sha=corrupt?"0000000000000000000000000000000000000000000000000000000000000000":req->schema_sha256.p;
		int old=loads;int64_t result;
		if(!entry)result=bml_load_checked(elf,len,sha,strlen(sha),maps,strlen(maps),0);
		else if(entry==1)result=bml_load_checked_config(elf,len,sha,strlen(sha),maps,strlen(maps),NULL,0,0);
		else result=bml_load_checked_targets(elf,len,sha,strlen(sha),maps,strlen(maps),NULL,0,NULL,0,0);
		int64_t n;const char *message=bml_result_message(result,&n);
		printf("checked-observation flags=%u entry=%d corrupt=%d kind=%lld loads=%d message=%s\n",flags,entry,corrupt,
			(long long)bml_result_kind(result),loads-old,message?message:"(none)");
		CHECK(message && n>0 && (corrupt?(loads==old && bml_result_kind(result)==BML_SCHEMA_MISMATCH):
			(loads==old+1 && bml_result_kind(result)==BML_OTHER && strstr(message,"input/output error"))));
		bml_result_free(result);free_range();printf("arena-pages-%u-checked%d-schema%d: %s\n",flags,entry,corrupt,bad==before?"GREEN":"FAIL");
	}
	for(int arm=0;arm<3;arm++){
		int before=bad;
		struct bml_obj *o=calloc(1,sizeof *o);CHECK(o);if(!o)break;
		o->obj=bpf_object__open_mem(elf,(size_t)len,NULL);CHECK(o->obj);if(!o->obj){free(o);break;}
		arena=bpf_object__find_map_by_name(o->obj,"ar");CHECK(arena);struct bml_load_result r={0};
		if(arm==0)CHECK(!bpf_map__set_map_flags(arena,spec.flags^131072));
		int rc=lb_arena_prepare(o,elf,(size_t)len,&r);
		if(!arm)CHECK(rc && r.msg && strstr(r.msg,"libbpf definition differs"));
		else {
			CHECK(!rc);
			if(rc){bml_obj_close(o);bml_load_result_free(&r);continue;}
			mapped=mmap((void *)(uintptr_t)spec.address,spec.length,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0);
			CHECK(mapped==(void *)(uintptr_t)spec.address);if(mapped==MAP_FAILED){mapped=NULL;bml_obj_close(o);break;}
			lb_arena_observe(o);info_wrong=arm==2;rc=lb_arena_check(o,&r);
			CHECK(info_wrong?(rc && r.stage==BML_LOAD_ARENA):!rc);
			void *base=NULL;size_t size=0;err=NULL;int span=bml_obj_arena_span(o,arena,&base,&size,&err);
			CHECK(info_wrong?(span && !base && !size):(!span && base==mapped && size==spec.length));free(err);
		}
		bml_obj_close(o);bml_load_result_free(&r);free_range();printf("arena-pages-%u-transaction%d: %s\n",flags,arm,bad==before?"GREEN":"FAIL");
	}
	bml_requirements_free(req);bml_req_elf_error_free(&re);free(elf);
}
int main(int argc,char **argv)
{
	if(argc!=3 && argc!=4)return 2;
	if(argc==4 && strcmp(argv[3],"--info-mutant"))return 2;
	if(argc==4)setenv("BML_MUTANT","arena.ignore_loaded_flags",1);
	one(argv[1],1024);one(argv[2],132096);CHECK(unmaps==4);
	return bad?1:0;
}
