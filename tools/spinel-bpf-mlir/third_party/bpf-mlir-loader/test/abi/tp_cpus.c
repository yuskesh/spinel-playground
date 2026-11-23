/* tp_cpus — E040 の単体試験 (非 root): tracepoint の attach の CPU の list の解析と選び (src/abi/tp_cpus.c) を bpf-mlir E434 の
 * kernel/internal/tpattach/tpattach_test.go と同じ表で。誤りの文の形も Go の tpattach と同じか (offline の名指しの BML_TRACEPOINT_ONLINE_ONLY は
 * option の名前だけ違う)。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "abi/tp_cpus.h"

static int bad;

static void list_eq(const char *in, const int *want, size_t nw)
{
	int *got;
	size_t n;
	char *err;
	int rc = bml_tp_parse_cpus(in, &got, &n, &err);
	int ok = rc == 0 && n == nw && (nw == 0 || memcmp(got, want, nw * sizeof *want) == 0);
	printf("parse %-12s %s\n", in[0] ? in : "(empty)", ok ? "ok" : "FAIL");
	bad |= !ok;
	free(got);
	free(err);
}

static void list_err(const char *in, const char *want)
{
	int *got;
	size_t n;
	char *err;
	int rc = bml_tp_parse_cpus(in, &got, &n, &err);
	int ok = rc != 0 && err && strcmp(err, want) == 0;
	printf("parse-err %-10s %s (%s)\n", in[0] ? in : "(empty)", ok ? "ok" : "FAIL", err ? err : "no error");
	bad |= !ok;
	free(got);
	free(err);
}

int main(void)
{
	list_eq("0", (int[]){0}, 1);
	list_eq("0-3\n", (int[]){0, 1, 2, 3}, 4);
	list_eq("0-1,4,6-7", (int[]){0, 1, 4, 6, 7}, 5);
	list_err("", "empty cpu list");
	list_err("x", "bad cpu list \"x\"");
	list_err("3-1", "bad cpu list \"3-1\"");
	list_err("1,0", "cpu list \"1,0\" is not ascending");
	list_err("0-1,1", "cpu list \"0-1,1\" is not ascending");
	list_err("-1", "bad cpu list \"-1\"");
	list_err("0,,1", "bad cpu list \"0,,1\"");
	list_err("0-99999", "bad cpu list \"0-99999\""); /* bml の上限 65535 (Go に無い — fail closed の差) */
	int *o;
	size_t n;
	char *err;
	int rc = bml_tp_select_cpus((int[]){0, 1}, 2, (int[]){0, 1}, 2, 0, &o, &n, &err);
	int ok = rc == 0 && n == 2 && o[0] == 0 && o[1] == 1;
	printf("select same %s\n", ok ? "ok" : "FAIL");
	bad |= !ok;
	free(o);
	free(err);
	rc = bml_tp_select_cpus((int[]){0, 1, 2, 3}, 4, (int[]){0, 2}, 2, 0, &o, &n, &err);
	ok = rc != 0 && err && strstr(err, "possible CPUs 1,3 are offline") == err;
	printf("select offline %s (%s)\n", ok ? "ok" : "FAIL", err ? err : "");
	bad |= !ok;
	free(o);
	free(err);
	rc = bml_tp_select_cpus((int[]){0, 1, 2, 3}, 4, (int[]){0, 2}, 2, 1, &o, &n, &err);
	ok = rc == 0 && n == 2 && o[0] == 0 && o[1] == 2;
	printf("select online-only %s\n", ok ? "ok" : "FAIL");
	bad |= !ok;
	free(o);
	free(err);
	rc = bml_tp_cpus(0, &o, &n, &err); /* この host の sysfs (possible = online の host なら全ての CPU) */
	printf("host cpus rc=%d n=%zu%s%s\n", rc, n, err ? " err=" : "", err ? err : "");
	free(o);
	free(err);
	printf("tp_cpus: %s\n", bad ? "FAIL" : "ok");
	return bad;
}
