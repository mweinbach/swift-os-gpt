enum RaspberryPi5CooperativeAction: UInt8, Equatable {
    case idle
    case storageBootstrap
    case networkBootstrap
    case steadyState
}

enum RaspberryPi5CooperativePolicy {
    static func action(
        storageBootstrapResolved: Bool,
        storageHasWork: Bool,
        networkBootstrapDeferred: Bool,
        networkHasWork: Bool
    ) -> RaspberryPi5CooperativeAction {
        if storageHasWork, !storageBootstrapResolved {
            return .storageBootstrap
        }
        if networkBootstrapDeferred { return .networkBootstrap }
        if storageHasWork || networkHasWork { return .steadyState }
        return .idle
    }
}

enum RaspberryPi5WatchdogServiceAction: UInt8, Equatable {
    case programService
    case suppressDuringTrialProbation
}

/// Pure policy for the Pi one-shot trial watchdog. Firmware has already given
/// the candidate one initial timeout window when the watchdog is adopted. No
/// later cooperative checkpoint may extend that window until the exact
/// candidate-health transition has become durable in the A/B journal.
struct RaspberryPi5WatchdogProbationPolicy {
    private(set) var isTrialProbationActive: Bool

    init(isTryBootCandidate: Bool) {
        isTrialProbationActive = isTryBootCandidate
    }

    var serviceAction: RaspberryPi5WatchdogServiceAction {
        isTrialProbationActive
            ? .suppressDuringTrialProbation : .programService
    }

    mutating func releaseAfterDurableCandidateHealth() -> Bool {
        guard isTrialProbationActive else { return false }
        isTrialProbationActive = false
        return true
    }
}

/// One-shot marker state kept separate from persistent-record sequencing. A
/// successful append marker itself enters the retained ring and is flushed on
/// a later pass, but must never authorize another marker.
struct RaspberryPi5StorageReportingPolicy {
    private var didReportFirstFlush = false
    private var didReportVolatileLoss = false

    mutating func shouldReportFirstFlush() -> Bool {
        guard !didReportFirstFlush else { return false }
        didReportFirstFlush = true
        return true
    }

    mutating func shouldReportFirstVolatileLoss() -> Bool {
        guard !didReportVolatileLoss else { return false }
        didReportVolatileLoss = true
        return true
    }
}
