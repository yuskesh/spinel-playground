/* abi_trace — E012 の契約の試験: fentry / fexit の attach・tracing の test run (短命の thread)・kprobe の attach と perf の link の info
 * (予測は E012 — 走らせる前に commit)。
 *
 *   abi_trace <tr.bpf.o> <sha>     (root、unshare -n の中 — ASan + UBSan と試験の caps の build。変異は BML_MUTANT で)
 * 各 case は "<id>: … — ok|FAIL" の 1 行 */
#define _GNU_SOURCE
#include <dirent.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_CTL "{\"name\":\"ctl\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":1}"
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"globals\":[],\"maps\":[" M_CTL "," M_HITS "]}"

/* 試験の build だけ (src/abi/trace.c — BML_TEST_CAPS)。製品に link した道具では無い (weak — F6 は FAIL) */
__attribute__((weak)) int bml_testonly_tracing_sigmask(sigset_t *out);

static int fails;
static void check(const char *id, int good, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
#include <stdarg.h>
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

static int64_t obj;
static uint64_t hit(int k)
{
	struct res r = take(bml_map_get_bits(obj, S(M_HITS), k));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}
static pid_t gettid_(void)
{
	return (pid_t)syscall(SYS_gettid);
}

/* 別の thread で ctl[0] = 自分の tid → poll(NULL, 3, 0) (do_sys_poll の nfds = 3) */
static void *poller(void *arg)
{
	pid_t *tid = arg;
	*tid = gettid_();
	take(bml_map_put_bits(obj, S(M_CTL), 0, *tid));
	syscall(SYS_poll, NULL, 3, 0);
	return NULL;
}
static pid_t poll_on_worker(void)
{
	pthread_t th;
	pid_t tid = 0;
	pthread_create(&th, NULL, poller, &tid);
	pthread_join(th, NULL);
	return tid;
}

static int n_tasks(void)
{
	DIR *d = opendir("/proc/self/task");
	int n = 0;
	for (struct dirent *e; d && (e = readdir(d));)
		n += e->d_name[0] != '.';
	if (d)
		closedir(d);
	return n;
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
		fprintf(stderr, "abi_trace <tr.bpf.o> <sha>\n");
		return 2;
	}
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	struct res r = take(bml_load_checked(elf, n, S(argv[2]), S(MAPS), 0));
	free(elf);
	if (r.kind != 0) {
		printf("load: kind %lld \"%s\" — FAIL\n", (long long)r.kind, r.msg);
		return 1;
	}
	obj = r.value;
	pid_t me = gettid_(), pid = getpid();

	/* F1 */
	struct res a = take(bml_attach_fentry(obj, S("fe"))), b = take(bml_attach_fexit(obj, S("fx")));
	int64_t lfe = a.value, lfx = b.value;
	check("F1", a.kind == 0 && b.kind == 0, "fentry %lld \"%s\", fexit %lld \"%s\"", (long long)a.kind, a.msg, (long long)b.kind, b.msg);
	/* F2 */
	r = take(bml_test_run_tracing(obj, S("fe"), 3));
	pid_t tid = (pid_t)r.value;
	uint64_t h0 = hit(0), h1 = hit(1), h2 = hit(2), h3 = hit(3);
	check("F2", r.kind == 0 && tid > 0 && tid != me && tid != pid && h0 == 3 && h2 == 3 && h3 == 2 && h1 == ((uint64_t)pid << 32 | (uint32_t)tid),
	      "kind %lld \"%s\", tid %d (caller %d, pid %d), hits 0=%llu 1=%#llx 2=%llu 3=%llu", (long long)r.kind, r.msg, tid, me, pid,
	      (unsigned long long)h0, (unsigned long long)h1, (unsigned long long)h2, (unsigned long long)h3);
	/* F3 */
	r = take(bml_test_run_tracing(obj, S("fx"), 2));
	h0 = hit(0);
	h2 = hit(2);
	check("F3", r.kind == 0 && h0 == 5 && h2 == 5, "kind %lld, hits 0=%llu 2=%llu", (long long)r.kind, (unsigned long long)h0,
	      (unsigned long long)h2);
	/* F4 */
	int64_t k[9] = {
		take(bml_attach_fentry(obj, S("fx"))).kind,      take(bml_attach_fentry(obj, S("xp"))).kind,
		take(bml_attach_fentry(obj, S("kp"))).kind,      take(bml_attach_fexit(obj, S("fe"))).kind,
		take(bml_attach_kprobe(obj, S("fe"))).kind,      take(bml_attach_kprobe(obj, S("xp"))).kind,
		take(bml_test_run_tracing(obj, S("xp"), 1)).kind, take(bml_test_run_tracing(obj, S("kp"), 1)).kind,
		take(bml_attach_fentry(obj, S("nope"))).kind,
	};
	int all6 = 1;
	for (int i = 0; i < 9; i++)
		all6 &= k[i] == 6;
	check("F4", all6, "%lld %lld %lld %lld %lld %lld %lld %lld %lld", (long long)k[0], (long long)k[1], (long long)k[2], (long long)k[3],
	      (long long)k[4], (long long)k[5], (long long)k[6], (long long)k[7], (long long)k[8]);
	/* F5 */
	a = take(bml_test_run_tracing(obj, S("fe"), 0));
	b = take(bml_test_run_tracing(obj, S("fe"), -1));
	check("F5", a.kind == 9 && b.kind == 9 && hit(0) == 5, "0 %lld, -1 %lld, hits 0=%llu", (long long)a.kind, (long long)b.kind,
	      (unsigned long long)hit(0));
	/* F6 */
	sigset_t usr1, before_mask, after_mask, th_mask;
	sigemptyset(&usr1);
	sigaddset(&usr1, SIGUSR1);
	pthread_sigmask(SIG_BLOCK, &usr1, NULL);
	pthread_sigmask(SIG_BLOCK, NULL, &before_mask);
	struct sigaction sa0[65], sa1[65];
	memset(sa0, 0, sizeof sa0); /* glibc は sa_mask の先頭しか書かない — 残りを揃える (E012 の試験の側の誤りの訂正) */
	memset(sa1, 0, sizeof sa1);
	for (int s = 1; s < 65; s++)
		sigaction(s, NULL, &sa0[s]);
	/* 前の run の thread が /proc/self/task から消えるのを前の側でも待つ (E022 の gate で変異 trace.kprobe_info_other の F6 に 2 → 1 を
	 * 1 度観測 — 前の側の数えが早すぎた)。100 ms まで 1 になるのを待つ */
	int t0 = n_tasks();
	for (int w = 0; t0 != 1 && w < 100; w++) {
		usleep(1000);
		t0 = n_tasks();
	}
	r = take(bml_test_run_tracing(obj, S("fe"), 1));
	/* join は kernel が子の tid を消した時に返る — task が /proc/self/task から消えるのは少し後でありうる (E013 の gate で 1 → 2 を
	 * 1 度観測)。100 ms まで待って数え、待った ms を印字する */
	int t1 = n_tasks(), waited = 0;
	while (t1 != t0 && waited < 100) {
		usleep(1000);
		waited++;
		t1 = n_tasks();
	}
	pthread_sigmask(SIG_BLOCK, NULL, &after_mask);
	int sa_diff = 0;
	for (int s = 1; s < 65; s++) {
		sigaction(s, NULL, &sa1[s]);
		/* memcmp は使えない: glibc は sa_mask の尾に初期化していない buffer を写す (同じ signal を 2 度読んでも違う — E012 の実測) */
		int d = sa0[s].sa_handler != sa1[s].sa_handler || sa0[s].sa_flags != sa1[s].sa_flags;
		for (int m = 1; m < 65; m++)
			d |= sigismember(&sa0[s].sa_mask, m) != sigismember(&sa1[s].sa_mask, m);
		sa_diff += d;
	}
	int got = bml_testonly_tracing_sigmask ? bml_testonly_tracing_sigmask(&th_mask) : -1, unblocked = 0, first = 0;
	for (int s = 1; s < 65; s++) {
		if (s == SIGKILL || s == SIGSTOP || s == 32 || s == 33)
			continue;
		if (got != 0 || !sigismember(&th_mask, s)) {
			unblocked++;
			first = first ? first : s;
		}
	}
	int mask_same = 1;
	for (int s = 1; s < 65; s++)
		mask_same &= sigismember(&before_mask, s) == sigismember(&after_mask, s);
#if defined(__SANITIZE_ADDRESS__) || defined(__SANITIZE_THREAD__) || (defined(__has_feature) && (__has_feature(address_sanitizer) || __has_feature(thread_sanitizer)))
	/* sanitizer の pthread_create の interceptor は子の thread で親の mask に戻す (attr の mask を上書き — E012 の実測: 同じ code の
	 * sanitizer 無しの build は全て block)。run の thread の mask は sanitizer 無しの build (abi-mojo-target.sh の contract-plain) で見る */
	check("F6", r.kind == 0 && t0 == t1 && sa_diff == 0 && mask_same,
	      "kind %lld, thread %d -> %d (waited %d ms), sigaction differs %d, caller mask unchanged %d (the run thread's mask is not checked in sanitizer builds; reference %d)",
	      (long long)r.kind, t0, t1, waited, sa_diff, mask_same, unblocked);
#else
	check("F6", r.kind == 0 && t0 == t1 && sa_diff == 0 && mask_same && got == 0 && unblocked == 0,
	      "kind %lld, thread %d -> %d (waited %d ms), sigaction differs %d, caller mask unchanged %d, signals not blocked in the run thread's mask %d (first %d)",
	      (long long)r.kind, t0, t1, waited, sa_diff, mask_same, unblocked, first);
#endif
	pthread_sigmask(SIG_UNBLOCK, &usr1, NULL);
	/* F7 */
	uint64_t p0 = hit(0), p2 = hit(2);
	a = take(bml_detach(lfe));
	b = take(bml_detach(lfx));
	r = take(bml_test_run_tracing(obj, S("fe"), 1));
	check("F7", a.kind == 0 && b.kind == 0 && r.kind == 0 && hit(0) == p0 && hit(2) == p2, "detach %lld %lld, run %lld, hits 0 %llu -> %llu, 2 %llu -> %llu",
	      (long long)a.kind, (long long)b.kind, (long long)r.kind, (unsigned long long)p0, (unsigned long long)hit(0), (unsigned long long)p2,
	      (unsigned long long)hit(2));
	/* K1 */
	a = take(bml_attach_kprobe(obj, S("kp")));
	pid_t w = poll_on_worker();
	uint64_t h4 = hit(4), h5 = hit(5), h6 = hit(6);
	check("K1", a.kind == 0 && h4 == 1 && h5 == 3 && h6 == ((uint64_t)pid << 32 | (uint32_t)w),
	      "attach %lld \"%s\", worker %d, hits 4=%llu 5=%llu 6=%#llx", (long long)a.kind, a.msg, w, (unsigned long long)h4,
	      (unsigned long long)h5, (unsigned long long)h6);
	/* K2 */
	b = take(bml_detach(a.value));
	poll_on_worker();
	check("K2", (a.kind != 0 || b.kind == 0) && hit(4) == h4, "detach %lld, hits 4 %llu -> %llu", (long long)b.kind, (unsigned long long)h4,
	      (unsigned long long)hit(4));
	/* C1 */
	take(bml_close(obj));
	int64_t c1 = take(bml_attach_fentry(obj, S("fe"))).kind, c2 = take(bml_attach_kprobe(obj, S("kp"))).kind,
		c3 = take(bml_test_run_tracing(obj, S("fe"), 1)).kind;
	check("C1", c1 == 6 && c2 == 6 && c3 == 6, "%lld %lld %lld", (long long)c1, (long long)c2, (long long)c3);
	printf("abi_trace: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
