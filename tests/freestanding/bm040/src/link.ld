/* bm040: the memory map of the secure Cortex-M33 (CPU0) of QEMU's mps2-an521.
 *
 * Code at 0x10000000 (4 MB): the secure alias of SSRAM-0. QEMU's
 * hw/arm/mps2-tz.c maps ssram-0 at 0x00000000, 4 MB, and sets the SSE-200's
 * init-svtor to 0x10000000, so the reset vector table is read from here.
 * Zephyr's boards/arm/mps2/mps2_an521_cpu0.dts names the same region ssram1,
 * `memory@10000000`, DT_SIZE_M(4), and links its flash image there.
 *
 * RAM at 0x38000000 (4 MB): the secure alias of SSRAM-1 and SSRAM-2 (QEMU:
 * ssram-1 at 0x28000000 and ssram-2 at 0x28200000, 2 MB each; Zephyr:
 * ssram2_3, `memory@38000000`, DT_SIZE_M(4)). The stack grows down from its
 * end.
 */
MEMORY
{
  CODE (rx)  : ORIGIN = 0x10000000, LENGTH = 4M
  RAM  (rwx) : ORIGIN = 0x38000000, LENGTH = 4M
}

ENTRY(Reset_Handler)
__stack_top = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
  .vectors : { KEEP(*(.vectors)) } > CODE
  .text : { *(.text .text.*) } > CODE
  .rodata : { *(.rodata .rodata.*) } > CODE
  .ARM.exidx : { *(.ARM.exidx .ARM.exidx.*) } > CODE

  .data : ALIGN(4)
  {
    __data_start = .;
    *(.data .data.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT > CODE
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM
}
