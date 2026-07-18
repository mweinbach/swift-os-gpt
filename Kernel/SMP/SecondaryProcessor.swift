@_cdecl("swiftos_secondary_main")
func swiftOSSecondaryMain(_ contextID: UInt64) -> Never {
    guard swiftOSSMPPublishOnline(contextID) == contextID else {
        while true { AArch64.waitForEvent() }
    }

    // Per-CPU interrupt scheduling is intentionally enabled only after the
    // CPU0 scheduler grows independent queues and controller-local state.
    while true { AArch64.waitForEvent() }
}
