/* tools/doom/net-probe/src/main.c -- the M33-only UDP sender of decision
 * 0024's amendment ("Order of work": first an M33-only UDP sender at 35
 * frames a second, measured). A measurement image, not the DOOM image.
 *
 * It takes swp0 up, gets an IPv4 address by DHCP, and sends a synthetic
 * 320 x 200 8-bit screen in the wire format of 0024's 2026-10-22
 * clarification: a palette message (0x50) at the start and every second,
 * and each frame as 50 pieces (0x43: tic u32, index u16, count u16, 1280
 * bytes). Frames are chosen by time, at most PROBE_FPS a second: frame k is
 * due at start + k / PROBE_FPS, a frame whose time has passed while the one
 * before it was still being sent is not sent and is counted as such. The
 * pattern changes with every tic: byte (x, y) of tic t is (x + 2y + 3t) mod
 * 256, so a viewer shows it moving.
 *
 * Measured and printed on the console (LPUART1), every line starting `P `:
 *   - the link: the PHY's speed and duplex, the address DHCP gave;
 *   - per frame, the service time: from the first piece's send to the last
 *     one's return (minimum, median, 99th percentile, maximum);
 *   - per send call, the same, and the sends that failed: by errno, each
 *     retried after 100 us until it succeeds (EAGAIN, ENOBUFS, ENOMEM), or
 *     given up (any other errno: the piece is lost, counted);
 *   - the driver's busy-wait for transmit completion: the time from the HAL's
 *     send returning to the driver's first reclaim after it (--wrap around
 *     EP_SendFrame, EP_SendFrameCommon and EP_ReclaimTxDescCommon; the
 *     driver spins on tx_done between the two);
 *   - the CPU's share: 1 - the idle thread's cycles over all cycles, across
 *     the sending window;
 *   - the stacks' high-water marks.
 * The send-call and busy-wait figures are kept in 1 us bins (their medians
 * and 99th percentiles are bin values, their means and maxima exact).
 * The memory map is the build's (build.sh prints the regions). */
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/dhcpv4.h>
#include <zephyr/net/phy.h>
#include <zephyr/net/socket.h>
#include <zephyr/cache.h>
#include <fsl_netc_endpoint.h>
#include PROBE_NET_H

#define WIDTH 320u
#define HEIGHT 200u
#define CHUNK 1280u
#define PIECES ((WIDTH * HEIGHT + CHUNK - 1u) / CHUNK)
#define HEADER 9u
#define MAX_FRAMES (PROBE_SECONDS * PROBE_FPS + 2u)
#define HIST 1024u /* 1 us bins; the last one also holds everything above */

/* ---- the driver's busy-wait, timed from outside it */
static volatile uint32_t tx_queued_at;  /* 0: no send waiting */
struct hist {
	uint16_t bin[HIST];
	uint32_t n, max_cyc;
	uint64_t sum_cyc;
};
static struct hist busy_h, send_h;
static void hist_add(struct hist *h, uint32_t cyc);

status_t __real_EP_SendFrame(ep_handle_t *handle, uint8_t ring, netc_frame_struct_t *frame, void *context, ep_tx_opt *opt);
status_t __real_EP_SendFrameCommon(ep_handle_t *handle, netc_tx_bdr_t *txBdRing, uint8_t hwRing, netc_frame_struct_t *frame,
				   void *context, netc_tx_bd_t *txDesc, bool txCacheMaintain);
netc_tx_frame_info_t *__real_EP_ReclaimTxDescCommon(ep_handle_t *handle, netc_tx_bdr_t *txBdRing, uint8_t hwRing, bool enCallback);

status_t __wrap_EP_SendFrame(ep_handle_t *handle, uint8_t ring, netc_frame_struct_t *frame, void *context, ep_tx_opt *opt)
{
	status_t r = __real_EP_SendFrame(handle, ring, frame, context, opt);

	tx_queued_at = k_cycle_get_32() | 1u;
	return r;
}

