private struct RaspberryPi5ABSlotHashState {
    let range: BlockDeviceRange
    let expectedDigest: BootImageDigest
    var nextBlock: UInt64
    var hash: USBKernelUpdateSHA256
}

private struct RaspberryPi5ABVerifiedMirrorSource: Equatable {
    let range: BlockDeviceRange
    let expectedDigest: BootImageDigest
}

private enum RaspberryPi5ABSlotHashResult {
    case inProgress
    case verified
    case failed
}

private enum RaspberryPi5ABRecoveryVerificationPhase: UInt8 {
    case confirmed
    case candidate
    case selector
}

/// Pi media adapter for the board-neutral transaction executor.
///
/// This value borrows the one SD transport already owned by
/// `RaspberryPi5StorageRuntime`; it never initializes another controller. The
/// owner must give it service priority before publishing any filesystem alias.
/// Its lease prevents re-entry through this port, while the runtime remains
/// responsible for withholding log/SwiftFS service for the lease duration.
///
/// New-release staging intentionally fails closed until a distinct persistent
/// full-slot source is integrated. Journal recovery, full-slot verification,
/// selector repair/commit, and confirmed-slot mirroring are operational here.
struct RaspberryPi5ABUpdatePort<Device: BlockDevice>:
    BootUpdateRuntimePort {
    /// Hash at most 64 KiB per cooperative pass. This keeps watchdog and USB
    /// service responsive without turning a 128 MiB verification into tens of
    /// thousands of scheduler round trips.
    static var maximumHashBlocksPerPass: UInt64 { 128 }

    let media: SwiftOSABMediaPartitions
    let layout: BootSlotLayout

    private let device: UnsafeMutablePointer<Device>
    private let scratch: UnsafeMutableRawBufferPointer
    private var leaseHeld = false
    private var hashState: RaspberryPi5ABSlotHashState?
    private var verifiedMirrorSource: RaspberryPi5ABVerifiedMirrorSource?
    private var recoveryAction: BootRecoverySelectorRepairAction?
    private var recoveryPhase =
        RaspberryPi5ABRecoveryVerificationPhase.confirmed

    init?(
        borrowing device: UnsafeMutablePointer<Device>?,
        media: SwiftOSABMediaPartitions,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        let table = MBRPartitionTable(
            partition0: media.selector,
            partition1: media.slotA,
            partition2: media.slotB,
            partition3: media.data
        )
        guard let device,
              UInt(bitPattern: device)
                & UInt(MemoryLayout<Device>.alignment - 1) == 0,
              scratch.baseAddress != nil,
              scratch.count >= 1_024,
              case .layout(let validatedMedia) =
                SwiftOSABMediaLayout.select(from: table),
              validatedMedia == media,
              media.selector.index == 0,
              media.slotA.index == 1,
              media.slotB.index == 2,
              media.data.index == 3,
              media.selector.range.blockCount
                == RaspberryPiABSelector.partitionBlockCount,
              media.data.range.blockCount >= 2,
              let layout = RaspberryPiABUpdateLayout.make(
                  deviceGeometry: device.pointee.geometry,
                  slotA: media.slotA.range,
                  slotB: media.slotB.range
              ),
              BorrowedBlockDeviceRegion(
                  borrowing: device,
                  partitionRange: media.selector.range
              ) != nil,
              BorrowedBlockDeviceRegion(
                  borrowing: device,
                  partitionRange: media.data.range
              ) != nil
        else { return nil }
        self.device = device
        self.media = media
        self.layout = layout
        self.scratch = scratch
    }

    mutating func acquireExclusiveMediaLease() -> Bool {
        guard !leaseHeld else { return false }
        leaseHeld = true
        return true
    }

    mutating func releaseExclusiveMediaLease() {
        leaseHeld = false
    }

    mutating func loadBootControlRecord()
        -> BootUpdateRuntimeJournalLoadResult {
        guard leaseHeld, var data = dataDevice() else { return .unavailable }
        switch BootControlJournal.open(&data, scratch: scratch) {
        case .record(let record, _): return .record(record)
        case .empty, .failure: return .unavailable
        }
    }

    mutating func commitBootControlRecord(
        _ record: BootControlRecord
    ) -> Bool {
        guard leaseHeld, var data = dataDevice() else { return false }
        guard case .committed(_, let sequence) = BootControlJournal.commit(
                  record,
                  to: &data,
                  scratch: scratch
              )
        else { return false }
        return sequence == record.sequence
    }

    /// A later persistent transport supplies one bounded release-source block
    /// through this seam. Until then no ordinary payload boot can gain raw
    /// inactive-slot write authority merely by presenting release metadata.
    mutating func stageCandidate(
        _ action: BootCandidateStageAction
    ) -> Bool {
        _ = action
        return false
    }

    mutating func verifyCandidate(
        _ action: BootCandidateVerificationAction
    ) -> BootUpdateRuntimeCandidateVerificationResult {
        guard leaseHeld,
              action.descriptor.blockCount == layout.slotBlockCount
        else { return .failed }
        switch advanceHash(
            range: layout.range(for: action.slot),
            expected: action.descriptor.digest
        ) {
        case .inProgress: return .inProgress
        case .verified: return .verified(action.descriptor)
        case .failed: return .failed
        }
    }

    mutating func commitSelector(
        _ action: BootSelectorCommitAction
    ) -> BootUpdateRuntimeSelectorCommitResult {
        guard leaseHeld, var selector = selectorDevice() else {
            return .rejectedBeforeWrite
        }
        switch RaspberryPiABSelector.commit(
            defaultSlot: action.defaultSlot,
            to: &selector,
            scratch: scratch
        ) {
        case .committed, .unchanged:
            return .committed
        case .rejectedBeforeWrite:
            return .rejectedBeforeWrite
        case .durabilityUncertain:
            return .durabilityUncertain
        }
    }

    mutating func repairSelectorFromRecovery(
        _ action: BootRecoverySelectorRepairAction
    ) -> BootUpdateRuntimeRecoverySelectorRepairResult {
        guard leaseHeld,
              action.mediaLayoutFingerprint == layout.mediaLayoutFingerprint,
              action.confirmedSlot != action.candidateSlot,
              action.defaultSlot == action.candidateSlot,
              action.confirmedRange == layout.range(for: action.confirmedSlot),
              action.candidateRange == layout.range(for: action.candidateSlot)
        else { return .failed }

        if recoveryAction != action {
            recoveryAction = action
            recoveryPhase = .confirmed
            hashState = nil
        }
        switch recoveryPhase {
        case .confirmed:
            switch advanceHash(
                range: action.confirmedRange,
                expected: action.confirmedDigest
            ) {
            case .inProgress: return .inProgress
            case .failed: return failRecovery()
            case .verified:
                recoveryPhase = .candidate
                return .inProgress
            }
        case .candidate:
            switch advanceHash(
                range: action.candidateRange,
                expected: action.candidateDigest
            ) {
            case .inProgress: return .inProgress
            case .failed: return failRecovery()
            case .verified:
                recoveryPhase = .selector
                return .inProgress
            }
        case .selector:
            guard var selector = selectorDevice() else {
                return failRecovery()
            }
            let result = RaspberryPiABSelector.commit(
                defaultSlot: action.defaultSlot,
                to: &selector,
                scratch: scratch
            )
            switch result {
            case .committed, .unchanged:
                resetRecovery()
                return .repaired
            case .rejectedBeforeWrite, .durabilityUncertain:
                return failRecovery()
            }
        }
    }

    mutating func mirrorPeer(
        _ action: BootPeerMirrorAction
    ) -> BootUpdateRuntimePeerMirrorResult {
        guard leaseHeld,
              action.sourceSlot != action.destinationSlot,
              action.plan == layout.copyPlan(
                  from: action.sourceSlot,
                  to: action.destinationSlot
              ),
              action.expectedDigest != .zero,
              action.blockCount != 0,
              action.blockCount <= VerifiedSlotCopier.maximumBlocksPerChunk,
              action.plan.writePolicy.boundedOperationCount(
                  atProgress: action.nextBlock,
                  blockCount: action.plan.blockCount,
                  requested: action.blockCount
              ) == action.blockCount,
              var whole = wholeDevice()
        else { return .failed }
        let proof = RaspberryPi5ABVerifiedMirrorSource(
            range: action.plan.source,
            expectedDigest: action.expectedDigest
        )
        if verifiedMirrorSource != proof {
            switch advanceHash(
                range: action.plan.source,
                expected: action.expectedDigest
            ) {
            case .inProgress:
                return .inProgress
            case .failed:
                verifiedMirrorSource = nil
                return .failed
            case .verified:
                verifiedMirrorSource = proof
            }
        }
        let result = VerifiedSlotCopier.copyNextChunk(
            on: &whole,
            plan: action.plan,
            nextBlock: action.nextBlock,
            maximumBlockCount: action.blockCount,
            scratch: scratch
        )
        guard case .advanced(let nextBlock, let isComplete) = result,
              nextBlock == action.nextBlock + action.blockCount
        else {
            verifiedMirrorSource = nil
            return .failed
        }
        if isComplete {
            verifiedMirrorSource = nil
        }
        return .mirrored
    }

    mutating func verifyMirror(
        _ action: BootPeerMirrorVerificationAction
    ) -> BootUpdateRuntimeMirrorVerificationResult {
        guard leaseHeld,
              action.sourceSlot != action.destinationSlot,
              action.blockCount == layout.slotBlockCount
        else { return .failed }
        switch advanceHash(
            range: layout.range(for: action.destinationSlot),
            expected: action.expectedDigest
        ) {
        case .inProgress: return .inProgress
        case .failed: return .failed
        case .verified:
            return .verified(BootPeerMirrorVerificationEvidence(
                destinationSlot: action.destinationSlot,
                generation: action.expectedGeneration,
                digest: action.expectedDigest,
                blockCount: action.blockCount
            ))
        }
    }

    private mutating func advanceHash(
        range: BlockDeviceRange,
        expected: BootImageDigest
    ) -> RaspberryPi5ABSlotHashResult {
        guard leaseHeld, expected != .zero, var whole = wholeDevice(),
              let base = scratch.baseAddress
        else { return .failed }
        var state: RaspberryPi5ABSlotHashState
        if let existing = hashState,
           existing.range == range,
           existing.expectedDigest == expected {
            state = existing
        } else {
            state = RaspberryPi5ABSlotHashState(
                range: range,
                expectedDigest: expected,
                nextBlock: 0,
                hash: USBKernelUpdateSHA256()
            )
        }
        let block = UnsafeMutableRawBufferPointer(start: base, count: 512)
        var completed: UInt64 = 0
        while state.nextBlock < range.blockCount,
              completed < Self.maximumHashBlocksPerPass {
            let result = whole.readBlock(
                at: range.startBlock + state.nextBlock,
                into: block
            )
            guard result == .success,
                  layout.metadataPolicy.normalizeForContentDigest(
                      relativeBlock: state.nextBlock,
                      slotStartBlock: range.startBlock,
                      bytes: block
                  ),
                  let address = block.baseAddress,
                  state.hash.update(UnsafeRawBufferPointer(
                      start: address,
                      count: block.count
                  ))
            else {
                hashState = nil
                return .failed
            }
            state.nextBlock += 1
            completed += 1
        }
        guard state.nextBlock == range.blockCount else {
            hashState = state
            return .inProgress
        }
        hashState = nil
        let digest = state.hash.finalizedDigest()
        let digestBuffer = UnsafeMutableRawBufferPointer(
            start: base.advanced(by: 512),
            count: 32
        )
        guard digest.write(to: digestBuffer),
              let digestAddress = digestBuffer.baseAddress,
              let measured = BootImageDigest(bytes: UnsafeRawBufferPointer(
                  start: digestAddress,
                  count: digestBuffer.count
              )), measured == expected
        else { return .failed }
        return .verified
    }

    private mutating func failRecovery()
        -> BootUpdateRuntimeRecoverySelectorRepairResult {
        resetRecovery()
        return .failed
    }

    private mutating func resetRecovery() {
        recoveryAction = nil
        recoveryPhase = .confirmed
        hashState = nil
    }

    private func wholeDevice() -> BorrowedBlockDeviceRegion<Device>? {
        guard let range = BlockDeviceRange(
                  startBlock: 0,
                  blockCount: device.pointee.geometry.logicalBlockCount,
                  within: device.pointee.geometry.logicalBlockCount
              )
        else { return nil }
        return BorrowedBlockDeviceRegion(
            borrowing: device,
            partitionRange: range
        )
    }

    private func selectorDevice() -> BorrowedBlockDeviceRegion<Device>? {
        BorrowedBlockDeviceRegion(
            borrowing: device,
            partitionRange: media.selector.range
        )
    }

    private func dataDevice() -> BorrowedBlockDeviceRegion<Device>? {
        BorrowedBlockDeviceRegion(
            borrowing: device,
            partitionRange: media.data.range
        )
    }
}
