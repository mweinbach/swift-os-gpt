/// Any ordered byte transport can back the SDBG client. A serial adapter, a
/// USB bulk adapter, and a connected UDP adapter only need to implement this
/// single write boundary and feed received bytes back through `receive`.
protocol SwiftOSSDBGHostTransport {
    func send(_ frame: [UInt8]) throws
}

enum SwiftOSSDBGHostClientError: Error, Equatable {
    case handshakeIncomplete
    case unsupportedOperation(SDBGOperation)
    case invalidRequestArgument(field: UInt16)
    case invalidTimeout
    case pendingRequestLimitReached(Int)
    case requestIDExhausted
    case requestEncodingFailed
}

enum SwiftOSSDBGHostTransactionResult: Equatable {
    case identity(KernelBootIdentity)
    case status(DebugStatusSnapshot)
    case ping(token: UInt64)
    case logSnapshot(SwiftOSSDBGHostLogSnapshot)
    case remoteError(SwiftOSSDBGHostRemoteError)
}

enum SwiftOSSDBGHostProtocolViolation: Equatable {
    case invalidPayload(SwiftOSSDBGHostPayloadRejection)
    case messageBeforeHello(SDBGMessageKind)
    case capabilitiesSessionMismatch(
        expected: SDBGBootSessionID,
        actual: SDBGBootSessionID
    )
    case helloIdentityChanged
    case responseSessionMismatch(
        expected: SDBGBootSessionID,
        actual: SDBGBootSessionID
    )
    case unexpectedRequestID(UInt64)
    case operationMismatch(expected: SDBGOperation, actualRawValue: UInt16)
    case responseDoesNotMatchRequest(SDBGOperation)
    case unsupportedUnsolicitedMessage(SDBGMessageKind)
    case decoderInputRejected(SDBGStreamAppendResult)
}

enum SwiftOSSDBGHostClientEvent: Equatable {
    case hello(SDBGHelloPayload)
    case capabilities(SDBGCapabilitiesPayload)
    case sessionChanged(
        previous: SDBGBootSessionID,
        current: SDBGBootSessionID
    )
    case completed(requestID: UInt64, result: SwiftOSSDBGHostTransactionResult)
    case timedOut(requestID: UInt64, operation: SDBGOperation)
    case cancelledForSessionChange(
        requestID: UInt64,
        operation: SDBGOperation
    )
    case discardedFrame(rejection: SDBGDecodeRejection, byteCount: Int)
    case protocolViolation(SwiftOSSDBGHostProtocolViolation)
}

/// A clock-independent SDBG transaction state machine.
///
/// Callers provide monotonically increasing ticks to `begin`, `receive`, and
/// `expire`. That keeps timeout behavior deterministic in tests and avoids
/// coupling the shared core to Dispatch, run loops, serial APIs, or sockets.
/// Calls must be serialized by the owning adapter.
final class SwiftOSSDBGHostStreamClient {
    private struct PendingRequest {
        let requestID: UInt64
        let request: SDBGRequest
        let deadline: UInt64
    }

    private let transport: any SwiftOSSDBGHostTransport
    private let decoderStorage: UnsafeMutableRawPointer
    private let decoderStorageByteCount: Int
    private var decoder: SDBGStreamDecoder
    private var pending: [PendingRequest] = []
    private var nextRequestID: UInt64 = 1
    private let pendingRequestLimit: Int

    private(set) var hello: SDBGHelloPayload?
    private(set) var capabilities: SDBGCapabilitiesPayload?

    var bootSessionID: SDBGBootSessionID? { hello?.bootSessionID }
    var isReady: Bool { hello != nil && capabilities != nil }
    var pendingRequestCount: Int { pending.count }

