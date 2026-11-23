/* E061: reservation collision preserves bytes and release permits re-reservation. */
#define _GNU_SOURCE
#include "load/arena_reserve.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

int main(void)
{
	size_t size=16384;
	unsigned char *p=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
	if(p==MAP_FAILED) return 2;
	p[0]=0x73; p[size-1]=0x39;
	struct lb_arena_reservation r={0}; char *err=NULL;
	int rc=lb_arena_reserve(&r,(uintptr_t)p,size,&err);
	int good=rc!=0 && err && !r.base && p[0]==0x73 && p[size-1]==0x39;
	printf("arena-collision: %s\n",good?"GREEN":"FAIL");
	free(err); err=NULL;
	if(!good) return 1;
	if(munmap(p,size)) return 2;
	rc=lb_arena_reserve(&r,(uintptr_t)p,size,&err);
	good=!rc && !err && r.base==p && r.length==size;
	printf("arena-reserve: %s\n",good?"GREEN":"FAIL");
	if(!good) {free(err);return 1;}
	if(lb_arena_release(&r,&err)) {free(err);return 2;}
	rc=lb_arena_reserve(&r,(uintptr_t)p,size,&err);
	good=!rc && !err && r.base==p;
	printf("arena-re-reserve: %s\n",good?"GREEN":"FAIL");
	if(lb_arena_release(&r,&err)) {free(err);return 2;}
	if(lb_arena_release(&r,&err)) {free(err);return 2;}
	return good?0:1;
}
