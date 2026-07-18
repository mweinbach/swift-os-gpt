/// The execution policy is an invariant at the rasterization boundary. A
/// production boot may only construct a path whose pixels are produced by a
/// hardware GPU. The CPU implementation remains available as an explicit
/// bring-up and correctness diagnostic.
enum GraphicsExecutionPolicy: UInt8, Equatable {
    case productionGPUOnly
    case diagnosticAllowCPURasterizer

    var permitsCPURasterization: Bool {
        self == .diagnosticAllowCPURasterizer
    }
}

enum HardwareGPURasterizerKind: UInt8, Equatable {
    case virtIOVirGL
    case nativeV3D
}

enum GraphicsRasterizerKind: Equatable {
    case cpuDiagnostic
    case hardwareGPU(HardwareGPURasterizerKind)

    var isHardwareGPU: Bool {
        switch self {
        case .cpuDiagnostic:
            return false
        case .hardwareGPU:
            return true
        }
    }
}

/// Presentation is deliberately separate from rasterization. A presenter may
/// continuously scan a fixed image or explicitly queue images for scanout;
/// neither choice says which engine produced the pixels.
enum GraphicsPresenterKind: UInt8, Equatable {
    case firmwareRAMFramebuffer
    case simpleFramebuffer
    case virtIOGPUScanout
    case nativeDisplay
}

enum GraphicsPresentationScheduling: UInt8, Equatable {
    case continuousScanout
    case queued
}

/// An opaque compatibility identity for image storage and ownership. Drivers
/// publish the same ID only when no copy or CPU rasterization is needed between
/// the producer and presenter. A driver may publish multiple candidate records
/// when it can import more than one image domain.
struct GraphicsImageDomainID: Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

/// Queue and completion-fence availability is data, not an assumption derived
/// from a backend name. This allows partially initialized and failed devices to
/// be rejected before any frame resource is acquired.
struct GraphicsQueueFenceCapabilities: Equatable {
    let submissionQueueAvailable: Bool
    let completionFenceAvailable: Bool

    static let unavailable = GraphicsQueueFenceCapabilities(
        submissionQueueAvailable: false,
        completionFenceAvailable: false
    )

    static let available = GraphicsQueueFenceCapabilities(
        submissionQueueAvailable: true,
        completionFenceAvailable: true
    )
}

struct GraphicsRasterizerCapabilities: Equatable {
    let kind: GraphicsRasterizerKind
    let outputImageDomain: GraphicsImageDomainID
    let queueAndFence: GraphicsQueueFenceCapabilities

    init(
        kind: GraphicsRasterizerKind,
        outputImageDomain: GraphicsImageDomainID,
        queueAndFence: GraphicsQueueFenceCapabilities
    ) {
        self.kind = kind
        self.outputImageDomain = outputImageDomain
        self.queueAndFence = queueAndFence
    }
}

struct GraphicsPresenterCapabilities: Equatable {
    let kind: GraphicsPresenterKind
    let inputImageDomain: GraphicsImageDomainID
    let scheduling: GraphicsPresentationScheduling
    let canConsumeCPUProducedImage: Bool
    let canConsumeGPUProducedImage: Bool
    let queueAndFence: GraphicsQueueFenceCapabilities

    init(
        kind: GraphicsPresenterKind,
        inputImageDomain: GraphicsImageDomainID,
        scheduling: GraphicsPresentationScheduling,
        canConsumeCPUProducedImage: Bool,
        canConsumeGPUProducedImage: Bool,
        queueAndFence: GraphicsQueueFenceCapabilities
    ) {
        self.kind = kind
        self.inputImageDomain = inputImageDomain
        self.scheduling = scheduling
        self.canConsumeCPUProducedImage = canConsumeCPUProducedImage
        self.canConsumeGPUProducedImage = canConsumeGPUProducedImage
        self.queueAndFence = queueAndFence
    }
}

enum GraphicsExecutionRejection: Equatable {
    case cpuRasterizerForbiddenInProduction
    case gpuSubmissionQueueUnavailable(HardwareGPURasterizerKind)
    case gpuCompletionFenceUnavailable(HardwareGPURasterizerKind)
    case presenterCannotConsumeCPUProducedImage(GraphicsPresenterKind)
    case presenterCannotConsumeGPUProducedImage(GraphicsPresenterKind)
    case imageDomainMismatch(
        produced: GraphicsImageDomainID,
        accepted: GraphicsImageDomainID
    )
    case presenterSubmissionQueueUnavailable(GraphicsPresenterKind)
    case presenterCompletionFenceUnavailable(GraphicsPresenterKind)
}

