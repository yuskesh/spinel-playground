/* load/load.h — libbpf v1.7.0 で ELF を load し、libbpf の黙った振る舞いを load の前後の guard で止める (E005 — R001 Q2)。
 *
 * 固定の option: RLIMIT_MEMLOCK を触らせない (libbpf_set_memlock_rlim(0) — process で 1 回)、BPF token を作らせない
 * (bpf_token_path = "")、libbpf の print は load の間だけ library の log に集める (前の callback に戻す — process の状態を残さない)、
 * kernel の log は自前の buffer、CO-RE の target は /sys/kernel/btf/vmlinux (照合の vmlinux と同じ)、自動の attach・skeleton・pin を
 * 使わない。
 *
 * 照合 (bml_check) の後に呼ぶ — ここは照合をしない。load の前の guard: ELF の形・libbpf の feat_supported と照合の btf_feature の
 * 答えの照らし合わせ・libbpf が BTF を sanitize する / program と map の属性を書き換える feature の欠け。load の後の guard: BTF が
 * kernel に載った・kernel の BTF と object の BTF が byte で同じ・func_info / line_info の数・map の BTF の id と flags。 */
#ifndef BML_LOAD_H
#define BML_LOAD_H

#include <stddef.h>
#include <stdint.h>

#include "caps/caps.h"
#include "req/req.h"

struct bpf_object;

enum bml_load_stage {
	BML_LOAD_OK = 0,
	BML_LOAD_ENV,         /* process の前提 (libbpf が既に memlock を上げた等) */
	BML_LOAD_SHAPE,       /* ELF の形 (section・relocation・symbol・.maps の定義) */
	BML_LOAD_PREDICT,     /* libbpf の feat_supported と照合の btf_feature の答えの食い違い (Unknown — 予測を信じられない) */
	BML_LOAD_SANITIZE,    /* libbpf が BTF を sanitize する feature の欠け (B1 — 4 機能の外を含む) */
	BML_LOAD_REWRITE,     /* libbpf が program / map を書き換える feature の欠け (P1 helper の置き換え・P2〜P5) */
	BML_LOAD_OPEN,        /* libbpf の open の失敗 */
	BML_LOAD_LIBBPF,      /* libbpf の load の失敗 (verifier の拒否を含む — log を持つ) */
	BML_LOAD_BTF_DROPPED, /* B2 / B3: BTF が kernel に載っていない */
	BML_LOAD_BTF_CHANGED, /* B1: kernel の BTF と object の BTF が違う */
	BML_LOAD_EXT_INFO,    /* B4: func_info / line_info の数・program の BTF の id */
	BML_LOAD_MAP_BTF,     /* M1 / M2: map の BTF の key / value の id が ELF と違う */
	BML_LOAD_MAP_FLAGS,   /* P3: map の flags が ELF (open の時の libbpf の定義) と違う */
	BML_LOAD_ARENA,
};

const char *bml_load_stage_name(int stage);

/* E034: program の section の kind と test run の族 (guard の ELF の形の表 — pre.c の sec_defs から 1 か所で)。知らない section は NULL と BML_RUN_NONE */
enum { BML_RUN_NONE = 0, BML_RUN_XDP, BML_RUN_TRACING, BML_RUN_SKB, BML_RUN_FLOW, BML_RUN_CTX, BML_RUN_NF };
const char *bml_load_section_kind(const char *section, int *family);

struct bml_load_result {
	int stage;
	char *msg; /* 名指しの文 (malloc) */
	char *log;    /* libbpf の print (verifier の log を含む — malloc、無ければ NULL) */
	int verifier; /* BML_LOAD_LIBBPF: program の load を kernel (verifier) が拒否した */
};
void bml_load_result_free(struct bml_load_result *r);

struct bml_obj; /* load した object (libbpf の bpf_object — attach の前) */

/* elf (len byte) を load する。req は照合した requirements、caps は照合の caps (btf_feature の答えを照らし合わせに使う)。
 * 成功は 0 と *out、失敗は -1 と r (load した物は全て閉じてある) */
int bml_load_guarded(const uint8_t *elf, size_t len, const struct bml_requirements *req, const struct bml_caps *caps,
		     struct bml_obj **out, struct bml_load_result *r);

/* .rodata の設定値 1 つ (E006 の後半 — 宣言の照合の済んだ global の symbol の offset と大きさ、little endian で書く bits) */
struct bml_rodata_value {
	uint64_t off;
	uint32_t size;
	uint64_t bits;
};
/* 同じ、open と load の間に .rodata の map の初期値へ values を書く (範囲の外は BML_LOAD_ENV の誤り — 照合の後なので起きない見込み) */
int bml_load_guarded_values(const uint8_t *elf, size_t len, const struct bml_requirements *req, const struct bml_caps *caps,
			    const struct bml_rodata_value *values, size_t n_values, struct bml_obj **out, struct bml_load_result *r);
void bml_obj_close(struct bml_obj *o);
/* CONTRACT: libbpf object (map and program access and attach, used by the ABI). Only bml_obj_close closes it */
struct bpf_object *bml_obj_bpf(const struct bml_obj *o);
#ifdef BML_TEST_CAPS
/* E044 の試験の口: usdt の program の libbpf の UPROBE_MULTI の書き換えを残す (1) か外す (0 — 製品) */
void bml_load_testonly_usdt_multi(int keep);
#endif

#endif
