/* tests/app/fixtures/udp/udp_harness.c -- the udp: transport on the host
 * (decision 0014 §5, decision 0024): messages put in a udp: :out ring leave
 * as one datagram each, payload verbatim, in order, through the loopback to
 * a socket this harness binds; a switched-off channel (port 0) discards and
 * counts; a send without buffers keeps its message and sends it later, in
 * order; a permanent failure drops one message and counts it; and every
 * message put is received, discarded or counted, so nothing else is lost.
 * The UART channel beside them still leaves on the UART.
 *
 *   udp_harness PORT   (the port the suite wrote into the network file)
 *
 * The failures are planted through spc_host_send(), the transport's host
 * send: the next `plant_n` calls fail with `plant_errno` before reaching
 * send(2). */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include "channel_console.h"
#include "channel_frames.h"
#include "channel_spare.h"

void spc_transport_step(void);
int32_t spc_transport_udp_open(void);
extern volatile uint32_t spc_transport_udp_errors;
extern uint32_t spc_transport_udp_sent[2];
extern uint32_t spc_transport_udp_discarded[2];
extern uint32_t spc_transport_udp_retries;
extern volatile int32_t spc_transport_udp_state;
extern uint32_t spc_transport_tx_count[4];

static uint32_t uart_tx_n;
void spc_uart_out(uint8_t b) { (void)b; uart_tx_n++; }
int spc_uart_in(uint8_t *b) { (void)b; return 0; }

static int plant_n, plant_errno, sends;
long spc_host_send(int fd, const void *buf, unsigned long n, int flags)
{
	sends++;
	if (plant_n > 0) {
		plant_n--;
		errno = plant_errno;
		return -1;
	}
	return (long)send(fd, buf, n, flags);
}

static int fails;
static void check(const char *what, int cond)
{
	printf("  %s %s\n", cond ? "ok" : "FAIL", what);
	if (!cond) fails++;
}

static int rx;
/* the next datagram into buf, or -1 when none arrives within the wait */
static int receive(uint8_t *buf, int cap, int wait_ms)
{
	struct pollfd p = { rx, POLLIN, 0 };

	if (poll(&p, 1, wait_ms) <= 0) return -1;
	return (int)recv(rx, buf, (size_t)cap, 0);
}

static uint32_t put_frames(uint8_t tag, uint32_t n)
{
	uint8_t m[64];

	for (uint32_t i = 0; i < n; i++) m[i] = (uint8_t)(tag + i);
	return (uint32_t)spc_channel_frames_put(m, sizeof m, n);
}

static int is_frame(const uint8_t *got, int len, uint8_t tag, int n)
{
	if (len != n) return 0;
	for (int i = 0; i < n; i++) if (got[i] != (uint8_t)(tag + i)) return 0;
	return 1;
}

int main(int argc, char **argv)
{
	struct sockaddr_in at = { 0 };
	uint8_t got[128], c[16] = { 9 }, s[8] = { 7 };
	uint32_t put = 0, received = 0;
	int len, len2;

	if (argc != 2) { fprintf(stderr, "usage: udp_harness PORT\n"); return 2; }
	rx = socket(AF_INET, SOCK_DGRAM, 0);
	at.sin_family = AF_INET;
	at.sin_port = htons((uint16_t)atoi(argv[1]));
	at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (rx < 0 || bind(rx, (struct sockaddr *)&at, sizeof at) != 0) {
		fprintf(stderr, "udp_harness: cannot bind 127.0.0.1:%s: %s\n", argv[1], strerror(errno));
		return 3;
	}

	check("open: every switched-on socket connected", spc_transport_udp_open() == 1 && spc_transport_udp_state == 1);

	/* two messages of different lengths, and a UART message beside them */
	put += put_frames(10, 64);
	put += put_frames(100, 5);
	spc_channel_console_put(c, sizeof c, 3);
	spc_transport_step();
	len = receive(got, sizeof got, 1000);
	check("a message leaves as one datagram, its 64 bytes verbatim", is_frame(got, len, 10, 64));
	received += len > 0;
	len = receive(got, sizeof got, 1000);
	check("the next one follows it, 5 bytes: the datagram is the message's length", is_frame(got, len, 100, 5));
	received += len > 0;
	check("the ring is empty after one pass, and the transport counts 2 sent", spc_channel_frames_occupancy() == 0 && spc_transport_udp_sent[0] == 2);
	check("the UART channel beside them still left on the UART (3 bytes of frame + 3 of payload)", spc_transport_tx_count[0] == 1 && uart_tx_n == 6);

	/* the switched-off channel: taken from its ring, discarded, counted */
	spc_channel_spare_put(s, sizeof s, 8);
	spc_channel_spare_put(s, sizeof s, 8);
	spc_transport_step();
	check("a channel switched off (port 0) is drained and its 2 messages counted as discarded",
	      spc_channel_spare_occupancy() == 0 && spc_transport_udp_discarded[1] == 2 && spc_transport_udp_sent[1] == 0);
	check("and nothing reaches the network for it", receive(got, sizeof got, 200) < 0);

	/* planted: three sends find no buffer; the message waits, then leaves first */
	plant_n = 3;
	plant_errno = ENOBUFS;
	put += put_frames(20, 16);
	put += put_frames(40, 16);
	spc_transport_step();
	check("a send without buffers keeps the message: nothing sent, the next still in its ring",
	      receive(got, sizeof got, 200) < 0 && spc_transport_udp_retries == 1 && spc_channel_frames_occupancy() == 1);
	spc_transport_step();
	spc_transport_step();
	check("each pass tries it again (3 retries) and sends nothing behind it", spc_transport_udp_retries == 3 && spc_channel_frames_occupancy() == 1);
	spc_transport_step();
	len = receive(got, sizeof got, 1000);
	len2 = receive(got + 64, 64, 1000);
	check("once a buffer is there the kept message leaves first, then the one behind it",
	      is_frame(got, len, 20, 16) && is_frame(got + 64, len2, 40, 16));
	received += (len > 0) + (len2 > 0);
	check("a retry is no loss: no error counted", spc_transport_udp_errors == 0);

	/* planted: a permanent failure drops that one message and counts it */
	plant_n = 1;
	plant_errno = EHOSTUNREACH;
	put += put_frames(50, 8);
	put += put_frames(60, 8);
	spc_transport_step();
	len = receive(got, sizeof got, 1000);
	check("a permanent failure counts one error, and the next message still leaves", spc_transport_udp_errors == 1 && is_frame(got, len, 60, 8));
	received += len > 0;
	check("nothing further arrives", receive(got, sizeof got, 200) < 0);

	/* conservation over the run */
	check("every message put was received or counted: put == received + errors",
	      put == received + spc_transport_udp_errors);
	printf("udp harness: put %u received %u errors %u retries %u discarded %u sends %d\n", put, received,
	       spc_transport_udp_errors, spc_transport_udp_retries, spc_transport_udp_discarded[1], sends);
	printf("harness: %d failed\n", fails);
	return fails != 0;
}
