/// Metadata for the one SDBG frame currently owned by the transport.
///
/// The bytes themselves remain in caller-owned storage. `remainingByteCount`
/// shrinks as a transport acknowledges partial writes, while `totalByteCount`
/// identifies the original frame boundary.
struct SDBGTransportOutboundMetadata: Equatable {
    let kind: SDBGMessageKind
    let requestID: UInt64
    let totalByteCount: Int
    let remainingByteCount: Int
}

enum SDBGTransportReceiveResult: Equatable {
    case accepted(byteCount: Int)
    /// No input was consumed. The caller can retry after pumping the session.
    case wouldBlock(requiredByteCount: Int, availableByteCount: Int)
    case rejected(SDBGStreamAppendResult)
}

enum SDBGTransportConsumeResult: Equatable {
    case consumed(byteCount: Int, remainingByteCount: Int)
    case invalidByteCount(requested: Int, available: Int)
}

enum SDBGTransportPumpResult: Equatable {
    /// A complete frame is available through `outboundBytes`.
    case outboundReady(SDBGTransportOutboundMetadata)
    /// The transport must consume the existing output before another frame can
    /// be decoded or encoded.
    case outboundBackpressured(SDBGTransportOutboundMetadata)
    case needsMoreBytes(requiredTotalByteCount: Int)
    case discardedMalformedFrame(
        rejection: SDBGDecodeRejection,
        byteCount: Int
    )
    case discardedUnexpectedMessage(
        kind: SDBGMessageKind,
        byteCount: Int
    )
    /// The runtime supplied state from a different boot than the stream's
    /// HELLO identity. The receive buffer remains untouched so the caller can
    /// retry with a coherent snapshot.
    case snapshotIdentityMismatch(
        expected: KernelIdentity128,
        actual: KernelIdentity128
    )
    case serviceRejected(SDBGServiceRejection)
}

private enum SDBGTransportDiscoveryStep {
    case hello
    case capabilities
    case complete
}

/// Allocation-free SDBG session for any reliable, ordered byte transport.
///
/// The session has deliberately no UART, USB, PCI, or network concepts. A
/// transport supplies received bytes, sends `outboundBytes`, and acknowledges
/// those bytes with `consumeOutboundBytes`. This preserves the same framing and
/// request semantics across QEMU serial, the Pi USB gadget, and a future TCP or
/// other reliable network stream.
///
/// Receive and transmit storage are caller-owned and must remain alive and at
/// fixed addresses for this value's lifetime. They must not overlap. One
/// outbound frame is retained until fully consumed, providing explicit
/// backpressure without allocation or hidden copying.
struct SDBGTransportSession {
    let bootIdentity: KernelBootIdentity
    let service: SDBGService

    private var decoder: SDBGStreamDecoder
    private let receiveStorageByteCount: Int
    private let outboundStorageBaseAddress: UInt
    private let outboundStorageByteCount: Int

    private var discoveryStep: SDBGTransportDiscoveryStep = .hello
    /// A decoded frame aliases the decoder until its next mutation. Tracking
    /// its size lets receive-side capacity account for the frame that the
    /// decoder will consume before appending more bytes.
    private var decodedFramePendingByteCount = 0

    private var outboundKind: SDBGMessageKind?
    private var outboundRequestID: UInt64 = 0
    private var outboundTotalByteCount = 0
    private var outboundConsumedByteCount = 0

