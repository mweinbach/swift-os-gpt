/// EL1 physical generic timer. Interrupt routing is owned by the GIC driver.
struct GenericPhysicalTimer {
    static let architecturalInterruptID: UInt32 = 30
    private static let maximumCatchUpPeriods = 8

    private(set) var periodTicks: UInt64 = 0
    private(set) var nextDeadline: UInt64 = 0
    private(set) var isRunning = false

    /// Establishes the safe architectural entry state for the calling PE.
    /// CNTP_CTL_EL0 is processor-local; this does not mutate the boot CPU's
    /// scheduler timer bookkeeping when a secondary is brought online.
    static func initializeCurrentProcessor() {
        AArch64.disablePhysicalTimer()
    }

    mutating func start(periodTicks: UInt64) -> Bool {
        guard periodTicks > 0 else { return false }
        self.periodTicks = periodTicks
        nextDeadline = AArch64.counterValue &+ periodTicks
        isRunning = true
        AArch64.setPhysicalTimerDeadline(nextDeadline)
        return true
    }

    /// Moves CVAL forward before the interrupt is EOIed, deasserting the level
    /// source. Catch-up work is explicitly bounded after a long masked period.
    mutating func rearmAfterInterrupt() {
        guard isRunning, periodTicks > 0 else {
            AArch64.disablePhysicalTimer()
            return
        }

        let now = AArch64.counterValue
        var deadline = nextDeadline &+ periodTicks
        var catchUpCount = 0
        while deadline <= now,
              catchUpCount < Self.maximumCatchUpPeriods {
            deadline &+= periodTicks
            catchUpCount += 1
        }
        if deadline <= now {
            deadline = now &+ periodTicks
        }
        nextDeadline = deadline
        AArch64.setPhysicalTimerDeadline(deadline)
    }

    mutating func stop() {
        AArch64.disablePhysicalTimer()
        isRunning = false
        periodTicks = 0
        nextDeadline = 0
    }
}
