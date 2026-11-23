/* E062 STOP C: real prediction gate; only kernel probes are substituted. */
#define _GNU_SOURCE
#include "load/internal.h"
#include "req/from_elf.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int answer, query_rc, selected, first, calls, supported;
bool __wrap_feat_supported(void *cache, int feat)
{
	(void)cache; if (!calls++) first=feat;
	return feat==selected ? supported : true;
}
static int query(void *ctx,const char *name,int *value,char **msg)
{ (void)ctx;(void)name;*value=answer;*msg=NULL;return query_rc; }
int main(int argc,char **argv)
{
	if(argc<2)return 2;
	const struct {const char *name;int feat;} table[]={
		{"int",2},{"ptr",2},{"const",2},{"array",2},{"struct",2},
		{"func",3},{"func_proto",3},{"func_global",5},{"var",4},{"datasec",4},
		{"decl_tag",13},{"type_tag",14},{"enum",2},{"enum64",17},{"float",-1}
	};
	int bad=0;
	for(int file=1;file<argc;file++){
		FILE *f=fopen(argv[file],"rb");if(!f)return 2;
		if(fseek(f,0,SEEK_END))return 2;
		long n=ftell(f);
		if(n<=0 || fseek(f,0,SEEK_SET))return 2;
		uint8_t *elf=malloc((size_t)n);if(!elf)return 2;
		if(fread(elf,1,(size_t)n,f)!=(size_t)n)return 2;
		fclose(f);
		struct bml_requirements *original=NULL;struct bml_req_elf_error re={0};
		if(bml_req_from_elf(elf,(size_t)n,&original,&re))return 2;
		struct bml_caps caps={.btf_feature=query};
		for(size_t i=0;i<sizeof table/sizeof *table;i++)for(int arm=0;arm<6;arm++){
			struct bml_requirements req=*original;
			struct bml_str name={.p=(char *)table[i].name,.len=strlen(table[i].name)};
			req.btf_features=&name;req.n_btf_features=1;
			answer=arm/2;query_rc=answer==2?BML_Q_UNKNOWN:BML_Q_OK;
			supported=arm%2;selected=table[i].feat;calls=0;first=-1;
			struct bml_load_result r={0};int rc=lb_check_features(elf,(size_t)n,&req,&caps,&r);
			int predict=table[i].feat<0 || answer==2 || answer!=supported;
			int good=predict ? rc!=0 && r.stage==BML_LOAD_PREDICT : r.stage!=BML_LOAD_PREDICT;
			if(table[i].feat>=0 && answer!=2)good &= first==table[i].feat;
			if(table[i].feat<0 || answer==2)good &= calls==0;
			if(answer==1 && supported && table[i].feat>=0)good &= rc==0;
			printf("feature-%d-%s-%d: %s stage=%s first=%d\n",file,table[i].name,arm,
				good?"GREEN":"FAIL",bml_load_stage_name(r.stage),first);
			bad+=!good;bml_load_result_free(&r);
		}
		bml_requirements_free(original);bml_req_elf_error_free(&re);free(elf);
	}
	return bad?1:0;
}
