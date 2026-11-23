/* netkit_run — E067 H7〜H9: netkit の停止と実 device (VM の root — 試験の build だけ、arm ごとに新しい netns — unshare -n の中)。
 *
 *   netkit_run stop <primary|peer> false <elf> <sha>        H7: 既知の false の停止 (Unknown の形は偵察の後の追補で足す)
 *   netkit_run arm <primary|peer> <pass|drop> <elf> <sha>   H8: 4 phase
 *   netkit_run neg <veth|peerdev> <elf> <sha>               H8: 負 (pass の ELF)
 *   netkit_run mismatch <elf> <sha>                         H9: BML_MUTANT の強制の mismatch。観測 netkit_link_gone / netkit_link_remains を出す
 *
 * want は bpf-mlir E650 の実測と同じ。観測の前に raw の Info を出す。各 check は "<id>: … — ok|FAIL" の 1 行。入力・環境の故障は rc 2。 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <inttypes.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>

#include "bml/bml.h"
#include "run_own.h"
#include "tcx_fixture.h"

#define FRAMES 8
#define RECV_WINDOW_MS 1000 /* 届く frame を数える有限の窓 (drop の 0 はこの窓の満了までの観測) */
#define GONE_MS 15000	    /* own の link の消失の期限 */
#define D_STATS "{\"name\":\"stats\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":1}"
#define MAPS "{\"maps\":[" D_STATS "]}"
#define PRI "nkp0"
#define PEE "nkq0"

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
	run_flush();
	fails += !good;
}

static int finish(const char *tool)
{
	printf("%s: FAIL %d\n", tool, fails);
	run_flush();
	return fails || run_out_failed ? 1 : 0;
}

static int sh(const char *cmd)
{
	int rc = system(cmd);
	printf("# %s rc=%d\n", cmd, rc);
	run_flush();
	return rc;
}

static int make_pair(void)
{
	return sh("ip link set lo up") || sh("ip link add " PRI " type netkit mode l2 peer name " PEE) || sh("ip link set " PRI " up") || sh("ip link set " PEE " up");
}

static int packet_sock(unsigned ifindex)
{
	int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (fd < 0)
		return -1;
	struct sockaddr_ll a = {.sll_family = AF_PACKET, .sll_protocol = htons(ETH_P_ALL), .sll_ifindex = (int)ifindex};
	if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void frame64(uint8_t f[64], int dirbyte, int cohort, int seq)
{
	memset(f, 0, 64);
	memset(f, 0x02, 12);
	f[12] = 0x88, f[13] = 0xb5;
	memcpy(f + 14, "E650NK01", 8);
	f[22] = (uint8_t)dirbyte, f[23] = (uint8_t)cohort, f[24] = (uint8_t)seq;
}

static ssize_t rx_read(void *ctx, uint8_t *b, size_t n, int *outgoing)
{
	struct sockaddr_ll ll;
	socklen_t l = sizeof ll;
	ssize_t got = recvfrom(*(int *)ctx, b, n, 0, (struct sockaddr *)&ll, &l);
	if (got < 0)
		return -errno;
	*outgoing = ll.sll_pkttype == PACKET_OUTGOING;
	return got;
}

static int rx_match(const uint8_t *b, ssize_t n, void *arg)
{
	return n >= 25 && b[12] == 0x88 && b[13] == 0xb5 && !memcmp(b + 14, "E650NK01", 8) && b[23] == *(int *)arg;
}

/* sender から FRAMES を qdisc を通さず送り、receiver で同じ cohort の incoming を CLOCK_MONOTONIC の窓の満了まで数える。手順の誤りは -1 で名指し */
static int exchange(unsigned from, unsigned to, int dirbyte, int cohort, int expect_drop, char *why, size_t wn)
{
	int rx = packet_sock(to), tx = packet_sock(from), on = 1, rb = 0, got = -1, err = 0;
	socklen_t rl = sizeof rb;
	if (rx < 0 || tx < 0) {
		snprintf(why, wn, "packet socket: %s", strerror(errno));
		goto out;
	}
	if (setsockopt(tx, SOL_PACKET, PACKET_QDISC_BYPASS, &on, sizeof on) != 0 || getsockopt(tx, SOL_PACKET, PACKET_QDISC_BYPASS, &rb, &rl) != 0 || rb != 1) {
		snprintf(why, wn, "PACKET_QDISC_BYPASS: readback %d (%s)", rb, strerror(errno));
		goto out;
	}
	struct timeval tv = {0, 20000};
	if (setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) != 0) {
		snprintf(why, wn, "SO_RCVTIMEO: %s", strerror(errno));
		goto out;
	}
	struct sockaddr_ll to_a = {.sll_family = AF_PACKET, .sll_ifindex = (int)from, .sll_halen = 6};
	for (int i = 0; i < FRAMES; i++) {
		uint8_t f[64];
		frame64(f, dirbyte, cohort, i);
		ssize_t sent = sendto(tx, f, 64, 0, (struct sockaddr *)&to_a, sizeof to_a);
		int serr = sent < 0 ? errno : 0;
		if (!send_outcome_ok(sent, serr, 64, expect_drop)) {
			snprintf(why, wn, "sendto frame %d: rc %zd errno %d (%s), drop stage %d", i, sent, serr, strerror(serr), expect_drop);
			goto out;
		}
	}
	const struct window_ops w = {rx_read, own_real_now_ms, &rx};
	got = window_count(&w, RECV_WINDOW_MS, rx_match, &cohort, &err);
	if (got < 0)
		snprintf(why, wn, "recvfrom: errno %d", err);
out:
	if (rx >= 0)
		close(rx);
	if (tx >= 0)
		close(tx);
	return got;
}

