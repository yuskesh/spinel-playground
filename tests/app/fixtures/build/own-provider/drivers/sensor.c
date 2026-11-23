/* The accepted provider: a pure function of its argument and a static
 * counter, no Zephyr call, so the screen of 0014 §6 passes it and its
 * -fstack-usage frame is its whole stack. The prototype comes from the
 * generated externs.h the build includes ahead of this file. */
#include <stdint.h>
static uint32_t spc_sensor_ticks;
int32_t spc_app_sensor_read(uint32_t ch)
{
	spc_sensor_ticks++;
	return (int32_t)((spc_sensor_ticks & 0xffu) + ch);
}
