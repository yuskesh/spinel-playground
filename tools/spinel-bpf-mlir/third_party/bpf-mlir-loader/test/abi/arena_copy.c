/* E061: link stubs exercise the real copy implementation, no BPF syscalls. */
#include "abi/map_internal.h"
#include "load/arena.h"
#include <bml/bml.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char bytes[33]; /* one extra byte makes the bounds mutation memory-safe */
static struct abi_object object;
static int acquired, closed, span_calls;
int64_t abi_fail(int64_t kind,const char *fmt,...){(void)fmt;return kind+100;}
int64_t abi_ok(int64_t value){return value?999:0;}
int64_t abi_map_open_kind(int64_t h,const char *decl,int64_t dl,const char *const *kinds,const char *what,
	const char *const *records,const int64_t *rl,size_t nr,struct abi_map *m)
{
	(void)decl;(void)dl;(void)what;(void)records;(void)rl;(void)nr;
	if(strcmp(kinds[0],"arena") || kinds[1]) return 999;
	if(h!=1) return BML_STATE+100;
	memset(m,0,sizeof *m);m->o=&object;acquired++;return 0;
}
void abi_map_close(struct abi_map *m){(void)m;acquired--;closed++;}
int bml_obj_arena_span(struct bml_obj *o,struct bpf_map *map,void **base,size_t *length,char **err)
{
	(void)o;(void)map;*err=NULL;span_calls++;
	if(acquired!=1)return -1;
	*base=bytes;*length=32;return 0;
}
static int check(const char *name,int64_t got,int64_t want)
{int good=got==want && acquired==0;printf("arena-copy-%s: %s\n",name,good?"GREEN":"FAIL");return !good;}
int main(int argc,char **argv)
{
	if(argc==2 && !strcmp(argv[1],"--mutate-boundary"))
		if(setenv("BML_MUTANT","arena.boundary_plus_one",1)) return 2;
	int bad=0; unsigned char data[4]={1,2,3,4},out[4]={0};
	bad+=check("write",bml_arena_write(1,"",0,28,4,data,4),0);
	bad+=check("tail-read",bml_arena_read(1,"",0,28,4,out,4),0);bad+=memcmp(data,out,4)!=0;
	bad+=check("end-cross",bml_arena_write(1,"",0,29,4,data,4),BML_VALUE_RANGE+100);
	bad+=check("u64-overflow",bml_arena_read(1,"",0,UINT64_MAX,4,out,4),BML_VALUE_RANGE+100);
	bad+=check("len-too-large",bml_arena_read(1,"",0,0,UINT64_MAX,out,4),BML_VALUE_RANGE+100);
	bad+=check("capacity",bml_arena_read(1,"",0,0,4,out,3),BML_VALUE_RANGE+100);
	bad+=check("zero-end",bml_arena_read(1,"",0,32,0,NULL,0),0);
	bad+=check("zero-outside",bml_arena_read(1,"",0,33,0,NULL,0),BML_VALUE_RANGE+100);
	bad+=check("closed-zero",bml_arena_read(2,"",0,32,0,NULL,0),BML_STATE+100);
	int before=span_calls;
	bad+=check("negative-capacity",bml_arena_read(1,"",0,0,0,NULL,-1),BML_OTHER+100);
	bad+=check("null",bml_arena_read(1,"",0,0,1,NULL,1),BML_OTHER+100);
	bad+=span_calls!=before;
	memcpy(bytes,"abcdefgh",8);
	bad+=check("overlap-write",bml_arena_write(1,"",0,2,6,bytes,6),0);bad+=memcmp(bytes,"ababcdef",8)!=0;
	bad+=check("overlap-read",bml_arena_read(1,"",0,2,6,bytes,6),0);bad+=memcmp(bytes,"abcdef",6)!=0;
	/* Ten opens succeed; stale handle and two buffer errors acquire nothing. */
	bad+=closed!=10;
	return bad?1:0;
}
