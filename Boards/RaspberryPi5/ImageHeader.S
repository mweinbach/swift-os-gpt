/*
 * Raspberry Pi 5 enters this standard AArch64 Image header. The layout is the
 * public Arm64 boot ABI; the instructions and symbols here are SwiftOS code.
 */

.section .text.image_header, "ax"
.balign 8
.global rpi5_image_entry
.type rpi5_image_entry, %function
rpi5_image_entry:
    b       _start
    nop
    .quad   0x0000000000080000    /* text_offset: 512 KiB from a 2 MiB base */
    .quad   __image_size          /* memory required from the image start */
    .quad   0x0000000000000002    /* little-endian, 4 KiB kernel page size */
    .quad   0
    .quad   0
    .quad   0
    .word   0x644d5241            /* little-endian "ARM\x64" magic */
    .word   0
.size rpi5_image_entry, . - rpi5_image_entry
