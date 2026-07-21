/// Board-neutral placement of the two complete boot payloads on one block
/// device. Board code discovers these ranges; update policy only reasons about
/// logical A/B identities and never embeds partition numbers or MMIO details.
struct BootSlotLayout: Equatable {
    let slotA: BlockDeviceRange
    let slotB: BlockDeviceRange
    let mediaLayoutFingerprint: UInt64
    let writePolicy: BootSlotWritePolicy
    let metadataPolicy: BootSlotMetadataPolicy

    init?(
        slotA: BlockDeviceRange,
        slotB: BlockDeviceRange,
        mediaLayoutFingerprint: UInt64,
        writePolicy: BootSlotWritePolicy = .direct,
        metadataPolicy: BootSlotMetadataPolicy = .none
    ) {
        guard slotA.blockCount == slotB.blockCount,
              !slotA.overlaps(slotB),
              mediaLayoutFingerprint != 0,
              writePolicy.isValid(blockCount: slotA.blockCount),
              metadataPolicy.isValid(blockCount: slotA.blockCount)
        else { return nil }
        self.slotA = slotA
        self.slotB = slotB
        self.mediaLayoutFingerprint = mediaLayoutFingerprint
        self.writePolicy = writePolicy
        self.metadataPolicy = metadataPolicy
    }

    var slotBlockCount: UInt64 { slotA.blockCount }

    func range(for slot: BootSlot) -> BlockDeviceRange {
        slot == .a ? slotA : slotB
    }

    func copyPlan(
        from source: BootSlot,
        to destination: BootSlot
    ) -> VerifiedSlotCopyPlan? {
        guard source != destination else { return nil }
        return VerifiedSlotCopyPlan(
            source: range(for: source),
            destination: range(for: destination),
            writePolicy: writePolicy,
            metadataPolicy: metadataPolicy
        )
    }
}

/// Location-neutral identity carried by a complete, integrity-validated
/// release capsule. The transport owns stream verification and applies the
/// layout's metadata policy before hashing or writing location-specific bytes;
/// a future signature policy remains a separate trust gate. This immutable
/// identity is journaled before any inactive-slot write begins.
struct BootReleaseDescriptor: Equatable {
    let generation: UInt64
    let digest: BootImageDigest
    let blockCount: UInt64
    let trialToken: UInt64

    init?(
        generation: UInt64,
        digest: BootImageDigest,
        blockCount: UInt64,
        trialToken: UInt64
    ) {
        guard generation != 0,
              digest != .zero,
              blockCount != 0,
              trialToken != 0
        else { return nil }
        self.generation = generation
        self.digest = digest
        self.blockCount = blockCount
        self.trialToken = trialToken
    }
}

struct BootCandidateStageAction: Equatable {
    let slot: BootSlot
    let destination: BlockDeviceRange
    let generation: UInt64
    let digest: BootImageDigest
    let trialToken: UInt64
    let writePolicy: BootSlotWritePolicy
    let metadataPolicy: BootSlotMetadataPolicy
    let nextBlock: UInt64
    let blockCount: UInt64
}

struct BootCandidateVerificationAction: Equatable {
    let slot: BootSlot
    let descriptor: BootReleaseDescriptor
}

struct BootTrialAuthorizationAction: Equatable {
    let confirmedSlot: BootSlot
    let candidateSlot: BootSlot
    let generation: UInt64
    let digest: BootImageDigest
    let trialToken: UInt64
}

struct BootCandidateHealthAction: Equatable {
    let slot: BootSlot
    let generation: UInt64
    let digest: BootImageDigest
    let trialToken: UInt64
}

struct BootSelectorCommitAction: Equatable {
    let defaultSlot: BootSlot
}

/// Narrow recovery-environment authority for repairing a torn selector after
/// candidate health was already durably recorded. A platform port must hash
/// both complete slots under the layout's content-identity policy and
/// revalidate immutable recovery media before it writes the selector. The
/// journal is deliberately
/// left in `selectorCommitPending`; a subsequent normal payload boot is the
/// evidence that confirms the candidate and starts peer convergence.
struct BootRecoverySelectorRepairAction: Equatable {
    let defaultSlot: BootSlot
    let confirmedSlot: BootSlot
    let confirmedRange: BlockDeviceRange
    let confirmedGeneration: UInt64
    let confirmedDigest: BootImageDigest
    let candidateSlot: BootSlot
    let candidateRange: BlockDeviceRange
    let candidateGeneration: UInt64
    let candidateDigest: BootImageDigest
    let trialToken: UInt64
    let mediaLayoutFingerprint: UInt64
}

