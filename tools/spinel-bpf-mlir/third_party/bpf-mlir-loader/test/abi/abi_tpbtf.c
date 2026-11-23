/* abi_tpbtf — E024 の契約の試験: tp_btf の attach (raw tracepoint の link の info の照らし)・tracing の test run の EFAULT と hint・実の trigger
 * (sched_process_fork — 試験が fork する)。予測は E024 (走らせる前に commit)。試験の build (bml_testonly_ — asan / mut) だけ。
 *
 *   abi_tpbtf <e24tc.bpf.o> <sha> <e24tp.bpf.o> <sha> <checked|ptrnull>     (root、unshare -n の中。変異は BML_MUTANT で)
 * checked: 照合する load が通る target (7.1.8・6.12.111)。ptrnull: struct の引数の tp_btf の照合が arg_nullable で止まる target (6.6.157 — E027 の
 * 判定の版 6。E024 の版 5 では e24tc も止まり、試験の口の照合しない load で続けた) — e24tp の止まりを確かめる。各 case は "<id>: … — ok|FAIL" の 1 行 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bml/bml.h"
#include "bml/bml_testonly.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"globals\":[],\"maps\":[" M_HITS "]}"
#define NULLABLE "the target's verifier does not mark NULL-able tracepoint arguments"
#define HINT "hint: this kernel does not test-run tp_btf programs — trigger the tracepoint instead (bpf_prog_test_run_tracing)"

static int fails, oks;
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
	oks += !!good;
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

static uint64_t hit(int64_t obj, int k)
{
	struct res r = take(bml_map_get_bits(obj, S(M_HITS), k));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}

/* fork を n 回 (子は即 _exit)。最後の子の pid */
static pid_t forks(int n)
{
	pid_t last = 0;
	for (int i = 0; i < n; i++) {
		pid_t c = fork();
		if (c == 0)
			_exit(0);
		if (c > 0) {
			waitpid(c, NULL, 0);
			last = c;
		}
	}
	return last;
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

static struct res load(const char *path, const char *sha, int unchecked)
{
	int64_t n = 0;
	uint8_t *elf = slurp(path, &n);
	struct res r = unchecked ? take(bml_testonly_load_unchecked_targets(elf, n, S(sha), S(MAPS), "", 0, "", 0))
				 : take(bml_load_checked(elf, n, S(sha), S(MAPS), 0));
	free(elf);
	return r;
}

/* e24tc (全ての fork を数える tc と fentry の fe) */
static void run_tc(int64_t o)
{
	/* T1・T2: 種類の取り違え */
	struct res a = take(bml_attach_tp_btf(o, S("fe"))), b = take(bml_attach_fentry(o, S("tc")));
	check("T1", a.kind == 6 && strstr(a.msg, "fentry program, not tp_btf"), "attach_tp_btf(fe) %lld \"%s\"", (long long)a.kind, a.msg);
	check("T2", b.kind == 6 && strstr(b.msg, "is a tp_btf program"), "attach_fentry(tc) %lld \"%s\"", (long long)b.kind, b.msg);
	/* T3: tp_btf の test run は kernel が EFAULT — BML_OTHER と hint */
	struct res r = take(bml_test_run_tracing(o, S("tc"), 1));
	check("T3", r.kind == 5 && strstr(r.msg, "bad address") && strstr(r.msg, HINT), "test_run_tracing(tc) %lld \"%s\"", (long long)r.kind, r.msg);
	/* T4: fentry の test run は走る (hint は無い) */
	struct res lf = take(bml_attach_fentry(o, S("fe")));
	r = take(bml_test_run_tracing(o, S("fe"), 1));
	uint64_t h2 = hit(o, 2);
	check("T4", lf.kind == 0 && r.kind == 0 && h2 == 1 && !strstr(r.msg, "hint"), "attach %lld, run %lld \"%s\", hits 2=%llu", (long long)lf.kind,
	      (long long)r.kind, r.msg, (unsigned long long)h2);
	take(bml_detach(lf.value));
	/* T5: attach と実の trigger (全ての fork — 8 以上) */
	struct res l = take(bml_attach_tp_btf(o, S("tc")));
	uint64_t h0 = hit(o, 0);
	forks(8);
	uint64_t h1 = hit(o, 0);
	check("T5", l.kind == 0 && h1 >= h0 + 8, "attach %lld \"%s\", hits 0 %llu -> %llu", (long long)l.kind, l.msg, (unsigned long long)h0,
	      (unsigned long long)h1);
	/* T6: detach の後は数えない (全ての fork — 差 0) */
	struct res d = take(bml_detach(l.value));
	h0 = hit(o, 0);
	forks(8);
	h1 = hit(o, 0);
	check("T6", d.kind == 0 && h1 == h0, "detach %lld, hits 0 %llu -> %llu", (long long)d.kind, (unsigned long long)h0, (unsigned long long)h1);
	/* T7: 宣言を別の tracepoint に差し替えると照らしが違いを捕まえて detach */
	take(bml_testonly_tpbtf_declared(S("sched_switch")));
	l = take(bml_attach_tp_btf(o, S("tc")));
	take(bml_testonly_tpbtf_declared("", 0));
	h0 = hit(o, 0);
	forks(8);
	h1 = hit(o, 0);
	check("T7", l.kind == 5 && strstr(l.msg, "the kernel attached it to sched_process_fork, but the ELF declares sched_switch (detached)") && h1 == h0,
	      "attach %lld \"%s\", hits 0 %llu -> %llu", (long long)l.kind, l.msg, (unsigned long long)h0, (unsigned long long)h1);
	if (l.kind == 0)
		take(bml_detach(l.value));
	/* T8: 無い program */
	a = take(bml_attach_tp_btf(o, S("nope")));
	check("T8", a.kind == 6, "attach_tp_btf(nope) %lld \"%s\"", (long long)a.kind, a.msg);
}

/* e24tp (親の tgid が hits[7] の fork だけを数え、hits[1] に子の pid) */
static void run_tp(int64_t o)
{
	take(bml_map_put_bits(o, S(M_HITS), 7, getpid()));
	struct res r = take(bml_test_run_tracing(o, S("tp"), 1));
	uint64_t h0 = hit(o, 0);
	check("P1", r.kind == 5 && strstr(r.msg, "bad address") && strstr(r.msg, HINT) && h0 == 0, "test_run_tracing(tp) %lld \"%s\", hits 0=%llu",
	      (long long)r.kind, r.msg, (unsigned long long)h0);
	struct res l = take(bml_attach_tp_btf(o, S("tp")));
	pid_t last = forks(8);
	h0 = hit(o, 0);
	uint64_t h1 = hit(o, 1);
	check("P2", l.kind == 0 && h0 == 8 && h1 == (uint64_t)last, "attach %lld \"%s\", hits 0=%llu 1=%llu (last child %d)", (long long)l.kind, l.msg,
	      (unsigned long long)h0, (unsigned long long)h1, last);
	struct res d = take(bml_detach(l.value));
	forks(8);
	h0 = hit(o, 0);
	check("P3", d.kind == 0 && h0 == 8, "detach %lld, hits 0=%llu", (long long)d.kind, (unsigned long long)h0);
	take(bml_testonly_tpbtf_declared(S("sched_switch")));
	l = take(bml_attach_tp_btf(o, S("tp")));
	take(bml_testonly_tpbtf_declared("", 0));
	forks(8);
	h0 = hit(o, 0);
	check("P4", l.kind == 5 && strstr(l.msg, "(detached)") && h0 == 8, "attach %lld \"%s\", hits 0=%llu", (long long)l.kind, l.msg,
	      (unsigned long long)h0);
	if (l.kind == 0)
		take(bml_detach(l.value));
}

int main(int argc, char **argv)
{
	if (argc != 6 || (strcmp(argv[5], "checked") && strcmp(argv[5], "ptrnull"))) {
		fprintf(stderr, "abi_tpbtf <e24tc.bpf.o> <sha> <e24tp.bpf.o> <sha> <checked|ptrnull>\n");
		return 2;
	}
	/* ptrnull: 印さない target (6.6.157) — 判定の版 6 (E027) で struct の引数を読む e24tp だけが止まる (Unmet は struct の index ごと —
	 * BML_TARGET_REJECTED)、読まない引数だけの e24tc は照合する load が通る (版 5 の E024 では e24tc も止まり、照合しない load で続けた) */
	int ptrnull = !strcmp(argv[5], "ptrnull");
	/* 埋め込みの object は同時に 1 つ — 1 つずつ load して閉じる */
	struct res tc = load(argv[1], argv[2], 0);
	check("L1", tc.kind == 0, "e24tc %lld \"%s\"", (long long)tc.kind, tc.msg);
	if (tc.kind == 0) {
		run_tc(tc.value);
		take(bml_close(tc.value));
	}
	struct res tp = load(argv[3], argv[4], 0);
	if (ptrnull) {
		check("L2", tp.kind == 3 && strstr(tp.msg, NULLABLE) && strstr(tp.msg, "reads pointer argument 0 of tracepoint sched_process_fork") &&
				    strstr(tp.msg, "reads pointer argument 1 of tracepoint sched_process_fork"),
		      "e24tp %lld \"%s\"", (long long)tp.kind, tp.msg);
		if (tp.kind == 0)
			take(bml_close(tp.value));
	} else {
		check("L2", tp.kind == 0, "e24tp %lld \"%s\"", (long long)tp.kind, tp.msg);
		if (tp.kind == 0) {
			run_tp(tp.value);
			take(bml_close(tp.value));
		}
	}
	printf("abi_tpbtf: ok %d, FAIL %d\n", oks, fails);
	return fails ? 1 : 0;
}
