/* E062: real C ABI observations. Only the link-time stub build replaces APIs. */
#define _GNU_SOURCE
#include <bml/bml.h>
#include "arena_live_instrument.h"
#include <errno.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>

#define ADDRESS UINT64_C(35184372092928)
#define LENGTH 16384
struct run {FILE *events;int64_t object;int failed,arena_missing;char message[4096];};

static void fail(struct run *r,const char *step)
{
	int error=errno;r->failed=1;
	/* A broken stderr must not erase the reason from the owned event file. */
	if(r->events){(void)fprintf(r->events,"{\"step\":\"failure\",\"operation\":\"%s\",\"errno\":%d}\n",step,error);(void)fflush(r->events);}
	fprintf(stderr,"arena-live: failure at %s (errno=%d)\n",step,error);
}
static int event(struct run *r,const char *step,int64_t kind,int64_t value)
{
	char b[512];int n=snprintf(b,sizeof b,"{\"step\":\"%s\",\"kind\":%lld,\"value\":%lld,\"target_loads\":%d}\n",step,(long long)kind,(long long)value,e062_target_loads);
	if(n<0 || (size_t)n>=sizeof b || fwrite(b,1,(size_t)n,r->events)!=(size_t)n || fflush(r->events) || ferror(r->events)) {fail(r,"save-events");return 0;}
	if(fprintf(stdout,"step %s kind=%lld\n",step,(long long)kind)<0 || fflush(stdout)){fail(r,"stdout");return 0;}
	return 1;
}
static int quoted(FILE *f,const char *s,int64_t n)
{
	if(n<0 || fputc('"',f)==EOF)return -1;
	for(int64_t i=0;i<n;i++){unsigned char c=(unsigned char)s[i];if(c=='"' || c=='\\'){if(fputc('\\',f)==EOF || fputc(c,f)==EOF)return -1;}else if(c<32){if(fprintf(f,"\\u%04x",c)<0)return -1;}else if(fputc(c,f)==EOF)return -1;}
	return fputc('"',f)==EOF?-1:0;
}
static int unmet(struct run *r,int64_t result)
{
	int64_t count=bml_result_unmet_count(result);
	if(!event(r,"unmet-count",0,count))return 0;
	for(int64_t i=0;i<count;i++) {
		const char *names[]={"kind","program","name","detail"};int match=1;
		if(fputs("{\"step\":\"unmet\"",r->events)==EOF)return 0;
		for(int k=0;k<4;k++) {
			int64_t n=0;const char *s=bml_result_unmet_field(result,i,k,&n);
			if(!s || n<0 || fprintf(r->events,",\"%s\":",names[k])<0 || quoted(r->events,s,n))return 0;
			const char *want=k==0?"map_type":k==1?"ar":"arena";
			if(k<3 && ((size_t)n!=strlen(want) || memcmp(s,want,(size_t)n)))match=0;
		}
		if(match)r->arena_missing=1;
		if(fputs("}\n",r->events)==EOF || fflush(r->events))return 0;
	}
	return 1;
}
static int take(struct run *r,const char *step,int64_t result,int64_t want,int64_t *value)
{
	int64_t kind=bml_result_kind(result),v=bml_result_value(result),n=0;
	const char *message=bml_result_message(result,&n);
	snprintf(r->message,sizeof r->message,"%.*s",(int)(n<4095?n:4095),message?message:"");
	if(n>0 && (fwrite(message,1,(size_t)n,stderr)!=(size_t)n || fputc('\n',stderr)==EOF || fflush(stderr)))fail(r,"stderr");
	if(value)*value=v;
	if(kind==BML_TARGET_REJECTED && !unmet(r,result))fail(r,"save-unmet");
	bml_result_free(result);
	if(kind!=want){fail(r,step);return 0;}
	return event(r,step,kind,v) && !r->failed;
}
static unsigned char *readfile(const char *path,size_t *len)
{
	FILE *f=fopen(path,"rb");if(!f)return NULL;unsigned char *p=NULL;long n;
	if(fseek(f,0,SEEK_END) || (n=ftell(f))<=0 || n>1024*1024 || fseek(f,0,SEEK_SET))goto done;
	p=malloc((size_t)n+1);if(!p)goto done;
	if(fread(p,1,(size_t)n,f)!=(size_t)n){free(p);p=NULL;}else{p[n]=0;*len=(size_t)n;}
done:if(fclose(f)){free(p);p=NULL;}return p;
}
static int mapput(struct run *r,const char *decl,int64_t key,uint64_t value)
{return take(r,"map-put",bml_map_put_bits(r->object,decl,(int64_t)strlen(decl),key,(int64_t)value),BML_OK,NULL);}
static int mapwant(struct run *r,const char *decl,int64_t key,uint64_t want)
{
	int64_t value;
	if(!take(r,"map-get",bml_map_get_bits(r->object,decl,(int64_t)strlen(decl),key),BML_OK,&value))return 0;
	if((uint64_t)value!=want){fail(r,"map-value");return 0;}return 1;
}
static int runprog(struct run *r,const char *name)
{return take(r,"test-run",bml_test_run_ctx_inout(r->object,name,(int64_t)strlen(name),NULL,0),BML_OK,NULL);}
static int fd_count(void)
{
	DIR *d=opendir("/proc/self/fd");if(!d)return -1;
	int count=0;struct dirent *ent;
	while((ent=readdir(d)))if(strcmp(ent->d_name,".") && strcmp(ent->d_name,".."))count++;
	return closedir(d)?-1:count;
}
static int pre_page(struct run *r,FILE *f,uint64_t off,int after)
{
	unsigned char resident=0;
	if(mincore((void *)(uintptr_t)(ADDRESS+(off&~UINT64_C(4095))),4096,&resident)){fail(r,"pre-mincore");return 0;}
	char b[256];int n=snprintf(b,sizeof b,"{\"operation\":\"pre-page\",\"after\":%d,\"offset\":%llu,\"length\":1,\"byte\":0,\"resident\":%u}\n",after,(unsigned long long)off,resident&1);
	if(n<0 || (size_t)n>=sizeof b || fwrite(b,1,(size_t)n,f)!=(size_t)n || fflush(f) || ferror(f)){fail(r,"save-pre-page");return 0;}
	if(after && !(resident&1)){fail(r,"pre-nonresident");return 0;}
	return 1;
}

