/* CONTRACT: C form of the `.ebpf_requirements` section (requirements_format.md sections 1 to 4).
 *
 * Types and Parse follow the Go requirements package line by line.
 * All strings are malloc'd and NUL-terminated (with a length too, since fields may hold NUL and are compared as byte sequences as in Go). */
#ifndef BML_REQ_H
#define BML_REQ_H

#include <stddef.h>
#include <stdint.h>

#include "req/mapfield.h"

#define BML_REQ_SECTION ".ebpf_requirements"
#define BML_MAX_FORMAT_VERSION 32 /* E060: enum farg 19、enumval 20、fibflags 21、enum kfield 22、datakptr 23、extern/guard 24、ptr:void 25、coreenum 26、funcret 27、kstructsize 28、arena 29。E066: netkit 30、helper_target 31、sleepable 32。 */

struct bml_str {
	char *p; /* NUL 終端 (中に NUL が在りうる — len が正) */
	size_t len;
};

#include "req/kernel_rows.h"

struct bml_helper {
	struct bml_str name;
	int64_t id;
};

struct bml_program {
	struct bml_str symbol, prog_type;
	int64_t prog_type_id;
	struct bml_helper *helpers;
	size_t n_helpers, cap_helpers;
};

struct bml_map {
	struct bml_str symbol, map_type;
	int64_t id;
	struct bml_str key, value; /* 版 1 では空 */
	uint64_t max_entries, flags;
};

struct bml_kfield {
	struct bml_str program, strct, field, type;
	struct bml_guard_list guards;
};

struct bml_ctxfield {
	struct bml_str strct, field;
	int64_t offset, size;
};

struct bml_intarg {
	int64_t n;
	struct bml_str type;
};

struct bml_attach {
	struct bml_str program, attach_type, target;
	struct bml_str *args;
	size_t n_args, cap_args;
	struct bml_str *fargs; /* farg の行 (trace_fentry — 形式 8、E319): 引数 i の struct の名前か - */
	size_t n_fargs, cap_fargs;
	int64_t ret_nargs; /* < 0 は retsig の行が無い */
	struct bml_str ret_type;
	struct bml_str func_ret;
	struct bml_str arch;
	struct bml_ctxfield *ctxfields;
	size_t n_ctxfields, cap_ctxfields;
	struct bml_intarg *kprobe_args;
	size_t n_kprobe_args, cap_kprobe_args;
	struct bml_str binary_sha256;
	struct bml_intarg *uprobe_args;
	size_t n_uprobe_args, cap_uprobe_args;
	/* bpf-mlir E388 (版 9 — E031): 汎用の attach の行 (付随の行を持たない)。tkind は target の種類、tval は値 (無ければ空) */
	int generic;
	struct bml_str tkind, tval;
	/* bpf-mlir E425 (版 11 — E036): trace_tp の tpfield (offset の狭義の昇順)、freplace の extret (ext_nargs < 0 は無し) と extarg、
	 * trace_struct_ops の structop (retsig と farg は ret_nargs・ret_type・fargs を使う) */
	struct bml_tpfield *tpfields;
	size_t n_tpfields, cap_tpfields;
	int64_t ext_nargs;
	struct bml_str ext_ret;
	struct bml_str *ext_args;
	size_t n_ext_args, cap_ext_args;
	struct bml_str sop_struct, sop_member;
	/* bpf-mlir E456 (版 12 — E039): multi の族の関数の数 (attach の行の target) と mtarget、usdt の usdtsem (空・required・none) と usdtarg */
	int64_t multi_n;
	struct bml_str *mtargets;
	size_t n_mtargets, cap_mtargets;
	struct bml_str usdt_sem;
	struct bml_intarg *usdt_args;
	size_t n_usdt_args, cap_usdt_args;
	/* bpf-mlir E480 (版 13 — E041): ksyscall の sysarg (n の狭義の昇順)、multi の族の mtargetarg ((i, n) の辞書順) */
	struct bml_intarg *sys_args;
	size_t n_sys_args, cap_sys_args;
	struct bml_mtargetarg *mtarget_args;
	size_t n_mtarget_args, cap_mtarget_args;
	struct bml_str tpbuf_type; /* bpf-mlir E499 (版 14 — E042): tpbuf の行の型 (i32、無ければ空) */
	int sleepable; /* bpf-mlir E660 (版 32 — E066): sleepable の行 (trace_fentry の attach の直後、section fentry.s/<fn>) */
};

/* `helper_target <program> d_path 147 trace_fentry <target> 0 path` (bpf-mlir E654 — E066) */
struct bml_helper_target {
	struct bml_str program, helper, attach_type, target, arg_type;
	int64_t helper_id, arg_index;
};

/* bpf-mlir E499 (E042): 1 つの program の初期の profile (reason が NULL でなければ導けない — Go の ErrUnknown の後の文)。文字列は malloc */
struct bml_kfunc_profile_entry {
	char *program, *reason;
	const char *kind, *prog_type, *attach_type, *target_kind; /* 静的な表の文字列 */
	char *section, *target, *context_identity;
	int64_t prog_type_id;
	uint32_t prog_flags;
};

/* `mtargetarg <program> <i> <n> <type>` (E480 — E041) */
struct bml_mtargetarg {
	int64_t i, n;
	struct bml_str type;
};

