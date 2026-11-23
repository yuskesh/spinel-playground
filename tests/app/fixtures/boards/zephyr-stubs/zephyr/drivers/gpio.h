/* stand-in: see README.md */
#ifndef STUB_ZEPHYR_GPIO_H
#define STUB_ZEPHYR_GPIO_H
#include <stdint.h>
#include <stdbool.h>
struct device { int dummy; };
struct gpio_dt_spec { const struct device *port; uint8_t pin; uint32_t dt_flags; };
#define GPIO_DT_SPEC_GET(node, prop) { 0, 0, 0 }
#define GPIO_OUTPUT_INACTIVE 1u
#define GPIO_INPUT 2u
bool gpio_is_ready_dt(const struct gpio_dt_spec *s);
int gpio_pin_configure_dt(const struct gpio_dt_spec *s, uint32_t flags);
int gpio_pin_set_dt(const struct gpio_dt_spec *s, int value);
int gpio_pin_get_dt(const struct gpio_dt_spec *s);
#endif
