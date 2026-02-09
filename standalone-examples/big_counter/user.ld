/*
 * Linker script for all user-space binaries (programs, services, drivers)
 * 
 * Entry point at offset 0 in the flat binary.
 * The kernel binary_loader handles loading and memory setup.
 * Capability differences are managed by the container table, not here.
 */

ENTRY(_start)

SECTIONS
{
    /* Start at 64KB to avoid null pointer issues */
    . = 0x10000;
    
    /* Single section containing everything, starting with _start */
    .all : {
        KEEP(*(.text._start))
        KEEP(*(.text*))
        *(.rodata*)
        *(.data*)
        *(.bss*)
    }
    
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.ARM.*) }
}

