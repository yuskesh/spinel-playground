/* The refused provider: it prints. printk reaches picolibc's vfprintf and the
 * console driver, frames its evidence would not count (on the 224-byte
 * scheduler stack of tests/app/stress, that path overran into the transport
 * thread's stack). */
#include <stdint.h>
#include <zephyr/sys/printk.h>
int32_t spc_app_sensor_read(uint32_t ch)
{
	printk("read %u\n", (unsigned)ch);
	return (int32_t)ch;
}
