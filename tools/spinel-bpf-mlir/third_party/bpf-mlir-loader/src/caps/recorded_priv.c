/* caps/recorded_priv.c — 記録の caps の権限の分離 (bpf-mlir E438 の go/requirements/privilege.go の写し — 判定の版 10、E037):
 * 問いの答えが probe の権限に依るか (PrivilegeDependentQueries)、SamePrivilege (CapEff の 64 bit)、ForLoad (load の権限が記録の probed_as と
 * 違えば権限に依る問いを再 probe の caps か Unknown に — recorded_query.c の各 callback が rc_privileged を先に問う)、ParseLoadAs。 */
#define _GNU_SOURCE
#include "caps/recorded_internal.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/gostr.h"
#include "util/mutation.h"

static const char *const dependent[] = {
	BML_QUERY_PROG_TYPE,   BML_QUERY_HELPER,        BML_QUERY_MAP_TYPE,       BML_QUERY_TCX,         BML_QUERY_BTF_FEATURE, BML_QUERY_ARG_TAG,
	BML_QUERY_MAP_FIELD,   BML_QUERY_NULLABLE_ARGS, BML_QUERY_TRACING_HELPER, BML_QUERY_ATTACH_TYPE, BML_QUERY_CTX_ACCESS,
	BML_QUERY_KFUNC_LOADS, /* bpf-mlir E499 (E042) */
	BML_QUERY_FIB_FLAGS,
	BML_QUERY_NETKIT, BML_QUERY_SLEEPABLE, BML_QUERY_HELPER_TARGET, /* E066 */
};

int bml_caps_privilege_dependent(const char *q)
{
	for (size_t i = 0; i < sizeof dependent / sizeof *dependent; i++)
		if (!strcmp(q, dependent[i]))
			return 1;
	return 0;
}

/* strconv.ParseUint(s, 16, 64): 1 つ以上の 16 進の数字だけ (符号・0x は無し)、64 bit を超えれば誤り */
static int parse_hex64(const char *s, size_t n, uint64_t *out)
{
	uint64_t v = 0;
	if (n == 0)
		return -1;
	for (size_t i = 0; i < n; i++) {
		char c = s[i];
		unsigned d = c >= '0' && c <= '9' ? (unsigned)(c - '0') : c >= 'a' && c <= 'f' ? (unsigned)(c - 'a' + 10) : c >= 'A' && c <= 'F' ? (unsigned)(c - 'A' + 10) : 16;
		if (d == 16 || v > (UINT64_MAX >> 4))
			return -1;
		v = v << 4 | d;
	}
	*out = v;
	return 0;
}

/* strings.TrimSpace の後の 16 進 */
static int trimmed_hex(const char *s, uint64_t *out)
{
	size_t n = strlen(s);
	while (n && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == '\v' || *s == '\f'))
		s++, n--;
	while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == '\v' || s[n - 1] == '\f'))
		n--;
	return parse_hex64(s, n, out);
}

int bml_caps_same_privilege(const char *a, const char *b)
{
	uint64_t x, y;
	return a && b && a[0] && b[0] && !trimmed_hex(a, &x) && !trimmed_hex(b, &y) && x == y;
}

int bml_recorded_for_load(struct bml_recorded *r, long long load_uid, const char *load_cap, const struct bml_caps *reprobe)
{
	char *c = strdup(load_cap ? load_cap : "");
	if (!c)
		return -1;
	free(r->scope.load_cap);
	r->scope.set = 1;
	r->scope.load_uid = load_uid;
	r->scope.load_cap = c;
	r->scope.reprobe = reprobe;
	r->scope.mismatch = !r->has_probed || !bml_caps_same_privilege(r->probed_cap, c);
	if (BML_MUT("caps.priv_ignore_load_as")) /* 変異: 権限の違いを見ない (記録の答えを他の権限の load に流用する) */
		r->scope.mismatch = 0;
	return 0;
}

int rc_privileged(const struct bml_recorded *r, const char *q, const struct bml_caps **reprobe, char **msg)
{
	*reprobe = NULL;
	int dep = BML_MUT("caps.priv_split_all") ? 1 : bml_caps_privilege_dependent(q); /* 変異: 全ての問いを権限に依るとする */
	if (!r->scope.set || !r->scope.mismatch || !dep)
		return 0;
	if (r->scope.reprobe) {
		*reprobe = r->scope.reprobe;
		return 1;
	}
	char rec[128];
	if (r->has_probed)
		snprintf(rec, sizeof rec, "uid %lld cap_eff %s", r->probed_uid, r->probed_cap ? r->probed_cap : "");
	else
		snprintf(rec, sizeof rec, "no probed_as");
	if (asprintf(msg,
		     "recorded caps: %s depends on the probing privilege — recorded as %s, the load runs as uid %lld cap_eff %s (record as the loading "
		     "privilege, or re-probe it live)",
		     q, rec, r->scope.load_uid, r->scope.load_cap) < 0)
		*msg = NULL;
	return -1;
}

int bml_caps_parse_load_as(const char *s, long long *uid, char **cap, char **err)
{
	const char *colon = strchr(s, ':');
	size_t ul = colon ? (size_t)(colon - s) : strlen(s);
	int64_t u;
	struct bml_buf b = {0};
	if (!colon || bml_go_atoi(s, ul, &u) || u < 0) {
		bml_buf_adds(&b, "load-as ");
		bml_buf_add_goquote(&b, s, strlen(s));
		bml_buf_adds(&b, ": want <uid>:<cap_eff hex>");
		*err = bml_buf_take(&b);
		return -1;
	}
	uint64_t x;
	const char *c = colon + 1;
	if (parse_hex64(c, strlen(c), &x)) {
		bml_buf_adds(&b, "load-as ");
		bml_buf_add_goquote(&b, s, strlen(s));
		bml_buf_adds(&b, ": the cap_eff is 64-bit hex (/proc/<pid>/status CapEff)");
		*err = bml_buf_take(&b);
		return -1;
	}
	*uid = (long long)u;
	*cap = strdup(c);
	return *cap ? 0 : -1;
}
