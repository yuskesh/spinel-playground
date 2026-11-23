/* abi_lpm — E016 の契約の試験: lpm_trie の check_prefix・put・remove・match・list (予測は E016 — 走らせる前に commit)。
 *
 *   abi_lpm <lpm.bpf.o> <sha>     (root、unshare -n の中)
 * 各 case は "<id>: … — ok|FAIL" の 1 行 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)
#define KEY "\"key\":\"record:mojobpf_lpm_key4\""
#define D_POL "{\"name\":\"pol\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define D_POL8 "{\"name\":\"pol8\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u64\",\"max_entries\":16,\"flags\":1}"
#define D_POL_HASH "{\"name\":\"pol\",\"kind\":\"hash\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define D_POL_U64 "{\"name\":\"pol\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u64\",\"max_entries\":3,\"flags\":1}"
#define D_NOPE "{\"name\":\"nope\",\"kind\":\"lpm_trie\"," KEY ",\"value\":\"u32\",\"max_entries\":3,\"flags\":1}"
#define MAPS "{\"maps\":[" D_POL "," D_POL8 "]}"

static int fails;
static void check(const char *id, int good, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int good, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("%s: ", id);
	vprintf(fmt, ap);
	printf(" — %s\n", good ? "ok" : "FAIL");
	va_end(ap);
	fails += !good;
}

struct res {
	int64_t kind, value;
	char msg[2048];
};
static struct res take(int64_t r)
{
	struct res x = {bml_result_kind(r), bml_result_value(r), ""};
	int64_t n = 0;
	const char *m = bml_result_message(r, &n);
	snprintf(x.msg, sizeof x.msg, "%.*s", (int)n, m ? m : "");
	bml_result_free(r);
	return x;
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
		fprintf(stderr, "abi_lpm <lpm.bpf.o> <sha>\n");
		return 2;
	}
	/* P1: check_prefix (object 無し) */
	struct res a = take(bml_lpm_check_prefix(S("10.0.0.0/8"))), b = take(bml_lpm_check_prefix(S("0.0.0.0/0"))),
		   c = take(bml_lpm_check_prefix(S("1.2.3.4/32"))), h = take(bml_lpm_check_prefix(S("10.0.0.1/8")));
	check("P1", a.kind == 0 && a.value == 8 && b.kind == 0 && b.value == 0 && c.kind == 0 && c.value == 32 && h.kind == 5 && strstr(h.msg, "use 10.0.0.0/8"),
	      "10.0.0.0/8 %lld/%lld, 0.0.0.0/0 %lld/%lld, 1.2.3.4/32 %lld/%lld, host bits %lld \"%s\"", (long long)a.kind, (long long)a.value,
	      (long long)b.kind, (long long)b.value, (long long)c.kind, (long long)c.value, (long long)h.kind, h.msg);
	static const char *const bad[] = {"::1/128", "10.0.0/8", "010.0.0.0/8", "256.0.0.0/8", "10.0.0.0/08", "10.0.0.0/33",
					  "10.0.0.0", "10.0.0.0/", "10.0.0.0/+8", "1.2.3.4.5/32", "10..0.0/8", ""};
	int nbad = 0;
	for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
		nbad += take(bml_lpm_check_prefix(S(bad[i]))).kind == 5;
	check("P1b", nbad == 12, "OTHER for %d of 12 malformed prefixes", nbad);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	struct res r = take(bml_load_checked(elf, n, S(argv[2]), S(MAPS), 0));
	free(elf);
	if (r.kind != 0) {
		printf("load: kind %lld \"%s\" — FAIL\n", (long long)r.kind, r.msg);
		return 1;
	}
	int64_t obj = r.value;
	/* P2: put (満杯は −28、在る prefix の上書きは満杯でも 0) */
	int64_t p[5] = {take(bml_lpm_put(obj, S(D_POL), S("10.0.0.0/8"), 1)).value, take(bml_lpm_put(obj, S(D_POL), S("10.1.0.0/16"), 2)).value,
			take(bml_lpm_put(obj, S(D_POL), S("0.0.0.0/0"), 3)).value, take(bml_lpm_put(obj, S(D_POL), S("192.168.0.0/16"), 4)).value,
			take(bml_lpm_put(obj, S(D_POL), S("10.0.0.0/8"), 5)).value};
	check("P2", p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == -28 && p[4] == 0, "status %lld %lld %lld %lld %lld", (long long)p[0], (long long)p[1],
	      (long long)p[2], (long long)p[3], (long long)p[4]);
	/* P3: match (最長一致) と list */
	struct res m1 = take(bml_lpm_match(obj, S(D_POL), S("10.1.2.3"))), m2 = take(bml_lpm_match(obj, S(D_POL), S("10.2.0.1"))),
		   m3 = take(bml_lpm_match(obj, S(D_POL), S("8.8.8.8"))), l = take(bml_lpm_list(obj, S(D_POL)));
	check("P3", !strcmp(m1.msg, "found") && m1.value == 2 && !strcmp(m2.msg, "found") && m2.value == 5 && !strcmp(m3.msg, "found") && m3.value == 3 &&
			    l.kind == 0 && l.value == 3 && !strcmp(l.msg, "0.0.0.0/0 3\n10.0.0.0/8 5\n10.1.0.0/16 2"),
	      "%s/%lld %s/%lld %s/%lld, list %lld/%lld \"%s\"", m1.msg, (long long)m1.value, m2.msg, (long long)m2.value, m3.msg, (long long)m3.value,
	      (long long)l.kind, (long long)l.value, l.msg);
	/* P4: remove */
	struct res d1 = take(bml_lpm_remove(obj, S(D_POL), S("0.0.0.0/0"))), d2 = take(bml_lpm_remove(obj, S(D_POL), S("0.0.0.0/0"))),
		   d3 = take(bml_lpm_match(obj, S(D_POL), S("8.8.8.8"))), d4 = take(bml_lpm_remove(obj, S(D_POL), S("10.0.0.1/8")));
	check("P4", d1.kind == 0 && d1.value == 0 && d2.kind == 0 && d2.value == -2 && d3.kind == 0 && !strcmp(d3.msg, "absent") && d4.kind == 5,
	      "%lld/%lld, %lld/%lld, match %s, host bits %lld", (long long)d1.kind, (long long)d1.value, (long long)d2.kind, (long long)d2.value, d3.msg,
	      (long long)d4.kind);
	/* P5: 値の幅 (u64 はそのまま、u32 は下の 32 bit) */
	take(bml_lpm_put(obj, S(D_POL8), S("172.16.0.0/12"), 0x1122334455667788LL));
	take(bml_lpm_put(obj, S(D_POL), S("10.1.0.0/16"), 0x100000005LL));
	struct res v8 = take(bml_lpm_match(obj, S(D_POL8), S("172.20.1.1"))), v4 = take(bml_lpm_match(obj, S(D_POL), S("10.1.9.9")));
	check("P5", v8.value == 0x1122334455667788LL && v4.value == 5, "u64 %#llx, u32 %#llx", (unsigned long long)v8.value, (unsigned long long)v4.value);
	/* P6: 宣言の食い違い */
	int64_t k6[3] = {take(bml_lpm_list(obj, S(D_POL_HASH))).kind, take(bml_lpm_list(obj, S(D_POL_U64))).kind, take(bml_lpm_list(obj, S(D_NOPE))).kind};
	check("P6", k6[0] == 8 && k6[1] == 8 && k6[2] == 8, "hash %lld, value u64 %lld, nope %lld", (long long)k6[0], (long long)k6[1], (long long)k6[2]);
	/* P7: address の誤り */
	int64_t k7[3] = {take(bml_lpm_match(obj, S(D_POL), S("::1"))).kind, take(bml_lpm_match(obj, S(D_POL), S("10.0.0"))).kind,
			 take(bml_lpm_match(obj, S(D_POL), S("10.0.0.0/8"))).kind};
	check("P7", k7[0] == 5 && k7[1] == 5 && k7[2] == 5, "%lld %lld %lld", (long long)k7[0], (long long)k7[1], (long long)k7[2]);
	/* C1: close の後 (check_prefix は object 無し — OK のまま) */
	take(bml_close(obj));
	int64_t c1 = take(bml_lpm_put(obj, S(D_POL), S("10.0.0.0/8"), 1)).kind, c2 = take(bml_lpm_match(obj, S(D_POL), S("10.0.0.1"))).kind,
		c3 = take(bml_lpm_list(obj, S(D_POL))).kind, c4 = take(bml_lpm_check_prefix(S("10.0.0.0/8"))).kind;
	check("C1", c1 == 6 && c2 == 6 && c3 == 6 && c4 == 0, "%lld %lld %lld %lld", (long long)c1, (long long)c2, (long long)c3, (long long)c4);
	printf("abi_lpm: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
