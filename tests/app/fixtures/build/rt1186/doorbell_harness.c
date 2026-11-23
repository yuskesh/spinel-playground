/* tests/app/fixtures/build/rt1186/doorbell_harness.c -- tests/app/core-channel.sh 7:
 * the generated put and get of the console contract with the doorbell of
 * decision 0028 (notify 0x01, MU1's GIR0), against a region of the host's
 * own and a host word in place of the producer's GCR (SPC_DOORBELL_GCR).
 *
 *   harness bell     the get of an empty ring stores waiting = 1; a put then
 *                    rings (GIR0 set, rung 1); a second put while GIR0 is
 *                    still set does not ring again; the host clears GIR0, as
 *                    the receiver's GSR write does; the get takes both and
 *                    stores waiting = 0, and the next empty get waiting = 1;
 *                    a put rings again (rung 2)
 *   harness unrung   the same with the put of --mutate-doorbell-unrung: GIR0
 *                    never set, rung 0, every message still taken
 *   harness notify   a descriptor whose notify is 0 is refused by the
 *                    producer's check, naming the flags word (D + 2) plus 1 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "ring/ring_abi.h"
#include "ring/wait_map.h"
#include "channel_console.h"
#include "d_words.h"

uint32_t spc_host_region[32768];
volatile uint32_t spc_host_gcr;
volatile struct spc_wait_ref spc_wait_ref;
static uint32_t spc_host_clock;

uint32_t spc_host_cycles(void)
{
	spc_host_clock += 7u;
	return spc_host_clock;
}
int32_t spc_channel_console_get(uint32_t *tic, uint32_t tic_len, uint8_t *len, uint32_t len_len, uint8_t *text, uint32_t text_len);
int32_t spc_channel_console_check_get(void);

static uint32_t word(uint32_t line, uint32_t i)
{
	return spc_host_region[line + i];
}

int main(int argc, char **argv)
{
	uint8_t text[119], rx_text[119], rx_len[1];
	uint32_t rx_tic[1];
	const char *what = argc > 1 ? argv[1] : "bell";

	for (uint32_t i = 0; i < 8u; i++) {
		spc_host_region[SPC_CH_D(0u) + i] = d_words[i];
	}
	if (strcmp(what, "notify") == 0) {
		spc_host_region[SPC_CH_D(0u) + SPC_CH_D_FLAGS] &= 0x00FFFFFFu;
		printf("notify check %d\n", (int)spc_channel_console_check());
		return 0;
	}
	if (spc_channel_console_check() != 0 || spc_channel_console_check_get() != 0) {
		printf("%s the checks refused the table\n", what);
		return 1;
	}
	memset(text, 0x41, sizeof text);
	printf("%s get-empty %d waiting %u\n", what, (int)spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u),
	       word(SPC_CH_C(0u), SPC_CH_C_WAITING));
	spc_channel_console_put(1u, 3u, text, 119u);
	printf("%s put rung %u gcr %u\n", what, word(SPC_CH_P(0u), SPC_CH_P_RUNG), spc_host_gcr);
	spc_channel_console_put(2u, 3u, text, 119u);
	printf("%s put-pending rung %u gcr %u\n", what, word(SPC_CH_P(0u), SPC_CH_P_RUNG), spc_host_gcr);
	spc_host_gcr = 0u; /* the receiver cleared GIP0, which clears GIR0 */
	{
		int32_t a = spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u);
		uint32_t wa = word(SPC_CH_C(0u), SPC_CH_C_WAITING);
		int32_t b = spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u);
		int32_t c = spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u);

		printf("%s take %d waiting %u, %d, then empty %d waiting %u\n", what, (int)a, wa, (int)b, (int)c,
		       word(SPC_CH_C(0u), SPC_CH_C_WAITING));
	}
	spc_channel_console_put(3u, 3u, text, 119u);
	printf("%s put rung %u gcr %u taken %u\n", what, word(SPC_CH_P(0u), SPC_CH_P_RUNG), spc_host_gcr,
	       word(SPC_CH_C(0u), SPC_CH_C_TAKEN));
	return 0;
}
