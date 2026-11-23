/* tcx_diff — E013 の差動の driver: 同じ操作の列を mojo の Go の loader (試験の c-archive — -DMOJO) か bml に。各段を 1 行で印字し、
 * scripts/tcx-diff.sh が 2 つの出力を比べる (message は向きの "ingress" / "egress" だけ比べる — 他の文は接頭辞が違う)。
 *
 *   tcx_diff <tc.bpf.o> <sha>     (root、unshare -n の中) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tcx_fixture.h"

#ifdef MOJO
/* mojo-bpf-mlir loader/main.go の export (5a53a6d — E099 で load は _targets (target と設定値の文書も) だけに) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
int64_t mojobpf_result_message(int64_t, char *, int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_attach_tcx(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_link_tcx_direction(int64_t);
int64_t mojobpf_test_run_tc_data(int64_t, const char *, int64_t, const uint8_t *, int64_t);
int64_t mojobpf_attach_xdp(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_attach_fentry(int64_t, const char *, int64_t);
int64_t mojobpf_detach(int64_t);
int64_t mojobpf_map_get(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define R_MSG(r, b, c) mojobpf_result_message(r, b, c)
#define LOAD(e, n, sha) mojobpf_load_checked_targets(e, n, S(sha), S(TC_MAPS), "", 0, "", 0, "", 0, 0)
#define TCX(o, p, i) mojobpf_attach_tcx(o, S(p), S(i))
#define DIR mojobpf_link_tcx_direction
#define TCRUN(o, p, d, n) mojobpf_test_run_tc_data(o, S(p), d, n)
#define XDP(o, p, i) mojobpf_attach_xdp(o, S(p), S(i))
#define FENTRY(o, p) mojobpf_attach_fentry(o, S(p))
#define DETACH mojobpf_detach
#define GET(o, k) mojobpf_map_get(o, S(M_CNT), k)
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define R_MSG(r, b, c) bml_result_message_copy(r, b, c)
#define LOAD(e, n, sha) bml_load_checked(e, n, S(sha), S(TC_MAPS), 0)
#define TCX(o, p, i) bml_attach_tcx(o, S(p), S(i))
#define DIR bml_link_tcx_direction
#define TCRUN(o, p, d, n) bml_test_run_tc_data(o, S(p), d, n)
#define XDP(o, p, i) bml_attach_xdp(o, S(p), S(i))
#define FENTRY(o, p) bml_attach_fentry(o, S(p))
#define DETACH bml_detach
#define GET(o, k) bml_map_get_bits(o, S(M_CNT), k)
#define CLOSE bml_close
#endif

static int64_t obj;

static int64_t kv(int64_t r, int64_t *value)
{
	int64_t k = R_KIND(r);
	if (value)
		*value = R_VALUE(r);
	R_FREE(r);
	return k;
}

/* 向き: kind・message (OK の時だけ)・value */
static void dir(const char *step, int64_t link)
{
	int64_t r = DIR(link), k = R_KIND(r), v = R_VALUE(r);
	char m[64] = "";
	if (k == 0) {
		int64_t n = R_MSG(r, m, (int64_t)sizeof m - 1);
		m[n < (int64_t)sizeof m - 1 ? n : (int64_t)sizeof m - 1] = 0;
	}
	R_FREE(r);
	printf("%s kind=%lld msg=%s value=%lld\n", step, (long long)k, k == 0 ? m : "-", (long long)(k == 0 ? v : 0));
}

static void dump(const char *step)
{
	int64_t v0 = 0, v1 = 0, k0 = kv(GET(obj, 0), &v0), k1 = kv(GET(obj, 1), &v1);
	printf("%s cnt kinds=%lld,%lld 0=%lld 1=%lld\n", step, (long long)k0, (long long)k1, (long long)v0, (long long)v1);
}

static void run(const char *step, const char *prog, const uint8_t *d, int64_t n)
{
	int64_t v = 0, k = kv(TCRUN(obj, prog, d, n), &v);
	printf("%s kind=%lld value=%lld\n", step, (long long)k, (long long)(k == 0 ? v : 0));
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "tcx_diff <tc.bpf.o> <sha>\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	int64_t k = kv(LOAD(elf, n, argv[2]), &obj);
	free(elf);
	printf("01-load kind=%lld\n", (long long)k);
	if (k != 0)
		return 1;
	int64_t li = 0, le = 0, lx = 0;
	printf("02-tcx-ti kind=%lld\n", (long long)kv(TCX(obj, "ti", "lo"), &li));
	dir("03-dir-ti", li);
	printf("04-tcx-te kind=%lld\n", (long long)kv(TCX(obj, "te", "lo"), &le));
	dir("05-dir-te", le);
	printf("06-lo-up rc=%d\n", lo_up());
	printf("07-udp got=%d\n", udp_self(7011));
	dump("08");
	printf("09-wrong kinds=%lld,%lld,%lld,%lld,%lld\n", (long long)kv(TCX(obj, "xp", "lo"), NULL), (long long)kv(TCX(obj, "ti", "nope0"), NULL),
	       (long long)kv(TCX(obj, "nope", "lo"), NULL), (long long)kv(TCRUN(obj, "xp", (uint8_t[42]){0}, 42), NULL),
	       (long long)kv(FENTRY(obj, "ti"), NULL));
	dir("10-dir-unknown", 987654);
	printf("11-xdp kind=%lld\n", (long long)kv(XDP(obj, "xp", "lo"), &lx));
	dir("12-dir-xdp", lx);
	printf("13-detach-xdp kind=%lld\n", (long long)kv(DETACH(lx), NULL));
	uint8_t v4[42], arp[42], shortf[13], v4s[20], big[4000];
	frame(v4, 42, 0x08, 0x00);
	frame(arp, 42, 0x08, 0x06);
	frame(shortf, 13, 0x08, 0x00);
	frame(v4s, 20, 0x08, 0x00);
	frame(big, sizeof big, 0x08, 0x06);
	run("14-run-ti-v4", "ti", v4, 42);
	run("15-run-ti-arp", "ti", arp, 42);
	run("16-run-ti-13", "ti", shortf, 13);
	run("17-run-ti-v4-20", "ti", v4s, 20);
	run("18-run-te-v4", "te", v4, 42);
	run("19-run-ti-empty", "ti", NULL, 0);
	run("20-run-ti-4000", "ti", big, (int64_t)sizeof big);
	dump("21");
	printf("22-detach kinds=%lld,%lld\n", (long long)kv(DETACH(li), NULL), (long long)kv(DETACH(le), NULL));
	dir("23-dir-detached", li);
	printf("24-udp got=%d\n", udp_self(7012));
	dump("25");
	printf("26-detach-again kind=%lld\n", (long long)kv(DETACH(li), NULL));
	printf("27-close kind=%lld\n", (long long)kv(CLOSE(obj), NULL));
	printf("28-after kinds=%lld,%lld\n", (long long)kv(TCX(obj, "ti", "lo"), NULL), (long long)kv(TCRUN(obj, "ti", v4, 42), NULL));
	return 0;
}
