/* tests/app/fixtures/channel/arm_main.c -- the entry of the two-channel
 * thumbv8m link fixture: references every CORE entry and the transport so
 * nothing is garbage-collected, and stubs the UART. Never run. */
#include <stdint.h>
void spc_uart_out(uint8_t b) { (void)b; }
int spc_uart_in(uint8_t *b) { (void)b; return 0; }
void spc_transport_step(void);
int32_t spinel_core_report(uint8_t *frame);
int32_t spinel_core_send_n(uint8_t *frame, uint32_t *n);
int32_t spinel_core_poll(uint8_t *command, int32_t *got);
int spc_main(void)
{
	uint8_t frame[16], command[8]; uint32_t n = 5; int32_t got;
	int32_t s = spinel_core_report(frame) + spinel_core_send_n(frame, &n) + spinel_core_poll(command, &got);
	spc_transport_step();
	return (int)s;
}
