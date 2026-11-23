/* tools/app/adapters/button/adapter.c -- the Button adapter over gpio-keys.
 *
 * Buttons are polled by entries; no interrupt callback is configured, so no
 * callback into CORE exists and no claim of interrupt context rests on the
 * GPIO emulator (0014 §10). gpio_pin_get_dt is one register read on the
 * memory-mapped drivers the effect table attests. */
#include "adapter.h"

int32_t spc_adapter_button_init(const struct gpio_dt_spec *table, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		if (!gpio_is_ready_dt(&table[i])) {
			return -1;
		}
		if (gpio_pin_configure_dt(&table[i], GPIO_INPUT) != 0) {
			return -1;
		}
	}
	return 0;
}

int32_t spc_adapter_button_read(const struct gpio_dt_spec *table, uint32_t index)
{
	int v = gpio_pin_get_dt(&table[index]);
	return v < 0 ? -1 : (v != 0 ? 1 : 0);
}
