/* E061: finite domain and arithmetic boundaries; no BPF syscalls. */
#include "maps/arena.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc,char **argv)
{
	if(argc==2 && !strcmp(argv[1],"--flags-mutant"))setenv("BML_MUTANT","arena.any_flags",1);
	static const struct { const char *name; uint64_t pages, flags, address; int ok; } cases[] = {
		{"normal",4,1024,UINT64_C(0x100001000),1},
		{"segv-selected",4,132096,UINT64_C(0x100001000),1},
		{"segv-without-mmap",4,131072,UINT64_C(0x100001000),0},
		{"no-user-conv",4,394240,UINT64_C(0x100001000),0},
		{"last-page",1,1024,UINT64_C(0x1fffff000),1},
		{"empty",0,1024,UINT64_C(0x100001000),0},
		{"too-many-pages",1048577,1024,UINT64_C(0x100001000),0},
		{"flags-absent",4,0,UINT64_C(0x100001000),0},
		{"extra-flags",4,1025,UINT64_C(0x100001000),0},
		{"zero-address",4,1024,0,0},
		{"low32-zero",4,1024,UINT64_C(0x100000000),0},
		{"unaligned",4,1024,UINT64_C(0x100001001),0},
		{"boundary-cross",2,1024,UINT64_C(0x1fffff000),0},
		{"add-overflow",2,1024,UINT64_C(0xfffffffffffff000),0},
	};
	int failures=0;
	for (size_t i=0; i<sizeof cases/sizeof *cases; i++) {
		struct bml_arena_spec out; char *err=NULL;
		int rc=bml_arena_shape(cases[i].pages,cases[i].flags,cases[i].address,&out,&err);
		int good=cases[i].ok ? rc==0 && !err && out.address==cases[i].address && out.length==cases[i].pages*4096 && out.flags==cases[i].flags
			: rc!=0 && err && !out.address && !out.length;
		printf("arena-shape-%s: %s\n",cases[i].name,good?"GREEN":"FAIL");
		failures+=!good; free(err);
	}
	return failures?1:0;
}
