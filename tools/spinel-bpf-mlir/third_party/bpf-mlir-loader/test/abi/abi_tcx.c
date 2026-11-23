/* abi_tcx — E013 の契約の試験: tcx の attach・link の向き・tc (skb) の test run (予測は E013 — 走らせる前に commit)。
 *
 *   abi_tcx <tc.bpf.o> <sha>     (root、unshare -n の中 — 新しい netns の lo だけ。lo を up にして UDP を自分に送る)
 * 各 case は "<id>: … — ok|FAIL" の 1 行 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "bml/bml.h"
#include "tcx_fixture.h"

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

static int64_t obj;
static uint64_t cnt(int k)
{
	struct res r = take(bml_map_get_bits(obj, S(M_CNT), k));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "abi_tcx <tc.bpf.o> <sha>\n");
		return 2;
	}
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	struct res r = take(bml_load_checked(elf, n, S(argv[2]), S(TC_MAPS), 0));
	free(elf);
	if (r.kind != 0) {
		printf("load: kind %lld \"%s\" — FAIL\n", (long long)r.kind, r.msg);
		return 1;
	}
	obj = r.value;
	unsigned lo = if_nametoindex("lo");
	/* X1・X2 */
	struct res a = take(bml_attach_tcx(obj, S("ti"), S("lo"))), da = take(bml_link_tcx_direction(a.value));
	check("X1", a.kind == 0 && da.kind == 0 && !strcmp(da.msg, "ingress") && da.value == lo, "attach %lld \"%s\", direction %lld \"%s\" ifindex %lld (lo %u)",
	      (long long)a.kind, a.msg, (long long)da.kind, da.msg, (long long)da.value, lo);
	struct res b = take(bml_attach_tcx(obj, S("te"), S("lo"))), db = take(bml_link_tcx_direction(b.value));
	check("X2", b.kind == 0 && db.kind == 0 && !strcmp(db.msg, "egress") && db.value == lo, "attach %lld \"%s\", direction %lld \"%s\" ifindex %lld",
	      (long long)b.kind, b.msg, (long long)db.kind, db.msg, (long long)db.value);
	/* X3: lo の UDP (IPv4) は egress で数え、ingress で数えて drop */
	int up = lo_up();
	int got = udp_self(7001);
	uint64_t c0 = cnt(0), c1 = cnt(1);
	check("X3", up == 0 && got == 0 && c0 == 1 && c1 == 1, "lo up %d, received %d, cnt 0=%llu 1=%llu", up, got, (unsigned long long)c0,
	      (unsigned long long)c1);
	/* X4 */
	int64_t k[6] = {
		take(bml_attach_tcx(obj, S("xp"), S("lo"))).kind,     take(bml_attach_tcx(obj, S("ti"), S("nope0"))).kind,
		take(bml_attach_tcx(obj, S("nope"), S("lo"))).kind,   take(bml_test_run_tc_data(obj, S("xp"), (uint8_t[42]){0}, 42)).kind,
		take(bml_attach_fentry(obj, S("ti"))).kind,           take(bml_link_tcx_direction(987654)).kind,
	};
	check("X4", k[0] == 6 && k[1] == 5 && k[2] == 6 && k[3] == 6 && k[4] == 6 && k[5] == 6, "%lld %lld %lld %lld %lld %lld", (long long)k[0],
	      (long long)k[1], (long long)k[2], (long long)k[3], (long long)k[4], (long long)k[5]);
	/* X5: xdp の link の向き */
	struct res x = take(bml_attach_xdp(obj, S("xp"), S("lo"))), dx = take(bml_link_tcx_direction(x.value)), xd = take(bml_detach(x.value));
	check("X5", x.kind == 0 && dx.kind == 6 && xd.kind == 0, "xdp attach %lld, direction %lld \"%s\", detach %lld", (long long)x.kind, (long long)dx.kind,
	      dx.msg, (long long)xd.kind);
	/* X6: tc の test run */
	uint8_t v4[42], arp[42], shortf[13], v4s[20];
	frame(v4, 42, 0x08, 0x00);
	frame(arp, 42, 0x08, 0x06);
	frame(shortf, 13, 0x08, 0x00);
	frame(v4s, 20, 0x08, 0x00);
	struct res t1 = take(bml_test_run_tc_data(obj, S("ti"), v4, 42)), t2 = take(bml_test_run_tc_data(obj, S("ti"), arp, 42)),
		   t3 = take(bml_test_run_tc_data(obj, S("ti"), shortf, 13)), t4 = take(bml_test_run_tc_data(obj, S("ti"), v4s, 20)),
		   t5 = take(bml_test_run_tc_data(obj, S("te"), v4, 42));
	check("X6", t1.kind == 0 && t1.value == 2 && t2.kind == 0 && t2.value == 0 && t3.kind == 5 && strstr(t3.msg, "at least 14 bytes") && t4.kind == 5 &&
			    strstr(t4.msg, "hint:") && t5.kind == 0 && t5.value == 0,
	      "v4 %lld/%lld, arp %lld/%lld, 13 byte %lld, v4 20 byte %lld \"%s\", te %lld/%lld", (long long)t1.kind, (long long)t1.value,
	      (long long)t2.kind, (long long)t2.value, (long long)t3.kind, (long long)t4.kind, t4.msg, (long long)t5.kind, (long long)t5.value);
	/* X7: detach の後は数えず drop しない */
	c0 = cnt(0);
	c1 = cnt(1);
	struct res e1 = take(bml_detach(a.value)), e2 = take(bml_detach(b.value)), dd = take(bml_link_tcx_direction(a.value));
	got = udp_self(7002);
	check("X7", e1.kind == 0 && e2.kind == 0 && dd.kind == 6 && got == 1 && cnt(0) == c0 && cnt(1) == c1,
	      "detach %lld %lld, direction after detach %lld, received %d, cnt 0 %llu -> %llu, 1 %llu -> %llu", (long long)e1.kind, (long long)e2.kind,
	      (long long)dd.kind, got, (unsigned long long)c0, (unsigned long long)cnt(0), (unsigned long long)c1, (unsigned long long)cnt(1));
	/* C1 */
	take(bml_close(obj));
	int64_t c_1 = take(bml_attach_tcx(obj, S("ti"), S("lo"))).kind, c_2 = take(bml_test_run_tc_data(obj, S("ti"), v4, 42)).kind;
	check("C1", c_1 == 6 && c_2 == 6, "%lld %lld", (long long)c_1, (long long)c_2);
	printf("abi_tcx: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
