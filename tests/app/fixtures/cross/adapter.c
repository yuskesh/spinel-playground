/* tests/app/fixtures/cross/adapter.c -- the spike of 0014 Task 2: a trivial
 * board adapter compiled against Zephyr's headers by the kernel's clang. */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <stdint.h>
int32_t spc_board_probe(uint32_t index, int32_t on)
{
	ARG_UNUSED(index);
	return k_is_in_isr() ? 1 : on;
}
