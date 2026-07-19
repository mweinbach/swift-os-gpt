/// Immutable description of the inactive artifact a storage backend stages.
struct USBKernelUpdateDescriptor: Equatable {
    let transferID: UInt32
    let artifactKind: USBKernelUpdateArtifactKind
    let targetMachine: USBKernelUpdateTargetMachine
    let totalLength: UInt64
    let chunkByteCount: UInt32
    let totalChunkCount: UInt32
    let sha256: USBKernelUpdateSHA256Digest
    let imageCRC32: UInt32
}

/// Storage boundary for USB update reception.
///
/// `beginStaging` and `writeStagedBytes` must address an inactive staging area.
/// They must never overwrite the running kernel or change boot selection.
/// `sealValidated` records that exact length, sequence, SHA-256, and whole-image
/// CRC integrity checks succeeded; it must not activate the artifact. Byte
/// buffers are borrowed only for the duration of each call.
protocol USBKernelUpdateStagingSink {
    mutating func beginStaging(
        _ descriptor: USBKernelUpdateDescriptor
    ) -> Bool

    mutating func writeStagedBytes(
        _ bytes: UnsafeRawBufferPointer,
        transferID: UInt32,
        at offset: UInt64
    ) -> Bool

    mutating func sealValidated(
        _ descriptor: USBKernelUpdateDescriptor
    ) -> Bool

    mutating func discardStaging(transferID: UInt32)
}

enum USBKernelUpdateReceiverPhase: UInt8, Equatable {
    case idle
    case receiving
    case committed
    case rejected
}

enum USBKernelUpdateReceiverEvent: Equatable {
    case transferAccepted(USBKernelUpdateDescriptor)
    case transferResumed(nextOffset: UInt64)
    case chunkStaged(sequence: UInt32, nextOffset: UInt64)
    case chunkReplayAcknowledged(sequence: UInt32, nextOffset: UInt64)
    case transferCommitted(USBKernelUpdateDescriptor)
    case transferAborted(reason: UInt32)
}

enum USBKernelUpdateReceiverRejection: Equatable {
    case unexpectedMessage(
        phase: USBKernelUpdateReceiverPhase,
        kind: USBKernelUpdateMessageKind
    )
    case busy(activeTransferID: UInt32)
    case wrongTarget(
        expected: USBKernelUpdateTargetMachine,
        actual: USBKernelUpdateTargetMachine
    )
    case artifactTooLarge(requested: UInt64, maximum: UInt64)
    case invalidBeginSequence(UInt32)
    case transferMismatch(expected: UInt32, actual: UInt32)
    case sequenceMismatch(expected: UInt32, actual: UInt32)
    case offsetMismatch(expected: UInt64, actual: UInt64)
    case chunkLengthMismatch(expected: UInt32, actual: Int)
    case replayedChunkMismatch(sequence: UInt32)
    case incompleteTransfer(expected: UInt64, actual: UInt64)
    case commitMetadataMismatch
    case sha256Mismatch
    case imageCRC32Mismatch(expected: UInt32, actual: UInt32)
    case stagingRejected
    case stagingWriteFailed
    case sealFailed
}

enum USBKernelUpdateReceiverResult: Equatable {
    case accepted(
        event: USBKernelUpdateReceiverEvent,
        status: USBKernelUpdateStatus
    )
    case rejected(
        USBKernelUpdateReceiverRejection,
        status: USBKernelUpdateStatus
    )
}

/// Strict, bounded semantic receiver. Wire framing and per-packet CRC checks
/// happen in `USBKernelUpdatePacketDecoder` before a packet reaches this type.
struct USBKernelUpdateReceiver {
    let targetMachine: USBKernelUpdateTargetMachine
    let maximumArtifactByteCount: UInt64
    let maximumChunkByteCount: UInt32

    private(set) var phase: USBKernelUpdateReceiverPhase = .idle
    private(set) var activeDescriptor: USBKernelUpdateDescriptor?
    private(set) var nextOffset: UInt64 = 0