static int64_t load_msg(int64_t r, int64_t *kind, char *msg, size_t cap)
{
	int64_t ml = 0, n = bml_result_unmet_count(r);
	*kind = bml_result_kind(r);
	const char *m = bml_result_message(r, &ml);
	snprintf(msg, cap, "%.*s", (int)ml, m ? m : "");
	printf("# load kind=%" PRId64 " unmet=%" PRId64, *kind, n);
	for (int64_t i = 0; i < n; i++) {
		const char *k = bml_result_unmet_field(r, i, 0, NULL), *p = bml_result_unmet_field(r, i, 1, NULL), *nm = bml_result_unmet_field(r, i, 2, NULL);
		printf(" %s/%s/%s", k ? k : "", p ? p : "", nm ? nm : "");
	}
	printf(" msg=%s\n", msg);
	run_flush();
	return bml_result_value(r);
}

/* 読めない ELF は *kind = -1 (手順の故障 — 呼び手が rc 2 で止める) */
static int64_t load_raw(const char *path, const char *sha, int64_t *result)
{
	int64_t n = 0;
	uint8_t *elf = slurp(path, &n);
	if (!elf) {
		fprintf(stderr, "netkit_run: cannot read %s\n", path);
		*result = 0;
		return -1;
	}
	*result = bml_load_checked(elf, n, S(sha), S(MAPS), 0);
	free(elf);
	return 0;
}

static uint32_t program_id(int64_t obj)
{
	uint32_t id = 0;
	char e[128] = "";
	if (own_program_id(obj, "filter", &id, e, sizeof e)) {
		printf("# own program id: %s\n", e);
		run_flush();
		return 0;
	}
	return id;
}

static int close_obj(int64_t obj)
{
	int64_t c = bml_close(obj);
	int k = (int)bml_result_kind(c);
	bml_result_free(c);
	return k;
}

