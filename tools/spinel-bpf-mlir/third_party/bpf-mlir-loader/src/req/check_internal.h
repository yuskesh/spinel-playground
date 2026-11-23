/* req/check_internal.h — 照合 (Check) の内部の部品 (req/ の中だけ — E003 の前の構造の整理で check.c を分けた) */
#ifndef BML_REQ_CHECK_INTERNAL_H
#define BML_REQ_CHECK_INTERNAL_H

#include <stdint.h>

#include "req/check.h"

struct ck {
	const struct bml_requirements *req;
	const struct bml_caps *caps;
	struct bml_unmets *out;
	char **err;
	int oom;
	/* bpf-mlir E388 (E031): 問うた (program, attach type) — 汎用の attach と ctxaccess で 1 回だけ問う ("<program>\0<attach type>") */
	char **asked;
	size_t n_asked, cap_asked;
};

char *ck_dupn(const char *s);
char *ck_fmtd(const char *f, ...) __attribute__((format(printf, 1, 2)));
/* CONTRACT: adds an Unmet; ownership of detail moves (NULL means "") */
void ck_add(struct ck *c, const char *kind, const char *program, const char *name, int64_t id, char *detail);
int ck_has(const struct ck *c, void *fnptr, const char *q);
#define HAS(c, f, q) ck_has((c), (void *)(c)->caps->f, (q))
const struct bml_loader_decl *ck_loader_of(const struct ck *c);
/* CONTRACT: stops with a check error (ownership of msg moves to *err) */
int ck_fail(struct ck *c, char *msg);
void ck_add_diffs(struct ck *c, const char *kind, const char *program, const char *name, struct bml_strs *d);
const char *ck_tracing_attach(const struct bml_requirements *r, const char *prog);
int ck_may_hold_field(const struct bml_map *m);
int ck_in_list(const char **l, size_t n, const char *s);
const char *ck_btf_rewrite_name(const char *f);
int ck_has_nul(const struct bml_requirements *r);
int ck_check_enum_values(struct ck *c);
int ck_check_struct_sizes(struct ck *c);
int ck_check_fib_flags(struct ck *c);
void ck_check_loader_rows(struct ck *c);
int ck_guards_state(struct ck *c, const struct bml_guard_list *gs, int *state, char **why);
int ck_check_kfields_guarded(struct ck *c);
int ck_check_ksym_vars(struct ck *c);
int ck_check_kconfigs(struct ck *c);
int bml_unmet_kernel_string(const struct bml_unmet *u, char **out);
/* check_target_rows.c (bpf-mlir E649 / E654 / E660 — E066): 汎用の helper の照合より先の helper_target・netkit・sleepable */
int ck_needs_helper_target(const struct bml_program *p, const struct bml_helper *h);
int ck_check_helper_targets(struct ck *c);
int ck_check_netkit(struct ck *c, const struct bml_attach *a);
int ck_check_sleepable(struct ck *c, const struct bml_attach *a);

/* attach の行の照合 (check_attach.c) */
int ck_check_nullable(struct ck *c, const struct bml_attach *a);
int ck_check_arch_ctx(struct ck *c, const struct bml_attach *a, char **target_arch);
/* ask_alias は loader の付け直しの名前を問う (単数の kprobe・kretprobe)。multi の族は問わない (bpf-mlir E456 — E039) */
int ck_check_kprobe_target(struct ck *c, const struct bml_attach *a, const char *target_arch, int ask_alias);
int ck_check_uprobe(struct ck *c, const struct bml_attach *a);
/* bpf-mlir E456 (E039): uprobe の照合の分け — binary を開く (1 は開いた — *bin と *elf は呼び手が閉じる、0 は Unmet で止める、-1 は誤り) と 1 つの target */
struct bml_elf;
int ck_uprobe_open(struct ck *c, const struct bml_attach *a, const char *name, uint8_t **bin, struct bml_elf *elf);
/* uprobe_source.c (bpf-mlir E557 — 判定の版 16 — E055): attach ごとの DWARF の源 (本体の埋め込みか分けた file — 1 回だけ解き multi で共有) */
#include "elf/elf.h"
struct bml_dwarf;
struct bml_dwarf_sub;
struct ck_dsrc {
	const struct bml_elf *body;
	const char *program;
	int resolved, split_open;
	struct bml_dwarf *d; /* 解けた DWARF (err が無い時) */
	uint8_t *raw;        /* 分けた file の byte の snapshot (照合の間だけ) */
	size_t rawn;
	struct bml_elf split;
	char *err;        /* 源の誤りの文 (uprobearg_unknown の Detail・uretprobe_abi_unknown の原因) */
	const char *kind; /* 確定の不一致の Unmet (uprobe_debug_build_id・uprobe_debug_crc) — NULL は無し */
};
void ck_dsrc_init(struct ck_dsrc *s, const struct bml_elf *body, const char *program);
void ck_dsrc_free(struct ck_dsrc *s);
void ck_dsrc_read(struct ck *c, struct ck_dsrc *s);
int ck_dsrc_subprogram(const struct ck_dsrc *s, const char *target, int parameters, const uint8_t *raw, size_t n_raw, struct bml_dwarf_sub *out,
		       char **err);
void ck_uprobe_target(struct ck *c, const struct bml_attach *a, struct bml_elf *elf, const char *target, int ret, struct ck_dsrc *src);
/* check_v9.c (bpf-mlir E388 — E031): 汎用の attach の行 (attach_type と値を持つ target の attach_target) と ctxaccess の行 (ctx_access) */
int ck_check_generic_attach(struct ck *c, const struct bml_attach *a);
/* checkAttachType (program, attach type ごとに 1 回) — 0 は続ける、-1 は照合の誤り */
int ck_check_attach_type(struct ck *c, const char *program, const char *at);
/* check_v12.c (bpf-mlir E456 — 判定の版 11 — E039): multi の族・usdt・innermap の map type */
int ck_check_multi(struct ck *c, const struct bml_attach *a);
int ck_check_usdt(struct ck *c, const struct bml_attach *a);
int ck_check_innermaps(struct ck *c);
/* check_v13.c (bpf-mlir E480 — 判定の版 12 — E041): loader の lsm_cgroup / fsession の load・kfunc・trace_lsm_cgroup・ksyscall */
int ck_check_prog_loader(struct ck *c, const struct bml_attach *a);
int ck_check_kfuncs(struct ck *c);
int ck_check_v13(struct ck *c, const struct bml_attach *a);
int ck_check_tpbuf(struct ck *c, const struct bml_attach *a); /* bpf-mlir E499 (E042) */
int ck_check_ctx_accesses(struct ck *c);
int ck_check_fmod_ret(struct ck *c, const struct bml_attach *a); /* bpf-mlir E404 (版 10 — E032) */
/* check_v11.c (bpf-mlir E425 — 判定の版 9 — E036): 付随の行の族 trace_lsm・trace_tp・trace_perf・freplace・trace_struct_ops */
int ck_check_v11(struct ck *c, const struct bml_attach *a);
int ck_lsm_args(struct ck *c, const struct bml_attach *a); /* checkLSMArgs (trace_lsm と trace_lsm_cgroup) */
int ck_fentry_args(struct ck *c, const struct bml_attach *a); /* checkFentryArgs (判定の版 15 — check_v15.c) */
/* validIntSpelling (i8…u64) */
int ck_int_spelling(const char *s);
void ck_asked_free(struct ck *c);

#endif
