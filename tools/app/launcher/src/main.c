/* The launcher's work is done before main (decision 0023): the SoC's reset
 * hook and PRE_KERNEL_2 init release the Cortex-M7. As the network firmware
 * (SPC_NET_FIRMWARE, decision 0024's amendment) main then forwards the
 * ring's messages for ever (net/forward.c). */
#if defined(SPC_NET_FIRMWARE)
void spc_net_forward(void);
#endif

int main(void)
{
#if defined(SPC_NET_FIRMWARE)
	spc_net_forward();
#endif
	return 0;
}