status_t __wrap_EP_SendFrameCommon(ep_handle_t *handle, netc_tx_bdr_t *txBdRing, uint8_t hwRing, netc_frame_struct_t *frame,
				   void *context, netc_tx_bd_t *txDesc, bool txCacheMaintain)
{
	status_t r = __real_EP_SendFrameCommon(handle, txBdRing, hwRing, frame, context, txDesc, txCacheMaintain);

	tx_queued_at = k_cycle_get_32() | 1u;
	return r;
}

netc_tx_frame_info_t *__wrap_EP_ReclaimTxDescCommon(ep_handle_t *handle, netc_tx_bdr_t *txBdRing, uint8_t hwRing, bool enCallback)
{
	uint32_t at = tx_queued_at;

	if (at != 0u) {
		uint32_t d = k_cycle_get_32() - at;

		tx_queued_at = 0u;
		hist_add(&busy_h, d);
	}
	return __real_EP_ReclaimTxDescCommon(handle, txBdRing, hwRing, enCallback);
}

/* ---- figures */
static uint32_t frame_cyc[MAX_FRAMES];
static uint32_t frames_sent, frames_not_sent, sends, sends_failed, retries, pieces_lost;
static uint32_t errno_seen[8][2]; /* errno, count */

static void count_errno(int e)
{
	for (int i = 0; i < 8; i++) {
		if (errno_seen[i][1] == 0u || errno_seen[i][0] == (uint32_t)e) {
			errno_seen[i][0] = (uint32_t)e;
			errno_seen[i][1]++;
			return;
		}
	}
}

static uint32_t us(uint32_t cyc)
{
	return (uint32_t)((uint64_t)cyc * 1000000u / sys_clock_hw_cycles_per_sec());
}

static void hist_add(struct hist *h, uint32_t cyc)
{
	uint32_t b = us(cyc);

	h->bin[b < HIST ? b : HIST - 1u]++;
	h->n++;
	h->sum_cyc += cyc;
	if (cyc > h->max_cyc) {
		h->max_cyc = cyc;
	}
}

/* the bin (us) below which a share q/1000 of the samples lie */
static uint32_t hist_q(const struct hist *h, uint32_t q)
{
	uint64_t want = (uint64_t)h->n * q / 1000u, have = 0;

	for (uint32_t b = 0; b < HIST; b++) {
		have += h->bin[b];
		if (have > want) {
			return b;
		}
	}
	return HIST - 1u;
}

static void hist_print(const char *what, const struct hist *h)
{
	printk("P %s n %u mean %u median %u p99 %u max %u us (1 us bins)\n", what, h->n,
	       h->n ? us((uint32_t)(h->sum_cyc / h->n)) : 0u, hist_q(h, 500u), hist_q(h, 990u), us(h->max_cyc));
}

/* sorts v[0..n) and prints its minimum, median, 99th percentile and maximum in us */
static void summary(const char *what, uint32_t *v, uint32_t n)
{
	if (n == 0u) {
		printk("P %s none\n", what);
		return;
	}
	/* insertion sort: n is at most MAX_FRAMES, and this runs once */
	for (uint32_t i = 1; i < n; i++) {
		uint32_t x = v[i], j = i;

		while (j > 0 && v[j - 1] > x) {
			v[j] = v[j - 1];
			j--;
		}
		v[j] = x;
	}
	printk("P %s n %u min %u median %u p99 %u max %u us\n", what, n, us(v[0]), us(v[n / 2]), us(v[(n * 99u) / 100u]), us(v[n - 1]));
}

/* ---- sending */
static int sock = -1;
static uint8_t msg[HEADER + CHUNK];

