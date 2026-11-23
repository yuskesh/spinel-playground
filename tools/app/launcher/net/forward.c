/* tools/app/launcher/net/forward.c -- the network firmware's job: every
 * message the M7 puts into the outbound OCRAM ring leaves as one UDP
 * datagram, its bytes verbatim, and every datagram the network file's host
 * sends to the inbound port enters the inbound ring, its bytes verbatim
 * (decision 0014 §5's udp: transport, with its other end on the other core,
 * decisions 0024 and 0025). It knows nothing of the messages' format.
 *
 * In order, on the main thread:
 *   1. the interface the network file names (spc_net.h) comes up, and takes
 *      its address by DHCP (or the file's address);
 *   2. the boot id is chosen, once: the cycle counter's two halves and the
 *      uptime in milliseconds at the moment the address arrived, mixed, and
 *      never 0 (0 is "not yet known"); it is published in the ring's
 *      boot_id word after a barrier. The M7 puts nothing until it reads a
 *      non-zero id, so the outbound ring is empty until then;
 *   3. the sending socket is bound to the destination's port as its own and
 *      connected to the destination; a destination port of 0 switches
 *      sending off: messages are then taken and discarded, counted apart.
 *      The receiving socket is its own, bound to the inbound port; port 0,
 *      or no inbound ring, opens none;
 *   4. then turns, for ever, each doing at most (decision 0025, "fair
 *      service"):
 *      - ONE send attempt: the held message if there is one, else the next
 *        message of the outbound ring, copied out of its slot (its len
 *        checked against max_len first) and the slot released. A send that
 *        finds no buffer (EAGAIN, EWOULDBLOCK, ENOBUFS, ENOMEM) keeps that
 *        one message held for the next turn, and no later message is taken
 *        past it; a message held for SPC_NET_HOLD_TURNS turns, any other
 *        failure, or a short send counts one error and drops that message;
 *      - ONE receive pass: the datagrams already waiting, at most the
 *        inbound ring's depth, never waiting for one. Each is exactly one of
 *        refused (its source address is not the network file's host, read
 *        from the datagram's source and never from its payload), empty (0
 *        bytes; 0014 has no empty message), too long (above max_len, seen
 *        with ZSOCK_MSG_TRUNC, which answers a UDP datagram's whole length,
 *        and a buffer one byte longer; nothing of it is queued), full (the
 *        inbound ring is full) or queued;
 *      - a 100 us sleep when the turn moved nothing, or when a message is
 *        held.
 *      This bounds what this thread does in a turn. A network driver call
 *      that does not return is not bounded by it, and nothing here is a
 *      realtime promise.
 *
 * THE COUNTS (spc_net, one struct), which the board lane reads with the debugger once the run has
 * drained (0024: after the M7's `D`, the ring's head equals its tail and
 * spc_net_pending and spc_net_in_send are 0, twice 100 ms apart): every
 * message taken is exactly one of sent, discarded (port 0) or an error; and
 * received = refused + empty + too_long + full + queued for the inbound
 * side. A fault -- head - tail above depth, or a len of 0 or above max_len
 * -- stops the forwarding with spc_net_fault set, and the ring's
 * consumer_state says so. */
#include <errno.h>
#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/dhcpv4.h>
#include <zephyr/net/socket.h>
#include "ring/ring_abi.h"
#include "spc_ring_geometry.h"
#include "spc_net.h"

#define W ((volatile uint32_t *)SPC_RING_M33_BASE)
/* a message held this many turns (each with its 100 us sleep) is dropped as
 * an error, so a send that never finds a buffer cannot hold the ring */
#define SPC_NET_HOLD_TURNS 10000u

/* the counts, together so that one read of the debugger takes them all: u32
 * words in this order, after the magic "SPNC"; the inbound counts follow the
 * first thirteen words, which keep their places */
struct spc_net_counts {
	uint32_t magic;
	uint32_t errors;    /* also spc_transport_udp_errors, the lane's name for it */
	uint32_t taken;
	uint32_t sent;
	uint32_t discarded; /* port 0 */
	uint32_t retries;
	uint32_t pending;   /* 1 while a message is out of the ring and not yet sent or failed */
	uint32_t in_send;
	uint32_t fault;     /* 0, or 1 head - tail above depth, 2 a bad len */
	uint32_t boot_id;   /* the id published */
	int32_t state;      /* 0 starting, 1 forwarding, <0 the step that failed */
	uint32_t dhcp_ms;   /* uptime when the address arrived */
	uint32_t tail;      /* this core's copy of the tail */
	uint32_t received;  /* inbound datagrams received */
	uint32_t refused;   /* from another address */
	uint32_t empty;     /* of 0 bytes */
	uint32_t too_long;  /* above max_len */
	uint32_t full;      /* the inbound ring full */
	uint32_t queued;    /* put into the inbound ring */
	uint32_t in_errors; /* a receive that failed other than "none waiting" */
	uint32_t in_head;   /* this core's copy of the inbound head */
};
volatile struct spc_net_counts spc_net = { .magic = 0x434e5053u };
#define spc_transport_udp_errors spc_net.errors
#define spc_net_taken spc_net.taken
#define spc_net_sent spc_net.sent
#define spc_net_discarded spc_net.discarded
#define spc_net_retries spc_net.retries
#define spc_net_pending spc_net.pending
#define spc_net_in_send spc_net.in_send
#define spc_net_fault spc_net.fault
#define spc_net_boot_id spc_net.boot_id
#define spc_net_state spc_net.state
#define spc_net_dhcp_ms spc_net.dhcp_ms

