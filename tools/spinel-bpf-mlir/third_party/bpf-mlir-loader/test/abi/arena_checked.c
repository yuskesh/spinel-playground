/* Every checked C ABI entry must reject missing arena declarations before probes/load.
 * Real parsing/checking; only subsequent capability check/load are link stubs. */
#define _GNU_SOURCE
#include "abi/internal.h"
#include "req/from_elf.h"
#include "../arena_fixture.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks,loads;
int __wrap_bml_check(const struct bml_requirements *req,const struct bml_caps *caps,
	struct bml_unmets *out,char **err)
{(void)req;(void)caps;checks++;memset(out,0,sizeof *out);*err=NULL;return 0;}
int __wrap_bml_load_guarded_values(const uint8_t *elf,size_t n,const struct bml_requirements *req,
	const struct bml_caps *caps,const struct bml_rodata_value *v,size_t nv,struct bml_obj **out,struct bml_load_result *r)
{
	(void)elf;(void)n;(void)req;(void)caps;(void)v;(void)nv;loads++;*out=NULL;
	memset(r,0,sizeof *r);r->stage=BML_LOAD_ENV;r->msg=strdup("test-only target load reached; no BPF syscall");return -1;
}
static void *readfile(const char *path,size_t *len)
{
	FILE *f=fopen(path,"rb");if(!f)return NULL;
	void *p=NULL;long n;
	if(fseek(f,0,SEEK_END) || (n=ftell(f))<=0 || fseek(f,0,SEEK_SET))goto done;
	p=malloc((size_t)n);if(!p)goto done;
	if(fread(p,1,(size_t)n,f)!=(size_t)n){free(p);p=NULL;}else *len=(size_t)n;
done:fclose(f);return p;
}
static int64_t entry(int id,const uint8_t *elf,size_t n,const char *sha,const char *maps)
{
	if(id==0)return bml_load_checked(elf,(int64_t)n,sha,strlen(sha),maps,strlen(maps),0);
	if(id==1)return bml_load_checked_config(elf,(int64_t)n,sha,strlen(sha),maps,strlen(maps),NULL,0,0);
	return bml_load_checked_targets(elf,(int64_t)n,sha,strlen(sha),maps,strlen(maps),NULL,0,NULL,0,0);
}
int main(int argc,char **argv)
{
	if(argc!=3)return 2;
	int bad=0;
	const char *decls[]={
		"{\"allow_undeclared\":true,\"maps\":[]}",
		"{\"allow_undeclared\":true,\"maps\":[{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024}]}",
		"{\"allow_undeclared\":true,\"maps\":[{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024,\"map_extra\":" E061_ARENA_ADDRESS_JSON "}]}"
	};
	for(int input=0;input<2;input++) {
		size_t n=0;uint8_t *elf=readfile(argv[input+1],&n);if(!elf)return 2;
		struct bml_requirements *req=NULL;struct bml_req_elf_error re={0};
		if(bml_req_from_elf(elf,n,&req,&re)){free(elf);bml_req_elf_error_free(&re);return 2;}
		if(input && req->version>=29){free(elf);bml_requirements_free(req);return 2;}
		for(int id=0;id<3;id++)for(int arm=0;arm<(input?2:3);arm++) {
			int c=checks,l=loads;
			int64_t r=entry(id,elf,n,req->schema_sha256.p?req->schema_sha256.p:"",decls[arm]);
			int kind=(int)bml_result_kind(r);int64_t ml=0;const char *message=bml_result_message(r,&ml);
			int good=arm==2 ? kind==BML_OTHER && checks==c+1 && loads==l+1
				:kind==BML_MAP_MISMATCH && checks==c && loads==l && message && strstr(message,"arena");
			printf("arena-checked-%s-entry%d-%s: %s\n",input?"old-format":"current",id,
				arm==0?"no-declaration":arm==1?"no-extra":"valid-reaches-stub",good?"GREEN":"FAIL");
			bad+=!good;bml_result_free(r);
		}
		bml_requirements_free(req);bml_req_elf_error_free(&re);free(elf);
	}
	return bad?1:0;
}
