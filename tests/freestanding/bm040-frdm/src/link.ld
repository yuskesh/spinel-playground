/* bm040-frdm: the memory map of the secure Cortex-M33 (CPU0) of the NXP MCX
 * N947 on the FRDM-MCXN947 board.
 *
 * Code at 0x10000000 (2 MB): the internal flash as CPU0 sees it in secure
 * state. Zephyr's dts/arm/nxp/mcx/nxp_mcxnx4x_common.dtsi has
 * `flash: flash@0`, DT_SIZE_M(2), under the flash controller, whose ranges in
 * nxp_mcxn94x.dtsi map 0x0 to 0x10000000. The boot ROM starts the image from
 * the vector table at the start of this flash.
 *
 * RAM at 0x30000000 (32 KB): RAMA, the first SRAM block, in its secure alias.
 * nxp_mcxnx4x_common.dtsi has `sram0: memory@20000000` and lists RAMA as its
 * first 32 KB; nxp_mcxn94x.dtsi's `sram@14000000` ranges map 0x04000000 to
 * 0x14000000, so 0x20000000 is 0x30000000 secure. Zephyr's own image for this
 * board starts with an initial stack pointer in this block. One block is far
 * more than the driver needs, and it keeps the image clear of how the blocks
 * are shared with CPU1 and of the RAM ECC setting. The stack grows down from
 * its end.
 */
MEMORY
{
  CODE (rx)  : ORIGIN = 0x10000000, LENGTH = 2M
  RAM  (rwx) : ORIGIN = 0x30000000, LENGTH = 32K
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
