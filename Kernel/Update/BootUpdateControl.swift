struct BootImageDigest: Equatable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64

    static let zero = BootImageDigest(
        word0: 0,
        word1: 0,
        word2: 0,
        word3: 0
    )

    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 32 else { return nil }
        word0 = Self.readLE64(bytes, at: 0)
        word1 = Self.readLE64(bytes, at: 8)
        word2 = Self.readLE64(bytes, at: 16)
        word3 = Self.readLE64(bytes, at: 24)
    }

    init(word0: UInt64, word1: UInt64, word2: UInt64, word3: UInt64) {
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
        self.word3 = word3
    }

    fileprivate func encode(
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        BootControlRecord.writeLE64(word0, into: bytes, at: offset)
        BootControlRecord.writeLE64(word1, into: bytes, at: offset + 8)
        BootControlRecord.writeLE64(word2, into: bytes, at: offset + 16)
        BootControlRecord.writeLE64(word3, into: bytes, at: offset + 24)
    }

    private static func readLE64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            index += 1
        }
        return value
    }
}

enum BootUpdatePhase: UInt8, Equatable {
    case stable = 0
    case writingCandidate = 1
    case trialPending = 2
    case trialBooting = 3
    case selectorCommitPending = 4
    case replicatingPeer = 5
}

enum BootUpdateKind: UInt8, Equatable {
    case release = 1
    case mirror = 2
}

enum BootControlTransitionRejection: Equatable {
    case wrongPhase
    case invalidCandidate
    case invalidGeneration
    case invalidBlockCount
    case invalidCursor
    case invalidTrialToken
    case unexpectedBoot
    case sequenceExhausted
}

enum BootControlTransitionResult: Equatable {
    case record(BootControlRecord)
    case rejected(BootControlTransitionRejection)
}

/// Crash-recoverable policy state for one A/B payload transaction.
///
/// The confirmed slot is never discarded while an update is being written or
/// trialed. Optional convergence copying has its own phase after the new slot
/// is already confirmed, so it can never move the selector back to a partially
/// written peer. A platform may prefer slot A, but that preference is
/// orchestration policy, not encoded into this board-neutral record.
struct BootControlRecord: Equatable {
    static let encodedByteCount = 160
    static let formatVersion: UInt16 = 1

    let sequence: UInt64
    let phase: BootUpdatePhase
    let confirmedSlot: BootSlot
    let confirmedGeneration: UInt64
    let confirmedDigest: BootImageDigest
    let candidateSlot: BootSlot?
    let candidateGeneration: UInt64
    let candidateDigest: BootImageDigest
    let updateKind: BootUpdateKind?
    let trialToken: UInt64
    let slotBlockCount: UInt64
    let nextCandidateBlock: UInt64
    let failedTrialCount: UInt32
    let mediaLayoutFingerprint: UInt64

    static func initial(
        confirmedSlot: BootSlot,
        generation: UInt64,
        digest: BootImageDigest,
        slotBlockCount: UInt64,
        mediaLayoutFingerprint: UInt64
    ) -> BootControlRecord? {
        guard generation != 0,
              digest != .zero,
              slotBlockCount != 0,
              mediaLayoutFingerprint != 0
        else { return nil }
        return BootControlRecord(
            sequence: 1,
            phase: .stable,
            confirmedSlot: confirmedSlot,
            confirmedGeneration: generation,
            confirmedDigest: digest,
            candidateSlot: nil,
            candidateGeneration: 0,
            candidateDigest: .zero,
            updateKind: nil,
            trialToken: 0,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: 0,
            failedTrialCount: 0,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        )
    }

    func beginCandidateWrite(
        to slot: BootSlot,
        generation: UInt64,
        digest: BootImageDigest,
        blockCount: UInt64,
        trialToken: UInt64
    ) -> BootControlTransitionResult {
        guard phase == .stable else { return .rejected(.wrongPhase) }
        guard slot == confirmedSlot.peer else {
            return .rejected(.invalidCandidate)
        }
        guard generation > confirmedGeneration else {
            return .rejected(.invalidGeneration)
        }
        guard blockCount != 0 else {
            return .rejected(.invalidBlockCount)
        }
        guard blockCount == slotBlockCount,
              digest != .zero
        else { return .rejected(.invalidBlockCount) }
        guard trialToken != 0 else {
            return .rejected(.invalidTrialToken)
        }
        guard let nextSequence else { return .rejected(.sequenceExhausted) }
        return .record(BootControlRecord(
            sequence: nextSequence,
            phase: .writingCandidate,
            confirmedSlot: confirmedSlot,
            confirmedGeneration: confirmedGeneration,
            confirmedDigest: confirmedDigest,
            candidateSlot: slot,
            candidateGeneration: generation,
            candidateDigest: digest,
            updateKind: .release,
            trialToken: trialToken,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: 0,
            failedTrialCount: failedTrialCount,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        ))
    }

