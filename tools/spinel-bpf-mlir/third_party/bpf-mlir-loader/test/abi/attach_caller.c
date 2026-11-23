/* attach_caller — E038 の差動の C の側: 呼び手の先への attach (bml_attach_cgroup・bml_attach_netns・bml_attach_socket・bml_program_fd) を
 * 照合する load (ASan) → attach → 起こし → 観測の文 ("obs …" — Go の test/oracle/cmd/attach-caller-oracle と byte で比べる) と C ABI の対照
 * ("check <名前> <kind> [named|kernel]")。root で unshare -n の中 (新しい netns — lo を up にする)。cge は子の cgroup /sys/fs/cgroup/bml-e038-<pid>
 * を作って消す (attachcheck の条件と同じ)。
 *
 *   attach_caller <mode> <ELF> <schema の sha256> <maps.json>     mode: cge | sk | sf | fd */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)

static const char *maps_doc;

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

static uint32_t out(int64_t obj, int64_t key)
{
	const char *s = strstr(maps_doc, "{\"name\":\"out\"");
	const char *e = s ? strchr(s, '}') : NULL;
	if (!e)
		return 0xffffffffu;
	int64_t r = bml_map_get_bits(obj, s, (int64_t)(e - s + 1), key);
	uint32_t v = bml_result_kind(r) == 0 ? (uint32_t)bml_result_value(r) : 0xffffffffu;
	bml_result_free(r);
	return v;
}

/* 結果の kind と、OTHER なら bml の名指し (fd の正体の文) か kernel の誤りか */
static void check(const char *name, int64_t r)
{
	int64_t k = bml_result_kind(r), mn = 0;
	const char *m = bml_result_message(r, &mn);
	const char *how = k == BML_OTHER ? (m && strstr(m, " is not a ") ? " named" : " kernel") : "";
	printf("check %s %lld%s\n", name, (long long)k, how);
	if (k)
		fprintf(stderr, "attach_caller: %s: %.*s\n", name, (int)mn, m ? m : "");
	bml_result_free(r);
}

static int64_t take(int64_t r, const char *what)
{
	int64_t k = bml_result_kind(r), v = k == 0 ? bml_result_value(r) : -1;
	if (k) {
		int64_t mn = 0;
		const char *m = bml_result_message(r, &mn);
		printf("obs %s attach=%lld\n", what, (long long)k);
		fprintf(stderr, "attach_caller: %s: %.*s\n", what, (int)mn, m ? m : "");
	}
	bml_result_free(r);
	return v;
}

static const char *err_name(int e)
{
	switch (e) {
	case 0: return "ok";
	case EPERM: return "EPERM";
	case ECONNREFUSED: return "ECONNREFUSED";
	case EAGAIN: return "EAGAIN";
	default: return "other";
	}
}

static void lo_up(void)
{
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	struct ifreq ifr;
	memset(&ifr, 0, sizeof ifr);
	strcpy(ifr.ifr_name, "lo");
	ioctl(s, SIOCGIFFLAGS, &ifr);
	ifr.ifr_flags |= IFF_UP;
	ioctl(s, SIOCSIFFLAGS, &ifr);
	close(s);
}

static struct sockaddr_in lo(int port)
{
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	return a;
}

