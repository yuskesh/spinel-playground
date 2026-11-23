/* dead_diff — E014 の差動の driver: .rodata の設定値が死んだ code を生む program の load を mojo の Go の loader (試験の c-archive — -DMOJO)
 * か bml に。cilium は B4 の照合を持たない — Go は load する。bml も同じく load するか (直しの後) を段の kind と test run と cnt で比べる。
 *
 *   dead_diff <dead.bpf.o> <sha>     (root、unshare -n の中) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(x) (x), (int64_t)strlen(x)
#define M_CNT "{\"name\":\"cnt\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define G_WANT "{\"name\":\"want\",\"section\":\"rodata\",\"type\":\"u32\"}"
#define MAPS "{\"globals\":[" G_WANT "],\"maps\":[" M_CNT "]}"

#ifdef MOJO
/* mojo-bpf-mlir loader/main.go の export (5a53a6d) — 設定値の文書は bml の bml_load_checked_config の形 (mojo E099 / E101) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_test_run_xdp(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_map_get(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define LOAD(e, n, sha, cfg) mojobpf_load_checked_targets(e, n, S(sha), S(MAPS), "", 0, "", 0, S(cfg), 0)
#define RUN(o) mojobpf_test_run_xdp(o, S("prog"), 1)
#define GET(o, k) mojobpf_map_get(o, S(M_CNT), k)
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define LOAD(e, n, sha, cfg) bml_load_checked_config(e, n, S(sha), S(MAPS), S(cfg), 0)
#define RUN(o) bml_test_run_xdp(o, S("prog"), 1)
#define GET(o, k) bml_map_get_bits(o, S(M_CNT), k)
#define CLOSE bml_close
#endif

static int64_t kv(int64_t r, int64_t *value)
{
	int64_t k = R_KIND(r);
	if (value)
		*value = R_VALUE(r);
	R_FREE(r);
	return k;
}

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l + 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

static void one(const char *step, const uint8_t *elf, int64_t n, const char *sha, const char *cfg)
{
	int64_t obj = 0, k = kv(LOAD(elf, n, sha, cfg), &obj);
	printf("%s-load kind=%lld\n", step, (long long)k);
	if (k != 0)
		return;
	int64_t v = 0, rk = kv(RUN(obj), &v), rk2 = kv(RUN(obj), NULL), c0 = 0, c1 = 0, k0 = kv(GET(obj, 0), &c0), k1 = kv(GET(obj, 1), &c1);
	printf("%s-run kinds=%lld,%lld value=%lld cnt kinds=%lld,%lld 0=%lld 1=%lld\n", step, (long long)rk, (long long)rk2, (long long)v, (long long)k0,
	       (long long)k1, (long long)c0, (long long)c1);
	printf("%s-close kind=%lld\n", step, (long long)kv(CLOSE(obj), NULL));
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "dead_diff <dead.bpf.o> <sha>\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	one("01-optional", elf, n, argv[2], "{\"optional\":[\"want\"]}");
	one("02-set-3", elf, n, argv[2], "{\"set\":{\"want\":3}}");
	one("03-set-0", elf, n, argv[2], "{\"set\":{\"want\":0}}");
	free(elf);
	return 0;
}
