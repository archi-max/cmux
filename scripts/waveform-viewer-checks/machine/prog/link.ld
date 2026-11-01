/* Machine-state fixture program (our own). One 64 KiB window at 0x80000000: every fixture core
   resets to 0x80000080 (Ibex's boot_addr + 0x80), and Spike starts there from its boot ROM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K }
SECTIONS {

  .text 0x80000080 : { *(.text.start) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  . = ALIGN(16);
  .data : { *(.data .data.* .sdata .sdata.*) } > RAM
  . = ALIGN(64);
  .tohost : { *(.tohost) } > RAM
  .bss (NOLOAD) : { *(.sbss .sbss.* .bss .bss.* COMMON) } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
