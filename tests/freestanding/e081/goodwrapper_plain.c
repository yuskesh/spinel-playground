/* E081: a host-compilable (no Zephyr headers) wrapper set with the SAME
 * signatures as zephyr/src/spinel_zephyr.c.  Two uses:
 *   1. an extern-check.py MATCH control on text the scanner fully sees;
 *   2. the dynamic backing of the scan (E062): compiled with the GENERATED
 *      header #included, the C compiler independently accepts these
 *      signatures -- and refuses the badwrappers/ variants.
 * The bodies follow the same documented contract as every other leg. */
#include <stdint.h>
#ifdef E081_WITH_HEADER
#include "spinel_freestanding.h"
#endif

static int32_t pin_shadow[8];

int64_t spinel_zephyr_uptime_ms(void) { return 1000; }
int32_t spinel_zephyr_sleep_ms(int32_t ms) { return 0; }
int32_t spinel_zephyr_print_i64(int64_t v) { return 0; }
int32_t spinel_zephyr_gpio_set(int32_t pin, int32_t val)
{
	if (pin < 0 || pin > 7 || val < 0 || val > 1) return -1;
	pin_shadow[pin] = val;
	return val;
}
int32_t spinel_zephyr_gpio_get(int32_t pin)
{
	if (pin < 0 || pin > 7) return -1;
	return pin_shadow[pin];
}
double spinel_zephyr_sense_scale(float a, double b) { return (double)a * 2.0 + b; }
uint32_t spinel_zephyr_checksum32(uint32_t v) { return v ^ 0xA5A5A5A5u; }
