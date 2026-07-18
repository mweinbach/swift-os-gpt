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

@_silgen_name("arch_wait_for_event")
private func archWaitForEvent()

