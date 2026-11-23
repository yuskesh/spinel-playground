/* Byte-helper probe: runs the CORE entry `fill` built for thumbv8m and prints
 * its 32 bytes as hex, then the marker the runner waits for. */
#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

int32_t spinel_core_fill(uint8_t *bytes, uint8_t *tag);

int main(void)
{
	uint8_t bytes[32] = {0}, tag[4] = {0};
	int32_t st = spinel_core_fill(bytes, tag);

	printk("SPC_BYTES status=%d ", (int)st);
	for (int i = 0; i < 32; i++) {
		printk("%02x", bytes[i]);
	}
	printk(" SPC_BYTES_DONE\n");
	return 0;
}