static int mode_stop(const char *direction, const char *form, const char *path, const char *sha)
{
	if (strcmp(form, "false") != 0) {
		fprintf(stderr, "netkit_run stop: the want %s is not fixed yet (addendum after the recon)\n", form);
		return 2;
	}
	int64_t r = 0, kind = 0;
	char msg[1024];
	if (load_raw(path, sha, &r))
		return 2;
	int64_t obj = load_msg(r, &kind, msg, sizeof msg);
	const char *uk = bml_result_unmet_field(r, 0, 0, NULL), *up = bml_result_unmet_field(r, 0, 1, NULL), *un = bml_result_unmet_field(r, 0, 2, NULL);
	int ok = stop_is_expected(kind, bml_result_unmet_count(r), uk, up, un, direction);
	bml_result_free(r);
	check("stop", ok, "kind %" PRId64 ", 0 attach calls", kind);
	if (kind == 0) {
		check("stop-load-succeeded", 0, "load succeeded (unexpected — STOP)");
		close_obj(obj);
	}
	return finish("netkit_run");
}

static int phase(const char *id, int64_t obj, uint64_t c_before, unsigned from, unsigned to, int dirbyte, int cohort, uint64_t want_add, int want_got, uint64_t *c_after)
{
	char why[160] = "";
	int d = exchange(from, to, dirbyte, cohort, want_add != 0 && want_got == 0, why, sizeof why);
	int64_t r = bml_map_get_bits(obj, S(D_STATS), 0);
	int ck = (int)bml_result_kind(r);
	uint64_t c = ck == 0 ? (uint64_t)bml_result_value(r) : UINT64_MAX;
	bml_result_free(r);
	*c_after = c;
	check(id, d == want_got && ck == 0 && c == c_before + want_add, "counter %" PRIu64 " → %" PRIu64 " (map kind %d), reached %d (%s)", c_before, c, ck, d, why);
	return d < 0 || ck != 0;
}

struct arm_ctx {
	int primary, drop, dirbyte;
	unsigned p, q, from, to;
	int64_t obj, link;
	uint32_t pid, ids[4];
	struct bpf_link_info li[4];
	int nl;
	uint64_t counter;
};

static int arm_own(void *v)
{
	struct arm_ctx *c = v;
	c->pid = program_id(c->obj);
	check("own-program", c->pid != 0, "program ID %u", c->pid);
	return c->pid == 0;
}

static int arm_phase(void *v, enum arm_phase ph)
{
	static const char *const names[] = {"no-link", "attached", "reverse", "after-close"};
	struct arm_ctx *c = v;
	int rev = ph == ARM_REVERSE, on = ph == ARM_ATTACHED;
	return phase(names[ph], c->obj, c->counter, rev ? c->to : c->from, rev ? c->from : c->to, c->dirbyte, (int)ph + 1, on ? FRAMES : 0, on && c->drop ? 0 : FRAMES, &c->counter);
}

static int arm_attach(void *v)
{
	struct arm_ctx *c = v;
	int64_t ml = 0, a = bml_attach_netkit(c->obj, S("filter"), S(PRI));
	int64_t ak = bml_result_kind(a);
	c->link = bml_result_value(a);
	const char *am = bml_result_message(a, &ml);
	check("attach", ak == 0, "kind %" PRId64 " \"%.*s\"", ak, (int)ml, am ? am : "");
	bml_result_free(a);
	return ak != 0;
}

static int arm_info(void *v)
{
	struct arm_ctx *c = v;
	char err[160] = "";
	memset(c->li, 0, sizeof c->li);
	int cr = own_collect_links(&own_real, c->pid, c->p, c->q, c->ids, c->li, 4, &c->nl, err, sizeof err);
	/* 保存の後で照らす (raw を先に出す) */
	printf("# raw-info rc=%d count=%d err=%s type=%u id=%u prog_id=%u attach_type=%u ifindex=%u own_prog=%u\n", cr, c->nl, err, c->li[0].type, c->ids[0], c->li[0].prog_id,
	       c->li[0].netkit.attach_type, c->li[0].netkit.ifindex, c->pid);
	run_flush();
	check("link-info", cr == 0 && c->nl == 1 && c->li[0].prog_id == c->pid && c->li[0].netkit.attach_type == (c->primary ? BPF_NETKIT_PRIMARY : BPF_NETKIT_PEER) &&
				   c->li[0].netkit.ifindex == (c->primary ? c->p : c->q),
	      "rc %d count %d ifindex %u (%s)", cr, c->nl, c->li[0].netkit.ifindex, err);
	return cr != 0 || c->nl != 1;
}