    private var activeBegin: USBKernelUpdateBegin?
    private var nextDataSequence: UInt32 = 1
    private var lastAcceptedDataSequence: UInt32 = 0
    private var lastAcceptedDataOffset: UInt64 = 0
    private var lastAcceptedDataByteCount: UInt32 = 0
    private var lastAcceptedDataSHA256: USBKernelUpdateSHA256Digest?
    private var sha256 = USBKernelUpdateSHA256()
    private var imageCRC32 = USBKernelUpdateCRC32()
    private var stagingIsLive = false
    private var lastStatusCode = USBKernelUpdateStatusCode.ready
    private var lastDetail: UInt32 = 0

    init?(
        targetMachine: USBKernelUpdateTargetMachine,
        maximumArtifactByteCount: UInt64 =
            USBKernelUpdateProtocol.maximumArtifactByteCount,
        maximumChunkByteCount: UInt32 =
            USBKernelUpdateProtocol.maximumAcceptedChunkByteCount
    ) {
        guard maximumArtifactByteCount > 0,
              maximumArtifactByteCount
                <= USBKernelUpdateProtocol.maximumArtifactByteCount,
              maximumChunkByteCount
                >= USBKernelUpdateProtocol.minimumChunkByteCount,
              maximumChunkByteCount
                <= USBKernelUpdateProtocol.maximumAcceptedChunkByteCount
        else { return nil }
        self.targetMachine = targetMachine
        self.maximumArtifactByteCount = maximumArtifactByteCount
        self.maximumChunkByteCount = maximumChunkByteCount
    }

    /// Accepts one completely decoded packet and returns the STATUS payload the
    /// transport should send with sequence zero and the same transfer ID.
    mutating func accept<Sink: USBKernelUpdateStagingSink>(
        _ packet: USBKernelUpdateDecodedPacket,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        switch packet.message {
        case .begin(let begin):
            return acceptBegin(packet, begin: begin, sink: &sink)
        case .data(let data):
            return acceptData(packet, data: data, sink: &sink)
        case .commit(let commit):
            return acceptCommit(packet, commit: commit, sink: &sink)
        case .abort(let abort):
            return acceptAbort(packet, abort: abort, sink: &sink)
        case .status:
            return nonfatalRejection(
                .unexpectedMessage(phase: phase, kind: .status),
                code: .malformedFrame,
                detail: UInt32(USBKernelUpdateMessageKind.status.rawValue)
            )
        }
    }

    /// Explicit administrative reset for a controller teardown. A mere USB
    /// disconnect need not call this, allowing a host to resume via BEGIN.
    mutating func discardAndReset<Sink: USBKernelUpdateStagingSink>(
        sink: inout Sink
    ) {
        discardIfNeeded(sink: &sink)
        clearTransfer()
    }

    /// Current transport-neutral status snapshot, useful after reconnect.
    func status() -> USBKernelUpdateStatus {
        makeStatus(code: lastStatusCode, detail: lastDetail)
    }

