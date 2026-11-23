/* tests/app/fixtures/channel/bytes_harness.c -- runs the natively built
 * `fill` entry and prints its 32 bytes as hex, to compare with bytes.rb. */
#include <stdint.h>
#include <stdio.h>
int32_t spinel_core_fill(uint8_t *bytes, uint8_t *tag);
int main(void)
{
	uint8_t bytes[32] = {0}, tag[4] = {0};
	int32_t st = spinel_core_fill(bytes, tag);
	if (st != 0) { printf("status %d\n", (int)st); return 1; }
	for (int i = 0; i < 32; i++) printf("%02x", bytes[i]);
	printf("\n");
	return 0;
}
