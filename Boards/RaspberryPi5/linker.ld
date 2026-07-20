OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(rpi5_image_entry)

IMAGE_LOAD_ADDRESS = 0x00080000;
UPDATE_DESTINATION_SIZE = 32M;
/* Match the universal desktop/driver stack contract used by QEMU. */
BOOT_STACK_SIZE = 128K;
SECONDARY_STACK_SIZE = 64K;
USER_STACK_SIZE = 64K;
STACK_GUARD_SIZE = 4K;
DMA_SCRATCH_SIZE = 4K;
RP1_GEM_WORKSPACE_SIZE = 16K;
STORAGE_SCRATCH_SIZE = 4K;
TERMINAL_STORAGE_SIZE = 8K;
FRAMEBUFFER_SIZE = 800 * 600 * 4;
CLASSIFIED_FREE_RUN_STORAGE_SIZE = 24K;
CLASSIFIED_ALLOCATION_LEDGER_SIZE = 24K;
FINAL_L2_TABLE_COUNT = 32;
FINAL_L3_TABLE_COUNT = 96;
DEBUG_LOG_STORAGE_SIZE = 64K;
RPI5_BCM_HIGH_MMIO_L1_DESCRIPTOR = 0x0060001040000401;

SECTIONS
{
    . = IMAGE_LOAD_ADDRESS;
    __image_start = .;
    __kernel_start = .;

    .image_header : ALIGN(8)
    {
        KEEP(*(.text.image_header))
    }

    .text : ALIGN(4K)
    {
        __kernel_text_start = .;
        KEEP(*(.text.boot))
        *(EXCLUDE_FILE (*userland.o) .text .text.*)
        __kernel_text_end = .;
    }

    .user_text : ALIGN(4K)
    {
        __user_text_start = .;
        KEEP(*userland.o(.text.swiftos_user_init))
        *userland.o(.text .text.*)
        __user_text_end = .;
    }

    .rodata : ALIGN(4K)
    {
        __kernel_rodata_start = .;
        *(EXCLUDE_FILE (*userland.o) .rodata .rodata.*)
        *(EXCLUDE_FILE (*userland.o) .swift5* swift5*)
        __kernel_rodata_end = .;
    }

    .user_rodata : ALIGN(4K)
    {
        __user_rodata_start = .;
        *userland.o(.rodata .rodata.*)
        *userland.o(.swift5* swift5* .swift_modhash)
        __user_rodata_end = .;
    }

    .data : ALIGN(4K)
    {
        __kernel_data_start = .;
        __data_start = .;
        *(EXCLUDE_FILE (*userland.o) .data .data.*)
        __data_end = .;
    }

    .bss (NOLOAD) : ALIGN(4K)
    {
        __bss_start = .;
        *(EXCLUDE_FILE (*userland.o) .bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    .page_tables (NOLOAD) : ALIGN(4K)
    {
        __early_l1_table = .;
        . += 4K;
        __early_l1_table_end = .;
        __final_l1_table = .;
        . += 4K;
        __final_l1_table_end = .;
        __final_l2_tables = .;
        . += FINAL_L2_TABLE_COUNT * 4K;
        __final_l2_tables_end = .;
        __final_l3_tables = .;
        . += FINAL_L3_TABLE_COUNT * 4K;
        __final_l3_tables_end = .;
    }

    .boot_stack (NOLOAD) : ALIGN(4K)
    {
        __boot_stack_bottom = .;
        . += STACK_GUARD_SIZE;
        __boot_stack_usable_bottom = .;
        . += BOOT_STACK_SIZE - STACK_GUARD_SIZE;
        __boot_stack_top = .;
    }

    .secondary_stacks (NOLOAD) : ALIGN(4K)
    {
        __secondary_stacks_start = .;
        . += 3 * SECONDARY_STACK_SIZE;
        __secondary_stacks_end = .;
    }

    .user_stacks (NOLOAD) : ALIGN(4K)
    {
        __user_stack0_physical = .;
        . += USER_STACK_SIZE;
        __user_stack0_physical_end = .;
        __user_stack1_physical = .;
        . += USER_STACK_SIZE;
        __user_stack1_physical_end = .;
    }

    .thread_contexts (NOLOAD) : ALIGN(4K)
    {
        __thread_contexts_start = .;
        . += 4K;
        __thread_contexts_end = .;
    }

    .scheduler_storage (NOLOAD) : ALIGN(4K)
    {
        __scheduler_threads_start = .;
        . += 4K;
        __scheduler_current_indices = .;
        . += 4K;
        __scheduler_storage_end = .;
    }

    .smp_storage (NOLOAD) : ALIGN(4K)
    {
        __smp_topology_storage = .;
        . += 512;
        __smp_target_storage = .;
        . += 256;
        __smp_state_storage = .;
        . += 64;
        __smp_report_storage = .;
        . += 512;
        __smp_work_thread_storage = .;
        . += 512;
        __smp_work_index_storage = .;
        . += 64;
        __smp_work_context_storage = .;
        . += 512;
        __smp_work_result_storage = .;
        . += 256;
        __smp_work_state_storage = .;
        . += 64;
        __smp_work_stack_storage = .;
        . += 64;
        . = ALIGN(4K);
        __smp_storage_end = .;
    }

    .paging_layout_storage (NOLOAD) : ALIGN(4K)
    {
        __paging_layout_storage = .;
        . += 4K;
        __paging_layout_storage_end = .;
    }

    .debug_log_storage (NOLOAD) : ALIGN(4K)
    {
        __debug_log_storage_start = .;
        . += DEBUG_LOG_STORAGE_SIZE;
        __debug_log_storage_end = .;
    }

    .memory_metadata (NOLOAD) : ALIGN(4K)
    {
        __memory_map_storage = .;
        . += 4K;
        __page_allocator_storage = .;
        . += 8K;
        __classified_free_run_storage = .;
        . += CLASSIFIED_FREE_RUN_STORAGE_SIZE;
        __classified_free_run_storage_end = .;
        __classified_allocation_ledger_storage = .;
        . += CLASSIFIED_ALLOCATION_LEDGER_SIZE;
        __classified_allocation_ledger_storage_end = .;
        __memory_metadata_end = .;
    }

    .dma_scratch (NOLOAD) : ALIGN(4K)
    {
        __dma_scratch_start = .;
        . += DMA_SCRATCH_SIZE;
        __dma_scratch_end = .;
    }

    .rp1_gem_workspace (NOLOAD) : ALIGN(4K)
    {
        __rp1_gem_workspace_start = .;
        __rp1_gem_descriptor_page_start = .;
        . += 4K;
        __rp1_gem_descriptor_page_end = .;
        __rp1_gem_cacheable_pages_start = .;
        . += RP1_GEM_WORKSPACE_SIZE - 4K;
        __rp1_gem_cacheable_pages_end = .;
        __rp1_gem_workspace_end = .;
    }

    .storage_scratch (NOLOAD) : ALIGN(4K)
    {
        __storage_scratch_start = .;
        . += STORAGE_SCRATCH_SIZE;
        __storage_scratch_end = .;
    }

    .terminal_storage (NOLOAD) : ALIGN(4K)
    {
        __terminal_storage_start = .;
        . += TERMINAL_STORAGE_SIZE;
        __terminal_storage_end = .;
    }

    /* Software surface only; this is not BCM2712 display scanout. */
    .framebuffer (NOLOAD) : ALIGN(4K)
    {
        __framebuffer_start = .;
        . += FRAMEBUFFER_SIZE;
        __framebuffer_end = .;
    }

    . = ALIGN(4K);
    __kernel_data_end = .;
    __image_end = .;
    __kernel_end = .;
    __image_size = __image_end - __image_start;
    __user_entry_physical = swiftos_user_init;

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}

ASSERT(__image_start == IMAGE_LOAD_ADDRESS,
       "Pi 5 image must start at physical 0x80000")
ASSERT(SIZEOF(.image_header) == 64,
       "AArch64 Image header must be exactly 64 bytes")
ASSERT((ADDR(.text) & 4095) == 0,
       "Pi 5 executable text must be 4 KiB aligned")
ASSERT((__early_l1_table & 4095) == 0,
       "Pi 5 bootstrap tables must be 4 KiB aligned")
ASSERT((__boot_stack_top & 15) == 0,
       "boot stack must be 16-byte aligned")
ASSERT((__boot_stack_bottom & 4095) == 0,
       "boot stack guard must be page aligned")
ASSERT(((__bss_end - __bss_start) & 15) == 0,
       "BSS clear span must be 16-byte aligned")
ASSERT((__dma_scratch_start & 4095) == 0,
       "DMA scratch must be 4 KiB aligned")
ASSERT(__dma_scratch_end - __dma_scratch_start == 4K,
       "DMA scratch must own one isolated cacheable page")
ASSERT(__dma_scratch_end <= 0x100000000,
       "Pi firmware mailbox scratch must fit its 32-bit physical word")
ASSERT((__rp1_gem_workspace_start & 4095) == 0,
       "RP1 GEM workspace must be 4 KiB aligned")
ASSERT(__rp1_gem_workspace_end - __rp1_gem_workspace_start == 16K,
       "RP1 GEM workspace must own exactly 16 KiB")
ASSERT(__rp1_gem_descriptor_page_end
           - __rp1_gem_descriptor_page_start == 4K,
       "RP1 GEM descriptor storage must own exactly one page")
ASSERT(__rp1_gem_descriptor_page_end == __rp1_gem_cacheable_pages_start,
       "RP1 GEM descriptor page must not overlap cacheable storage")
ASSERT(__rp1_gem_cacheable_pages_end == __rp1_gem_workspace_end,
       "RP1 GEM cacheable workspace must be contiguous")
ASSERT(__rp1_gem_workspace_end <= 0x100000000,
       "RP1 GEM 32-bit DMA workspace must remain below 4 GiB")
ASSERT((__storage_scratch_start & 4095) == 0,
       "storage scratch must be 4 KiB aligned")
ASSERT(__storage_scratch_end - __storage_scratch_start == 4K,
       "storage scratch must own exactly one page")
ASSERT((__terminal_storage_start & 4095) == 0,
       "terminal storage must be 4 KiB aligned")
ASSERT((__framebuffer_start & 4095) == 0,
       "software framebuffer must be 4 KiB aligned")
ASSERT((__debug_log_storage_start & 4095) == 0,
       "debug log storage must be 4 KiB aligned")
ASSERT(__debug_log_storage_end - __debug_log_storage_start
           >= 1024 * 48,
       "debug log storage must retain at least 1024 events")
ASSERT((__classified_free_run_storage & 15) == 0,
       "classified free-run metadata must be 16-byte aligned")
ASSERT((__classified_allocation_ledger_storage & 15) == 0,
       "classified allocation ledger must be 16-byte aligned")
ASSERT(__image_size > 64,
       "Pi 5 image cannot contain only its header")
ASSERT(__image_end <= IMAGE_LOAD_ADDRESS + UPDATE_DESTINATION_SIZE,
       "Pi 5 image exceeds the reserved 32 MiB restart window")
ASSERT(__user_entry_physical >= __user_text_start,
       "user entry precedes isolated user text")
ASSERT(__user_entry_physical < __user_text_end,
       "user entry follows isolated user text")
ASSERT(__thread_contexts_end - __thread_contexts_start >= 2 * 832,
       "thread context storage cannot hold two complete frames")
