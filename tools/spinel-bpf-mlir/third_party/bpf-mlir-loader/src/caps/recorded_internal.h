/* caps/recorded_internal.h — 記録した caps (caps.json) の内部 (caps/ の中だけ — E003 の前の構造の整理で recorded.c を分けた) */
#ifndef BML_CAPS_RECORDED_INTERNAL_H
#define BML_CAPS_RECORDED_INTERNAL_H

#include <stddef.h>

#include "caps/recorded.h"
#include "json/json.h"


struct answer {
	int has_value, value;
	char *unknown, *error, *text, *file; /* unknown・error・file は "" で未設定、text は NULL で未設定 */
	int has_diffs;
	struct bml_strs diffs;
};

struct entry {
	char *key;
	struct answer a;
};

struct query {
	char *name;
	struct entry *e;
	size_t n;
	int priv; /* bpf-mlir E438 (E037): privileged_queries から読んだ (読みの検めだけ — 後は queries と同じ表) */
};

/* bpf-mlir E438 (E037): ForLoad の load の権限 (recorded_priv.c) */
struct rc_scope {
	int set;           /* ForLoad の後 */
	int mismatch;      /* 記録の probed_as と load の権限が違う (probed_as が無いも) */
	long long load_uid;
	char *load_cap;
	const struct bml_caps *reprobe; /* 再 probe の caps (NULL は Unknown) */
};

struct bml_recorded {
	char *format;
	int has_probed; /* Go の *ProbedAs が nil でない ({} も在る) */
	long long probed_uid;
	char *probed_cap;
	struct bml_loader_decl loader;
	struct query *q;
	size_t n_q;
	char *dir;
	struct rc_scope scope;
};

/* 権限に依る問いの扱い (Go の privileged): 0 は記録で答える、1 は *r (再 probe の caps) で、-1 は Unknown (*msg — malloc) */
int rc_privileged(const struct bml_recorded *r, const char *q, const struct bml_caps **reprobe, char **msg);
/* recorded_query.c の答えの読み (真偽・diffs — E042 で recorded_e499.c と共有) */
int rc_boolean(const struct bml_recorded *r, const char *q, const char *key, int *out, char **msg);
/* 記録の 1 つの答え (無い鍵は ERROR、unknown / error の答えはその文で UNKNOWN / ERROR) */
int rc_answer(const struct bml_recorded *r, const char *q, const char *key, const struct answer **out, char **msg);
int rc_diffs(const struct bml_recorded *r, const char *q, const char *key, struct bml_strs *out, char **msg);
/* recorded_e499.c (bpf-mlir E499 — E042): kfunc_loads と tracepoint_buffer の callback を c に */
void rc_caps_e499(struct bml_caps *c);
/* recorded_v16.c (bpf-mlir E546〜E548 — E053): tracepoint_fields と syscall_args の callback を c に (strptr・strarray の鍵の欠けは Unknown) */
void rc_caps_v16(struct bml_caps *c);
int rc_format_version(const char *format);
int rc_added_loader_version(const struct bml_recorded *r, int version, char **err);
int rc_added_query_version(const struct bml_recorded *r, int version, char **err);
void rc_caps_kernel_values(struct bml_caps *c);
/* recorded_target_rows.c (E066): sleepable・netkit・helper_target の読みの検め (0、-1 は *err、1 は *err で caps_key_newer_format) と callback */
int rc_check_target_queries(const struct bml_recorded *r, const struct bml_json *j, int version, char **err);
void rc_caps_target_rows(struct bml_caps *c);
int rc_helper_target_privilege(const struct bml_recorded *r, const struct bml_caps **reprobe, char **msg);

extern const struct bml_json_desc rc_d_caps, rc_d_loader;
char *rc_fmts(const char *f, ...) __attribute__((format(printf, 1, 2)));
void rc_answer_free(struct answer *a);
int rc_check_keys(const struct bml_json *o, const char *const *allowed, size_t n, const char *where, char **err);
int rc_get_str(const struct bml_json *o, const char *key, char **out, char **err);
int rc_get_bool(const struct bml_json *o, const char *key, int *set, int *out, char **err);
int rc_get_kv(const struct bml_json *o, const char *key, struct bml_kv **out, size_t *n, int *has, char **err);
int rc_decode_answer(const struct bml_json *v, struct answer *a, char **err);
/* 厳しい読み (§13) — parse (byte の水準の規則と key_case) → 型の検査 (unknown_key・type) */
struct bml_json *rc_strict(const char *data, size_t len, const struct bml_json_desc *d, const char *prefix, char **err,
			   enum bml_json_rule *rule);

#endif
