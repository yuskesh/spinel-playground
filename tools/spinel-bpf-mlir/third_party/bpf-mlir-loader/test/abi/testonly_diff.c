/* testonly_diff — E017 の差動の driver: 試験の口を mojo の Go の loader (試験の c-archive — -DMOJO) か bml (試験の build) に。各段を 1 行で印字し
 * scripts/abi-mojo-diff.sh が比べる (global への直の書き込みの message は「拒否したか」の組に畳む — 名前が cilium / libbpf で違う)。
 *
 *   testonly_diff <to.bpf.o> <sha> <up.bpf.o> <up の sha> <fixture> <fixture_other>     (root、unshare -n の中)
 *   testonly_diff fault <to.bpf.o> <sha>     (故意の fault の子 — 戻らない) */
#define _GNU_SOURCE
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>

#include "up_fixture.h"

#define M_CNT "{\"name\":\"cnt\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define M_EV "{\"name\":\"ev\",\"kind\":\"ringbuf\",\"key\":\"-\",\"value\":\"record:evr\",\"max_entries\":4096}"
#define G_WANT "{\"name\":\"want\",\"section\":\"rodata\",\"type\":\"u64\"}"
#define TO_MAPS "{\"globals\":[" G_WANT "],\"maps\":[" M_CNT "," M_EV "]}"
#define UP_MAPS_BAD "{\"maps\":[{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":5}]}"
#define CFG "{\"set\":{\"want\":7}}"

