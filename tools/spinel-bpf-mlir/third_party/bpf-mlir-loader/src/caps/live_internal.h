/* caps/live_internal.h — live の caps の probe の共通 (live_sys.c・live_feat.c) — E004。
 *
 * cilium の誤りの鎖を (errno, VerifierError か, ErrNotSupported か) の 3 つで持つ: 答えの規則 (prog_type の「鎖に EINVAL・E2BIG」、kload の
 * have の「Is(ErrNotSupported)」、helper の「VerifierError ∧ EINVAL」) はこの 3 つだけを見る。 */
#ifndef BML_CAPS_LIVE_INTERNAL_H
#define BML_CAPS_LIVE_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "caps/live.h"

/* bpf(2) (cilium の sys.BPF — PROG_LOAD の EAGAIN の再試行・fd 0 の dup)。成功は fd か 0、失敗は -errno */
int lv_bpf(int cmd, void *attr, unsigned size);
void lv_close(int fd);
int lv_close_checked(int fd); /* E066: 0 か -errno (閉じる失敗を答えに反映する probe のため) */

enum { LV_LOG_DISABLED, LV_LOG_0, LV_LOG_1 };
enum { LV_NO_KIND = 0 };

/* 1 つの program の load (cilium の NewProgramWithOptions の手順 — probes.md §1.3) */
struct lv_prog {
	uint32_t type, attach_type, flags;
	const uint8_t *insns; /* 8 byte ずつ (cilium の Marshal の出力 — 書き換えの前) */
	size_t n_insns;
	const char *license, *name;
	int log_mode;
	const uint8_t *btf; /* program の BTF (KernelMarshalOptions の flag が全て偽の形 — StripFuncLinkage は load が当てる) */
	size_t btf_len;
	const uint8_t *func_info; /* 8 byte ずつ */
	uint32_t func_info_cnt;
	const char *attach_to; /* vmlinux で引く型の名前 (NULL は解決しない) */
	uint32_t attach_kind;
	uint32_t attach_btf_id, attach_prog_fd; /* Extension の直の値 */
	int bpf2bpf; /* bpf-to-bpf の call を持つ (haveBPFToBPFCalls の分岐) */
};

/* 誤りの鎖 */
struct lv_res {
	int fd;       /* 成功は >= 0 (呼び手が閉じる)、失敗は -1 */
	int err;      /* 鎖の errno (0 は errno の無い誤り — 置き換えた cause・vDSO の誤り等) */
	int verifier; /* VerifierError か */
	int notsup;   /* Is(ErrNotSupported) か */
	char **lines; /* ErrorWithLog の行 (右端を削った — VerifierError のとき) */
	size_t n_lines;
	/* E031 (bpf-mlir E388 の probe の文): cilium の "load program: %w<suffix>" の suffix (無ければ NULL — 静的な文字列)、
	 * err が 0 に置き換わった cause (1 は errBadRelocation "bad CO-RE relocation"、2 は errUnknownKfunc "unknown kfunc") */
	const char *suffix;
	int cause;
	char *text; /* E048: load の前の誤りの文 (cilium の attach 先の解決・kload の生の load — 在れば lv_res_text が返す、malloc) */
};
/* cilium の NewProgram の誤りの文 (err.Error() — "load program: …"、VerifierError は Error() の写し)。malloc */
char *lv_res_text(const struct lv_res *r);
void lv_res_free(struct lv_res *r);
int lv_prog_load(struct bml_live *l, const struct lv_prog *p, struct lv_res *r);

/* NewHandleFromRawBTF (log の再試行と haveBTF の再検査 — probes_3.md §1.7)。成功は fd、失敗は -1 と r (VerifierError でない) */
int lv_btf_handle(struct bml_live *l, const uint8_t *btf, size_t len, struct lv_res *r);
int lv_btf_handle_reason(struct bml_live *l, const uint8_t *btf, size_t len, struct lv_res *r);

/* cilium の内部の FeatureTest: LV_OK・LV_NOTSUP、または覚えない誤りの -errno (errno の無い誤りは -1) */
int lv_feat(struct bml_live *l, int which);
/* KernelMarshalOptions (4 つを順に評価 — flag は「!= nil」) */
struct lv_kmo {
	int strip_func_linkage, replace_decl_tags, replace_type_tags, replace_enum64;
};
void lv_kmo(struct bml_live *l, struct lv_kmo *o);
/* raw の BTF の FUNC を全て static に (StripFuncLinkage — malloc の写し) */
uint8_t *lv_strip_func_linkage(const uint8_t *btf, size_t len);
/* linux.KernelVersion (vDSO の Linux の note)。0 と *v、失敗は -1 */
int lv_kernel_version(struct bml_live *l, uint32_t *v);
/* maybeFillObjName (haveObjName・objNameAllowsDot を起こす) — dst は 16 byte */
void lv_obj_name(struct bml_live *l, const char *name, char dst[16]);
/* vmlinux (kload の Once) と cilium の LoadKernelSpec の失敗の区別: 0 は読めた、-2 は cilium も「無い」、-1 は cilium の load の誤り、
 * -3 は C の型の検めだけの誤り (cilium は遅延) */
int lv_vmlinux(struct bml_live *l, const struct bml_kbtf **kb);

/* ErrorWithLog の行 (buffer を NUL で切る → 両端の空白を削る → '\n' で分ける → 各行の右端を削る) */
void lv_log_lines(const char *buf, size_t size, char ***lines, size_t *n);

