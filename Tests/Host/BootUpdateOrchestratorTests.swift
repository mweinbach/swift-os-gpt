#if BOOT_UPDATE_ORCHESTRATOR_STANDALONE_TEST
struct PlatformBootObservation: Equatable {
    let slot: BootSlot
    let wasTryBoot: Bool
    let trialCapability: PlatformTrialBootCapability
}
#endif

@main
struct BootUpdateOrchestratorTests {
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
        stagesOnlyTheInactiveSlotBeforeTrialAuthorization()
        recordsRollbackAndRejectsUnprovenRuntimeState()
        confirmsHealthThenDurablyMirrorsThePeer()
        recoversSelectorCommitAndRejectsInvalidTransitions()
        journalsAtomicConfirmationAndMirrorIntent()
        mapsPiFATBootabilityAfterPayloadProgress()
        print("boot update orchestrator host tests: 6 groups passed")
    }

    private static func stagesOnlyTheInactiveSlotBeforeTrialAuthorization() {
        let layout = makeLayout()
        let descriptor = makeDescriptor()
        var record = initialRecord()
        record = takePersist(BootUpdateOrchestrator.beginRelease(
            from: record,
            observation: normal(.a),
            layout: layout,
            descriptor: descriptor
        ))
        expect(record.phase == .writingCandidate, "candidate write phase")
        expect(record.candidateSlot == .b, "active slot selected for overwrite")

        guard case .stageCandidate(let first) = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )
        ) else { fail("missing first candidate stage action") }
        expect(first.slot == .b, "first stage slot")
        expect(first.destination == layout.slotB, "first stage range")
        expect(first.nextBlock == 0 && first.blockCount == 2,
               "first stage bounds")

        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: first
            )
        )
        guard case .stageCandidate(let second) = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )
        ) else { fail("missing second candidate stage action") }
        expect(second.nextBlock == 2 && second.blockCount == 2,
               "second stage bounds")

        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: second
            )
        )
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )) == .verifyCandidate(BootCandidateVerificationAction(
                slot: .b,
                descriptor: descriptor
            )),
            "complete candidate did not require full verification"
        )

        let wrongDescriptor = BootReleaseDescriptor(
            generation: 3,
            digest: newDigest,
            blockCount: 4,
            trialToken: 99
        )!
        expect(
            BootUpdateOrchestrator.sealVerifiedCandidate(
                in: record,
                observation: normal(.a),
                layout: layout,
                slot: .b,
                verifiedDescriptor: wrongDescriptor
            ) == .failure(.descriptorMismatch),
            "mismatched full-slot identity was sealed"
        )
        record = takePersist(BootUpdateOrchestrator.sealVerifiedCandidate(
            in: record,
            observation: normal(.a),
            layout: layout,
            slot: .b,
            verifiedDescriptor: descriptor
        ))
        expect(record.phase == .trialPending, "candidate was not trial pending")
        expect(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.a, trialCapability: .unavailable),
                layout: layout,
                maximumBlockCount: 2
            ) == .failure(.trialBootCapabilityUnavailable),
            "missing firmware capability evidence authorized a trial"
        )
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )) == .authorizeTrial(BootTrialAuthorizationAction(
                confirmedSlot: .a,
                candidateSlot: .b,
                generation: 2,
                digest: newDigest,
                trialToken: 99
            )),
            "trial was not authorized after durable seal"
        )
    }

    private static func recordsRollbackAndRejectsUnprovenRuntimeState() {
        let layout = makeLayout()
        let pending = trialPendingRecord()
        let rollback = takePersist(BootUpdateOrchestrator.observeBoot(
            in: pending,
            observation: normal(.a),
            layout: layout
        ))
        expect(rollback.phase == .stable, "rollback phase")
        expect(rollback.confirmedSlot == .a, "rollback changed default")
        expect(rollback.failedTrialCount == 1, "rollback counter")

        expect(
            BootUpdateOrchestrator.observeBoot(
                in: pending,
                observation: nil,
                layout: layout
            ) == .failure(.missingBootObservation),
            "missing firmware identity authorized a transition"
        )
        expect(
            BootUpdateOrchestrator.beginRelease(
                from: initialRecord(),
                observation: trial(.a),
                layout: layout,
                descriptor: makeDescriptor()
            ) == .failure(.unexpectedBoot(slot: .a, wasTryBoot: true)),
            "release began from a provisional boot"
        )

        let wrongLayout = BootSlotLayout(
            slotA: layout.slotA,
            slotB: layout.slotB,
            mediaLayoutFingerprint: fingerprint + 1
        )!
        expect(
            BootUpdateOrchestrator.nextAction(
                for: pending,
                observation: normal(.a),
                layout: wrongLayout,
                maximumBlockCount: 2
            ) == .failure(.mediaLayoutMismatch),
            "foreign media layout authorized a trial"
        )
        expect(
            BootUpdateOrchestrator.observeBoot(
                in: pending,
                observation: normal(.b),
                layout: layout
            ) == .failure(.unexpectedBoot(slot: .b, wasTryBoot: false)),
            "non-try candidate boot bypassed trial policy"
        )
    }

    private static func confirmsHealthThenDurablyMirrorsThePeer() {
        let layout = makeLayout()
        var record = trialPendingRecord()
        record = takePersist(BootUpdateOrchestrator.observeBoot(
            in: record,
            observation: trial(.b),
            layout: layout
        ))
        expect(record.phase == .trialBooting, "trial boot phase")
        expect(
            BootUpdateOrchestrator.observeBoot(
                in: record,
                observation: trial(.b),
                layout: layout
            ) == .unchanged(record),
            "replayed trial observation changed the journal"
        )

        let health = BootCandidateHealthAction(
            slot: .b,
            generation: 2,
            digest: newDigest,
            trialToken: 99
        )
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: trial(.b),
                layout: layout,
                maximumBlockCount: 2
            )) == .awaitCandidateHealth(health),
            "trial did not wait for exact health identity"
        )
        expect(
            BootUpdateOrchestrator.confirmCandidateHealth(
                in: record,
                observation: trial(.b),
                layout: layout,
                evidence: BootCandidateHealthAction(
                    slot: .b,
                    generation: 2,
                    digest: newDigest,
                    trialToken: 100
                )
            ) == .failure(.descriptorMismatch),
            "wrong health token confirmed the candidate"
        )
        record = takePersist(BootUpdateOrchestrator.confirmCandidateHealth(
            in: record,
            observation: trial(.b),
            layout: layout,
            evidence: health
        ))
        expect(record.phase == .selectorCommitPending, "selector commit phase")
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: trial(.b),
                layout: layout,
                maximumBlockCount: 2
            )) == .commitSelector(BootSelectorCommitAction(defaultSlot: .b)),
            "healthy trial did not authorize selector commit"
        )

        let selectorSequence = record.sequence
        record = takePersist(BootUpdateOrchestrator.recordSelectorCommitted(
            in: record,
            observation: trial(.b),
            layout: layout,
            defaultSlot: .b
        ))
        expect(record.sequence == selectorSequence + 1,
               "confirmation and mirror were not one journal transition")
        expect(record.phase == .replicatingPeer, "mirror was not durable")
        expect(record.confirmedSlot == .b && record.candidateSlot == .a,
               "mirror direction")

        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: trial(.b),
                layout: layout,
                maximumBlockCount: 2
            )) == .rebootToConfirmed(BootConfirmedSlotRebootAction(
                expectedSlot: .b,
                generation: 2,
                digest: newDigest
            )),
            "provisional runtime was allowed to overwrite the fallback slot"
        )
        record = takePersist(BootUpdateOrchestrator.observeBoot(
            in: record,
            observation: normal(.b),
            layout: layout
        ))

        guard case .mirrorPeer(let first) = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 2
            )
        ) else { fail("missing mirror action") }
        expect(first.sourceSlot == .b && first.destinationSlot == .a,
               "mirror slot identities")
        expect(first.plan.source == layout.slotB,
               "mirror source range")
        expect(first.plan.destination == layout.slotA,
               "mirror destination range")

        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedMirrorProgress(
                in: record,
                observation: normal(.b),
                layout: layout,
                completed: first
            )
        )
        let second = mirrorAction(
            for: record,
            observation: normal(.b),
            layout: layout,
            maximumBlockCount: 2
        )
        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedMirrorProgress(
                in: record,
                observation: normal(.b),
                layout: layout,
                completed: second
            )
        )
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 2
            )) == .verifyMirror(BootPeerMirrorVerificationAction(
                sourceSlot: .b,
                destinationSlot: .a,
                expectedGeneration: 2,
                expectedDigest: newDigest,
                blockCount: 4
            )),
            "completed mirror did not require full verification"
        )
        expect(
            BootUpdateOrchestrator.sealVerifiedMirror(
                in: record,
                observation: normal(.b),
                layout: layout,
                evidence: BootPeerMirrorVerificationEvidence(
                    destinationSlot: .a,
                    generation: 2,
                    digest: oldDigest,
                    blockCount: 4
                )
            ) == .failure(.descriptorMismatch),
            "mirror sealed with the wrong destination digest"
        )
        record = takePersist(BootUpdateOrchestrator.sealVerifiedMirror(
            in: record,
            observation: normal(.b),
            layout: layout,
            evidence: BootPeerMirrorVerificationEvidence(
                destinationSlot: .a,
                generation: 2,
                digest: newDigest,
                blockCount: 4
            )
        ))
        expect(record.phase == .stable, "mirror did not converge")
        expect(record.confirmedSlot == .b, "mirror moved confirmed default")
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: record,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 2
            )) == .idle,
            "healthy current runtime did not settle"
        )
    }

    private static func recoversSelectorCommitAndRejectsInvalidTransitions() {
        let layout = makeLayout()
        let pending = selectorCommitPendingRecord()
        let recovered = takePersist(BootUpdateOrchestrator.observeBoot(
            in: pending,
            observation: normal(.b),
            layout: layout
        ))
        expect(recovered.phase == .replicatingPeer,
               "normal candidate boot forgot peer mirror")
        expect(recovered.confirmedSlot == .b && recovered.candidateSlot == .a,
               "recovered mirror direction")

        let retry = takePersist(BootUpdateOrchestrator.observeBoot(
            in: pending,
            observation: normal(.a),
            layout: layout
        ))
        expect(retry.phase == .selectorCommitPending,
               "old default boot discarded proven candidate")
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: retry,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )) == .commitSelector(BootSelectorCommitAction(defaultSlot: .b)),
            "selector commit was not retryable"
        )
        let committedFromOld = takePersist(
            BootUpdateOrchestrator.recordSelectorCommitted(
                in: retry,
                observation: normal(.a),
                layout: layout,
                defaultSlot: .b
            )
        )
        expect(
            takeAction(BootUpdateOrchestrator.nextAction(
                for: committedFromOld,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 2
            )) == .rebootToConfirmed(BootConfirmedSlotRebootAction(
                expectedSlot: .b,
                generation: 2,
                digest: newDigest
            )),
            "old-slot selector commit did not require a normal reboot"
        )
        expect(
            BootUpdateOrchestrator.observeBoot(
                in: committedFromOld,
                observation: normal(.a),
                layout: layout
            ) == .unchanged(committedFromOld),
            "pre-reset old-slot runtime corrupted mirror state"
        )
        let afterConfirmedReboot = takePersist(
            BootUpdateOrchestrator.observeBoot(
                in: committedFromOld,
                observation: normal(.b),
                layout: layout
            )
        )
        guard case .mirrorPeer = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: afterConfirmedReboot,
                observation: normal(.b),
                layout: layout,
                maximumBlockCount: 2
            )
        ) else { fail("confirmed reboot did not unlock mirror") }

        expect(
            BootUpdateOrchestrator.recordSelectorCommitted(
                in: pending,
                observation: trial(.b),
                layout: layout,
                defaultSlot: .a
            ) == .failure(.wrongTargetSlot),
            "selector readback for the wrong slot was accepted"
        )
        expect(
            BootUpdateOrchestrator.nextAction(
                for: trialPendingRecord(),
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 0
            ) == .action(.authorizeTrial(BootTrialAuthorizationAction(
                confirmedSlot: .a,
                candidateSlot: .b,
                generation: 2,
                digest: newDigest,
                trialToken: 99
            ))),
            "non-copy phase incorrectly depended on chunk limit"
        )

        let writing = writingRecord()
        expect(
            BootUpdateOrchestrator.nextAction(
                for: writing,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 0
            ) == .failure(.invalidOperationLimit),
            "zero-sized staging operation was authorized"
        )
        expect(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: writing,
                observation: normal(.a),
                layout: layout,
                completed: BootCandidateStageAction(
                    slot: .a,
                    destination: layout.slotA,
                    generation: 2,
                    digest: newDigest,
                    trialToken: 99,
                    writePolicy: .direct,
                    nextBlock: 0,
                    blockCount: 1
                )
            ) == .failure(.invalidVerifiedProgress),
            "confirmed slot was writable as candidate"
        )

        let exhausted = BootControlRecord(
            sequence: UInt64.max,
            phase: pending.phase,
            confirmedSlot: pending.confirmedSlot,
            confirmedGeneration: pending.confirmedGeneration,
            confirmedDigest: pending.confirmedDigest,
            candidateSlot: pending.candidateSlot,
            candidateGeneration: pending.candidateGeneration,
            candidateDigest: pending.candidateDigest,
            updateKind: pending.updateKind,
            trialToken: pending.trialToken,
            slotBlockCount: pending.slotBlockCount,
            nextCandidateBlock: pending.nextCandidateBlock,
            failedTrialCount: pending.failedTrialCount,
            mediaLayoutFingerprint: pending.mediaLayoutFingerprint
        )
        expect(
            BootUpdateOrchestrator.recordSelectorCommitted(
                in: exhausted,
                observation: trial(.b),
                layout: layout,
                defaultSlot: .b
            ) == .failure(.sequenceExhausted),
            "sequence exhaustion wrapped the durable journal"
        )

        expect(
            BootSlotLayout(
                slotA: layout.slotA,
                slotB: layout.slotA,
                mediaLayoutFingerprint: fingerprint
            ) == nil,
            "overlapping slots formed a layout"
        )
    }

    private static func journalsAtomicConfirmationAndMirrorIntent() {
        var device = MemoryBlockDevice(blockCount: 32)
        withScratch(byteCount: 512) { scratch in
            guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                &device,
                kernelLogBlockCount: 2,
                scratch: scratch
            ) else { fail("journal fixture format") }

            let layout = makeLayout()
            var record = initialRecord()
            commit(record, to: &device, scratch: scratch)
            record = takePersist(BootUpdateOrchestrator.beginRelease(
                from: record,
                observation: normal(.a),
                layout: layout,
                descriptor: makeDescriptor()
            ))
            commit(record, to: &device, scratch: scratch)
            let stage = candidateStageAction(
                for: record,
                observation: normal(.a),
                layout: layout,
                maximumBlockCount: 4
            )
            record = takePersist(
                BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                    in: record,
                    observation: normal(.a),
                    layout: layout,
                    completed: stage
                )
            )
            commit(record, to: &device, scratch: scratch)
            record = takePersist(
                BootUpdateOrchestrator.sealVerifiedCandidate(
                    in: record,
                    observation: normal(.a),
                    layout: layout,
                    slot: .b,
                    verifiedDescriptor: makeDescriptor()
                )
            )
            commit(record, to: &device, scratch: scratch)
            record = takePersist(BootUpdateOrchestrator.observeBoot(
                in: record,
                observation: trial(.b),
                layout: layout
            ))
            commit(record, to: &device, scratch: scratch)
            record = takePersist(BootUpdateOrchestrator.confirmCandidateHealth(
                in: record,
                observation: trial(.b),
                layout: layout,
                evidence: BootCandidateHealthAction(
                    slot: .b,
                    generation: 2,
                    digest: newDigest,
                    trialToken: 99
                )
            ))
            commit(record, to: &device, scratch: scratch)
            record = takePersist(
                BootUpdateOrchestrator.recordSelectorCommitted(
                    in: record,
                    observation: trial(.b),
                    layout: layout,
                    defaultSlot: .b
                )
            )
            commit(record, to: &device, scratch: scratch)

            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(record, .twoValidReplicas),
                "atomic confirmation and mirror intent was not journal-valid"
            )
            expect(record.phase == .replicatingPeer,
                   "journal lost mirror intent")
        }
    }

    private static func mapsPiFATBootabilityAfterPayloadProgress() {
        let slotA = BlockDeviceRange(
            startBlock: 10,
            blockCount: 10,
            within: 64
        )!
        let slotB = BlockDeviceRange(
            startBlock: 30,
            blockCount: 10,
            within: 64
        )!
        let layout = RaspberryPiABUpdateLayout.make(
            deviceGeometry: BlockDeviceGeometry(
                logicalBlockByteCount: 512,
                logicalBlockCount: 64
            )!,
            slotA: slotA,
            slotB: slotB
        )!
        expect(
            RaspberryPiABUpdateLayout.make(
                deviceGeometry: BlockDeviceGeometry(
                    logicalBlockByteCount: 4_096,
                    logicalBlockCount: 64
                )!,
                slotA: slotA,
                slotB: slotB
            ) == nil,
            "Pi sector policy accepted non-512-byte logical media"
        )
        expect(
            layout.mediaLayoutFingerprint
                == RaspberryPiABUpdateLayout.mediaLayoutFingerprint,
            "Pi media fingerprint was not attached to the shared layout"
        )
        var record = BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 1,
            digest: oldDigest,
            slotBlockCount: 10,
            mediaLayoutFingerprint:
                RaspberryPiABUpdateLayout.mediaLayoutFingerprint
        )!
        let descriptor = BootReleaseDescriptor(
            generation: 2,
            digest: newDigest,
            blockCount: 10,
            trialToken: 99
        )!
        record = takePersist(BootUpdateOrchestrator.beginRelease(
            from: record,
            observation: normal(.a),
            layout: layout,
            descriptor: descriptor
        ))
        let payload = candidateStageAction(
            for: record,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 10
        )
        expect(
            payload.writePolicy == RaspberryPiABUpdateLayout.writePolicy
                && payload.nextBlock == 0 && payload.blockCount == 8,
            "Pi payload action crossed into FAT activation blocks"
        )
        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: payload
            )
        )
        let backupBoot = candidateStageAction(
            for: record,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 10
        )
        expect(
            backupBoot.nextBlock == 8 && backupBoot.blockCount == 1
                && backupBoot.writePolicy.relativeBlock(
                    atProgress: 8,
                    blockCount: 10
                ) == 6,
            "Pi backup boot sector was not a separate penultimate commit"
        )
        expect(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: BootCandidateStageAction(
                    slot: backupBoot.slot,
                    destination: backupBoot.destination,
                    generation: backupBoot.generation,
                    digest: backupBoot.digest,
                    trialToken: backupBoot.trialToken,
                    writePolicy: backupBoot.writePolicy,
                    nextBlock: backupBoot.nextBlock,
                    blockCount: 2
                )
            ) == .failure(.invalidVerifiedProgress),
            "one progress report skipped both Pi activation commits"
        )
        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: backupBoot
            )
        )
        let primaryBoot = candidateStageAction(
            for: record,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 10
        )
        expect(
            primaryBoot.nextBlock == 9 && primaryBoot.blockCount == 1
                && primaryBoot.writePolicy.relativeBlock(
                    atProgress: 9,
                    blockCount: 10
                ) == 0,
            "Pi primary boot sector was not the final bootability commit"
        )
    }

    private static func initialRecord() -> BootControlRecord {
        BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 1,
            digest: oldDigest,
            slotBlockCount: 4,
            mediaLayoutFingerprint: fingerprint
        )!
    }

    private static func writingRecord() -> BootControlRecord {
        takePersist(BootUpdateOrchestrator.beginRelease(
            from: initialRecord(),
            observation: normal(.a),
            layout: makeLayout(),
            descriptor: makeDescriptor()
        ))
    }

    private static func trialPendingRecord() -> BootControlRecord {
        var record = writingRecord()
        let layout = makeLayout()
        let stage = candidateStageAction(
            for: record,
            observation: normal(.a),
            layout: layout,
            maximumBlockCount: 4
        )
        record = takePersist(
            BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                in: record,
                observation: normal(.a),
                layout: layout,
                completed: stage
            )
        )
        return takePersist(BootUpdateOrchestrator.sealVerifiedCandidate(
            in: record,
            observation: normal(.a),
            layout: layout,
            slot: .b,
            verifiedDescriptor: makeDescriptor()
        ))
    }

    private static func selectorCommitPendingRecord() -> BootControlRecord {
        var record = takePersist(BootUpdateOrchestrator.observeBoot(
            in: trialPendingRecord(),
            observation: trial(.b),
            layout: makeLayout()
        ))
        record = takePersist(BootUpdateOrchestrator.confirmCandidateHealth(
            in: record,
            observation: trial(.b),
            layout: makeLayout(),
            evidence: BootCandidateHealthAction(
                slot: .b,
                generation: 2,
                digest: newDigest,
                trialToken: 99
            )
        ))
        return record
    }

    private static func makeDescriptor() -> BootReleaseDescriptor {
        BootReleaseDescriptor(
            generation: 2,
            digest: newDigest,
            blockCount: 4,
            trialToken: 99
        )!
    }

    private static func makeLayout() -> BootSlotLayout {
        let slotA = BlockDeviceRange(
            startBlock: 10,
            blockCount: 4,
            within: 64
        )!
        let slotB = BlockDeviceRange(
            startBlock: 20,
            blockCount: 4,
            within: 64
        )!
        return BootSlotLayout(
            slotA: slotA,
            slotB: slotB,
            mediaLayoutFingerprint: fingerprint
        )!
    }

    private static func normal(
        _ slot: BootSlot,
        trialCapability: PlatformTrialBootCapability = .oneShotAlternateSlot
    ) -> PlatformBootObservation {
        PlatformBootObservation(
            slot: slot,
            wasTryBoot: false,
            trialCapability: trialCapability
        )
    }

    private static func trial(_ slot: BootSlot) -> PlatformBootObservation {
        PlatformBootObservation(
            slot: slot,
            wasTryBoot: true,
            trialCapability: .oneShotAlternateSlot
        )
    }

    private static func takePersist(
        _ decision: BootUpdateTransitionDecision
    ) -> BootControlRecord {
        guard case .persist(let record) = decision else {
            fail("expected journal transition")
        }
        return record
    }

    private static func takeAction(
        _ result: BootUpdateActionResult
    ) -> BootUpdateOrchestratorAction {
        guard case .action(let action) = result else {
            fail("expected authorized action")
        }
        return action
    }

    private static func candidateStageAction(
        for record: BootControlRecord,
        observation: PlatformBootObservation,
        layout: BootSlotLayout,
        maximumBlockCount: UInt64
    ) -> BootCandidateStageAction {
        guard case .stageCandidate(let action) = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: observation,
                layout: layout,
                maximumBlockCount: maximumBlockCount
            )
        ) else { fail("expected candidate stage action") }
        return action
    }

    private static func mirrorAction(
        for record: BootControlRecord,
        observation: PlatformBootObservation,
        layout: BootSlotLayout,
        maximumBlockCount: UInt64
    ) -> BootPeerMirrorAction {
        guard case .mirrorPeer(let action) = takeAction(
            BootUpdateOrchestrator.nextAction(
                for: record,
                observation: observation,
                layout: layout,
                maximumBlockCount: maximumBlockCount
            )
        ) else { fail("expected peer mirror action") }
        return action
    }

    private static func commit(
        _ record: BootControlRecord,
        to device: inout MemoryBlockDevice,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        guard case .committed(_, let sequence) = BootControlJournal.commit(
            record,
            to: &device,
            scratch: scratch
        ), sequence == record.sequence else {
            fail("journal commit")
        }
    }

    private static func withScratch(
        byteCount: Int,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 8
        )
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(
            start: pointer,
            count: byteCount
        ))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
