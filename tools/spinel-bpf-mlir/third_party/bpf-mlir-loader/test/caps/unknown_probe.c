/* E062: real callbacks/decision code, finite lower-operation stubs, no BPF. */
#define _GNU_SOURCE
#include "caps/live_caps.h"
#include "caps/live_internal.h"
#include <errno.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int family, mode, loads, maps, alive, nextfd, rewrite, features;
static int fds[128];
static int newfd(void) { int fd=++nextfd; if(fd>=128)abort(); fds[fd]=1;alive++;return fd; }
void __wrap_lv_close(int fd) { if(fd<0)return; if(fd>=128 || !fds[fd])abort();fds[fd]=0;alive--; }
int __wrap_lv_bpf(int cmd,void *attr,unsigned n) {
 (void)attr;(void)n;if(cmd!=BPF_MAP_CREATE)abort();maps++;
 if(family==0 && ((mode==2 && maps==1)||(mode==3 && maps==2)))return -EPERM;
 return newfd();
}
void __wrap_lv_kmo(struct bml_live *l,struct lv_kmo *o) { (void)l;memset(o,0,sizeof *o);o->replace_decl_tags=rewrite; }
void __wrap_lv_obj_name(struct bml_live *l,const char *name,char dst[16]) { (void)l;snprintf(dst,16,"%s",name); }
int __wrap_lv_btf_handle_reason(struct bml_live *l,const uint8_t *b,size_t n,struct lv_res *r) {
 (void)b;(void)n;memset(r,0,sizeof *r);l->feat[LVF_BTF]=LV_OK;
 if(family==0 && mode>=9){r->fd=-1;r->err=EINVAL;const char log[]="invalid btf\n";lv_btf_reason(r,1,log,sizeof log);return -1;}
 r->fd=newfd();return r->fd;
}
int __wrap_lv_feat(struct bml_live *l,int which){(void)l;features++;return family==0 && mode==10 && which==LVF_MAP_BTF?-EIO:LV_OK;}
static int result(struct lv_res *r,int kind,const char *line) {
 memset(r,0,sizeof *r);r->fd=-1;
 if(kind==0){r->fd=newfd();return 0;}
 r->err=kind==1?EINVAL:EPERM;r->verifier=kind==1;
 if(kind==1){r->lines=calloc(1,sizeof(char*));if(!r->lines)abort();r->lines[0]=strdup(line);r->n_lines=1;}
 return -1;
}
int __wrap_lv_prog_load(struct bml_live *l,const struct lv_prog *p,struct lv_res *r) {
 (void)l;(void)p;int i=loads++;
 if(family==0){
  if(mode==4 && i==0)return result(r,1,"invalid control");
  if(mode==5 && i==2)return result(r,1,"invalid xdp");
  if(i==1 && mode==6)return result(r,2,"");
  if(i==1 && mode!=7)return result(r,1,"invalid field");
  return result(r,0,"");
 }
 if(family==1){
  if((mode==3 && i==0)||(mode==5 && i==1))return result(r,2,"");
  if(i==0)return result(r,1,mode==4?"invalid control":"invalid mem access 'mem_or_null'");
  if(mode==7)return result(r,0,"");
  return result(r,1,mode==8?"invalid mem access 'mem_or_null'":"invalid tagged");
 }
 if((mode==0 && i==0)||(mode==2 && i==1))return result(r,2,"");
 if(i==0)return mode==1?result(r,1,"invalid mem access control"):result(r,0,"");
 if(mode==4)return result(r,0,"");
 return result(r,1,mode==5?"invalid mem access 'or_null'":"invalid mem access other");
}
int main(void) {
 for(family=0;family<3;family++)for(mode=0;mode<(family==0?11:family==2?6:9);mode++){
  struct bml_live_caps c={0};struct bml_caps q; bml_live_caps(&c,&q);
  features=loads=maps=alive=0;nextfd=8;rewrite=family==1 && mode==2;
  int v=-1,rc;char *msg=NULL;
  if(family==0)rc=q.map_field(q.ctx,"struct_ops",mode==0?BPF_PROG_TYPE_STRUCT_OPS:BPF_PROG_TYPE_XDP,mode==1?"bad":"bpf_timer",&v,&msg);
  else if(family==1)rc=q.arg_tag(q.ctx,"struct_ops",mode==0?BPF_PROG_TYPE_STRUCT_OPS:BPF_PROG_TYPE_XDP,mode==1?"bad":"arg:nonnull","mem",&v,&msg);
  else rc=q.nullable_args(q.ctx,&v,&msg);
  printf("%d/%d\t%d\t%d\t%s\n",family,mode,rc,v,msg?msg:"");
  if(family==0 && mode>=9 && features!=1){fprintf(stderr,"mode %d: feature calls %d, want 1\n",mode,features);return 2;}
  if(alive)abort();int oldfeatures=features,oldloads=loads,oldmaps=maps,v2=-1,rc2;char *m2=NULL;
  if(family==0)rc2=q.map_field(q.ctx,"alias",mode==0?BPF_PROG_TYPE_STRUCT_OPS:BPF_PROG_TYPE_XDP,mode==1?"bad":"bpf_timer",&v2,&m2);
  else if(family==1)rc2=q.arg_tag(q.ctx,"alias",mode==0?BPF_PROG_TYPE_STRUCT_OPS:BPF_PROG_TYPE_XDP,mode==1?"bad":"arg:nonnull","mem",&v2,&m2);
  else rc2=q.nullable_args(q.ctx,&v2,&m2);
  if(rc2!=rc || v2!=v || strcmp(msg?msg:"",m2?m2:"") || loads!=oldloads || maps!=oldmaps || features!=oldfeatures)abort();
  free(msg);free(m2);bml_live_caps_free(&c);
 }
 return 0;
}
