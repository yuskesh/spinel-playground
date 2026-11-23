/* A provider whose definition drops the `_len` parameter: it must fail to
 * compile against the generated extern header. */
#include <stdint.h>
#include "externs.h"
int32_t spc_channel_telemetry_put(const uint8_t *data, uint32_t n) { (void)data; return (int32_t)n; }