static int arm_detach(void *v)
{
	struct arm_ctx *c = v;
	char err[160] = "";
	int64_t dt = bml_detach(c->link);
	int dk = (int)bml_result_kind(dt);
	bml_result_free(dt);
	enum own_state st = c->nl == 1 ? own_poll(&own_real, own_real_link_open, c->ids[0], GONE_MS, err, sizeof err) : OWN_UNOBSERVED;
	check("link-gone", dk == 0 && st == OWN_GONE, "detach kind %d, own link %u state %d (%s)", dk, c->ids[0], st, err);
	return dk != 0 || st != OWN_GONE;
}

static int arm_close(void *v)
{
	int bad = close_obj(((struct arm_ctx *)v)->obj) != 0;
	check("close", !bad, "object");
	return bad;
}

static int arm_out(void *v)
{
	(void)v;
	return run_out_failed;
}

static int mode_arm(const char *dir, const char *verdict, const char *elf, const char *sha)
{
	struct arm_ctx c;
	memset(&c, 0, sizeof c);
	c.primary = !strcmp(dir, "primary"), c.drop = !strcmp(verdict, "drop"), c.dirbyte = c.primary ? 1 : 2;
	if (make_pair())
		return 2;
	c.p = if_nametoindex(PRI), c.q = if_nametoindex(PEE), c.from = c.primary ? c.p : c.q, c.to = c.primary ? c.q : c.p;
	printf("# pair primary=%u peer=%u\n", c.p, c.q);
	int64_t r = 0, kind = 0;
	char msg[1024];
	if (load_raw(elf, sha, &r))
		return 2;
	c.obj = load_msg(r, &kind, msg, sizeof msg);
	bml_result_free(r);
	check("load", kind == 0, "kind %" PRId64 " \"%s\"", kind, msg);
	if (kind != 0)
		return finish("netkit_run");
	const struct arm_steps s = {&c, arm_own, arm_phase, arm_attach, arm_info, arm_detach, arm_close, arm_out};
	if (arm_sequence(&s))
		check("arm-stopped", 0, "procedure failure; later steps not run");
	return finish("netkit_run");
}

/* own の program を固定できない・保存できないなら attach を 0 回にして閉じる。止めたら 1 */
static int stopped_before_attach(int64_t obj, uint32_t pid)
{
	check("own-program", pid != 0, "program ID %u", pid);
	if (pid != 0 && !run_out_failed)
		return 0;
	check("close", close_obj(obj) == 0, "object");
	return 1;
}

static int mode_neg(const char *device, const char *elf, const char *sha)
{
	const char *ifn = !strcmp(device, "veth") ? "vtha0" : PEE;
	if (make_pair() || sh("ip link add vtha0 type veth peer name vthb0") || sh("ip link set vtha0 up"))
		return 2;
	unsigned p = if_nametoindex(PRI), q = if_nametoindex(PEE);
	int64_t r = 0, kind = 0, ml = 0;
	char msg[1024], m[1024], err[160] = "";
	if (load_raw(elf, sha, &r))
		return 2;
	int64_t obj = load_msg(r, &kind, msg, sizeof msg);
	bml_result_free(r);
	check("load", kind == 0, "kind %" PRId64 " \"%s\"", kind, msg);
	if (kind != 0)
		return finish("netkit_run");
	uint32_t pid = program_id(obj);
	if (stopped_before_attach(obj, pid))
		return finish("netkit_run");
	int64_t a = bml_attach_netkit(obj, S("filter"), S(ifn));
	int64_t ak = bml_result_kind(a);
	const char *am = bml_result_message(a, &ml);
	snprintf(m, sizeof m, "%.*s", (int)ml, am ? am : "");
	const char *want = !strcmp(device, "veth") ? "not a netkit device" : "pass the primary device";
	check("neg", ak == BML_OTHER && strstr(m, want) != NULL, "kind %" PRId64 " \"%s\"", ak, m);
	bml_result_free(a);
	uint32_t ids[4];
	struct bpf_link_info li[4];
	int nl = 0, cr = own_collect_links(&own_real, pid, p, q, ids, li, 4, &nl, err, sizeof err);
	check("neg-no-link", pid != 0 && cr == 0 && nl == 0, "program %u, rc %d, own link %d (%s)", pid, cr, nl, err);
	check("close", close_obj(obj) == 0, "object");
	return finish("netkit_run");
}

