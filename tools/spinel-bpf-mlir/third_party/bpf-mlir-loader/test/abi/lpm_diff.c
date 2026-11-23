/* lpm_diff — E016 の差動の driver: lpm_trie の操作を mojo の Go の loader (試験の c-archive — -DMOJO) か bml に。各段を 1 行 (kind・value・
 * OK の時の message — found / absent と list の行) で印字し scripts/abi-mojo-diff.sh が比べる (誤りの文は接頭辞が違うので比べない)。
 *
 *   lpm_diff <lpm.bpf.o> <sha>     (root、unshare -n の中) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(x) (x), (int64_t)strlen(x)
#define KEY "\"key\":\"record:mojobpf_lpm_key4\""
#define D_POL "{\"name\":\"pol\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define D_POL8 "{\"name\":\"pol8\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u64\",\"max_entries\":16,\"flags\":1}"
#define D_POL_HASH "{\"name\":\"pol\",\"kind\":\"hash\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define D_POL_U64 "{\"name\":\"pol\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u64\",\"max_entries\":3,\"flags\":1}"
#define D_NOPE "{\"name\":\"nope\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define MAPS "{\"maps\":[" D_POL "," D_POL8 "]}"

#ifdef MOJO
/* mojo-bpf-mlir loader/main.go の export (5a53a6d) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
int64_t mojobpf_result_message(int64_t, char *, int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_lpm_check_prefix(const char *, int64_t);
int64_t mojobpf_lpm_put(int64_t, const char *, int64_t, const char *, int64_t, uint64_t);
int64_t mojobpf_lpm_remove(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_lpm_match(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_lpm_list(int64_t, const char *, int64_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define R_MSG(r, b, c) mojobpf_result_message(r, b, c)
#define LOAD(e, n, sha) mojobpf_load_checked_targets(e, n, S(sha), S(MAPS), "", 0, "", 0, "", 0, 0)
#define CHECK(p) mojobpf_lpm_check_prefix(S(p))
#define PUT(o, d, p, v) mojobpf_lpm_put(o, S(d), S(p), (uint64_t)(v))
#define REMOVE(o, d, p) mojobpf_lpm_remove(o, S(d), S(p))
#define MATCH(o, d, a) mojobpf_lpm_match(o, S(d), S(a))
#define LIST(o, d) mojobpf_lpm_list(o, S(d))
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define R_MSG(r, b, c) bml_result_message_copy(r, b, c)
#define LOAD(e, n, sha) bml_load_checked(e, n, S(sha), S(MAPS), 0)
#define CHECK(p) bml_lpm_check_prefix(S(p))
#define PUT(o, d, p, v) bml_lpm_put(o, S(d), S(p), (int64_t)(v))
#define REMOVE(o, d, p) bml_lpm_remove(o, S(d), S(p))
#define MATCH(o, d, a) bml_lpm_match(o, S(d), S(a))
#define LIST(o, d) bml_lpm_list(o, S(d))
#define CLOSE bml_close
#endif

/* 1 行: kind・value・OK なら message (改行は | に) */
static void show(const char *step, int64_t r)
{
	int64_t k = R_KIND(r), v = R_VALUE(r);
	char m[4096] = "";
	if (k == 0) {
		int64_t n = R_MSG(r, m, (int64_t)sizeof m - 1);
		m[n < (int64_t)sizeof m - 1 ? n : (int64_t)sizeof m - 1] = 0;
		for (char *p = m; *p; p++)
			if (*p == '\n')
				*p = '|';
	}
	R_FREE(r);
	printf("%s kind=%lld value=%lld msg=%s\n", step, (long long)k, (long long)(k == 0 ? v : 0), k == 0 ? m : "-");
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

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "lpm_diff <lpm.bpf.o> <sha>\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	static const char *const prefixes[] = {"10.0.0.0/8", "0.0.0.0/0", "1.2.3.4/32", "10.0.0.1/8", "::1/128", "10.0.0/8", "010.0.0.0/8",
					       "256.0.0.0/8", "10.0.0.0/08", "10.0.0.0/33", "10.0.0.0", "10.0.0.0/", "10.0.0.0/+8", "1.2.3.4.5/32",
					       "10..0.0/8", "", "255.255.255.255/32", "192.168.1.0/24", "1.2.3.4/-1", "1.2.3.4/100"};
	for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++) {
		char step[64];
		snprintf(step, sizeof step, "01-check-%02zu", i);
		show(step, CHECK(prefixes[i]));
	}
	int64_t n = 0, obj = 0;
	uint8_t *elf = slurp(argv[1], &n);
	int64_t r = LOAD(elf, n, argv[2]);
	free(elf);
	if (R_KIND(r) != 0) {
		show("02-load", r);
		return 1;
	}
	obj = R_VALUE(r);
	R_FREE(r);
	show("03-put-a", PUT(obj, D_POL, "10.0.0.0/8", 1));
	show("04-put-b", PUT(obj, D_POL, "10.1.0.0/16", 2));
	show("05-put-c", PUT(obj, D_POL, "0.0.0.0/0", 3));
	show("06-put-full", PUT(obj, D_POL, "192.168.0.0/16", 4));
	show("07-put-over", PUT(obj, D_POL, "10.0.0.0/8", 5));
	show("08-put-bad", PUT(obj, D_POL, "10.0.0.1/8", 6));
	show("09-match-a", MATCH(obj, D_POL, "10.1.2.3"));
	show("10-match-b", MATCH(obj, D_POL, "10.2.0.1"));
	show("11-match-c", MATCH(obj, D_POL, "8.8.8.8"));
	show("12-list", LIST(obj, D_POL));
	show("13-remove", REMOVE(obj, D_POL, "0.0.0.0/0"));
	show("14-remove-again", REMOVE(obj, D_POL, "0.0.0.0/0"));
	show("15-match-absent", MATCH(obj, D_POL, "8.8.8.8"));
	show("16-remove-bad", REMOVE(obj, D_POL, "10.0.0.1/8"));
	show("17-put8", PUT(obj, D_POL8, "172.16.0.0/12", 0x1122334455667788ULL));
	show("18-match8", MATCH(obj, D_POL8, "172.20.1.1"));
	show("19-put-wide", PUT(obj, D_POL, "10.1.0.0/16", 0x100000005ULL));
	show("20-match-wide", MATCH(obj, D_POL, "10.1.9.9"));
	show("21-list8", LIST(obj, D_POL8));
	show("22-decl-hash", LIST(obj, D_POL_HASH));
	show("23-decl-u64", LIST(obj, D_POL_U64));
	show("24-decl-nope", LIST(obj, D_NOPE));
	show("25-match-v6", MATCH(obj, D_POL, "::1"));
	show("26-match-short", MATCH(obj, D_POL, "10.0.0"));
	show("27-match-prefix", MATCH(obj, D_POL, "10.0.0.0/8"));
	show("28-close", CLOSE(obj));
	show("29-after-put", PUT(obj, D_POL, "10.0.0.0/8", 1));
	show("30-after-match", MATCH(obj, D_POL, "10.0.0.1"));
	show("31-after-list", LIST(obj, D_POL));
	show("32-after-check", CHECK("10.0.0.0/8"));
	return 0;
}
