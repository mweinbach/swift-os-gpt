@main
struct GraphicsExecutionPolicyTests {
    static func main() {
        separatesRasterizationFromPresentation()
        forbidsCPUInProductionBeforeOtherChecks()
        permitsExplicitCPUDiagnostics()
        requiresGPUQueueAndFence()
        requiresPresenterToImportGPUImages()
        requiresCompatibleImageDomains()
        validatesQueuedPresentationCapabilities()
        permitsContinuousGPUScanoutWithoutAQueue()
        productionSelectorNeverFallsBackToCPU()
        diagnosticSelectorPrefersGPU()
        diagnosticSelectorFallsBackWithACompleteAudit()
        boundsCandidatesAndPreservesValueSemantics()
        print("graphics execution policy host tests: 12 groups passed")
    }

    private static func separatesRasterizationFromPresentation() {
        let virGL = gpuRasterizer(kind: .virtIOVirGL, domain: domain(1))
        let v3D = gpuRasterizer(kind: .nativeV3D, domain: domain(2))
        expect(virGL.kind.isHardwareGPU, "VirtIO GPU classified as CPU")
        expect(v3D.kind.isHardwareGPU, "V3D classified as CPU")
        expect(
            !cpuRasterizer(domain: domain(1)).kind.isHardwareGPU,
            "CPU diagnostic classified as hardware GPU"
        )

        let ramfb = continuousPresenter(
            kind: .firmwareRAMFramebuffer,
            domain: domain(1),
            acceptsCPU: true,
            acceptsGPU: false
        )
        let simpleFB = continuousPresenter(
            kind: .simpleFramebuffer,
            domain: domain(1),
            acceptsCPU: true,
            acceptsGPU: false
        )
        let virtIO = queuedPresenter(
            kind: .virtIOGPUScanout,
            domain: domain(1)
        )
        let native = queuedPresenter(kind: .nativeDisplay, domain: domain(2))
        expect(ramfb.scheduling == .continuousScanout, "ramfb scheduling")
        expect(simpleFB.kind == .simpleFramebuffer, "simplefb identity")
        expect(virtIO.scheduling == .queued, "VirtIO scanout scheduling")
        expect(native.kind == .nativeDisplay, "native display identity")
    }

    private static func forbidsCPUInProductionBeforeOtherChecks() {
        let output = domain(10)
        let incompatiblePresenter = continuousPresenter(
            kind: .firmwareRAMFramebuffer,
            domain: domain(11),
            acceptsCPU: false,
            acceptsGPU: false
        )
        expect(
            GraphicsExecutionContract.evaluate(
                rasterizer: cpuRasterizer(domain: output),
                presenter: incompatiblePresenter,
                policy: .productionGPUOnly
            ) == .rejected(.cpuRasterizerForbiddenInProduction),
            "production policy did not reject CPU at the boundary"
        )
    }

    private static func permitsExplicitCPUDiagnostics() {
        let shared = domain(20)
        let rasterizer = cpuRasterizer(domain: shared)
        let presenter = continuousPresenter(
            kind: .simpleFramebuffer,
            domain: shared,
            acceptsCPU: true,
            acceptsGPU: false
        )
        let evaluation = GraphicsExecutionContract.evaluate(
            rasterizer: rasterizer,
            presenter: presenter,
            policy: .diagnosticAllowCPURasterizer
        )
        guard case .compatible(let path) = evaluation else {
            fatalError("explicit CPU diagnostic path rejected")
        }
        expect(!path.usesHardwareGPURasterization, "CPU path marked as GPU")
        expect(path.presenter.kind == .simpleFramebuffer, "presenter was lost")

        let rejectingPresenter = continuousPresenter(
            kind: .nativeDisplay,
            domain: shared,
            acceptsCPU: false,
            acceptsGPU: true
        )
        expect(
            GraphicsExecutionContract.evaluate(
                rasterizer: rasterizer,
                presenter: rejectingPresenter,
                policy: .diagnosticAllowCPURasterizer
            ) == .rejected(
                .presenterCannotConsumeCPUProducedImage(.nativeDisplay)
            ),
            "CPU import rejection was not exact"
        )
    }

