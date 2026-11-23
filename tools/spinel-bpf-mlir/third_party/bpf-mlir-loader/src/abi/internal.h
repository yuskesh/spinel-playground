/* abi/internal.h — C ABI (bml_*) の内部 (E006): 結果と handle の registry (mutex)、load した object。 */
#ifndef BML_ABI_INTERNAL_H
#define BML_ABI_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "bml/bml.h"
#include "caps/live_caps.h"
#include "load/load.h"
#include "maps/mapdecl.h"
#include "req/check.h"
#include "req/req.h"

/* ---- 結果 ---- */
struct abi_unmet {
	char *f[4]; /* kind・program・name・detail */
	size_t len[4];
};

struct abi_result {
	int64_t kind, value;
	char *msg;
	size_t msg_len;
	struct abi_unmet *u;
	size_t n_u;
};

/* CONTRACT: places the result in the registry and returns a handle (ownership of r's contents moves). Out of memory is -1 (callers read a negative handle as STATE) */
int64_t abi_put(struct abi_result *r);
/* kind と文 (printf の形) の結果 */
int64_t abi_fail(int64_t kind, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
int64_t abi_ok(int64_t value);
/* Unmet の列を結果に写す (kind・program・name・detail — detail は Unmet.Detail) */
int abi_set_unmets(struct abi_result *r, const struct bml_unmet *u, size_t n);

/* ---- handle ---- */
enum { H_OBJECT = 1, H_LINK, H_READER, H_ITER };

struct abi_object {
	struct bml_obj *lo;            /* guard 付きで load した libbpf の object */
	struct bml_requirements *req;  /* 1 回だけ読んだ requirements (map の操作の宣言の照合) */
	uint8_t *elf;                  /* ELF の写し (records の照合が BTF を読む) */
	size_t elf_len;
	struct bml_unmets rest;        /* 止めなかった Unmet */
	struct bml_live_caps caps;     /* 照合の caps (object と同じ寿命) */
	struct bml_loader_decl arena_decl; /* arena-only copy; strings remain borrowed from the static preset */
	int closed;
	int inflight; /* CONTRACT: number of running calls (under the registry lock). close only at 0 */
	/* load の時の global の宣言 (maps.json の globals — E006 の後半、bml_global_get の照合) */
	struct bml_global_decl *globals;
	size_t n_globals;
};

/* E006 の後半 (globals.c): config の文書を読み、宣言の globals と照合し、.rodata に書く値を *vals に (malloc)。成功は 0、失敗は結果の handle
 * (PRECHECK_FAILED・MAP_MISMATCH・VALUE_RANGE・CONFIG_NOT_SET) */
int64_t abi_config(const char *cfg, int64_t cfg_len, const struct bml_map_decls *d, const uint8_t *elf, size_t elf_len,
		   struct bml_rodata_value **vals, size_t *n_vals);
/* 宣言の globals を object に写す (失敗は -1) と放す */
int abi_globals_keep(struct abi_object *o, const struct bml_map_decls *d);
void abi_globals_free(struct abi_object *o);

/* registry の lock (全ての handle の操作はこの lock の中で表を引く) */
void abi_lock(void);
void abi_unlock(void);
/* CONTRACT: new handle (type, contents, and the owning object's handle, or 0 if none). Returns -1 when out of memory. Call with the lock held */
int64_t abi_handle_new(int type, void *p, int64_t owner);
/* CONTRACT: contents of a handle (NULL for a wrong type or absent). Call with the lock held */
void *abi_handle_get(int64_t h, int type);
/* CONTRACT: removes a handle from the table (returns its contents, or NULL). Call with the lock held */
void *abi_handle_take(int64_t h, int type);
/* type の handle で owner (object の handle) に属するものの中身の一覧 (表に残す — 閉じた reader・iterator は STATE を返すため) */
size_t abi_handle_list_owned(int type, int64_t owner, void ***out);

/* CONTRACT: the open object (one per process; 0 for none). Read with the lock held */
extern int64_t abi_loaded;

/* object の reader と iterator を閉じる (owned.c — close の前) */
void abi_close_owned(int64_t obj);

/* CONTRACT: errno text (Go's spelling; per-thread buffer, valid until the next call) */
const char *abi_errno(int e);

/* object を引く (無い・閉じたは STATE の結果を *err に) */
struct abi_object *abi_object_get(int64_t h, int64_t *err);
/* CONTRACT: the same, counted as a running call (the closed check and the increment are under one lock, closing the check-then-close window).
 * The caller must release the count with abi_object_release */
struct abi_object *abi_object_acquire(int64_t h, int64_t *err);
void abi_object_release(struct abi_object *o);

/* ---- program と link (run.c — trace.c と共有) ---- */
struct bpf_program;
struct bpf_link;
/* 名前 (ptr, len) の program (無ければ STATE の結果の handle、在れば 0 と *p) */
int64_t abi_program(struct abi_object *o, const char *prog, int64_t len, struct bpf_program **p);
/* link を handle の表に (OK の結果 — value は link の handle。失敗は l を壊して OTHER) */
int64_t abi_link_put(struct bpf_link *l);
/* E015 (uprobe.c): uprobe の target の文書を読み、ELF の uprobe の program と照らし、path を開いて o->caps.bins に (照合の uprobe_binary と
 * attach が同じ fd)。成功は 0 (len 0 は target 無し)、失敗は結果の handle (読めない文書は PRECHECK_FAILED・開けない / uprobe でない program は OTHER) */
int64_t abi_uprobe_targets(struct abi_object *o, const char *doc, int64_t len);
/* H_LINK の handle の中身 */
struct abi_link {
	struct bpf_link *l; /* NULL は detach 済み */
	int64_t uprobe_owner; /* uprobe の link の object (E015 — bml_uprobe_link_file の照らし、他は 0) */
	char *uprobe_file;    /* attach の時の perf の link の info の file (表と同じ寿命) */
	int *extra_fds;       /* E040: tracepoint の link の program の無い CPU の perf の event (detach で l と一緒に閉じる) */
	size_t n_extra;
	struct bpf_link **more; /* E044: USDT の点ごとの uprobe の 2 つ目以降の link (detach で l と一緒に壊す) */
	size_t n_more;
};
/* CONTRACT: the same, for per-point USDT links (ownership of the n entries in more moves, the array is copied; failure destroys them all) */
int64_t abi_link_put_more(struct bpf_link *l, struct bpf_link **more, size_t n);
/* E044 (uprobe.c が持つ — usdt.c と共有): program の load の時の target の fd (無ければ -1)・fd の file の全体 (malloc、失敗は NULL と errno)・
 * perf の link の info の uprobe の offset と cookie (want の型でなければ 1、読めなければ -errno) */
int abi_uprobe_target_fd(const struct abi_object *o, const char *prog);
uint8_t *abi_read_fd(int fd, size_t *len);
int abi_uprobe_info(int fd, uint32_t want, uint32_t *off, uint64_t *cookie, char *file, uint32_t cap);
/* E049 (trace.c が持つ — ksyscall.c と共有): perf の link の info の kprobe の関数の名前を buf に (want の型でなければ "")。成功は 0、失敗は -errno */
int abi_kprobe_link_name(int fd, uint32_t want, char *buf, uint32_t cap);
/* E044 (usdt.c): program の attach の行 usdt (無ければ NULL) */
const struct bml_attach *abi_usdt_row(const struct abi_object *o, const char *name);
/* CONTRACT: the same, for a uprobe link (ownership of owner and file moves) */
int64_t abi_link_put_uprobe(struct bpf_link *l, int64_t owner, char *file);
/* CONTRACT: the same, for a tracepoint link (ownership of the other CPUs' perf fds moves; failure destroys l and closes every fd) */
int64_t abi_link_put_extra(struct bpf_link *l, int *fds, size_t n);
/* CONTRACT: dups the link's kernel fd and returns it (to read its info outside detach races; the caller closes it).
 * For a missing link or one already detached, stores the STATE result handle in *err and returns -1 */
int abi_link_dup_fd(int64_t link, int64_t *err);
/* program の種類の名前 (取り違えの文 — xdp・fentry・fexit・kprobe・uprobe・tc ingress・tc egress・他は libbpf の型の名前 — trace.c) */
const char *abi_kind_name(const struct abi_object *o, struct bpf_program *p);

#endif