    /// Begins the optional B-to-A (or A-to-B) convergence copy only after the
    /// new slot is already the confirmed/default boot source. Replication is
    /// never trialed and never changes the selector, so an interrupted copy
    /// continues to boot the confirmed source.
    func beginPeerReplication(
        to slot: BootSlot,
        blockCount: UInt64
    ) -> BootControlTransitionResult {
        guard phase == .stable else { return .rejected(.wrongPhase) }
        guard slot == confirmedSlot.peer else {
            return .rejected(.invalidCandidate)
        }
        guard blockCount == slotBlockCount else {
            return .rejected(.invalidBlockCount)
        }
        guard let nextSequence else { return .rejected(.sequenceExhausted) }
        return .record(BootControlRecord(
            sequence: nextSequence,
            phase: .replicatingPeer,
            confirmedSlot: confirmedSlot,
            confirmedGeneration: confirmedGeneration,
            confirmedDigest: confirmedDigest,
            candidateSlot: slot,
            candidateGeneration: confirmedGeneration,
            candidateDigest: confirmedDigest,
            updateKind: .mirror,
            trialToken: 0,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: 0,
            failedTrialCount: failedTrialCount,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        ))
    }

    func recordCandidateProgress(
        nextBlock: UInt64
    ) -> BootControlTransitionResult {
        guard phase == .writingCandidate || phase == .replicatingPeer else {
            return .rejected(.wrongPhase)
        }
        guard nextBlock > nextCandidateBlock,
              nextBlock <= slotBlockCount
        else { return .rejected(.invalidCursor) }
        guard let nextSequence else { return .rejected(.sequenceExhausted) }
        return .record(replacing(
            sequence: nextSequence,
            nextCandidateBlock: nextBlock
        ))
    }

    func sealCandidate() -> BootControlTransitionResult {
        guard phase == .writingCandidate || phase == .replicatingPeer else {
            return .rejected(.wrongPhase)
        }
        guard nextCandidateBlock == slotBlockCount
        else { return .rejected(.invalidCursor) }
        guard let nextSequence else { return .rejected(.sequenceExhausted) }
        if phase == .replicatingPeer {
            return .record(BootControlRecord(
                sequence: nextSequence,
                phase: .stable,
                confirmedSlot: confirmedSlot,
                confirmedGeneration: confirmedGeneration,
                confirmedDigest: confirmedDigest,
                candidateSlot: nil,
                candidateGeneration: 0,
                candidateDigest: .zero,
                updateKind: nil,
                trialToken: 0,
                slotBlockCount: slotBlockCount,
                nextCandidateBlock: 0,
                failedTrialCount: failedTrialCount,
                mediaLayoutFingerprint: mediaLayoutFingerprint
            ))
        }
        return .record(replacing(sequence: nextSequence, phase: .trialPending))
    }

