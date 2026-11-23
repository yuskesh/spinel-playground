/* screen control: an adapter that calls a generated entry wrapper. */
#include <stdint.h>
extern int32_t spc_entry_blink(void);
int32_t spc_board_x_set(uint32_t index, uint32_t v) { return (int32_t)(index + v) + spc_entry_blink(); }