#if SPC_RING_DEPTH > 0
static uint8_t msg[SPC_RING_MAX_LEN];
#endif
#if SPC_RING_IN_DEPTH > 0 && SPC_NET_IN_PORT != 0
#define SPC_NET_RECEIVES 1
static uint8_t in_msg[SPC_RING_IN_MAX_LEN + 1u];
#else
#define SPC_NET_RECEIVES 0
#endif

static struct net_if *bring_up(void)
{
	int index = net_if_get_by_name(SPC_NET_IFACE);
	struct net_if *iface = index > 0 ? net_if_get_by_index(index) : NULL;

	if (iface == NULL) {
		spc_net_state = -1;
		return NULL;
	}
#if SPC_NET_DHCP
	net_dhcpv4_start(iface);
	while (net_if_ipv4_get_global_addr(iface, NET_ADDR_PREFERRED) == NULL) {
		k_msleep(10);
	}
#else
	{
		struct net_in_addr addr, mask;

		if (zsock_inet_pton(NET_AF_INET, SPC_NET_ADDRESS, &addr) != 1 || zsock_inet_pton(NET_AF_INET, SPC_NET_NETMASK, &mask) != 1 ||
		    net_if_ipv4_addr_add(iface, &addr, NET_ADDR_MANUAL, 0) == NULL || !net_if_ipv4_set_netmask_by_addr(iface, &addr, &mask)) {
			spc_net_state = -2;
			return NULL;
		}
	}
#endif
	return iface;
}

static uint32_t choose_boot_id(void)
{
	uint64_t c = k_cycle_get_64();
	uint32_t ms = k_uptime_get_32(), id;

	spc_net_dhcp_ms = ms;
	id = (uint32_t)c ^ (uint32_t)(c >> 32) ^ (ms * 2654435761u);
	return id != 0u ? id : 1u;
}

#if SPC_RING_DEPTH > 0 && SPC_NET_DEST_PORT != 0
static int open_socket(void)
{
	struct net_sockaddr_in from = { .sin_family = NET_AF_INET, .sin_port = net_htons(SPC_NET_DEST_PORT) };
	struct net_sockaddr_in to = { .sin_family = NET_AF_INET, .sin_port = net_htons(SPC_NET_DEST_PORT) };
	int s = zsock_socket(NET_AF_INET, NET_SOCK_DGRAM, NET_IPPROTO_UDP);

	if (s < 0 || zsock_inet_pton(NET_AF_INET, SPC_NET_DEST_ADDR, &to.sin_addr) != 1 ||
	    zsock_bind(s, (struct net_sockaddr *)&from, sizeof from) != 0 ||
	    zsock_connect(s, (struct net_sockaddr *)&to, sizeof to) != 0) {
		spc_net_state = -3;
		return -1;
	}
	return s;
}
#endif

#if SPC_NET_RECEIVES
static struct net_in_addr in_host;

/* the inbound socket: its own, bound to the inbound port on any address, not
 * connected, so any source port is received and the source address is
 * compared per datagram */
static int open_in_socket(void)
{
	struct net_sockaddr_in at = { .sin_family = NET_AF_INET, .sin_port = net_htons(SPC_NET_IN_PORT) };
	int s = zsock_socket(NET_AF_INET, NET_SOCK_DGRAM, NET_IPPROTO_UDP);

	if (s < 0 || zsock_inet_pton(NET_AF_INET, SPC_NET_IN_HOST, &in_host) != 1 ||
	    zsock_bind(s, (struct net_sockaddr *)&at, sizeof at) != 0) {
		spc_net_state = -4;
		return -1;
	}
	return s;
}

/* one datagram into the inbound ring: 1 queued, 0 full. The M7 is the only
 * writer of in_tail; this core of in_head. */
static int in_put(uint32_t n)
{
	uint32_t tail = spc_ring_load(W, SPC_RING_W_IN_TAIL);
	volatile uint8_t *slot;

	spc_ring_dmb();
	if (spc_net.in_head - tail >= SPC_RING_IN_DEPTH) {
		return 0;
	}
	slot = spc_ring_slot(W, SPC_RING_IN_OFFSET, SPC_RING_IN_STRIDE, SPC_RING_IN_DEPTH, spc_net.in_head);
	for (uint32_t i = 0; i < n; i++) {
		slot[4u + i] = in_msg[i];
	}
	*(volatile uint32_t *)slot = n;
	spc_ring_dmb();
	spc_net.in_head++;
	spc_ring_store(W, SPC_RING_W_IN_HEAD, spc_net.in_head);
	return 1;
}