    private static func requiresGPUQueueAndFence() {
        let shared = domain(30)
        let presenter = queuedPresenter(
            kind: .virtIOGPUScanout,
            domain: shared
        )
        let noQueue = GraphicsRasterizerCapabilities(
            kind: .hardwareGPU(.virtIOVirGL),
            outputImageDomain: shared,
            queueAndFence: .unavailable
        )
        expect(
            evaluateGPU(noQueue, presenter) == .rejected(
                .gpuSubmissionQueueUnavailable(.virtIOVirGL)
            ),
            "missing GPU queue accepted"
        )

        let noFence = GraphicsRasterizerCapabilities(
            kind: .hardwareGPU(.nativeV3D),
            outputImageDomain: shared,
            queueAndFence: GraphicsQueueFenceCapabilities(
                submissionQueueAvailable: true,
                completionFenceAvailable: false
            )
        )
        expect(
            evaluateGPU(noFence, presenter) == .rejected(
                .gpuCompletionFenceUnavailable(.nativeV3D)
            ),
            "missing GPU completion fence accepted"
        )
    }

    private static func requiresPresenterToImportGPUImages() {
        let shared = domain(40)
        let presenter = continuousPresenter(
            kind: .firmwareRAMFramebuffer,
            domain: shared,
            acceptsCPU: true,
            acceptsGPU: false
        )
        expect(
            evaluateGPU(
                gpuRasterizer(kind: .virtIOVirGL, domain: shared),
                presenter
            ) == .rejected(
                .presenterCannotConsumeGPUProducedImage(
                    .firmwareRAMFramebuffer
                )
            ),
            "presenter silently accepted a GPU image"
        )
    }

    private static func requiresCompatibleImageDomains() {
        let produced = domain(50)
        let accepted = domain(51)
        let presenter = queuedPresenter(
            kind: .nativeDisplay,
            domain: accepted
        )
        expect(
            evaluateGPU(
                gpuRasterizer(kind: .nativeV3D, domain: produced),
                presenter
            ) == .rejected(
                .imageDomainMismatch(produced: produced, accepted: accepted)
            ),
            "foreign GPU image domain accepted"
        )
    }

    private static func validatesQueuedPresentationCapabilities() {
        let shared = domain(60)
        let rasterizer = gpuRasterizer(kind: .nativeV3D, domain: shared)
        let noQueue = GraphicsPresenterCapabilities(
            kind: .nativeDisplay,
            inputImageDomain: shared,
            scheduling: .queued,
            canConsumeCPUProducedImage: false,
            canConsumeGPUProducedImage: true,
            queueAndFence: .unavailable
        )
        expect(
            evaluateGPU(rasterizer, noQueue) == .rejected(
                .presenterSubmissionQueueUnavailable(.nativeDisplay)
            ),
            "queued presenter without queue accepted"
        )

        let noFence = GraphicsPresenterCapabilities(
            kind: .virtIOGPUScanout,
            inputImageDomain: shared,
            scheduling: .queued,
            canConsumeCPUProducedImage: true,
            canConsumeGPUProducedImage: true,
            queueAndFence: GraphicsQueueFenceCapabilities(
                submissionQueueAvailable: true,
                completionFenceAvailable: false
            )
        )
        expect(
            evaluateGPU(rasterizer, noFence) == .rejected(
                .presenterCompletionFenceUnavailable(.virtIOGPUScanout)
            ),
            "queued presenter without completion fence accepted"
        )
    }

    private static func permitsContinuousGPUScanoutWithoutAQueue() {
        let shared = domain(70)
        let presenter = continuousPresenter(
            kind: .simpleFramebuffer,
            domain: shared,
            acceptsCPU: true,
            acceptsGPU: true
        )
        let evaluation = evaluateGPU(
            gpuRasterizer(kind: .nativeV3D, domain: shared),
            presenter
        )
        guard case .compatible(let path) = evaluation else {
            fatalError("continuous GPU-produced scanout rejected")
        }
        expect(path.usesHardwareGPURasterization, "GPU path became CPU path")
        expect(
            !path.presenter.queueAndFence.submissionQueueAvailable,
            "continuous presenter fixture unexpectedly has a queue"
        )
    }

