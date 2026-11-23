/* abi_testonly — E017 の試験: 試験の build だけの口 (照合しない load・global への直の書き込み・freeze・ring buffer の故意の fault・uprobe の
 * attach の変異 — 予測は E017、走らせる前に commit)。-DBML_TEST_CAPS の build (asan・mut) だけ。
 *
 *   abi_testonly <to.bpf.o> <sha> <up.bpf.o> <up の sha> <fixture> <fixture_other>     (root、unshare -n の中)
 *   abi_testonly fault <to.bpf.o> <sha>       (T5 の子 — 戻らない) */
#define _GNU_SOURCE
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/wait.h>

#include "bml/bml.h"
#include "bml/bml_testonly.h"
#include "up_fixture.h"

#define M_CNT "{\"name\":\"cnt\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define M_EV "{\"name\":\"ev\",\"kind\":\"ringbuf\",\"key\":\"-\",\"value\":\"record:evr\",\"max_entries\":4096}"
#define G_WANT "{\"name\":\"want\",\"section\":\"rodata\",\"type\":\"u64\"}"
#define TO_MAPS "{\"globals\":[" G_WANT "],\"maps\":[" M_CNT "," M_EV "]}"
#define UP_MAPS_BAD "{\"maps\":[{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":5}]}"

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

static uint8_t *to_elf, *up_elf;
static int64_t to_n, up_n;

static int64_t load_to(const char *sha)
{
	struct res r = take(bml_load_checked_config(to_elf, to_n, S(sha), S(TO_MAPS), S("{\"set\":{\"want\":7}}"), 0));
	return r.kind == 0 ? r.value : -r.kind;
}