/// A validated pairing. Its initializer is intentionally hidden so callers
/// cannot bypass the policy and capability checks below.
struct GraphicsExecutionPath: Equatable {
    let rasterizer: GraphicsRasterizerCapabilities
    let presenter: GraphicsPresenterCapabilities

    fileprivate init(
        rasterizer: GraphicsRasterizerCapabilities,
        presenter: GraphicsPresenterCapabilities
    ) {
        self.rasterizer = rasterizer
        self.presenter = presenter
    }

    var usesHardwareGPURasterization: Bool {
        rasterizer.kind.isHardwareGPU
    }
}

enum GraphicsExecutionEvaluation: Equatable {
    case compatible(GraphicsExecutionPath)
    case rejected(GraphicsExecutionRejection)
}

/// Validates one rasterizer/presenter pairing in a stable order so a failed
/// boot reports one precise, reproducible reason.
enum GraphicsExecutionContract {
    static func evaluate(
        rasterizer: GraphicsRasterizerCapabilities,
        presenter: GraphicsPresenterCapabilities,
        policy: GraphicsExecutionPolicy
    ) -> GraphicsExecutionEvaluation {
        switch rasterizer.kind {
        case .cpuDiagnostic:
            guard policy.permitsCPURasterization else {
                return .rejected(.cpuRasterizerForbiddenInProduction)
            }
            guard presenter.canConsumeCPUProducedImage else {
                return .rejected(
                    .presenterCannotConsumeCPUProducedImage(presenter.kind)
                )
            }

        case .hardwareGPU(let hardwareKind):
            guard rasterizer.queueAndFence.submissionQueueAvailable else {
                return .rejected(
                    .gpuSubmissionQueueUnavailable(hardwareKind)
                )
            }
            guard rasterizer.queueAndFence.completionFenceAvailable else {
                return .rejected(
                    .gpuCompletionFenceUnavailable(hardwareKind)
                )
            }
            guard presenter.canConsumeGPUProducedImage else {
                return .rejected(
                    .presenterCannotConsumeGPUProducedImage(presenter.kind)
                )
            }
        }

        guard rasterizer.outputImageDomain == presenter.inputImageDomain else {
            return .rejected(
                .imageDomainMismatch(
                    produced: rasterizer.outputImageDomain,
                    accepted: presenter.inputImageDomain
                )
            )
        }

        if presenter.scheduling == .queued {
            guard presenter.queueAndFence.submissionQueueAvailable else {
                return .rejected(
                    .presenterSubmissionQueueUnavailable(presenter.kind)
                )
            }
            guard presenter.queueAndFence.completionFenceAvailable else {
                return .rejected(
                    .presenterCompletionFenceUnavailable(presenter.kind)
                )
            }
        }

        return .compatible(
            GraphicsExecutionPath(
                rasterizer: rasterizer,
                presenter: presenter
            )
        )
    }
}

/// Candidate preference is considered only after compatibility. Hardware GPU
/// candidates always outrank CPU diagnostic candidates, independent of append
/// order or preference, so diagnostic mode uses the CPU only as a fallback.
struct GraphicsExecutionCandidate: Equatable {
    let rasterizer: GraphicsRasterizerCapabilities
    let presenter: GraphicsPresenterCapabilities
    let preference: UInt8

    init(
        rasterizer: GraphicsRasterizerCapabilities,
        presenter: GraphicsPresenterCapabilities,
        preference: UInt8 = 0
    ) {
        self.rasterizer = rasterizer
        self.presenter = presenter
        self.preference = preference
    }
}

enum GraphicsExecutionCandidateAppendResult: Equatable {
    case inserted(index: Int)
    case capacityExhausted
}

enum GraphicsExecutionSelectionFailure: UInt8, Equatable {
    case noCandidates
    case noCompatibleCandidate
}

/// The report retains one exact rejection per candidate without allocating a
/// collection. A nil rejection for an in-range candidate means it was valid,
/// even when a higher-ranked valid candidate was selected.
struct GraphicsExecutionSelectionReport {
    let candidateCount: Int
    private(set) var selectedPath: GraphicsExecutionPath?
    private(set) var selectedCandidateIndex: Int?

    private var rejection0: GraphicsExecutionRejection?
    private var rejection1: GraphicsExecutionRejection?
    private var rejection2: GraphicsExecutionRejection?
    private var rejection3: GraphicsExecutionRejection?
    private var rejection4: GraphicsExecutionRejection?
    private var rejection5: GraphicsExecutionRejection?
    private var rejection6: GraphicsExecutionRejection?
    private var rejection7: GraphicsExecutionRejection?

