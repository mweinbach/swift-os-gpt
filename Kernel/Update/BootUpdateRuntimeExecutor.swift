/// Result of opening the already-seeded boot-control journal while holding the
/// platform's exclusive media lease. The runtime executor intentionally does
/// not know where the journal lives; a board adapter may use a partition view,
/// while tests and future machines can provide another durable store.
enum BootUpdateRuntimeJournalLoadResult: Equatable {
    case record(BootControlRecord)
    case unavailable
}

enum BootUpdateRuntimeVerificationKind: Equatable {
    case candidate(BootSlot)
    case mirrorSource(BootSlot)
    case mirror(BootSlot)
    case recoverySelector(BootSlot)
}

enum BootUpdateRuntimeRecoverySelectorRepairResult: Equatable {
    case inProgress
    case repaired
    case failed
}

/// Effect boundary for a platform selector commit. A validation rejection is
/// safe only when the port proves that no selector write was attempted. Once a
/// write may have begun, loss of synchronization or readback is durability
/// ambiguity and must remain distinct through board reset policy.
enum BootUpdateRuntimeSelectorCommitResult: Equatable {
    case committed
    case rejectedBeforeWrite
    case durabilityUncertain
}

/// Full-slot verification is cooperative. A port may hash a bounded number of
/// blocks and return `inProgress`, but it may report `verified` only after an
/// independent read of the complete destination has produced this exact
/// release identity.
enum BootUpdateRuntimeCandidateVerificationResult: Equatable {
    case inProgress
    case verified(BootReleaseDescriptor)
    case failed
}

enum BootUpdateRuntimeMirrorVerificationResult: Equatable {
    case inProgress
    case verified(BootPeerMirrorVerificationEvidence)
    case failed
}

/// Confirmed-source hashing is cooperative and must finish before the first
/// peer write in this boot. A reconstructed port has no in-memory proof and
/// therefore returns `inProgress` while it revalidates a resumed mirror.
enum BootUpdateRuntimePeerMirrorResult: Equatable {
    case inProgress
    case mirrored
    case failed
}

/// One serialization boundary for every persistent A/B media operation.
///
/// A physical-board implementation must route this port through the same owner
/// as its filesystem and persistent-log services. Acquiring the lease must
/// prevent every aliased block-device view from issuing I/O until release. In
/// particular, implementing this protocol beside an independently active raw
/// SD alias is invalid even if each individual method is synchronous.
/// Cooperative hashes and source proofs may span lease acquisitions, so the
/// owner must also keep both boot-slot extents mutation-quiescent for the full
/// lifetime of a pending update transaction. A platform that cannot enforce
/// that ownership must invalidate progress with a mutation epoch and rehash;
/// it must never reuse a proof across an untracked slot write.
protocol BootUpdateRuntimePort {
    mutating func acquireExclusiveMediaLease() -> Bool
    mutating func releaseExclusiveMediaLease()

    mutating func loadBootControlRecord()
        -> BootUpdateRuntimeJournalLoadResult

    /// Returns true only after both redundant-journal policy and durable
    /// readback have accepted the exact next sequence.
    mutating func commitBootControlRecord(_ record: BootControlRecord) -> Bool

    /// Writes exactly the bounded action, synchronizes it, and compares the
    /// destination with the release source before returning true. Replaying an
    /// action after a later journal failure must be idempotent.
    mutating func stageCandidate(_ action: BootCandidateStageAction) -> Bool

    mutating func verifyCandidate(
        _ action: BootCandidateVerificationAction
    ) -> BootUpdateRuntimeCandidateVerificationResult

    /// Commits and reads back the platform selector while the same lease still
    /// excludes filesystem/log traffic. A journal failure after this returns
    /// is recoverable because the old selector-commit phase remains durable.
    mutating func commitSelector(
        _ action: BootSelectorCommitAction
    ) -> BootUpdateRuntimeSelectorCommitResult