/* H9: BML_MUTANT で強制した mismatch。obj・program・map を持ったまま同じ ID を見続ける (全体の cleanup の前 — 最後に閉じると漏れを隠せる) */
static int mode_mismatch(const char *elf, const char *sha)
{
	if (make_pair())
		return 2;
	unsigned p = if_nametoindex(PRI), q = if_nametoindex(PEE);
	int64_t r = 0, kind = 0, ml = 0;
	char msg[1024], m[1024], err[160] = "";
	if (load_raw(elf, sha, &r))
		return 2;
	int64_t obj = load_msg(r, &kind, msg, sizeof msg);
	bml_result_free(r);
	check("load", kind == 0, "kind %" PRId64 " \"%s\"", kind, msg);
	if (kind != 0)
		return finish("netkit_run");
	uint32_t pid = program_id(obj);
	if (stopped_before_attach(obj, pid))
		return finish("netkit_run");
	int64_t a = bml_attach_netkit(obj, S("filter"), S(PRI));
	int64_t ak = bml_result_kind(a);
	const char *am = bml_result_message(a, &ml);
	snprintf(m, sizeof m, "%.*s", (int)ml, am ? am : "");
	check("mismatch-result", ak == BML_OTHER && strstr(m, "attach type") != NULL, "kind %" PRId64 " \"%s\"", ak, m);
	bml_result_free(a);
	uint32_t ids[4];
	struct bpf_link_info li[4];
	int nl = 0, cr = own_collect_links(&own_real, pid, p, q, ids, li, 4, &nl, err, sizeof err);
	check("mismatch-collect", pid != 0 && cr == 0, "program %u, rc %d, own link %d (%s)", pid, cr, nl, err);
	int remains = 0, unobserved = cr != 0;
	for (int i = 0; i < nl; i++) {
		enum own_state st = own_poll(&own_real, own_real_link_open, ids[i], GONE_MS, err, sizeof err);
		printf("# link %u state %d (%s)\n", ids[i], st, err);
		remains |= st == OWN_PRESENT;
		unobserved |= st == OWN_UNOBSERVED;
	}
	check("mismatch-observed", !unobserved, "unobserved %d (%s)", unobserved, err);
	if (!unobserved)
		printf("%s\n", remains ? "netkit_link_remains" : "netkit_link_gone");
	run_flush();
	check("close", close_obj(obj) == 0, "object");
	return finish("netkit_run");
}

int main(int argc, char **argv)
{
	if (argc == 6 && !strcmp(argv[1], "stop"))
		return mode_stop(argv[2], argv[3], argv[4], argv[5]);
	if (argc == 6 && !strcmp(argv[1], "arm"))
		return mode_arm(argv[2], argv[3], argv[4], argv[5]);
	if (argc == 5 && !strcmp(argv[1], "neg"))
		return mode_neg(argv[2], argv[3], argv[4]);
	if (argc == 4 && !strcmp(argv[1], "mismatch"))
		return mode_mismatch(argv[2], argv[3]);
	fprintf(stderr, "netkit_run stop|arm|neg|mismatch ...\n");
	return 2;
}
