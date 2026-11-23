/* The refused provider: it sleeps, a blocking primitive, which no provider
 * of a CORE extern may reach (0014 §6). */
#include <stdint.h>
#include <zephyr/kernel.h>
int32_t spc_app_sensor_read(uint32_t ch)
{
	k_msleep(1);
	return (int32_t)ch;
}
