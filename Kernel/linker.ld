OUTPUT_ARCH(aarch64)
ENTRY(_start)

KERNEL_LOAD_ADDRESS = 0x40080000;
BOOT_STACK_SIZE = 64K;
DMA_SCRATCH_SIZE = 4K;
TERMINAL_STORAGE_SIZE = 8K;
FRAMEBUFFER_SIZE = 800 * 600 * 4;

SECTIONS
{
    . = KERNEL_LOAD_ADDRESS;
    __kernel_start = .;

    .text : ALIGN(4K)
    {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(4K)
    {
        *(.rodata .rodata.*)
        *(.swift5* swift5*)
    }

    .data : ALIGN(4K)
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    }

    .bss (NOLOAD) : ALIGN(4K)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    .page_tables (NOLOAD) : ALIGN(4K)
    {
        __early_l1_table = .;
        . += 4K;
        __early_l1_table_end = .;
    }

    .boot_stack (NOLOAD) : ALIGN(16)
    {
        __boot_stack_bottom = .;
        . += BOOT_STACK_SIZE;
        __boot_stack_top = .;
    }

    .dma_scratch (NOLOAD) : ALIGN(4K)
    {
        __dma_scratch_start = .;
        . += DMA_SCRATCH_SIZE;
        __dma_scratch_end = .;
    }

    .terminal_storage (NOLOAD) : ALIGN(4K)
    {
        __terminal_storage_start = .;
        . += TERMINAL_STORAGE_SIZE;
        __terminal_storage_end = .;
    }

    .framebuffer (NOLOAD) : ALIGN(4K)
    {
        __framebuffer_start = .;
        . += FRAMEBUFFER_SIZE;
        __framebuffer_end = .;
    }

    . = ALIGN(4K);
    __kernel_end = .;

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}

ASSERT((__boot_stack_top & 15) == 0, "boot stack must be 16-byte aligned")
ASSERT((__dma_scratch_start & 4095) == 0, "DMA scratch must be page aligned")
ASSERT((__terminal_storage_start & 4095) == 0, "terminal storage must be page aligned")
ASSERT((__framebuffer_start & 4095) == 0, "framebuffer must be page aligned")
ASSERT(__kernel_end < 0x42000000, "early kernel exceeds reserved 32 MiB window")
