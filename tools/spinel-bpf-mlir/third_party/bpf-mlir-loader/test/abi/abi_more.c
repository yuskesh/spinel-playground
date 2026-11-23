/* abi_more — E007 の H4: E006 で未試験の bml_* の面 (非 LRU の hash・record の array の bytes・per-CPU の stride・on_cpu の test run)。
 * 予測は E007 の「H4 の予測」の表 (走らせる前に commit)。
 *
 *   abi_more <bg.bpf.o> <bg の sha> <percpu.bpf.o> <percpu の sha>      (root、unshare -n の中)
 * 各行は `<id>: <観測> — ok|FAIL`、FAIL が在れば exit 1。 */
#define _GNU_SOURCE
#include <dirent.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#include "bml/bml.h"

static int fails;

static void check(const char *id, int ok, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int ok, const char *fmt, ...)
{
	va_list ap;
	printf("%s: ", id);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf(" — %s\n", ok ? "ok" : "FAIL");
	fails += !ok;
	fflush(stdout);
}

struct res {
	int64_t kind, value;
	char msg[1024];
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

#define S(x) (x), (int64_t)strlen(x)

static int64_t load(const char *path, const char *sha, const char *maps)
{
	int64_t n = 0;
	uint8_t *elf = slurp(path, &n);
	int64_t r = bml_load_checked(elf, n, S(sha), S(maps), 0);
	int64_t obj = bml_result_kind(r) == BML_OK ? bml_result_value(r) : -1;
	if (obj < 0)
		printf("load %s: kind %lld %s\n", path, (long long)bml_result_kind(r), bml_result_message(r, NULL));
	bml_result_free(r);
	free(elf);
	return obj;
}

/* ---- process の状態 (abi_case と同じ) ---- */
struct pstate {
	struct sigaction sa[65];
	int sa_rc[65], threads, fds;
	struct rlimit memlock;
};
static int count_fds(void)
{
	DIR *d = opendir("/proc/self/fd");
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d)))
		n += e->d_name[0] != '.';
	if (d)
		closedir(d);
	return n - 1;
}
static int count_threads(void)
{
	FILE *f = fopen("/proc/self/status", "r");
	char line[256];
	int n = -1;
	while (f && fgets(line, sizeof line, f))
		if (sscanf(line, "Threads: %d", &n) == 1)
			break;
	if (f)
		fclose(f);
	return n;
}
static void snap(struct pstate *s)
{
	memset(s, 0, sizeof *s);
	for (int i = 1; i <= 64; i++)
		s->sa_rc[i] = sigaction(i, NULL, &s->sa[i]);
	s->threads = count_threads();
	s->fds = count_fds();
	getrlimit(RLIMIT_MEMLOCK, &s->memlock);
}

#define BG_FLOWS "{\"name\":\"flows\",\"kind\":\"hash\",\"key\":\"record:fkey\",\"value\":\"u64\",\"max_entries\":16}"
#define BG_FLOWS_LRU "{\"name\":\"flows\",\"kind\":\"lru_hash\",\"key\":\"record:fkey\",\"value\":\"u64\",\"max_entries\":16}"
#define BG_PFLOWS "{\"name\":\"pflows\",\"kind\":\"percpu_hash\",\"key\":\"record:fkey\",\"value\":\"u64\",\"max_entries\":16}"
#define BG_RECS "{\"name\":\"recs\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"record:rec\",\"max_entries\":2}"
#define BG_RECS_OTHER "{\"name\":\"recs\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"record:other\",\"max_entries\":2}"
#define BG_OUT "{\"name\":\"out\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":4}"
#define BG_MAPS "{\"maps\":[" BG_FLOWS "," BG_OUT "," BG_PFLOWS "," BG_RECS "]}"
#define PC_PA "{\"name\":\"pa\",\"kind\":\"percpu_array\",\"key\":\"u32\",\"value\":\"i32\",\"max_entries\":2}"
#define PC_PH "{\"name\":\"ph\",\"kind\":\"percpu_hash\",\"key\":\"u32\",\"value\":\"record:tri\",\"max_entries\":8}"
#define PC_MAPS "{\"maps\":[" PC_PA "," PC_PH "]}"

