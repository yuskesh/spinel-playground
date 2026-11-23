/* abi_case — E006 の spinel の面の契約の試験 (予測は E006 の「spinel の面の契約の試験 — 予測」の表 — 走らせる前に commit)。
 *
 *   abi_case all <flow.bpf.o> <schema の sha256>        R・L・M・H・B・T1〜T3・A・C・L11・P・X (root、unshare -n の中)
 *   abi_case signals <flow.bpf.o> <sha> <回数>           T4 (strace が BPF_PROG_TEST_RUN を数える)
 *   abi_case eintr <flow.bpf.o> <sha>                    T5 (変異の build と BML_MUTANT=run.fake_eintr_at_3)
 *
 * 入力の ELF は bpf-mlir の kernel/flow/mlir (xdp prog・array stats・lru_hash flows・ringbuf events・lpm_trie policy)。
 * 各行は `<id>: <観測> — ok` か `— FAIL (want …)`、FAIL が在れば exit 1。caps の kind 1 / 2 は -DBML_TEST_CAPS の build だけ。 */
#define _GNU_SOURCE
#include <dirent.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "bml/bml.h"
#include "abi_fixture.h"

static int fails;
static uint8_t *elf;
static int64_t elf_len;
static const char *sha;

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

/* 結果の kind と value を読み、message を *msg に写して free */
struct res {
	int64_t kind, value;
	char msg[4096];
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

static int64_t now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static uint8_t *read_file(const char *path, int64_t *n)
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

static struct res load(const char *maps, int64_t caps_kind)
{
	return take(bml_load_checked(elf, elf_len, S(sha), S(maps), caps_kind));
}

/* ---- process の状態 (P1〜P4) ---- */
struct pstate {
	struct sigaction sa[65];
	int sa_rc[65];
	int threads, fds;
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
	return n - 1; /* opendir の fd */
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

static void compare(const struct pstate *a, const struct pstate *b)
{
	int diff = 0;
	for (int i = 1; i <= 64; i++)
		if (a->sa_rc[i] != b->sa_rc[i] || (a->sa_rc[i] == 0 && (a->sa[i].sa_handler != b->sa[i].sa_handler || a->sa[i].sa_flags != b->sa[i].sa_flags)))
			diff++;
	check("P1", diff == 0, "sigaction differs %d", diff);
	check("P2", a->threads == b->threads, "thread %d → %d", a->threads, b->threads);
	check("P3", a->memlock.rlim_cur == b->memlock.rlim_cur && a->memlock.rlim_max == b->memlock.rlim_max, "RLIMIT_MEMLOCK %llu/%llu → %llu/%llu",
	      (unsigned long long)a->memlock.rlim_cur, (unsigned long long)a->memlock.rlim_max, (unsigned long long)b->memlock.rlim_cur,
	      (unsigned long long)b->memlock.rlim_max);
	check("P4", a->fds == b->fds, "fd %d → %d", a->fds, b->fds);
}

/* ---- B8: read を block している間の close ---- */
struct rd {
	int64_t reader;
	struct res r;
	int64_t t_end;
};
static void *reader_thread(void *p)
{
	struct rd *x = p;
	uint8_t ev[32];
	x->r = take(bml_ringbuf_read(x->reader, 500, ev, sizeof ev));
	x->t_end = now_ms();
	return NULL;
}

/* ---- X1: thread ---- */
struct xt {
	int64_t obj;
	int t, bad;
};
static void *stress(void *p)
{
	struct xt *x = p;
	uint8_t key[16] = {0}, val[24] = {0}, got[24];
	key[0] = 0x55;
	key[1] = (uint8_t)x->t;
	for (int i = 0; i < 10000; i++) {
		struct res a = take(bml_map_put_int(x->obj, S(DECL_STATS), x->t % 4, i));
		struct res b = take(bml_map_get_int(x->obj, S(DECL_STATS), x->t % 4));
		val[0] = (uint8_t)i;
		struct res c = take(bml_hash_put(x->obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), key, 16, val, 24));
		struct res d = take(bml_hash_get(x->obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), key, 16, got, 24));
		if (a.kind || b.kind || c.kind || d.kind || d.value != 1)
			x->bad++;
	}
	return NULL;
}

