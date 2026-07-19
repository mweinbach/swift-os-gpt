/// Caller-owned inactive RAM used to stage one verified kernel image.
///
/// The region is deliberately capped at the first platform contract's 16 MiB
/// raw-image limit. It does not describe the destination address and is never
/// made executable by this transport layer.
struct USBKernelUpdateRAMStagingRegion: Equatable {
    static let maximumByteCount: UInt64 = 16 * 1_024 * 1_024

    let baseAddress: UInt64
    let byteCount: UInt64

    init?(baseAddress: UInt64, byteCount: UInt64) {
        guard baseAddress <= UInt64(UInt.max),
              byteCount > 0,
              byteCount <= Self.maximumByteCount,
              byteCount <= UInt64(Int.max),
              byteCount <= UInt64.max - baseAddress
        else { return nil }
        self.baseAddress = baseAddress
        self.byteCount = byteCount
    }
}

/// Platform metadata sealed only after both SUPD integrity checks and the
/// machine's structural image checks have succeeded.
enum USBKernelUpdateValidatedImageMetadata: Equatable {
    case raspberryPi5(RaspberryPiKernelImageMetadata)
}

struct USBKernelUpdateSealedArtifact: Equatable {
    let descriptor: USBKernelUpdateDescriptor
    let stagingRegion: USBKernelUpdateRAMStagingRegion
    let imageMetadata: USBKernelUpdateValidatedImageMetadata
}

/// Allocation-free RAM sink. `sealValidated` only seals metadata; it never
/// copies over the running image, changes boot selection, or transfers control.
struct USBKernelUpdateRAMStagingSink: USBKernelUpdateStagingSink {
    let region: USBKernelUpdateRAMStagingRegion

    private(set) var activeDescriptor: USBKernelUpdateDescriptor?
    private(set) var sealedArtifact: USBKernelUpdateSealedArtifact?

    mutating func beginStaging(
        _ descriptor: USBKernelUpdateDescriptor
    ) -> Bool {
        guard descriptor.totalLength > 0,
              descriptor.totalLength <= region.byteCount
        else { return false }
        activeDescriptor = descriptor
        sealedArtifact = nil
        return true
    }

    mutating func writeStagedBytes(
        _ bytes: UnsafeRawBufferPointer,
        transferID: UInt32,
        at offset: UInt64
    ) -> Bool {
        guard let activeDescriptor,
              activeDescriptor.transferID == transferID,
              offset <= activeDescriptor.totalLength,
              UInt64(bytes.count) <= activeDescriptor.totalLength - offset,
              offset <= region.byteCount,
              UInt64(bytes.count) <= region.byteCount - offset,
              bytes.count == 0 || bytes.baseAddress != nil,
              let destinationBase = UnsafeMutableRawPointer(
                  bitPattern: UInt(region.baseAddress)
              )
        else { return false }

        let destination = destinationBase.advanced(by: Int(offset))
        var index = 0
        while index < bytes.count {
            destination.storeBytes(
                of: bytes[index],
                toByteOffset: index,
                as: UInt8.self
            )
            index += 1
        }
        return true
    }

    mutating func sealValidated(
        _ descriptor: USBKernelUpdateDescriptor
    ) -> Bool {
        guard descriptor == activeDescriptor,
              descriptor.totalLength <= UInt64(Int.max),
              let baseAddress = UnsafeRawPointer(
                  bitPattern: UInt(region.baseAddress)
              )
        else { return false }

        let image = UnsafeRawBufferPointer(
            start: baseAddress,
            count: Int(descriptor.totalLength)
        )
        let metadata: USBKernelUpdateValidatedImageMetadata
        switch descriptor.targetMachine {
        case .raspberryPi5:
            guard case .accepted(let piMetadata) =
                    RaspberryPiKernelImageValidator.validate(image)
            else { return false }
            metadata = .raspberryPi5(piMetadata)
        case .qemuVirtAArch64:
            // A QEMU activation image contract has not been defined yet.
            return false
        }
        sealedArtifact = USBKernelUpdateSealedArtifact(
            descriptor: descriptor,
            stagingRegion: region,
            imageMetadata: metadata
        )
        return true
    }

