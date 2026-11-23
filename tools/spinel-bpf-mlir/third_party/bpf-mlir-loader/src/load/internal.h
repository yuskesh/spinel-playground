/* load/internal.h — load の guard の内部 (load.c・pre.c・post.c — E005) */
#ifndef BML_LOAD_INTERNAL_H
#define BML_LOAD_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "load/load.h"
#include "util/gostr.h"

struct bpf_object;
struct lb_arena;

struct bml_obj {
	struct bpf_object *obj;
	struct lb_arena *arena;
	int print_held; /* libbpf の print の holder として数えた (E026 — close で数を下げる) */
};

/* libbpf v1.7.0 の src/libbpf_internal.h の enum kern_feature_id の値 (公開の API でない — 版は gate が source の hash で固定する —
 * scripts/libbpf-pin.sh) と feat_supported (libbpf.a の features.o の GLOBAL の symbol — token を使わなければ load の
 * kernel_supports(obj, f) と同じ process の cache を読む: 前に読んだ値 = load が使う値 — R001 Q2 §2.5) */
enum {
	LBF_PROG_NAME = 0, LBF_GLOBAL_DATA = 1, LBF_BTF = 2, LBF_BTF_FUNC = 3, LBF_BTF_DATASEC = 4, LBF_BTF_GLOBAL_FUNC = 5,
	LBF_ARRAY_MMAP = 6, LBF_EXP_ATTACH_TYPE = 7, LBF_PROBE_READ_KERN = 8, LBF_BTF_FLOAT = 11, LBF_BTF_DECL_TAG = 13,
	LBF_BTF_TYPE_TAG = 14, LBF_BTF_ENUM64 = 17, LBF_BTF_QMARK_DATASEC = 21,
};
bool feat_supported(void *cache, int feat_id);
const char *lb_feat_name(int feat_id);
/* CONTRACT: errno text (Go's syscall.Errno spelling; downstream tests match it. Per-thread buffer) */
const char *lb_errno(int e);

/* 誤りを r に (stage と文 — malloc)。-1 を返す */
int lb_fail(struct bml_load_result *r, int stage, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

/* load の前の guard (pre.c) */
int lb_check_shape(const uint8_t *elf, size_t len, struct bml_load_result *r);
struct bpf_object;
int lb_mark_sleepable(struct bpf_object *obj, struct bml_load_result *r); /* E067 追補 2: open の後・load の前 */
int lb_check_features(const uint8_t *elf, size_t len, const struct bml_requirements *req, const struct bml_caps *caps,
		      struct bml_load_result *r);
/* libbpf の sanitize が ELF の BTF を書き換えるか: 欠けた feature (LBF_*)・書き換え無し -1・読めない -2 */
int lb_btf_rewrite(const uint8_t *elf, size_t len);
/* E019 (secdefs.c): libbpf の section_defs で sec が最初に当たる定義に SEC_EXP_ATTACH_OPT が在るか (FEAT_EXP_ATTACH_TYPE の欠けで libbpf が
 * expected_attach_type を 0 にする program か) と、試験の表の印字 (gate が libbpf の source から抜いた表と比べる) */
int lb_sec_exp_attach_opt(const char *sec);
void lb_secdefs_print(void);

/* open の後・load の前に libbpf の map の定義 (ELF から読んだ BTF の id と flags) を控える (post.c) */
struct lb_map_def {
	char *name;
	uint32_t key_id, value_id, flags;
};
int lb_capture_maps(struct bpf_object *obj, struct lb_map_def **defs, size_t *n);
void lb_free_maps(struct lb_map_def *defs, size_t n);
/* load の後の guard (post.c) */
int lb_check_loaded(struct bpf_object *obj, const struct lb_map_def *defs, size_t n, struct bml_load_result *r);

#endif
