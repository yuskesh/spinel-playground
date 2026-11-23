/* E062 link-only backend: no BPF syscall. Real anonymous mmap permits residency checks. */
#define _GNU_SOURCE
#include <bml/bml.h>
#include "arena_live_instrument.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define ADDRESS UINT64_C(35184372092928)
int e062_target_loads;
static unsigned char *arena;
static uint64_t input[8];
static int kinds[256],next=100;
static int64_t values[256];
static const char *messages[256];
static FILE *events;
void e062_observe(FILE *f) {(void)f;}
int e062_snapshot(FILE *f)
{
	const char *s="{\"step\":\"map-snapshot-stub\"}\n";
	return fwrite(s,1,strlen(s),f)!=strlen(s) || fflush(f);
}
static void audit(const char *s)
{
	const char *path=getenv("E062_STUB_AUDIT");if(!path)return;
	int fd=open(path,O_CREAT|O_WRONLY|O_APPEND,0644);if(fd<0)_exit(90);
	size_t n=strlen(s);if(write(fd,s,n)!=(ssize_t)n || write(fd,"\n",1)!=1 || close(fd))_exit(91);
}
static int injected(const char *name)
{const char *v=getenv("E062_API_FAIL");return v && !strcmp(v,name);}
static void op(const char *name,uint64_t a,uint64_t b,uint64_t c)
{char s[160];snprintf(s,sizeof s,"op-%s %llu %llu %llu",name,(unsigned long long)a,(unsigned long long)b,(unsigned long long)c);audit(s);}
static int io_fail(const char *name)
{const char *v=getenv("E062_IO_FAIL");return v && !strcmp(v,name);}
static int64_t result(int kind,int64_t value,const char *message)
{if(next>=256)_exit(92);int id=next++;kinds[id]=kind;values[id]=value;messages[id]=message;return id;}
int64_t bml_result_kind(int64_t r){return kinds[r];}
int64_t bml_result_value(int64_t r){return values[r];}
const char *bml_result_message(int64_t r,int64_t *n)
{const char *s=messages[r]?messages[r]:"";*n=(int64_t)strlen(s);return s;}
void bml_result_free(int64_t r){(void)r;audit("free");}
int64_t bml_result_unmet_count(int64_t r){return kinds[r]==BML_TARGET_REJECTED?1:0;}
const char *bml_result_unmet_field(int64_t r,int64_t i,int64_t k,int64_t *n)
{(void)r;static const char *fields[]={"map_type","ar","arena",""};const char *s=(i==0 && k>=0 && k<4)?fields[k]:"";*n=(int64_t)strlen(s);return s;}