    mutating func discardStaging(transferID: UInt32) {
        guard activeDescriptor?.transferID == transferID else { return }
        activeDescriptor = nil
        sealedArtifact = nil
    }
}

enum USBKernelUpdateStreamAppendResult: Equatable {
    case appended
    case invalidInput
    case capacityExceeded
}

enum USBKernelUpdateStreamPumpResult {
    case needsMoreBytes
    case response(USBKernelUpdateTransportResponse)
}

struct USBKernelUpdateTransportResponse {
    let transferID: UInt32
    let status: USBKernelUpdateStatus
    /// Non-nil only when this response reports a structurally valid committed
    /// artifact. The USB gadget must still wait for this STATUS IN transfer to
    /// complete before exposing the artifact to activation policy.
    let committedArtifact: USBKernelUpdateSealedArtifact?
}

/// Bounded byte-stream framing for SUPD. It accepts frames split across
/// full-speed 64-byte transfers, coalesced frames, and arbitrary leading
/// garbage while retaining at most a three-byte split magic prefix during
/// recovery.
struct USBKernelUpdateStreamReceiver {
    static let maximumTransportPacketByteCount = 512
    static let maximumAcceptedFrameByteCount =
        USBKernelUpdateProtocol.headerByteCount
            + USBKernelUpdateProtocol.dataPrefixByteCount
            + Int(USBKernelUpdateProtocol.maximumAcceptedChunkByteCount)
    static let minimumStorageByteCount = maximumAcceptedFrameByteCount
        + maximumTransportPacketByteCount

    private let storageBaseAddress: UInt
    private let storageByteCount: Int
    private(set) var bufferedByteCount = 0
    private var receiver: USBKernelUpdateReceiver
    private var sink: USBKernelUpdateRAMStagingSink

    init?(
        storageBaseAddress: UInt64,
        storageByteCount: UInt64,
        targetMachine: USBKernelUpdateTargetMachine,
        stagingRegion: USBKernelUpdateRAMStagingRegion
    ) {
        guard storageBaseAddress <= UInt64(UInt.max),
              storageByteCount >= UInt64(Self.minimumStorageByteCount),
              storageByteCount <= UInt64(Int.max),
              storageByteCount <= UInt64.max - storageBaseAddress,
              let receiver = USBKernelUpdateReceiver(
                  targetMachine: targetMachine,
                  maximumArtifactByteCount: stagingRegion.byteCount,
                  maximumChunkByteCount:
                      USBKernelUpdateProtocol.maximumAcceptedChunkByteCount
              )
        else { return nil }
        self.storageBaseAddress = UInt(storageBaseAddress)
        self.storageByteCount = Int(storageByteCount)
        self.receiver = receiver
        sink = USBKernelUpdateRAMStagingSink(region: stagingRegion)
    }

    mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> USBKernelUpdateStreamAppendResult {
        guard bytes.count == 0 || bytes.baseAddress != nil,
              bytes.count <= Self.maximumTransportPacketByteCount
        else { return .invalidInput }
        guard bytes.count <= storageByteCount - bufferedByteCount,
              let destination = UnsafeMutableRawPointer(
                  bitPattern: storageBaseAddress
              )
        else { return .capacityExceeded }

        var index = 0
        while index < bytes.count {
            destination.storeBytes(
                of: bytes[index],
                toByteOffset: bufferedByteCount + index,
                as: UInt8.self
            )
            index += 1
        }
        bufferedByteCount += bytes.count
        return .appended
    }

