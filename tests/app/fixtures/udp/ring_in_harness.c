/* tests/app/fixtures/udp/ring_in_harness.c -- the get of a udp: :in channel
 * whose producer is the other core (tools/app/templates/channel_xcore_in.c.erb,
 * decision 0025), run on the host against a region of this harness's own:
 * the harness plays the M33, initialising the ring as ring_init.c does and
 * putting messages as forward.c's in_put does (tools/app/ring/ring_abi.h,
 * version 3). The channel is `keys` of tests/app/fixtures/udp/app-in.rb;
 * udp.sh passes its geometry as SPC_T_STRIDE and SPC_T_OFFSET.
 *
 * Checked: the boot check refuses a cleared magic, version 1 and another
 * inbound depth, naming the word; a matching ring is accepted; an empty ring
 * answers 0; messages come out whole, in order, once each, with in_tail
 * published; the counts cross 2^32; and a length of 0 or above `size` is a
 * fault after which every get answers 0 and in_consumer_state says 3. */
#include <stdio.h>
#include <string.h>
#include "ring/ring_abi.h"
#include "channel_keys.h"

uintptr_t spc_test_base;
static uint32_t region[SPC_RING_BYTES / 4u];
static int failed;

#define W ((volatile uint32_t *)spc_test_base)
#define DEPTH SPC_CHANNEL_KEYS_DEPTH
#define SIZE SPC_CHANNEL_KEYS_SIZE

static void ok(const char *what, int cond)
{
	printf("  %s %s\n", cond ? "ok" : "FAIL", what);
	failed += !cond;
}

/* ring_init.c's initialisation, the inbound ring only */
static void init(uint32_t version, uint32_t depth, uint32_t index)
{
	memset(region, 0, sizeof region);
	W[SPC_RING_W_VERSION] = version;
	W[SPC_RING_W_IN_DEPTH] = depth;
	W[SPC_RING_W_IN_STRIDE] = SPC_T_STRIDE;
	W[SPC_RING_W_IN_MAX_LEN] = SIZE;
	W[SPC_RING_W_IN_OFFSET] = SPC_T_OFFSET;
	W[SPC_RING_W_IN_INIT_INDEX] = index;
	W[SPC_RING_W_IN_HEAD] = index;
	W[SPC_RING_W_IN_TAIL] = index;
	W[SPC_RING_W_MAGIC] = SPC_RING_MAGIC;
}

/* forward.c's in_put: 1 queued, 0 full; `len` is the slot's length word */
static int put(const uint8_t *data, uint32_t n, uint32_t len)
{
	uint32_t head = W[SPC_RING_W_IN_HEAD];
	volatile uint8_t *slot;

	if (head - W[SPC_RING_W_IN_TAIL] >= DEPTH) {
		return 0;
	}
	slot = spc_ring_slot(W, SPC_T_OFFSET, SPC_T_STRIDE, DEPTH, head);
	for (uint32_t i = 0; i < n; i++) {
		slot[4u + i] = data[i];
	}
	*(volatile uint32_t *)slot = len;
	W[SPC_RING_W_IN_HEAD] = head + 1u;
	return 1;
}

static void pattern(uint8_t *b, uint32_t seq, uint32_t n)
{
	for (uint32_t i = 0; i < n; i++) {
		b[i] = (uint8_t)(seq * 13u + i);
	}
}

int main(void)
{
	uint8_t in[SIZE], out[SIZE];
	int all = 1;

	spc_test_base = (uintptr_t)region;
	init(SPC_RING_ABI_VERSION, DEPTH, 0u);
	W[SPC_RING_W_MAGIC] = 0u;
	ok("a cleared magic is refused, naming word 0", spc_channel_keys_check() == (int32_t)SPC_RING_W_MAGIC + 1);
	init(1u, DEPTH, 0u);
	ok("a version 1 ring is refused, naming the version word", spc_channel_keys_check() == (int32_t)SPC_RING_W_VERSION + 1);
	init(SPC_RING_ABI_VERSION, DEPTH * 2u, 0u);
	ok("another inbound depth is refused, naming its word", spc_channel_keys_check() == (int32_t)SPC_RING_W_IN_DEPTH + 1);

	init(SPC_RING_ABI_VERSION, DEPTH, 0u);
	ok("the matching ring is accepted, and in_consumer_state says taking",
	   spc_channel_keys_check() == 0 && W[SPC_RING_W_IN_CONSUMER_STATE] == 1u);
	ok("an empty ring answers 0", spc_channel_keys_get(out, SIZE) == 0);

	static const uint32_t lens[3] = { 1u, SIZE, 5u };
	for (uint32_t k = 0; k < 3u; k++) {
		pattern(in, k, lens[k]);
		put(in, lens[k], lens[k]);
	}
	for (uint32_t k = 0; k < 3u; k++) {
		int32_t n = spc_channel_keys_get(out, SIZE);

		pattern(in, k, lens[k]);
		all &= n == (int32_t)lens[k] && memcmp(in, out, lens[k]) == 0;
	}
	ok("three messages come out whole and in order", all);
	ok("then the ring is empty, and in_tail is published as 3",
	   spc_channel_keys_get(out, SIZE) == 0 && W[SPC_RING_W_IN_TAIL] == 3u);

	init(SPC_RING_ABI_VERSION, DEPTH, 0xFFFFFFF8u);
	spc_channel_keys_check();
	all = 1;
	for (uint32_t k = 0; k < 4u * DEPTH; k++) {
		uint32_t n = 1u + k % SIZE;

		pattern(in, k, n);
		all &= put(in, n, n);
		all &= spc_channel_keys_get(out, SIZE) == (int32_t)n && memcmp(in, out, n) == 0;
	}
	ok("the counts cross 2^32 with every message intact", all && W[SPC_RING_W_IN_TAIL] == 0xFFFFFFF8u + 4u * DEPTH);
	all = 1;
	for (uint32_t k = 0; k < DEPTH; k++) {
		all &= put(in, 1u, 1u);
	}
	ok("depth messages fill the ring, and one more is refused by the producer", all && !put(in, 1u, 1u));
	all = 1;
	for (uint32_t k = 0; k < DEPTH; k++) {
		all &= spc_channel_keys_get(out, SIZE) == 1;
	}
	ok("each comes out once", all && spc_channel_keys_get(out, SIZE) == 0);

	init(SPC_RING_ABI_VERSION, DEPTH, 0u);
	spc_channel_keys_check();
	put(in, 1u, 0u);
	ok("a length of 0 is a fault: the get answers 0 and in_consumer_state says 3",
	   spc_channel_keys_get(out, SIZE) == 0 && W[SPC_RING_W_IN_CONSUMER_STATE] == 3u);
	put(in, 1u, 1u);
	ok("and after it every get answers 0", spc_channel_keys_get(out, SIZE) == 0);
	init(SPC_RING_ABI_VERSION, DEPTH, 0u);
	spc_channel_keys_check();
	put(in, 1u, SIZE + 1u);
	ok("a length above the size is a fault too", spc_channel_keys_get(out, SIZE) == 0 && W[SPC_RING_W_IN_CONSUMER_STATE] == 3u);

	printf("harness: %d failed\n", failed);
	return failed != 0;
}
