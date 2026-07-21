#if BOOT_UPDATE_ORCHESTRATOR_STANDALONE_TEST
struct PlatformBootObservation: Equatable {
    let slot: BootSlot
    let wasTryBoot: Bool
    let trialCapability: PlatformTrialBootCapability
}
#endif

private enum RuntimePortEvent: Equatable {
    case acquire
    case release
    case load
    case commit(UInt64)
    case stage(BootCandidateStageAction)
    case verifyCandidate(BootCandidateVerificationAction)
    case selector(BootSelectorCommitAction)
    case recoverySelector(BootRecoverySelectorRepairAction)
    case mirror(BootPeerMirrorAction)
    case verifyMirror(BootPeerMirrorVerificationAction)
}

private struct TestBootUpdateRuntimePort: BootUpdateRuntimePort {
    var record: BootControlRecord?
    var events: [RuntimePortEvent] = []
    var leaseAvailable = true
    var leaseHeld = false
    var failNextJournalCommit = false
    var failNextJournalCommitAfterWrite = false
    var candidateStageSucceeds = true
    var selectorCommitSucceeds = true
    var recoverySelectorRepair:
        BootUpdateRuntimeRecoverySelectorRepairResult = .repaired
    var peerMirrorSucceeds = true
    var candidateVerification:
        BootUpdateRuntimeCandidateVerificationResult = .inProgress
    var mirrorVerification:
        BootUpdateRuntimeMirrorVerificationResult = .inProgress

    mutating func acquireExclusiveMediaLease() -> Bool {
        events.append(.acquire)
        guard leaseAvailable, !leaseHeld else { return false }
        leaseHeld = true
        return true
    }

    mutating func releaseExclusiveMediaLease() {
        expect(leaseHeld, "released an unheld runtime media lease")
        events.append(.release)
        leaseHeld = false
    }

    mutating func loadBootControlRecord()
        -> BootUpdateRuntimeJournalLoadResult {
        expect(leaseHeld, "journal load escaped the runtime media lease")
        events.append(.load)
        guard let record else { return .unavailable }
        return .record(record)
    }

    mutating func commitBootControlRecord(
        _ record: BootControlRecord
    ) -> Bool {
        expect(leaseHeld, "journal commit escaped the runtime media lease")
        events.append(.commit(record.sequence))
        if failNextJournalCommit {
            failNextJournalCommit = false
            return false
        }
        self.record = record
        if failNextJournalCommitAfterWrite {
            failNextJournalCommitAfterWrite = false
            return false
        }
        return true
    }

    mutating func stageCandidate(
        _ action: BootCandidateStageAction
    ) -> Bool {
        expect(leaseHeld, "candidate write escaped the runtime media lease")
        events.append(.stage(action))
        return candidateStageSucceeds
    }

    mutating func verifyCandidate(
        _ action: BootCandidateVerificationAction
    ) -> BootUpdateRuntimeCandidateVerificationResult {
        expect(leaseHeld, "candidate hash escaped the runtime media lease")
        events.append(.verifyCandidate(action))
        return candidateVerification
    }

    mutating func commitSelector(
        _ action: BootSelectorCommitAction
    ) -> Bool {
        expect(leaseHeld, "selector write escaped the runtime media lease")
        events.append(.selector(action))
        return selectorCommitSucceeds
    }

    mutating func repairSelectorFromRecovery(
        _ action: BootRecoverySelectorRepairAction
    ) -> BootUpdateRuntimeRecoverySelectorRepairResult {
        expect(leaseHeld, "recovery selector repair escaped the media lease")
        events.append(.recoverySelector(action))
        return recoverySelectorRepair
    }

    mutating func mirrorPeer(_ action: BootPeerMirrorAction) -> Bool {
        expect(leaseHeld, "peer mirror escaped the runtime media lease")
        events.append(.mirror(action))
        return peerMirrorSucceeds
    }

    mutating func verifyMirror(
        _ action: BootPeerMirrorVerificationAction
    ) -> BootUpdateRuntimeMirrorVerificationResult {
        expect(leaseHeld, "mirror hash escaped the runtime media lease")
        events.append(.verifyMirror(action))
        return mirrorVerification
    }
}

@main
struct BootUpdateRuntimeExecutorTests {
    private static let fingerprint: UInt64 = 0x5357_4142_0000_0002
    private static let oldDigest = BootImageDigest(
        word0: 1,
        word1: 2,
        word2: 3,
        word3: 4
    )
    private static let newDigest = BootImageDigest(
        word0: 5,
        word1: 6,
        word2: 7,
        word3: 8
    )

