/* up_diff — E015 の差動の driver: uprobe の target 付きの load・attach・link の file を mojo の Go の loader (試験の c-archive — -DMOJO) か bml に。
 * 各段を 1 行で印字し scripts/abi-mojo-diff.sh が比べる (link の file は realpath と同じかの真偽で — 文は比べない)。
 *
 *   up_diff <up.bpf.o> <sha> <fixture> <fixture_other> <argsum.bpf.o> <argsum の sha>     (root、unshare -n の中) */
#define _GNU_SOURCE
#include <stdlib.h>

#include "up_fixture.h"

#define M_H(n) "{\"name\":\"" n "\",\"kind\":\"hash\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":1024}"
#define AS_MAPS "{\"maps\":[" M_H("counts") "," M_H("suma") "," M_H("sumb") "]}"

#ifdef MOJO
/* mojo-bpf-mlir loader/main.go の export (5a53a6d) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
int64_t mojobpf_result_message(int64_t, char *, int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_attach_uprobe(int64_t, const char *, int64_t, int64_t);
int64_t mojobpf_uprobe_link_file(int64_t, int64_t);
int64_t mojobpf_attach_kprobe(int64_t, const char *, int64_t);
int64_t mojobpf_attach_xdp(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_detach(int64_t);
int64_t mojobpf_map_get(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define R_MSG(r, b, c) mojobpf_result_message(r, b, c)
#define LOAD(e, n, sha, maps, t) mojobpf_load_checked_targets(e, n, S(sha), S(maps), "", 0, S(t), "", 0, 0)
#define UPROBE(o, p, pid) mojobpf_attach_uprobe(o, S(p), pid)
#define LFILE mojobpf_uprobe_link_file
#define KPROBE(o, p) mojobpf_attach_kprobe(o, S(p))
#define XDP(o, p, i) mojobpf_attach_xdp(o, S(p), S(i))
#define DETACH mojobpf_detach
#define GET(o, k) mojobpf_map_get(o, S(M_HITS), k)
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define R_MSG(r, b, c) bml_result_message_copy(r, b, c)
#define LOAD(e, n, sha, maps, t) bml_load_checked_targets(e, n, S(sha), S(maps), NULL, 0, S(t), 0)
#define UPROBE(o, p, pid) bml_attach_uprobe(o, S(p), pid)
#define LFILE bml_uprobe_link_file
#define KPROBE(o, p) bml_attach_kprobe(o, S(p))
#define XDP(o, p, i) bml_attach_xdp(o, S(p), S(i))
#define DETACH bml_detach
#define GET(o, k) bml_map_get_bits(o, S(M_HITS), k)
#define CLOSE bml_close
#endif

static int64_t obj;
static char real[4096];
static struct child c;

static int64_t kv(int64_t r, int64_t *value)
{
	int64_t k = R_KIND(r);
	if (value)
		*value = R_VALUE(r);
	R_FREE(r);
	return k;
}

static void lfile(const char *step, int64_t link)
{
	int64_t r = LFILE(obj, link), k = R_KIND(r);
	char m[4096] = "";
	if (k == 0) {
		int64_t n = R_MSG(r, m, (int64_t)sizeof m - 1);
		m[n < (int64_t)sizeof m - 1 ? n : (int64_t)sizeof m - 1] = 0;
	}
	R_FREE(r);
	printf("%s kind=%lld file=%s\n", step, (long long)k, k != 0 ? "-" : !strcmp(m, real) ? "realpath" : !strncmp(m, "/proc/self/fd/", 14) ? "fdpath" : "other");
}

static void hits(const char *step)
{
	int64_t v0 = 0, v1 = 0, k0 = kv(GET(obj, 0), &v0), k1 = kv(GET(obj, 1), &v1);
	uint64_t u1 = (uint64_t)v1;
	printf("%s hits kinds=%lld,%lld 0=%lld 1=%s\n", step, (long long)k0, (long long)k1, (long long)v0,
	       !u1 ? "0" : u1 == ((uint64_t)c.pid << 32 | (uint32_t)c.pid) ? "child" : "other");
}

int main(int argc, char **argv)
{
	if (argc != 7) {
		fprintf(stderr, "up_diff <up.bpf.o> <sha> <fixture> <fixture_other> <argsum.bpf.o> <argsum sha>\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	const char *sha = argv[2], *bin = argv[3], *other = argv[4];
	if (!realpath(bin, real))
		snprintf(real, sizeof real, "%s", bin);
	char doc[4096];
	printf("01-load-none kind=%lld\n", (long long)kv(LOAD(elf, n, sha, UP_MAPS, ""), NULL));
	printf("02-load-unreadable kind=%lld\n", (long long)kv(LOAD(elf, n, sha, UP_MAPS, "{"), NULL));
	targets_doc(doc, sizeof doc, "xp", bin);
	printf("03-load-xp kind=%lld\n", (long long)kv(LOAD(elf, n, sha, UP_MAPS, doc), NULL));
	printf("04-load-nopath kind=%lld\n",
	       (long long)kv(LOAD(elf, n, sha, UP_MAPS, "{\"uprobe_targets\":[{\"program\":\"up\",\"path\":\"/nonexistent/bml\"}]}"), NULL));
	targets_doc(doc, sizeof doc, "up", other);
	printf("05-load-other kind=%lld\n", (long long)kv(LOAD(elf, n, sha, UP_MAPS, doc), NULL));
	printf("06-load-dup kind=%lld\n",
	       (long long)kv(LOAD(elf, n, sha, UP_MAPS, "{\"uprobe_targets\":[{\"program\":\"up\",\"path\":\"/bin/true\"},{\"program\":\"up\",\"path\":\"/bin/true\"}]}"),
			     NULL));
	targets_doc(doc, sizeof doc, "up", bin);
	int64_t k = kv(LOAD(elf, n, sha, UP_MAPS, doc), &obj);
	printf("07-load kind=%lld\n", (long long)k);
	if (k != 0)
		return 1;
	child_start(&c, bin);
	int64_t l = 0;
	printf("08-attach-0 kind=%lld\n", (long long)kv(UPROBE(obj, "up", 0), &l));
	lfile("09-link-file", l);
	printf("10-calls %lld %lld %lld\n", child_call(&c, 1, 2), child_call(&c, 3, 4), child_call(&c, 5, 6));
	hits("11");
	printf("12-detach kind=%lld\n", (long long)kv(DETACH(l), NULL));
	child_call(&c, 1, 1);
	hits("13");
	printf("14-attach-child kind=%lld\n", (long long)kv(UPROBE(obj, "up", c.pid), &l));
	child_call(&c, 1, 1);
	hits("15");
	printf("16-detach kind=%lld\n", (long long)kv(DETACH(l), NULL));
	printf("17-attach-self kind=%lld\n", (long long)kv(UPROBE(obj, "up", getpid()), &l));
	child_call(&c, 1, 1);
	hits("18");
	printf("19-detach kind=%lld\n", (long long)kv(DETACH(l), NULL));
	child_stop(&c);
	int64_t lx = 0;
	printf("20-xdp kind=%lld\n", (long long)kv(XDP(obj, "xp", "lo"), &lx));
	printf("21-wrong kinds=%lld,%lld,%lld,%lld,%lld,%lld\n", (long long)kv(UPROBE(obj, "xp", 0), NULL), (long long)kv(UPROBE(obj, "up", -1), NULL),
	       (long long)kv(KPROBE(obj, "up"), NULL), (long long)kv(LFILE(obj, lx), NULL), (long long)kv(LFILE(obj, 987654), NULL),
	       (long long)kv(UPROBE(obj, "nope", 0), NULL));
	kv(DETACH(lx), NULL);
	printf("22-close kind=%lld\n", (long long)kv(CLOSE(obj), NULL));
	printf("23-after kinds=%lld,%lld\n", (long long)kv(UPROBE(obj, "up", 0), NULL), (long long)kv(LFILE(obj, l), NULL));
	int64_t an = 0, ao = 0;
	uint8_t *as = slurp(argv[5], &an);
	targets_doc(doc, sizeof doc, "prog", bin);
	int64_t ak = kv(LOAD(as, an, argv[6], AS_MAPS, doc), &ao);
	printf("24-argsum kind=%lld\n", (long long)ak);
	if (ak == 0)
		kv(CLOSE(ao), NULL);
	free(as);
	free(elf);
	return 0;
}