#ifdef MOJO
/* mojo-bpf-mlir loader の export (5a53a6d — 試験の build -tags mojobpf_test) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int64_t mojobpf_testonly_load_unchecked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
						const char *, int64_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
int64_t mojobpf_result_message(int64_t, char *, int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_testonly_global_set_raw(int64_t, const char *, int64_t, uint64_t);
int64_t mojobpf_global_get(int64_t, const char *, int64_t);
int64_t mojobpf_test_freeze_map(int64_t, const char *, int64_t);
int64_t mojobpf_test_ringbuf_fault(int64_t, const char *, int64_t);
int64_t mojobpf_testonly_uprobe_symbol(const char *, int64_t, const char *, int64_t);
int64_t mojobpf_testonly_uprobe_offset_mode(const char *, int64_t);
int64_t mojobpf_attach_uprobe(int64_t, const char *, int64_t, int64_t);
int64_t mojobpf_detach(int64_t);
int64_t mojobpf_map_get(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_map_put(int64_t, const char *, int64_t, uint32_t, uint64_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define R_MSG(r, b, c) mojobpf_result_message(r, b, c)
#define LOAD(e, n, sha, maps, cfg, t) mojobpf_load_checked_targets(e, n, S(sha), S(maps), "", 0, S(t), S(cfg), 0)
#define UNCHECKED(e, n, sha, maps, t) mojobpf_testonly_load_unchecked_targets(e, n, S(sha), S(maps), "", 0, S(t))
#define SET_RAW(o, nm, v) mojobpf_testonly_global_set_raw(o, S(nm), (uint64_t)(v))
#define GGET(o, d) mojobpf_global_get(o, S(d))
#define FREEZE(o, nm) mojobpf_test_freeze_map(o, S(nm))
#define FAULT(o, nm) mojobpf_test_ringbuf_fault(o, S(nm))
#define USYM(p, s) mojobpf_testonly_uprobe_symbol(S(p), S(s))
#define UMODE(m) mojobpf_testonly_uprobe_offset_mode(S(m))
#define UPROBE(o, p, pid) mojobpf_attach_uprobe(o, S(p), pid)
#define DETACH mojobpf_detach
#define GET(o, d, k) mojobpf_map_get(o, S(d), k)
#define PUT(o, d, k, v) mojobpf_map_put(o, S(d), k, (uint64_t)(v))
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#include "bml/bml_testonly.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define R_MSG(r, b, c) bml_result_message_copy(r, b, c)
#define LOAD(e, n, sha, maps, cfg, t) bml_load_checked_targets(e, n, S(sha), S(maps), S(cfg), S(t), 0)
#define UNCHECKED(e, n, sha, maps, t) bml_testonly_load_unchecked_targets(e, n, S(sha), S(maps), NULL, 0, S(t))
#define SET_RAW(o, nm, v) bml_testonly_global_set_raw(o, S(nm), (int64_t)(v))
#define GGET(o, d) bml_global_get(o, S(d))
#define FREEZE(o, nm) bml_testonly_freeze_map(o, S(nm))
#define FAULT(o, nm) bml_testonly_ringbuf_fault(o, S(nm))
#define USYM(p, s) bml_testonly_uprobe_symbol(S(p), S(s))
#define UMODE(m) bml_testonly_uprobe_offset_mode(S(m))
#define UPROBE(o, p, pid) bml_attach_uprobe(o, S(p), pid)
#define DETACH bml_detach
#define GET(o, d, k) bml_map_get_bits(o, S(d), k)
#define PUT(o, d, k, v) bml_map_put_bits(o, S(d), k, (int64_t)(v))
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

/* 直の書き込みの message "<名>=<誤り|nil> kernel=<誤り|nil>" を "lib:<nil|err> kernel:<nil|err>" に */
static void raw(const char *step, int64_t r)
{
	int64_t k = R_KIND(r);
	char m[1024] = "";
	if (k == 0) {
		int64_t n = R_MSG(r, m, (int64_t)sizeof m - 1);
		m[n < (int64_t)sizeof m - 1 ? n : (int64_t)sizeof m - 1] = 0;
	}
	R_FREE(r);
	const char *eq = strchr(m, '='), *kn = strstr(m, " kernel=");
	int lib_nil = eq && !strncmp(eq + 1, "nil ", 4), ker_nil = kn && !strcmp(kn + 8, "nil");
	printf("%s kind=%lld lib:%s kernel:%s\n", step, (long long)k, k ? "-" : lib_nil ? "nil" : "err", k ? "-" : ker_nil ? "nil" : "err");
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 4 && !strcmp(argv[1], "fault")) {
		int64_t n = 0, obj = 0;
		uint8_t *e = slurp(argv[2], &n);
		if (kv(LOAD(e, n, argv[3], TO_MAPS, CFG, ""), &obj) != 0)
			return 3;
		kv(FAULT(obj, "ev"), NULL);
		return 4;
	}
	if (argc != 7) {
		fprintf(stderr, "testonly_diff <to.bpf.o> <sha> <up.bpf.o> <up sha> <fixture> <fixture_other>\n");
		return 2;
	}
	int64_t tn = 0, un = 0, obj = 0, l = 0, v = 0;
	uint8_t *to = slurp(argv[1], &tn), *up = slurp(argv[3], &un);
	char doc[4096];
	targets_doc(doc, sizeof doc, "up", argv[6]);
	printf("01-checked-other kind=%lld\n", (long long)kv(LOAD(up, un, argv[4], UP_MAPS, "", doc), NULL));
	int64_t k = kv(UNCHECKED(up, un, argv[4], UP_MAPS, doc), &obj);
	printf("02-unchecked-other kind=%lld\n", (long long)k);
	if (k == 0)
		kv(CLOSE(obj), NULL);
	k = kv(UNCHECKED(up, un, argv[4], UP_MAPS, ""), &obj);
	printf("03-unchecked-none kind=%lld attach=%lld\n", (long long)k, (long long)(k == 0 ? kv(UPROBE(obj, "up", 0), NULL) : -1));
	if (k == 0)
		kv(CLOSE(obj), NULL);
	printf("04-unchecked-sha kind=%lld\n", (long long)kv(UNCHECKED(up, un, "00", UP_MAPS, ""), NULL));
	printf("05-unchecked-maps kind=%lld\n", (long long)kv(UNCHECKED(up, un, argv[4], UP_MAPS_BAD, ""), NULL));
	k = kv(LOAD(to, tn, argv[2], TO_MAPS, CFG, ""), &obj);
	printf("06-load-to kind=%lld\n", (long long)k);
	raw("07-set-raw", SET_RAW(obj, "want", 9));
	k = kv(GGET(obj, G_WANT), &v);
	printf("08-global-get kind=%lld value=%lld\n", (long long)k, (long long)v);
	printf("09-set-raw-nope kind=%lld\n", (long long)kv(SET_RAW(obj, "nope", 1), NULL));
	printf("10-freeze kind=%lld\n", (long long)kv(FREEZE(obj, "cnt"), NULL));
	printf("11-put-frozen kind=%lld\n", (long long)kv(PUT(obj, M_CNT, 0, 5), NULL));
	printf("12-get-frozen kind=%lld\n", (long long)kv(GET(obj, M_CNT, 0), NULL));
	printf("13-freeze-again kind=%lld\n", (long long)kv(FREEZE(obj, "cnt"), NULL));
	printf("14-freeze-nope kind=%lld\n", (long long)kv(FREEZE(obj, "nope"), NULL));
	printf("15-close kind=%lld\n", (long long)kv(CLOSE(obj), NULL));
	/* close の後は 1 つずつ (E017 の 1 回目: mojo の global_set_raw は handle の誤りも message に畳み OK — 名指しの差の行を分ける) */
	printf("16a-after-set-raw kind=%lld\n", (long long)kv(SET_RAW(obj, "want", 1), NULL));
	printf("16b-after-freeze kind=%lld\n", (long long)kv(FREEZE(obj, "cnt"), NULL));
	printf("16c-after-fault kind=%lld\n", (long long)kv(FAULT(obj, "ev"), NULL));
	pid_t pid = fork();
	if (pid == 0) {
		setenv("ASAN_OPTIONS", "handle_segv=0", 1);
		freopen("/dev/null", "w", stderr); /* 子の落ちる時の文 (Go の runtime の trace 等) は比べない */
		execl("/proc/self/exe", argv[0], "fault", argv[1], argv[2], (char *)NULL);
		_exit(5);
	}
	int st = 0;
	waitpid(pid, &st, 0);
	printf("17-fault-child %s=%d\n", WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
	targets_doc(doc, sizeof doc, "up", argv[5]);
	k = kv(LOAD(up, un, argv[4], UP_MAPS, "", doc), &obj);
	printf("18-load-up kind=%lld\n", (long long)k);
	printf("19-mode-bogus kind=%lld\n", (long long)kv(UMODE("bogus"), NULL));
	struct child c = {0};
	child_start(&c, argv[5]);
	const char *modes[3] = {"no_p_offset", "vaddr", ""};
	for (int i = 0; i < 3; i++) {
		int64_t mk = kv(UMODE(modes[i]), NULL), ak = kv(UPROBE(obj, "up", 0), &l);
		child_call(&c, 1, 1);
		int64_t hk = kv(GET(obj, M_HITS, 0), &v);
		printf("2%d-mode-%s kinds=%lld,%lld hits=%lld/%lld\n", i, modes[i][0] ? modes[i] : "correct", (long long)mk, (long long)ak, (long long)hk,
		       (long long)v);
		if (ak == 0)
			kv(DETACH(l), NULL);
	}
	const char *syms[2] = {"main", ""};
	for (int i = 0; i < 2; i++) {
		int64_t sk = kv(USYM("up", syms[i]), NULL), ak = kv(UPROBE(obj, "up", 0), &l);
		child_call(&c, 1, 1);
		int64_t hk = kv(GET(obj, M_HITS, 0), &v);
		printf("3%d-sym-%s kinds=%lld,%lld hits=%lld/%lld\n", i, syms[i][0] ? syms[i] : "reset", (long long)sk, (long long)ak, (long long)hk,
		       (long long)v);
		if (ak == 0)
			kv(DETACH(l), NULL);
	}
	child_stop(&c);
	printf("40-close kind=%lld\n", (long long)kv(CLOSE(obj), NULL));
	free(to);
	free(up);
	return 0;
}
