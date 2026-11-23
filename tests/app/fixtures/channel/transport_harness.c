/* tests/app/fixtures/channel/transport_harness.c -- the UART transport on
 * the host (decision 0014 §5): frames out of the :out ring reach the UART,
 * frames in fill the :in ring, and a drop happens only as oversize or
 * channel_full, counted per reason; a channel_full drop only at occupancy ==
 * depth. Built with -DSPC_MUTATE_DROP_WITH_ROOM, the transport is the plan's
 * kept failing input, and the conservation check here fails. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "channel_telemetry.h"
#include "channel_commands.h"

void spc_transport_step(void);
extern uint32_t spc_transport_drops[2][2];
extern uint32_t spc_transport_framing_errors;
extern uint32_t spc_transport_tx_count[2];

static uint8_t uart_tx[1024];
static uint32_t uart_tx_n;
static uint8_t uart_rx[1024];
static uint32_t uart_rx_n, uart_rx_pos;

void spc_uart_out(uint8_t b) { if (uart_tx_n < sizeof uart_tx) uart_tx[uart_tx_n++] = b; }
int spc_uart_in(uint8_t *b) { if (uart_rx_pos < uart_rx_n) { *b = uart_rx[uart_rx_pos++]; return 1; } return 0; }
static void feed(uint8_t channel, const uint8_t *p, uint32_t n)
{
	uart_rx[uart_rx_n++] = 0xA5; uart_rx[uart_rx_n++] = channel; uart_rx[uart_rx_n++] = (uint8_t)n;
	memcpy(uart_rx + uart_rx_n, p, n); uart_rx_n += n;
}

static int fails;
static void check(const char *what, int cond)
{
	printf("  %s %s\n", cond ? "ok" : "FAIL", what);
	if (!cond) fails++;
}

int main(void)
{
	uint8_t m1[3] = {1, 2, 3}, m2[2] = {4, 5}, big[9] = {0}, m3[1] = {6}, m4[1] = {7}, out[8];
	uint32_t accepted = 0, dropped_full = 0;

	/* outbound: two messages in the :out ring, one step, two frames on the UART */
	spc_channel_telemetry_put(m1, 16, 3);
	spc_channel_telemetry_put(m2, 16, 2);
	spc_transport_step();
	check("outbound: both rings drained to the UART as two frames", spc_transport_tx_count[0] == 2 && uart_tx_n == 3 + 3 + 3 + 2);
	check("outbound: the first frame is SOF, channel 0, length 3, payload", uart_tx[0] == 0xA5 && uart_tx[1] == 0 && uart_tx[2] == 3 && uart_tx[3] == 1 && uart_tx[5] == 3);
	check("outbound: the :out ring is empty after the drain", spc_channel_telemetry_occupancy() == 0);

	/* inbound, one frame per step, the ring's occupancy read before each:
	 * a frame is queued only with room, dropped as channel_full only at
	 * occupancy == depth, and as oversize only above size. m1, m2 fit
	 * (depth 2); big is oversize; m3 finds the ring full; after one get, m4
	 * fits; then m4 again finds it full. */
	{
		struct { const uint8_t *p; uint32_t n; const char *expect; } seq[] = {
			{ m1, 3, "queued" }, { m2, 2, "queued" }, { big, 9, "oversize" }, { m3, 1, "full" },
			{ NULL, 0, "get" }, { m4, 1, "queued" }, { m4, 1, "full" },
		};
		uint32_t i, rule_ok = 1, seq_ok = 1;
		for (i = 0; i < sizeof seq / sizeof seq[0]; i++) {
			uint32_t before = spc_channel_commands_occupancy();
			uint32_t full0 = spc_transport_drops[1][1], over0 = spc_transport_drops[1][0];
			const char *got;
			if (seq[i].p == NULL) {
				got = spc_channel_commands_get(out, 8) > 0 ? "get" : "empty";
			} else {
				uart_rx_n = uart_rx_pos = 0;
				feed(1, seq[i].p, seq[i].n);
				spc_transport_step();
				if (spc_transport_drops[1][0] > over0) got = "oversize";
				else if (spc_transport_drops[1][1] > full0) { got = "full"; dropped_full++; if (before != SPC_CHANNEL_COMMANDS_DEPTH) rule_ok = 0; }
				else if (spc_channel_commands_occupancy() == before + 1) { got = "queued"; accepted++; }
				else got = "lost";
			}
			if (strcmp(got, seq[i].expect) != 0) { printf("    frame %u: %s, expected %s (occupancy before %u)\n", i, got, seq[i].expect, before); seq_ok = 0; }
		}
		check("inbound: every frame ends as the sequence says (queued, oversize, full, queued, full)", seq_ok);
		check("drop rule: a channel_full drop only at occupancy == depth", rule_ok);
		check("drop rule: 3 frames queued and 2 dropped as channel_full over the sequence", accepted == 3 && dropped_full == 2);
		check("inbound: the oversize frame is counted once", spc_transport_drops[1][0] == 1);
		check("inbound: no framing error", spc_transport_framing_errors == 0);
		check("conservation: the messages come out in order", spc_channel_commands_get(out, 8) == 2 && out[0] == 4 && spc_channel_commands_get(out, 8) == 1 && out[0] == 7);
		check("occupancy before the out-channel test is 0", spc_channel_commands_occupancy() == 0);
	}
	/* a frame for the :out channel, and one for an unknown channel, are framing errors, not drops */
	uart_rx_n = uart_rx_pos = 0;
	feed(0, m4, 1); feed(7, m4, 1);
	spc_transport_step();
	check("a frame naming an :out channel or an unknown index is a framing error, not a drop", spc_transport_framing_errors == 2 && spc_transport_drops[1][0] == 1 && spc_transport_drops[1][1] == 2);
	printf("harness: %d failed\n", fails);
	return fails ? 1 : 0;
}
