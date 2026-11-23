/* tcx_fixture.h — E013 の試験の共通 (abi_tcx.c・tcx_diff.c): fixture tc.mlir の宣言、lo を up に、自分への UDP、frame */
#ifndef BML_TEST_TCX_FIXTURE_H
#define BML_TEST_TCX_FIXTURE_H

#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define S(x) (x), (int64_t)strlen(x)
#define M_CNT "{\"name\":\"cnt\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define TC_MAPS "{\"maps\":[" M_CNT "]}"

static inline uint8_t *slurp(const char *path, int64_t *n)
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

/* 新しい netns の lo を up に (0 は成功) */
static inline int lo_up(void)
{
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	struct ifreq ifr;
	memset(&ifr, 0, sizeof ifr);
	strcpy(ifr.ifr_name, "lo");
	int rc = s < 0 || ioctl(s, SIOCGIFFLAGS, &ifr) != 0 ? -1 : 0;
	ifr.ifr_flags |= IFF_UP;
	if (rc == 0)
		rc = ioctl(s, SIOCSIFFLAGS, &ifr);
	if (s >= 0)
		close(s);
	return rc;
}

/* 127.0.0.1:port に 1 つ送り 200 ms 待つ: 受けたら 1、受けなければ 0、誤りは -1 */
static inline int udp_self(int port)
{
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
	if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) != 0 || setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) != 0) {
		if (s >= 0)
			close(s);
		return -1;
	}
	char m[8] = "bml", b[8];
	int rc = sendto(s, m, sizeof m, 0, (struct sockaddr *)&a, sizeof a) == (ssize_t)sizeof m ? 0 : -1;
	if (rc == 0)
		rc = recv(s, b, sizeof b, 0) == (ssize_t)sizeof m ? 1 : 0;
	close(s);
	return rc;
}

/* n byte の frame (dst・src は 0、byte 12 / 13 は EtherType、IPv4 なら byte 14 は 0x45 (版 4・IHL 5)、残りは 0) */
static inline void frame(uint8_t *f, size_t n, uint8_t e12, uint8_t e13)
{
	memset(f, 0, n);
	if (n > 12)
		f[12] = e12;
	if (n > 13)
		f[13] = e13;
	if (n > 14 && e12 == 0x08 && e13 == 0x00)
		f[14] = 0x45;
}

#endif
