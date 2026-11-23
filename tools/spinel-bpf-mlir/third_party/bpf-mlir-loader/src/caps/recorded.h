/* recorded.h — 記録した caps (caps.json — bpf-mlir docs/requirements_format.md §10、go/requirements/recorded.go の写し、ebpf-caps 3 (2 も読む) — E002・E009) */
#ifndef BML_RECORDED_H
#define BML_RECORDED_H

#include "caps/caps.h"
#include "json/json.h"

#define BML_RECORDED_FORMAT "ebpf-caps 20" /* E066: sleepable_types。2〜19も読む。 */
#define BML_RECORDED_FORMAT_V19 "ebpf-caps 19" /* helper_target */
#define BML_RECORDED_FORMAT_V18 "ebpf-caps 18" /* netkit */
#define BML_RECORDED_FORMAT_V17 "ebpf-caps 17" /* E060: arena の loader 宣言 */
#define BML_RECORDED_FORMAT_V16 "ebpf-caps 16"
#define BML_RECORDED_FORMAT_V15 "ebpf-caps 15"
#define BML_RECORDED_FORMAT_V14 "ebpf-caps 14"
#define BML_RECORDED_FORMAT_V13 "ebpf-caps 13"
#define BML_RECORDED_FORMAT_V12 "ebpf-caps 12"
#define BML_RECORDED_FORMAT_V11 "ebpf-caps 11"
#define BML_RECORDED_FORMAT_V10 "ebpf-caps 10"
#define BML_RECORDED_FORMAT_V9 "ebpf-caps 9" /* まだ読む (bpf-mlir E499 (E042): 問い kfunc_loads (権限に依る)・tracepoint_buffer) */
#define BML_RECORDED_FORMAT_V8 "ebpf-caps 8" /* まだ読む (bpf-mlir E480 (E041): loader の 4 つの鍵と問い kfunc_protos・syscall_args) */
#define BML_RECORDED_FORMAT_V7 "ebpf-caps 7" /* まだ読む (bpf-mlir E480 (E041): E480 の loader の 4 つの鍵と kfunc_protos・syscall_args を持たない) */
#define BML_RECORDED_FORMAT_V6 "ebpf-caps 6" /* まだ読む (usdt_attach を持たない — bpf-mlir E438 (E037): 権限に依る問いを privileged_queries に) */
#define BML_RECORDED_FORMAT_V5 "ebpf-caps 5" /* まだ読む (全ての問いを queries に — E425 (E036) の tracepoint_fields 等は持つ) */
#define BML_RECORDED_FORMAT_V4 "ebpf-caps 4" /* まだ読む (E425 の 3 つの問い合わせを持たない形式 — E388 (E031) の attach_types 等は持つ) */
#define BML_RECORDED_FORMAT_V3 "ebpf-caps 3" /* まだ読む (E388 の 3 つの問い合わせを持たない形式) */
#define BML_RECORDED_FORMAT_V2 "ebpf-caps 2" /* v0.17.0 E319: まだ読む (func_args を持たない形式) */

struct bml_recorded;

/* caps.json の byte を読む (dir は uprobe の binary の相対の path の基 — NULL は作業の dir)。失敗は NULL と *err */
struct bml_recorded *bml_recorded_parse(const char *data, size_t len, const char *dir, char **err);
/* 同じ、誤りの §13 の規則付き (JSON の誤りでない誤り — 形式・loader の欠け等 — は BML_JR_NONE) */
struct bml_recorded *bml_recorded_parse_rule(const char *data, size_t len, const char *dir, char **err, enum bml_json_rule *rule);
/* --loader-file の宣言 (Go の DecodeStrictJSON(LoaderJSON) — name の空の検査は呼び手)。失敗は -1 と *err・*rule */
int bml_loader_decl_parse(const char *data, size_t len, struct bml_loader_decl *d, char **err, enum bml_json_rule *rule);
/* path の file を読む (dir は path の directory) */
struct bml_recorded *bml_recorded_read(const char *path, char **err);
void bml_recorded_free(struct bml_recorded *r);
/* 照合に渡す caps (r が生きている間有効) */
void bml_recorded_caps(struct bml_recorded *r, struct bml_caps *out);
/* bpf-mlir E425 の記録の鍵 (malloc — oom は NULL): TPFieldKey `<cat>/<event>/<field>/<offset>/<bytes>/<i|u>`、
 * StructOpsKey (a.b — ret は呼び手が "" を - に) と ExtTargetKey (a/b) の `<a><sep><b>/<nargs>/<ret>(<args,>)` */
char *bml_caps_tpfield_key(const char *event, const char *field, int64_t off, int64_t bytes, const char *sign);
char *bml_caps_kfunc_key(const char *name, const char *ret, const struct bml_str *args, size_t n); /* bpf-mlir E480 (E041) */
char *bml_caps_proto_key(const char *a, char sep, const char *b, int64_t nargs, const char *ret, const struct bml_str *args, size_t n);
/* bpf-mlir E438 (E037): 問いの答えが probe の権限に依るか (PrivilegeDependentQueries — 11) */
int bml_caps_privilege_dependent(const char *q);
/* SamePrivilege: CapEff (16 進の 64 bit — 前後の空白は無視) が同じ。空・読めないは違う */
int bml_caps_same_privilege(const char *cap_a, const char *cap_b);
/* CONTRACT: RecordedCaps.ForLoad: uses r with the load privileges (uid and CapEff); when they differ from the recorded probed_as, privilege-dependent queries are reprobed (NULL means Unknown).
 * Modifies r (Go returns a copy; bml uses one record for one check). reprobe must stay alive while r is used. Out of memory is -1 */
int bml_recorded_for_load(struct bml_recorded *r, long long load_uid, const char *load_cap, const struct bml_caps *reprobe);
/* "<uid>:<cap_eff>" (--load-as) を読む (Go の ParseLoadAs)。失敗は -1 と *err (Go の文 — malloc)、*cap は malloc */
int bml_caps_parse_load_as(const char *s, long long *uid, char **cap, char **err);
/* 記録の probed_as (無ければ 0)。*cap は malloc */
int bml_recorded_probed_as(const struct bml_recorded *r, long long *uid, char **cap);

#endif
