/* tools/app/launcher/net/ring_init.c -- the OCRAM ring, initialised by the
 * M33 alone before the M7 is released (ring/ring_abi.h): PRE_KERNEL_1, where
 * Zephyr's second_core_boot releases the M7 at PRE_KERNEL_2. The geometry is
 * the application's channels', from the build's spc_ring_geometry.h (ring ABI
 * version 5: the outbound ring, and the inbound one of decision 0025, depth 0
 * when the application has none). magic first set to 0, then the geometry,
 * head = tail = SPC_RING_INIT_INDEX and in_head = in_tail =
 * SPC_RING_IN_INIT_INDEX, the boot id 0 (not yet known) and the states, a
 * barrier, magic last. The rest of the header, lines 11 to 15, is 0: this
 * M33 is no Spinel companion and has no channel table. */
#include <stdint.h>
#include <zephyr/init.h>
#include "ring/ring_abi.h"
#include "spc_ring_geometry.h"

#define W ((volatile uint32_t *)SPC_RING_M33_BASE)

BUILD_ASSERT((SPC_RING_DEPTH & (SPC_RING_DEPTH - 1u)) == 0u, "the depth is a power of two");
BUILD_ASSERT(SPC_RING_DEPTH == 0u || SPC_RING_OFFSET >= SPC_RING_HEADER_BYTES, "the slots follow the header (512 bytes)");
BUILD_ASSERT(SPC_RING_IN_DEPTH == 0u || SPC_RING_IN_OFFSET >= SPC_RING_HEADER_BYTES, "the inbound slots follow the header");
BUILD_ASSERT(SPC_RING_OFFSET + SPC_RING_DEPTH * SPC_RING_STRIDE <= SPC_RING_BYTES, "the slots fit the region");
BUILD_ASSERT((SPC_RING_IN_DEPTH & (SPC_RING_IN_DEPTH - 1u)) == 0u, "the inbound depth is 0 or a power of two");
BUILD_ASSERT(SPC_RING_IN_DEPTH == 0u || SPC_RING_DEPTH == 0u ||
	     SPC_RING_IN_OFFSET >= SPC_RING_OFFSET + SPC_RING_DEPTH * SPC_RING_STRIDE, "the inbound slots follow the outbound ones");
BUILD_ASSERT(SPC_RING_IN_OFFSET + SPC_RING_IN_DEPTH * SPC_RING_IN_STRIDE <= SPC_RING_BYTES, "the inbound slots fit the region");

static int spc_ring_init(void)
{
	spc_ring_store(W, SPC_RING_W_MAGIC, 0u);
	spc_ring_dmb();
	for (uint32_t i = 1; i < SPC_RING_HEADER_BYTES / 4u; i++) {
		spc_ring_store(W, i, 0u);
	}
	spc_ring_store(W, SPC_RING_W_VERSION, SPC_RING_ABI_VERSION);
	spc_ring_store(W, SPC_RING_W_DEPTH, SPC_RING_DEPTH);
	spc_ring_store(W, SPC_RING_W_STRIDE, SPC_RING_STRIDE);
	spc_ring_store(W, SPC_RING_W_MAX_LEN, SPC_RING_MAX_LEN);
	spc_ring_store(W, SPC_RING_W_OFFSET, SPC_RING_OFFSET);
	spc_ring_store(W, SPC_RING_W_INIT_INDEX, SPC_RING_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_BOOT_ID, 0u);
	spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_STOPPED);
	spc_ring_store(W, SPC_RING_W_HEAD, SPC_RING_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_TAIL, SPC_RING_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_PRODUCER_STATE, SPC_RING_PRODUCER_STARTING);
	spc_ring_store(W, SPC_RING_W_IN_DEPTH, SPC_RING_IN_DEPTH);
	spc_ring_store(W, SPC_RING_W_IN_STRIDE, SPC_RING_IN_STRIDE);
	spc_ring_store(W, SPC_RING_W_IN_MAX_LEN, SPC_RING_IN_MAX_LEN);
	spc_ring_store(W, SPC_RING_W_IN_OFFSET, SPC_RING_IN_OFFSET);
	spc_ring_store(W, SPC_RING_W_IN_INIT_INDEX, SPC_RING_IN_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_IN_HEAD, SPC_RING_IN_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_IN_TAIL, SPC_RING_IN_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_IN_CONSUMER_STATE, SPC_RING_CONSUMER_STOPPED);
	spc_ring_dmb();
	spc_ring_store(W, SPC_RING_W_MAGIC, SPC_RING_MAGIC);
	spc_ring_dmb();
	return 0;
}
SYS_INIT(spc_ring_init, PRE_KERNEL_1, 0);