static void run_bg(const char *path, const char *sha)
{
	int64_t obj = load(path, sha, BG_MAPS);
	if (obj < 0) {
		fails++;
		return;
	}
	uint8_t k[24] = {0}, v[8] = {1, 2, 3, 4, 5, 6, 7, 8}, got[8];
	/* N1 */
	k[0] = 0xa0;
	struct res a = take(bml_hash_get(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k, 24, got, 8));
	struct res b = take(bml_hash_put(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k, 24, v, 8));
	memset(got, 0, 8);
	struct res c = take(bml_hash_get(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k, 24, got, 8));
	uint8_t k2[24] = {0xa1}, k3[24] = {0xa2};
	take(bml_hash_put(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k2, 24, v, 8));
	take(bml_hash_put(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k3, 24, v, 8));
	int64_t rh = bml_hash_iter_open(obj, S(BG_FLOWS), NULL, 0, NULL, 0, 24, 8);
	int64_t it = bml_result_value(rh);
	bml_result_free(rh);
	int ones = 0;
	int64_t last = -1;
	for (int i = 0; i < 10; i++) {
		uint8_t kk[24], vv[8];
		struct res x = take(bml_hash_iter_next(it, kk, 24, vv, 8));
		last = x.kind ? -100 - x.kind : x.value;
		if (x.kind || x.value != 1)
			break;
		ones++;
	}
	take(bml_hash_iter_close(it));
	struct res d1 = take(bml_hash_delete(obj, S(BG_FLOWS), NULL, 0, k, 24)), d2 = take(bml_hash_delete(obj, S(BG_FLOWS), NULL, 0, k, 24));
	struct res g2 = take(bml_hash_get(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k, 24, got, 8));
	check("N1", a.kind == 11 && b.kind == 0 && c.kind == 0 && c.value == 1 && !memcmp(got, v, 8) && ones == 3 && last == 0 && d1.kind == 0 &&
			    d1.value == 1 && d2.kind == 11 && g2.kind == 11,
	      "get %lld, put %lld, get %lld/%lld, iterate saw 1 %d times, last %lld, delete %lld/%lld, %lld, get %lld", (long long)a.kind, (long long)b.kind,
	      (long long)c.kind, (long long)c.value, ones, (long long)last, (long long)d1.kind, (long long)d1.value, (long long)d2.kind, (long long)g2.kind);
	take(bml_hash_delete(obj, S(BG_FLOWS), NULL, 0, k2, 24));
	take(bml_hash_delete(obj, S(BG_FLOWS), NULL, 0, k3, 24));
	/* N2: 満杯 */
	int ok16 = 0;
	struct res full = {0};
	for (int i = 0; i < 17; i++) {
		uint8_t kk[24] = {0};
		kk[0] = 0xb0;
		kk[1] = (uint8_t)i;
		struct res x = take(bml_hash_put(obj, S(BG_FLOWS), NULL, 0, NULL, 0, kk, 24, v, 8));
		if (i < 16)
			ok16 += x.kind == 0;
		else
			full = x;
	}
	check("N2", ok16 == 16 && full.kind == 5 && strstr(full.msg, "argument list too long"), "16 entries %d, 17th %lld \"%s\"", ok16, (long long)full.kind,
	      full.msg);
	/* N3 */
	a = take(bml_hash_get(obj, S(BG_FLOWS_LRU), NULL, 0, NULL, 0, k, 24, got, 8));
	b = take(bml_hash_get(obj, S(BG_FLOWS), NULL, 0, NULL, 0, k, 16, got, 8));
	check("N3", a.kind == 8 && b.kind == 8, "lru declaration %lld, klen 16 %lld", (long long)a.kind, (long long)b.kind);
	/* R1: record の array */
	uint8_t rv[24], rg[24] = {0};
	for (int i = 0; i < 24; i++)
		rv[i] = (uint8_t)(i * 11 + 3);
	a = take(bml_map_put_bytes(obj, S(BG_RECS), NULL, 0, 1, rv, 24));
	b = take(bml_map_get_bytes(obj, S(BG_RECS), NULL, 0, 1, rg, 24));
	c = take(bml_map_get_bytes(obj, S(BG_RECS), NULL, 0, 1, rg, 23));
	struct res e = take(bml_map_get_bytes(obj, S(BG_RECS_OTHER), NULL, 0, 1, rg, 24));
	check("R1", a.kind == 0 && b.kind == 0 && !memcmp(rv, rg, 24) && c.kind == 8 && e.kind == 8, "put %lld, get %lld same %d, n 23 %lld, other %lld",
	      (long long)a.kind, (long long)b.kind, !memcmp(rv, rg, 24), (long long)c.kind, (long long)e.kind);
	/* C8: pflows (record の key の percpu_hash) */
	int64_t P = take(bml_possible_cpus()).value;
	uint8_t *pv = calloc((size_t)P, 8), *pg = calloc((size_t)P, 8);
	for (int64_t i = 0; i < P * 8; i++)
		pv[i] = (uint8_t)(i * 7 + 1);
	a = take(bml_percpu_put(obj, S(BG_PFLOWS), NULL, 0, NULL, 0, k, 24, 8, pv, P * 8));
	b = take(bml_percpu_get(obj, S(BG_PFLOWS), NULL, 0, NULL, 0, k, 24, 8, pg, P * 8));
	check("C8", a.kind == 0 && b.kind == 0 && b.value == 1 && !memcmp(pv, pg, (size_t)(P * 8)), "put %lld, get %lld/%lld same %d", (long long)a.kind,
	      (long long)b.kind, (long long)b.value, !memcmp(pv, pg, (size_t)(P * 8)));
	free(pv);
	free(pg);
	take(bml_close(obj));
}