/* kload の memo */
struct lv_memo *lv_memo_get(struct bml_live *l, const char *key);
int lv_memo_put(struct bml_live *l, const char *key, int rc, int value);
int lv_unknownf(char **msg,const char *fmt,...);
void lv_btf_reason(struct lv_res *r,int load_error,const char *log,size_t size);
int lv_memo_answer(const struct lv_memo *m,int *out,char **msg);
int lv_memo_reason(struct bml_live *l,const char *key,int rc,int value,char *why,int *out,char **msg);
void lv_caps_kernel_values(struct bml_caps *out);

/* live_btf.c の共有 (live_btf_func.c — E009 で分けた): vmlinux の BTF (無ければ NULL と *err)、prefix + err の文、食い違いの文を足す (b を空に、
 * oom は -1)、oom の答え、整数の綴り (i32 / u64 …)、名前の型 (oom は -1、1 は ErrNotFound、2 は複数) */
struct bml_buf;
const struct bml_kbtf *lv_kb(struct bml_live *l, const char **err);
int lv_msg(char **msg, int rc, const char *prefix, const char *err);
int lv_push(struct bml_strs *out, struct bml_buf *b);
int lv_oom(struct bml_strs *out, char **msg);
void lv_int_spell(const struct bml_kbtf *kb, const struct kbtf_type *t, char *dst, size_t n);
/* requirements.ArgName (bpf-mlir E432): 空の名前は `unnamed` (live_btf_func.c) */
const char *bml_arg_name(const char *n);
/* kload の compareProto (bpf-mlir E425): FUNC_PROTO fp と (nargs — < 0 は見ない・ret — "" は見ない・args — struct の名前か整数の綴りか -) の
 * 食い違いの文を out に足す (live_btf_func.c)。oom は -1 */
int lv_compare_proto(const struct bml_kbtf *kb, const struct kbtf_type *fp, const char *what, int64_t nargs, const char *ret,
		     const struct bml_str *args, size_t n_args, struct bml_strs *out);
/* HasAttachTarget の種類 tp (bpf-mlir E419): tracefs の events/<cat>/<name>/id の在否 — 無い・読めないは Unknown (live_v11.c) */
int lv_tracefs_event_id(const char *event, int *out, char **msg);
/* bpf-mlir E440 (E037): sk_skb / sk_msg の attach type の sockmap の link の probe (live_sockmap.c)。load が受理されなければ -2 (呼び手が今の対の
 * load で判定)、他は BML_Q_* と *val・*why (Unknown の文 — malloc) */
int lv_sockmap_link_probe(struct bml_live *l, const char *pt_name, uint32_t pt, const char *at_name, uint32_t at, int *val, char **why);
/* bpf-mlir E479 (E041 — live_multi.c): kprobe の multi / session の link の probe。-2 は load の拒否 (呼び手の対の load)、他は BML_Q_OK / BML_Q_UNKNOWN */
int lv_multi_link_probe(struct bml_live *l, const char *pt_name, const char *at_name, uint32_t at, int *val, char **why);
/* path の全体を読む (malloc — *data は NUL 終端)。失敗は -1 と *e (errno) (live_v11.c) */
int lv_read_file(const char *path, char **data, size_t *len, int *e);
int lv_lookup(const struct bml_kbtf *kb, const char *name, uint32_t kind, uint32_t *id, char **err);
/* live_kpath.c (bpf-mlir E553 — E054): findMember を経路 a.b(.c) の段ごとに (1 は見つけた・0 は無い・-1 は oom)、型 struct:T の照らし
 * (0 は合う・1 は食い違いの文を b に) */
struct kbtf_member;
int lv_find_member_path(const struct bml_kbtf *kb, uint32_t struct_id, const char *path, struct kbtf_member *out, int *twice);
int lv_kfield_embedded(const struct bml_kbtf *kb, const struct kbtf_member *mb, const char *name, struct bml_buf *b);
/* bpf-mlir E546〜E548 (E053 — live_str.c): tpfield / sysarg の strptr・strarray の char pointer の深度。各 1 は既知 (*depth — 非 char は 0 か -1)、
 * 0 は不明 (Unknown)。lv_tp_field_name は tpFieldName の正規表現の名前の範囲 [*s, *e) (無ければ 0) */
int lv_tp_field_name(const char *d, size_t n, size_t *s, size_t *e);
int lv_tp_char_depth(const char *decl, size_t n, int *depth);
/* tpByteArrayShape (bpf-mlir E552 — E054): 1 は既知 (*count は配列の個数か 0、*sign は 'u'・'i'・0)、0 は不明 */
int lv_tp_array_shape(const char *decl, size_t n, int64_t *count, char *sign);
int lv_sys_char_depth(const struct bml_kbtf *kb, const char *typ, int *depth);
int lv_sys_btf_char_depth(const struct bml_kbtf *kb, uint32_t id, int *depth);
int lv_str_depth_ok(int depth, const char *typ);
int lv_is_str(const char *typ);
/* compareSysarg の引数 n の値: 深度が合えば typ、違えば not-<typ> (malloc) */
char *lv_str_arg(int depth, const char *typ);
/* CONTRACT: tracefsRoots (shared by tracepoint id, format and syscall format). The product does not change it; only the classification differential tool replaces it
 * with a constructed tracefs directory (the Go oracle points its copy at the same directory) */
extern const char *lv_tracefs_roots[2];
/* tracefs の format の text の CheckTracepointField (読んだ後 — live_v11.c — 分類の差動も呼ぶ)。BML_Q_* */
int lv_tp_field_text(const char *text, size_t len, const char *event, const char *field, int64_t off, int64_t bytes, const char *sign,
		     struct bml_strs *out, char **msg);

#endif
