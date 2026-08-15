/* SPDX-License-Identifier: Apache-2.0 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 256K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 384K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ROM

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > RAM AT > ROM
    __data_load_start = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    __heap_start = .;
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame .eh_frame.*)
        *(.riscv.attributes)
    }
}

ASSERT(__heap_start < __stack_top, "firmware RAM overflow")
ASSERT(SIZEOF(.text) + SIZEOF(.rodata) + SIZEOF(.data) <= LENGTH(ROM),
       "firmware ROM overflow")