    /// Recovery-environment repair is narrower than ordinary update service.
    /// The port must independently hash both complete slot ranges against the
    /// action, revalidate immutable recovery media, and synchronize/read back
    /// the repaired selector. It must not modify the journal or either slot.
    mutating func repairSelectorFromRecovery(
        _ action: BootRecoverySelectorRepairAction
    ) -> BootUpdateRuntimeRecoverySelectorRepairResult

    /// Hashes the complete confirmed source against the action identity before
    /// any peer write in this boot, then copies exactly one bounded,
    /// synchronized, read-back-verified chunk. It must preserve the action's
    /// activation-last write policy.
    mutating func mirrorPeer(
        _ action: BootPeerMirrorAction
    ) -> BootUpdateRuntimePeerMirrorResult

    mutating func verifyMirror(
        _ action: BootPeerMirrorVerificationAction
    ) -> BootUpdateRuntimeMirrorVerificationResult
}

enum BootUpdateRuntimeExecutorFailure: Equatable {
    case bootRecoveryRequired
    case recoveryEnvironmentRequired
    case durabilityRecoveryRequired
    case mediaLeaseUnavailable
    case journalUnavailable
    case journalCommitFailed
    case orchestrator(BootUpdateOrchestratorFailure)
    case candidateStageFailed
    case candidateVerificationFailed
    case selectorCommitRejectedBeforeWrite
    case selectorCommitDurabilityUncertain
    case recoverySelectorRepairFailed
    case peerMirrorFailed
    case peerMirrorVerificationFailed
}

/// A reset boundary is deliberately returned rather than performed here. The
/// board adapter must combine firmware tryboot arming and its no-return reset
/// in one platform operation. Persistent storage is already quiescent because
/// the executor releases the media lease before returning either boundary.
enum BootUpdateRuntimeExecutorResult: Equatable {
    case recovered(BootControlRecord)
    case releaseAccepted(BootControlRecord)
    case progressed(BootControlRecord)
    case idle(BootControlRecord)
    case verificationInProgress(BootUpdateRuntimeVerificationKind)
    case waitingForHealth(BootCandidateHealthAction)
    case trialResetRequired(BootTrialAuthorizationAction)
    case confirmedResetRequired(BootConfirmedSlotRebootAction)
    case recoveryResetRequired(BootConfirmedSlotRebootAction)
    case failure(BootUpdateRuntimeExecutorFailure)
}

private enum BootUpdateRuntimePersistenceResult {
    case record(BootControlRecord)
    case failure(BootUpdateRuntimeExecutorFailure)
}

/// Stateful, board-neutral execution layer around `BootUpdateOrchestrator`.
///
/// The pure orchestrator describes legal effects. This executor adds the
/// runtime ordering contract that every effect occurs under one media lease
/// and every verified effect is followed by its journal transition before the
/// lease is released. It performs at most one bounded action per service pass.
/// A fresh instance refuses release and service work until the current
/// firmware boot observation has been recovered into the journal once.
struct BootUpdateRuntimeExecutor {
    private(set) var recoveredCurrentBoot = false
    /// A failed journal barrier leaves the executor unable to distinguish an
    /// old durable record from a newly visible but not yet durable replica.
    /// No further media effect is safe in this boot. A fresh executor after a
    /// reset reopens the journal and reconciles whichever record survived.
    private(set) var durabilityRecoveryRequired = false

