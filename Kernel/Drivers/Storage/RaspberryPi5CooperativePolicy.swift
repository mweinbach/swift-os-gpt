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
    case inactive
    case programService
    case suppressDuringTrialProbation
}

enum RaspberryPi5WatchdogBootPolicy {
    /// Only a payload partition that firmware explicitly reports as the
    /// one-shot tryboot target may adopt the rollback watchdog during boot.
    /// A stable payload reports `false`; rescue, unsupported, and missing boot
    /// identity report `nil`. Both remain disarmed so early diagnosis never
    /// probes the still-hardware-unverified PM register aperture.
    static func requiresAdoption(payloadWasTryBoot: Bool?) -> Bool {
        payloadWasTryBoot == true
    }
}

/// Pure policy for the Pi one-shot trial watchdog. Firmware has already given
/// an observed tryboot payload one initial timeout window when the watchdog is
/// adopted. Stable, rescue, unsupported, and unidentified boots stay inactive.
/// No later cooperative checkpoint may extend a candidate's window until the
/// exact candidate-health transition has become durable in the A/B journal.
struct RaspberryPi5WatchdogProbationPolicy {
    private enum State {
        case inactive
        case trialProbation
        case released
    }

    private var state: State

    init(isTryBootCandidate: Bool) {
        state = isTryBootCandidate ? .trialProbation : .inactive
    }

    var isTrialProbationActive: Bool {
        state == .trialProbation
    }

    var serviceAction: RaspberryPi5WatchdogServiceAction {
        switch state {
        case .inactive: return .inactive
        case .trialProbation: return .suppressDuringTrialProbation
        case .released: return .programService
        }
    }

    mutating func releaseAfterDurableCandidateHealth() -> Bool {
        guard state == .trialProbation else { return false }
        state = .released
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