    private static func productionSelectorNeverFallsBackToCPU() {
        let shared = domain(80)
        let presenter = continuousPresenter(
            kind: .firmwareRAMFramebuffer,
            domain: shared,
            acceptsCPU: true,
            acceptsGPU: true
        )
        var candidates = GraphicsExecutionCandidateSet()
        expect(
            candidates.append(
                GraphicsExecutionCandidate(
                    rasterizer: cpuRasterizer(domain: shared),
                    presenter: presenter
                )
            ) == .inserted(index: 0),
            "CPU candidate append"
        )
        let brokenGPU = GraphicsRasterizerCapabilities(
            kind: .hardwareGPU(.virtIOVirGL),
            outputImageDomain: shared,
            queueAndFence: GraphicsQueueFenceCapabilities(
                submissionQueueAvailable: true,
                completionFenceAvailable: false
            )
        )
        _ = candidates.append(
            GraphicsExecutionCandidate(
                rasterizer: brokenGPU,
                presenter: presenter
            )
        )

        let report = candidates.select(policy: .productionGPUOnly)
        expect(report.selectedPath == nil, "production selected CPU fallback")
        expect(report.failure == .noCompatibleCandidate, "failure summary")
        expect(
            report.rejection(at: 0) == .cpuRasterizerForbiddenInProduction,
            "CPU production rejection audit"
        )
        expect(
            report.rejection(at: 1) == .gpuCompletionFenceUnavailable(
                .virtIOVirGL
            ),
            "GPU rejection audit"
        )
    }

    private static func diagnosticSelectorPrefersGPU() {
        let shared = domain(90)
        let presenter = continuousPresenter(
            kind: .simpleFramebuffer,
            domain: shared,
            acceptsCPU: true,
            acceptsGPU: true
        )
        var candidates = GraphicsExecutionCandidateSet()
        _ = candidates.append(
            GraphicsExecutionCandidate(
                rasterizer: cpuRasterizer(domain: shared),
                presenter: presenter,
                preference: 0
            )
        )
        _ = candidates.append(
            GraphicsExecutionCandidate(
                rasterizer: gpuRasterizer(
                    kind: .nativeV3D,
                    domain: shared
                ),
                presenter: presenter,
                preference: .max
            )
        )

        let report = candidates.select(policy: .diagnosticAllowCPURasterizer)
        expect(report.selectedCandidateIndex == 1, "CPU outranked valid GPU")
        expect(
            report.selectedPath?.usesHardwareGPURasterization == true,
            "diagnostic mode failed to prefer GPU"
        )
        expect(report.isCompatible(at: 0), "valid CPU path marked rejected")
        expect(report.isCompatible(at: 1), "valid GPU path marked rejected")
    }

    private static func diagnosticSelectorFallsBackWithACompleteAudit() {
        let shared = domain(100)
        let presenter = queuedPresenter(
            kind: .virtIOGPUScanout,
            domain: shared
        )
        var candidates = GraphicsExecutionCandidateSet()
        let brokenGPU = GraphicsRasterizerCapabilities(
            kind: .hardwareGPU(.virtIOVirGL),
            outputImageDomain: shared,
            queueAndFence: .unavailable
        )
        _ = candidates.append(
            GraphicsExecutionCandidate(
                rasterizer: brokenGPU,
                presenter: presenter
            )
        )
        _ = candidates.append(
            GraphicsExecutionCandidate(
                rasterizer: cpuRasterizer(domain: shared),
                presenter: presenter
            )
        )

        let report = candidates.select(policy: .diagnosticAllowCPURasterizer)
        expect(report.selectedCandidateIndex == 1, "CPU diagnostic fallback")
        expect(
            report.selectedPath?.usesHardwareGPURasterization == false,
            "fallback was not CPU diagnostic"
        )
        expect(
            report.rejection(at: 0) == .gpuSubmissionQueueUnavailable(
                .virtIOVirGL
            ),
            "failed GPU reason was not retained"
        )
        expect(report.rejection(at: 1) == nil, "selected CPU was rejected")
    }