static void run_percpu(const char *path, const char *sha)
{
	int64_t obj = load(path, sha, PC_MAPS);
	if (obj < 0) {
		fails++;
		return;
	}
	struct res pc = take(bml_possible_cpus());
	int64_t P = pc.value;
	check("C1", pc.kind == 0 && P > 0, "possible %lld", (long long)P);
	uint32_t key0 = 0;
	int32_t *g = calloc((size_t)P, 4), *w = calloc((size_t)P, 4);
	struct res a = take(bml_percpu_get(obj, S(PC_PA), NULL, 0, NULL, 0, (uint8_t *)&key0, 4, 4, (uint8_t *)g, P * 4));
	int zero = 1;
	for (int64_t c = 0; c < P; c++)
		zero &= g[c] == 0;
	struct res b = take(bml_percpu_get(obj, S(PC_PA), NULL, 0, NULL, 0, (uint8_t *)&key0, 4, 4, (uint8_t *)g, P * 4 - 1));
	check("C2", a.kind == 0 && a.value == 1 && zero && b.kind == 5, "get %lld/%lld all 0 %d, dlen -1 %lld", (long long)a.kind, (long long)a.value, zero,
	      (long long)b.kind);
	for (int64_t c = 0; c < P; c++)
		w[c] = (int32_t)(c + 1);
	a = take(bml_percpu_put(obj, S(PC_PA), NULL, 0, NULL, 0, (uint8_t *)&key0, 4, 4, (uint8_t *)w, P * 4));
	memset(g, 0, (size_t)P * 4);
	b = take(bml_percpu_get(obj, S(PC_PA), NULL, 0, NULL, 0, (uint8_t *)&key0, 4, 4, (uint8_t *)g, P * 4));
	check("C3", a.kind == 0 && b.kind == 0 && !memcmp(g, w, (size_t)P * 4), "put %lld, get %lld same %d", (long long)a.kind, (long long)b.kind,
	      !memcmp(g, w, (size_t)P * 4));
	/* C4: on_cpu */
	cpu_set_t before, after;
	sched_getaffinity(0, sizeof before, &before);
	static const uint8_t frame[64];
	int runs_ok = 1;
	for (int i = 0; i < 3; i++) {
		struct res x = take(bml_test_run_xdp_data_on_cpu(obj, S("prog"), frame, 64, 1));
		runs_ok &= x.kind == 0 && x.value == 2;
		if (x.kind)
			printf("  on_cpu: %lld %s\n", (long long)x.kind, x.msg);
	}
	sched_getaffinity(0, sizeof after, &after);
	memset(g, 0, (size_t)P * 4);
	b = take(bml_percpu_get(obj, S(PC_PA), NULL, 0, NULL, 0, (uint8_t *)&key0, 4, 4, (uint8_t *)g, P * 4));
	int slots = P > 1 && g[1] == 5;
	for (int64_t c = 0; c < P; c++)
		if (c != 1)
			slots &= g[c] == (int32_t)(c + 1);
	check("C4", runs_ok && b.kind == 0 && slots && CPU_EQUAL(&before, &after), "run %d, slot 1 = %d, others c+1 %d, affinity same %d", runs_ok, P > 1 ? g[1] : -1,
	      slots, CPU_EQUAL(&before, &after));
	a = take(bml_test_run_xdp_data_on_cpu(obj, S("prog"), frame, 64, P));
	sched_getaffinity(0, sizeof after, &after);
	check("C5", a.kind == 5 && CPU_EQUAL(&before, &after), "cpu %lld: %lld, affinity same %d", (long long)P, (long long)a.kind, CPU_EQUAL(&before, &after));
	/* C6: record 12 byte の percpu_hash */
	uint32_t key7 = 7;
	uint8_t *tv = calloc((size_t)P, 12), *tg = calloc((size_t)P, 12);
	for (int64_t i = 0; i < P * 12; i++)
		tv[i] = (uint8_t)(i * 5 + 9);
	a = take(bml_percpu_put(obj, S(PC_PH), NULL, 0, NULL, 0, (uint8_t *)&key7, 4, 12, tv, P * 12));
	b = take(bml_percpu_get(obj, S(PC_PH), NULL, 0, NULL, 0, (uint8_t *)&key7, 4, 12, tg, P * 12));
	int same = !memcmp(tv, tg, (size_t)P * 12);
	int64_t rh = bml_percpu_iter_open(obj, S(PC_PH), NULL, 0, NULL, 0, 4, 12);
	int64_t it = bml_result_value(rh);
	bml_result_free(rh);
	uint32_t ik = 0;
	memset(tg, 0, (size_t)P * 12);
	struct res i1 = take(bml_hash_iter_next(it, (uint8_t *)&ik, 4, tg, P * 12)), i2 = take(bml_hash_iter_next(it, (uint8_t *)&ik, 4, tg, P * 12));
	take(bml_hash_iter_close(it));
	int isame = !memcmp(tv, tg, (size_t)P * 12);
	struct res d1 = take(bml_percpu_delete(obj, S(PC_PH), NULL, 0, (uint8_t *)&key7, 4)), d2 = take(bml_percpu_delete(obj, S(PC_PH), NULL, 0, (uint8_t *)&key7, 4));
	struct res gm = take(bml_percpu_get(obj, S(PC_PH), NULL, 0, NULL, 0, (uint8_t *)&key7, 4, 12, tg, P * 12));
	check("C6", a.kind == 0 && b.kind == 0 && b.value == 1 && same && i1.kind == 0 && i1.value == 1 && ik == 7 && isame && i2.kind == 0 && i2.value == 0 &&
			    d1.kind == 0 && d2.kind == 11 && gm.kind == 11,
	      "put %lld, get %lld/%lld same %d, iter %lld/%lld key %u same %d -> %lld/%lld, delete %lld, %lld, get %lld", (long long)a.kind, (long long)b.kind,
	      (long long)b.value, same, (long long)i1.kind, (long long)i1.value, ik, isame, (long long)i2.kind, (long long)i2.value, (long long)d1.kind,
	      (long long)d2.kind, (long long)gm.kind);
	a = take(bml_percpu_put(obj, S(PC_PH), NULL, 0, NULL, 0, (uint8_t *)&key7, 4, 12, tv, P * 12 - 12));
	b = take(bml_percpu_put(obj, S(PC_PH), NULL, 0, NULL, 0, (uint8_t *)&key7, 4, 16, tv, P * 16 > P * 12 ? P * 12 : P * 16));
	check("C7", a.kind == 5 && b.kind == 8, "slen -12 %lld, vlen 16 %lld", (long long)a.kind, (long long)b.kind);
	free(g);
	free(w);
	free(tv);
	free(tg);
	take(bml_close(obj));
}

int main(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "abi_more <bg.bpf.o> <sha> <percpu.bpf.o> <sha>\n");
		return 2;
	}
	struct pstate s0, s1;
	snap(&s0);
	run_bg(argv[1], argv[2]);
	run_percpu(argv[3], argv[4]);
	snap(&s1);
	int sd = 0;
	for (int i = 1; i <= 64; i++)
		sd += s0.sa_rc[i] != s1.sa_rc[i] || (s0.sa_rc[i] == 0 && (s0.sa[i].sa_handler != s1.sa[i].sa_handler || s0.sa[i].sa_flags != s1.sa[i].sa_flags));
	check("P1", sd == 0, "sigaction differs %d", sd);
	check("P2", s0.threads == s1.threads, "thread %d → %d", s0.threads, s1.threads);
	check("P3", s0.memlock.rlim_cur == s1.memlock.rlim_cur, "RLIMIT_MEMLOCK same");
	check("P4", s0.fds == s1.fds, "fd %d → %d", s0.fds, s1.fds);
	printf("abi_more: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
