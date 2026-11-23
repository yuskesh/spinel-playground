/* Real snapshot implementation; fake kernel/time only. No BPF. */
#define _GNU_SOURCE
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <signal.h>
static int fake_clock(clockid_t,struct timespec *);
static int fake_sleep(const struct timespec *,struct timespec *);
static int fake_close(int);
#define clock_gettime fake_clock
#define nanosleep fake_sleep
#define close fake_close
#include "arena_live_wrap.c"
#undef close
#undef clock_gettime
#undef nanosleep
static const char *mode;
static int queries,closes,sleeps,clock_calls;
static int64_t ticks;
static int is(const char *s){return !strcmp(mode,s);}
static int fake_clock(clockid_t c,struct timespec *ts)
{
	if(c!=CLOCK_MONOTONIC)abort();
	clock_calls++;
	if(is("clock")){errno=EIO;return -1;}
	int64_t n=is("backwards") && clock_calls>1?ticks-1:ticks;
	ts->tv_sec=n/1000000000;ts->tv_nsec=n%1000000000;return 0;
}
static int fake_sleep(const struct timespec *ts,struct timespec *unused)
{
	(void)unused;sleeps++;
	if(ts->tv_nsec!=10000000 || ts->tv_sec)abort();
	if(is("wait")){errno=EINTR;return -1;}
	if(!is("frozen"))ticks+=ts->tv_nsec;
	return 0;
}
static int fake_close(int fd)
{
	closes++;int rc=close(fd);
	if(is("close")){errno=EIO;return -1;}return rc;
}
static int query(void)
{
	queries++;
	if(is("slow-absent") || is("slow-error"))ticks+=15000000000LL;
	if(is("query") || is("slow-error")){errno=EPERM;return -EPERM;}
	if(is("delayed") && queries<=2)return open("/dev/null",O_RDONLY);
	if(is("residual") || is("frozen") || is("wait") || is("close"))return open("/dev/null",O_RDONLY);
	errno=ENOENT;return -ENOENT;
}
int bpf_map_get_fd_by_id(__u32 id){if(id!=17)abort();return query();}
int bpf_prog_get_fd_by_id(__u32 id){if(id!=29)abort();return query();}
struct bpf_map *bpf_object__find_map_by_name(const struct bpf_object *o,const char *n)
{(void)o;(void)n;abort();}
int bpf_map__fd(const struct bpf_map *m){(void)m;abort();}
int bpf_obj_get_info_by_fd(int fd,void *info,__u32 *len)
{
	(void)fd;(void)len;
	if(is("capture-info")){errno=EBADF;return -EBADF;}
	((struct bpf_map_info *)info)->id=is("capture-zero")?0:17;return 0;
}
void *bpf_map__initial_value(const struct bpf_map *m,size_t *s)
{(void)m;(void)s;abort();}
static int one(const char *name,const char *reason,int success)
{
	mode=name;queries=closes=sleeps=clock_calls=0;ticks=1000000000;
	nm=np=1;map_ids[0]=17;prog_ids[0]=29;capture_error=0;
	if(is("empty"))nm=np=0;
	FILE *f=is("events-storage")?fopen("/dev/full","w"):tmpfile(),*audit=is("storage")?fopen("/dev/full","w"):tmpfile();
	if(!f || !audit)return 2;
	e062_observe(audit);
	if(!strncmp(mode,"capture-",8)) {
		nm=is("capture-capacity")?8:0;
		capture("map",42,map_ids,&nm);
	}
	int rc=e062_snapshot(f),bad=(rc==0)!=success;
	if(is("delayed") && (queries!=4 || closes!=2 || sleeps!=1))bad=1;
	if(is("residual") && (ticks!=16000000000LL || sleeps!=1500))bad=1;
	if(is("frozen") && sleeps!=1500)bad=1;
	if(is("close") && (queries!=1 || closes!=1 || sleeps))bad=1;
	if(is("slow-absent") && (queries!=1 || sleeps))bad=1;
	if(!strncmp(mode,"capture-",8) && queries)bad=1;
	if(reason && !is("storage")) {
		char buf[1024],needle[128];int found=0;rewind(audit);
		snprintf(needle,sizeof needle,"\"operation\":\"%s\"",reason);
		while(fgets(buf,sizeof buf,audit))if(strstr(buf,needle)) {
			if(is("capture-info") && (!strstr(buf,"\"errno\":9") || !strstr(buf,"\"fd\":42")))continue;
			if(is("empty") && !strstr(buf,"\"elapsed_ns\":0,"))continue;
			found=1;
		}
		if(!found)bad=1;
	}
	if(!success && !is("events-storage") && ftell(f)!=0)bad=1;
	fclose(f);fclose(audit);e062_observe(NULL);
	printf("%s %s rc=%d query=%d close=%d sleeps=%d\n",bad?"FAIL":"PASS",name,rc,queries,closes,sleeps);
	return bad;
}
int main(void)
{
	struct {const char *name,*reason;int success;} cases[]={
		{"empty","absent",1},{"immediate","absent",1},{"delayed","absent",1},
		{"capture-info","capture-info",0},{"capture-zero","capture-zero-id",0},
		{"capture-capacity","capture-capacity",0},{"residual","deadline",0},
		{"frozen","round-limit",0},{"query","query-error",0},
		{"close","query-close",0},{"clock","clock",0},{"backwards","clock-backwards",0},
		{"wait","wait",0},{"slow-absent","deadline",0},{"slow-error","deadline",0},
		{"storage",NULL,0},{"events-storage","snapshot-flush",0}
	};
	int bad=0;for(size_t i=0;i<sizeof cases/sizeof cases[0];i++)bad|=one(cases[i].name,cases[i].reason,cases[i].success);
	pid_t child=fork();if(child<0)return 2;
	if(!child){
		int p[2];if(pipe(p))_exit(2);close(p[0]);
		FILE *f=fdopen(p[1],"w");if(!f)_exit(2);
		signal(SIGPIPE,SIG_IGN);e062_observe(f);
		int rc=record("broken-pipe","all",-1,0,0,0,0,0);(void)fclose(f);_exit(rc==-1?0:3);
	}
	int status;if(waitpid(child,&status,0)!=child)return 2;
	if(!WIFEXITED(status) || WEXITSTATUS(status)!=0)bad=1;
	printf("%s observation broken pipe\n",WIFEXITED(status) && WEXITSTATUS(status)==0?"PASS":"FAIL");
	return bad;
}