/// A normal reset required after selector confirmation occurred while the CPU
/// was still executing the former default slot. No peer write is authorized
/// until firmware proves that this newly confirmed source actually booted.
struct BootConfirmedSlotRebootAction: Equatable {
    let expectedSlot: BootSlot
    let generation: UInt64
    let digest: BootImageDigest
}

struct BootPeerMirrorAction: Equatable {
    let sourceSlot: BootSlot
    let destinationSlot: BootSlot
    let plan: VerifiedSlotCopyPlan
    let nextBlock: UInt64
    let blockCount: UInt64
}

struct BootPeerMirrorVerificationAction: Equatable {
    let sourceSlot: BootSlot
    let destinationSlot: BootSlot
    let expectedGeneration: UInt64
    let expectedDigest: BootImageDigest
    let blockCount: UInt64
}

/// Identity measured from a complete destination-slot read after every mirror
/// chunk was synchronized and compared. Cursor completion alone is never
/// sufficient to declare the peer bootable.
struct BootPeerMirrorVerificationEvidence: Equatable {
    let destinationSlot: BootSlot
    let generation: UInt64
    let digest: BootImageDigest
    let blockCount: UInt64
}

enum BootUpdateOrchestratorAction: Equatable {
    case idle
    case stageCandidate(BootCandidateStageAction)
    case verifyCandidate(BootCandidateVerificationAction)
    case authorizeTrial(BootTrialAuthorizationAction)
    case awaitCandidateHealth(BootCandidateHealthAction)
    case commitSelector(BootSelectorCommitAction)
    case rebootToConfirmed(BootConfirmedSlotRebootAction)
    case mirrorPeer(BootPeerMirrorAction)
    case verifyMirror(BootPeerMirrorVerificationAction)
}

enum BootUpdateOrchestratorFailure: Equatable {
    case missingBootObservation
    case trialBootCapabilityUnavailable
    case mediaLayoutMismatch
    case slotBlockCountMismatch
    case invalidOperationLimit
    case unexpectedBoot(slot: BootSlot, wasTryBoot: Bool)
    case wrongTargetSlot
    case descriptorMismatch
    case invalidVerifiedProgress
    case missingCandidate
    case sequenceExhausted
    case recoveryNotAuthorized
    case transitionRejected(BootControlTransitionRejection)
}

enum BootUpdateActionResult: Equatable {
    case action(BootUpdateOrchestratorAction)
    case failure(BootUpdateOrchestratorFailure)
}

enum BootRecoverySelectorRepairResult: Equatable {
    case action(BootRecoverySelectorRepairAction)
    case failure(BootUpdateOrchestratorFailure)
}

/// A transition is not authoritative until its record has been committed to
/// the redundant BootControlJournal. Returning `.persist` rather than running
/// side effects here makes that ordering explicit to every board integration.
enum BootUpdateTransitionDecision: Equatable {
    case unchanged(BootControlRecord)
    case persist(BootControlRecord)
    case failure(BootUpdateOrchestratorFailure)
}

/// Pure A/B update policy shared by every board.
///
/// Platform integrations execute the returned actions and report only durable,
/// read-back-verified progress. In particular, a board may arm its own one-shot
/// boot mechanism or commit its own selector, but neither operation is exposed
/// until the preceding journal state proves it is safe.
enum BootUpdateOrchestrator {
    static let maximumBlocksPerOperation =
        VerifiedSlotCopier.maximumBlocksPerChunk

