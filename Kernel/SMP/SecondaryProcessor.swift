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
    guard InterruptSubsystem.configureCurrentProcessor(
              logicalProcessorID: contextID
          )
    else {
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

    // Remain restart-aware while CPU0 assembles the shared EL0 queue. Once it
    // release-publishes that queue, this no-return handoff installs local hooks
    // and leases one migratable userspace context. Later timer IRQs continue
    // servicing the restart rendezvous from bounded exception context.
    KernelEL0Runtime.waitForSecondaryLaunch(
        contextID: contextID,
        observedRestartEpoch: &observedRestartEpoch
    )
}
