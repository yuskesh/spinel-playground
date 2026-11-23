/* tools/doom/net-ring/m7/src/main.c -- the network path's test producer on
 * the M7 (README.md): DOOM's stream in wire format version 3 (decision
 * 0024's clarification and decision 0025: a frame carries no input, session
 * 0, sequence 0, state 0), from a synthetic screen, through the OCRAM ring
 * (tools/app/ring/ring_abi.h) to the M33's network firmware
 * (tools/app/launcher with SPC_NET_FIRMWARE), which sends every message
 * verbatim. It is the board application's stream without DOOM: the same
 * messages, the same choices and the same counts, so the M33 firmware and
 * the viewer can be judged before the application tool generates the
 * channel.
 *
 * Every TIC_US a tic runs (DOOM's 35 tics a second by default, as the
 * board lane's tic is about 19 ms with its period of 1 ms, here a fixed
 * pacing). At each tic:
 *   - the boot id is loaded once (never waited for); while it is 0 the tic's
 *     frame is not sent and nothing is put;
 *   - at the first tic of each second (by the cycle counter), the palette
 *     is put before the frame, and the stream counts after it; a refusal
 *     counts as a palette or stats drop, apart from the frames';
 *   - the frame is due by time, at most FPS a second, keeping the average's
 *     phase (0024: period ceil(Hz / FPS), next_due moved on by a period, a
 *     tic more than a period late moving it to now plus a period);
 *   - a due frame is put as 50 pieces; a refused piece drops the rest of the
 *     frame (frames dropped, messages dropped).
 * After TICS tics it prints its counts and `R N` (the console's N line's
 * three counts) and `R end`, and put_count nothing more. The pattern of tic t is
 * byte (x, y) = (x + 2y + 3t) mod 256. */
#include <stdint.h>
#include <zephyr/kernel.h>
#include "ring/ring_abi.h"

#define W ((volatile uint32_t *)SPC_RING_M7_BASE)
#ifndef TICS
#define TICS 600u
#endif
#ifndef TIC_US
#define TIC_US 28571u /* 35 a second */
#endif
#define FPS 35u
#define WIDTH 320u
#define HEIGHT 200u
#define CHUNK 1280u
#define PIECES 50u

static uint32_t depth, stride, max_len, offset, head;
static uint32_t frames_sent, not_sent, not_sent_no_id, frames_dropped, msgs_dropped, palette_drops, stats_drops, put_count;

static int put(const uint8_t *data, uint32_t len)
{
	uint32_t tail = spc_ring_load(W, SPC_RING_W_TAIL);
	volatile uint8_t *slot;

	spc_ring_dmb();
	if (len == 0u || len > max_len || head - tail >= depth) {
		return 0;
	}
	slot = spc_ring_slot(W, offset, stride, depth, head);
	for (uint32_t i = 0; i < len; i++) {
		slot[4u + i] = data[i];
	}
	*(volatile uint32_t *)slot = len;
	spc_ring_dmb();
	head++;
	spc_ring_store(W, SPC_RING_W_HEAD, head);
	put_count++;
	return 1;
}

#define C_HEADER 21u /* wire version 3: kind, version, boot id, tic, index, count, session, sequence, state */
static uint8_t msg[C_HEADER + CHUNK];

static void header(uint8_t kind, uint32_t boot)
{
	msg[0] = kind;
	msg[1] = 3u;
	msg[2] = (uint8_t)boot; msg[3] = (uint8_t)(boot >> 8); msg[4] = (uint8_t)(boot >> 16); msg[5] = (uint8_t)(boot >> 24);
}

static void w32(uint32_t at, uint32_t v)
{
	msg[at] = (uint8_t)v; msg[at + 1u] = (uint8_t)(v >> 8); msg[at + 2u] = (uint8_t)(v >> 16); msg[at + 3u] = (uint8_t)(v >> 24);
}