static void run_all(void)
{
	struct pstate before, after;
	snap(&before);
	/* R: 結果の registry */
	struct res r = take(123456789);
	/* R1 の message: 予測は "" — 実際は説明の文 (事後の訂正、E006 の判定の欄) */
	check("R1", r.kind == 6 && r.value == 0 && !strcmp(r.msg, "bml: no such result (it was never returned or was already freed)") && bml_result_kind(0) == 6, "kind %lld value %lld msg \"%s\"", (long long)r.kind,
	      (long long)r.value, r.msg);
	int64_t h = bml_load_checked(NULL, 0, S(sha), S(MAPS_OK), 0);
	bml_result_free(h);
	check("R2", bml_result_kind(h) == 6, "kind after free %lld", (long long)bml_result_kind(h));
	h = bml_load_checked(NULL, 0, S(sha), S(MAPS_OK), 0);
	int64_t ul = -1, full = bml_result_message_copy(h, (char[4]){0}, 4);
	const char *uf = bml_result_unmet_field(h, 5, 0, &ul);
	check("R3", uf && !uf[0] && ul == 0 && full == (int64_t)strlen(bml_result_message(h, NULL)), "unmet_field \"%s\" len %lld, full copy length %lld", uf ? uf : "(null)",
	      (long long)ul, (long long)full);
	bml_result_free(h);
	/* L: load の段 */
	r = take(bml_load_checked(elf, 0, S(sha), S(MAPS_OK), 0));
	check("L1", r.kind == 2, "0-byte ELF: kind %lld", (long long)r.kind);
	uint8_t junk[64];
	memset(junk, 0x5a, sizeof junk);
	r = take(bml_load_checked(junk, sizeof junk, S(sha), S(MAPS_OK), 0));
	check("L2", r.kind == 2 && !strncmp(r.msg, "bml: cannot read requirements from the embedded ELF", strlen("bml: cannot read requirements from the embedded ELF")),
	      "not an ELF: kind %lld \"%.80s\"", (long long)r.kind, r.msg);
	r = take(bml_load_checked(elf, elf_len, S("0000000000000000000000000000000000000000000000000000000000000000"), S(MAPS_OK), 0));
	check("L3", r.kind == 1, "sha differs: kind %lld", (long long)r.kind);
	r = load(MAPS_BAD_MAX, 0);
	check("L4", r.kind == 8 && strstr(r.msg, "map stats: max_entries is 5 in the declaration, but 4 in the ELF"), "kind %lld \"%s\"", (long long)r.kind, r.msg);
	struct res l5a = load("{", 0), l5b = load("{}", 0);
	check("L5", l5a.kind == 2 && l5b.kind == 2, "kind %lld / %lld", (long long)l5a.kind, (long long)l5b.kind);
	r = load(MAPS_GHOST_GLOBAL, 0);
	check("L6", r.kind == 8 && strstr(r.msg, "global ghost: declared (rodata u32), but the ELF has no such global"), "kind %lld \"%s\"", (long long)r.kind,
	      r.msg);
	int64_t rh = bml_load_checked(elf, elf_len, S(sha), S(MAPS_OK), 1);
	int64_t nu = bml_result_unmet_count(rh);
	char k0[64] = "";
	int64_t kl = 0;
	const char *kf = bml_result_unmet_field(rh, 0, 0, &kl);
	snprintf(k0, sizeof k0, "%.*s", (int)kl, kf ? kf : "");
	r = take(rh);
	check("L7", r.kind == 3 && nu >= 1 && !strcmp(k0, "program_type"), "caps 1: kind %lld unmet %lld [0] %s", (long long)r.kind, (long long)nu, k0);
	r = load(MAPS_OK, 7);
	check("L8", r.kind == 2, "caps 7: kind %lld", (long long)r.kind);
	rh = bml_load_checked(elf, elf_len, S(sha), S(MAPS_OK), 0);
	int64_t obj = bml_result_value(rh);
	r = take(rh);
	struct res un = take(bml_object_unmet(obj));
	int64_t nun = 0;
	{
		int64_t u = bml_object_unmet(obj);
		nun = bml_result_unmet_count(u);
		bml_result_free(u);
	}
	check("L9", r.kind == 0 && obj > 0 && un.kind == 0 && nun == 0, "kind %lld obj %lld unmet %lld \"%.200s\"", (long long)r.kind, (long long)obj,
	      (long long)nun, r.msg);
	if (r.kind != 0) {
		printf("abi_case: load failed; skipping later tests\n");
		fails++;
		return;
	}
	r = load(MAPS_OK, 0);
	check("L10", r.kind == 6, "second time: kind %lld", (long long)r.kind);
	/* M: array */
	r = take(bml_map_get_int(obj, S(DECL_STATS), 0));
	check("M1", r.kind == 0 && r.value == 0, "stats[0] %lld/%lld", (long long)r.kind, (long long)r.value);
	struct res a = take(bml_map_put_int(obj, S(DECL_STATS), 1, 42)), b = take(bml_map_get_int(obj, S(DECL_STATS), 1));
	check("M2", a.kind == 0 && b.kind == 0 && b.value == 42, "put %lld get %lld/%lld", (long long)a.kind, (long long)b.kind, (long long)b.value);
	a = take(bml_map_put_int(obj, S(DECL_STATS), 1, -1));
	b = take(bml_map_get_int(obj, S(DECL_STATS), 1));
	check("M3", a.kind == 9 && b.kind == 0 && b.value == 42, "put -1 %lld, get %lld/%lld", (long long)a.kind, (long long)b.kind, (long long)b.value);
	a = take(bml_map_put_bits(obj, S(DECL_STATS), 2, -1));
	b = take(bml_map_get_int(obj, S(DECL_STATS), 2));
	struct res c = take(bml_map_get_bits(obj, S(DECL_STATS), 2));
	check("M4", a.kind == 0 && b.kind == 9 && c.kind == 0 && c.value == -1, "put_bits %lld, get_int %lld, get_bits %lld/%lld", (long long)a.kind,
	      (long long)b.kind, (long long)c.kind, (long long)c.value);
	a = take(bml_map_get_int(obj, S(DECL_STATS), 4));
	b = take(bml_map_get_int(obj, S(DECL_STATS), -1));
	check("M5", a.kind == 5 && b.kind == 5, "key 4 %lld, key -1 %lld", (long long)a.kind, (long long)b.kind);
	struct res m6[4] = {take(bml_map_get_int(obj, S(DECL_STATS_U32), 0)), take(bml_map_get_int(obj, S(DECL_NOPE), 0)),
			    take(bml_map_get_int(obj, S(DECL_STATS_HASH), 0)), take(bml_map_get_int(obj, S("{\"name\":"), 0))};
	check("M6", m6[0].kind == 8 && m6[1].kind == 8 && m6[2].kind == 8 && m6[3].kind == 5, "%lld %lld %lld %lld", (long long)m6[0].kind,
	      (long long)m6[1].kind, (long long)m6[2].kind, (long long)m6[3].kind);
	/* H: hash (lru_hash の flows — record の key / value) */
	uint8_t k1[16] = {1, 2, 3, 4}, k2[16] = {5}, k3[16] = {6}, v1[24] = {9, 8, 7}, got[24];
	r = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), k1, 16, got, 24));
	check("H1", r.kind == 11, "missing key: kind %lld", (long long)r.kind);
	a = take(bml_hash_put(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), k1, 16, v1, 24));
	memset(got, 0, sizeof got);
	b = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), k1, 16, got, 24));
	check("H2", a.kind == 0 && b.kind == 0 && b.value == 1 && !memcmp(got, v1, 24), "put %lld get %lld/%lld", (long long)a.kind, (long long)b.kind,
	      (long long)b.value);
	a = take(bml_hash_delete(obj, S(DECL_FLOWS), S(REC_KEY), k1, 16));
	b = take(bml_hash_delete(obj, S(DECL_FLOWS), S(REC_KEY), k1, 16));
	c = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), k1, 16, got, 24));
	check("H3", a.kind == 0 && a.value == 1 && b.kind == 11 && c.kind == 11, "delete %lld/%lld, %lld, get %lld", (long long)a.kind, (long long)a.value,
	      (long long)b.kind, (long long)c.kind);
	a = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), k1, 8, got, 24));
	b = take(bml_hash_get(obj, S(DECL_FLOWS_ARRAY), S(REC_KEY), S(REC_VAL), k1, 16, got, 24));
	check("H4", a.kind == 8 && b.kind == 8, "klen 8 %lld, kind array %lld", (long long)a.kind, (long long)b.kind);
	uint8_t *ks[3] = {k1, k2, k3};
	for (int i = 0; i < 3; i++)
		take(bml_hash_put(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), ks[i], 16, v1, 24));
	rh = bml_hash_iter_open(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), 16, 24);
	int64_t it = bml_result_value(rh);
	r = take(rh);
	int seen = 0, n1 = 0;
	int64_t last = -1;
	for (int i = 0; i < 10; i++) {
		uint8_t kk[16], vv[24];
		struct res x = take(bml_hash_iter_next(it, kk, 16, vv, 24));
		last = x.kind == 0 ? x.value : -100 - x.kind;
		if (x.kind != 0 || x.value != 1)
			break;
		n1++;
		for (int j = 0; j < 3; j++)
			if (!memcmp(kk, ks[j], 16))
				seen |= 1 << j;
	}
	check("H5", r.kind == 0 && n1 == 3 && seen == 7 && last == 0, "open %lld, value 1 seen %d times, set %d, last %lld", (long long)r.kind, n1, seen,
	      (long long)last);
	a = take(bml_hash_iter_close(it));
	b = take(bml_hash_iter_close(it));
	c = take(bml_hash_iter_next(it, k1, 16, got, 24));
	check("H6", a.kind == 0 && b.kind == 0 && c.kind == 6, "close %lld %lld, next %lld", (long long)a.kind, (long long)b.kind, (long long)c.kind);
	for (int i = 0; i < 3; i++)
		take(bml_hash_delete(obj, S(DECL_FLOWS), S(REC_KEY), ks[i], 16));
	/* B: ring buffer と test run */
	rh = bml_ringbuf_open(obj, S(DECL_EVENTS), S(REC_EVENT), 32);
	int64_t rd = bml_result_value(rh);
	r = take(rh);
	check("B1", r.kind == 0 && rd > 0, "open %lld \"%s\"", (long long)r.kind, r.msg);
	uint8_t ev[32];
	int64_t t0 = now_ms();
	r = take(bml_ringbuf_read(rd, 10, ev, 32));
	check("B2", r.kind == 0 && r.value == 0 && now_ms() - t0 >= 10, "read %lld/%lld %lld ms", (long long)r.kind, (long long)r.value,
	      (long long)(now_ms() - t0));
	uint8_t frame[42];
	udp_frame(frame);
	a = take(bml_test_run_xdp_data(obj, S("prog"), frame, 42));
	memset(ev, 0, sizeof ev);
	b = take(bml_ringbuf_read(rd, 100, ev, 32));
	uint8_t fk[16], fv[24];
	flow_key_of(fk);
	c = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), fk, 16, fv, 24));
	uint32_t len = (uint32_t)ev[24] | (uint32_t)ev[25] << 8 | (uint32_t)ev[26] << 16 | (uint32_t)ev[27] << 24;
	check("B3", a.kind == 0 && a.value == 2 && b.kind == 0 && b.value == 1 && len == 28 && ev[8] == 0x04 && ev[9] == 0xd2 && c.kind == 0 && fv[0] == 1,
	      "run %lld/%lld, read %lld/%lld len %u sport %02x%02x, flows %lld packets %u \"%s\"", (long long)a.kind, (long long)a.value, (long long)b.kind,
	      (long long)b.value, len, ev[8], ev[9], (long long)c.kind, fv[0], a.msg);
	a = take(bml_test_run_xdp_data(obj, S("prog"), frame, 42));
	b = take(bml_ringbuf_read(rd, 10, ev, 32));
	c = take(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), fk, 16, fv, 24));
	check("B4", a.kind == 0 && a.value == 2 && b.kind == 0 && b.value == 0 && c.kind == 0 && fv[0] == 2, "run %lld/%lld, read %lld/%lld, packets %u",
	      (long long)a.kind, (long long)a.value, (long long)b.kind, (long long)b.value, fv[0]);
	r = take(bml_ringbuf_open(obj, S(DECL_EVENTS), S(REC_EVENT), 16));
	check("B5", r.kind == 8, "rec_size 16: kind %lld \"%s\"", (long long)r.kind, r.msg);
	if (r.kind == 0)
		take(bml_ringbuf_close(r.value));
	r = take(bml_ringbuf_read(rd, 0, ev, 16));
	check("B6", r.kind == 5, "n 16: kind %lld", (long long)r.kind);
	a = take(bml_ringbuf_close(rd));
	b = take(bml_ringbuf_close(rd));
	c = take(bml_ringbuf_read(rd, 0, ev, 32));
	check("B7", a.kind == 0 && b.kind == 0 && c.kind == 6, "close %lld %lld, read %lld", (long long)a.kind, (long long)b.kind, (long long)c.kind);
	rh = bml_ringbuf_open(obj, S(DECL_EVENTS), S(REC_EVENT), 32);
	struct rd x = {.reader = bml_result_value(rh)};
	bml_result_free(rh);
	pthread_t th;
	int64_t ts = now_ms();
	pthread_create(&th, NULL, reader_thread, &x);
	usleep(50000);
	/* E006 の後半の追補の 2: close は待たない — read の中の close は STATE (前の契約は read の timeout まで待った) */
	int64_t tq = now_ms();
	a = take(bml_ringbuf_close(x.reader));
	int64_t tc = now_ms();
	pthread_join(th, NULL);
	c = take(bml_ringbuf_close(x.reader));
	b = take(bml_ringbuf_read(x.reader, 0, ev, 32));
	check("B8", a.kind == 6 && tc - tq < 100 && x.r.kind == 0 && x.r.value == 0 && x.t_end - ts >= 400 && c.kind == 0 && b.kind == 6,
	      "close during read %lld (%lld ms), read %lld/%lld (%lld ms), later close %lld, later read %lld", (long long)a.kind, (long long)(tc - tq),
	      (long long)x.r.kind, (long long)x.r.value, (long long)(x.t_end - ts), (long long)c.kind, (long long)b.kind);
	/* T: test run */
	a = take(bml_test_run_xdp(obj, S("prog"), 0));
	b = take(bml_test_run_xdp(obj, S("prog"), -5));
	check("T1", a.kind == 9 && b.kind == 9, "0 %lld, -5 %lld", (long long)a.kind, (long long)b.kind);
	r = take(bml_test_run_xdp(obj, S("prog"), 1000));
	check("T2", r.kind == 0 && r.value == 2, "1000 times %lld/%lld", (long long)r.kind, (long long)r.value);
	r = take(bml_test_run_xdp(obj, S("nope"), 1));
	check("T3", r.kind == 6, "nope %lld", (long long)r.kind);
	/* A: attach (新しい netns の lo) */
	rh = bml_attach_xdp(obj, S("prog"), S("lo"));
	int64_t ln = bml_result_value(rh);
	r = take(rh);
	a = take(bml_detach(ln));
	b = take(bml_detach(ln));
	c = take(bml_detach(987654));
	check("A1", r.kind == 0 && a.kind == 0 && b.kind == 0 && c.kind == 6, "attach %lld \"%s\", detach %lld %lld, unknown %lld", (long long)r.kind, r.msg,
	      (long long)a.kind, (long long)b.kind, (long long)c.kind);
	r = take(bml_attach_xdp(obj, S("prog"), S("nope0")));
	check("A2", r.kind == 5, "nope0 %lld", (long long)r.kind);
	/* X: thread */
	struct xt xs[8];
	pthread_t tt[8];
	for (int i = 0; i < 8; i++) {
		xs[i] = (struct xt){obj, i, 0};
		pthread_create(&tt[i], NULL, stress, &xs[i]);
	}
	int bad = 0;
	for (int i = 0; i < 8; i++) {
		pthread_join(tt[i], NULL);
		bad += xs[i].bad;
	}
	check("X1", bad == 0, "8 threads x 10000, unexpected %d", bad);
	/* C: close の後 */
	rh = bml_ringbuf_open(obj, S(DECL_EVENTS), S(REC_EVENT), 32);
	int64_t r3 = bml_result_value(rh);
	bml_result_free(rh);
	a = take(bml_close(obj));
	struct res c1[5] = {take(bml_ringbuf_read(r3, 0, ev, 32)), take(bml_ringbuf_close(r3)), take(bml_map_get_int(obj, S(DECL_STATS), 0)),
			    take(bml_test_run_xdp(obj, S("prog"), 1)), take(bml_close(obj))};
	check("C1", a.kind == 0 && c1[0].kind == 6 && c1[1].kind == 0 && c1[2].kind == 6 && c1[3].kind == 6 && c1[4].kind == 0,
	      "close %lld, read %lld, reader close %lld, get %lld, run %lld, second close %lld", (long long)a.kind, (long long)c1[0].kind,
	      (long long)c1[1].kind, (long long)c1[2].kind, (long long)c1[3].kind, (long long)c1[4].kind);
	/* L11: caps の kind 2 */
	rh = bml_load_checked(elf, elf_len, S(sha), S(MAPS_OK), 2);
	int64_t o2 = bml_result_value(rh);
	r = take(rh);
	int64_t nh = 0, all_hu = 1;
	if (r.kind == 0) {
		int64_t u = bml_object_unmet(o2);
		nh = bml_result_unmet_count(u);
		for (int64_t i = 0; i < nh; i++) {
			int64_t l = 0;
			const char *f = bml_result_unmet_field(u, i, 0, &l);
			all_hu &= l == (int64_t)strlen("helper_unknown") && !memcmp(f, "helper_unknown", (size_t)l);
		}
		bml_result_free(u);
		take(bml_close(o2));
	}
	check("L11", r.kind == 0 && nh == 5 && all_hu, "caps 2: kind %lld unmet %lld all helper_unknown %lld \"%.200s\"", (long long)r.kind, (long long)nh,
	      (long long)all_hu, r.msg);
	snap(&after);
	compare(&before, &after);
}

