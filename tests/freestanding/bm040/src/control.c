/* bm040: the image checks' control. Linked into bm_control.elf only, beside
 * the real inputs, it is an input that is neither the driver, kern.o nor a
 * builtins member; it defines a symbol none of those define; and it leaves a
 * reference unresolved. Each image check has to fail on that image, or it
 * could not have failed on the real ones. The image is never run. */
void bm_control_missing(void);

void bm_control_foreign(void)
{
	bm_control_missing();
}