    /// Repairs the only selector sector from a generic recovery environment.
    /// No missing payload observation is inferred: the caller must enter this
    /// method only after platform discovery positively identifies its recovery
    /// context. The next normal boot remains responsible for journal recovery.
    mutating func recoverSelectorFromRecovery<Port: BootUpdateRuntimePort>(
        through port: inout Port,
        context: BootUpdateRuntimeBootContext,
        layout: BootSlotLayout
    ) -> BootUpdateRuntimeExecutorResult {
        guard !durabilityRecoveryRequired else {
            return .failure(.durabilityRecoveryRequired)
        }
        guard context == .recovery, !recoveredCurrentBoot else {
            return .failure(.recoveryEnvironmentRequired)
        }
        guard port.acquireExclusiveMediaLease() else {
            return .failure(.mediaLeaseUnavailable)
        }
        defer { port.releaseExclusiveMediaLease() }

        guard case .record(let record) = port.loadBootControlRecord() else {
            return .failure(.journalUnavailable)
        }
        switch BootUpdateOrchestrator.recoverySelectorRepair(
            for: record,
            layout: layout
        ) {
        case .failure(let failure):
            return .failure(.orchestrator(failure))
        case .action(let action):
            switch port.repairSelectorFromRecovery(action) {
            case .inProgress:
                return .verificationInProgress(
                    .recoverySelector(action.defaultSlot)
                )
            case .failed:
                return .failure(.recoverySelectorRepairFailed)
            case .repaired:
                return .recoveryResetRequired(BootConfirmedSlotRebootAction(
                    expectedSlot: action.candidateSlot,
                    generation: action.candidateGeneration,
                    digest: action.candidateDigest
                ))
            }
        }
    }

