/* E062: fixed real E639 objects and one-property derived negative ELF. */
#define _GNU_SOURCE
#include "load/internal.h"
#include "elf/elf.h"
#include "btf/kernel.h"
#include "maps/arena.h"
#include <bpf/libbpf.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int loads;
#ifdef E062_ANY_MAP_EXTRA
/* Deliberately wrong shape adapter, linked only into the sensitivity binary. */
int e062_accept_extra(const void *p,size_t n,const char *name,struct bml_arena_spec *s,char **err)
{(void)p;(void)n;(void)name;memset(s,0,sizeof *s);*err=NULL;return 0;}
#endif
bool __wrap_feat_supported(void *cache,int id){(void)cache;(void)id;return true;}
int __wrap_bpf_object__load(struct bpf_object *obj){(void)obj;loads++;return -EIO;}
static void put32(uint8_t *p,uint32_t v){for(int i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8));}
/* Modify only the ar VAR's named member in an owned BTF copy. */
static int derive(uint8_t *elf,size_t n,const char *field,uint32_t value,int rename)
{
	struct bml_elf e;char *err=NULL;int rc=-1;
	if(bml_elf_open(elf,n,&e,&err)){free(err);return -1;}
	const struct bml_elf_shdr *s=bml_elf_section(&e,".BTF");
	if(!s || s->offset>n || s->size>n-s->offset)goto done;
	uint8_t *raw=malloc(s->size);if(!raw)goto done;
	memcpy(raw,elf+s->offset,s->size);struct bml_kbtf b;
	if(bml_kbtf_from_raw(raw,s->size,&b,&err)){free(err);goto done;}
	for(uint32_t id=1;id<b.n && rc;id++){
		struct kbtf_type var,st;bml_kbtf_type(&b,id,&var);
		if(var.kind!=KBTF_VAR || strcmp(var.name,"ar"))continue;
		int cycle;bml_kbtf_type(&b,bml_kbtf_underlying(&b,var.size_type,&cycle),&st);
		if(cycle || st.kind!=KBTF_STRUCT)break;
		for(uint32_t k=0;k<st.vlen;k++){
			struct kbtf_member m;bml_kbtf_member(&b,&st,k,&m);
			if(strcmp(m.name,field))continue;
			if(rename){((char *)m.name)[0]='z';rc=0;break;}
			struct kbtf_type t;bml_kbtf_type(&b,m.type,&t);
			if(t.kind==KBTF_PTR){
				bml_kbtf_type(&b,t.size_type,&t);
				if(t.kind==KBTF_ARRAY){put32((uint8_t *)t.aux+8,value);rc=0;}
			}else if(t.kind==KBTF_ENUM64){put32((uint8_t *)t.aux+4,value);rc=0;}
			break;
		}
	}
	if(!rc)memcpy(elf+s->offset,b.raw,s->size);
	bml_kbtf_free(&b);
done:bml_elf_close(&e);return rc;
}
int main(int argc,char **argv)
{
	if(argc<2)return 2;
	int bad=0;
	for(int file=1;file<argc;file++){
		FILE *f=fopen(argv[file],"rb");if(!f)return 2;
		if(fseek(f,0,SEEK_END))return 2;
		long n=ftell(f);if(n<=0 || fseek(f,0,SEEK_SET))return 2;
		uint8_t *raw=malloc((size_t)n),*elf=malloc((size_t)n);if(!raw || !elf)return 2;
		if(fread(raw,1,(size_t)n,f)!=(size_t)n)return 2;
		fclose(f);
		const struct {const char *name,*field;uint32_t value;int rename;} arms[]={
			{"valid",NULL,0,0},{"nonarena","type",2,0},{"flags","map_flags",1025,0},
			{"address","map_extra",4097,0},{"unknown-field","max_entries",0,1}
		};
		for(size_t arm=0;arm<sizeof arms/sizeof *arms;arm++){
			memcpy(elf,raw,(size_t)n);
			if(arm && derive(elf,(size_t)n,arms[arm].field,arms[arm].value,arms[arm].rename))return 2;
			struct bml_load_result r={0};int rc=lb_check_shape(elf,(size_t)n,&r);
			int good=arm ? rc && r.stage==BML_LOAD_SHAPE && r.msg && strstr(r.msg,"definition field") : !rc;
			printf("arena-guard-%d-%s: %s message=%s\n",file,arms[arm].name,good?"GREEN":"FAIL",r.msg?r.msg:"accepted");
			bad+=!good;bml_load_result_free(&r);
			if(arm){
				struct bml_requirements req={0};struct bml_obj *o=NULL;int old=loads;
				rc=bml_load_guarded_values(elf,(size_t)n,&req,NULL,NULL,0,&o,&r);
				good=rc && r.stage==BML_LOAD_SHAPE && loads==old && !o;
				printf("arena-guard-%d-%s-load0: %s\n",file,arms[arm].name,good?"GREEN":"FAIL");
				bad+=!good;bml_obj_close(o);bml_load_result_free(&r);
			}
		}
		free(raw);free(elf);
	}
	return bad?1:0;
}
