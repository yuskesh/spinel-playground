/* E065: real dispatcher/BTF/lv_prog_load/attr encoding; only the native syscall is replaced.
 * Synthetic BTF and feature answers are not evidence of kernel permission. */
#define _GNU_SOURCE
#include "caps/live_internal.h"
#include "util/gostr.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int bad, mode, creates, programs, auxiliary, closes, carrier=-1, program=-1;
static int fds[64], nfds, expected_id;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL:%d %s\n",__LINE__,#x); bad++; } } while (0)
static uint32_t u32(const void *p) { uint32_t v;memcpy(&v,p,4);return v; }
static uint64_t u64(const void *p) { uint64_t v;memcpy(&v,p,8);return v; }
static int newfd(void) { int fd=open("/dev/null",O_RDONLY|O_CLOEXEC);CHECK(fd>=0 && nfds<64);fds[nfds++]=fd;return fd; }
int __real_close(int);
int __wrap_close(int fd)
{
	if(fd==carrier && program>=0)CHECK(fcntl(program,F_GETFD)==-1 && errno==EBADF);
	for(int i=0;i<nfds;i++)if(fds[i]==fd){CHECK(fcntl(fd,F_GETFD)>=0);fds[i]=-1;closes++;}
	return __real_close(fd);
}
long __wrap_syscall(long number,...)
{
	CHECK(number==__NR_bpf);
	if(number!=__NR_bpf){errno=ENOSYS;return -1;}
	va_list ap;va_start(ap,number);int cmd=va_arg(ap,int);uint8_t *a=va_arg(ap,void *);unsigned sz=va_arg(ap,unsigned);va_end(ap);
	if(cmd==BPF_MAP_CREATE && u32(a)==33){
		creates++;CHECK(sz>=72 && u32(a+4)==0 && u32(a+8)==0 && u32(a+12)==1 && u32(a+16)==1024);
		CHECK(u64(a+64)==UINT64_C(0x100001000));
		if(mode==1){errno=ENOMEM;return -1;}
		carrier=newfd();return carrier;
	}
	if(cmd==BPF_PROG_LOAD && u32(a)==31){
		programs++;CHECK(creates==1 && carrier>=0 && sz>=72 && u32(a+44)==16 && u32(a+68)==0);
		CHECK(!strcmp((const char *)(uintptr_t)u64(a+16),"GPL"));
		const uint8_t *ins=(const uint8_t *)(uintptr_t)u64(a+8);unsigned n=u32(a+4);
		CHECK(n==(expected_id==6?9u:7u));
		CHECK(ins[0]==0x18 && ins[1]==0x11 && u32(ins+4)==(unsigned)carrier && !u64(ins+8));
		CHECK(ins[16]==0xb7 && ins[17]==2 && !u32(ins+20));
		CHECK(ins[24]==0xb7 && ins[25]==3 && u32(ins+28)==1);
		unsigned call=32;
		if(expected_id==6){CHECK(ins[32]==0xb7 && ins[33]==4 && u32(ins+36)==UINT32_MAX);CHECK(ins[40]==0xb7 && ins[41]==5 && !u32(ins+44));call=48;}
		CHECK(ins[call]==0x85 && ins[call+1]==0x20 && u32(ins+call+4)==(unsigned)expected_id);
		CHECK(ins[call+8]==0xb7 && ins[call+9]==0 && !u32(ins+call+12) && ins[call+16]==0x95);
		if(mode>=2){
			char *log=(char *)(uintptr_t)u64(a+32);size_t cap=u32(a+28);
			const char *name=expected_id==6?"bpf_arena_alloc_pages":"bpf_arena_free_pages";
			if(log && cap && mode!=3){
				if(mode==4)snprintf(log,cap,"calling kernel function other is not allowed\n");
				else if(mode==5)snprintf(log,cap,"calling kernel function %s is not allowed\ncalling kernel function other is not allowed\n",name);
				else if(mode==6)snprintf(log,cap,"invalid access to memory\n");
				else snprintf(log,cap,"calling kernel function %s is not allowed\n",name);
			}
			errno=EACCES;return -1;
		}
		program=newfd();return program;
	}
	/* Real first-call feature discovery is allowed through the same encoder. */
	if(cmd==BPF_MAP_CREATE || cmd==BPF_PROG_LOAD || cmd==BPF_BTF_LOAD){auxiliary++;return newfd();}
	CHECK(0 && "unexpected native operation (Run/attach forbidden)");errno=EINVAL;return -1;
}

