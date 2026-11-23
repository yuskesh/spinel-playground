/* tools/app/adapters/led/adapter.h -- the Led adapter over gpio-leds. */
#ifndef SPC_ADAPTER_LED_H
#define SPC_ADAPTER_LED_H
#include <stdint.h>
#include <zephyr/drivers/gpio.h>
/* Configures every LED of the table as an output, off. Called from the
 * generated glue at start, before any entry runs. */
int32_t spc_adapter_led_init(const struct gpio_dt_spec *table, uint32_t count);
/* Sets LED `index` on (duty != 0) or off. The index is in range: the kernel
 * guards `index < COUNT` before the call (0014 plan, D2). */
int32_t spc_adapter_led_set(const struct gpio_dt_spec *table, uint32_t index, uint32_t duty);
/* The safe state (0014 §4, failure): every LED off. */
void spc_adapter_led_safe(const struct gpio_dt_spec *table, uint32_t count);
#endif