    /// Produces at most one STATUS response. Call again after that response is
    /// transmitted to drain a coalesced second frame without accepting more
    /// OUT traffic in between.
    mutating func pump() -> USBKernelUpdateStreamPumpResult {
        var remainingRecoverySteps = bufferedByteCount + 1
        while remainingRecoverySteps > 0 {
            remainingRecoverySteps -= 1
            let input = storageBuffer
            switch USBKernelUpdatePacketDecoder.decodePrefix(input) {
            case .needMoreBytes(let requiredTotalByteCount):
                if requiredTotalByteCount
                    <= Self.maximumAcceptedFrameByteCount {
                    return .needsMoreBytes
                }
                let transferID = recoverableTransferID(in: input)
                discardMalformedPrefix(input)
                if let transferID {
                    return .response(
                        malformedResponse(
                            transferID: transferID,
                            code: .malformedFrame,
                            detail: UInt32(
                                truncatingIfNeeded: requiredTotalByteCount
                            )
                        )
                    )
                }

            case .rejected(let rejection, let discardByteCount):
                let transferID = recoverableTransferID(in: input)
                consume(discardByteCount)
                if let transferID {
                    let statusCode: USBKernelUpdateStatusCode
                    switch rejection {
                    case .unsupportedVersion:
                        statusCode = .unsupportedVersion
                    case .packetChecksumMismatch:
                        statusCode = .checksumMismatch
                    case .invalidMagic, .unknownMessageKind, .nonzeroFlags,
                         .zeroTransferID, .payloadTooLarge, .malformedPayload:
                        statusCode = .malformedFrame
                    }
                    return .response(
                        malformedResponse(
                            transferID: transferID,
                            code: statusCode,
                            detail: 0
                        )
                    )
                }

            case .decoded(let packet):
                let result = receiver.accept(packet, sink: &sink)
                let status: USBKernelUpdateStatus
                switch result {
                case .accepted(_, let acceptedStatus):
                    status = acceptedStatus
                case .rejected(_, let rejectedStatus):
                    status = rejectedStatus
                }
                let committedArtifact = status.code == .committed
                    ? sink.sealedArtifact : nil
                consume(packet.encodedByteCount)
                return .response(
                    USBKernelUpdateTransportResponse(
                        transferID: packet.transferID,
                        status: status,
                        committedArtifact: committedArtifact
                    )
                )
            }
        }
        // Every recovery step consumes at least one byte. Reaching this point
        // therefore means the buffer is empty or contains only an incomplete
        // magic prefix.
        return .needsMoreBytes
    }

    /// Drops only transport framing. Receiver and staged bytes intentionally
    /// survive a USB reset so an identical BEGIN can negotiate resume.
    mutating func resetTransport() {
        bufferedByteCount = 0
    }

    private var storageBuffer: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(
            start: UnsafeRawPointer(bitPattern: storageBaseAddress),
            count: bufferedByteCount
        )
    }

    private mutating func discardMalformedPrefix(
        _ input: UnsafeRawBufferPointer
    ) {
        guard input.count > 0 else { return }
        // A valid SUPD frame is at most 496 bytes. For an oversized declared
        // frame, scan the bytes already present for a later magic and otherwise
        // retain only a possible split three-byte prefix.
        var offset = 1
        while offset + 4 <= input.count {
            if readUInt32(input, at: offset)
                == USBKernelUpdateProtocol.magic {
                consume(offset)
                return
            }
            offset += 1
        }
        consume(input.count > 3 ? input.count - 3 : 1)
    }

    private mutating func consume(_ requestedByteCount: Int) {
        let byteCount = requestedByteCount < bufferedByteCount
            ? requestedByteCount : bufferedByteCount
        guard byteCount > 0,
              let storage = UnsafeMutableRawPointer(
                  bitPattern: storageBaseAddress
              )
        else { return }
        let remaining = bufferedByteCount - byteCount
        var index = 0
        while index < remaining {
            let byte = storage.load(
                fromByteOffset: byteCount + index,
                as: UInt8.self
            )
            storage.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
            index += 1
        }
        bufferedByteCount = remaining
    }

    private func malformedResponse(
        transferID: UInt32,
        code: USBKernelUpdateStatusCode,
        detail: UInt32
    ) -> USBKernelUpdateTransportResponse {
        let current = receiver.status()
        return USBKernelUpdateTransportResponse(
            transferID: transferID,
            status: USBKernelUpdateStatus(
                code: code,
                phase: current.phase,
                nextOffset: current.nextOffset,
                acceptedChunkByteCount: current.acceptedChunkByteCount,
                detail: detail
            ),
            committedArtifact: nil
        )
    }

    private func recoverableTransferID(
        in input: UnsafeRawBufferPointer
    ) -> UInt32? {
        guard input.count >= 12,
              readUInt32(input, at: 0) == USBKernelUpdateProtocol.magic
        else { return nil }
        let transferID = readUInt32(input, at: 8)
        return transferID == 0 ? nil : transferID
    }

    private func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
