/*
 * The only pre-Swift execution path. It establishes architectural invariants
 * that cannot be expressed by Swift before a stack and EL1 environment exist.
 */

.section .text.boot, "ax"
.align  7
.global _start
.type   _start, %function
_start:
    msr     daifset, #0xf
    mov     x19, x0                 /* QEMU device-tree pointer */

    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
    cbnz    x1, .Lpark

    mrs     x1, CurrentEL
    cmp     x1, #0x8
    b.eq    .Ldrop_from_el2
    cmp     x1, #0x4
    b.eq    .Lenter_el1
    b       .Lpark                  /* EL3 and EL0 are unsupported contracts */

.Ldrop_from_el2:
    mov     x1, #(1 << 31)          /* EL1 executes AArch64 */
    msr     hcr_el2, x1
    mov     x1, #3                  /* EL1 physical counter and timer access */
    msr     cnthctl_el2, x1
    msr     cntvoff_el2, xzr
    mov     x1, #0x3c5              /* mask DAIF, return to EL1h */
    msr     spsr_el2, x1
    adr     x1, .Lenter_el1
    msr     elr_el2, x1
    eret

.Lenter_el1:
    msr     daifset, #0xf
    ldr     x1, =__boot_stack_top
    mov     sp, x1

    /* Swift may use FP/SIMD registers even when source looks scalar. */
    mrs     x1, cpacr_el1
    orr     x1, x1, #(3 << 20)
    msr     cpacr_el1, x1
    isb

    ldr     x1, =early_vectors
    msr     vbar_el1, x1
    isb

    /* Clear language-level zero storage before touching Swift globals. */
    ldr     x1, =__bss_start
    ldr     x2, =__bss_end
.Lclear_bss:
    cmp     x1, x2
    b.hs    .Lbss_done
    stp     xzr, xzr, [x1], #16
    b       .Lclear_bss
.Lbss_done:

    /*
     * Boot-time 4 KiB-granule identity map for the low device GiB and first
     * RAM GiB. It remains active until the future owned-memory milestone.
     */
    ldr     x1, =__early_l1_table
    mov     x2, #0
    mov     x3, #(4096 / 16)
.Lzero_table:
    stp     xzr, xzr, [x1], #16
    subs    x3, x3, #1
    b.ne    .Lzero_table

    ldr     x1, =__early_l1_table
    ldr     x2, =0x0060000000000401 /* device, AF, privileged XN */
    str     x2, [x1, #0]
    ldr     x2, =0x0000000040000705 /* normal WB, inner-shareable, AF */
    str     x2, [x1, #8]
    dsb     sy

    mov     x2, #0xff00             /* MAIR attr0=device, attr1=normal WB */
    msr     mair_el1, x2

    /*
     * T0SZ/T1SZ=32, 4 KiB granules, inner-shareable WBWA. TTBR1 walks are
     * disabled explicitly so no reset-unknown upper table can be consulted.
     */
    ldr     x2, =0x00000000b5a03520
    mrs     x3, id_aa64mmfr0_el1
    and     x3, x3, #0xf
    lsl     x3, x3, #32
    orr     x2, x2, x3
    msr     tcr_el1, x2
    ldr     x2, =__early_l1_table
    msr     ttbr0_el1, x2
    msr     ttbr1_el1, xzr
    isb

    tlbi    vmalle1
    dsb     sy
    isb
    ic      iallu
    dsb     nsh
    isb
    /* Armv8.0 RES1 bits + M/C/I + EL0/EL1 stack alignment checks. */
    ldr     x2, =0x0000000030d0181d
    msr     sctlr_el1, x2
    isb

    mov     x0, x19
    bl      swiftos_main

.Lpark:
    wfe
    b       .Lpark
.size _start, . - _start

/* Early vectors park safely. Typed diagnostic vectors are the next milestone. */
.align 11
early_vectors:
.macro EARLY_VECTOR
    b       early_exception
    .space  124
.endm
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR
    EARLY_VECTOR

early_exception:
    msr     daifset, #0xf
    b       .Lpark

.text
.align 2
.global arch_current_el
.type arch_current_el, %function
arch_current_el:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    ret

.global arch_counter_frequency
.type arch_counter_frequency, %function
arch_counter_frequency:
    mrs     x0, cntfrq_el0
    ret

.global arch_counter_value
.type arch_counter_value, %function
arch_counter_value:
    isb
    mrs     x0, cntpct_el0
    ret

.global arch_stack_pointer
.type arch_stack_pointer, %function
arch_stack_pointer:
    mov     x0, sp
    ret

.global arch_sctlr
.type arch_sctlr, %function
arch_sctlr:
    mrs     x0, sctlr_el1
    ret

.global arch_dma_scratch_address
.type arch_dma_scratch_address, %function
arch_dma_scratch_address:
    ldr     x0, =__dma_scratch_start
    ret

.global arch_framebuffer_address
.type arch_framebuffer_address, %function
arch_framebuffer_address:
    ldr     x0, =__framebuffer_start
    ret

.global arch_terminal_storage_address
.type arch_terminal_storage_address, %function
arch_terminal_storage_address:
    ldr     x0, =__terminal_storage_start
    ret

.global arch_data_sync_barrier
.type arch_data_sync_barrier, %function
arch_data_sync_barrier:
    dsb     sy
    ret

.global arch_spin_hint
.type arch_spin_hint, %function
arch_spin_hint:
    yield
    ret

.global arch_wait_for_event
.type arch_wait_for_event, %function
arch_wait_for_event:
    wfe
    ret