    static func main() {
        requiresBootRecoveryAndSerializesEveryEffect()
        replaysAnUnjournaledCandidateChunk()
        latchesAnUncertainJournalWriteUntilReboot()
        repairsOnlyAPostHealthSelectorFromRecovery()
        recoversFailedTrialsBeforeFurtherWrites()
        promotesThenMirrorsOnlyFromANormalConfirmedBoot()
        failsClosedWhenTheSharedMediaLeaseIsUnavailable()
        print("boot update runtime executor host tests: 7 groups passed")
    }

    private static func requiresBootRecoveryAndSerializesEveryEffect() {
        let layout = makeLayout()
        var port = TestBootUpdateRuntimePort(record: initialRecord())
        var executor = BootUpdateRuntimeExecutor()

        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .failure(.bootRecoveryRequired),
            "runtime work bypassed current-boot recovery"
        )
        expect(port.events.isEmpty, "unrecovered work touched shared media")

        expect(
            executor.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            ) == .recovered(initialRecord()),
            "stable boot recovery failed"
        )
        expect(
            port.events == [.acquire, .load, .release],
            "stable recovery did not hold one media lease"
        )
        port.events = []

        let accepted = executor.beginRelease(
            descriptor(),
            through: &port,
            observation: normal(.a),
            layout: layout
        )
        guard case .releaseAccepted(let writing) = accepted else {
            fail("release descriptor was not journaled")
        }
        expect(writing.phase == .writingCandidate, "release phase")
        expect(writing.candidateSlot == .b, "inactive release target")
        expect(
            port.events == [
                .acquire,
                .load,
                .commit(writing.sequence),
                .release,
            ],
            "release intent was not committed under one media lease"
        )
    }

    private static func replaysAnUnjournaledCandidateChunk() {
        let layout = makeLayout()
        var port = TestBootUpdateRuntimePort(record: initialRecord())
        var executor = BootUpdateRuntimeExecutor()
        _ = executor.recoverCurrentBoot(
            through: &port,
            observation: normal(.a),
            layout: layout
        )
        _ = executor.beginRelease(
            descriptor(),
            through: &port,
            observation: normal(.a),
            layout: layout
        )
        let journaledWriting = port.record!
        port.events = []
        port.failNextJournalCommit = true

        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .failure(.journalCommitFailed),
            "post-write journal failure was hidden"
        )
        guard case .stage(let first)? = port.events.first(where: {
                  if case .stage = $0 { return true }
                  return false
              })
        else { fail("candidate chunk was not attempted") }
        expect(first.nextBlock == 0 && first.blockCount == 3,
               "first bounded candidate chunk")
        expect(port.record == journaledWriting,
               "failed journal commit advanced durable cursor")
        expect(
            port.events == [
                .acquire,
                .load,
                .stage(first),
                .commit(journaledWriting.sequence + 1),
                .release,
            ],
            "candidate effect and cursor commit escaped serialization"
        )

        port.events = []
        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .failure(.durabilityRecoveryRequired),
            "uncertain journal durability allowed same-boot replay"
        )
        expect(port.events.isEmpty,
               "durability latch touched media before reboot recovery")

        executor = BootUpdateRuntimeExecutor()
        guard case .recovered(let rebootRecovered) =
                executor.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            )
        else { fail("fresh executor did not reopen the durable journal") }
        expect(rebootRecovered.phase == .writingCandidate
                && rebootRecovered.nextCandidateBlock == 0,
               "reboot recovery changed the durable candidate cursor")
        port.events = []
        guard case .progressed(let replayed) = executor.serviceOnce(
            through: &port,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 3
        ) else { fail("candidate chunk was not replayable") }
        guard case .stage(let replay)? = port.events.first(where: {
                  if case .stage = $0 { return true }
                  return false
              })
        else { fail("replayed candidate chunk was not issued") }
        expect(replay == first, "journal replay changed candidate bounds")
        expect(replayed.nextCandidateBlock == 3,
               "replayed cursor was not committed")

        while port.record!.nextCandidateBlock < layout.slotBlockCount {
            guard case .progressed = executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) else { fail("candidate staging did not finish") }
        }
        port.candidateVerification = .inProgress
        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .verificationInProgress(.candidate(.b)),
            "cooperative candidate verification was not resumable"
        )
        let sequenceBeforeSeal = port.record!.sequence
        port.candidateVerification = .verified(descriptor())
        guard case .progressed(let pending) = executor.serviceOnce(
            through: &port,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 3
        ) else { fail("verified candidate was not sealed") }
        expect(pending.phase == .trialPending, "candidate seal phase")
        expect(pending.sequence == sequenceBeforeSeal + 1,
               "candidate seal was not journaled")
        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .trialResetRequired(
                BootTrialAuthorizationAction(
                    confirmedSlot: .a,
                    candidateSlot: .b,
                    generation: 2,
                    digest: newDigest,
                    trialToken: 99
                )
            ),
            "sealed candidate did not stop at the tryboot reset boundary"
        )
    }

    private static func latchesAnUncertainJournalWriteUntilReboot() {
        let layout = makeLayout()
        var port = TestBootUpdateRuntimePort(record: initialRecord())
        var executor = BootUpdateRuntimeExecutor()
        _ = executor.recoverCurrentBoot(
            through: &port,
            observation: normal(.a),
            layout: layout
        )
        _ = executor.beginRelease(
            descriptor(),
            through: &port,
            observation: normal(.a),
            layout: layout
        )
        port.events = []
        port.failNextJournalCommitAfterWrite = true

        expect(
            executor.serviceOnce(
                through: &port,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 3
            ) == .failure(.journalCommitFailed),
            "post-write barrier failure was hidden"
        )
        let visibleProgress = port.record!
        expect(visibleProgress.nextCandidateBlock == 3,
               "uncertain write fixture did not expose the newer replica")
        port.events = []
        expect(
            executor.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            ) == .failure(.durabilityRecoveryRequired),
            "uncertain newer replica was trusted in the same boot"
        )
        expect(port.events.isEmpty,
               "journal latch reopened media in the same boot")

        var rebooted = BootUpdateRuntimeExecutor()
        guard case .recovered(let rebootRecovered) =
                rebooted.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            )
        else { fail("reboot did not reconcile the surviving newer replica") }
        expect(rebootRecovered.phase == .writingCandidate
                && rebootRecovered.nextCandidateBlock == 3,
               "reboot did not reconcile the surviving newer cursor")
    }

    private static func recoversFailedTrialsBeforeFurtherWrites() {
        let layout = makeLayout()
        let pending = trialPendingRecord()
        var port = TestBootUpdateRuntimePort(record: pending)
        var executor = BootUpdateRuntimeExecutor()

        guard case .recovered(let rollback) = executor.recoverCurrentBoot(
            through: &port,
            observation: normal(.a),
            layout: layout
        ) else { fail("failed trial did not recover") }
        expect(rollback.phase == .stable, "rollback phase")
        expect(rollback.confirmedSlot == .a, "rollback changed fallback")
        expect(rollback.failedTrialCount == 1, "rollback counter")
        expect(port.record == rollback, "rollback was not durable")
        expect(
            port.events == [
                .acquire,
                .load,
                .commit(rollback.sequence),
                .release,
            ],
            "rollback recovery escaped the shared media lease"
        )
    }

    private static func repairsOnlyAPostHealthSelectorFromRecovery() {
        let layout = makeLayout()
        let pending = selectorCommitPendingRecord()
        var port = TestBootUpdateRuntimePort(record: pending)
        var recovery = BootUpdateRuntimeExecutor()
        port.recoverySelectorRepair = .inProgress

        expect(
            recovery.recoverSelectorFromRecovery(
                through: &port,
                context: .recovery,
                layout: layout
            ) == .verificationInProgress(.recoverySelector(.b)),
            "cooperative recovery selector verification was not resumable"
        )
        expect(port.record == pending,
               "in-progress recovery selector verification changed journal")
        port.events = []
        port.recoverySelectorRepair = .repaired

        let reset = BootConfirmedSlotRebootAction(
            expectedSlot: .b,
            generation: 2,
            digest: newDigest
        )
        guard case .recoveryResetRequired(let requested) =
                recovery.recoverSelectorFromRecovery(
                    through: &port,
                    context: .recovery,
                    layout: layout
                )
        else { fail("post-health selector repair was not authorized") }
        expect(requested == reset, "recovery reset identity changed")
        guard case .recoverySelector(let action)? = port.events.first(where: {
                  if case .recoverySelector = $0 { return true }
                  return false
              })
        else { fail("recovery selector action was not issued") }
        expect(action.defaultSlot == .b
                && action.confirmedSlot == .a
                && action.candidateSlot == .b
                && action.confirmedRange == layout.slotA
                && action.candidateRange == layout.slotB
                && action.confirmedDigest == oldDigest
                && action.candidateDigest == newDigest,
               "recovery selector action lost slot identity")
        expect(port.record == pending,
               "recovery selector repair changed the journal")
        expect(port.events == [
            .acquire,
            .load,
            .recoverySelector(action),
            .release,
        ], "recovery selector repair escaped one media lease")

        var stablePort = TestBootUpdateRuntimePort(record: initialRecord())
        var stableRecovery = BootUpdateRuntimeExecutor()
        expect(
            stableRecovery.recoverSelectorFromRecovery(
                through: &stablePort,
                context: .recovery,
                layout: layout
            ) == .failure(.orchestrator(.recoveryNotAuthorized)),
            "stable recovery environment gained selector authority"
        )
        expect(stablePort.events == [.acquire, .load, .release],
               "unauthorized recovery performed a selector effect")

        port.events = []
        port.recoverySelectorRepair = .failed
        var failingRecovery = BootUpdateRuntimeExecutor()
        expect(
            failingRecovery.recoverSelectorFromRecovery(
                through: &port,
                context: .recovery,
                layout: layout
            ) == .failure(.recoverySelectorRepairFailed),
            "recovery selector write failure was hidden"
        )
        expect(port.record == pending,
               "failed recovery selector repair changed the journal")

        port.events = []
        port.recoverySelectorRepair = .repaired
        var payloadExecutor = BootUpdateRuntimeExecutor()
        expect(
            payloadExecutor.recoverSelectorFromRecovery(
                through: &port,
                context: .payload(normal(.a)),
                layout: layout
            ) == .failure(.recoveryEnvironmentRequired),
            "payload context entered recovery-only selector repair"
        )
        expect(port.events.isEmpty,
               "rejected payload recovery context touched media")
    }

    private static func promotesThenMirrorsOnlyFromANormalConfirmedBoot() {
        let layout = makeLayout()
        var port = TestBootUpdateRuntimePort(record: trialPendingRecord())
        var trialExecutor = BootUpdateRuntimeExecutor()

        guard case .recovered(let trialBooting) =
                trialExecutor.recoverCurrentBoot(
                    through: &port,
                    observation: trial(.b),
                    layout: layout
                )
        else { fail("candidate tryboot was not recovered") }
        expect(trialBooting.phase == .trialBooting, "trial boot phase")

        let health = BootCandidateHealthAction(
            slot: .b,
            generation: 2,
            digest: newDigest,
            trialToken: 99
        )
        expect(
            trialExecutor.serviceOnce(
                through: &port,
                observation: trial(.b),
                layout: layout,
                maximumBlockCount: 3
            ) == .waitingForHealth(health),
            "trial runtime was treated as healthy without evidence"
        )
        guard case .progressed(let selectorPending) =
                trialExecutor.serviceOnce(
                    through: &port,
                    observation: trial(.b),
                    layout: layout,
                    maximumBlockCount: 3,
                    healthEvidence: health
                )
        else { fail("exact candidate health was not recorded") }
        expect(selectorPending.phase == .selectorCommitPending,
               "selector pending phase")

        port.events = []
        guard case .progressed(let replicating) =
                trialExecutor.serviceOnce(
                    through: &port,
                    observation: trial(.b),
                    layout: layout,
                    maximumBlockCount: 3
                )
        else { fail("selector confirmation was not recorded") }
        expect(replicating.phase == .replicatingPeer,
               "selector did not create durable mirror work")
        expect(replicating.confirmedSlot == .b,
               "healthy candidate was not confirmed")
        expect(replicating.candidateSlot == .a,
               "old confirmed slot was not selected as mirror peer")
        expect(
            port.events == [
                .acquire,
                .load,
                .selector(BootSelectorCommitAction(defaultSlot: .b)),
                .commit(replicating.sequence),
                .release,
            ],
            "selector and journal confirmation were not serialized"
        )

        let reset = BootConfirmedSlotRebootAction(
            expectedSlot: .b,
            generation: 2,
            digest: newDigest
        )
        expect(
            trialExecutor.serviceOnce(
                through: &port,
                observation: trial(.b),
                layout: layout,
                maximumBlockCount: 3
            ) == .confirmedResetRequired(reset),
            "trial runtime was allowed to mirror its fallback"
        )

        var confirmedExecutor = BootUpdateRuntimeExecutor()
        guard case .recovered = confirmedExecutor.recoverCurrentBoot(
            through: &port,
            observation: normal(.b),
            layout: layout
        ) else { fail("normal confirmed boot was not recovered") }
        port.events = []

        while port.record!.nextCandidateBlock < layout.slotBlockCount {
            guard case .progressed = confirmedExecutor.serviceOnce(
                through: &port,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 3
            ) else { fail("peer mirror did not advance") }
        }
        let mirrorEvents = port.events.filter {
            if case .mirror = $0 { return true }
            return false
        }
        expect(!mirrorEvents.isEmpty, "normal confirmed boot did not mirror")
        for event in mirrorEvents {
            guard case .mirror(let action) = event else { continue }
            expect(action.sourceSlot == .b && action.destinationSlot == .a,
                   "peer mirror direction changed")
        }

        port.mirrorVerification = .inProgress
        expect(
            confirmedExecutor.serviceOnce(
                through: &port,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 3
            ) == .verificationInProgress(.mirror(.a)),
            "cooperative mirror verification was not resumable"
        )
        port.mirrorVerification = .verified(
            BootPeerMirrorVerificationEvidence(
                destinationSlot: .a,
                generation: 2,
                digest: newDigest,
                blockCount: layout.slotBlockCount
            )
        )
        guard case .progressed(let stable) = confirmedExecutor.serviceOnce(
            through: &port,
            observation: normal(.b),
            layout: layout,
            maximumBlockCount: 3
        ) else { fail("verified mirror did not converge") }
        expect(stable.phase == .stable, "mirror convergence phase")
        expect(stable.confirmedSlot == .b, "mirror moved confirmed slot")
    }

    private static func failsClosedWhenTheSharedMediaLeaseIsUnavailable() {
        let layout = makeLayout()
        var port = TestBootUpdateRuntimePort(record: initialRecord())
        port.leaseAvailable = false
        var executor = BootUpdateRuntimeExecutor()

        expect(
            executor.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            ) == .failure(.mediaLeaseUnavailable),
            "unavailable media lease did not fail closed"
        )
        expect(port.events == [.acquire],
               "lease failure touched the journal or payload")
        expect(!executor.recoveredCurrentBoot,
               "failed lease marked boot recovery complete")

        port.leaseAvailable = true
        port.record = nil
        port.events = []
        expect(
            executor.recoverCurrentBoot(
                through: &port,
                observation: normal(.a),
                layout: layout
            ) == .failure(.journalUnavailable),
            "missing journal did not fail closed"
        )
        expect(port.events == [.acquire, .load, .release],
               "journal failure leaked the media lease")
    }

    private static func makeLayout() -> BootSlotLayout {
        let slotA = BlockDeviceRange(
            startBlock: 16,
            blockCount: 8,
            within: 64
        )!
        let slotB = BlockDeviceRange(
            startBlock: 32,
            blockCount: 8,
            within: 64
        )!
        return BootSlotLayout(
            slotA: slotA,
            slotB: slotB,
            mediaLayoutFingerprint: fingerprint,
            writePolicy: .deferredActivation(
                firstCommitBlock: 6,
                lastCommitBlock: 0
            )
        )!
    }

    private static func initialRecord() -> BootControlRecord {
        BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 1,
            digest: oldDigest,
            slotBlockCount: 8,
            mediaLayoutFingerprint: fingerprint
        )!
    }

    private static func descriptor() -> BootReleaseDescriptor {
        BootReleaseDescriptor(
            generation: 2,
            digest: newDigest,
            blockCount: 8,
            trialToken: 99
        )!
    }

    private static func trialPendingRecord() -> BootControlRecord {
        var record = take(initialRecord().beginCandidateWrite(
            to: .b,
            generation: 2,
            digest: newDigest,
            blockCount: 8,
            trialToken: 99
        ))
        record = take(record.recordCandidateProgress(nextBlock: 8))
        return take(record.sealCandidate())
    }

    private static func selectorCommitPendingRecord() -> BootControlRecord {
        var record = take(trialPendingRecord().observeBoot(
            slot: .b,
            wasTryBoot: true
        ))
        record = take(record.confirmCandidateHealth(
            slot: .b,
            generation: 2,
            digest: newDigest,
            trialToken: 99
        ))
        return record
    }

    private static func normal(_ slot: BootSlot) -> PlatformBootObservation {
        PlatformBootObservation(
            slot: slot,
            wasTryBoot: false,
            trialCapability: .oneShotAlternateSlot
        )
    }

    private static func trial(_ slot: BootSlot) -> PlatformBootObservation {
        PlatformBootObservation(
            slot: slot,
            wasTryBoot: true,
            trialCapability: .oneShotAlternateSlot
        )
    }

    private static func take(
        _ result: BootControlTransitionResult
    ) -> BootControlRecord {
        guard case .record(let record) = result else {
            fail("fixture transition was rejected")
        }
        return record
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() { fatalError(message) }
}

private func fail(_ message: String) -> Never {
    fatalError(message)
}
