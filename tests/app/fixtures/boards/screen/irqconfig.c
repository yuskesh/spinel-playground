/* screen control: an adapter that installs an interrupt handler at run time. */
#include <stdint.h>
extern int irq_connect_dynamic(unsigned int irq, unsigned int prio, void (*f)(const void *), const void *p, uint32_t flags);
static void handler(const void *p) { (void)p; }
int32_t spc_board_x_set(uint32_t index, uint32_t v) { return irq_connect_dynamic(index, v, handler, 0, 0); }