/* the receive pass: the datagrams already waiting, at most the ring's depth;
 * answers how many were received */
static uint32_t receive_pass(int s)
{
	uint32_t k;

	for (k = 0; k < SPC_RING_IN_DEPTH; k++) {
		struct net_sockaddr_in src;
		net_socklen_t len = sizeof src;
		ssize_t r = zsock_recvfrom(s, in_msg, sizeof in_msg, ZSOCK_MSG_DONTWAIT | ZSOCK_MSG_TRUNC,
					   (struct net_sockaddr *)&src, &len);

		if (r < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK) {
				spc_net.in_errors++;
			}
			break;
		}
		spc_net.received++;
		if (src.sin_family != NET_AF_INET || src.sin_addr.s_addr != in_host.s_addr) {
			spc_net.refused++;
		} else if (r == 0) {
			spc_net.empty++;
		} else if ((size_t)r > SPC_RING_IN_MAX_LEN) {
			spc_net.too_long++;
		} else if (in_put((uint32_t)r)) {
			spc_net.queued++;
		} else {
			spc_net.full++;
		}
	}
	return k;
}
#endif

void spc_net_forward(void)
{
#if SPC_RING_DEPTH > 0
	uint32_t tail = SPC_RING_INIT_INDEX;
	uint32_t held = 0u, held_n = 0u, held_turns = 0u;
	int s = -1;
#endif
#if SPC_NET_RECEIVES
	int s_in = -1;

	spc_net.in_head = SPC_RING_IN_INIT_INDEX;
#endif
	if (bring_up() == NULL) {
		return;
	}
	spc_net_boot_id = choose_boot_id();
	spc_ring_dmb();
	spc_ring_store(W, SPC_RING_W_BOOT_ID, spc_net_boot_id);
	spc_ring_dmb();
#if SPC_RING_DEPTH > 0 && SPC_NET_DEST_PORT != 0
	s = open_socket();
	if (s < 0) {
		return;
	}
#endif
#if SPC_NET_RECEIVES
	s_in = open_in_socket();
	if (s_in < 0) {
		return;
	}
#endif
	spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_TAKING);
	spc_net_state = 1;
	for (;;) {
		uint32_t moved = 0u;

#if SPC_RING_DEPTH > 0
		/* the turn's one send attempt */
		if (!held) {
			uint32_t head = spc_ring_load(W, SPC_RING_W_HEAD), occ;

			spc_ring_dmb();
			occ = head - tail;
			if (occ > SPC_RING_DEPTH) {
				spc_net_fault = 1u;
				break;
			}
			if (occ != 0u) {
				volatile uint8_t *slot = spc_ring_slot(W, SPC_RING_OFFSET, SPC_RING_STRIDE, SPC_RING_DEPTH, tail);
				uint32_t n = *(volatile uint32_t *)slot;

				if (n == 0u || n > SPC_RING_MAX_LEN) {
					spc_net_fault = 2u;
					break;
				}
				spc_net_pending = 1u;
				for (uint32_t i = 0; i < n; i++) {
					msg[i] = slot[4u + i];
				}
				/* done with the slot: release it, then send the copy */
				spc_ring_dmb();
				tail++;
				spc_ring_store(W, SPC_RING_W_TAIL, tail);
				spc_net.tail = tail;
				spc_net_taken++;
				held = 1u;
				held_n = n;
				held_turns = 0u;
			}
		}
		if (held) {
#if SPC_NET_DEST_PORT != 0
			ssize_t r;

			spc_net_in_send = 1u;
			r = zsock_send(s, msg, held_n, ZSOCK_MSG_DONTWAIT);
			spc_net_in_send = 0u;
			if (r == (ssize_t)held_n) {
				spc_net_sent++;
				held = 0u;
			} else if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS || errno == ENOMEM) &&
				   ++held_turns < SPC_NET_HOLD_TURNS) {
				spc_net_retries++; /* kept for the next turn */
			} else {
				spc_transport_udp_errors++; /* any other failure, a short send, or held too long */
				held = 0u;
			}
#else
			spc_net_discarded++;
			held = 0u;
#endif
			spc_net_pending = held;
			moved = held ? 0u : 1u;
		}
#endif
#if SPC_NET_RECEIVES
		moved += receive_pass(s_in);
#endif
		if (moved == 0u) {
			k_usleep(100);
		}
	}
#if SPC_RING_DEPTH > 0
	spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_FAULT);
	spc_ring_dmb();
#endif
}
