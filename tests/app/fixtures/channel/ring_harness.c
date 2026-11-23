/* tests/app/fixtures/channel/ring_harness.c -- single-threaded ring tests on
 * the host, over the generated channel units (decision 0014 §5): wraparound
 * over 10 x depth, FIFO order without duplicates, a full refusal that leaves
 * the ring unchanged, 0 from an empty ring; and the guards through the
 * generated Ruby modules, on the entries the kernel built natively.
 * Prints `  ok <what>` or `  FAIL <what>` per check and a summary line. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "channel_telemetry.h"
#include "channel_commands.h"

int32_t spinel_core_report(uint8_t *frame);
int32_t spinel_core_send_n(uint8_t *frame, uint32_t *n);
int32_t spinel_core_poll(uint8_t *command, int32_t *got);

static int fails;
static void check(const char *what, int cond)
{
	printf("  %s %s\n", cond ? "ok" : "FAIL", what);
	if (!cond) fails++;
}

int main(void)
{
	uint8_t msg[16], out[16];
	uint32_t i, k;
	int all_fifo = 1, all_len = 1, all_queued = 1;

	/* wraparound over 10 x depth: put one, get one, 40 times; every message
	 * comes back once, in order, with its length */
	for (i = 0; i < 10u * SPC_CHANNEL_TELEMETRY_DEPTH; i++) {
		uint32_t n = 1u + (i % SPC_CHANNEL_TELEMETRY_SIZE);
		for (k = 0; k < n; k++) msg[k] = (uint8_t)(i + k);
		if (spc_channel_telemetry_put(msg, 16, n) != 1) all_queued = 0;
		memset(out, 0xee, sizeof out);
		if ((uint32_t)spc_channel_telemetry_get(out, 16) != n) all_len = 0;
		if (memcmp(out, msg, n) != 0) all_fifo = 0;
	}
	check("wraparound over 10 x depth: every put queued", all_queued);
	check("wraparound: every get returned its message's length", all_len);
	check("wraparound: every message came back intact", all_fifo);
	check("wraparound: the ring is empty after", spc_channel_telemetry_occupancy() == 0);

	/* FIFO order and no duplicate: fill to depth, then drain */
	for (i = 0; i < SPC_CHANNEL_TELEMETRY_DEPTH; i++) {
		msg[0] = (uint8_t)(0x10 + i);
		check("fill: a put into a ring with room is queued", spc_channel_telemetry_put(msg, 16, 1) == 1);
	}
	check("full: occupancy equals depth", spc_channel_telemetry_occupancy() == SPC_CHANNEL_TELEMETRY_DEPTH);
	msg[0] = 0x99;
	check("full refusal: put returns 0", spc_channel_telemetry_put(msg, 16, 1) == 0);
	check("full refusal: occupancy unchanged", spc_channel_telemetry_occupancy() == SPC_CHANNEL_TELEMETRY_DEPTH);
	all_fifo = 1;
	for (i = 0; i < SPC_CHANNEL_TELEMETRY_DEPTH; i++) {
		int32_t n = spc_channel_telemetry_get(out, 16);
		if (n != 1 || out[0] != (uint8_t)(0x10 + i)) all_fifo = 0;
	}
	check("full refusal: the ring's contents were unchanged, first in first out, each once", all_fifo);
	check("empty: get returns 0", spc_channel_telemetry_get(out, 16) == 0);
	check("empty: a second get returns 0 too", spc_channel_telemetry_get(out, 16) == 0);

	/* the guards through the generated Ruby modules: send_n with n = 0, 17, 5 */
	{
		uint8_t frame[16] = {0};
		uint32_t n;
		int32_t got;
		uint8_t command[8] = {0};
		uint8_t in[8] = {7, 8, 9};
		n = 0;
		check("guard: Telemetry.put(frame, 0) is ARGUMENT (1), nothing queued",
		      spinel_core_send_n(frame, &n) == 1 && spc_channel_telemetry_occupancy() == 0);
		n = 17;
		check("guard: Telemetry.put(frame, 17) is BOUNDS (3), nothing queued",
		      spinel_core_send_n(frame, &n) == 3 && spc_channel_telemetry_occupancy() == 0);
		n = 5;
		check("guard: Telemetry.put(frame, 5) is OK (0) and queues one", spinel_core_send_n(frame, &n) == 0 && spc_channel_telemetry_occupancy() == 1);
		check("send_n's message drained", spc_channel_telemetry_get(out, 16) == 5);
		check("report: the entry's message is the five bytes it wrote",
		      spinel_core_report(frame) == 0 && spc_channel_telemetry_get(out, 16) == 5 &&
		      out[0] == 1 && out[1] == 2 && out[2] == 3 && out[3] == 4 && out[4] == 5);
		check("poll: Commands.get on an empty ring is 0", spinel_core_poll(command, &got) == 0 && got == 0);
		check("poll: after the transport's put, Commands.get returns the length and the bytes",
		      spc_channel_commands_put(in, 8, 3) == 1 && spinel_core_poll(command, &got) == 0 && got == 3 && command[0] == 7 && command[2] == 9);
	}
	printf("harness: %d failed\n", fails);
	return fails ? 1 : 0;
}