int64_t bml_load_checked(const uint8_t *elf,int64_t n,const char *sha,int64_t sn,const char *maps,int64_t mn,int64_t caps)
{
	(void)elf;(void)n;(void)sha;(void)sn;(void)maps;(void)mn;(void)caps;audit("load");
	const char *cell=getenv("E062_STUB_CELL");
	if(cell && !strcmp(cell,"arena66-checked"))return result(BML_TARGET_REJECTED,0,"map_type ar 33");
	if(cell && !strcmp(cell,"arena73-segv-flag"))return result(BML_MAP_MISMATCH,0,"flags mismatch");
	if(injected("load"))return result(BML_OTHER,0,"stub load failure");
	void *p=mmap((void *)(uintptr_t)ADDRESS,16384,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
	if(p==MAP_FAILED)return result(BML_OTHER,0,"arena reservation failed");
	if((uintptr_t)p!=ADDRESS){munmap(p,16384);return result(BML_OTHER,0,"arena address changed");}
	arena=p;e062_target_loads++;return result(BML_OK,1,NULL);
}
int64_t bml_close(int64_t object)
{
	(void)object;audit(arena?"close":"idempotent");
	if(arena){if(munmap(arena,16384))return result(BML_OTHER,0,"stub munmap failed");arena=NULL;}
	return result(injected("close")?BML_OTHER:BML_OK,0,"stub close");
}
int64_t bml_arena_write(int64_t object,const char *decl,int64_t dn,uint64_t off,uint64_t len,const uint8_t *src,int64_t cap)
{
	(void)object;(void)decl;(void)dn;audit("write");
	uint64_t written=0;if(src && len<=8)for(uint64_t i=0;i<len;i++)written|=(uint64_t)src[i]<<(8*i);
	op("write",off,len,written);
	if(!arena)return result(BML_STATE,0,NULL);
	if(injected("write"))return result(BML_OTHER,0,"stub write failure");
	if(len>16384 || off>16384-len || cap<0 || len>(uint64_t)cap)return result(BML_VALUE_RANGE,0,NULL);
	if(len)memmove(arena+off,src,(size_t)len);
	return result(BML_OK,0,NULL);
}
int64_t bml_arena_read(int64_t object,const char *decl,int64_t dn,uint64_t off,uint64_t len,uint8_t *dst,int64_t cap)
{
	(void)object;(void)decl;(void)dn;audit("read");
	op("read",off,len,0);
	if(!arena)return result(BML_STATE,0,NULL);
	if(injected("read"))return result(BML_OTHER,0,"stub read failure");
	if(len>16384 || off>16384-len || cap<0 || len>(uint64_t)cap)return result(BML_VALUE_RANGE,0,NULL);
	if(len)memmove(dst,arena+off,(size_t)len);
	return result(BML_OK,0,NULL);
}
int64_t bml_map_put_bits(int64_t object,const char *decl,int64_t dn,int64_t key,int64_t bits)
{(void)object;(void)decl;(void)dn;audit("put");op("put",key,bits,0);if(key<0 || key>=8)return result(BML_VALUE_RANGE,0,NULL);input[key]=(uint64_t)bits;return result(BML_OK,0,NULL);}
int64_t bml_map_get_bits(int64_t object,const char *decl,int64_t dn,int64_t key)
{(void)object;(void)decl;(void)dn;audit("get");op("get",key,0,0);if(key<0 || key>=8)return result(BML_VALUE_RANGE,0,NULL);return result(BML_OK,(int64_t)(input[key]+injected("value")),NULL);}
int64_t bml_test_run_ctx_inout(int64_t object,const char *prog,int64_t pn,uint8_t *ctx,int64_t cn)
{
	(void)object;(void)pn;(void)ctx;(void)cn;audit("run");
	op("run",!strcmp(prog,"wr64")?64:0,0,0);
	if(injected("run"))return result(BML_OTHER,0,"stub test_run failure");
	if(input[0]>16376)return result(BML_VALUE_RANGE,0,NULL);
	if(!strcmp(prog,"wr64")){
		/* Contract model only: a fake BPF store must not fault in a user page. */
		unsigned char resident=0;if(mincore(arena+(input[0]&~UINT64_C(4095)),4096,&resident))return result(BML_OTHER,0,"mincore");
		if((resident&1) && !injected("store-missing"))for(int i=0;i<8;i++)arena[input[0]+(unsigned)i]=(unsigned char)((input[1]+injected("store-wrong"))>>(i*8));
		input[2]=1;
	}
	else{uint64_t v=0;for(int i=0;i<8;i++)v|=(uint64_t)arena[input[0]+(unsigned)i]<<(i*8);input[1]=v&255;input[2]=v&65535;input[3]=v&UINT32_MAX;input[4]=v;input[5]=15;}
	return result(BML_OK,0,NULL);
}

extern FILE *__real_fopen(const char *,const char *);
extern size_t __real_fwrite(const void *,size_t,size_t,FILE *);
extern int __real_fflush(FILE *);
extern int __real_fclose(FILE *);
FILE *__wrap_fopen(const char *path,const char *mode)
{FILE *f=__real_fopen(path,mode);if(f && strstr(path,"/events.jsonl"))events=f;return f;}
size_t __wrap_fwrite(const void *p,size_t s,size_t n,FILE *f)
{if((f==events && io_fail("write")) || (io_fail("pre-observe") && s==1 && memmem(p,n,"\"operation\":\"pre-page\"",22))){errno=EIO;return 0;}return __real_fwrite(p,s,n,f);}
int __wrap_fflush(FILE *f)
{if(f==events && io_fail("flush")){errno=EIO;return EOF;}return __real_fflush(f);}
int __wrap_fclose(FILE *f)
{int target=f==events;if(target)events=NULL;int rc=__real_fclose(f);if(target && io_fail("close")){errno=EIO;return EOF;}return rc;}
