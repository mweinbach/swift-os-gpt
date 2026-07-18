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
}

@_silgen_name("arch_current_el")
private func archCurrentEL() -> UInt64

@_silgen_name("arch_counter_frequency")
private func archCounterFrequency() -> UInt64

@_silgen_name("arch_counter_value")
private func archCounterValue() -> UInt64

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
