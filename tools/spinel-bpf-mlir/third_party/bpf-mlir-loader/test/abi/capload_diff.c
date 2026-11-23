/* capload_diff — E019 の差動の driver: 1 つの ELF を live の caps で load し、kind と権限の hint の有無を 1 行で印字する (mojo の Go の loader
 * (試験の c-archive — -DMOJO) か bml)。権限の組は呼び手 (scripts/capload-target.sh の setpriv) が決める。
 *
 *   capload_diff <label> <ELF> <sha>     → "<label> kind=<k> hint=<yes|no> perfmon=<yes|no> net_admin=<yes|no>" (bml は stage= も stderr に) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(x) (x), (int64_t)strlen(x)
#define MAPS "{\"maps\":[{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}]}"

#ifdef MOJO
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_message(int64_t, char *, int64_t);
int64_t mojobpf_result_value(int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_close(int64_t);
#define LOAD(e, n, sha) mojobpf_load_checked_targets(e, n, S(sha), S(MAPS), "", 0, "", 0, "", 0, 0)
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_MSG(r, b, c) mojobpf_result_message(r, b, c)
#define R_FREE mojobpf_result_free
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define LOAD(e, n, sha) bml_load_checked(e, n, S(sha), S(MAPS), 0)
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_MSG(r, b, c) bml_result_message_copy(r, b, c)
#define R_FREE bml_result_free
#define CLOSE bml_close
#endif

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "capload_diff <label> <ELF> <sha>\n");
		return 2;
	}
	FILE *f = fopen(argv[2], "rb");
	if (!f)
		return 2;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *e = malloc((size_t)l);
	if (!e || fread(e, 1, (size_t)l, f) != (size_t)l)
		return 2;
	fclose(f);
	int64_t r = LOAD(e, l, argv[3]);
	int64_t k = R_KIND(r), obj = R_VALUE(r);
	char m[8192] = "";
	int64_t n = R_MSG(r, m, (int64_t)sizeof m - 1);
	m[n < (int64_t)sizeof m - 1 ? n : (int64_t)sizeof m - 1] = 0;
	R_FREE(r);
	const char *h = strstr(m, "(hint: loading this object needs ");
	printf("%s kind=%lld hint=%s perfmon=%s net_admin=%s\n", argv[1], (long long)k, h ? "yes" : "no", h && strstr(h, "CAP_PERFMON —") ? "yes" : "no",
	       h && strstr(h, "CAP_NET_ADMIN") && strstr(h, "CAP_NET_ADMIN") < strstr(h, " — ") ? "yes" : "no");
	fprintf(stderr, "%s message: %s\n", argv[1], m);
	if (k == 0)
		R_FREE(CLOSE(obj));
	free(e);
	return 0;
}