    mutating func recoverCurrentBoot<Port: BootUpdateRuntimePort>(
        through port: inout Port,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout
    ) -> BootUpdateRuntimeExecutorResult {
        guard !durabilityRecoveryRequired else {
            return .failure(.durabilityRecoveryRequired)
        }
        guard port.acquireExclusiveMediaLease() else {
            return .failure(.mediaLeaseUnavailable)
        }
        defer { port.releaseExclusiveMediaLease() }

        guard case .record(let record) = port.loadBootControlRecord() else {
            return .failure(.journalUnavailable)
        }
        let decision = BootUpdateOrchestrator.observeBoot(
            in: record,
            observation: observation,
            layout: layout
        )
        switch commit(decision, through: &port) {
        case .record(let recovered):
            recoveredCurrentBoot = true
            return .recovered(recovered)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    mutating func beginRelease<Port: BootUpdateRuntimePort>(
        _ descriptor: BootReleaseDescriptor,
        through port: inout Port,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout
    ) -> BootUpdateRuntimeExecutorResult {
        guard !durabilityRecoveryRequired else {
            return .failure(.durabilityRecoveryRequired)
        }
        guard recoveredCurrentBoot else {
            return .failure(.bootRecoveryRequired)
        }
        guard port.acquireExclusiveMediaLease() else {
            return .failure(.mediaLeaseUnavailable)
        }
        defer { port.releaseExclusiveMediaLease() }

        guard case .record(let record) = port.loadBootControlRecord() else {
            return .failure(.journalUnavailable)
        }
        switch commit(
            BootUpdateOrchestrator.beginRelease(
                from: record,
                observation: observation,
                layout: layout,
                descriptor: descriptor
            ),
            through: &port
        ) {
        case .record(let accepted): return .releaseAccepted(accepted)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Executes no more than one orchestrator action. `healthEvidence` must be
    /// supplied by a separately completed boot-health policy; the executor
    /// never equates reaching the service loop with candidate health.
    mutating func serviceOnce<Port: BootUpdateRuntimePort>(
        through port: inout Port,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        maximumBlockCount: UInt64,
        healthEvidence: BootCandidateHealthAction? = nil
    ) -> BootUpdateRuntimeExecutorResult {
        guard !durabilityRecoveryRequired else {
            return .failure(.durabilityRecoveryRequired)
        }
        guard recoveredCurrentBoot else {
            return .failure(.bootRecoveryRequired)
        }
        guard port.acquireExclusiveMediaLease() else {
            return .failure(.mediaLeaseUnavailable)
        }
        defer { port.releaseExclusiveMediaLease() }

        guard case .record(let record) = port.loadBootControlRecord() else {
            return .failure(.journalUnavailable)
        }
        let actionResult = BootUpdateOrchestrator.nextAction(
            for: record,
            observation: observation,
            layout: layout,
            maximumBlockCount: maximumBlockCount
        )
        guard case .action(let action) = actionResult else {
            if case .failure(let failure) = actionResult {
                return .failure(.orchestrator(failure))
            }
            return .failure(.journalUnavailable)
        }

        switch action {
        case .idle:
            return .idle(record)

        case .stageCandidate(let stage):
            guard port.stageCandidate(stage) else {
                return .failure(.candidateStageFailed)
            }
            return progressed(
                BootUpdateOrchestrator.recordVerifiedCandidateProgress(
                    in: record,
                    observation: observation,
                    layout: layout,
                    completed: stage
                ),
                through: &port
            )

        case .verifyCandidate(let verification):
            switch port.verifyCandidate(verification) {
            case .inProgress:
                return .verificationInProgress(.candidate(verification.slot))
            case .failed:
                return .failure(.candidateVerificationFailed)
            case .verified(let descriptor):
                return progressed(
                    BootUpdateOrchestrator.sealVerifiedCandidate(
                        in: record,
                        observation: observation,
                        layout: layout,
                        slot: verification.slot,
                        verifiedDescriptor: descriptor
                    ),
                    through: &port
                )
            }

        case .authorizeTrial(let authorization):
            return .trialResetRequired(authorization)

        case .awaitCandidateHealth(let expected):
            guard let healthEvidence else {
                return .waitingForHealth(expected)
            }
            return progressed(
                BootUpdateOrchestrator.confirmCandidateHealth(
                    in: record,
                    observation: observation,
                    layout: layout,
                    evidence: healthEvidence
                ),
                through: &port
            )

        case .commitSelector(let selector):
            switch port.commitSelector(selector) {
            case .rejectedBeforeWrite:
                return .failure(.selectorCommitRejectedBeforeWrite)
            case .durabilityUncertain:
                return .failure(.selectorCommitDurabilityUncertain)
            case .committed:
                break
            }
            return progressed(
                BootUpdateOrchestrator.recordSelectorCommitted(
                    in: record,
                    observation: observation,
                    layout: layout,
                    defaultSlot: selector.defaultSlot
                ),
                through: &port
            )

        case .rebootToConfirmed(let reboot):
            return .confirmedResetRequired(reboot)

        case .mirrorPeer(let mirror):
            switch port.mirrorPeer(mirror) {
            case .inProgress:
                return .verificationInProgress(
                    .mirrorSource(mirror.sourceSlot)
                )
            case .failed:
                return .failure(.peerMirrorFailed)
            case .mirrored:
                break
            }
            return progressed(
                BootUpdateOrchestrator.recordVerifiedMirrorProgress(
                    in: record,
                    observation: observation,
                    layout: layout,
                    completed: mirror
                ),
                through: &port
            )

        case .verifyMirror(let verification):
            switch port.verifyMirror(verification) {
            case .inProgress:
                return .verificationInProgress(
                    .mirror(verification.destinationSlot)
                )
            case .failed:
                return .failure(.peerMirrorVerificationFailed)
            case .verified(let evidence):
                return progressed(
                    BootUpdateOrchestrator.sealVerifiedMirror(
                        in: record,
                        observation: observation,
                        layout: layout,
                        evidence: evidence
                    ),
                    through: &port
                )
            }
        }
    }

    private mutating func progressed<Port: BootUpdateRuntimePort>(
        _ decision: BootUpdateTransitionDecision,
        through port: inout Port
    ) -> BootUpdateRuntimeExecutorResult {
        switch commit(decision, through: &port) {
        case .record(let record): return .progressed(record)
        case .failure(let failure): return .failure(failure)
        }
    }

    private mutating func commit<Port: BootUpdateRuntimePort>(
        _ decision: BootUpdateTransitionDecision,
        through port: inout Port
    ) -> BootUpdateRuntimePersistenceResult {
        switch decision {
        case .unchanged(let record):
            return .record(record)
        case .persist(let record):
            guard port.commitBootControlRecord(record) else {
                durabilityRecoveryRequired = true
                return .failure(.journalCommitFailed)
            }
            return .record(record)
        case .failure(let failure):
            return .failure(.orchestrator(failure))
        }
    }
}
