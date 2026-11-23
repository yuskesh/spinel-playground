/* E081 control: uptime_ms returning int32_t (the declaration says i64). */
#include <stdint.h>
#ifdef E081_WITH_HEADER
#include "spinel_freestanding.h"
#endif
int32_t spinel_zephyr_uptime_ms(void) { return 42; }
