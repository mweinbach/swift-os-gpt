@_cdecl("swiftos_secondary_main")
func swiftOSSecondaryMain(_ contextID: UInt64) -> Never {
    guard swiftOSSMPPublishOnline(contextID) == contextID else {
        while true { AArch64.waitForEvent() }
    }

    // Per-CPU interrupt scheduling is intentionally enabled only after the
    // CPU0 scheduler grows independent queues and controller-local state. The
    // restart checkpoint makes this WFE park a real quiesce rendezvous: CPU0
    // publishes an epoch and sends an event, then this CPU enters PSCI CPU_OFF.
    var observedRestartEpoch: UInt64 = 0
    while true {
        _ = SMPKernelRestartRendezvous.checkpoint(
            logicalProcessorID: contextID,
            observedEpoch: &observedRestartEpoch
        )
        AArch64.waitForEvent()
    }
}