static volatile sig_atomic_t alarms;
static void on_alarm(int s)
{
	(void)s;
	alarms++;
}

static void run_signals(int64_t n)
{
	int64_t rh = bml_load_checked(elf, elf_len, S(sha), S(MAPS_OK), 0);
	int64_t obj = bml_result_value(rh);
	struct res r = take(rh);
	if (r.kind != 0) {
		check("T4", 0, "load %lld \"%s\"", (long long)r.kind, r.msg);
		return;
	}
	struct sigaction sa = {.sa_handler = on_alarm}, old; /* SA_RESTART 無し */
	sigaction(SIGALRM, &sa, &old);
	struct itimerval iv = {{0, 100}, {0, 100}}, off = {{0, 0}, {0, 0}};
	setitimer(ITIMER_REAL, &iv, NULL);
	r = take(bml_test_run_xdp(obj, S("prog"), n));
	setitimer(ITIMER_REAL, &off, NULL);
	sigaction(SIGALRM, &old, NULL);
	check("T4", r.kind == 0 && r.value == 2 && alarms > 0, "%lld times: %lld/%lld, SIGALRM %d times \"%s\" (count BPF_PROG_TEST_RUN with strace)", (long long)n,
	      (long long)r.kind, (long long)r.value, (int)alarms, r.msg);
	take(bml_close(obj));
}

