/* E081 control: a `static` wrapper -- right signature, unlinkable symbol. */
#include <stdint.h>
static int32_t spinel_zephyr_gpio_get(int32_t pin) { return pin; }
/* referenced so the TU compiles warning-free on its own */
int32_t e081_touch(void) { return spinel_zephyr_gpio_get(0); }