    /// Records the firmware-proven boot identity. A normal return to the
    /// confirmed slot after either trial state is an automatic rollback: the
    /// one-shot candidate did not reach its health confirmation point.
    func observeBoot(
        slot: BootSlot,
        wasTryBoot: Bool
    ) -> BootControlTransitionResult {
        if (phase == .writingCandidate || phase == .replicatingPeer),
           slot == confirmedSlot,
           !wasTryBoot {
            guard let nextSequence else {
                return .rejected(.sequenceExhausted)
            }
            return .record(replacing(sequence: nextSequence))
        }
        if phase == .trialPending,
           slot == candidateSlot,
           wasTryBoot {
            guard let nextSequence else {
                return .rejected(.sequenceExhausted)
            }
            return .record(replacing(
                sequence: nextSequence,
                phase: .trialBooting
            ))
        }
        if (phase == .trialPending || phase == .trialBooting),
           slot == confirmedSlot,
           !wasTryBoot {
            guard let nextSequence else {
                return .rejected(.sequenceExhausted)
            }
            return .record(BootControlRecord(
                sequence: nextSequence,
                phase: .stable,
                confirmedSlot: confirmedSlot,
                confirmedGeneration: confirmedGeneration,
                confirmedDigest: confirmedDigest,
                candidateSlot: nil,
                candidateGeneration: 0,
                candidateDigest: .zero,
                updateKind: nil,
                trialToken: 0,
                slotBlockCount: slotBlockCount,
                nextCandidateBlock: 0,
                failedTrialCount: failedTrialCount == UInt32.max
                    ? UInt32.max : failedTrialCount + 1,
                mediaLayoutFingerprint: mediaLayoutFingerprint
            ))
        }
        if phase == .selectorCommitPending,
           slot == candidateSlot,
           !wasTryBoot,
           let candidateSlot,
           let nextSequence {
            return .record(BootControlRecord(
                sequence: nextSequence,
                phase: .stable,
                confirmedSlot: candidateSlot,
                confirmedGeneration: candidateGeneration,
                confirmedDigest: candidateDigest,
                candidateSlot: nil,
                candidateGeneration: 0,
                candidateDigest: .zero,
                updateKind: nil,
                trialToken: 0,
                slotBlockCount: slotBlockCount,
                nextCandidateBlock: 0,
                failedTrialCount: failedTrialCount,
                mediaLayoutFingerprint: mediaLayoutFingerprint
            ))
        }
        if phase == .selectorCommitPending,
           slot == confirmedSlot,
           !wasTryBoot,
           let nextSequence {
            return .record(replacing(sequence: nextSequence))
        }
        return .rejected(.unexpectedBoot)
    }

    func confirmCandidateHealth(
        slot: BootSlot,
        generation: UInt64,
        digest: BootImageDigest,
        trialToken: UInt64
    ) -> BootControlTransitionResult {
        guard phase == .trialBooting else {
            return .rejected(.wrongPhase)
        }
        guard slot == candidateSlot,
              generation == candidateGeneration,
              digest == candidateDigest,
              trialToken == self.trialToken
        else { return .rejected(.invalidCandidate) }
        guard let nextSequence else { return .rejected(.sequenceExhausted) }
        return .record(replacing(
            sequence: nextSequence,
            phase: .selectorCommitPending
        ))
    }

    /// Called only after the platform selector was synchronized and read back.
    /// If mirroring back to a preferred slot is desired, the caller starts a
    /// `.mirror` transaction from this new stable state.
    func confirmSelectorCommit(
        to slot: BootSlot
    ) -> BootControlTransitionResult {
        guard phase == .selectorCommitPending else {
            return .rejected(.wrongPhase)
        }
        guard slot == candidateSlot,
              let candidateSlot,
              let nextSequence
        else { return .rejected(.invalidCandidate) }
        return .record(BootControlRecord(
            sequence: nextSequence,
            phase: .stable,
            confirmedSlot: candidateSlot,
            confirmedGeneration: candidateGeneration,
            confirmedDigest: candidateDigest,
            candidateSlot: nil,
            candidateGeneration: 0,
            candidateDigest: .zero,
            updateKind: nil,
            trialToken: 0,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: 0,
            failedTrialCount: failedTrialCount,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        ))
    }

    fileprivate func encode(
        into block: UnsafeMutableRawBufferPointer,
        at base: Int
    ) -> Bool {
        guard isValid,
              base >= 0,
              base <= block.count - Self.encodedByteCount
        else { return false }
        var index = 0
        while index < Self.encodedByteCount {
            block[base + index] = 0
            index += 1
        }
        block[base] = 0x53
        block[base + 1] = 0x57
        block[base + 2] = 0x41
        block[base + 3] = 0x42
        block[base + 4] = 0x43
        block[base + 5] = 0x54
        block[base + 6] = 0x4c
        block[base + 7] = 0x31
        Self.writeLE16(Self.formatVersion, into: block, at: base + 8)
        Self.writeLE16(
            UInt16(Self.encodedByteCount),
            into: block,
            at: base + 10
        )
        Self.writeLE64(sequence, into: block, at: base + 16)
        block[base + 24] = phase.rawValue
        block[base + 25] = confirmedSlot.rawValue
        block[base + 26] = candidateSlot?.rawValue ?? 0
        block[base + 27] = updateKind?.rawValue ?? 0
        Self.writeLE32(failedTrialCount, into: block, at: base + 28)
        Self.writeLE64(confirmedGeneration, into: block, at: base + 32)
        Self.writeLE64(candidateGeneration, into: block, at: base + 40)
        Self.writeLE64(trialToken, into: block, at: base + 48)
        Self.writeLE64(nextCandidateBlock, into: block, at: base + 56)
        Self.writeLE64(slotBlockCount, into: block, at: base + 64)
        confirmedDigest.encode(into: block, at: base + 72)
        candidateDigest.encode(into: block, at: base + 104)
        Self.writeLE64(mediaLayoutFingerprint, into: block, at: base + 136)
        guard let recordAddress = block.baseAddress?.advanced(by: base) else {
            return false
        }
        let checksum = StorageCRC32.checksum(UnsafeRawBufferPointer(
            start: recordAddress,
            count: 156
        ))
        Self.writeLE32(checksum, into: block, at: base + 156)
        return true
    }