static void run_eintr(void)
{
	int64_t rh = bml_load_checked(elf, elf_len, S(sha), S(MAPS_OK), 0);
	int64_t obj = bml_result_value(rh);
	struct res r = take(rh);
	if (r.kind != 0) {
		check("T5", 0, "load %lld \"%s\"", (long long)r.kind, r.msg);
		return;
	}
	r = take(bml_test_run_xdp(obj, S("prog"), 10));
	check("T5", r.kind == 5 && r.value == 2 && strstr(r.msg, "interrupted by a signal at run 3 of 10 — 2 runs completed (not retried)"),
	      "%lld/%lld \"%s\"", (long long)r.kind, (long long)r.value, r.msg);
	take(bml_close(obj));
}

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "abi_case all|signals|eintr <flow.bpf.o> <sha> [count]\n");
		return 2;
	}
	elf = read_file(argv[2], &elf_len);
	sha = argv[3];
	if (!elf) {
		fprintf(stderr, "abi_case: cannot read %s\n", argv[2]);
		return 2;
	}
	if (!strcmp(argv[1], "all"))
		run_all();
	else if (!strcmp(argv[1], "signals") && argc > 4)
		run_signals(strtoll(argv[4], NULL, 10));
	else if (!strcmp(argv[1], "eintr"))
		run_eintr();
	else
		return 2;
	free(elf);
	printf("abi_case: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
