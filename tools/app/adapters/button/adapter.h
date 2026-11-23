/* tools/app/adapters/button/adapter.h -- the Button adapter over gpio-keys, polled. */
#ifndef SPC_ADAPTER_BUTTON_H
#define SPC_ADAPTER_BUTTON_H
#include <stdint.h>
#include <zephyr/drivers/gpio.h>
int32_t spc_adapter_button_init(const struct gpio_dt_spec *table, uint32_t count);
/* The logical level of button `index`: 1 pressed, 0 released, -1 when the
 * driver reports an error. Polled; no callback reaches CORE (0014 §10). */
int32_t spc_adapter_button_read(const struct gpio_dt_spec *table, uint32_t index);
#endif