    fileprivate static func decode(
        _ block: UnsafeMutableRawBufferPointer,
        at base: Int
    ) -> BootControlRecord? {
        guard base >= 0,
              base <= block.count - encodedByteCount,
              hasMagic(block, at: base),
              readLE16(block, at: base + 8) == formatVersion,
              readLE16(block, at: base + 10) == UInt16(encodedByteCount),
              let address = block.baseAddress?.advanced(by: base),
              readLE32(block, at: base + 156)
                == StorageCRC32.checksum(UnsafeRawBufferPointer(
                    start: address,
                    count: 156
                ))
        else { return nil }
        var reserved = base + 144
        while reserved < base + 156 {
            if block[reserved] != 0 { return nil }
            reserved += 1
        }
        guard let phase = BootUpdatePhase(rawValue: block[base + 24]),
              let confirmed = BootSlot(rawValue: block[base + 25])
        else { return nil }
        let candidateRaw = block[base + 26]
        let kindRaw = block[base + 27]
        let candidate = candidateRaw == 0
            ? nil : BootSlot(rawValue: candidateRaw)
        let kind = kindRaw == 0 ? nil : BootUpdateKind(rawValue: kindRaw)
        if candidateRaw != 0 && candidate == nil { return nil }
        if kindRaw != 0 && kind == nil { return nil }
        let confirmedDigest = BootImageDigest(
            word0: readLE64(block, at: base + 72),
            word1: readLE64(block, at: base + 80),
            word2: readLE64(block, at: base + 88),
            word3: readLE64(block, at: base + 96)
        )
        let candidateDigest = BootImageDigest(
            word0: readLE64(block, at: base + 104),
            word1: readLE64(block, at: base + 112),
            word2: readLE64(block, at: base + 120),
            word3: readLE64(block, at: base + 128)
        )
        let record = BootControlRecord(
            sequence: readLE64(block, at: base + 16),
            phase: phase,
            confirmedSlot: confirmed,
            confirmedGeneration: readLE64(block, at: base + 32),
            confirmedDigest: confirmedDigest,
            candidateSlot: candidate,
            candidateGeneration: readLE64(block, at: base + 40),
            candidateDigest: candidateDigest,
            updateKind: kind,
            trialToken: readLE64(block, at: base + 48),
            slotBlockCount: readLE64(block, at: base + 64),
            nextCandidateBlock: readLE64(block, at: base + 56),
            failedTrialCount: readLE32(block, at: base + 28),
            mediaLayoutFingerprint: readLE64(block, at: base + 136)
        )
        return record.isValid ? record : nil
    }

    fileprivate static func hasMagic(
        _ bytes: UnsafeMutableRawBufferPointer,
        at base: Int
    ) -> Bool {
        guard base >= 0, base <= bytes.count - 8 else { return false }
        return bytes[base] == 0x53 && bytes[base + 1] == 0x57
            && bytes[base + 2] == 0x41 && bytes[base + 3] == 0x42
            && bytes[base + 4] == 0x43 && bytes[base + 5] == 0x54
            && bytes[base + 6] == 0x4c && bytes[base + 7] == 0x31
    }