int main(int argc,char **argv)
{
	/* Test executable only: report EPIPE and explicitly close owned resources. */
	struct sigaction pipe_action={.sa_handler=SIG_IGN};
	if(sigemptyset(&pipe_action.sa_mask) || sigaction(SIGPIPE,&pipe_action,NULL))return 1;
	if(argc!=8){fprintf(stderr,"arena_live CELL ELF SHA MAPS ARENA_DECL INPUT_DECL OUT\n");return 2;}
	const char *cell=argv[1],*out=argv[7];
	int share=!strcmp(cell,"arena73-share-read"),wr=!strcmp(cell,"arena73-share-write"),lazy=!strcmp(cell,"arena73-lazy");
	int collision=!strcmp(cell,"arena73-collision"),flag=!strcmp(cell,"arena73-segv-flag"),old=!strcmp(cell,"arena66-checked");
	if((!share && !wr && !lazy && !collision && !flag && !old) || strlen(argv[3])!=64)return 2;
	int initial_fds=fd_count();if(initial_fds<0)return 1;
	struct run r={0};unsigned char *data[4]={0};size_t sizes[4]={0};void *reservation=NULL;FILE *observe=NULL;
	char path[4096];int64_t closed=0;unsigned char bytes[8]={0};uint64_t x=wr?UINT64_C(0x0123456789abcdef):UINT64_C(0x1122334455667788);
	for(int i=0;i<4;i++){data[i]=readfile(argv[i==0?2:i+3],&sizes[i]);if(!data[i]){fail(&r,"read-input");goto done;}}
	if(sysconf(_SC_PAGESIZE)!=4096){fail(&r,"page-size");goto done;}
	if(snprintf(path,sizeof path,"%s/events.jsonl",out)>=(int)sizeof path){fail(&r,"out-path");goto done;}
	r.events=fopen(path,"wx");if(!r.events){fail(&r,"open-events");goto done;}
	if(snprintf(path,sizeof path,"%s/observation.jsonl",out)>=(int)sizeof path){fail(&r,"observe-path");goto done;}
	observe=fopen(path,"wx");if(!observe){fail(&r,"open-observation");goto done;}
	e062_observe(observe);
	if(collision) {
		reservation=mmap((void *)(uintptr_t)ADDRESS,LENGTH,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
		if(reservation==MAP_FAILED){reservation=NULL;fail(&r,"collision-reserve");goto done;}
		if((uintptr_t)reservation!=ADDRESS){fail(&r,"collision-address");goto done;}
		((unsigned char *)reservation)[0]=0x73;((unsigned char *)reservation)[LENGTH-1]=0x39;
	}
	int64_t result=bml_load_checked(data[0],(int64_t)sizes[0],argv[3],64,(const char *)data[1],(int64_t)sizes[1],0);
	if(bml_result_kind(result)==BML_OK)r.object=bml_result_value(result);
	int want=collision?BML_OTHER:flag?BML_MAP_MISMATCH:old?BML_TARGET_REJECTED:BML_OK;
	if(!take(&r,"checked-load",result,want,NULL))goto done;
	if(collision || flag || old) {
		if(e062_target_loads || (old?!r.arena_missing:!strstr(r.message,collision?"arena":"flag"))){fail(&r,"rejection-before-target-load");goto done;}
		if(collision && (((unsigned char *)reservation)[0]!=0x73 || ((unsigned char *)reservation)[LENGTH-1]!=0x39))fail(&r,"collision-bytes");
		if(collision && !r.failed && !event(&r,"collision-marker",0,0x3973))r.failed=1;
		goto done;
	}
	if(e062_snapshot(r.events)){fail(&r,"save-map-snapshot");goto done;}
	const char *ar=(const char *)data[2],*in=(const char *)data[3];
	uint64_t off=lazy?8200:wr?4096:0;
	if(lazy) {
		unsigned char resident=0;
		if(mincore((void *)(uintptr_t)(ADDRESS+8192),4096,&resident) || (resident&1)){fail(&r,"lazy-before");goto done;}
		if(!event(&r,"lazy-before",0,resident&1))goto done;
	}
	for(int i=0;i<8;i++)bytes[i]=(unsigned char)(x>>(i*8));
	if(wr) {
		unsigned char zero=0;
		if(!pre_page(&r,observe,off,0) || !take(&r,"arena-prewrite",bml_arena_write(r.object,ar,strlen(ar),off,1,&zero,1),BML_OK,NULL) || !pre_page(&r,observe,off,1))goto done;
		if(!mapput(&r,in,0,off) || !mapput(&r,in,1,x) || !runprog(&r,"wr64") || !mapwant(&r,in,2,1))goto done;
	}else{
		if(!take(&r,"arena-write",bml_arena_write(r.object,ar,strlen(ar),off,8,bytes,8),BML_OK,NULL))goto done;
		if(lazy){unsigned char resident=0;if(mincore((void *)(uintptr_t)(ADDRESS+8192),4096,&resident) || !(resident&1)){fail(&r,"lazy-after");goto done;}if(!event(&r,"lazy-after",0,resident&1))goto done;}
		if(!mapput(&r,in,0,off) || !runprog(&r,"rd"))goto done;
		uint64_t values[5]={x&255,x&65535,x&UINT32_MAX,x,15};
		for(int i=0;i<5;i++)if(!mapwant(&r,in,i+1,values[i]))goto done;
	}
	unsigned char got[8];
	if(!take(&r,"arena-read",bml_arena_read(r.object,ar,strlen(ar),off,8,got,8),BML_OK,NULL))goto done;
	uint64_t observed=0;for(int i=0;i<8;i++)observed|=(uint64_t)got[i]<<(i*8);
	if(!event(&r,"arena-bytes",0,(int64_t)observed))goto done;
	if(memcmp(got,bytes,8)){fail(&r,"arena-bytes");goto done;}
done:
	if(r.object){closed=r.object;r.object=0;(void)take(&r,"cleanup-close",bml_close(closed),BML_OK,NULL);}
	if(share && closed && !r.failed){
		if(!take(&r,"reclose",bml_close(closed),BML_OK,NULL) || !take(&r,"closed-read",bml_arena_read(closed,(const char *)data[2],sizes[2],0,0,NULL,0),BML_STATE,NULL))r.failed=1;
	}
	if(reservation){if(munmap(reservation,LENGTH))fail(&r,"collision-cleanup");reservation=NULL;}
	if((share || collision) && !r.failed) {
		void *p=mmap((void *)(uintptr_t)ADDRESS,LENGTH,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
		if(p==MAP_FAILED)fail(&r,"re-reserve");else{if((uintptr_t)p!=ADDRESS)fail(&r,"re-reserve-address");if(munmap(p,LENGTH))fail(&r,"re-reserve-cleanup");}
	}
	for(int i=0;i<4;i++)free(data[i]);
	if(r.events && !r.failed && e062_snapshot(r.events))fail(&r,"save-final-snapshot");
	if(r.events){if(fflush(r.events) || ferror(r.events))fail(&r,"flush-events");FILE *f=r.events;r.events=NULL;if(fclose(f))fail(&r,"close-events");}
	e062_observe(NULL);
	if(observe){if(fflush(observe) || ferror(observe))fail(&r,"flush-observation");if(fclose(observe))fail(&r,"close-observation");}
	if(fd_count()!=initial_fds)fail(&r,"owned-fd-residue");
	if(r.failed)return 1;
	if(fprintf(stdout,"cell %s complete\n",cell)<0 || fflush(stdout))return 1;
	if(snprintf(path,sizeof path,"%s/success.json",out)>=(int)sizeof path)return 1;
	FILE *f=fopen(path,"wx");if(!f)return 1;
	int bad=fprintf(f,"{\"cell\":\"%s\",\"status\":\"same\",\"target_loads\":%d,\"close_cell\":%s}\n",cell,e062_target_loads,share?"true":"false")<0;
	if(fflush(f) || ferror(f))bad=1;
	if(fclose(f))bad=1;
	if(bad){unlink(path);return 1;}return 0;
}
