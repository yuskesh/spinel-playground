/* tools/doom/ocram-ring/m7/src/main.c -- the ring test's producer, on the
 * M7 (README.md), and the pair's console: every line it prints starts with
 * `R `.
 *
 * In order: the ring's magic and geometry as the M33 initialised them; the
 * M33's probe word read through this core's alias, and this core's probe
 * written for the M33; this core's MPU regions over the ring, which must
 * make it Normal non-cacheable; the put's own refusals of a length of 0 and
 * of 1293; the short messages; then normal messages for SPC_TEST_PUT_MS, a
 * refused put counted and the next attempt made at once; the end's counts
 * published; and the M33's report, printed once its status is set.
 *
 * Built with -DSPC_RING_PLANT_EARLY_HEAD it is the kept failing input: each
 * put publishes head before it writes the slot, and then waits until the
 * consumer has taken that slot before writing it, so the consumer always
 * reads an old slot. The M33's checker must then fail. It shows the checker
 * sees a slot read before it was written; it is no proof of the barriers'
 * order. */
#include <errno.h>
#include <stdint.h>
#include <zephyr/kernel.h>
#include <fsl_device_registers.h>
#include "ring_abi.h"
#include "test_words.h"

#define W ((volatile uint32_t *)SPC_RING_M7_BASE)

static uint32_t depth, stride, max_len, offset;
static uint32_t head;  /* this core's copy: it is the only writer */
static uint32_t attempted, accepted, refused;

/* 1 queued, 0 full, -EINVAL a length the ring cannot carry (nothing written) */
static int put(const uint8_t *data, uint32_t len)
{
	uint32_t tail;
	volatile uint8_t *slot;

	if (len == 0u || len > max_len) {
		return -EINVAL;
	}
	tail = spc_ring_load(W, SPC_RING_W_TAIL);
	spc_ring_dmb();
	if (head - tail >= depth) {
		return 0;
	}
	slot = spc_ring_slot(W, offset, stride, depth, head);
#if defined(SPC_RING_PLANT_EARLY_HEAD)
	spc_ring_store(W, SPC_RING_W_HEAD, head + 1u);
	for (uint32_t t = k_uptime_get_32(); spc_ring_load(W, SPC_RING_W_TAIL) == tail && k_uptime_get_32() - t < 100u;) {
		spc_ring_dmb();
	}
#endif
	for (uint32_t i = 0; i < len; i++) {
		slot[4u + i] = data[i];
	}
	*(volatile uint32_t *)slot = len;
	spc_ring_dmb();
	head++;
	spc_ring_store(W, SPC_RING_W_HEAD, head);
	return 1;
}

/* the MPU regions that cover the ring (Armv7-M: the highest-numbered enabled
 * one that covers an address decides); 1 when every byte of the ring is
 * Normal non-cacheable (TEX 001, C 0, B 0) */
static int check_mpu(void)
{
	uint32_t n = (MPU->TYPE & MPU_TYPE_DREGION_Msk) >> MPU_TYPE_DREGION_Pos;
	int decided = -1;

	printk("R mpu ctrl 0x%08x regions %u\n", MPU->CTRL, n);
	for (uint32_t r = 0; r < n; r++) {
		uint32_t rbar, rasr, size, base;

		MPU->RNR = r;
		rbar = MPU->RBAR;
		rasr = MPU->RASR;
		if (!(rasr & MPU_RASR_ENABLE_Msk)) {
			continue;
		}
		size = 2u << ((rasr & MPU_RASR_SIZE_Msk) >> MPU_RASR_SIZE_Pos);
		base = rbar & MPU_RBAR_ADDR_Msk;
		printk("R mpu region %u base 0x%08x size 0x%08x tex %u c %u b %u s %u srd 0x%02x\n", r, base, size,
		       (rasr & MPU_RASR_TEX_Msk) >> MPU_RASR_TEX_Pos, !!(rasr & MPU_RASR_C_Msk), !!(rasr & MPU_RASR_B_Msk),
		       !!(rasr & MPU_RASR_S_Msk), (rasr & MPU_RASR_SRD_Msk) >> MPU_RASR_SRD_Pos);
		if (base <= SPC_RING_M7_BASE && SPC_RING_M7_BASE - base + SPC_RING_BYTES <= size) {
			/* every subregion that holds the ring must be enabled for the
			 * region to decide the whole ring */
			uint32_t sub = size / 8u, srd = (rasr & MPU_RASR_SRD_Msk) >> MPU_RASR_SRD_Pos, covered = 1;

			for (uint32_t a = SPC_RING_M7_BASE; size >= 256u && a < SPC_RING_M7_BASE + SPC_RING_BYTES; a += sub) {
				if (srd & (1u << ((a - base) / sub))) {
					covered = 0;
				}
			}
			if (covered) {
				decided = ((rasr & MPU_RASR_TEX_Msk) >> MPU_RASR_TEX_Pos) == 1u && !(rasr & MPU_RASR_C_Msk) &&
					  !(rasr & MPU_RASR_B_Msk);
				printk("R mpu region %u covers the ring: %s\n", r, decided ? "normal non-cacheable" : "NOT normal non-cacheable");
			}
		}
	}
	return decided == 1;
}