    /// Authorizes no payload or journal write. This is the sole operation a
    /// non-payload recovery environment may request, and only the durable
    /// post-health selector phase can produce it.
    static func recoverySelectorRepair(
        for record: BootControlRecord,
        layout: BootSlotLayout
    ) -> BootRecoverySelectorRepairResult {
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard record.phase == .selectorCommitPending,
              let candidateSlot = record.candidateSlot,
              record.updateKind == .release,
              record.nextCandidateBlock == record.slotBlockCount,
              record.trialToken != 0
        else { return .failure(.recoveryNotAuthorized) }
        return .action(BootRecoverySelectorRepairAction(
            defaultSlot: candidateSlot,
            confirmedSlot: record.confirmedSlot,
            confirmedRange: layout.range(for: record.confirmedSlot),
            confirmedGeneration: record.confirmedGeneration,
            confirmedDigest: record.confirmedDigest,
            candidateSlot: candidateSlot,
            candidateRange: layout.range(for: candidateSlot),
            candidateGeneration: record.candidateGeneration,
            candidateDigest: record.candidateDigest,
            trialToken: record.trialToken,
            mediaLayoutFingerprint: record.mediaLayoutFingerprint
        ))
    }

    static func beginRelease(
        from record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        descriptor: BootReleaseDescriptor
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard observation.slot == record.confirmedSlot,
              !observation.wasTryBoot
        else { return unexpected(observation) }
        guard descriptor.blockCount == layout.slotBlockCount else {
            return .failure(.slotBlockCountMismatch)
        }
        return transition(record.beginCandidateWrite(
            to: record.confirmedSlot.peer,
            generation: descriptor.generation,
            digest: descriptor.digest,
            blockCount: descriptor.blockCount,
            trialToken: descriptor.trialToken
        ))
    }

    /// Returns the only side effect currently authorized by the durable record.
    /// A missing or contradictory runtime boot identity disables every update
    /// write while leaving ordinary kernel boot policy untouched.
    static func nextAction(
        for record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        maximumBlockCount: UInt64
    ) -> BootUpdateActionResult {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }

