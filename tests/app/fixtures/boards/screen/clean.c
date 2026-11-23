/* screen control: an adapter that calls only a driver operation. */
#include <stdint.h>
extern int gpio_pin_set_raw(const void *port, uint32_t pin, int value);
int32_t spc_board_x_set(uint32_t index, uint32_t v) { return gpio_pin_set_raw(0, index, v != 0u); }
