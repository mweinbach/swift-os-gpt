enum AArch64 {
    @inline(__always)
    static var currentExceptionLevel: UInt64 {
        archCurrentEL()
    }

    @inline(__always)
    static var counterFrequency: UInt64 {
        archCounterFrequency()
    }

    @inline(__always)
    static var counterValue: UInt64 {
        archCounterValue()
    }

    @inline(__always)
    static var multiprocessorAffinity: UInt64 {
        archMPIDR()
    }

    /// Aff3:Aff2:Aff1:Aff0 in the format used by GIC redistributor affinity.
    @inline(__always)
    static var redistributorAffinity: UInt32 {
        let mpidr = multiprocessorAffinity
        return UInt32(truncatingIfNeeded: mpidr & 0x00ff_ffff)
            | UInt32(truncatingIfNeeded: (mpidr >> 8) & 0xff00_0000)
    }

    @inline(__always)
    static var vectorBase: UInt64 {
        archVectorBase()
    }

    @inline(__always)
    static var stackPointer: UInt64 {
        archStackPointer()
    }

    @inline(__always)
    static var systemControl: UInt64 {
        archSystemControl()
    }

    @inline(__always)
    static var dmaScratchAddress: UInt64 {
        archDMAScratchAddress()
    }

    @inline(__always)
    static var framebufferAddress: UInt64 {
        archFramebufferAddress()
    }

    @inline(__always)
    static var terminalStorageAddress: UInt64 {
        archTerminalStorageAddress()
    }

    @inline(__always)
    static func synchronizeData() {
        archDataSyncBarrier()
    }

    @inline(__always)
    static func spinHint() {
        archSpinHint()
    }

    static func waitForEvent() {
        archWaitForEvent()
    }

    static func waitForInterrupt() {
        archWaitForInterrupt()
    }

    @inline(__always)
    static func enableIRQs() {
        archEnableIRQs()
    }

    @inline(__always)
    static func disableIRQs() {
        archDisableIRQs()
    }

    @inline(__always)
    static func setPhysicalTimerDeadline(_ deadline: UInt64) {
        archPhysicalTimerSetDeadline(deadline)
    }

    @inline(__always)
    static func disablePhysicalTimer() {
        archPhysicalTimerDisable()
    }

    @inline(__always)
    static func enableGICv3SystemRegisters() -> Bool {
        archGICv3EnableSystemRegisters() != 0
    }

    @inline(__always)
    static func prepareGICv3Control() {
        archGICv3PrepareControl()
    }

    @inline(__always)
    static func setGICv3PriorityMask(_ mask: UInt8) {
        archGICv3SetPriorityMask(UInt64(mask))
    }

    @inline(__always)
    static func setGICv3BinaryPoint(_ point: UInt8) {
        archGICv3SetBinaryPoint(UInt64(point))
    }

    @inline(__always)
    static func setGICv3Group1Enabled(_ enabled: Bool) {
        archGICv3EnableGroup1(enabled ? 1 : 0)
    }

    @inline(__always)
    static func acknowledgeGICv3Group1() -> UInt64 {
        archGICv3AcknowledgeGroup1()
    }

    @inline(__always)
    static func endGICv3Group1(_ acknowledgeToken: UInt64) {
        archGICv3EndGroup1(acknowledgeToken)
    }
}

@_silgen_name("arch_current_el")
private func archCurrentEL() -> UInt64

@_silgen_name("arch_counter_frequency")
private func archCounterFrequency() -> UInt64

@_silgen_name("arch_counter_value")
private func archCounterValue() -> UInt64

@_silgen_name("arch_mpidr")
private func archMPIDR() -> UInt64

@_silgen_name("arch_vector_base")
private func archVectorBase() -> UInt64

@_silgen_name("arch_stack_pointer")
private func archStackPointer() -> UInt64

@_silgen_name("arch_sctlr")
private func archSystemControl() -> UInt64

@_silgen_name("arch_dma_scratch_address")
private func archDMAScratchAddress() -> UInt64

@_silgen_name("arch_framebuffer_address")
private func archFramebufferAddress() -> UInt64

@_silgen_name("arch_terminal_storage_address")
private func archTerminalStorageAddress() -> UInt64

@_silgen_name("arch_data_sync_barrier")
private func archDataSyncBarrier()

@_silgen_name("arch_spin_hint")
private func archSpinHint()

@_silgen_name("arch_wait_for_event")
private func archWaitForEvent()

@_silgen_name("arch_wait_for_interrupt")
private func archWaitForInterrupt()

@_silgen_name("arch_enable_irqs")
private func archEnableIRQs()

@_silgen_name("arch_disable_irqs")
private func archDisableIRQs()

@_silgen_name("arch_physical_timer_set_deadline")
private func archPhysicalTimerSetDeadline(_ deadline: UInt64)

@_silgen_name("arch_physical_timer_disable")
private func archPhysicalTimerDisable()

@_silgen_name("arch_gicv3_enable_system_registers")
private func archGICv3EnableSystemRegisters() -> UInt64

@_silgen_name("arch_gicv3_prepare_control")
private func archGICv3PrepareControl()

@_silgen_name("arch_gicv3_set_priority_mask")
private func archGICv3SetPriorityMask(_ mask: UInt64)

@_silgen_name("arch_gicv3_set_binary_point")
private func archGICv3SetBinaryPoint(_ point: UInt64)

@_silgen_name("arch_gicv3_enable_group1")
private func archGICv3EnableGroup1(_ enabled: UInt64)

@_silgen_name("arch_gicv3_acknowledge_group1")
private func archGICv3AcknowledgeGroup1() -> UInt64

@_silgen_name("arch_gicv3_end_group1")
private func archGICv3EndGroup1(_ acknowledgeToken: UInt64)
