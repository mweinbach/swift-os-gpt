enum CooperativeTimerProofDecision: Equatable {
    case waiting
    case report(UInt8)
    case complete
    case timedOut
}

/// Pure progress policy for a timer proof that must keep polled board devices
/// alive. Counter and interrupt deltas deliberately use wrapping arithmetic.
struct CooperativeTimerProofPolicy {
    static let requiredInterruptCount: UInt8 = 3

    private let startedAtTicks: UInt64
    private let startingInterruptCount: UInt64
    private let timeoutTicks: UInt64
    private(set) var reportedInterruptCount: UInt8 = 0

    init?(
        startedAtTicks: UInt64,
        startingInterruptCount: UInt64,
        timeoutTicks: UInt64
    ) {
        guard timeoutTicks > 0 else { return nil }
        self.startedAtTicks = startedAtTicks
        self.startingInterruptCount = startingInterruptCount
        self.timeoutTicks = timeoutTicks
    }

    var isComplete: Bool {
        reportedInterruptCount == Self.requiredInterruptCount
    }

    mutating func poll(
        counterTick: UInt64,
        deliveredInterruptCount: UInt64
    ) -> CooperativeTimerProofDecision {
        if isComplete { return .complete }

        let deliveredSinceStart = deliveredInterruptCount
            &- startingInterruptCount
        if UInt64(reportedInterruptCount) < deliveredSinceStart {
            reportedInterruptCount &+= 1
            return .report(reportedInterruptCount)
        }
        if counterTick &- startedAtTicks >= timeoutTicks {
            return .timedOut
        }
        return .waiting
    }
}
