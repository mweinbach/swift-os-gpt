/// Wrap-safe, allocation-free deadline for CPU0's secondary-work evidence
/// wait. Architectural counter time is the primary bound because work quanta
/// are deliberately timer paced; the poll count is only a fail-safe for a
/// counter that firmware left stopped or otherwise unusable.
struct SecondaryProcessorWorkWaitPolicy {
    private let startedAtTicks: UInt64
    private let timeoutTicks: UInt64
    private let maximumPollCount: UInt64
    private(set) var pollCount: UInt64 = 0

    init?(
        startedAtTicks: UInt64,
        timeoutTicks: UInt64,
        maximumPollCount: UInt64
    ) {
        guard timeoutTicks > 0, maximumPollCount > 0 else { return nil }
        self.startedAtTicks = startedAtTicks
        self.timeoutTicks = timeoutTicks
        self.maximumPollCount = maximumPollCount
    }

    mutating func permitAnotherPoll(counterTick: UInt64) -> Bool {
        guard counterTick &- startedAtTicks < timeoutTicks,
              pollCount < maximumPollCount
        else {
            return false
        }
        pollCount &+= 1
        return true
    }
}