/* cgroup の中の子の process が 127.0.0.1:9 へ UDP の n byte を送る — sendto の errno */
static int udp_in_cgroup(const char *cgdir, int n)
{
	pid_t pid = fork();
	if (pid == 0) {
		char p[512];
		snprintf(p, sizeof p, "%s/cgroup.procs", cgdir);
		int f = open(p, O_WRONLY);
		if (f < 0 || write(f, "0", 1) != 1)
			_exit(200);
		close(f);
		int s = socket(AF_INET, SOCK_DGRAM, 0);
		char buf[128] = {0};
		struct sockaddr_in a = lo(9);
		ssize_t r = sendto(s, buf, (size_t)n, 0, (struct sockaddr *)&a, sizeof a);
		_exit(r < 0 ? errno : 0);
	}
	int st = 0;
	waitpid(pid, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

static int mode_cge(int64_t obj)
{
	char cg[256];
	snprintf(cg, sizeof cg, "/sys/fs/cgroup/bml-e038-%d", (int)getpid());
	if (mkdir(cg, 0755) != 0)
		return 2;
	int cfd = open(cg, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	int e = udp_in_cgroup(cg, 100);
	printf("obs none100 act=%s out=%u,%u\n", err_name(e), out(obj, 0), out(obj, 1));
	int64_t l = take(bml_attach_cgroup(obj, S("cge"), cfd), "attach");
	if (l > 0) {
		static const int sizes[] = {20, 36, 37, 100};
		for (int i = 0; i < 4; i++) {
			e = udp_in_cgroup(cg, sizes[i]);
			printf("obs udp%d act=%s out=%u,%u\n", sizes[i], err_name(e), out(obj, 0), out(obj, 1));
		}
		bml_result_free(bml_detach(l));
	}
	int nsfd = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
	check("cgroup_with_netns_fd", bml_attach_cgroup(obj, S("cge"), nsfd));
	check("cgroup_negative_fd", bml_attach_cgroup(obj, S("cge"), -1));
	check("netns_on_cgroup_skb", bml_attach_netns(obj, S("cge"), nsfd));
	check("program_fd_on_cgroup_skb", bml_program_fd(obj, S("cge")));
	close(nsfd);
	close(cfd);
	rmdir(cg);
	return 0;
}

static void tcp_listen(int port, int *fd)
{
	*fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	int one = 1;
	setsockopt(*fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in a = lo(port);
	bind(*fd, (struct sockaddr *)&a, sizeof a);
	listen(*fd, 4);
}

static int tcp_connect(int port)
{
	int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	struct sockaddr_in a = lo(port);
	int r = connect(s, (struct sockaddr *)&a, sizeof a) == 0 ? 0 : errno;
	close(s);
	return r;
}

static void sk_obs(int64_t obj, const char *name)
{
	int a = tcp_connect(7777), b = tcp_connect(8888);
	/* out[2] は remote_port — connect の ephemeral の port で毎回違う (attachcheck の want も見ない) — '-' に */
	printf("obs %s act=7777=%s,8888=%s out=%u,%u,-,%u,%u,%u\n", name, err_name(a), err_name(b), out(obj, 0), out(obj, 1), out(obj, 3), out(obj, 4),
	       out(obj, 5));
}

static int mode_sk(int64_t obj)
{
	int l1, l2;
	tcp_listen(7777, &l1);
	tcp_listen(8888, &l2);
	sk_obs(obj, "none");
	int nsfd = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
	int64_t l = take(bml_attach_netns(obj, S("sk"), nsfd), "attach");
	if (l > 0) {
		sk_obs(obj, "linked");
		bml_result_free(bml_detach(l));
	}
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	check("netns_with_socket_fd", bml_attach_netns(obj, S("sk"), s));
	check("cgroup_on_sk_lookup", bml_attach_cgroup(obj, S("sk"), nsfd));
	close(s);
	close(nsfd);
	close(l1);
	close(l2);
	return 0;
}

/* 自分の UDP の socket r (127.0.0.1:port) に n byte を送り受かるか (200 ms) — 受けた byte 数か none */
static void udp_roundtrip(int r, int port, int n, char *res, size_t cap)
{
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	char buf[256] = {0};
	struct sockaddr_in a = lo(port);
	sendto(s, buf, (size_t)n, 0, (struct sockaddr *)&a, sizeof a);
	close(s);
	struct pollfd p = {.fd = r, .events = POLLIN};
	if (poll(&p, 1, 200) == 1) {
		ssize_t got = recv(r, buf, sizeof buf, MSG_DONTWAIT);
		snprintf(res, cap, "%zd", got);
	} else
		snprintf(res, cap, "none");
}

static int bound_udp(int port)
{
	int r = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	struct sockaddr_in a = lo(port);
	bind(r, (struct sockaddr *)&a, sizeof a);
	return r;
}

static int mode_sf(int64_t obj)
{
	static const int sizes[] = {20, 56, 57, 100};
	for (int form = 0; form < 2; form++) {
		int port = 9100 + form, r = bound_udp(port);
		const char *fname = form ? "progfd" : "attach";
		if (!form) {
			if (take(bml_attach_socket(obj, S("sf"), r), fname) < 0)
				return 1;
		} else {
			int64_t fr = bml_program_fd(obj, S("sf"));
			int pfd = bml_result_kind(fr) == 0 ? (int)bml_result_value(fr) : -1;
			bml_result_free(fr);
			if (pfd < 0 || setsockopt(r, SOL_SOCKET, SO_ATTACH_BPF, &pfd, sizeof pfd) != 0) {
				printf("obs progfd attach=failed\n");
				return 1;
			}
			close(pfd);
		}
		for (int i = 0; i < 4; i++) {
			char res[32];
			udp_roundtrip(r, port, sizes[i], res, sizeof res);
			printf("obs %s payload%d recv=%s out=%u\n", fname, sizes[i], res, out(obj, 0));
		}
		close(r);
	}
	int nsfd = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
	check("socket_with_netns_fd", bml_attach_socket(obj, S("sf"), nsfd));
	check("socket_negative_fd", bml_attach_socket(obj, S("sf"), -5));
	close(nsfd);
	return 0;
}

static int mode_fd(int64_t obj)
{
	int r = bound_udp(9200);
	char res[32];
	udp_roundtrip(r, 9200, 20, res, sizeof res);
	printf("obs none recv=%s out=%u,%u\n", res, out(obj, 0), out(obj, 1));
	int nsfd = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
	int64_t l = take(bml_attach_netns(obj, S("fd"), nsfd), "attach");
	if (l > 0) {
		udp_roundtrip(r, 9200, 20, res, sizeof res);
		printf("obs linked recv=%s out=%u,%u\n", res, out(obj, 0), out(obj, 1));
		bml_result_free(bml_detach(l));
	}
	check("socket_on_flow_dissector", bml_attach_socket(obj, S("fd"), r));
	check("program_fd_on_flow_dissector", bml_program_fd(obj, S("fd")));
	close(nsfd);
	close(r);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "attach_caller <cge|sk|sf|fd> <ELF> <sha> <maps.json>\n");
		return 2;
	}
	maps_doc = argv[4];
	lo_up();
	int64_t n = 0;
	uint8_t *elf = slurp(argv[2], &n);
	if (!elf)
		return 2;
	int64_t lr = bml_load_checked(elf, n, S(argv[3]), S(maps_doc), 0);
	free(elf);
	if (bml_result_kind(lr) != 0) {
		int64_t mn = 0;
		const char *m = bml_result_message(lr, &mn);
		printf("obs load=%lld\n", (long long)bml_result_kind(lr));
		fprintf(stderr, "attach_caller: load: %.*s\n", (int)mn, m ? m : "");
		return 1;
	}
	int64_t obj = bml_result_value(lr);
	bml_result_free(lr);
	const char *m = argv[1];
	int rc = !strcmp(m, "cge") ? mode_cge(obj) : !strcmp(m, "sk") ? mode_sk(obj) : !strcmp(m, "sf") ? mode_sf(obj) : !strcmp(m, "fd") ? mode_fd(obj) : 2;
	bml_result_free(bml_close(obj));
	return rc;
}
