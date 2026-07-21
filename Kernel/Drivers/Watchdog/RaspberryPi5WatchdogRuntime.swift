private typealias RaspberryPi5PMWatchdog = BCM2712PMWatchdog<
    BCM2712PMWatchdogMMIORegisterAccess
>

/// Owns the continuously armed Pi watchdog after the final page table maps its
/// DT-described PM aperture. Kicks are driven by cooperative scheduler
/// progress, never by timer IRQ delivery, so a wedged scheduler cannot conceal
/// itself by continuing to acknowledge interrupts.
enum RaspberryPi5WatchdogRuntime {
    static let timeoutSeconds: UInt32 = 15
    static let serviceIntervalSeconds: UInt64 = 5

    private nonisolated(unsafe) static var activeWatchdog:
        RaspberryPi5PMWatchdog?
    private nonisolated(unsafe) static var lastServiceTicks: UInt64 = 0
    private nonisolated(unsafe) static var serviceIntervalTicks: UInt64 = 0
    private nonisolated(unsafe) static var console: EarlyConsole?
    private nonisolated(unsafe) static var probation =
        RaspberryPi5WatchdogProbationPolicy(isTryBootCandidate: false)

    static var isActive: Bool { activeWatchdog != nil }
    static var isTrialProbationActive: Bool {
        probation.isTrialProbationActive
    }

    @discardableResult
    static func activate(console: EarlyConsole, platform: Platform) -> Bool {
        guard platform.kind == .raspberryPi5 else { return true }
        if activeWatchdog != nil { return true }
        guard case .bcm2712PM(let resource)? = platform.systemWatchdog,
              let registers = BCM2712PMWatchdogMMIORegisterAccess(
                  resource: resource
              )
        else {
            console.write("SWIFTOS:WATCHDOG_UNAVAILABLE\n")
            return false
        }
        let frequency = AArch64.counterFrequency
        let interval = frequency.multipliedReportingOverflow(
            by: serviceIntervalSeconds
        )
        guard frequency != 0, !interval.overflow, interval.partialValue != 0
        else {
            console.write("SWIFTOS:WATCHDOG_CLOCK_INVALID\n")
            return false
        }
        var watchdog = RaspberryPi5PMWatchdog(registers: registers)
        guard watchdog.adoptAndService(timeoutSeconds: timeoutSeconds)
                == .adopted
        else {
            console.write("SWIFTOS:WATCHDOG_ADOPT_FAILED\n")
            return false
        }
        self.console = console
        activeWatchdog = watchdog
        probation = RaspberryPi5WatchdogProbationPolicy(
            isTryBootCandidate: platform.bootObservation?.wasTryBoot == true
        )
        lastServiceTicks = AArch64.counterValue
        serviceIntervalTicks = interval.partialValue
        console.write("SWIFTOS:WATCHDOG_READY\n")
        return true
    }

    @discardableResult
    static func serviceNow() -> Bool {
        if probation.serviceAction == .suppressDuringTrialProbation {
            return activeWatchdog != nil
        }
        guard var watchdog = activeWatchdog, watchdog.service() else {
            return false
        }
        activeWatchdog = watchdog
        lastServiceTicks = AArch64.counterValue
        return true
    }

    static func serviceIfDue() {
        guard activeWatchdog != nil, serviceIntervalTicks != 0 else { return }
        guard probation.serviceAction == .programService else { return }
        let now = AArch64.counterValue
        guard now &- lastServiceTicks >= serviceIntervalTicks else { return }
        guard serviceNow() else {
            activeWatchdog = nil
            console?.write("SWIFTOS:WATCHDOG_SERVICE_FAILED\n")
            return
        }
    }

    /// Releases probation only after the executor has durably moved the exact
    /// running tryboot candidate into selector-commit-pending. The immediate
    /// service starts a fresh window for selector commit and controlled reset.
    @discardableResult
    static func releaseAfterDurableCandidateHealth() -> Bool {
        guard probation.releaseAfterDurableCandidateHealth() else {
            return false
        }
        return serviceNow()
    }

    /// Irreversibly returns through firmware partition zero. All managed
    /// secondaries and interrupt delivery are quiesced before the global PM
    /// reset is armed; any failed quiescence simply leaves the already-running
    /// rollback watchdog to expire rather than resuming normal execution.
    static func resetToDefault(platform: Platform) -> Never {
        AArch64.disableIRQs()
        guard RaspberryPiKernelUpdateActivator.quiesceProcessors(
                  platform: platform
              ), InterruptSubsystem.quiesceForKernelRestart(),
              var watchdog = activeWatchdog
        else {
            console?.write("SWIFTOS:WATCHDOG_RESET_QUIESCE_FAILED\n")
            while true { AArch64.waitForEvent() }
        }
        AArch64.synchronizeData()
        watchdog.programResetToDefault()
        activeWatchdog = watchdog
        AArch64.synchronizeData()
        while true { AArch64.waitForEvent() }
    }
}
