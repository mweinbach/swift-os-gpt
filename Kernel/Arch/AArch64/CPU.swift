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

    /// Dense kernel processor identifier established by the reset/PSCI entry
    /// veneers. It is intentionally independent of the hardware MPIDR layout
    /// so processor-local runtime storage works across board CPU topologies.
    @inline(__always)
    static var logicalProcessorID: UInt64 {
        archLogicalProcessorID()
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

    static var softRestartTrampolineSourceAddress: UInt64 {
        archSoftRestartTrampolineStart()
    }

    static var softRestartTrampolineByteCount: UInt64 {
        archSoftRestartTrampolineEnd()
            - archSoftRestartTrampolineStart()
    }

    @inline(__always)
    static func synchronizeData() {
        archDataSyncBarrier()
    }

    /// Makes CPU writes visible to a non-coherent device over one physical
    /// byte interval. The assembly boundary discovers the implemented cache
    /// line size and rounds the first address down before issuing `dc cvac`.
    @inline(__always)
    static func cleanDataCache(address: UInt64, byteCount: UInt64) -> Bool {
        guard byteCount > 0,
              byteCount <= UInt64.max - address
        else {
            return false
        }
        archCleanDataCacheRange(address, byteCount)
        return true
    }

    /// Discards CPU cache lines after a non-coherent device has completed
    /// writing the corresponding physical byte interval. Callers must clean
    /// any dirty CPU data before ownership is transferred to the device.
    @inline(__always)
    static func invalidateDataCache(
        address: UInt64,
        byteCount: UInt64
    ) -> Bool {
        guard byteCount > 0,
              byteCount <= UInt64.max - address
        else {
            return false
        }
        archInvalidateDataCacheRange(address, byteCount)
        return true
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

    /// Does not return. Every pointer must be identity-mapped and validated by
    /// the update activation policy before crossing this architectural veneer.
    static func activateStagedKernel(
        sourceAddress: UInt64,
        rawImageByteCount: UInt64,
        destinationAddress: UInt64,
        deviceTreeAddress: UInt64,
        trampolineAddress: UInt64,
        stackTopAddress: UInt64,
        destinationRuntimeByteCount: UInt64,
        trampolineByteCount: UInt64
    ) -> Never {
        archActivateStagedKernel(
            sourceAddress,
            rawImageByteCount,
            destinationAddress,
            deviceTreeAddress,
            trampolineAddress,
            stackTopAddress,
            destinationRuntimeByteCount,
            trampolineByteCount
        )
    }

    @inline(__always)
    static func enableIRQs() {
        archEnableIRQs()
    }

    @inline(__always)
    static func disableIRQs() {
        archDisableIRQs()
    }

    /// Acquires one architecture-neutral kernel lock while masking IRQs on the
    /// local CPU. The returned DAIF value must be passed back to the matching
    /// release operation so callers compose correctly with already-masked
    /// interrupt contexts.
    @inline(__always)
    static func acquireInterruptSafeLock(
        _ lockWord: UnsafeMutablePointer<UInt32>
    ) -> UInt64 {
        archAcquireInterruptSafeLock(lockWord)
    }

    @inline(__always)
    static func releaseInterruptSafeLock(
        _ lockWord: UnsafeMutablePointer<UInt32>,
        restoring interruptState: UInt64
    ) {
        archReleaseInterruptSafeLock(lockWord, interruptState)
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

@_silgen_name("arch_logical_processor_id")
private func archLogicalProcessorID() -> UInt64

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

@_silgen_name("arch_soft_restart_trampoline_source_address")
private func archSoftRestartTrampolineStart() -> UInt64

@_silgen_name("arch_soft_restart_trampoline_source_end")
private func archSoftRestartTrampolineEnd() -> UInt64

@_silgen_name("arch_data_sync_barrier")
private func archDataSyncBarrier()

@_silgen_name("arch_clean_data_cache_range")
private func archCleanDataCacheRange(_ address: UInt64, _ byteCount: UInt64)

@_silgen_name("arch_invalidate_data_cache_range")
private func archInvalidateDataCacheRange(
    _ address: UInt64,
    _ byteCount: UInt64
)

@_silgen_name("arch_spin_hint")
private func archSpinHint()

@_silgen_name("arch_wait_for_event")
private func archWaitForEvent()

@_silgen_name("arch_wait_for_interrupt")
private func archWaitForInterrupt()

@_silgen_name("arch_activate_staged_kernel")
private func archActivateStagedKernel(
    _ sourceAddress: UInt64,
    _ rawImageByteCount: UInt64,
    _ destinationAddress: UInt64,
    _ deviceTreeAddress: UInt64,
    _ trampolineAddress: UInt64,
    _ stackTopAddress: UInt64,
    _ destinationRuntimeByteCount: UInt64,
    _ trampolineByteCount: UInt64
) -> Never

@_silgen_name("arch_enable_irqs")
private func archEnableIRQs()

@_silgen_name("arch_disable_irqs")
private func archDisableIRQs()

@_silgen_name("arch_acquire_interrupt_safe_lock")
private func archAcquireInterruptSafeLock(
    _ lockWord: UnsafeMutablePointer<UInt32>
) -> UInt64

@_silgen_name("arch_release_interrupt_safe_lock")
private func archReleaseInterruptSafeLock(
    _ lockWord: UnsafeMutablePointer<UInt32>,
    _ interruptState: UInt64
)

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