    init?(
        transport: any SwiftOSSDBGHostTransport,
        maximumPayloadByteCount: Int = SDBGProtocol.maximumPayloadByteCount,
        pendingRequestLimit: Int = 32
    ) {
        guard maximumPayloadByteCount >= 0,
              maximumPayloadByteCount <= SDBGProtocol.maximumPayloadByteCount,
              pendingRequestLimit > 0
        else { return nil }
        let storageCount = SDBGProtocol.headerByteCount
            + maximumPayloadByteCount
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageCount,
            alignment: MemoryLayout<UInt64>.alignment
        )
        guard let decoder = SDBGStreamDecoder(
            storageBaseAddress: UInt(bitPattern: storage),
            storageByteCount: storageCount,
            maximumPayloadByteCount: maximumPayloadByteCount
        ) else {
            storage.deallocate()
            return nil
        }
        self.transport = transport
        decoderStorage = storage
        decoderStorageByteCount = storageCount
        self.decoder = decoder
        self.pendingRequestLimit = pendingRequestLimit
    }

    deinit {
        decoderStorage.deallocate()
    }

    func begin(
        _ request: SDBGRequest,
        now: UInt64,
        timeoutTicks: UInt64
    ) throws -> UInt64 {
        guard let hello, let capabilities else {
            throw SwiftOSSDBGHostClientError.handshakeIncomplete
        }
        guard timeoutTicks != 0 else {
            throw SwiftOSSDBGHostClientError.invalidTimeout
        }
        guard timeoutTicks <= UInt64.max - now else {
            throw SwiftOSSDBGHostClientError.invalidTimeout
        }
        guard pending.count < pendingRequestLimit else {
            throw SwiftOSSDBGHostClientError.pendingRequestLimitReached(
                pendingRequestLimit
            )
        }
        guard supports(request.operation, capabilities: capabilities) else {
            throw SwiftOSSDBGHostClientError.unsupportedOperation(
                request.operation
            )
        }
        switch request {
        case .logSnapshot(let value):
            guard value.startingSequence != 0 else {
                throw SwiftOSSDBGHostClientError.invalidRequestArgument(field: 1)
            }
            guard value.maximumEntryCount != 0 else {
                throw SwiftOSSDBGHostClientError.invalidRequestArgument(field: 2)
            }
        case .identity, .status, .ping:
            break
        }
        guard nextRequestID != 0 else {
            throw SwiftOSSDBGHostClientError.requestIDExhausted
        }

        var payload = [UInt8](
            repeating: 0,
            count: requestByteCount(request)
        )
        let payloadCount = payload.withUnsafeMutableBytes {
            SDBGRequestCodec.encode(request, into: $0)
        }
        guard let payloadCount,
              payloadCount <= Int(capabilities.maximumRequestPayloadByteCount)
        else { throw SwiftOSSDBGHostClientError.requestEncodingFailed }

        let requestID = nextRequestID
        nextRequestID = requestID == UInt64.max ? 0 : requestID + 1
        var frame = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + payloadCount
        )
        let encoded = frame.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                SDBGFrameEncoder.encode(
                    envelope: SDBGEnvelope(
                        kind: .request,
                        flags: .none,
                        bootSessionID: hello.bootSessionID,
                        requestID: requestID
                    ),
                    payload: UnsafeRawBufferPointer(
                        start: input.baseAddress,
                        count: payloadCount
                    ),
                    into: output
                )
            }
        }
        guard case .encoded(let frameByteCount) = encoded,
              frameByteCount == frame.count
        else { throw SwiftOSSDBGHostClientError.requestEncodingFailed }

        let deadline = now + timeoutTicks
        pending.append(
            PendingRequest(
                requestID: requestID,
                request: request,
                deadline: deadline
            )
        )
        do {
            try transport.send(frame)
        } catch {
            pending.removeLast()
            throw error
        }
        return requestID
    }

    func receive(
        _ bytes: [UInt8],
        now: UInt64
    ) -> [SwiftOSSDBGHostClientEvent] {
        bytes.withUnsafeBytes { receive($0, now: now) }
    }

    func receive(
        _ bytes: UnsafeRawBufferPointer,
        now: UInt64
    ) -> [SwiftOSSDBGHostClientEvent] {
        var events = expire(now: now)
        guard bytes.count == 0 || bytes.baseAddress != nil else {
            events.append(
                .protocolViolation(.decoderInputRejected(.invalidInput))
            )
            return events
        }

        drainDecoder(into: &events)
        var offset = 0
        while offset < bytes.count {
            let available = decoderStorageByteCount - decoder.bufferedByteCount
            if available == 0 {
                let before = events.count
                drainDecoder(into: &events)
                if decoderStorageByteCount - decoder.bufferedByteCount == 0,
                   events.count == before {
                    events.append(
                        .protocolViolation(
                            .decoderInputRejected(.capacityExceeded)
                        )
                    )
                    decoder.reset()
                }
                continue
            }
            let remaining = bytes.count - offset
            let count = remaining < available ? remaining : available
            let chunk = UnsafeRawBufferPointer(
                start: bytes.baseAddress!.advanced(by: offset),
                count: count
            )
            let appendResult = decoder.append(chunk)
            guard appendResult == .appended else {
                events.append(
                    .protocolViolation(.decoderInputRejected(appendResult))
                )
                decoder.reset()
                break
            }
            offset += count
            drainDecoder(into: &events)
        }
        return events
    }

    func expire(now: UInt64) -> [SwiftOSSDBGHostClientEvent] {
        var events: [SwiftOSSDBGHostClientEvent] = []
        var retained: [PendingRequest] = []
        retained.reserveCapacity(pending.count)
        for item in pending {
            if now >= item.deadline {
                events.append(
                    .timedOut(
                        requestID: item.requestID,
                        operation: item.request.operation
                    )
                )
            } else {
                retained.append(item)
            }
        }
        pending = retained
        return events
    }

    private func drainDecoder(
        into events: inout [SwiftOSSDBGHostClientEvent]
    ) {
        while true {
            switch decoder.pump() {
            case .needsMoreBytes:
                return
            case .discarded(let rejection, let byteCount):
                events.append(
                    .discardedFrame(
                        rejection: rejection,
                        byteCount: byteCount
                    )
                )
            case .frame(let frame):
                process(frame, into: &events)
            }
        }
    }

    private func process(
        _ frame: SDBGDecodedFrame,
        into events: inout [SwiftOSSDBGHostClientEvent]
    ) {
        let decoded: SwiftOSSDBGHostTypedPayload
        switch SwiftOSSDBGHostPayloadDecoder.decode(frame) {
        case .rejected(let rejection):
            events.append(
                .protocolViolation(.invalidPayload(rejection))
            )
            return
        case .decoded(let payload):
            decoded = payload
        }

        switch decoded {
        case .hello(let value):
            processHello(value, into: &events)
        case .capabilities(let value):
            processCapabilities(
                value,
                envelope: frame.envelope,
                into: &events
            )
        case .identity, .status, .ping, .logSnapshot, .remoteError:
            processResponse(
                decoded,
                envelope: frame.envelope,
                into: &events
            )
        }
    }

    private func processHello(
        _ value: SDBGHelloPayload,
        into events: inout [SwiftOSSDBGHostClientEvent]
    ) {
        if let previous = hello {
            if previous.bootSessionID != value.bootSessionID {
                for item in pending {
                    events.append(
                        .cancelledForSessionChange(
                            requestID: item.requestID,
                            operation: item.request.operation
                        )
                    )
                }
                pending.removeAll(keepingCapacity: true)
                capabilities = nil
                events.append(
                    .sessionChanged(
                        previous: previous.bootSessionID,
                        current: value.bootSessionID
                    )
                )
            } else if previous.buildID != value.buildID {
                events.append(
                    .protocolViolation(.helloIdentityChanged)
                )
                return
            }
        }
        hello = value
        events.append(.hello(value))
    }

    private func processCapabilities(
        _ value: SDBGCapabilitiesPayload,
        envelope: SDBGEnvelope,
        into events: inout [SwiftOSSDBGHostClientEvent]
    ) {
        guard let hello else {
            events.append(
                .protocolViolation(.messageBeforeHello(.capabilities))
            )
            return
        }
        guard envelope.bootSessionID == hello.bootSessionID else {
            events.append(
                .protocolViolation(
                    .capabilitiesSessionMismatch(
                        expected: hello.bootSessionID,
                        actual: envelope.bootSessionID
                    )
                )
            )
            return
        }
        capabilities = value
        events.append(.capabilities(value))
    }

    private func processResponse(
        _ payload: SwiftOSSDBGHostTypedPayload,
        envelope: SDBGEnvelope,
        into events: inout [SwiftOSSDBGHostClientEvent]
    ) {
        guard let activeSession = hello?.bootSessionID else {
            events.append(
                .protocolViolation(.messageBeforeHello(.response))
            )
            return
        }
        guard envelope.bootSessionID == activeSession else {
            events.append(
                .protocolViolation(
                    .responseSessionMismatch(
                        expected: activeSession,
                        actual: envelope.bootSessionID
                    )
                )
            )
            return
        }
        guard let index = pending.firstIndex(
            where: { $0.requestID == envelope.requestID }
        ) else {
            events.append(
                .protocolViolation(
                    .unexpectedRequestID(envelope.requestID)
                )
            )
            return
        }
        let transaction = pending.remove(at: index)

        let actualOperationRawValue: UInt16
        switch payload {
        case .identity:
            actualOperationRawValue = SDBGOperation.identity.rawValue
        case .status:
            actualOperationRawValue = SDBGOperation.status.rawValue
        case .ping:
            actualOperationRawValue = SDBGOperation.ping.rawValue
        case .logSnapshot:
            actualOperationRawValue = SDBGOperation.logSnapshot.rawValue
        case .remoteError(let error):
            actualOperationRawValue = error.operationRawValue
        case .hello, .capabilities:
            events.append(
                .protocolViolation(.unsupportedUnsolicitedMessage(.response))
            )
            return
        }
        guard actualOperationRawValue == transaction.request.operation.rawValue
        else {
            events.append(
                .protocolViolation(
                    .operationMismatch(
                        expected: transaction.request.operation,
                        actualRawValue: actualOperationRawValue
                    )
                )
            )
            return
        }

        let result: SwiftOSSDBGHostTransactionResult
        switch (transaction.request, payload) {
        case (.identity, .identity(let value)):
            result = .identity(value)
        case (.status, .status(let value)):
            result = .status(value)
        case (.ping(let expected), .ping(let actual)) where expected == actual:
            result = .ping(token: actual)
        case (.logSnapshot(let request), .logSnapshot(let value))
                where request.startingSequence
                    == value.requestedStartingSequence:
            result = .logSnapshot(value)
        case (_, .remoteError(let value)):
            result = .remoteError(value)
        default:
            events.append(
                .protocolViolation(
                    .responseDoesNotMatchRequest(transaction.request.operation)
                )
            )
            return
        }
        events.append(
            .completed(requestID: envelope.requestID, result: result)
        )
    }

    private func supports(
        _ operation: SDBGOperation,
        capabilities: SDBGCapabilitiesPayload
    ) -> Bool {
        switch operation {
        case .identity:
            return capabilities.capabilities.contains(.identity)
        case .status:
            return capabilities.capabilities.contains(.status)
        case .logSnapshot:
            return capabilities.capabilities.contains(.logSnapshot)
        case .ping:
            return capabilities.capabilities.contains(.ping)
        }
    }

    private func requestByteCount(_ request: SDBGRequest) -> Int {
        switch request {
        case .identity:
            return SDBGTypedPayloadProtocol.identityRequestByteCount
        case .status:
            return SDBGTypedPayloadProtocol.statusRequestByteCount
        case .logSnapshot:
            return SDBGTypedPayloadProtocol.logSnapshotRequestByteCount
        case .ping:
            return SDBGTypedPayloadProtocol.pingRequestByteCount
        }
    }
}
