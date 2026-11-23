/* tools/doom/ocram-ring/m33/src/main.c -- the ring test's consumer and
 * checker, on the M33 (README.md). It initialises the ring before the M7 is
 * released, takes every message, checks it against the test's patterns
 * (test_words.h), pauses once, and writes its report into the test's words
 * for the M7 to print: the M33 has no console in this pair (LPUART1 is the
 * M7's). */
#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <fsl_device_registers.h>
#include "ring_abi.h"
#include "test_words.h"

#define W ((volatile uint32_t *)SPC_RING_M33_BASE)
BUILD_ASSERT(SPC_TEST_OFFSET >= SPC_RING_HEADER_BYTES, "the test's slots follow the header");

/* the ring, before second_core_boot (PRE_KERNEL_2) releases the M7 */
static int spc_ring_init(void)
{
	spc_ring_store(W, SPC_RING_W_MAGIC, 0u);
	spc_ring_dmb();
	for (uint32_t i = 1; i < SPC_TEST_OFFSET / 4u; i++) {
		spc_ring_store(W, i, 0u);
	}
	spc_ring_store(W, SPC_RING_W_VERSION, SPC_RING_ABI_VERSION);
	spc_ring_store(W, SPC_RING_W_DEPTH, SPC_TEST_DEPTH);
	spc_ring_store(W, SPC_RING_W_STRIDE, SPC_TEST_STRIDE);
	spc_ring_store(W, SPC_RING_W_MAX_LEN, SPC_TEST_MAX_LEN);
	spc_ring_store(W, SPC_RING_W_OFFSET, SPC_TEST_OFFSET);
	spc_ring_store(W, SPC_RING_W_INIT_INDEX, SPC_TEST_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_BOOT_ID, SPC_TEST_BOOT_ID);
	spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_TAKING);
	spc_ring_store(W, SPC_RING_W_HEAD, SPC_TEST_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_TAIL, SPC_TEST_INIT_INDEX);
	spc_ring_store(W, SPC_RING_W_PRODUCER_STATE, SPC_RING_PRODUCER_STARTING);
	spc_ring_store(W, SPC_TW_M33_PROBE, SPC_TEST_M33_PROBE);
	spc_ring_dmb();
	spc_ring_store(W, SPC_RING_W_MAGIC, SPC_RING_MAGIC);
	spc_ring_dmb();
	return 0;
}
SYS_INIT(spc_ring_init, PRE_KERNEL_1, 0);

static uint32_t errors, first_kind, first_at, taken_normal, taken_short;

static void error(uint32_t kind)
{
	if (errors == 0u) {
		first_kind = kind;
		first_at = taken_normal + taken_short;
	}
	errors++;
}

/* the M33's MPU region that covers the ring, and its attribute (Armv8-M:
 * the highest-numbered enabled region that matches) */
static void read_mpu(void)
{
	uint32_t n = (MPU->TYPE & MPU_TYPE_DREGION_Msk) >> MPU_TYPE_DREGION_Pos;

	for (uint32_t r = 0; r < n; r++) {
		uint32_t rbar, rlar, base, limit;

		MPU->RNR = r;
		rbar = MPU->RBAR;
		rlar = MPU->RLAR;
		base = rbar & MPU_RBAR_BASE_Msk;
		limit = (rlar & MPU_RLAR_LIMIT_Msk) | 0x1fu;
		if ((rlar & MPU_RLAR_EN_Msk) && base <= SPC_RING_M33_BASE && SPC_RING_M33_BASE + SPC_RING_BYTES - 1u <= limit) {
			uint32_t idx = (rlar & MPU_RLAR_AttrIndx_Msk) >> MPU_RLAR_AttrIndx_Pos;
			uint32_t mair = idx < 4u ? MPU->MAIR0 : MPU->MAIR1;

			spc_ring_store(W, SPC_TW_MPU_RBAR, rbar);
			spc_ring_store(W, SPC_TW_MPU_RLAR, rlar);
			spc_ring_store(W, SPC_TW_MPU_ATTR, (mair >> (8u * (idx & 3u))) & 0xffu);
		}
	}
}

static uint8_t buf[SPC_TEST_MAX_LEN];

static void check(uint32_t len, uint32_t *prev_seq, uint32_t *prev_ref)
{
	uint32_t c = taken_short;

	if (c < SPC_TEST_SHORT_COUNT) {
		int ok = len == c + 1u;

		for (uint32_t i = 0; ok && i < len; i++) {
			ok = buf[i] == spc_test_short_byte(c, i);
		}
		if (!ok) {
			error(SPC_TE_SHORT);
		}
		taken_short++;
		return;
	}
	if (len < 8u) {
		error(SPC_TE_CONTENT);
		taken_normal++;
		return;
	}
	uint32_t seq = (uint32_t)buf[0] | (uint32_t)buf[1] << 8 | (uint32_t)buf[2] << 16 | (uint32_t)buf[3] << 24;
	uint32_t ref = (uint32_t)buf[4] | (uint32_t)buf[5] << 8 | (uint32_t)buf[6] << 16 | (uint32_t)buf[7] << 24;
	int ok = len == spc_test_len(seq);

	for (uint32_t i = 8; ok && i < len; i++) {
		ok = buf[i] == spc_test_byte(seq, i);
	}
	if (!ok) {
		error(SPC_TE_CONTENT);
	}
	/* the attempts between two taken messages are the refusals between them */
	if (taken_normal == 0u ? seq != ref : seq - *prev_seq - 1u != ref - *prev_ref) {
		error(SPC_TE_SEQ);
	}
	*prev_seq = seq;
	*prev_ref = ref;
	taken_normal++;
}