/* `kfunc <program> <name> <ret> <arg>…` (E480 — E041 — 引数は 0..5) */
struct bml_kfunc {
	struct bml_str program, name, ret;
	struct bml_str *args;
	size_t n_args;
};

/* `innermap <outer> <map type> <id> <key> <value> <max_entries> <flags>` (E456 — E039): array_of_maps / hash_of_maps の雛形 */
struct bml_innermap {
	struct bml_str outer, map_type, key, value;
	int64_t id;
	uint64_t max_entries, flags;
};

/* `tpfield <program> <field> <offset> <byte 数> <i|u>` (E425 — E036) */
struct bml_tpfield {
	struct bml_str field, sign;
	int64_t offset, bytes;
};

/* bpf-mlir E388 (版 9 — E031): `ctxaccess <program> <attach type|-> <struct> <field> <r|w> <byte 数>` */
struct bml_ctxaccess {
	struct bml_str program, attach_type, strct, field, mode;
	int64_t bytes;
};

struct bml_argtag {
	struct bml_str program, tag, cls;
};

struct bml_tailslot {
	struct bml_str map;
	uint32_t slot;
	struct bml_str program;
};

struct bml_requirements {
	int version;
	struct bml_str schema_sha256;
	struct bml_program *programs;
	size_t n_programs, cap_programs;
	struct bml_helper_target *helper_targets; /* 版 31 (E066) */
	size_t n_helper_targets, cap_helper_targets;
	struct bml_map *maps;
	size_t n_maps, cap_maps;
	struct bml_kfield *kfields;
	size_t n_kfields, cap_kfields;
	struct bml_attach *attaches;
	size_t n_attaches, cap_attaches;
	struct bml_str *btf_features;
	size_t n_btf_features, cap_btf_features;
	struct bml_argtag *argtags;
	size_t n_argtags, cap_argtags;
	struct bml_tailslot *tailslots;
	size_t n_tailslots, cap_tailslots;
	struct bml_ctxaccess *ctxaccesses; /* v9 (E388) */
	size_t n_ctxaccesses, cap_ctxaccesses;
	struct bml_innermap *innermaps; /* v12 (E456 — E039) */
	size_t n_innermaps, cap_innermaps;
	struct bml_kfunc *kfuncs; /* v13 (E480 — E041、文書の順) */
	size_t n_kfuncs, cap_kfuncs;
	/* bpf-mlir E499 (E042): kfunc の行を持つ program ごとの初期の profile (FromELF だけが導く — Parse だけなら 0 個 — kfunc_profile.c) */
	struct bml_kfunc_profile_entry *kfunc_profiles;
	size_t n_kfunc_profiles;
	/* §7 — FromELF が導く (Parse だけなら導出していない) */
	struct bml_map_fields map_fields;
	struct bml_str *arenas, *data_kptrs;
	size_t n_arenas, cap_arenas, n_data_kptrs, cap_data_kptrs;
	struct bml_fib_flag *fib_flags;
	size_t n_fib_flags, cap_fib_flags;
	struct bml_enum_value *enum_values, *core_enums;
	size_t n_enum_values, cap_enum_values, n_core_enums, cap_core_enums;
	struct bml_struct_size *struct_sizes;
	size_t n_struct_sizes, cap_struct_sizes;
	struct bml_ksym_var *ksym_vars;
	size_t n_ksym_vars, cap_ksym_vars;
	struct bml_kconfig *kconfigs;
	size_t n_kconfigs, cap_kconfigs;
	struct bml_guard *guards;
	size_t n_guards, cap_guards;
	struct bml_guarded_row *guarded_rows;
	size_t n_guarded_rows, cap_guarded_rows;
};

/* Parse の誤り (Go の requirements.ParseError)。rule が空の誤りは型の無い誤り (Go の sc.Err() — 64 KiB を超える行、
 * または memory の不足) — corpus の want の形には写らない。 */
struct bml_parse_error {
	int line;       /* 1 始まり、header は 1、文書の終わりの検査は 0 */
	const char *row;  /* 行の種類 (静的な文字列)、header・知らない種類・文書の規則は "" */
	const char *rule; /* header / fields / min_version / order / value / unknown_kind / document、型の無い誤りは "" */
	char *msg;        /* Go の Error() と同じ文 (malloc) */
};

/* CONTRACT: Go's Parse. Success is 0 with *out (free with bml_requirements_free). Failure is -1 with *err (bml_parse_error_free).
 * A line over 64 KiB stops the scan as in Go: if the document checks pass, *out is returned and the result is -1 (rule ""); the caller frees both. */
int bml_req_parse(const char *data, size_t len, struct bml_requirements **out, struct bml_parse_error *err);
void bml_requirements_free(struct bml_requirements *r);
void bml_parse_error_free(struct bml_parse_error *e);

/* 行の種類の表 (spec.go の RowKinds) と attach の型 (AttachTypes)、btf の機能 (BTFFeatureBlob の知る 11) */
struct bml_row_kind {
	const char *name;
	int fields, min_version;
};
extern const struct bml_row_kind bml_row_kinds[];
extern const size_t bml_n_row_kinds;
int bml_known_btf_feature(const char *s, size_t n);

#endif