    private mutating func acceptBegin<Sink: USBKernelUpdateStagingSink>(
        _ packet: USBKernelUpdateDecodedPacket,
        begin: USBKernelUpdateBegin,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        guard packet.sequence == 0 else {
            return fatalRejection(
                .invalidBeginSequence(packet.sequence),
                code: .invalidOffset,
                detail: packet.sequence,
                sink: &sink
            )
        }
        guard begin.targetMachine == targetMachine else {
            return nonfatalRejection(
                .wrongTarget(
                    expected: targetMachine,
                    actual: begin.targetMachine
                ),
                code: .unsupportedTarget,
                detail: UInt32(begin.targetMachine.rawValue)
            )
        }
        guard begin.totalLength <= maximumArtifactByteCount else {
            return nonfatalRejection(
                .artifactTooLarge(
                    requested: begin.totalLength,
                    maximum: maximumArtifactByteCount
                ),
                code: .malformedFrame,
                detail: UInt32(truncatingIfNeeded: begin.totalLength)
            )
        }

        if phase == .receiving {
            guard packet.transferID == activeDescriptor?.transferID,
                  begin == activeBegin
            else {
                return nonfatalRejection(
                    .busy(activeTransferID: activeDescriptor?.transferID ?? 0),
                    code: .busy,
                    detail: activeDescriptor?.transferID ?? 0
                )
            }
            lastStatusCode = nextOffset == 0 ? .accepted : .progress
            lastDetail = nextDataSequence
            return .accepted(
                event: .transferResumed(nextOffset: nextOffset),
                status: status()
            )
        }

        if phase == .rejected {
            return nonfatalRejection(
                .busy(activeTransferID: activeDescriptor?.transferID ?? 0),
                code: .busy,
                detail: activeDescriptor?.transferID ?? 0
            )
        }

        if phase == .committed,
           packet.transferID == activeDescriptor?.transferID,
           begin == activeBegin {
            return .accepted(
                event: .transferResumed(nextOffset: nextOffset),
                status: status()
            )
        }

        let acceptedChunkByteCount = begin.chunkByteCount
            < maximumChunkByteCount
            ? begin.chunkByteCount : maximumChunkByteCount
        guard let totalChunkCount = Self.chunkCount(
                  totalLength: begin.totalLength,
                  chunkByteCount: acceptedChunkByteCount
              )
        else {
            return nonfatalRejection(
                .artifactTooLarge(
                    requested: begin.totalLength,
                    maximum: maximumArtifactByteCount
                ),
                code: .malformedFrame,
                detail: UInt32(truncatingIfNeeded: begin.totalLength)
            )
        }
        let descriptor = USBKernelUpdateDescriptor(
            transferID: packet.transferID,
            artifactKind: begin.artifactKind,
            targetMachine: begin.targetMachine,
            totalLength: begin.totalLength,
            chunkByteCount: acceptedChunkByteCount,
            totalChunkCount: totalChunkCount,
            sha256: begin.sha256,
            imageCRC32: begin.imageCRC32
        )

        // A committed transfer is no longer live, so replacing its metadata
        // does not discard or mutate the sealed artifact.
        clearTransfer()
        activeBegin = begin
        activeDescriptor = descriptor
        guard sink.beginStaging(descriptor) else {
            phase = .rejected
            lastStatusCode = .storageFailure
            return .rejected(
                .stagingRejected,
                status: makeStatus(code: .storageFailure, detail: 0)
            )
        }
        stagingIsLive = true
        phase = .receiving
        lastStatusCode = .accepted
        lastDetail = totalChunkCount
        return .accepted(
            event: .transferAccepted(descriptor),
            status: status()
        )
    }

    private mutating func acceptData<Sink: USBKernelUpdateStagingSink>(
        _ packet: USBKernelUpdateDecodedPacket,
        data: USBKernelUpdateData,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        guard phase == .receiving, let descriptor = activeDescriptor else {
            return nonfatalRejection(
                .unexpectedMessage(phase: phase, kind: .data),
                code: .busy,
                detail: activeDescriptor?.transferID ?? 0
            )
        }
        guard packet.transferID == descriptor.transferID else {
            return nonfatalRejection(
                .transferMismatch(
                    expected: descriptor.transferID,
                    actual: packet.transferID
                ),
                code: .busy,
                detail: descriptor.transferID
            )
        }

        if packet.sequence == lastAcceptedDataSequence,
           packet.sequence != 0,
           data.offset == lastAcceptedDataOffset,
           data.bytes.count == Int(lastAcceptedDataByteCount) {
            var replaySHA256 = USBKernelUpdateSHA256()
            guard replaySHA256.update(data.bytes),
                  replaySHA256.finalizedDigest() == lastAcceptedDataSHA256
            else {
                return fatalRejection(
                    .replayedChunkMismatch(sequence: packet.sequence),
                    code: .checksumMismatch,
                    detail: packet.sequence,
                    sink: &sink
                )
            }
            // The original packet was already hashed and staged. Reply with
            // the durable offset without writing or hashing it a second time.
            lastStatusCode = .progress
            lastDetail = nextDataSequence
            return .accepted(
                event: .chunkReplayAcknowledged(
                    sequence: packet.sequence,
                    nextOffset: nextOffset
                ),
                status: status()
            )
        }
        guard packet.sequence == nextDataSequence else {
            return fatalRejection(
                .sequenceMismatch(
                    expected: nextDataSequence,
                    actual: packet.sequence
                ),
                code: .invalidOffset,
                detail: packet.sequence,
                sink: &sink
            )
        }
        guard data.offset == nextOffset else {
            return fatalRejection(
                .offsetMismatch(expected: nextOffset, actual: data.offset),
                code: .invalidOffset,
                detail: UInt32(truncatingIfNeeded: data.offset),
                sink: &sink
            )
        }
        let remaining = descriptor.totalLength - nextOffset
        let configuredChunk = UInt64(descriptor.chunkByteCount)
        let expectedByteCount = UInt32(
            configuredChunk < remaining ? configuredChunk : remaining
        )
        guard data.bytes.count == Int(expectedByteCount) else {
            return fatalRejection(
                .chunkLengthMismatch(
                    expected: expectedByteCount,
                    actual: data.bytes.count
                ),
                code: .invalidOffset,
                detail: UInt32(truncatingIfNeeded: data.bytes.count),
                sink: &sink
            )
        }

        // Hash before handing the bytes to storage. Every representable update
        // is far below SHA-256's bit-length limit, so failure is unreachable
        // after the receiver's artifact bound has been enforced.
        var chunkSHA256 = USBKernelUpdateSHA256()
        guard chunkSHA256.update(data.bytes), sha256.update(data.bytes) else {
            return fatalRejection(
                .stagingWriteFailed,
                code: .storageFailure,
                detail: packet.sequence,
                sink: &sink
            )
        }
        imageCRC32.update(data.bytes)
        guard sink.writeStagedBytes(
                  data.bytes,
                  transferID: descriptor.transferID,
                  at: data.offset
              )
        else {
            return fatalRejection(
                .stagingWriteFailed,
                code: .storageFailure,
                detail: packet.sequence,
                sink: &sink
            )
        }

        nextOffset += UInt64(expectedByteCount)
        lastAcceptedDataSequence = packet.sequence
        lastAcceptedDataOffset = data.offset
        lastAcceptedDataByteCount = expectedByteCount
        lastAcceptedDataSHA256 = chunkSHA256.finalizedDigest()
        nextDataSequence &+= 1
        lastStatusCode = .progress
        lastDetail = nextDataSequence
        return .accepted(
            event: .chunkStaged(
                sequence: packet.sequence,
                nextOffset: nextOffset
            ),
            status: status()
        )
    }

