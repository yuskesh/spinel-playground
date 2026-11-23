/* screen control: an adapter that calls back into a CORE entry. */
#include <stdint.h>
extern int32_t spinel_core_sample(int32_t *reading);
int32_t spc_board_x_set(uint32_t index, uint32_t v) { int32_t r = (int32_t)(index + v); return spinel_core_sample(&r); }
