/* E062: real checked ABI -> guarded_values -> shape -> reservation.
 * Substitute only capability queries and the final target load (no BPF). */
#define _GNU_SOURCE
#include "abi/internal.h"
#include "load/internal.h"
#include "req/from_elf.h"
#include "../arena_fixture.h"
#include <bpf/libbpf.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static int loads, reserved;
static int yes(void *ctx,const char *name,int *value,char **msg)
{(void)ctx;(void)name;*value=1;*msg=NULL;return BML_Q_OK;}
int __wrap_bml_check(const struct bml_requirements *req,const struct bml_caps *caps,
	struct bml_unmets *out,char **err)
{
	(void)req;
	/* ABI owns this writable live-caps object; substitute its lower query. */
	((struct bml_caps *)caps)->btf_feature=yes;
	memset(out,0,sizeof *out);*err=NULL;return 0;
}
bool __wrap_feat_supported(void *cache,int id){(void)cache;(void)id;return true;}
int __wrap_bpf_object__load(struct bpf_object *obj)
{
	loads++;
	struct bpf_map *m=bpf_object__find_map_by_name(obj,"ar");
	if(!m || bpf_map__map_extra(m)!=E061_ARENA_ADDRESS)return -EINVAL;
	void *p=mmap((void *)(uintptr_t)E061_ARENA_ADDRESS,16384,PROT_NONE,
		MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
	reserved += p==MAP_FAILED && errno==EEXIST;
	if(p!=MAP_FAILED)munmap(p,16384);
	return -EIO;
}
int main(int argc,char **argv)
{
	if(argc!=2)return 2;
	FILE *f=fopen(argv[1],"rb");if(!f)return 2;
	if(fseek(f,0,SEEK_END))return 2;
	long n=ftell(f);if(n<=0 || fseek(f,0,SEEK_SET))return 2;
	uint8_t *elf=malloc((size_t)n);if(!elf)return 2;
	if(fread(elf,1,(size_t)n,f)!=(size_t)n)return 2;
	fclose(f);
	struct bml_requirements *req=NULL;struct bml_req_elf_error re={0};
	if(bml_req_from_elf(elf,(size_t)n,&req,&re))return 2;
	const char *sha=req->schema_sha256.p;
	const char *maps="{\"allow_undeclared\":true,\"maps\":[{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024,\"map_extra\":" E061_ARENA_ADDRESS_JSON "}]}";
	int bad=0;
	for(int id=0;id<3;id++){
		int old=loads,oldreserved=reserved;int64_t result;
		if(id==0)result=bml_load_checked(elf,n,sha,strlen(sha),maps,strlen(maps),0);
		else if(id==1)result=bml_load_checked_config(elf,n,sha,strlen(sha),maps,strlen(maps),NULL,0,0);
		else result=bml_load_checked_targets(elf,n,sha,strlen(sha),maps,strlen(maps),NULL,0,NULL,0,0);
		int64_t length;const char *msg=bml_result_message(result,&length);
		int good=bml_result_kind(result)==BML_OTHER && loads==old+1 && reserved==oldreserved+1
			&& msg && strstr(msg,"libbpf could not load the object: input/output error");
		printf("arena-real-shape-entry%d: %s loads=%d reserved=%d message=%s\n",id,
			good?"GREEN":"FAIL",loads-old,reserved-oldreserved,msg?msg:"(none)");bad+=!good;
		bml_result_free(result);
		void *p=mmap((void *)(uintptr_t)E061_ARENA_ADDRESS,16384,PROT_NONE,
			MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
		good=p==(void *)(uintptr_t)E061_ARENA_ADDRESS;
		printf("arena-real-shape-cleanup%d: %s\n",id,good?"GREEN":"FAIL");bad+=!good;
		if(p!=MAP_FAILED)munmap(p,16384);
	}
	bml_requirements_free(req);bml_req_elf_error_free(&re);free(elf);
	return bad?1:0;
}
