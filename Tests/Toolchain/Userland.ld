OUTPUT_ARCH(aarch64)
ENTRY(swiftos_user_init)

SECTIONS
{
    . = 0x100000;

    .user_text : ALIGN(4K)
    {
        __user_text_start = .;
        KEEP(*(.text.swiftos_user_init))
        *(.text .text.*)
        __user_text_end = .;
    }

    .user_rodata : ALIGN(4K)
    {
        __user_rodata_start = .;
        *(.rodata .rodata.*)
        *(.swift5* swift5*)
        *(.swift_modhash)
        __user_rodata_end = .;
    }

    .user_data : ALIGN(4K)
    {
        *(.data .data.*)
    }

    .user_bss (NOLOAD) : ALIGN(4K)
    {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}

__user_entry = swiftos_user_init;

ASSERT(swiftos_user_init >= __user_text_start,
       "user entry precedes isolated text")
ASSERT(swiftos_user_init < __user_text_end,
       "user entry follows isolated text")
