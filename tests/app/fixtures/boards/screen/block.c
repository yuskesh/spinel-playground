/* screen control: an adapter that sleeps. */
#include <stdint.h>
extern int32_t k_sleep(int64_t t);
int32_t spc_board_x_set(uint32_t index, uint32_t v) { return k_sleep((int64_t)index + v); }