int main(void)
{
	uint32_t tail = SPC_TEST_INIT_INDEX, prev_seq = 0, prev_ref = 0, max_occ = 0, paused_ms = 0;
	uint32_t last_progress = k_uptime_get_32();
	int done = 0;

	read_mpu();
	/* the M7's probe through its own alias: both views reach the same words */
	for (uint32_t t = k_uptime_get_32(); spc_ring_load(W, SPC_TW_M7_PROBE) != SPC_TEST_M7_PROBE;) {
		spc_ring_dmb();
		if (k_uptime_get_32() - t > SPC_TEST_TIMEOUT_MS) {
			error(SPC_TE_PROBE);
			break;
		}
	}
	spc_ring_store(W, SPC_TW_M7_PROBE_SEEN, spc_ring_load(W, SPC_TW_M7_PROBE));
	while (!done && errors == 0u) {
		uint32_t head = spc_ring_load(W, SPC_RING_W_HEAD);
		uint32_t occ;

		spc_ring_dmb();
		occ = head - tail;
		if (occ > SPC_TEST_DEPTH) {
			error(SPC_TE_OCCUPANCY);
			break;
		}
		if (occ > max_occ) {
			max_occ = occ;
		}
		if (occ == 0u) {
			/* the end: DONE, then head read again; the producer stores its
			 * counts and DONE after its last head */
			if (spc_ring_load(W, SPC_RING_W_PRODUCER_STATE) == SPC_RING_PRODUCER_DONE) {
				spc_ring_dmb();
				if (spc_ring_load(W, SPC_RING_W_HEAD) == tail) {
					done = 1;
					break;
				}
			}
			spc_ring_dmb();
			if (k_uptime_get_32() - last_progress > SPC_TEST_TIMEOUT_MS) {
				error(SPC_TE_TIMEOUT);
			}
			continue;
		}
		{
			volatile uint8_t *slot = spc_ring_slot(W, SPC_TEST_OFFSET, SPC_TEST_STRIDE, SPC_TEST_DEPTH, tail);
			uint32_t len = *(volatile uint32_t *)slot;

			if (len == 0u || len > SPC_TEST_MAX_LEN) {
				error(SPC_TE_LEN);
				break;
			}
			for (uint32_t i = 0; i < len; i++) {
				buf[i] = slot[4u + i];
			}
			check(len, &prev_seq, &prev_ref);
		}
		/* done with the slot: release it */
		spc_ring_dmb();
		tail++;
		spc_ring_store(W, SPC_RING_W_TAIL, tail);
		last_progress = k_uptime_get_32();
		if (taken_normal == SPC_TEST_PAUSE_AT && paused_ms == 0u) {
			/* the pause: stopped, the slots kept, the tail where it is */
			uint32_t t0 = k_uptime_get_32();

			spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_STOPPED);
			k_msleep(SPC_TEST_PAUSE_MS);
			paused_ms = k_uptime_get_32() - t0;
			spc_ring_store(W, SPC_RING_W_CONSUMER_STATE, SPC_RING_CONSUMER_TAKING);
			last_progress = k_uptime_get_32();
		}
	}
	if (done) {
		/* the end's counts: every attempt accepted or refused, every accepted
		 * one taken, and the refusals after the last taken one */
		uint32_t attempted = spc_ring_load(W, SPC_RING_W_ATTEMPTED);
		uint32_t accepted = spc_ring_load(W, SPC_RING_W_ACCEPTED);
		uint32_t refused = spc_ring_load(W, SPC_RING_W_REFUSED);

		if (attempted != accepted + refused || taken_normal != accepted || taken_short != SPC_TEST_SHORT_COUNT ||
		    (taken_normal > 0u && attempted - 1u - prev_seq != refused - prev_ref)) {
			error(SPC_TE_END);
		}
	}
	spc_ring_store(W, SPC_TW_TAKEN_NORMAL, taken_normal);
	spc_ring_store(W, SPC_TW_TAKEN_SHORT, taken_short);
	spc_ring_store(W, SPC_TW_ERRORS, errors);
	spc_ring_store(W, SPC_TW_FIRST_ERROR_KIND, first_kind);
	spc_ring_store(W, SPC_TW_FIRST_ERROR_AT, first_at);
	spc_ring_store(W, SPC_TW_MAX_OCCUPANCY, max_occ);
	spc_ring_store(W, SPC_TW_PAUSED_MS, paused_ms);
	spc_ring_store(W, SPC_TW_FINAL_HEAD, spc_ring_load(W, SPC_RING_W_HEAD));
	spc_ring_store(W, SPC_TW_FINAL_TAIL, tail);
	spc_ring_dmb();
	spc_ring_store(W, SPC_TW_STATUS, errors == 0u && done ? 1u : 2u);
	spc_ring_dmb();
	return 0;
}