    init?(
        bootIdentity: KernelBootIdentity,
        service: SDBGService = SDBGService(),
        receiveStorageBaseAddress: UInt,
        receiveStorageByteCount: Int,
        outboundStorageBaseAddress: UInt,
        outboundStorageByteCount: Int
    ) {
        let requiredReceive = SDBGProtocol.headerByteCount
            + Int(service.limits.maximumRequestPayloadByteCount)
        let requiredOutbound = SDBGProtocol.headerByteCount
            + Int(service.limits.maximumResponsePayloadByteCount)
        guard receiveStorageBaseAddress != 0,
              outboundStorageBaseAddress != 0,
              receiveStorageByteCount >= requiredReceive,
              outboundStorageByteCount >= requiredOutbound,
              UInt(receiveStorageByteCount)
                <= UInt.max - receiveStorageBaseAddress,
              UInt(outboundStorageByteCount)
                <= UInt.max - outboundStorageBaseAddress
        else { return nil }

        let receiveEnd = receiveStorageBaseAddress
            + UInt(receiveStorageByteCount)
        let outboundEnd = outboundStorageBaseAddress
            + UInt(outboundStorageByteCount)
        guard receiveEnd <= outboundStorageBaseAddress
                || outboundEnd <= receiveStorageBaseAddress,
              let decoder = SDBGStreamDecoder(
                  storageBaseAddress: receiveStorageBaseAddress,
                  storageByteCount: receiveStorageByteCount,
                  maximumPayloadByteCount: Int(
                      service.limits.maximumRequestPayloadByteCount
                  )
              )
        else { return nil }

        self.bootIdentity = bootIdentity
        self.service = service
        self.decoder = decoder
        self.receiveStorageByteCount = receiveStorageByteCount
        self.outboundStorageBaseAddress = outboundStorageBaseAddress
        self.outboundStorageByteCount = outboundStorageByteCount
    }

    var discoveryIsComplete: Bool {
        switch discoveryStep {
        // CAPABILITIES must be acknowledged by the transport, not merely
        // encoded, before negotiation is complete.
        case .complete: return outboundKind != .capabilities
        case .hello, .capabilities: return false
        }
    }

    /// Bytes still logically waiting for framing. A frame already returned by
    /// the decoder is excluded because the next decoder mutation consumes it.
    var inboundBufferedByteCount: Int {
        let pending = decodedFramePendingByteCount <= decoder.bufferedByteCount
            ? decodedFramePendingByteCount
            : decoder.bufferedByteCount
        return decoder.bufferedByteCount - pending
    }

    var inboundWritableByteCount: Int {
        receiveStorageByteCount - inboundBufferedByteCount
    }

    var pendingOutboundByteCount: Int {
        outboundTotalByteCount - outboundConsumedByteCount
    }

    var outboundMetadata: SDBGTransportOutboundMetadata? {
        guard let kind = outboundKind,
              pendingOutboundByteCount > 0
        else { return nil }
        return SDBGTransportOutboundMetadata(
            kind: kind,
            requestID: outboundRequestID,
            totalByteCount: outboundTotalByteCount,
            remainingByteCount: pendingOutboundByteCount
        )
    }

    /// A zero-copy view of the unsent suffix of the pending frame. It remains
    /// valid until the next mutating session call.
    var outboundBytes: UnsafeRawBufferPointer {
        let count = pendingOutboundByteCount
        guard count > 0,
              let base = UnsafeRawPointer(
                  bitPattern: outboundStorageBaseAddress
              )
        else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(
            start: base.advanced(by: outboundConsumedByteCount),
            count: count
        )
    }

    /// Appends one ordered stream fragment. This is all-or-none: callers can
    /// limit transport reads to `inboundWritableByteCount` to avoid retry
    /// bookkeeping.
    mutating func receive(
        _ bytes: UnsafeRawBufferPointer
    ) -> SDBGTransportReceiveResult {
        guard bytes.count == 0 || bytes.baseAddress != nil else {
            return .rejected(.invalidInput)
        }
        let available = inboundWritableByteCount
        guard bytes.count <= available else {
            return .wouldBlock(
                requiredByteCount: bytes.count,
                availableByteCount: available
            )
        }
        guard bytes.count != 0 else { return .accepted(byteCount: 0) }

        // `append` first releases the previously returned decoder frame.
        decodedFramePendingByteCount = 0
        let result = decoder.append(bytes)
        switch result {
        case .appended:
            return .accepted(byteCount: bytes.count)
        case .invalidInput, .capacityExceeded:
            return .rejected(result)
        }
    }

