private typealias RaspberryPi5PMWatchdog = BCM2712PMWatchdog<
    BCM2712PMWatchdogMMIORegisterAccess
>

/// Owns the Pi rollback watchdog only for a firmware-observed tryboot payload
/// candidate. Stable, rescue, unsupported, and unidentified boots leave the
/// hardware untouched. Kicks are driven by cooperative scheduler progress,
/// never by timer IRQ delivery, so a wedged scheduler cannot conceal itself by
/// continuing to acknowledge interrupts.
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
        self.console = console
        guard RaspberryPi5WatchdogBootPolicy.requiresAdoption(
                  payloadWasTryBoot: platform.bootObservation?.wasTryBoot
              )
        else {
            // Retaining the discovered page in the final map is not an MMIO
            // access. Stable boots need that mapping only if the A/B executor
            // later reaches an explicit, no-return reset boundary.
            return true
        }
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
        activeWatchdog = watchdog
        probation = RaspberryPi5WatchdogProbationPolicy(
            isTryBootCandidate: true
        )
        lastServiceTicks = AArch64.counterValue
        serviceIntervalTicks = interval.partialValue
        console.write("SWIFTOS:WATCHDOG_READY\n")
        return true
    }

    @discardableResult
    static func serviceNow() -> Bool {
        switch probation.serviceAction {
        case .inactive:
            return false
        case .suppressDuringTrialProbation:
            return activeWatchdog != nil
        case .programService:
            break
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
        guard case .programService = probation.serviceAction else { return }
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
    /// reset is armed. Failed quiescence never resumes normal execution: an
    /// active candidate remains rollback-bound, while a stable explicit-reset
    /// caller parks after its no-return boundary.
    static func resetToDefault(platform: Platform) -> Never {
        AArch64.disableIRQs()
        guard RaspberryPiKernelUpdateActivator.quiesceProcessors(
                  platform: platform
              ), InterruptSubsystem.quiesceForKernelRestart()
        else {
            console?.write("SWIFTOS:WATCHDOG_RESET_QUIESCE_FAILED\n")
            while true { AArch64.waitForEvent() }
        }
        let resetWatchdog: RaspberryPi5PMWatchdog?
        if let activeWatchdog {
            resetWatchdog = activeWatchdog
        } else if case .bcm2712PM(let resource)? = platform.systemWatchdog,
                  let registers = BCM2712PMWatchdogMMIORegisterAccess(
                      resource: resource
                  ) {
            // A stable boot may reach this path only after update policy has
            // authorized a no-return reset (including an armed tryboot). Merely
            // constructing the accessor performs no register access.
            resetWatchdog = RaspberryPi5PMWatchdog(registers: registers)
        } else {
            resetWatchdog = nil
        }
        guard var watchdog = resetWatchdog else {
            console?.write("SWIFTOS:WATCHDOG_RESET_UNAVAILABLE\n")
            // Reset authority is already committed or media durability is
            // ambiguous. Resuming could violate rollback invariants.
            while true { AArch64.waitForEvent() }
        }
        AArch64.synchronizeData()
        watchdog.programResetToDefault()
        activeWatchdog = watchdog
        AArch64.synchronizeData()
        while true { AArch64.waitForEvent() }
    }
}
