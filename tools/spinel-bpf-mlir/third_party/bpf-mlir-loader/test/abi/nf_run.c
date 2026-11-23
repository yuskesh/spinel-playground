/* nf_run — E051 の差動の C の側 (Go の側は test/oracle/cmd/nf-attach-oracle — 同じ入力・起こし方・同じ形の行):
 *   nf_run <nf.bpf.o> <schema の sha256>
 * 使い捨ての netns の中で (呼び手が `unshare -n` と loopback の up — bml は netns を変えない) 製品の照合する load と bml_attach_netfilter
 * (IPv4・LOCAL_OUT・priority −128 — bpf-mlir E402 と同じ)。行: E402 の nethookcheck の観測の文・link の info・無効な引数・残りの link の数。
 * 変異 nf.* は tools-mut で (BML_MUTANT)。 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "abi/internal.h"
#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_OUT "{\"name\":\"out\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u32\",\"max_entries\":4}"
#define MAPS "{\"globals\":[],\"maps\":[" M_OUT "]}"

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc(l > 0 ? (size_t)l : 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

static int64_t take(int64_t r, const char *what)
{
	if (bml_result_kind(r) != 0) {
		int64_t ml;
		const char *m = bml_result_message(r, &ml);
		fprintf(stderr, "nf_run: %s: kind %lld: %.*s\n", what, (long long)bml_result_kind(r), (int)ml, m);
		exit(1);
	}
	int64_t v = bml_result_value(r);
	bml_result_free(r);
	return v;
}

/* Go の errName (ok か unix.ErrnoName) */
static const char *err_name(int rc, int e)
{
	if (rc >= 0)
		return "ok";
	const char *n = strerrorname_np(e);
	return n ? n : "?";
}

static void send_all(int s, int r, char *buf, size_t cap)
{
	static const int sizes[5] = {100, 100, 100, 1200, 1200};
	static char data[1200];
	struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(9999), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	size_t off = strlen(buf);
	for (int i = 0; i < 5; i++) {
		int rc = (int)sendto(s, data, (size_t)sizes[i], 0, (struct sockaddr *)&to, sizeof to);
		off += (size_t)snprintf(buf + off, cap - off, "%s%d:%s", i ? "," : "", sizes[i], err_name(rc, errno));
	}
	int n100 = 0, n1200 = 0;
	char rb[4096];
	for (;;) {
		ssize_t n = recvfrom(r, rb, sizeof rb, 0, NULL, NULL);
		if (n < 0)
			break;
		n100 += n == 100;
		n1200 += n == 1200;
	}
	snprintf(buf + off, cap - off, " received:100x%d,1200x%d", n100, n1200);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc != 3) {
		fprintf(stderr, "usage: nf_run <nf.bpf.o> <sha256>\n");
		return 2;
	}
	int64_t n;
	uint8_t *elf = slurp(argv[1], &n);
	if (!elf)
		return 1;
	int64_t obj = take(bml_load_checked(elf, n, S(argv[2]), S(MAPS), 0), "load");
	free(elf);
	int r = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0), s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	struct sockaddr_in at = {.sin_family = AF_INET, .sin_port = htons(9999), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
	if (r < 0 || s < 0 || bind(r, (struct sockaddr *)&at, sizeof at) != 0 || setsockopt(r, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) != 0) {
		fprintf(stderr, "nf_run: socket: %s\n", strerror(errno));
		return 1;
	}
	char line[1024] = "control:";
	send_all(s, r, line, sizeof line);
	int64_t lk = take(bml_attach_netfilter(obj, S("nf"), 2 /* NFPROTO_IPV4 */, 3 /* NF_INET_LOCAL_OUT */, -128, 0), "attach");
	strncat(line, " linked:", sizeof line - strlen(line) - 1);
	send_all(s, r, line, sizeof line);
	uint32_t o[4];
	for (int k = 0; k < 4; k++)
		o[k] = (uint32_t)take(bml_map_get_bits(obj, S(M_OUT), k), "out");
	printf("%s out:hook=%u,pf=%u,len=%u,runs=%u\n", line, o[0], o[1], o[2], o[3]);
	int64_t e = 0;
	int fd = abi_link_dup_fd(lk, &e);
	struct bpf_link_info info;
	uint32_t il = sizeof info;
	memset(&info, 0, sizeof info);
	bpf_link_get_info_by_fd(fd, &info, &il);
	close(fd);
	printf("info pf=%u hooknum=%u priority=%d flags=%u\n", info.netfilter.pf, info.netfilter.hooknum, info.netfilter.priority, info.netfilter.flags);
	uint32_t id = info.id;
	take(bml_detach(lk), "detach");
	/* 無効な引数 (kernel の拒否 — 文は比べない) と範囲の外 (bml の VALUE_RANGE) */
	static const int64_t bad[2][2] = {{99, 3}, {2, 9}};
	for (int i = 0; i < 2; i++) {
		int64_t b = bml_attach_netfilter(obj, S("nf"), bad[i][0], bad[i][1], -128, 0);
		printf("bad pf=%lld hooknum=%lld %s\n", (long long)bad[i][0], (long long)bad[i][1], bml_result_kind(b) == 0 ? "ok" : "error");
		if (bml_result_kind(b) == 0)
			bml_detach(bml_result_value(b));
		bml_result_free(b);
	}
	int64_t vr = bml_attach_netfilter(obj, S("nf"), 2, 3, (int64_t)INT32_MAX + 1, 0);
	printf("range priority=2147483648 kind=%lld\n", (long long)bml_result_kind(vr));
	bml_result_free(vr);
	int lfd = bpf_link_get_fd_by_id(id);
	printf("left %d\n", lfd >= 0);
	if (lfd >= 0)
		close(lfd);
	bml_close(obj);
	return 0;
}
