/* btf/kernel.h — target の kernel の BTF (vmlinux) の読みと名前引き (E004 — cilium/ebpf v0.22 の btf.LoadKernelSpec・Spec.TypeByName・
 * UnderlyingType・Sizeof・型の書式 (%s / %v / %T) の写し)。
 *
 * live の caps の問い合わせ (func・func_sig・tracepoint・kfields・struct_field・func_param) の食い違いの文は Go の書式を byte で写す
 * (記録の diffs が判定の Unmet の文になる)。cilium は型を名前引きの時に遅延で inflate し、壊れた型は引いた時にだけ誤りになるが、
 * C は load の時に全ての型を検める (壊れた vmlinux の BTF では C は全ての問い合わせで誤り — Go より厳しい向き、E004 の Honest boundary)。 */
#ifndef BML_BTF_KERNEL_H
#define BML_BTF_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#include "util/gostr.h"

enum {
	KBTF_UNKN = 0, KBTF_INT, KBTF_PTR, KBTF_ARRAY, KBTF_STRUCT, KBTF_UNION, KBTF_ENUM, KBTF_FWD, KBTF_TYPEDEF, KBTF_VOLATILE,
	KBTF_CONST, KBTF_RESTRICT, KBTF_FUNC, KBTF_FUNC_PROTO, KBTF_VAR, KBTF_DATASEC, KBTF_FLOAT, KBTF_DECL_TAG, KBTF_TYPE_TAG,
	KBTF_ENUM64, KBTF_NKINDS
};

struct bml_kbtf {
	uint8_t *raw; /* 読んだ BTF の全体 (malloc) */
	size_t raw_len;
	int be;
	const uint8_t *types; /* type の section */
	uint32_t types_len;
	const uint8_t *strs; /* 文字列の section */
	uint32_t strs_len;
	uint32_t n;    /* 型の数 + 1 (id 0 は Void) */
	uint32_t *off; /* id → types の中の offset (off[0] は使わない) */
	uint32_t *idx; /* 名前の索引: 名前を持つ id を (鍵 — 最後の "___" の前、id) の順に (cilium の namedTypes と同じ鍵) */
	uint32_t nidx;
};

/* 1 つの型の header (id 0 は kind 0 の Void) */
struct kbtf_type {
	uint32_t kind, vlen, kflag, size_type;
	const char *name; /* NUL 終端 (strs の中) */
	const uint8_t *aux;
};

/* CONTRACT: reads raw (a malloc'd buffer; ownership moves). Failure is *err (malloc) with -1 (errors cilium's loadRawSpec also stops on) or -3 (checked by cilium only
 * when a type is looked up: referenced ids, member names, decl tags). raw is released even on failure */
int bml_kbtf_from_raw(uint8_t *raw, size_t len, struct bml_kbtf *kb, char **err);
int bml_kbtf_from_split_raw(uint8_t *raw, size_t len, const struct bml_kbtf *base, struct bml_kbtf *out, char **err);
/* /sys/kernel/btf/vmlinux を読む (cilium の LoadKernelSpec の最初の場所)。開けないとき cilium は vmlinux の ELF の 7 つの場所を探すが、
 * C はそこを写さず誤り (fail closed — 3 kernel とも /sys/kernel/btf/vmlinux が在る)。-2 は 7 つの場所も全て無い (cilium の「no BTF found」— Tracing / LSM の
 * prog_type の probe は false に読む — probes_2.md §1.5)、-1 は他の誤り */
int bml_kbtf_load_kernel(struct bml_kbtf *kb, char **err);
void bml_kbtf_free(struct bml_kbtf *kb);

uint32_t bml_kbtf_u32(const struct bml_kbtf *kb, const uint8_t *p);
void bml_kbtf_type(const struct bml_kbtf *kb, uint32_t id, struct kbtf_type *t);

/* Struct / Union の member (cilium の convertMembers — kind_flag の bitfield と legacy の bitfield の付け替え) */
struct kbtf_member {
	const char *name;
	uint32_t type, offset, bitfield_size; /* offset と大きさは bit */
};
void bml_kbtf_member(const struct bml_kbtf *kb, const struct kbtf_type *t, uint32_t i, struct kbtf_member *m);
/* FuncProto の引数 */
void bml_kbtf_param(const struct bml_kbtf *kb, const struct kbtf_type *t, uint32_t i, const char **name, uint32_t *type);

/* Type.TypeName: 名前を持つ Go の型だけ (Pointer・Array・修飾・FuncProto・declTag・TypeTag は "") */
const char *bml_kbtf_type_name(const struct kbtf_type *t);
/* 名前の索引を作る (from_raw の中 — kernel_name.c) */
int bml_kbtf_build_index(struct bml_kbtf *kb, char **err);
#ifdef BML_TEST_CAPS
/* 試験の build だけ (E022): 前の索引 (比べごとに decode) — 新しい索引と byte で比べる */
int bml_kbtf_build_index_reference(struct bml_kbtf *kb, char **err);
#endif

/* cilium の Go の型の名前 (Enum と Enum64 は共に "Enum") */
const char *bml_kbtf_goname(uint32_t kind);

/* Spec.TypeByName(name, &<kind の Go の型>): 0 は見つかった (*id)、1 は見つからない、2 は複数 — 1 と 2 は *err に Go の誤りの文 (malloc) */
int bml_kbtf_by_name(const struct bml_kbtf *kb, const char *name, uint32_t kind, uint32_t *id, char **err);
/* Spec.AnyTypesByName(name): 名前の全体が name の型の id (cilium の順と飛ばしの癖 — *ids は malloc)。0・1 (not found)・2 (memory) は by_name と同じ */
int bml_kbtf_any_by_name(const struct bml_kbtf *kb, const char *name, uint32_t **ids, size_t *n, char **err);

/* UnderlyingType (qualifier と Typedef を外す — 深さ 32 を超えると cycle{root})。*cycle が立てば root は元の id */
uint32_t bml_kbtf_underlying(const struct bml_kbtf *kb, uint32_t id, int *cycle);
/* Sizeof: 0 と *size、誤りは -1 と *err (Go の文 — malloc) */
int bml_kbtf_sizeof(const struct bml_kbtf *kb, uint32_t id, int64_t *size, char **err);

/* 型の書式: verb 's' (名前まで) か 'v' (詳細 — 入れ子は名前まで)。cycle は UnderlyingType の cycle{root=id} */
void bml_kbtf_format(const struct bml_kbtf *kb, struct bml_buf *b, uint32_t id, int cycle, char verb);
/* %T (*btf.Int …、cycle は *btf.cycle) */
void bml_kbtf_gotype(const struct bml_kbtf *kb, struct bml_buf *b, uint32_t id, int cycle);

#endif
