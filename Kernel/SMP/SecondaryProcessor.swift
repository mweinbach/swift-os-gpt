@_cdecl("swiftos_secondary_main")
func swiftOSSecondaryMain(_ contextID: UInt64) -> Never {
    // Acquire the complete scheduler/context registry before consulting any
    // CPU0-published interrupt-controller state. ONLINE therefore means both
    // the work registry and this CPU's local controller interface are ready.
    guard SecondaryProcessorWorkRuntime.prepareSecondary(
              contextID: contextID
          )
    else {
        while true { AArch64.waitForEvent() }
    }
    guard InterruptSubsystem.configureCurrentProcessor() else {
        SecondaryProcessorWorkRuntime
            .recordCurrentProcessorInitializationFailure(contextID: contextID)
        while true { AArch64.waitForEvent() }
    }
    guard swiftOSSMPPublishOnline(contextID) == contextID else {
        while true { AArch64.waitForEvent() }
    }

    var observedRestartEpoch: UInt64 = 0
    _ = SecondaryProcessorWorkRuntime.run(
        contextID: contextID,
        observedRestartEpoch: &observedRestartEpoch
    )

    // Every bounded scheduling quantum above and every idle wake below checks
    // the restart epoch. CPU0 may therefore quiesce a worker even if PSCI
    // CPU_OFF previously returned a failure and a later request must retry.
    while true {
        _ = SMPKernelRestartRendezvous.checkpoint(
            logicalProcessorID: contextID,
            observedEpoch: &observedRestartEpoch
        )
        AArch64.waitForEvent()
    }
}
