/* abi_up — E015 の契約の試験: uprobe の target 付きの load・attach・link の file (予測は E015 — 走らせる前に commit)。
 *
 *   abi_up <up.bpf.o> <sha> <fixture> <fixture_other> <argsum.bpf.o> <argsum の sha>     (root、unshare -n の中)
 * fixture は bpf-mlir kernel/uprobe/fixture/bin/fixture (up の binary の sha256)、fixture_other は同じ入出力の別の binary。各 case は
 * "<id>: … — ok|FAIL" の 1 行 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdlib.h>

#include "bml/bml.h"
#include "up_fixture.h"

#define M_H(n) "{\"name\":\"" n "\",\"kind\":\"hash\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":1024}"
#define AS_MAPS "{\"maps\":[" M_H("counts") "," M_H("suma") "," M_H("sumb") "]}"

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
	int64_t kind, value, n_unmet;
	char msg[2048], unmet0[64];
};
static struct res take(int64_t r)
{
	struct res x = {bml_result_kind(r), bml_result_value(r), bml_result_unmet_count(r), "", ""};
	int64_t n = 0;
	const char *m = bml_result_message(r, &n);
	snprintf(x.msg, sizeof x.msg, "%.*s", (int)n, m ? m : "");
	if (x.n_unmet > 0) {
		const char *u = bml_result_unmet_field(r, 0, 0, &n);
		snprintf(x.unmet0, sizeof x.unmet0, "%.*s", (int)n, u ? u : "");
	}
	bml_result_free(r);
	return x;
}

static uint8_t *elf;
static int64_t elf_n;
static const char *sha;
static int64_t obj;

static struct res load(const char *targets)
{
	struct res r = take(bml_load_checked_targets(elf, elf_n, S(sha), S(UP_MAPS), NULL, 0, S(targets), 0));
	if (r.kind == 0)
		obj = r.value;
	return r;
}
static uint64_t hit(int k)
{
	struct res r = take(bml_map_get_bits(obj, S(M_HITS), k));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}

int main(int argc, char **argv)
{
	if (argc != 7) {
		fprintf(stderr, "abi_up <up.bpf.o> <sha> <fixture> <fixture_other> <argsum.bpf.o> <argsum sha>\n");
		return 2;
	}
	elf = slurp(argv[1], &elf_n);
	sha = argv[2];
	const char *bin = argv[3], *other = argv[4];
	char doc[4096], real[4096];
	if (!realpath(bin, real))
		snprintf(real, sizeof real, "%s", bin);
	/* U5: load の誤り (各々 object を作らない) */
	targets_doc(doc, sizeof doc, "xp", bin);
	struct res e[6] = {
		load(""), load("{"), load(doc), load("{\"uprobe_targets\":[{\"program\":\"up\",\"path\":\"/nonexistent/bml\"}]}"),
		(targets_doc(doc, sizeof doc, "up", other), load(doc)),
		load("{\"uprobe_targets\":[{\"program\":\"up\",\"path\":\"/bin/true\"},{\"program\":\"up\",\"path\":\"/bin/true\"}]}"),
	};
	check("U5", e[0].kind == 3 && !strcmp(e[0].unmet0, "binary_unknown") && e[1].kind == 2 && e[2].kind == 5 && e[3].kind == 5 && e[4].kind == 3 &&
			    !strcmp(e[4].unmet0, "binary") && e[5].kind == 2,
	      "none %lld %s, unreadable %lld, xp %lld, missing path %lld, other binary %lld %s, two %lld", (long long)e[0].kind, e[0].unmet0, (long long)e[1].kind,
	      (long long)e[2].kind, (long long)e[3].kind, (long long)e[4].kind, e[4].unmet0, (long long)e[5].kind);
	/* U1 */
	targets_doc(doc, sizeof doc, "up", bin);
	struct res r = load(doc);
	check("U1", r.kind == 0 && r.n_unmet == 0, "load %lld \"%s\"", (long long)r.kind, r.msg);
	if (r.kind != 0)
		return 1;
	/* U2: pid 0 (全ての process) — 子の 3 回の呼び出しを数える */
	struct child c;
	child_start(&c, bin);
	struct res a = take(bml_attach_uprobe(obj, S("up"), 0)), f = take(bml_uprobe_link_file(obj, a.value));
	long long s1 = child_call(&c, 1, 2), s2 = child_call(&c, 3, 4), s3 = child_call(&c, 5, 6);
	uint64_t h0 = hit(0), h1 = hit(1);
	check("U2", a.kind == 0 && f.kind == 0 && !strncmp(f.msg, "/proc/self/fd/", 14) && s1 == 3 && s2 == 7 && s3 == 11 && h0 == 3 &&
			    h1 == ((uint64_t)c.pid << 32 | (uint32_t)c.pid),
	      "attach %lld \"%s\", file %lld \"%s\" (want /proc/self/fd/N; info is the path passed to attach, realpath %s), calls %lld %lld %lld, hits 0=%llu 1=%#llx (child %d)", (long long)a.kind, a.msg,
	      (long long)f.kind, f.msg, real, s1, s2, s3, (unsigned long long)h0, (unsigned long long)h1, c.pid);
	/* U3: detach の後は数えない → pid = 子で attach は数える → pid = この process は子を数えない */
	struct res d = take(bml_detach(a.value));
	child_call(&c, 1, 1);
	uint64_t after_detach = hit(0);
	struct res pc = take(bml_attach_uprobe(obj, S("up"), c.pid));
	child_call(&c, 1, 1);
	uint64_t with_pid = hit(0);
	struct res pd = take(bml_detach(pc.value)), ps = take(bml_attach_uprobe(obj, S("up"), getpid()));
	child_call(&c, 1, 1);
	uint64_t other_pid = hit(0);
	take(bml_detach(ps.value));
	check("U3", d.kind == 0 && after_detach == 3 && pc.kind == 0 && with_pid == 4 && pd.kind == 0 && ps.kind == 0 && other_pid == 4,
	      "detach %lld -> %llu, pid child %lld -> %llu, pid self %lld -> %llu", (long long)d.kind, (unsigned long long)after_detach, (long long)pc.kind,
	      (unsigned long long)with_pid, (long long)ps.kind, (unsigned long long)other_pid);
	child_stop(&c);
	/* U4: 取り違えと誤り */
	struct res x = take(bml_attach_xdp(obj, S("xp"), S("lo")));
	int64_t k[6] = {
		take(bml_attach_uprobe(obj, S("xp"), 0)).kind, take(bml_attach_uprobe(obj, S("up"), -1)).kind,
		take(bml_attach_kprobe(obj, S("up"))).kind,    take(bml_uprobe_link_file(obj, x.value)).kind,
		take(bml_uprobe_link_file(obj, 987654)).kind,  take(bml_attach_uprobe(obj, S("nope"), 0)).kind,
	};
	take(bml_detach(x.value));
	check("U4", k[0] == 6 && k[1] == 5 && k[2] == 6 && k[3] == 6 && k[4] == 6 && k[5] == 6, "%lld %lld %lld %lld %lld %lld", (long long)k[0],
	      (long long)k[1], (long long)k[2], (long long)k[3], (long long)k[4], (long long)k[5]);
	/* C1: close の後 */
	take(bml_close(obj));
	int64_t c1 = take(bml_attach_uprobe(obj, S("up"), 0)).kind, c2 = take(bml_uprobe_link_file(obj, a.value)).kind;
	check("C1", c1 == 6 && c2 == 6, "%lld %lld", (long long)c1, (long long)c2);
	/* U6: 引数を読む uprobe (bpf-mlir の arg_sum) — E008 (DWARF の reader) の後は load する (E015 の前の契約は uprobearg_unknown — E008 H4 の予測) */
	int64_t an = 0;
	uint8_t *as = slurp(argv[5], &an);
	targets_doc(doc, sizeof doc, "prog", bin);
	struct res u6 = take(bml_load_checked_targets(as, an, S(argv[6]), S(AS_MAPS), NULL, 0, S(doc), 0));
	if (u6.kind == 0)
		take(bml_close(u6.value));
	check("U6", u6.kind == 0 && u6.n_unmet == 0, "load %lld, Unmet %lld first %s", (long long)u6.kind, (long long)u6.n_unmet,
	      u6.unmet0);
	free(as);
	free(elf);
	printf("abi_up: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