    fileprivate static func writeLE16(
        _ value: UInt16,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    fileprivate static func writeLE32(
        _ value: UInt32,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE16(UInt16(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE16(
            UInt16(truncatingIfNeeded: value >> 16),
            into: bytes,
            at: offset + 2
        )
    }

    fileprivate static func writeLE64(
        _ value: UInt64,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE32(
            UInt32(truncatingIfNeeded: value >> 32),
            into: bytes,
            at: offset + 4
        )
    }

    fileprivate static func readLE16(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    fileprivate static func readLE32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(readLE16(bytes, at: offset))
            | UInt32(readLE16(bytes, at: offset + 2)) << 16
    }

    fileprivate static func readLE64(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readLE32(bytes, at: offset))
            | UInt64(readLE32(bytes, at: offset + 4)) << 32
    }

    private var nextSequence: UInt64? {
        sequence == UInt64.max ? nil : sequence + 1
    }

    private var isValid: Bool {
        guard sequence != 0,
              confirmedGeneration != 0,
              confirmedDigest != .zero,
              slotBlockCount != 0,
              mediaLayoutFingerprint != 0
        else { return false }
        switch phase {
        case .stable:
            return candidateSlot == nil
                && candidateGeneration == 0
                && candidateDigest == .zero
                && updateKind == nil
                && trialToken == 0
                && nextCandidateBlock == 0
        case .writingCandidate, .trialPending, .trialBooting,
             .selectorCommitPending:
            guard candidateSlot == confirmedSlot.peer,
                  let updateKind,
                  updateKind == .release,
                  trialToken != 0,
                  candidateDigest != .zero,
                  nextCandidateBlock <= slotBlockCount
            else { return false }
            if updateKind == .release {
                guard candidateGeneration > confirmedGeneration else {
                    return false
                }
            } else if candidateGeneration != confirmedGeneration {
                return false
            }
            if phase != .writingCandidate,
               nextCandidateBlock != slotBlockCount {
                return false
            }
            return true
        case .replicatingPeer:
            return candidateSlot == confirmedSlot.peer
                && candidateGeneration == confirmedGeneration
                && candidateDigest == confirmedDigest
                && updateKind == .mirror
                && trialToken == 0
                && nextCandidateBlock <= slotBlockCount
        }
    }

    private func replacing(
        sequence: UInt64,
        phase: BootUpdatePhase? = nil,
        nextCandidateBlock: UInt64? = nil
    ) -> BootControlRecord {
        BootControlRecord(
            sequence: sequence,
            phase: phase ?? self.phase,
            confirmedSlot: confirmedSlot,
            confirmedGeneration: confirmedGeneration,
            confirmedDigest: confirmedDigest,
            candidateSlot: candidateSlot,
            candidateGeneration: candidateGeneration,
            candidateDigest: candidateDigest,
            updateKind: updateKind,
            trialToken: trialToken,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: nextCandidateBlock ?? self.nextCandidateBlock,
            failedTrialCount: failedTrialCount,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        )
    }
}

enum BootControlJournalRedundancy: Equatable {
    case oneValidReplica
    case twoValidReplicas
}

enum BootControlJournalOpenFailure: Equatable {
    case invalidScratch
    case invalidDataVolume
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
    case corruptRecord
    case conflictingRecords
}

enum BootControlJournalOpenResult: Equatable {
    case empty
    case record(BootControlRecord, BootControlJournalRedundancy)
    case failure(BootControlJournalOpenFailure)
}

enum BootControlJournalCommitFailure: Equatable {
    case invalidScratch
    case invalidDataVolume
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
    case existingJournal(BootControlJournalOpenFailure)
    case sequenceMismatch
    case encodeFailed
    case writeFailed(block: UInt64, result: BlockDeviceIOResult)
    case synchronizeFailed(BlockDeviceIOResult)
    case readbackMismatch
}

enum BootControlJournalCommitResult: Equatable {
    case committed(block: UInt64, sequence: UInt64)
    case failure(BootControlJournalCommitFailure)
}

/// Two boot-control replicas live in bytes 64...223 of the two existing data
/// superblocks. Data-volume v1 owns and checks only bytes 0...63, so this is a
/// backwards-compatible journal extension and does not move either the log or
/// SwiftFS arenas. Each update overwrites the older replica, synchronizes, and
/// verifies it before the newer state becomes authoritative.
enum BootControlJournal {
    static let recordOffset = 64

    private struct ReplicaInspection {
        let outerSuperblockIsValid: Bool
        let recordAreaIsZero: Bool
        let record: BootControlRecord?

        var recordIsCorrupt: Bool {
            outerSuperblockIsValid && record == nil && !recordAreaIsZero
        }
    }

    static func open<Device: BlockDevice>(
        _ device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> BootControlJournalOpenResult {
        guard scratch.count >= device.geometry.logicalBlockByteCount,
              device.geometry.logicalBlockByteCount
                >= recordOffset + BootControlRecord.encodedByteCount
        else { return .failure(.invalidScratch) }

        switch SwiftOSDataVolume.open(&device, scratch: scratch) {
        case .volume:
            break
        case .failure:
            return .failure(.invalidDataVolume)
        }

        var replica0: ReplicaInspection?
        var replica1: ReplicaInspection?
        var block: UInt64 = 0
        while block < 2 {
            let read = device.readBlock(at: block, into: scratch)
            guard read == .success else {
                return .failure(.readFailed(block: block, result: read))
            }
            let outerValid = validDataVolumePrefix(
                scratch,
                geometry: device.geometry
            )
            let inspection = ReplicaInspection(
                outerSuperblockIsValid: outerValid,
                recordAreaIsZero: recordAreaIsZero(scratch),
                record: outerValid
                    ? BootControlRecord.decode(scratch, at: recordOffset)
                    : nil
            )
            if block == 0 { replica0 = inspection } else { replica1 = inspection }
            block += 1
        }
        guard let replica0, let replica1 else {
            return .failure(.invalidDataVolume)
        }
        let record0 = replica0.record
        let record1 = replica1.record
        if record0 == nil && record1 == nil {
            if replica0.recordIsCorrupt || replica1.recordIsCorrupt {
                return .failure(.corruptRecord)
            }
            // With one damaged outer superblock, a zero record in the survivor
            // cannot prove that a newer journal was not lost with its peer.
            guard replica0.outerSuperblockIsValid,
                  replica1.outerSuperblockIsValid,
                  replica0.recordAreaIsZero,
                  replica1.recordAreaIsZero
            else { return .failure(.invalidDataVolume) }
            return .empty
        }
        if let record0, let record1 {
            if record0.sequence == record1.sequence,
               record0 != record1 {
                return .failure(.conflictingRecords)
            }
            return .record(
                record0.sequence >= record1.sequence ? record0 : record1,
                .twoValidReplicas
            )
        }
        return .record(record0 ?? record1!, .oneValidReplica)
    }

    static func commit<Device: BlockDevice>(
        _ record: BootControlRecord,
        to device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> BootControlJournalCommitResult {
        guard scratch.count >= device.geometry.logicalBlockByteCount,
              device.geometry.logicalBlockByteCount
                >= recordOffset + BootControlRecord.encodedByteCount
        else { return .failure(.invalidScratch) }

        switch SwiftOSDataVolume.open(&device, scratch: scratch) {
        case .volume:
            break
        case .failure:
            return .failure(.invalidDataVolume)
        }

        var replica0: ReplicaInspection?
        var replica1: ReplicaInspection?
        var block: UInt64 = 0
        while block < 2 {
            let read = device.readBlock(at: block, into: scratch)
            guard read == .success else {
                return .failure(.readFailed(block: block, result: read))
            }
            let outerValid = validDataVolumePrefix(
                scratch,
                geometry: device.geometry
            )
            let inspection = ReplicaInspection(
                outerSuperblockIsValid: outerValid,
                recordAreaIsZero: recordAreaIsZero(scratch),
                record: outerValid
                    ? BootControlRecord.decode(scratch, at: recordOffset)
                    : nil
            )
            if block == 0 { replica0 = inspection } else { replica1 = inspection }
            block += 1
        }
        guard let replica0, let replica1 else {
            return .failure(.invalidDataVolume)
        }
        let existing0 = replica0.record
        let existing1 = replica1.record

        let target: UInt64
        if let existing0, let existing1 {
            if existing0.sequence == existing1.sequence,
               existing0 != existing1 {
                return .failure(.existingJournal(.conflictingRecords))
            }
            let current = existing0.sequence >= existing1.sequence
                ? existing0 : existing1
            let currentBlock: UInt64 = existing0.sequence >= existing1.sequence
                ? 0 : 1
            if record == current {
                return synchronizeAndVerifyExisting(
                    record,
                    at: currentBlock,
                    on: &device,
                    scratch: scratch
                )
            }
            guard current.sequence != UInt64.max,
                  record.sequence == current.sequence + 1
            else { return .failure(.sequenceMismatch) }
            target = existing0.sequence <= existing1.sequence ? 0 : 1
        } else if let existing = existing0 ?? existing1 {
            let existingBlock: UInt64 = existing0 == nil ? 1 : 0
            if record == existing {
                return synchronizeAndVerifyExisting(
                    record,
                    at: existingBlock,
                    on: &device,
                    scratch: scratch
                )
            }
            guard existing.sequence != UInt64.max,
                  record.sequence == existing.sequence + 1
            else { return .failure(.sequenceMismatch) }
            target = existing0 == nil ? 0 : 1
        } else {
            if replica0.recordIsCorrupt || replica1.recordIsCorrupt {
                return .failure(.existingJournal(.corruptRecord))
            }
            guard replica0.outerSuperblockIsValid,
                  replica1.outerSuperblockIsValid,
                  replica0.recordAreaIsZero,
                  replica1.recordAreaIsZero
            else { return .failure(.invalidDataVolume) }
            guard record.sequence == 1 else {
                return .failure(.sequenceMismatch)
            }
            target = 0
        }

        let targetOuterIsValid = target == 0
            ? replica0.outerSuperblockIsValid
            : replica1.outerSuperblockIsValid
        let sourceBlock: UInt64
        if targetOuterIsValid {
            sourceBlock = target
        } else if replica0.outerSuperblockIsValid {
            sourceBlock = 0
        } else if replica1.outerSuperblockIsValid {
            sourceBlock = 1
        } else {
            return .failure(.invalidDataVolume)
        }
        let read = device.readBlock(at: sourceBlock, into: scratch)
        guard read == .success else {
            return .failure(.readFailed(block: sourceBlock, result: read))
        }
        guard record.encode(into: scratch, at: recordOffset) else {
            return .failure(.encodeFailed)
        }
        guard let base = scratch.baseAddress else {
            return .failure(.invalidScratch)
        }
        let write = device.writeBlock(
            at: target,
            from: UnsafeRawBufferPointer(
                start: base,
                count: device.geometry.logicalBlockByteCount
            )
        )
        guard write == .success else {
            return .failure(.writeFailed(block: target, result: write))
        }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .failure(.synchronizeFailed(synchronized))
        }
        let readback = device.readBlock(at: target, into: scratch)
        guard readback == .success else {
            return .failure(.readFailed(block: target, result: readback))
        }
        guard BootControlRecord.decode(scratch, at: recordOffset) == record else {
            return .failure(.readbackMismatch)
        }
        return .committed(block: target, sequence: record.sequence)
    }

    /// Retry the exact newest record after an earlier synchronization result
    /// was uncertain. This never advances sequence; it establishes a fresh
    /// media barrier and proves the already-written bytes by readback.
    private static func synchronizeAndVerifyExisting<Device: BlockDevice>(
        _ record: BootControlRecord,
        at block: UInt64,
        on device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> BootControlJournalCommitResult {
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .failure(.synchronizeFailed(synchronized))
        }
        let readback = device.readBlock(at: block, into: scratch)
        guard readback == .success else {
            return .failure(.readFailed(block: block, result: readback))
        }
        guard validDataVolumePrefix(scratch, geometry: device.geometry),
              BootControlRecord.decode(scratch, at: recordOffset) == record
        else { return .failure(.readbackMismatch) }
        return .committed(block: block, sequence: record.sequence)
    }

    private static func recordAreaIsZero(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard bytes.count >= recordOffset + BootControlRecord.encodedByteCount
        else { return false }
        var index = recordOffset
        let end = recordOffset + BootControlRecord.encodedByteCount
        while index < end {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private static func validDataVolumePrefix(
        _ bytes: UnsafeMutableRawBufferPointer,
        geometry: BlockDeviceGeometry
    ) -> Bool {
        guard bytes.count >= 64,
              bytes[0] == 0x53, bytes[1] == 0x57,
              bytes[2] == 0x4f, bytes[3] == 0x53,
              bytes[4] == 0x44, bytes[5] == 0x41,
              bytes[6] == 0x54, bytes[7] == 0x41,
              BootControlRecord.readLE16(bytes, at: 8) == 1,
              BootControlRecord.readLE16(bytes, at: 10) == 64,
              BootControlRecord.readLE32(bytes, at: 12)
                == UInt32(geometry.logicalBlockByteCount),
              BootControlRecord.readLE64(bytes, at: 16)
                == geometry.logicalBlockCount,
              let base = bytes.baseAddress
        else { return false }
        let checksum = StorageCRC32.checksum(UnsafeRawBufferPointer(
            start: base,
            count: 60
        ))
        return BootControlRecord.readLE32(bytes, at: 60) == checksum
    }
}