/* one datagram; retried after 100 us while the stack has no buffer */
static void send_msg(uint32_t n)
{
	for (;;) {
		uint32_t t0 = k_cycle_get_32();
		ssize_t r = zsock_send(sock, msg, n, ZSOCK_MSG_DONTWAIT);
		uint32_t d = k_cycle_get_32() - t0;

		hist_add(&send_h, d);
		sends++;
		if (r == (ssize_t)n) {
			return;
		}
		sends_failed++;
		count_errno(errno);
		if (errno == EAGAIN || errno == ENOBUFS || errno == ENOMEM) {
			retries++;
			k_usleep(100);
			continue;
		}
		pieces_lost++;
		return;
	}
}

static void send_palette(void)
{
	msg[0] = 0x50;
	/* a grey ramp: index i is (i, i, i) */
	for (uint32_t i = 0; i < 256u; i++) {
		msg[1 + 3 * i] = msg[2 + 3 * i] = msg[3 + 3 * i] = (uint8_t)i;
	}
	send_msg(1u + 768u);
}

static void send_frame(uint32_t tic)
{
	for (uint32_t p = 0; p < PIECES; p++) {
		uint32_t off = p * CHUNK, n = WIDTH * HEIGHT - off < CHUNK ? WIDTH * HEIGHT - off : CHUNK;

		msg[0] = 0x43;
		msg[1] = (uint8_t)tic;
		msg[2] = (uint8_t)(tic >> 8);
		msg[3] = (uint8_t)(tic >> 16);
		msg[4] = (uint8_t)(tic >> 24);
		msg[5] = (uint8_t)p;
		msg[6] = (uint8_t)(p >> 8);
		msg[7] = (uint8_t)PIECES;
		msg[8] = (uint8_t)(PIECES >> 8);
		for (uint32_t i = 0; i < n; i++) {
			uint32_t at = off + i, x = at % WIDTH, y = at / WIDTH;

			msg[HEADER + i] = (uint8_t)(x + 2u * y + 3u * tic);
		}
		send_msg(HEADER + n);
	}
}

/* ---- the link */
static struct net_if *bring_up(void)
{
	int index = net_if_get_by_name(PROBE_IFACE);
	struct net_if *iface = index > 0 ? net_if_get_by_index(index) : NULL;
	const struct device *phy = DEVICE_DT_GET(DT_NODELABEL(phy0));
	struct phy_link_state st = { 0 };

	if (iface == NULL) {
		printk("P error no interface %s\n", PROBE_IFACE);
		return NULL;
	}
	for (int i = 0; i < 100 && !net_if_is_carrier_ok(iface); i++) {
		k_msleep(100);
	}
	if (phy_get_link_state(phy, &st) == 0) {
		printk("P link %s up %d speed %s\n", PROBE_IFACE, st.is_up,
		       PHY_LINK_IS_SPEED_1000M(st.speed) ? "1000" : PHY_LINK_IS_SPEED_100M(st.speed) ? "100" : "10");
		printk("P link duplex %s\n", PHY_LINK_IS_FULL_DUPLEX(st.speed) ? "full" : "half");
	}
	net_dhcpv4_start(iface);
	for (int i = 0; i < 300; i++) {
		struct net_in_addr *a = net_if_ipv4_get_global_addr(iface, NET_ADDR_PREFERRED);

		if (a != NULL) {
			char s[NET_IPV4_ADDR_LEN];

			printk("P dhcp %s after %d ms\n", net_addr_ntop(NET_AF_INET, a, s, sizeof s), i * 100);
			return iface;
		}
		k_msleep(100);
	}
	printk("P error no DHCP address after 30 s\n");
	return NULL;
}

static int open_socket(void)
{
	struct net_sockaddr_in from = { .sin_family = NET_AF_INET, .sin_port = net_htons(PROBE_SRC_PORT) };
	struct net_sockaddr_in to = { .sin_family = NET_AF_INET, .sin_port = net_htons(PROBE_DEST_PORT) };

	sock = zsock_socket(NET_AF_INET, NET_SOCK_DGRAM, NET_IPPROTO_UDP);
	if (sock < 0 || zsock_inet_pton(NET_AF_INET, PROBE_DEST_ADDR, &to.sin_addr) != 1 ||
	    zsock_bind(sock, (struct net_sockaddr *)&from, sizeof from) != 0 ||
	    zsock_connect(sock, (struct net_sockaddr *)&to, sizeof to) != 0) {
		printk("P error socket %d errno %d\n", sock, errno);
		return -1;
	}
	return 0;
}