    fileprivate init(candidateCount: Int) {
        self.candidateCount = candidateCount
        selectedPath = nil
        selectedCandidateIndex = nil
        rejection0 = nil
        rejection1 = nil
        rejection2 = nil
        rejection3 = nil
        rejection4 = nil
        rejection5 = nil
        rejection6 = nil
        rejection7 = nil
    }

    var failure: GraphicsExecutionSelectionFailure? {
        guard selectedPath == nil else { return nil }
        return candidateCount == 0 ? .noCandidates : .noCompatibleCandidate
    }

    func rejection(at index: Int) -> GraphicsExecutionRejection? {
        guard index >= 0, index < candidateCount else { return nil }
        switch index {
        case 0: return rejection0
        case 1: return rejection1
        case 2: return rejection2
        case 3: return rejection3
        case 4: return rejection4
        case 5: return rejection5
        case 6: return rejection6
        default: return rejection7
        }
    }

    func isCompatible(at index: Int) -> Bool {
        index >= 0 && index < candidateCount && rejection(at: index) == nil
    }

    fileprivate mutating func record(
        rejection: GraphicsExecutionRejection,
        at index: Int
    ) {
        switch index {
        case 0: rejection0 = rejection
        case 1: rejection1 = rejection
        case 2: rejection2 = rejection
        case 3: rejection3 = rejection
        case 4: rejection4 = rejection
        case 5: rejection5 = rejection
        case 6: rejection6 = rejection
        default: rejection7 = rejection
        }
    }

    fileprivate mutating func select(
        path: GraphicsExecutionPath,
        candidateIndex: Int
    ) {
        selectedPath = path
        selectedCandidateIndex = candidateIndex
    }
}

/// A bounded candidate store replaces heap-backed backend registries. The
/// selector evaluates every entry, records every rejection, and deterministically
/// chooses the strongest compatible path.
struct GraphicsExecutionCandidateSet {
    static let maximumCandidateCount = 8

    private(set) var count: Int = 0
    private var candidate0: GraphicsExecutionCandidate?
    private var candidate1: GraphicsExecutionCandidate?
    private var candidate2: GraphicsExecutionCandidate?
    private var candidate3: GraphicsExecutionCandidate?
    private var candidate4: GraphicsExecutionCandidate?
    private var candidate5: GraphicsExecutionCandidate?
    private var candidate6: GraphicsExecutionCandidate?
    private var candidate7: GraphicsExecutionCandidate?

    mutating func append(
        _ candidate: GraphicsExecutionCandidate
    ) -> GraphicsExecutionCandidateAppendResult {
        guard count < Self.maximumCandidateCount else {
            return .capacityExhausted
        }
        let index = count
        setStoredCandidate(candidate, at: index)
        count += 1
        return .inserted(index: index)
    }

    func candidate(at index: Int) -> GraphicsExecutionCandidate? {
        guard index >= 0, index < count else { return nil }
        return storedCandidate(at: index)
    }

    func select(
        policy: GraphicsExecutionPolicy
    ) -> GraphicsExecutionSelectionReport {
        var report = GraphicsExecutionSelectionReport(candidateCount: count)
        var bestPriority: UInt16?
        var index = 0

        while index < count {
            let candidate = storedCandidate(at: index)
            let evaluation = GraphicsExecutionContract.evaluate(
                rasterizer: candidate.rasterizer,
                presenter: candidate.presenter,
                policy: policy
            )
            switch evaluation {
            case .rejected(let rejection):
                report.record(rejection: rejection, at: index)

            case .compatible(let path):
                let classPriority: UInt16 = path.usesHardwareGPURasterization
                    ? 0
                    : 256
                let priority = classPriority + UInt16(candidate.preference)
                if bestPriority == nil || priority < bestPriority! {
                    bestPriority = priority
                    report.select(path: path, candidateIndex: index)
                }
            }
            index += 1
        }

        return report
    }

    private func storedCandidate(at index: Int) -> GraphicsExecutionCandidate {
        switch index {
        case 0: return candidate0!
        case 1: return candidate1!
        case 2: return candidate2!
        case 3: return candidate3!
        case 4: return candidate4!
        case 5: return candidate5!
        case 6: return candidate6!
        default: return candidate7!
        }
    }

    private mutating func setStoredCandidate(
        _ candidate: GraphicsExecutionCandidate,
        at index: Int
    ) {
        switch index {
        case 0: candidate0 = candidate
        case 1: candidate1 = candidate
        case 2: candidate2 = candidate
        case 3: candidate3 = candidate
        case 4: candidate4 = candidate
        case 5: candidate5 = candidate
        case 6: candidate6 = candidate
        default: candidate7 = candidate
        }
    }
}