    private static func boundsCandidatesAndPreservesValueSemantics() {
        expect(GraphicsImageDomainID(rawValue: 0) == nil, "zero domain accepted")
        var candidates = GraphicsExecutionCandidateSet()
        let shared = domain(110)
        let candidate = GraphicsExecutionCandidate(
            rasterizer: cpuRasterizer(domain: shared),
            presenter: continuousPresenter(
                kind: .firmwareRAMFramebuffer,
                domain: shared,
                acceptsCPU: true,
                acceptsGPU: false
            )
        )
        var index = 0
        while index < GraphicsExecutionCandidateSet.maximumCandidateCount {
            expect(
                candidates.append(candidate) == .inserted(index: index),
                "bounded candidate insertion"
            )
            index += 1
        }
        expect(
            candidates.append(candidate) == .capacityExhausted,
            "candidate capacity overflow"
        )
        expect(candidates.candidate(at: -1) == nil, "negative candidate index")
        expect(candidates.candidate(at: 8) == nil, "high candidate index")

        let empty = GraphicsExecutionCandidateSet().select(
            policy: .productionGPUOnly
        )
        expect(empty.failure == .noCandidates, "empty selection failure")

        let snapshot = candidates
        _ = candidates.select(policy: .diagnosticAllowCPURasterizer)
        expect(snapshot.count == 8, "candidate snapshot mutated")
        expect(snapshot.candidate(at: 0) == candidate, "candidate value lost")
    }

    private static func evaluateGPU(
        _ rasterizer: GraphicsRasterizerCapabilities,
        _ presenter: GraphicsPresenterCapabilities
    ) -> GraphicsExecutionEvaluation {
        GraphicsExecutionContract.evaluate(
            rasterizer: rasterizer,
            presenter: presenter,
            policy: .productionGPUOnly
        )
    }

    private static func domain(_ rawValue: UInt32) -> GraphicsImageDomainID {
        guard let domain = GraphicsImageDomainID(rawValue: rawValue) else {
            fatalError("invalid image domain fixture")
        }
        return domain
    }

    private static func cpuRasterizer(
        domain: GraphicsImageDomainID
    ) -> GraphicsRasterizerCapabilities {
        GraphicsRasterizerCapabilities(
            kind: .cpuDiagnostic,
            outputImageDomain: domain,
            queueAndFence: .unavailable
        )
    }

    private static func gpuRasterizer(
        kind: HardwareGPURasterizerKind,
        domain: GraphicsImageDomainID
    ) -> GraphicsRasterizerCapabilities {
        GraphicsRasterizerCapabilities(
            kind: .hardwareGPU(kind),
            outputImageDomain: domain,
            queueAndFence: .available
        )
    }

    private static func continuousPresenter(
        kind: GraphicsPresenterKind,
        domain: GraphicsImageDomainID,
        acceptsCPU: Bool,
        acceptsGPU: Bool
    ) -> GraphicsPresenterCapabilities {
        GraphicsPresenterCapabilities(
            kind: kind,
            inputImageDomain: domain,
            scheduling: .continuousScanout,
            canConsumeCPUProducedImage: acceptsCPU,
            canConsumeGPUProducedImage: acceptsGPU,
            queueAndFence: .unavailable
        )
    }

    private static func queuedPresenter(
        kind: GraphicsPresenterKind,
        domain: GraphicsImageDomainID
    ) -> GraphicsPresenterCapabilities {
        GraphicsPresenterCapabilities(
            kind: kind,
            inputImageDomain: domain,
            scheduling: .queued,
            canConsumeCPUProducedImage: true,
            canConsumeGPUProducedImage: true,
            queueAndFence: .available
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