static void stack_mark(const struct k_thread *t, void *u)
{
	size_t unused = 0;
	const char *name = k_thread_name_get((k_tid_t)t);

	(void)u;
	if (k_thread_stack_space_get(t, &unused) == 0) {
		printk("P stack %s size %u used %u\n", name ? name : "?", (unsigned)t->stack_info.size,
		       (unsigned)(t->stack_info.size - unused));
	}
}

int main(void)
{
	k_thread_runtime_stats_t s0, s1;
	uint32_t hz = sys_clock_hw_cycles_per_sec(), period = hz / PROBE_FPS;
	uint32_t start, tic = 0, last_palette;

#if defined(PROBE_ICACHE)
	/* the variant that enables the code bus cache, which the SoC hook leaves
	 * off (soc/nxp/imxrt/imxrt118x/soc.c enables the data cache only) */
	sys_cache_instr_enable();
#endif
	printk("P cache code %s system %s\n", (XCACHE_PC->CCR & XCACHE_CCR_ENCACHE_MASK) ? "on" : "off",
	       (XCACHE_PS->CCR & XCACHE_CCR_ENCACHE_MASK) ? "on" : "off");
	printk("P probe %s:%u from %s port %u, %u fps for %u s, cycles %u Hz\n", PROBE_DEST_ADDR, PROBE_DEST_PORT, PROBE_IFACE,
	       PROBE_SRC_PORT, PROBE_FPS, PROBE_SECONDS, hz);
	if (bring_up() == NULL || open_socket() != 0) {
		printk("P end failed\n");
		return 0;
	}
	k_thread_runtime_stats_all_get(&s0);
	start = k_cycle_get_32();
	send_palette();
	last_palette = start;
	for (uint32_t k = 0; k < PROBE_SECONDS * PROBE_FPS; k++) {
		uint32_t due = start + k * period, now = k_cycle_get_32();
		uint32_t t0, d;

		if ((int32_t)(now - due) < 0) {
			k_usleep(us(due - now));
		} else if ((int32_t)(now - due) >= (int32_t)period) {
			frames_not_sent++; /* its time passed while the frame before it was sent */
			tic++;
			continue;
		}
		if (k_cycle_get_32() - last_palette >= hz) {
			send_palette();
			last_palette += hz;
		}
		t0 = k_cycle_get_32();
		send_frame(tic);
		d = k_cycle_get_32() - t0;
		if (frames_sent < MAX_FRAMES) {
			frame_cyc[frames_sent] = d;
		}
		frames_sent++;
		tic++;
	}
	k_thread_runtime_stats_all_get(&s1);
	{
		uint64_t all = s1.execution_cycles - s0.execution_cycles, idle = s1.idle_cycles - s0.idle_cycles;

		printk("P window %u ms\n", us(k_cycle_get_32() - start) / 1000u);
		printk("P cpu busy %u.%u %%\n", (unsigned)(1000u - idle * 1000u / all) / 10u, (unsigned)(1000u - idle * 1000u / all) % 10u);
	}
	printk("P frames sent %u not_sent %u pieces_lost %u\n", frames_sent, frames_not_sent, pieces_lost);
	printk("P sends %u failed %u retries %u\n", sends, sends_failed, retries);
	for (int i = 0; i < 8 && errno_seen[i][1] != 0u; i++) {
		printk("P errno %u count %u\n", errno_seen[i][0], errno_seen[i][1]);
	}
	summary("frame", frame_cyc, frames_sent < MAX_FRAMES ? frames_sent : MAX_FRAMES);
	hist_print("send", &send_h);
	hist_print("busy_wait", &busy_h);
	k_thread_foreach(stack_mark, NULL);
	printk("P end ok\n");
	return 0;
}