static uint64_t hit0(int64_t obj)
{
	struct res r = take(bml_map_get_bits(obj, S(M_HITS), 0));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "fault")) { /* T5 の子 */
		to_elf = slurp(argv[2], &to_n);
		int64_t obj = load_to(argv[3]);
		if (obj <= 0)
			return 3;
		take(bml_testonly_ringbuf_fault(obj, S("ev")));
		return 4; /* 届かない */
	}
	if (argc != 7) {
		fprintf(stderr, "abi_testonly <to.bpf.o> <sha> <up.bpf.o> <up sha> <fixture> <fixture_other>\n");
		return 2;
	}
	to_elf = slurp(argv[1], &to_n);
	up_elf = slurp(argv[3], &up_n);
	const char *to_sha = argv[2], *up_sha = argv[4], *bin = argv[5], *other = argv[6];
	char doc[4096];
	/* T1: 照合しない load — 別の binary の target (照合は binary で止める) と target 無し */
	targets_doc(doc, sizeof doc, "up", other);
	struct res c1 = take(bml_load_checked_targets(up_elf, up_n, S(up_sha), S(UP_MAPS), NULL, 0, S(doc), 0));
	struct res u1 = take(bml_testonly_load_unchecked_targets(up_elf, up_n, S(up_sha), S(UP_MAPS), NULL, 0, S(doc)));
	if (u1.kind == 0)
		take(bml_close(u1.value));
	struct res u2 = take(bml_testonly_load_unchecked_targets(up_elf, up_n, S(up_sha), S(UP_MAPS), NULL, 0, NULL, 0));
	struct res a2 = u2.kind == 0 ? take(bml_attach_uprobe(u2.value, S("up"), 0)) : (struct res){-1, 0, ""};
	if (u2.kind == 0)
		take(bml_close(u2.value));
	check("T1", c1.kind == 3 && u1.kind == 0 && u2.kind == 0 && a2.kind == 6, "checked %lld, unchecked (other binary) %lld, unchecked (no target) %lld -> attach %lld",
	      (long long)c1.kind, (long long)u1.kind, (long long)u2.kind, (long long)a2.kind);
	/* T2: 照合しない load も schema・map の宣言は見る */
	struct res s1 = take(bml_testonly_load_unchecked_targets(up_elf, up_n, S("00"), S(UP_MAPS), NULL, 0, NULL, 0)),
		   s2 = take(bml_testonly_load_unchecked_targets(up_elf, up_n, S(up_sha), S(UP_MAPS_BAD), NULL, 0, NULL, 0));
	check("T2", s1.kind == 1 && s2.kind == 8, "sha differs %lld, map declaration differs %lld", (long long)s1.kind, (long long)s2.kind);
	/* T3: global への直の書き込み (.rodata は凍結 — libbpf も kernel も拒否、値は変わらない) */
	int64_t obj = load_to(to_sha);
	struct res w = take(bml_testonly_global_set_raw(obj, S("want"), 9)), g = take(bml_global_get(obj, S(G_WANT))),
		   wn = take(bml_testonly_global_set_raw(obj, S("nope"), 1));
	check("T3", obj > 0 && w.kind == 0 && strncmp(w.msg, "libbpf=nil", 10) && !strstr(w.msg, "kernel=nil") && g.kind == 0 && g.value == 7 && wn.kind == 6,
	      "load %lld, direct write %lld \"%s\", global_get %lld/%lld, nope %lld", (long long)obj, (long long)w.kind, w.msg, (long long)g.kind,
	      (long long)g.value, (long long)wn.kind);
	/* T4: freeze — user 空間の書きは OTHER、読みは OK、2 度目の freeze は OTHER */
	struct res f1 = take(bml_testonly_freeze_map(obj, S("cnt"))), p1 = take(bml_map_put_bits(obj, S(M_CNT), 0, 5)),
		   r1 = take(bml_map_get_bits(obj, S(M_CNT), 0)), f2 = take(bml_testonly_freeze_map(obj, S("cnt"))),
		   fn = take(bml_testonly_freeze_map(obj, S("nope")));
	check("T4", f1.kind == 0 && p1.kind == 5 && r1.kind == 0 && f2.kind == 5 && fn.kind == 6, "freeze %lld, put %lld \"%s\", get %lld, second %lld, nope %lld",
	      (long long)f1.kind, (long long)p1.kind, p1.msg, (long long)r1.kind, (long long)f2.kind, (long long)fn.kind);
	/* C1 (T4 の後): close の後の試験の口は STATE (fault も写像に触れない) */
	take(bml_close(obj));
	int64_t k1 = take(bml_testonly_global_set_raw(obj, S("want"), 1)).kind, k2 = take(bml_testonly_freeze_map(obj, S("cnt"))).kind,
		k3 = take(bml_testonly_ringbuf_fault(obj, S("ev"))).kind;
	check("C1", k1 == 6 && k2 == 6 && k3 == 6, "%lld %lld %lld", (long long)k1, (long long)k2, (long long)k3);
	/* T5: ring buffer の故意の fault — 子の process が SIGSEGV で落ちる (bml は handler を入れない。ASan の SEGV の handler は外す) */
	pid_t pid = fork();
	if (pid == 0) {
		setenv("ASAN_OPTIONS", "handle_segv=0", 1);
		execl("/proc/self/exe", argv[0], "fault", argv[1], argv[2], (char *)NULL);
		_exit(5);
	}
	int st = 0;
	waitpid(pid, &st, 0);
	check("T5", WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV, "child ended: %s %d", WIFSIGNALED(st) ? "signal" : "exit",
	      WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
	/* T6: uprobe の attach の変異 (file offset の計算・symbol の取り違えは attach は通るが数えない) */
	targets_doc(doc, sizeof doc, "up", bin);
	struct res ul = take(bml_load_checked_targets(up_elf, up_n, S(up_sha), S(UP_MAPS), NULL, 0, S(doc), 0));
	obj = ul.value;
	struct child c = {0};
	child_start(&c, bin);
	uint64_t h[4];
	int64_t ak[4], bad = take(bml_testonly_uprobe_offset_mode(S("bogus"))).kind;
	const char *modes[2] = {"no_p_offset", ""};
	for (int i = 0; i < 2; i++) {
		take(bml_testonly_uprobe_offset_mode(S(modes[i])));
		struct res a = take(bml_attach_uprobe(obj, S("up"), 0));
		ak[i] = a.kind;
		child_call(&c, 1, 1);
		h[i] = hit0(obj);
		take(bml_detach(a.value));
	}
	const char *syms[2] = {"main", ""};
	for (int i = 0; i < 2; i++) {
		take(bml_testonly_uprobe_symbol(S("up"), S(syms[i])));
		struct res a = take(bml_attach_uprobe(obj, S("up"), 0));
		ak[2 + i] = a.kind;
		child_call(&c, 1, 1);
		h[2 + i] = hit0(obj);
		take(bml_detach(a.value));
	}
	child_stop(&c);
	take(bml_close(obj));
	check("T6", ul.kind == 0 && bad == 5 && ak[0] == 0 && ak[1] == 0 && ak[2] == 0 && ak[3] == 0 && h[0] == 0 && h[1] == 1 && h[2] == 1 && h[3] == 2,
	      "load %lld, bogus %lld, no_p_offset %lld -> %llu, restore %lld -> %llu, main %lld -> %llu, restore %lld -> %llu", (long long)ul.kind, (long long)bad,
	      (long long)ak[0], (unsigned long long)h[0], (long long)ak[1], (unsigned long long)h[1], (long long)ak[2], (unsigned long long)h[2],
	      (long long)ak[3], (unsigned long long)h[3]);
	free(to_elf);
	free(up_elf);
	printf("abi_testonly: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
