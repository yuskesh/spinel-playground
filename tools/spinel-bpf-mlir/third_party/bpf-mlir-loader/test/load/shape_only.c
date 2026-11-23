/* E065 stop A inventory: actual old guard only; never caps/target load. */
#include "load/internal.h"
#include "req/from_elf.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv)
{
	size_t inputs=0,kfuncs=0,refused=0,with_extern=0;
	for(int i=1;i<argc;i++){
		FILE *f=fopen(argv[i],"rb");if(!f)return 2;
		if(fseek(f,0,SEEK_END))return 2;
		long size=ftell(f);if(size<0 || fseek(f,0,SEEK_SET))return 2;
		uint8_t *elf=malloc(size?(size_t)size:1);if(!elf)return 2;
		if(fread(elf,1,(size_t)size,f)!=(size_t)size || fclose(f))return 2;
		struct bml_requirements *req=NULL;struct bml_req_elf_error e={0};
		inputs++;
		if(!bml_req_from_elf(elf,(size_t)size,&req,&e) && req->n_kfuncs){
			struct bml_elf view;struct bml_elf_sym *syms=NULL;size_t ns=0,externs=0;char *err=NULL;
			if(bml_elf_open(elf,(size_t)size,&view,&err))return 2;
			if(bml_elf_symbols(&view,BML_SHT_SYMTAB,&syms,&ns,&err))return 2;
			for(size_t k=0;k<ns;k++)externs+=syms[k].shndx==BML_SHN_UNDEF;
			free(syms);free(err);bml_elf_close(&view);with_extern+=externs>0;
			struct bml_load_result r={0};int rc=lb_check_shape(elf,(size_t)size,&r);
			kfuncs++;refused+=rc!=0;
			printf("%s\tkfunc_rows=%zu\texterns=%zu\tshape_rc=%d\t%s\n",argv[i],req->n_kfuncs,externs,rc,r.msg?r.msg:"");
			bml_load_result_free(&r);
		}
		bml_requirements_free(req);bml_req_elf_error_free(&e);free(elf);
	}
	printf("inventory inputs=%zu kfunc_ELF=%zu with_extern=%zu shape_refused=%zu\n",inputs,kfuncs,with_extern,refused);
	return !kfuncs?2:0;
}