    private mutating func acceptCommit<Sink: USBKernelUpdateStagingSink>(
        _ packet: USBKernelUpdateDecodedPacket,
        commit: USBKernelUpdateCommit,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        guard phase == .receiving, let descriptor = activeDescriptor else {
            return nonfatalRejection(
                .unexpectedMessage(phase: phase, kind: .commit),
                code: .busy,
                detail: activeDescriptor?.transferID ?? 0
            )
        }
        guard packet.transferID == descriptor.transferID else {
            return nonfatalRejection(
                .transferMismatch(
                    expected: descriptor.transferID,
                    actual: packet.transferID
                ),
                code: .busy,
                detail: descriptor.transferID
            )
        }
        let expectedCommitSequence = descriptor.totalChunkCount &+ 1
        guard packet.sequence == expectedCommitSequence else {
            return fatalRejection(
                .sequenceMismatch(
                    expected: expectedCommitSequence,
                    actual: packet.sequence
                ),
                code: .invalidOffset,
                detail: packet.sequence,
                sink: &sink
            )
        }
        guard nextOffset == descriptor.totalLength,
              nextDataSequence == expectedCommitSequence
        else {
            return fatalRejection(
                .incompleteTransfer(
                    expected: descriptor.totalLength,
                    actual: nextOffset
                ),
                code: .invalidOffset,
                detail: UInt32(truncatingIfNeeded: nextOffset),
                sink: &sink
            )
        }
        guard commit.totalLength == descriptor.totalLength,
              commit.sha256 == descriptor.sha256
        else {
            return fatalRejection(
                .commitMetadataMismatch,
                code: .checksumMismatch,
                detail: 0,
                sink: &sink
            )
        }

        lastStatusCode = .verified
        guard sha256.finalizedDigest() == descriptor.sha256 else {
            return fatalRejection(
                .sha256Mismatch,
                code: .checksumMismatch,
                detail: 1,
                sink: &sink
            )
        }
        guard imageCRC32.value == descriptor.imageCRC32 else {
            return fatalRejection(
                .imageCRC32Mismatch(
                    expected: descriptor.imageCRC32,
                    actual: imageCRC32.value
                ),
                code: .checksumMismatch,
                detail: 2,
                sink: &sink
            )
        }

        // Integrity verification only seals the inactive staging metadata.
        // Activation and boot-selection policy are deliberately outside this
        // receiver.
        guard sink.sealValidated(descriptor) else {
            return fatalRejection(
                .sealFailed,
                code: .storageFailure,
                detail: 3,
                sink: &sink
            )
        }
        stagingIsLive = false
        phase = .committed
        lastStatusCode = .committed
        lastDetail = descriptor.totalChunkCount
        return .accepted(
            event: .transferCommitted(descriptor),
            status: status()
        )
    }

