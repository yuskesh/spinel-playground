/* E065 stop A: independent single-field damage to frozen real ELF bytes; no BPF. */
#define _GNU_SOURCE
#include "load/internal.h"
#include "btf/kernel.h"
#include "req/from_elf.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int bad;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL:%d %s\n",__LINE__,#x);bad++;}}while(0)
static void put32(uint8_t *p,uint32_t v){for(int i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static void put64(uint8_t *p,uint64_t v){for(int i=0;i<8;i++)p[i]=(uint8_t)(v>>(8*i));}
static size_t section_header(const struct bml_elf *e,const struct bml_elf_shdr *s)
{return (size_t)bml_elf_u64(e,e->data+40)+(size_t)(s-e->sections)*64;}
static void run(const char *path)
{
	FILE *f=fopen(path,"rb");CHECK(f);if(!f)return;
	CHECK(!fseek(f,0,SEEK_END));long length=ftell(f);rewind(f);CHECK(length>0);
	uint8_t *original=malloc((size_t)length);CHECK(original);if(!original){fclose(f);return;}
	CHECK(fread(original,1,(size_t)length,f)==(size_t)length);CHECK(!fclose(f));
	static const char *const names[]={"pristine","weak","visibility","duplicate-symbol","other-extern","btf-magic","btf-linkage",
		"ksyms-member","prototype","call-opcode","resolved-src","call-off","call-imm","reloc-kind","reloc-link","reloc-info",
		"reloc-symbol","duplicate-reloc","overlap-reloc","metadata-kind","metadata-target","metadata-offset","missing-row","wrong-signature","wrong-entry",
		"metadata-duplicate","reloc-bounds"};
	for(size_t arm=0;arm<sizeof names/sizeof *names;arm++){
		uint8_t *bytes=malloc((size_t)length);CHECK(bytes);if(!bytes)break;memcpy(bytes,original,(size_t)length);
		struct bml_elf e;char *err=NULL;CHECK(!bml_elf_open(bytes,(size_t)length,&e,&err));free(err);
		const struct bml_elf_shdr *tab=bml_elf_section(&e,".symtab"),*rel=bml_elf_section(&e,".relsyscall"),*btf=bml_elf_section(&e,".BTF"),
			*br=bml_elf_section(&e,".rel.BTF"),*prog=bml_elf_section(&e,"syscall"),*req=bml_elf_section(&e,".ebpf_requirements");
		CHECK(tab && rel && btf && br && prog && req);
		struct bml_elf_sym *syms=NULL;size_t ns=0;err=NULL;CHECK(!bml_elf_symbols(&e,BML_SHT_SYMTAB,&syms,&ns,&err));free(err);
		size_t ai=0,fi=0,entry=0,license=0;for(size_t i=0;i<ns;i++){
			if(!strcmp(syms[i].name,"bpf_arena_alloc_pages"))ai=i+1;
			if(!strcmp(syms[i].name,"bpf_arena_free_pages"))fi=i+1;
			if(!strcmp(syms[i].name,"pages"))entry=i+1;
			if(!strcmp(syms[i].name,"_license"))license=i+1;
		}
		CHECK(ai && fi && entry && license);uint8_t *as=bytes+tab->offset+ai*24,*fs=bytes+tab->offset+fi*24;
		uint8_t *callrel=NULL,*meta=NULL;
		for(size_t i=0;i<rel->size;i+=16)if(bml_elf_u64(&e,bytes+rel->offset+i+8)>>32==ai)callrel=bytes+rel->offset+i;
		for(size_t i=0;i<br->size;i+=16)if(bml_elf_u64(&e,bytes+br->offset+i+8)>>32==ai)meta=bytes+br->offset+i;
		CHECK(callrel && meta);uint8_t *call=bytes+prog->offset+bml_elf_u64(&e,callrel);
		uint8_t *raw=malloc((size_t)btf->size);CHECK(raw);memcpy(raw,bytes+btf->offset,(size_t)btf->size);
		struct bml_kbtf kb;err=NULL;CHECK(!bml_kbtf_from_raw(raw,(size_t)btf->size,&kb,&err));free(err);
		size_t fninfo=0,protoret=0,member=0;
		for(uint32_t i=1;i<kb.n;i++){
			struct kbtf_type t;bml_kbtf_type(&kb,i,&t);
			if(t.kind==KBTF_FUNC && !strcmp(t.name,"bpf_arena_alloc_pages")){fninfo=(size_t)(kb.types+kb.off[i]+4-kb.raw);protoret=(size_t)(kb.types+kb.off[t.size_type]+8-kb.raw);}
			if(t.kind==KBTF_DATASEC && !strcmp(t.name,".ksyms"))member=(size_t)(t.aux-kb.raw);
		}
		CHECK(fninfo && protoret && member);
		switch(arm){
		case 0:break;
		case 1:as[4]=0x20;break;
		case 2:as[5]=2;break;
		case 3:memcpy(fs,as,4);break;
		case 4:{uint32_t off=bml_elf_u32(&e,as);memcpy(bytes+e.sections[tab->link].offset+off,"bpf_task_from_pid\0",18);break;}
		case 5:bytes[btf->offset]=0;break;
		case 6:put32(bytes+btf->offset+fninfo,12u<<24|1);break;
		case 7:put32(bytes+btf->offset+member,0);break;
		case 8:put32(bytes+btf->offset+protoret,0);break;
		case 9:call[0]=0xb7;break;
		case 10:call[1]=0x20;break;
		case 11:call[2]=1;break;
		case 12:put32(call+4,0);break;
		case 13:put32(callrel+8,1);break;
		case 14:put32(bytes+section_header(&e,rel)+40,0);break;
		case 15:put32(bytes+section_header(&e,rel)+44,(uint32_t)(btf-e.sections));break;
		case 16:put32(callrel+12,0);break;
		case 17:memcpy(bytes+rel->offset,callrel,16);break;
		case 18:memcpy(bytes+rel->offset,callrel,16);put64(bytes+rel->offset,bml_elf_u64(&e,callrel)+4);break;
		case 19:put32(meta+8,4);break;
		case 20:put32(bytes+section_header(&e,br)+44,(uint32_t)(prog-e.sections));break;
		case 21:put64(meta,bml_elf_u64(&e,meta)+1);break;
		case 22:{char *at=memmem(bytes+req->offset,(size_t)req->size,"kfunc\tpages\tbpf_arena_alloc_pages",33);CHECK(at);if(at)*at='x';break;}
		case 23:{char *at=memmem(bytes+req->offset,(size_t)req->size,"bpf_arena_alloc_pages\tptr:void",30);CHECK(at);if(at)memcpy(at+22,"ptr:char",8);break;}
		case 24:memcpy(bytes+tab->offset+entry*24,bytes+tab->offset+license*24,4);break;
		case 25:memcpy(bytes+br->offset+16,meta,16);break;
		case 26:put64(callrel,prog->size);break;
		}
		bml_kbtf_free(&kb);free(syms);bml_elf_close(&e);
		if(arm==23){struct bml_requirements *r=NULL;struct bml_req_elf_error error={0};CHECK(!bml_req_from_elf(bytes,(size_t)length,&r,&error));bml_requirements_free(r);bml_req_elf_error_free(&error);}
		struct bml_load_result result={0};int rc=lb_check_shape(bytes,(size_t)length,&result);
		int good=arm?(rc!=0 && result.stage==BML_LOAD_SHAPE && result.msg && *result.msg):!rc;
		CHECK(good);printf("arena-extern-%s: %s %s\n",names[arm],good?"GREEN":"FAIL",result.msg?result.msg:"");
		bml_load_result_free(&result);free(bytes);
	}
	free(original);
}
int main(int argc,char **argv)
{
	if(argc!=3)return 2;
	run(argv[1]);run(argv[2]);return bad?1:0;
}