int main(void)
{
	uint32_t hz = sys_clock_hw_cycles_per_sec(), period = (hz + FPS - 1u) / FPS;
	uint32_t next_due = 0, next_second = 0, first_id_tic = 0xffffffffu, boot = 0;
	int64_t t_next = k_uptime_ticks();

	printk("R net-ring producer, %u tics at %u us, %u fps, cycles %u Hz, period %u\n", TICS, TIC_US, FPS, hz, period);
	while (spc_ring_load(W, SPC_RING_W_MAGIC) != SPC_RING_MAGIC) {
		spc_ring_dmb();
	}
	spc_ring_dmb();
	depth = spc_ring_load(W, SPC_RING_W_DEPTH);
	stride = spc_ring_load(W, SPC_RING_W_STRIDE);
	max_len = spc_ring_load(W, SPC_RING_W_MAX_LEN);
	offset = spc_ring_load(W, SPC_RING_W_OFFSET);
	head = spc_ring_load(W, SPC_RING_W_HEAD);
	if (spc_ring_load(W, SPC_RING_W_VERSION) != SPC_RING_ABI_VERSION || !spc_ring_geometry_ok(depth, stride, max_len, offset) ||
	    max_len < C_HEADER + CHUNK) {
		printk("R SPC_RING_REFUSED geometry\nR end fail\n");
		return 0;
	}
	for (uint32_t t = 0; t < TICS; t++) {
		uint32_t now = k_cycle_get_32();
		int second = 0;

		if (boot == 0u) {
			boot = spc_ring_load(W, SPC_RING_W_BOOT_ID);
			spc_ring_dmb();
			if (boot != 0u) {
				first_id_tic = t;
				next_due = now;
				next_second = now;
				printk("R B %08x at tic %u\n", boot, t);
			}
		}
		if (boot == 0u) {
			not_sent++;
			not_sent_no_id++;
		} else {
			if ((int32_t)(now - next_second) >= 0) {
				header(0x50u, boot);
				for (uint32_t i = 0; i < 256u; i++) {
					msg[6u + 3u * i] = msg[7u + 3u * i] = msg[8u + 3u * i] = (uint8_t)i;
				}
				if (!put(msg, 774u)) {
					palette_drops++;
				}
				next_second += hz;
				second = 1;
			}
			if ((int32_t)(now - next_due) < 0) {
				not_sent++;
			} else {
				uint32_t p;

				for (p = 0; p < PIECES; p++) {
					header(0x43u, boot);
					w32(6, t);
					msg[10] = (uint8_t)p;
					msg[11] = (uint8_t)PIECES;
					w32(12, 0u); /* no controller */
					w32(16, 0u);
					msg[20] = 0u; /* no input */
					for (uint32_t i = 0; i < CHUNK; i++) {
						uint32_t at = p * CHUNK + i;

						msg[C_HEADER + i] = (uint8_t)(at % WIDTH + 2u * (at / WIDTH) + 3u * t);
					}
					if (!put(msg, C_HEADER + CHUNK)) {
						break;
					}
				}
				if (p == PIECES) {
					frames_sent++;
				} else {
					frames_dropped++;
					msgs_dropped += PIECES - p;
				}
				/* the average's phase; a tic more than a period late restarts it */
				next_due = (int32_t)(now - next_due) >= (int32_t)period ? now + period : next_due + period;
			}
			if (second) {
				/* the counts after this tic: sent + not sent + dropped = t + 1 */
				header(0x53u, boot);
				w32(6, t);
				w32(10, frames_sent);
				w32(14, not_sent);
				w32(18, frames_dropped);
				w32(22, msgs_dropped);
				if (!put(msg, 26u)) {
					stats_drops++;
				}
			}
		}
		t_next += k_us_to_ticks_ceil64(TIC_US);
		k_sleep(K_TIMEOUT_ABS_TICKS(t_next));
	}
	printk("R tics %u sent %u not_sent %u (no id %u, first id at tic %u) dropped %u msgs_dropped %u palette_drops %u stats_drops %u put_count %u head 0x%08x\n",
	       TICS, frames_sent, not_sent, not_sent_no_id, first_id_tic, frames_dropped, msgs_dropped, palette_drops, stats_drops, put_count, head);
	printk("R N %016x %016x %016x\n", frames_dropped, msgs_dropped, not_sent);
	printk("R end ok\n");
	return 0;
}