    private mutating func acceptAbort<Sink: USBKernelUpdateStagingSink>(
        _ packet: USBKernelUpdateDecodedPacket,
        abort: USBKernelUpdateAbort,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        guard packet.sequence == 0 else {
            return nonfatalRejection(
                .sequenceMismatch(expected: 0, actual: packet.sequence),
                code: .invalidOffset,
                detail: packet.sequence
            )
        }
        if let descriptor = activeDescriptor,
           packet.transferID != descriptor.transferID {
            return nonfatalRejection(
                .transferMismatch(
                    expected: descriptor.transferID,
                    actual: packet.transferID
                ),
                code: .busy,
                detail: descriptor.transferID
            )
        }
        discardIfNeeded(sink: &sink)
        clearTransfer()
        // An abort acknowledgement is intentionally an error-class STATUS so
        // an uploader cannot mistake it for a committed update.
        let status = USBKernelUpdateStatus(
            code: .aborted,
            phase: .idle,
            nextOffset: 0,
            acceptedChunkByteCount: maximumChunkByteCount,
            detail: abort.reason
        )
        return .accepted(
            event: .transferAborted(reason: abort.reason),
            status: status
        )
    }

    private mutating func fatalRejection<Sink: USBKernelUpdateStagingSink>(
        _ rejection: USBKernelUpdateReceiverRejection,
        code: USBKernelUpdateStatusCode,
        detail: UInt32,
        sink: inout Sink
    ) -> USBKernelUpdateReceiverResult {
        discardIfNeeded(sink: &sink)
        phase = .rejected
        lastStatusCode = code
        lastDetail = detail
        return .rejected(rejection, status: status())
    }

    private func nonfatalRejection(
        _ rejection: USBKernelUpdateReceiverRejection,
        code: USBKernelUpdateStatusCode,
        detail: UInt32
    ) -> USBKernelUpdateReceiverResult {
        .rejected(
            rejection,
            status: makeStatus(code: code, detail: detail)
        )
    }

    private func makeStatus(
        code: USBKernelUpdateStatusCode,
        detail: UInt32
    ) -> USBKernelUpdateStatus {
        let statusPhase: USBKernelUpdateStatusPhase
        switch phase {
        case .idle: statusPhase = .idle
        case .receiving: statusPhase = .receiving
        case .committed: statusPhase = .committed
        case .rejected: statusPhase = .rejected
        }
        return USBKernelUpdateStatus(
            code: code,
            phase: statusPhase,
            nextOffset: nextOffset,
            acceptedChunkByteCount:
                activeDescriptor?.chunkByteCount ?? maximumChunkByteCount,
            detail: detail
        )
    }

    private mutating func discardIfNeeded<
        Sink: USBKernelUpdateStagingSink
    >(sink: inout Sink) {
        if stagingIsLive, let descriptor = activeDescriptor {
            sink.discardStaging(transferID: descriptor.transferID)
        }
        stagingIsLive = false
    }

    private mutating func clearTransfer() {
        phase = .idle
        activeBegin = nil
        activeDescriptor = nil
        nextOffset = 0
        nextDataSequence = 1
        lastAcceptedDataSequence = 0
        lastAcceptedDataOffset = 0
        lastAcceptedDataByteCount = 0
        lastAcceptedDataSHA256 = nil
        sha256 = USBKernelUpdateSHA256()
        imageCRC32 = USBKernelUpdateCRC32()
        stagingIsLive = false
        lastStatusCode = .ready
        lastDetail = 0
    }

    private static func chunkCount(
        totalLength: UInt64,
        chunkByteCount: UInt32
    ) -> UInt32? {
        let chunk = UInt64(chunkByteCount)
        let count = totalLength / chunk
            + (totalLength % chunk == 0 ? 0 : 1)
        guard count > 0, count < UInt64(UInt32.max) else { return nil }
        return UInt32(count)
    }
}