static uint8_t msg[SPC_TEST_MAX_LEN];

int main(void)
{
	uint32_t t0;
	int ok = 1;

	printk("R ring test producer, ring abi %u at 0x%08x\n", SPC_RING_ABI_VERSION, SPC_RING_M7_BASE);
#if defined(SPC_RING_PLANT_EARLY_HEAD)
	printk("R planted: head published before the slot is written\n");
#endif
	for (t0 = k_uptime_get_32(); spc_ring_load(W, SPC_RING_W_MAGIC) != SPC_RING_MAGIC;) {
		spc_ring_dmb();
		if (k_uptime_get_32() - t0 > SPC_TEST_TIMEOUT_MS) {
			printk("R FAIL no ring magic\nR end fail\n");
			return 0;
		}
	}
	spc_ring_dmb();
	depth = spc_ring_load(W, SPC_RING_W_DEPTH);
	stride = spc_ring_load(W, SPC_RING_W_STRIDE);
	max_len = spc_ring_load(W, SPC_RING_W_MAX_LEN);
	offset = spc_ring_load(W, SPC_RING_W_OFFSET);
	head = spc_ring_load(W, SPC_RING_W_HEAD);
	printk("R ring version %u depth %u stride %u max_len %u offset %u init 0x%08x boot_id 0x%08x\n",
	       spc_ring_load(W, SPC_RING_W_VERSION), depth, stride, max_len, offset, spc_ring_load(W, SPC_RING_W_INIT_INDEX),
	       spc_ring_load(W, SPC_RING_W_BOOT_ID));
	if (spc_ring_load(W, SPC_RING_W_VERSION) != SPC_RING_ABI_VERSION || !spc_ring_geometry_ok(depth, stride, max_len, offset)) {
		printk("R FAIL the ring's version or geometry is not one this producer takes\nR end fail\n");
		return 0;
	}
	printk("R probe m33 0x%08x (want 0x%08x)\n", spc_ring_load(W, SPC_TW_M33_PROBE), SPC_TEST_M33_PROBE);
	ok &= spc_ring_load(W, SPC_TW_M33_PROBE) == SPC_TEST_M33_PROBE;
	spc_ring_store(W, SPC_TW_M7_PROBE, SPC_TEST_M7_PROBE);
	spc_ring_dmb();
	if (!check_mpu()) {
		printk("R FAIL the M7's MPU does not make the whole ring normal non-cacheable\n");
		ok = 0;
	}
	/* the put's own refusals, which leave the ring as it was */
	{
		uint32_t h = spc_ring_load(W, SPC_RING_W_HEAD);
		int r0 = put(msg, 0u), r1 = put(msg, SPC_TEST_MAX_LEN + 1u);

		printk("R put len 0 -> %d, len %u -> %d, head unchanged %d\n", r0, SPC_TEST_MAX_LEN + 1u, r1, spc_ring_load(W, SPC_RING_W_HEAD) == h);
		ok &= r0 == -EINVAL && r1 == -EINVAL && spc_ring_load(W, SPC_RING_W_HEAD) == h;
	}
	spc_ring_store(W, SPC_RING_W_PRODUCER_STATE, SPC_RING_PRODUCER_PUTTING);
	/* the short messages, each until it is queued */
	for (uint32_t c = 0; c < SPC_TEST_SHORT_COUNT; c++) {
		for (uint32_t i = 0; i <= c; i++) {
			msg[i] = spc_test_short_byte(c, i);
		}
		while (put(msg, c + 1u) != 1) {
		}
	}
	/* the normal messages, for a while */
	t0 = k_uptime_get_32();
	while (k_uptime_get_32() - t0 < SPC_TEST_PUT_MS) {
		uint32_t seq = attempted, len = spc_test_len(seq);
		int r;

		msg[0] = (uint8_t)seq; msg[1] = (uint8_t)(seq >> 8); msg[2] = (uint8_t)(seq >> 16); msg[3] = (uint8_t)(seq >> 24);
		msg[4] = (uint8_t)refused; msg[5] = (uint8_t)(refused >> 8); msg[6] = (uint8_t)(refused >> 16); msg[7] = (uint8_t)(refused >> 24);
		for (uint32_t i = 8; i < len; i++) {
			msg[i] = spc_test_byte(seq, i);
		}
		r = put(msg, len);
		attempted++;
		if (r == 1) {
			accepted++;
		} else {
			refused++;
		}
	}
	/* the end: the counts, then DONE */
	spc_ring_store(W, SPC_RING_W_ATTEMPTED, attempted);
	spc_ring_store(W, SPC_RING_W_ACCEPTED, accepted);
	spc_ring_store(W, SPC_RING_W_REFUSED, refused);
	spc_ring_dmb();
	spc_ring_store(W, SPC_RING_W_PRODUCER_STATE, SPC_RING_PRODUCER_DONE);
	spc_ring_dmb();
	printk("R producer attempted %u accepted %u refused %u in %u ms, head 0x%08x\n", attempted, accepted, refused, SPC_TEST_PUT_MS, head);
	/* the report: status last, so read it first and the rest after */
	for (t0 = k_uptime_get_32(); spc_ring_load(W, SPC_TW_STATUS) == 0u;) {
		spc_ring_dmb();
		if (k_uptime_get_32() - t0 > SPC_TEST_TIMEOUT_MS) {
			printk("R FAIL no report from the M33\nR end fail\n");
			return 0;
		}
	}
	spc_ring_dmb();
	printk("R m33 status %u taken normal %u short %u errors %u first kind %u at %u\n", spc_ring_load(W, SPC_TW_STATUS),
	       spc_ring_load(W, SPC_TW_TAKEN_NORMAL), spc_ring_load(W, SPC_TW_TAKEN_SHORT), spc_ring_load(W, SPC_TW_ERRORS),
	       spc_ring_load(W, SPC_TW_FIRST_ERROR_KIND), spc_ring_load(W, SPC_TW_FIRST_ERROR_AT));
	printk("R m33 max occupancy %u paused %u ms final head 0x%08x tail 0x%08x\n", spc_ring_load(W, SPC_TW_MAX_OCCUPANCY),
	       spc_ring_load(W, SPC_TW_PAUSED_MS), spc_ring_load(W, SPC_TW_FINAL_HEAD), spc_ring_load(W, SPC_TW_FINAL_TAIL));
	printk("R m33 probe m7 seen 0x%08x (want 0x%08x)\n", spc_ring_load(W, SPC_TW_M7_PROBE_SEEN), SPC_TEST_M7_PROBE);
	printk("R m33 mpu rbar 0x%08x rlar 0x%08x attr 0x%02x\n", spc_ring_load(W, SPC_TW_MPU_RBAR), spc_ring_load(W, SPC_TW_MPU_RLAR),
	       spc_ring_load(W, SPC_TW_MPU_ATTR));
	ok &= spc_ring_load(W, SPC_TW_STATUS) == 1u && spc_ring_load(W, SPC_TW_M7_PROBE_SEEN) == SPC_TEST_M7_PROBE;
	/* the M33's attribute byte: Normal memory, outer and inner non-cacheable */
	if (spc_ring_load(W, SPC_TW_MPU_ATTR) != 0x44u) {
		printk("R FAIL the M33's MPU attribute over the ring is not normal non-cacheable (0x44)\n");
		ok = 0;
	}
	printk("R end %s\n", ok ? "ok" : "fail");
	return 0;
}