    /// Advances discovery or handles at most one receive-side decoder event.
    /// Repeated calls drain coalesced frames. A response is never written over
    /// a partially transmitted frame.
    mutating func pump(
        snapshot: SDBGServiceSnapshot,
        lookupLogEntry: (UInt64) -> KernelLogLookupResult
    ) -> SDBGTransportPumpResult {
        if let metadata = outboundMetadata {
            return .outboundBackpressured(metadata)
        }

        switch discoveryStep {
        case .hello:
            return emitDiscoveryFrame(kind: .hello)
        case .capabilities:
            return emitDiscoveryFrame(kind: .capabilities)
        case .complete:
            break
        }

        guard snapshot.bootIdentity == bootIdentity else {
            return .snapshotIdentityMismatch(
                expected: bootIdentity.sessionID,
                actual: snapshot.bootIdentity.sessionID
            )
        }

        // `pump` first releases any frame returned on the previous call.
        decodedFramePendingByteCount = 0
        switch decoder.pump() {
        case .needsMoreBytes(let required):
            return .needsMoreBytes(requiredTotalByteCount: required)
        case .discarded(let rejection, let byteCount):
            return .discardedMalformedFrame(
                rejection: rejection,
                byteCount: byteCount
            )
        case .frame(let frame):
            decodedFramePendingByteCount = frame.encodedByteCount
            guard frame.envelope.kind == .request else {
                return .discardedUnexpectedMessage(
                    kind: frame.envelope.kind,
                    byteCount: frame.encodedByteCount
                )
            }
            let result = service.handleRequest(
                frame,
                snapshot: snapshot,
                lookupLogEntry: lookupLogEntry,
                into: mutableOutboundStorage
            )
            switch result {
            case .emitted(let byteCount):
                setPendingOutbound(
                    kind: .response,
                    requestID: frame.envelope.requestID,
                    byteCount: byteCount
                )
                return .outboundReady(outboundMetadata!)
            case .rejected(let rejection):
                return .serviceRejected(rejection)
            }
        }
    }

    /// Acknowledges a successfully written prefix of `outboundBytes`.
    mutating func consumeOutboundBytes(
        _ byteCount: Int
    ) -> SDBGTransportConsumeResult {
        let available = pendingOutboundByteCount
        guard byteCount >= 0, byteCount <= available else {
            return .invalidByteCount(
                requested: byteCount,
                available: available
            )
        }
        outboundConsumedByteCount += byteCount
        let remaining = pendingOutboundByteCount
        if remaining == 0 {
            clearPendingOutbound()
        }
        return .consumed(
            byteCount: byteCount,
            remainingByteCount: remaining
        )
    }

    /// Starts a fresh ordered stream after disconnect or transport reset. The
    /// boot identity is deliberately preserved; HELLO and CAPABILITIES are
    /// emitted again so a new host can identify the same running kernel.
    mutating func resetStream() {
        decoder.reset()
        decodedFramePendingByteCount = 0
        clearPendingOutbound()
        discoveryStep = .hello
    }

    private var mutableOutboundStorage: UnsafeMutableRawBufferPointer {
        guard let base = UnsafeMutableRawPointer(
            bitPattern: outboundStorageBaseAddress
        ) else {
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeMutableRawBufferPointer(
            start: base,
            count: outboundStorageByteCount
        )
    }

    private mutating func emitDiscoveryFrame(
        kind: SDBGMessageKind
    ) -> SDBGTransportPumpResult {
        let result: SDBGServiceResult
        switch kind {
        case .hello:
            result = service.emitHello(
                identity: bootIdentity,
                into: mutableOutboundStorage
            )
        case .capabilities:
            result = service.emitCapabilities(
                identity: bootIdentity,
                into: mutableOutboundStorage
            )
        case .request, .response, .event, .logChunk:
            // Only the private discovery state calls this helper.
            return .serviceRejected(.invalidMessageKind(kind))
        }

        switch result {
        case .emitted(let byteCount):
            setPendingOutbound(
                kind: kind,
                requestID: 0,
                byteCount: byteCount
            )
            switch kind {
            case .hello:
                discoveryStep = .capabilities
            case .capabilities:
                discoveryStep = .complete
            case .request, .response, .event, .logChunk:
                break
            }
            return .outboundReady(outboundMetadata!)
        case .rejected(let rejection):
            return .serviceRejected(rejection)
        }
    }

    private mutating func setPendingOutbound(
        kind: SDBGMessageKind,
        requestID: UInt64,
        byteCount: Int
    ) {
        outboundKind = kind
        outboundRequestID = requestID
        outboundTotalByteCount = byteCount
        outboundConsumedByteCount = 0
    }

    private mutating func clearPendingOutbound() {
        outboundKind = nil
        outboundRequestID = 0
        outboundTotalByteCount = 0
        outboundConsumedByteCount = 0
    }
}