        switch record.phase {
        case .stable:
            guard observation.slot == record.confirmedSlot,
                  !observation.wasTryBoot
            else {
                return actionUnexpected(observation)
            }
            return .action(.idle)

        case .writingCandidate:
            guard observation.slot == record.confirmedSlot,
                  !observation.wasTryBoot,
                  let candidateSlot = record.candidateSlot
            else { return actionUnexpected(observation) }
            if record.nextCandidateBlock == record.slotBlockCount {
                guard let descriptor = releaseDescriptor(from: record) else {
                    return .failure(.missingCandidate)
                }
                return .action(.verifyCandidate(
                    BootCandidateVerificationAction(
                        slot: candidateSlot,
                        descriptor: descriptor
                    )
                ))
            }
            guard validOperationLimit(maximumBlockCount) else {
                return .failure(.invalidOperationLimit)
            }
            guard let count = layout.writePolicy.boundedOperationCount(
                      atProgress: record.nextCandidateBlock,
                      blockCount: record.slotBlockCount,
                      requested: maximumBlockCount
                  )
            else { return .failure(.invalidOperationLimit) }
            return .action(.stageCandidate(BootCandidateStageAction(
                slot: candidateSlot,
                destination: layout.range(for: candidateSlot),
                generation: record.candidateGeneration,
                digest: record.candidateDigest,
                trialToken: record.trialToken,
                writePolicy: layout.writePolicy,
                metadataPolicy: layout.metadataPolicy,
                nextBlock: record.nextCandidateBlock,
                blockCount: count
            )))

        case .trialPending:
            guard observation.slot == record.confirmedSlot,
                  !observation.wasTryBoot,
                  let candidateSlot = record.candidateSlot
            else { return actionUnexpected(observation) }
            guard observation.trialCapability == .oneShotAlternateSlot else {
                return .failure(.trialBootCapabilityUnavailable)
            }
            return .action(.authorizeTrial(BootTrialAuthorizationAction(
                confirmedSlot: record.confirmedSlot,
                candidateSlot: candidateSlot,
                generation: record.candidateGeneration,
                digest: record.candidateDigest,
                trialToken: record.trialToken
            )))

        case .trialBooting:
            guard let candidateSlot = record.candidateSlot,
                  observation.slot == candidateSlot,
                  observation.wasTryBoot
            else { return actionUnexpected(observation) }
            return .action(.awaitCandidateHealth(BootCandidateHealthAction(
                slot: candidateSlot,
                generation: record.candidateGeneration,
                digest: record.candidateDigest,
                trialToken: record.trialToken
            )))

        case .selectorCommitPending:
            guard let candidateSlot = record.candidateSlot,
                  (observation.slot == candidateSlot
                    || (observation.slot == record.confirmedSlot
                        && !observation.wasTryBoot))
            else { return actionUnexpected(observation) }
            return .action(.commitSelector(BootSelectorCommitAction(
                defaultSlot: candidateSlot
            )))

        case .replicatingPeer:
            guard let destination = record.candidateSlot else {
                return .failure(.missingCandidate)
            }
            if (observation.slot == destination && !observation.wasTryBoot)
                || (observation.slot == record.confirmedSlot
                    && observation.wasTryBoot) {
                return .action(.rebootToConfirmed(
                    BootConfirmedSlotRebootAction(
                        expectedSlot: record.confirmedSlot,
                        generation: record.confirmedGeneration,
                        digest: record.confirmedDigest
                    )
                ))
            }
            guard observation.slot == record.confirmedSlot,
                  !observation.wasTryBoot,
                  let plan = layout.copyPlan(
                    from: record.confirmedSlot,
                    to: destination
                  )
            else { return actionUnexpected(observation) }
            if record.nextCandidateBlock == record.slotBlockCount {
                return .action(.verifyMirror(
                    BootPeerMirrorVerificationAction(
                    sourceSlot: record.confirmedSlot,
                    destinationSlot: destination,
                    expectedGeneration: record.confirmedGeneration,
                    expectedDigest: record.confirmedDigest,
                    blockCount: record.slotBlockCount
                )))
            }
            guard validOperationLimit(maximumBlockCount) else {
                return .failure(.invalidOperationLimit)
            }
            guard let count = layout.writePolicy.boundedOperationCount(
                      atProgress: record.nextCandidateBlock,
                      blockCount: record.slotBlockCount,
                      requested: maximumBlockCount
                  )
            else { return .failure(.invalidOperationLimit) }
            return .action(.mirrorPeer(BootPeerMirrorAction(
                sourceSlot: record.confirmedSlot,
                destinationSlot: destination,
                plan: plan,
                nextBlock: record.nextCandidateBlock,
                blockCount: count
            )))
        }
    }

    /// Records one synchronized and read-back-verified inactive-slot chunk.
    static func recordVerifiedCandidateProgress(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        completed action: BootCandidateStageAction
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard record.phase == .writingCandidate,
              let candidateSlot = record.candidateSlot
        else { return .failure(.wrongTargetSlot) }
        guard observation.slot == record.confirmedSlot,
              !observation.wasTryBoot
        else { return unexpected(observation) }
        guard action.slot == candidateSlot,
              action.destination == layout.range(for: candidateSlot),
              action.generation == record.candidateGeneration,
              action.digest == record.candidateDigest,
              action.trialToken == record.trialToken,
              action.writePolicy == layout.writePolicy,
              action.metadataPolicy == layout.metadataPolicy,
              action.nextBlock == record.nextCandidateBlock,
              validPolicyProgress(
                from: action.nextBlock,
                count: action.blockCount,
                layout: layout
              ),
              validProgress(
                from: action.nextBlock,
                count: action.blockCount,
                limit: record.slotBlockCount
              )
        else { return .failure(.invalidVerifiedProgress) }
        return transition(record.recordCandidateProgress(
            nextBlock: action.nextBlock + action.blockCount
        ))
    }

    /// Seals a candidate only after a full-slot digest independently matches
    /// the descriptor that was journaled before the first write.
    static func sealVerifiedCandidate(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        slot: BootSlot,
        verifiedDescriptor: BootReleaseDescriptor
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard observation.slot == record.confirmedSlot,
              !observation.wasTryBoot
        else { return unexpected(observation) }
        guard record.phase == .writingCandidate,
              slot == record.candidateSlot
        else { return .failure(.wrongTargetSlot) }
        guard releaseDescriptor(from: record) == verifiedDescriptor else {
            return .failure(.descriptorMismatch)
        }
        return transition(record.sealCandidate())
    }

    /// Applies firmware-proven boot identity once at startup. A return to the
    /// old confirmed slot from either trial phase is recorded as rollback. A
    /// normal candidate boot after a selector write atomically confirms the new
    /// default and preserves the mandatory mirror as durable work.
    static func observeBoot(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        if record.phase == .stable {
            guard observation.slot == record.confirmedSlot,
                  !observation.wasTryBoot
            else {
                return unexpected(observation)
            }
            return .unchanged(record)
        }
        if record.phase == .trialBooting,
           observation.slot == record.candidateSlot,
           observation.wasTryBoot {
            return .unchanged(record)
        }
        if record.phase == .selectorCommitPending,
           observation.slot == record.candidateSlot {
            if observation.wasTryBoot {
                return .unchanged(record)
            }
            return confirmCandidateAndBeginMirror(record)
        }
        if record.phase == .replicatingPeer,
           observation.slot == record.candidateSlot,
           !observation.wasTryBoot {
            return .unchanged(record)
        }
        let result = record.observeBoot(
            slot: observation.slot,
            wasTryBoot: observation.wasTryBoot
        )
        if result == .rejected(.unexpectedBoot) {
            return unexpected(observation)
        }
        return transition(result)
    }

    static func confirmCandidateHealth(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        evidence: BootCandidateHealthAction
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard let candidateSlot = record.candidateSlot,
              observation.slot == candidateSlot,
              observation.wasTryBoot
        else { return unexpected(observation) }
        guard evidence == BootCandidateHealthAction(
            slot: candidateSlot,
            generation: record.candidateGeneration,
            digest: record.candidateDigest,
            trialToken: record.trialToken
        ) else { return .failure(.descriptorMismatch) }
        return transition(record.confirmCandidateHealth(
            slot: evidence.slot,
            generation: evidence.generation,
            digest: evidence.digest,
            trialToken: evidence.trialToken
        ))
    }

    /// Called after the platform selector was synchronized and read back. This
    /// one journal transition both confirms the healthy slot and records that
    /// its old peer must be replaced, avoiding a crash window that could forget
    /// convergence between two separate journal commits.
    static func recordSelectorCommitted(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        defaultSlot: BootSlot
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard record.phase == .selectorCommitPending,
              let candidateSlot = record.candidateSlot,
              defaultSlot == candidateSlot
        else { return .failure(.wrongTargetSlot) }
        guard observation.slot == candidateSlot
                || (observation.slot == record.confirmedSlot
                    && !observation.wasTryBoot)
        else { return unexpected(observation) }
        return confirmCandidateAndBeginMirror(record)
    }

    static func recordVerifiedMirrorProgress(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        completed action: BootPeerMirrorAction
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard record.phase == .replicatingPeer,
              let destinationSlot = record.candidateSlot,
              let expectedPlan = layout.copyPlan(
                from: record.confirmedSlot,
                to: destinationSlot
              )
        else { return .failure(.wrongTargetSlot) }
        guard observation.slot == record.confirmedSlot,
              !observation.wasTryBoot
        else {
            return unexpected(observation)
        }
        guard action.sourceSlot == record.confirmedSlot,
              action.destinationSlot == destinationSlot,
              action.plan == expectedPlan,
              action.nextBlock == record.nextCandidateBlock,
              validPolicyProgress(
                from: action.nextBlock,
                count: action.blockCount,
                layout: layout
              ),
              validProgress(
                from: action.nextBlock,
                count: action.blockCount,
                limit: record.slotBlockCount
              )
        else { return .failure(.invalidVerifiedProgress) }
        return transition(record.recordCandidateProgress(
            nextBlock: action.nextBlock + action.blockCount
        ))
    }

    static func sealVerifiedMirror(
        in record: BootControlRecord,
        observation: PlatformBootObservation?,
        layout: BootSlotLayout,
        evidence: BootPeerMirrorVerificationEvidence
    ) -> BootUpdateTransitionDecision {
        guard let observation else {
            return .failure(.missingBootObservation)
        }
        if let failure = validate(record: record, layout: layout) {
            return .failure(failure)
        }
        guard record.phase == .replicatingPeer,
              let destinationSlot = record.candidateSlot,
              evidence.destinationSlot == destinationSlot
        else { return .failure(.wrongTargetSlot) }
        guard observation.slot == record.confirmedSlot,
              !observation.wasTryBoot
        else {
            return unexpected(observation)
        }
        guard evidence.generation == record.confirmedGeneration,
              evidence.digest == record.confirmedDigest,
              evidence.blockCount == record.slotBlockCount
        else { return .failure(.descriptorMismatch) }
        return transition(record.sealCandidate())
    }

    private static func validate(
        record: BootControlRecord,
        layout: BootSlotLayout
    ) -> BootUpdateOrchestratorFailure? {
        guard record.mediaLayoutFingerprint
                == layout.mediaLayoutFingerprint
        else { return .mediaLayoutMismatch }
        guard record.slotBlockCount == layout.slotBlockCount else {
            return .slotBlockCountMismatch
        }
        return nil
    }

    private static func validOperationLimit(_ count: UInt64) -> Bool {
        count != 0 && count <= maximumBlocksPerOperation
    }

    private static func validProgress(
        from current: UInt64,
        count: UInt64,
        limit: UInt64
    ) -> Bool {
        guard current < limit,
              count != 0,
              count <= maximumBlocksPerOperation
        else { return false }
        return count <= limit - current
    }

    /// Completion evidence may be reconstructed after a crash, so validate
    /// the write-policy boundary independently of the action producer. In
    /// particular, neither of the two activation commits may be skipped by a
    /// forged multi-block progress report.
    private static func validPolicyProgress(
        from current: UInt64,
        count: UInt64,
        layout: BootSlotLayout
    ) -> Bool {
        layout.writePolicy.boundedOperationCount(
            atProgress: current,
            blockCount: layout.slotBlockCount,
            requested: count
        ) == count
    }

    private static func releaseDescriptor(
        from record: BootControlRecord
    ) -> BootReleaseDescriptor? {
        guard record.updateKind == .release else { return nil }
        return BootReleaseDescriptor(
            generation: record.candidateGeneration,
            digest: record.candidateDigest,
            blockCount: record.slotBlockCount,
            trialToken: record.trialToken
        )
    }

    private static func confirmCandidateAndBeginMirror(
        _ record: BootControlRecord
    ) -> BootUpdateTransitionDecision {
        guard record.phase == .selectorCommitPending,
              let candidateSlot = record.candidateSlot
        else { return .failure(.missingCandidate) }
        guard record.sequence != UInt64.max else {
            return .failure(.sequenceExhausted)
        }
        return .persist(BootControlRecord(
            sequence: record.sequence + 1,
            phase: .replicatingPeer,
            confirmedSlot: candidateSlot,
            confirmedGeneration: record.candidateGeneration,
            confirmedDigest: record.candidateDigest,
            candidateSlot: record.confirmedSlot,
            candidateGeneration: record.candidateGeneration,
            candidateDigest: record.candidateDigest,
            updateKind: .mirror,
            trialToken: 0,
            slotBlockCount: record.slotBlockCount,
            nextCandidateBlock: 0,
            failedTrialCount: record.failedTrialCount,
            mediaLayoutFingerprint: record.mediaLayoutFingerprint
        ))
    }

    private static func transition(
        _ result: BootControlTransitionResult
    ) -> BootUpdateTransitionDecision {
        switch result {
        case .record(let record):
            return .persist(record)
        case .rejected(let rejection):
            return .failure(.transitionRejected(rejection))
        }
    }

    private static func unexpected(
        _ observation: PlatformBootObservation
    ) -> BootUpdateTransitionDecision {
        .failure(.unexpectedBoot(
            slot: observation.slot,
            wasTryBoot: observation.wasTryBoot
        ))
    }

    private static func actionUnexpected(
        _ observation: PlatformBootObservation
    ) -> BootUpdateActionResult {
        .failure(.unexpectedBoot(
            slot: observation.slot,
            wasTryBoot: observation.wasTryBoot
        ))
    }
}
