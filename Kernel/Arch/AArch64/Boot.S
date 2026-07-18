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

    /* Permit an implemented GIC system-register interface at lower ELs. */
    mrs     x2, id_aa64pfr0_el1
    ubfx    x2, x2, #24, #4
    cbz     x2, .Lno_gic_sre_el2
    mrs     x2, icc_sre_el2
    mov     x3, #9                  /* Enable | SRE */
    orr     x2, x2, x3
    msr     icc_sre_el2, x2
    isb
.Lno_gic_sre_el2:

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
#if defined(SWIFTOS_RPI5)
    /* BCM2712 executes in low RAM and exposes its main MMIO windows high. */
    ldr     x2, =0x0000000000000705 /* normal WB, inner-shareable, AF */
    str     x2, [x1, #0]
    ldr     x2, =0x0060000000000401 /* device, AF, privileged XN */
    str     x2, [x1, #(65 * 8)]     /* 0x10_40000000...0x10_7fffffff */
    str     x2, [x1, #(124 * 8)]    /* RP1 CPU aperture at 0x1f_00000000 */
#else
    ldr     x2, =0x0060000000000401 /* device, AF, privileged XN */
    str     x2, [x1, #0]
    ldr     x2, =0x0000000040000705 /* normal WB, inner-shareable, AF */
    str     x2, [x1, #8]
#endif
    dsb     sy

    mov     x2, #0xff00             /* MAIR attr0=device, attr1=normal WB */
    msr     mair_el1, x2

    /*
     * T0SZ=25 (39-bit), 4 KiB granules, inner-shareable WBWA. TTBR1 walks are
     * disabled explicitly so no reset-unknown upper table can be consulted.
     */
    ldr     x2, =0x00000000b5a03519
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

    /* Early faults park; all Swift execution uses the typed runtime table. */
    ldr     x1, =exception_vectors
    msr     vbar_el1, x1
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

/*
 * Runtime exception veneers. Swift sees the entire save image so a scheduler
 * may replace an EL0 context without leaving outgoing FP/SIMD or stack state.
 *
 *   0x000...0x1ff  q0...q31
 *   0x200           FPCR
 *   0x208           FPSR
 *   0x210...0x300   x0...x30
 *   0x308           vector-table slot
 *   0x310           ELR_EL1
 *   0x318           SPSR_EL1
 *   0x320           ESR_EL1
 *   0x328           FAR_EL1
 *   0x330           SP_EL0
 *   0x338           TPIDR_EL0
 */
.equ EXCEPTION_FRAME_BASE, 528
.equ EXCEPTION_STACK_SIZE, 832
.equ EXCEPTION_VECTOR_OFFSET, 248
.equ EXCEPTION_ELR_OFFSET, 256
.equ EXCEPTION_SPSR_OFFSET, 264
.equ EXCEPTION_ESR_OFFSET, 272
.equ EXCEPTION_FAR_OFFSET, 280
.equ EXCEPTION_SP_EL0_OFFSET, 288
.equ EXCEPTION_TPIDR_EL0_OFFSET, 296

.align 11
.global exception_vectors
.type exception_vectors, %object
exception_vectors:
.macro RUNTIME_VECTOR target
    b       \target
    .space  124
.endm
    RUNTIME_VECTOR .Lvector_sync_sp0
    RUNTIME_VECTOR .Lvector_irq_sp0
    RUNTIME_VECTOR .Lvector_fiq_sp0
    RUNTIME_VECTOR .Lvector_serror_sp0
    RUNTIME_VECTOR .Lvector_sync_spx
    RUNTIME_VECTOR .Lvector_irq_spx
    RUNTIME_VECTOR .Lvector_fiq_spx
    RUNTIME_VECTOR .Lvector_serror_spx
    RUNTIME_VECTOR .Lvector_sync_aarch64
    RUNTIME_VECTOR .Lvector_irq_aarch64
    RUNTIME_VECTOR .Lvector_fiq_aarch64
    RUNTIME_VECTOR .Lvector_serror_aarch64
    RUNTIME_VECTOR .Lvector_sync_aarch32
    RUNTIME_VECTOR .Lvector_irq_aarch32
    RUNTIME_VECTOR .Lvector_fiq_aarch32
    RUNTIME_VECTOR .Lvector_serror_aarch32
.size exception_vectors, . - exception_vectors

/* Save x0 before using it to carry the vector-table slot into common code. */
.macro EXCEPTION_ENTRY name, slot
\name:
    sub     sp, sp, #EXCEPTION_STACK_SIZE
    str     x0, [sp, #EXCEPTION_FRAME_BASE]
    mov     x0, #\slot
    b       .Lexception_common
.endm

/* Current-EL SP0 entries must move onto the EL1 exception stack first. */
.macro EXCEPTION_ENTRY_SP0 name, slot
\name:
    msr     spsel, #1
    sub     sp, sp, #EXCEPTION_STACK_SIZE
    str     x0, [sp, #EXCEPTION_FRAME_BASE]
    mov     x0, #\slot
    b       .Lexception_common
.endm

    EXCEPTION_ENTRY_SP0 .Lvector_sync_sp0, 0
    EXCEPTION_ENTRY_SP0 .Lvector_irq_sp0, 1
    EXCEPTION_ENTRY_SP0 .Lvector_fiq_sp0, 2
    EXCEPTION_ENTRY_SP0 .Lvector_serror_sp0, 3
    EXCEPTION_ENTRY .Lvector_sync_spx, 4
    EXCEPTION_ENTRY .Lvector_irq_spx, 5
    EXCEPTION_ENTRY .Lvector_fiq_spx, 6
    EXCEPTION_ENTRY .Lvector_serror_spx, 7
    EXCEPTION_ENTRY .Lvector_sync_aarch64, 8
    EXCEPTION_ENTRY .Lvector_irq_aarch64, 9
    EXCEPTION_ENTRY .Lvector_fiq_aarch64, 10
    EXCEPTION_ENTRY .Lvector_serror_aarch64, 11
    EXCEPTION_ENTRY .Lvector_sync_aarch32, 12
    EXCEPTION_ENTRY .Lvector_irq_aarch32, 13
    EXCEPTION_ENTRY .Lvector_fiq_aarch32, 14
    EXCEPTION_ENTRY .Lvector_serror_aarch32, 15

.Lexception_common:
    /* x0 is already saved and currently contains the vector-table slot. */
    str     x0, [sp, #(EXCEPTION_FRAME_BASE + EXCEPTION_VECTOR_OFFSET)]
    add     x0, sp, #EXCEPTION_FRAME_BASE
    str     x1, [x0, #8]
    stp     x2, x3, [x0, #16]
    stp     x4, x5, [x0, #32]
    stp     x6, x7, [x0, #48]
    stp     x8, x9, [x0, #64]
    stp     x10, x11, [x0, #80]
    stp     x12, x13, [x0, #96]
    stp     x14, x15, [x0, #112]
    stp     x16, x17, [x0, #128]
    stp     x18, x19, [x0, #144]
    stp     x20, x21, [x0, #160]
    stp     x22, x23, [x0, #176]
    stp     x24, x25, [x0, #192]
    stp     x26, x27, [x0, #208]
    stp     x28, x29, [x0, #224]
    str     x30, [x0, #240]

    mrs     x1, fpcr
    str     x1, [sp, #512]
    mrs     x1, fpsr
    str     x1, [sp, #520]
    stp     q0, q1, [sp, #0]
    stp     q2, q3, [sp, #32]
    stp     q4, q5, [sp, #64]
    stp     q6, q7, [sp, #96]
    stp     q8, q9, [sp, #128]
    stp     q10, q11, [sp, #160]
    stp     q12, q13, [sp, #192]
    stp     q14, q15, [sp, #224]
    stp     q16, q17, [sp, #256]
    stp     q18, q19, [sp, #288]
    stp     q20, q21, [sp, #320]
    stp     q22, q23, [sp, #352]
    stp     q24, q25, [sp, #384]
    stp     q26, q27, [sp, #416]
    stp     q28, q29, [sp, #448]
    stp     q30, q31, [sp, #480]

    mrs     x1, elr_el1
    str     x1, [x0, #EXCEPTION_ELR_OFFSET]
    mrs     x1, spsr_el1
    str     x1, [x0, #EXCEPTION_SPSR_OFFSET]
    mrs     x1, esr_el1
    str     x1, [x0, #EXCEPTION_ESR_OFFSET]
    mrs     x1, far_el1
    str     x1, [x0, #EXCEPTION_FAR_OFFSET]
    mrs     x1, sp_el0
    str     x1, [x0, #EXCEPTION_SP_EL0_OFFSET]
    mrs     x1, tpidr_el0
    str     x1, [x0, #EXCEPTION_TPIDR_EL0_OFFSET]

    mov     x0, sp
    bl      swiftos_exception_dispatch

    add     x0, sp, #EXCEPTION_FRAME_BASE
    ldr     x1, [x0, #EXCEPTION_ELR_OFFSET]
    msr     elr_el1, x1
    ldr     x1, [x0, #EXCEPTION_SPSR_OFFSET]
    msr     spsr_el1, x1
    ldr     x1, [x0, #EXCEPTION_SP_EL0_OFFSET]
    msr     sp_el0, x1
    ldr     x1, [x0, #EXCEPTION_TPIDR_EL0_OFFSET]
    msr     tpidr_el0, x1

    ldp     q0, q1, [sp, #0]
    ldp     q2, q3, [sp, #32]
    ldp     q4, q5, [sp, #64]
    ldp     q6, q7, [sp, #96]
    ldp     q8, q9, [sp, #128]
    ldp     q10, q11, [sp, #160]
    ldp     q12, q13, [sp, #192]
    ldp     q14, q15, [sp, #224]
    ldp     q16, q17, [sp, #256]
    ldp     q18, q19, [sp, #288]
    ldp     q20, q21, [sp, #320]
    ldp     q22, q23, [sp, #352]
    ldp     q24, q25, [sp, #384]
    ldp     q26, q27, [sp, #416]
    ldp     q28, q29, [sp, #448]
    ldp     q30, q31, [sp, #480]
    ldr     x1, [sp, #512]
    msr     fpcr, x1
    ldr     x1, [sp, #520]
    msr     fpsr, x1

    ldr     x30, [x0, #240]
    ldp     x28, x29, [x0, #224]
    ldp     x26, x27, [x0, #208]
    ldp     x24, x25, [x0, #192]
    ldp     x22, x23, [x0, #176]
    ldp     x20, x21, [x0, #160]
    ldp     x18, x19, [x0, #144]
    ldp     x16, x17, [x0, #128]
    ldp     x14, x15, [x0, #112]
    ldp     x12, x13, [x0, #96]
    ldp     x10, x11, [x0, #80]
    ldp     x8, x9, [x0, #64]
    ldp     x6, x7, [x0, #48]
    ldp     x4, x5, [x0, #32]
    ldp     x2, x3, [x0, #16]
    ldr     x1, [x0, #8]
    ldr     x0, [x0, #0]
    add     sp, sp, #EXCEPTION_STACK_SIZE
    eret

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

.global arch_wait_for_interrupt
.type arch_wait_for_interrupt, %function
arch_wait_for_interrupt:
    wfi
    ret

.global arch_mpidr
.type arch_mpidr, %function
arch_mpidr:
    mrs     x0, mpidr_el1
    ret

.global arch_vector_base
.type arch_vector_base, %function
arch_vector_base:
    mrs     x0, vbar_el1
    ret

.global arch_enable_irqs
.type arch_enable_irqs, %function
arch_enable_irqs:
    msr     daifclr, #2
    isb
    ret

.global arch_disable_irqs
.type arch_disable_irqs, %function
arch_disable_irqs:
    msr     daifset, #2
    isb
    ret

.global arch_physical_timer_set_deadline
.type arch_physical_timer_set_deadline, %function
arch_physical_timer_set_deadline:
    msr     cntp_cval_el0, x0
    mov     x1, #1
    msr     cntp_ctl_el0, x1
    isb
    ret

.global arch_physical_timer_disable
.type arch_physical_timer_disable, %function
arch_physical_timer_disable:
    msr     cntp_ctl_el0, xzr
    isb
    ret

.global arch_gicv3_enable_system_registers
.type arch_gicv3_enable_system_registers, %function
arch_gicv3_enable_system_registers:
    mrs     x1, icc_sre_el1
    orr     x1, x1, #1
    msr     icc_sre_el1, x1
    isb
    mrs     x0, icc_sre_el1
    and     x0, x0, #1
    ret

.global arch_gicv3_prepare_control
.type arch_gicv3_prepare_control, %function
arch_gicv3_prepare_control:
    mrs     x1, icc_ctlr_el1
    bic     x1, x1, #2              /* EOImode = priority drop + deactivate */
    msr     icc_ctlr_el1, x1
    isb
    ret

.global arch_gicv3_set_priority_mask
.type arch_gicv3_set_priority_mask, %function
arch_gicv3_set_priority_mask:
    msr     icc_pmr_el1, x0
    isb
    ret

.global arch_gicv3_set_binary_point
.type arch_gicv3_set_binary_point, %function
arch_gicv3_set_binary_point:
    msr     icc_bpr1_el1, x0
    isb
    ret

.global arch_gicv3_enable_group1
.type arch_gicv3_enable_group1, %function
arch_gicv3_enable_group1:
    msr     icc_igrpen1_el1, x0
    isb
    ret

.global arch_gicv3_acknowledge_group1
.type arch_gicv3_acknowledge_group1, %function
arch_gicv3_acknowledge_group1:
    mrs     x0, icc_iar1_el1
    ret

.global arch_gicv3_end_group1
.type arch_gicv3_end_group1, %function
arch_gicv3_end_group1:
    msr     icc_eoir1_el1, x0
    isb
    ret
