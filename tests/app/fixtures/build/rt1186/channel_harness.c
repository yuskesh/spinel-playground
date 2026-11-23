/* tests/app/fixtures/build/rt1186/channel_harness.c -- tests/app/core-channel.sh 6:
 * the generated put and get of the console contract (channel_core.c.erb)
 * against a region of the host's own, the descriptor written as the
 * companion's main.c writes it (d_words.h, from the same layout).
 *
 *   harness stopped   the consumer never checks its end (0027's control 5,
 *                     --mutate-consumer-stopped): the producer is ready, 16
 *                     puts are accepted and the rest refused, each counted,
 *                     and the consumer's state stays STOPPED
 *   harness taking    both ends checked: puts and gets alternate, every
 *                     field comes out as it went in, and the counts close
 *   harness waits     as taking, with an alignment of one producer cycle per
 *                     consumer cycle (k_prod 1.0, k_cons just below 1.0) and
 *                     the host's counter moving 7 a read: each wait is the
 *                     stamp's read to the copy's end, two reads later, 14
 *                     cycles, 13 after the 0.32 factor's truncation; line M
 *                     and the histogram count all 40
 *
 * Both ends share the one region: SPC_RING_M7_BASE and SPC_RING_M33_BASE are
 * its address. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "ring/ring_abi.h"
#include "ring/wait_map.h"
#include "channel_console.h"
#include "d_words.h"

uint32_t spc_host_region[32768];
volatile struct spc_wait_ref spc_wait_ref;
extern uint32_t spc_channel_console_wait_hist[32];
static uint32_t spc_host_clock;

uint32_t spc_host_cycles(void)
{
	spc_host_clock += 7u;
	return spc_host_clock;
}
int32_t spc_channel_console_get(uint32_t *tic, uint32_t tic_len, uint8_t *len, uint32_t len_len, uint8_t *text, uint32_t text_len);
int32_t spc_channel_console_check_get(void);

static void table(void)
{
	for (uint32_t i = 0; i < 8u; i++) {
		spc_host_region[SPC_CH_D(0u) + i] = d_words[i];
	}
}

static void counts(const char *what)
{
	volatile uint32_t *w = spc_host_region;

	printf("%s P head %u attempted %u accepted %u refused %u C tail %u state %u taken %u\n", what, w[SPC_CH_P(0u)],
	       w[SPC_CH_P(0u) + SPC_CH_P_ATTEMPTED], w[SPC_CH_P(0u) + SPC_CH_P_ACCEPTED], w[SPC_CH_P(0u) + SPC_CH_P_REFUSED],
	       w[SPC_CH_C(0u)], w[SPC_CH_C(0u) + SPC_CH_C_STATE], w[SPC_CH_C(0u) + SPC_CH_C_TAKEN]);
}

int main(int argc, char **argv)
{
	uint8_t text[119], rx_text[119], rx_len[1];
	uint32_t rx_tic[1];
	int ok = 1;

	table();
	if (spc_channel_console_check() != 0) {
		printf("the producer's check refused the table\n");
		return 1;
	}
	if (argc > 1 && strcmp(argv[1], "stopped") == 0) {
		int32_t first = 0, last = 0;

		for (int i = 0; i < 20; i++) {
			int32_t r = spc_channel_console_put((uint32_t)i, 3u, text, 119u);

			first += i < 16 ? r : 0;
			last += i >= 16 ? r : 0;
		}
		printf("stopped accepted-first-16 %d accepted-after %d\n", (int)first, (int)last);
		counts("stopped");
		return 0;
	}
	if (argc > 1 && (strcmp(argv[1], "waits") == 0 || strcmp(argv[1], "longest") == 0)) {
		spc_wait_ref.k_prod = 1u << 16;
		spc_wait_ref.k_cons = 0xFFFFFFFFu;
		spc_wait_ref.valid = 1u;
	}
	if (spc_channel_console_check_get() != 0) {
		printf("the consumer's check refused the table\n");
		return 1;
	}
	for (uint32_t i = 0; i < 40u; i++) {
		memset(text, (int)(0x40u + i), sizeof text);
		ok &= spc_channel_console_put(1000u + i, 5u + i, text, 119u) == 1;
		if (argc > 1 && strcmp(argv[1], "longest") == 0 && i == 27u) {
			spc_host_clock += 1000u; /* message 27 waits longest (line C, lat_max_at) */
		}
		ok &= spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u) == 1;
		ok &= rx_tic[0] == 1000u + i && rx_len[0] == 5u + i && rx_text[0] == (uint8_t)(0x40u + i) && rx_text[118] == (uint8_t)(0x40u + i);
	}
	ok &= spc_channel_console_get(rx_tic, 1u, rx_len, 1u, rx_text, 119u) == 0;
	printf("taking fields %s\n", ok ? "ok" : "differ");
	counts("taking");
	{
		volatile uint32_t *w = spc_host_region;

		printf("waits n %u min %u max %u sum %u bucket3 %u\n", w[SPC_CH_M(0u) + SPC_CH_M_LAT_N], w[SPC_CH_M(0u) + SPC_CH_M_LAT_MIN],
		       w[SPC_CH_M(0u) + SPC_CH_M_LAT_MAX], w[SPC_CH_M(0u) + SPC_CH_M_LAT_SUM_LO], spc_channel_console_wait_hist[3]);
		printf("longest at %u\n", w[SPC_CH_C(0u) + SPC_CH_C_LAT_MAX_AT]);
	}
	return 0;
}
