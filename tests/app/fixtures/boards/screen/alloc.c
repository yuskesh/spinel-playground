/* screen control: an adapter that allocates. */
#include <stddef.h>
#include <stdint.h>
extern void *k_malloc(size_t n);
int32_t spc_board_x_set(uint32_t index, uint32_t v) { return k_malloc(index + v) ? 0 : -1; }
