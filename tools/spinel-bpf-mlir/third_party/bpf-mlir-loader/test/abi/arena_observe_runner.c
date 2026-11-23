/* Runner + real instrumentation, replacing only ABI/kernel backend. */
#define e062_snapshot unused_stub_snapshot
#define e062_observe unused_stub_observe
#define e062_target_loads stub_target_loads
#define bml_load_checked stub_load_checked
#define bml_close stub_close
#include "arena_live_stub.c"
#undef e062_snapshot
#undef e062_observe
#undef e062_target_loads
#undef bml_load_checked
#undef bml_close
#include "arena_live_wrap.c"
static int mapfd=-1,progfd=-1,map_queries,close_result;
static struct bpf_object *object(void){return (struct bpf_object *)(uintptr_t)1;}
struct bpf_map *bpf_object__find_map_by_name(const struct bpf_object *o,const char *name)
{return o==object() && !strcmp(name,"ar")?(struct bpf_map *)(uintptr_t)2:NULL;}
struct bpf_map *bpf_object__next_map(const struct bpf_object *o,const struct bpf_map *p)
{return o==object() && !p?(struct bpf_map *)(uintptr_t)2:NULL;}
struct bpf_program *bpf_object__next_program(const struct bpf_object *o,struct bpf_program *p)
{return o==object() && !p?(struct bpf_program *)(uintptr_t)3:NULL;}
int bpf_map__fd(const struct bpf_map *m){(void)m;return mapfd;}
int bpf_program__fd(const struct bpf_program *p){(void)p;return progfd;}
void *bpf_map__initial_value(const struct bpf_map *m,size_t *sz){(void)m;*sz=0;return arena;}
int bpf_obj_get_info_by_fd(int fd,void *p,__u32 *n)
{
	(void)n;
	if(fd==mapfd){struct bpf_map_info *i=p;i->id=17;i->type=33;i->map_flags=1024;i->max_entries=4;i->map_extra=ADDRESS;return 0;}
	if(fd==progfd){((struct bpf_prog_info *)p)->id=29;return 0;}
	errno=EBADF;return -EBADF;
}
int bpf_map_get_fd_by_id(__u32 id)
{
	if(id!=17)abort();
	if(injected("observe-query")){errno=EINVAL;return -EINVAL;}
	if(!map_queries++)return open("/dev/null",O_RDONLY);
	errno=ENOENT;return -ENOENT;
}
int bpf_prog_get_fd_by_id(__u32 id){if(id!=29)abort();errno=ENOENT;return -ENOENT;}
int __real_bpf_object__load(struct bpf_object *o){(void)o;return 0;}
void __real_bpf_object__close(struct bpf_object *o)
{(void)o;close_result=stub_close(1);if(mapfd>=0)close(mapfd);if(progfd>=0)close(progfd);mapfd=progfd=-1;}
int64_t bml_load_checked(const uint8_t *elf,int64_t n,const char *sha,int64_t sn,const char *maps,int64_t mn,int64_t caps)
{
	int64_t r=stub_load_checked(elf,n,sha,sn,maps,mn,caps);
	if(bml_result_kind(r)!=BML_OK)return r;
	if(injected("pipe-stderr"))messages[r]="fixture load message";
	/* Model libbpf replacing its own reservation; real mmap counter path. */
	if(mmap(arena,16384,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0)!=arena)abort();
	mapfd=open("/dev/null",O_RDONLY);progfd=open("/dev/null",O_RDONLY);
	if(mapfd<0 || progfd<0)abort();
	__wrap_bpf_object__load(object());return r;
}
int64_t bml_close(int64_t o)
{if(!arena)return stub_close(o);__wrap_bpf_object__close(object());return close_result;}