static struct bml_buf types, strings;
static void word(struct bml_buf *b,uint32_t v){uint8_t p[4];for(int i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));bml_buf_add(b,(char *)p,4);}
static uint32_t str(const char *s){uint32_t i=(uint32_t)strings.len;bml_buf_add(&strings,s,strlen(s)+1);return i;}
static void type(const char *s,uint32_t info,uint32_t value){word(&types,*s?str(s):0);word(&types,info);word(&types,value);}
static void context(struct bml_live *l,int fresh,int wrong)
{
	memset(l,0,sizeof *l);bml_buf_add(&strings,"",1);
	type("",2u<<24,0); /* 1 void* */
	type("u32",1u<<24,4);word(&types,32); /* 2 */
	type("i32",1u<<24,4);word(&types,1u<<24|32); /* 3 */
	type("u64",1u<<24,8);word(&types,64); /* 4 */
	type("",13u<<24|5,1); /* 5 alloc proto */
	unsigned args[]={1,1,2,3,wrong?2u:4u};for(int i=0;i<5;i++){word(&types,str("arg"));word(&types,args[i]);}
	type("bpf_arena_alloc_pages",12u<<24|1,5); /* 6 */
	type("",13u<<24|3,0);for(int i=0;i<3;i++){word(&types,str("arg"));word(&types,i==2?2:1);} /* 7 */
	type("bpf_arena_free_pages",12u<<24|1,7); /* 8 */
	struct bml_buf raw={0};word(&raw,0x0001eb9f);word(&raw,24);word(&raw,0);word(&raw,(uint32_t)types.len);word(&raw,(uint32_t)types.len);word(&raw,(uint32_t)strings.len);
	bml_buf_add(&raw,types.p,types.len);bml_buf_add(&raw,strings.p,strings.len);size_t len=raw.len;char *bytes=bml_buf_take(&raw),*msg=NULL;
	CHECK(!bml_kbtf_from_raw((uint8_t *)bytes,len,&l->kb,&msg));free(msg);l->kb_done=1;
	if(!fresh)for(int i=0;i<LVF_N;i++)l->feat[i]=LV_NOTSUP;
	bml_buf_free(&types);bml_buf_free(&strings);
}
static struct bml_kfunc_profile profile(void)
{
	return (struct bml_kfunc_profile){.recipe="kfunc-v1",.kind="syscall",.prog_type="syscall",.prog_type_id=31,.section="syscall",
		.attach_type="-",.target_kind="none",.target="",.prog_flags=16,.context_identity="arena-real-profile"};
}
int main(void)
{
	for(int which=0;which<2;which++)for(int arm=0;arm<13;arm++){
		struct bml_live l;context(&l,arm==12,arm==10);
		struct bml_kfunc_profile p=profile();
		const char *name=which?"bpf_arena_free_pages":"bpf_arena_alloc_pages",*ret=which?"void":"ptr:void";
		struct bml_str args[]={{"ptr:void",8},{"ptr:void",8},{"u32",3},{"i32",3},{"u64",3}};
		mode=arm<=6?arm:0;creates=programs=auxiliary=closes=nfds=0;carrier=program=-1;expected_id=which?8:6;
		if(arm==7)p.prog_flags=0;
		if(arm==8)args[0]=(struct bml_str){"ptr:u8",6};
		if(arm==9){bml_kbtf_free(&l.kb);l.kb_rc=-1;l.kb_err=strdup("fixture BTF absent");}
		if(arm==11)name="bpf_arena_not_a_recipe";
		int value=-1;char *msg=NULL;int rc=bml_live_kfunc_load(&l,&p,name,ret,args,which?3:5,&value,&msg);
		int want=(arm==0 || arm==12)?BML_Q_OK:arm==2?BML_Q_OK:BML_Q_UNKNOWN;
		/* Wrong alloc proto affects alloc only; free remains independently usable. */
		if(arm==10 && which)want=BML_Q_OK;
		CHECK(rc==want && value==(want==BML_Q_OK && arm!=2));
		CHECK(want!=BML_Q_UNKNOWN || (msg && *msg));
		if(arm>=7 && arm!=12 && !(arm==10 && which))CHECK(!creates && !programs && !auxiliary);
		if(creates)CHECK(creates==1 && programs==(mode==1?0:1));
		for(int i=0;i<nfds;i++)CHECK(fds[i]==-1);
		CHECK(closes==nfds);if(arm==12)CHECK(auxiliary>0);else CHECK(!auxiliary);
		printf("arena-recipe-%s-arm%d: %s rc=%d value=%d native=%d/%d/%d closed=%d\n",which?"free":"alloc",arm,bad?"FAIL":"GREEN",rc,value,creates,programs,auxiliary,closes);
		free(msg);bml_live_free(&l);
	}
	return bad?1:0;
}
