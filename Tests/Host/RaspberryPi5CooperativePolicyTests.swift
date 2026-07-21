@main
struct RaspberryPi5CooperativePolicyTests {
    static func main() {
        selectsExactlyOneBlockingBootstrapPerPass()
        permitsSteadyNetworkAndOneStorageStepTogether()
        adoptsWatchdogOnlyForObservedTryBootPayload()
        suppressesWatchdogServiceUntilDurableTrialHealth()
        reportsFlushAndLossMarkersExactlyOnce()
        print("Raspberry Pi 5 cooperative policy: 5 groups passed")
    }

    private static func adoptsWatchdogOnlyForObservedTryBootPayload() {
        expect(
            RaspberryPi5WatchdogBootPolicy.requiresAdoption(
                payloadWasTryBoot: true
            ),
            "firmware-observed tryboot payload did not require adoption"
        )
        expect(
            !RaspberryPi5WatchdogBootPolicy.requiresAdoption(
                payloadWasTryBoot: false
            ),
            "stable payload was allowed to touch watchdog MMIO"
        )
        expect(
            !RaspberryPi5WatchdogBootPolicy.requiresAdoption(
                payloadWasTryBoot: nil
            ),
            "non-payload or missing firmware identity required adoption"
        )
    }

    private static func suppressesWatchdogServiceUntilDurableTrialHealth() {
        var normal = RaspberryPi5WatchdogProbationPolicy(
            isTryBootCandidate: false
        )
        expect(normal.serviceAction == .inactive,
               "normal boot gained watchdog service authority")
        expect(!normal.releaseAfterDurableCandidateHealth(),
               "normal boot manufactured a trial-health release")

        var trial = RaspberryPi5WatchdogProbationPolicy(
            isTryBootCandidate: true
        )
        expect(
            trial.serviceAction == .suppressDuringTrialProbation,
            "tryboot candidate could extend its rollback window"
        )
        expect(trial.releaseAfterDurableCandidateHealth(),
               "durable candidate health did not release probation")
        expect(trial.serviceAction == .programService,
               "healthy candidate remained rollback-bound")
        expect(!trial.releaseAfterDurableCandidateHealth(),
               "candidate health released probation more than once")
    }

    private static func selectsExactlyOneBlockingBootstrapPerPass() {
        expect(
            RaspberryPi5CooperativePolicy.action(
                storageBootstrapResolved: false,
                storageHasWork: true,
                networkBootstrapDeferred: true,
                networkHasWork: true
            ) == .storageBootstrap,
            "network ran before signed-volume bootstrap resolved"
        )
        expect(
            RaspberryPi5CooperativePolicy.action(
                storageBootstrapResolved: true,
                storageHasWork: true,
                networkBootstrapDeferred: true,
                networkHasWork: true
            ) == .networkBootstrap,
            "recovery ran in the blocking network-bootstrap pass"
        )
    }

    private static func permitsSteadyNetworkAndOneStorageStepTogether() {
        expect(
            RaspberryPi5CooperativePolicy.action(
                storageBootstrapResolved: true,
                storageHasWork: true,
                networkBootstrapDeferred: false,
                networkHasWork: true
            ) == .steadyState,
            "steady network/recovery work was unnecessarily serialized"
        )
        expect(
            RaspberryPi5CooperativePolicy.action(
                storageBootstrapResolved: true,
                storageHasWork: false,
                networkBootstrapDeferred: false,
                networkHasWork: false
            ) == .idle,
            "empty service pass did not idle"
        )
    }

    private static func reportsFlushAndLossMarkersExactlyOnce() {
        var policy = RaspberryPi5StorageReportingPolicy()
        expect(policy.shouldReportFirstFlush(), "first flush marker was suppressed")
        expect(!policy.shouldReportFirstFlush(), "flush marker fed itself")
        expect(!policy.shouldReportFirstFlush(), "later append emitted another marker")
        expect(policy.shouldReportFirstVolatileLoss(), "first loss was hidden")
        expect(!policy.shouldReportFirstVolatileLoss(), "loss marker repeated")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
