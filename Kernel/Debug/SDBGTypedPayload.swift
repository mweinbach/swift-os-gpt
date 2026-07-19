/// Versioned, transport-independent payloads carried inside SDBG envelopes.
///
/// Every multi-byte field is little-endian. Payloads carry their own schema and
/// byte count so a valid SDBG frame cannot be mistaken for a valid operation.
/// Reserved fields and flags must be zero in version 1.
enum SDBGTypedPayloadProtocol {
    static let schemaVersion: UInt16 = 1
    static let typedHeaderByteCount: UInt16 = 8
    static let requestHeaderByteCount: UInt16 = 12
    static let responseHeaderByteCount: UInt16 = 12

    static let helloByteCount = 48
    static let capabilitiesByteCount = 24
    static let identityRequestByteCount = 12
    static let statusRequestByteCount = 12
    static let pingRequestByteCount = 20
    static let logSnapshotRequestByteCount = 24
    static let errorResponseByteCount = 28
    static let identityResponseByteCount = 84
    static let statusResponseByteCount = 124
    static let pingResponseByteCount = 20
    static let logSnapshotResponseHeaderByteCount = 68
}

struct SDBGCapabilitySet: RawRepresentable, Equatable {
    let rawValue: UInt32

    static let identity = Self(rawValue: 1 << 0)
    static let status = Self(rawValue: 1 << 1)
    static let logSnapshot = Self(rawValue: 1 << 2)
    static let ping = Self(rawValue: 1 << 3)
    static let readOnlyV1 = Self(
        rawValue: identity.rawValue
            | status.rawValue
            | logSnapshot.rawValue
            | ping.rawValue
    )

    func contains(_ capability: Self) -> Bool {
        rawValue & capability.rawValue == capability.rawValue
    }
}

struct SDBGHelloPayload: Equatable {
    let protocolMajor: UInt8
    let protocolMinor: UInt8
    let bootSessionID: SDBGBootSessionID
    let buildID: KernelIdentity128
    let buildIdentitySchemaVersion: UInt16
    let bootIdentitySchemaVersion: UInt16
}

struct SDBGCapabilitiesPayload: Equatable {
    let capabilities: SDBGCapabilitySet
    let maximumRequestPayloadByteCount: UInt32
    let maximumResponsePayloadByteCount: UInt32
    let logRecordByteCount: UInt16
    let maximumLogEntriesPerResponse: UInt16
}

enum SDBGDiscoveryPayloadRejection: Equatable {
    case invalidBuffer
    case invalidByteCount(required: Int, actual: Int)
    case unsupportedSchema(UInt16)
    case invalidHeaderByteCount(UInt16)
    case byteCountMismatch(declared: UInt32, actual: Int)
    case nonzeroReserved(UInt16)
    case zeroIdentity
    case unsupportedCapabilities(UInt32)
    case invalidLimits
}

enum SDBGHelloDecodeResult: Equatable {
    case hello(SDBGHelloPayload)
    case rejected(SDBGDiscoveryPayloadRejection)
}

enum SDBGCapabilitiesDecodeResult: Equatable {
    case capabilities(SDBGCapabilitiesPayload)
    case rejected(SDBGDiscoveryPayloadRejection)
}

enum SDBGDiscoveryPayloadCodec {
    static func decodeHello(
        _ payload: UnsafeRawBufferPointer
    ) -> SDBGHelloDecodeResult {
        if let rejection = validateTypedPayload(
            payload,
            requiredByteCount: SDBGTypedPayloadProtocol.helloByteCount
        ) {
            return .rejected(rejection)
        }
        let reserved = SDBGPayloadWire.readUInt16(payload, at: 10)
        guard reserved == 0 else {
            return .rejected(.nonzeroReserved(reserved))
        }
        let session = SDBGBootSessionID(
            high: SDBGWire.readUInt64(payload, at: 12),
            low: SDBGWire.readUInt64(payload, at: 20)
        )
        guard !session.isZero,
              let buildID = KernelIdentity128(
                  high: SDBGWire.readUInt64(payload, at: 28),
                  low: SDBGWire.readUInt64(payload, at: 36)
              )
        else { return .rejected(.zeroIdentity) }
        return .hello(
            SDBGHelloPayload(
                protocolMajor: payload[8],
                protocolMinor: payload[9],
                bootSessionID: session,
                buildID: buildID,
                buildIdentitySchemaVersion: SDBGPayloadWire.readUInt16(
                    payload,
                    at: 44
                ),
                bootIdentitySchemaVersion: SDBGPayloadWire.readUInt16(
                    payload,
                    at: 46
                )
            )
        )
    }

    static func decodeCapabilities(
        _ payload: UnsafeRawBufferPointer
    ) -> SDBGCapabilitiesDecodeResult {
        if let rejection = validateTypedPayload(
            payload,
            requiredByteCount: SDBGTypedPayloadProtocol.capabilitiesByteCount
        ) {
            return .rejected(rejection)
        }
        let rawCapabilities = SDBGWire.readUInt32(payload, at: 8)
        guard rawCapabilities & ~SDBGCapabilitySet.readOnlyV1.rawValue == 0 else {
            return .rejected(.unsupportedCapabilities(rawCapabilities))
        }
        let maximumRequest = SDBGWire.readUInt32(payload, at: 12)
        let maximumResponse = SDBGWire.readUInt32(payload, at: 16)
        let recordByteCount = SDBGPayloadWire.readUInt16(payload, at: 20)
        let maximumEntries = SDBGPayloadWire.readUInt16(payload, at: 22)
        guard maximumRequest
                >= UInt32(SDBGTypedPayloadProtocol.logSnapshotRequestByteCount),
              maximumRequest <= UInt32(SDBGProtocol.maximumPayloadByteCount),
              maximumResponse
                >= UInt32(SDBGTypedPayloadProtocol.statusResponseByteCount),
              maximumResponse <= UInt32(SDBGProtocol.maximumPayloadByteCount),
              recordByteCount == UInt16(KernelLogRing.recordByteCount),
              maximumEntries != 0,
              Int(maximumEntries) * KernelLogRing.recordByteCount
                <= Int(maximumResponse)
                    - SDBGTypedPayloadProtocol
                        .logSnapshotResponseHeaderByteCount
        else { return .rejected(.invalidLimits) }
        return .capabilities(
            SDBGCapabilitiesPayload(
                capabilities: SDBGCapabilitySet(rawValue: rawCapabilities),
                maximumRequestPayloadByteCount: maximumRequest,
                maximumResponsePayloadByteCount: maximumResponse,
                logRecordByteCount: recordByteCount,
                maximumLogEntriesPerResponse: maximumEntries
            )
        )
    }

    private static func validateTypedPayload(
        _ payload: UnsafeRawBufferPointer,
        requiredByteCount: Int
    ) -> SDBGDiscoveryPayloadRejection? {
        guard payload.count == 0 || payload.baseAddress != nil else {
            return .invalidBuffer
        }
        guard payload.count == requiredByteCount else {
            return .invalidByteCount(
                required: requiredByteCount,
                actual: payload.count
            )
        }
        let schema = SDBGPayloadWire.readUInt16(payload, at: 0)
        guard schema == SDBGTypedPayloadProtocol.schemaVersion else {
            return .unsupportedSchema(schema)
        }
        let header = SDBGPayloadWire.readUInt16(payload, at: 2)
        guard header == SDBGTypedPayloadProtocol.typedHeaderByteCount else {
            return .invalidHeaderByteCount(header)
        }
        let declared = SDBGWire.readUInt32(payload, at: 4)
        guard declared == UInt32(payload.count) else {
            return .byteCountMismatch(declared: declared, actual: payload.count)
        }
        return nil
    }
}

enum SDBGOperation: UInt16, Equatable {
    case identity = 1
    case status = 2
    case logSnapshot = 3
    case ping = 4
}

struct SDBGLogSnapshotRequest: Equatable {
    let startingSequence: UInt64
    let maximumEntryCount: UInt32
}

enum SDBGRequest: Equatable {
    case identity
    case status
    case logSnapshot(SDBGLogSnapshotRequest)
    case ping(token: UInt64)

    var operation: SDBGOperation {
        switch self {
        case .identity: return .identity
        case .status: return .status
        case .logSnapshot: return .logSnapshot
        case .ping: return .ping
        }
    }
}

enum SDBGRequestRejection: Equatable {
    case invalidBuffer
    case tooShort(required: Int, available: Int)
    case unsupportedSchema(UInt16)
    case invalidHeaderByteCount(UInt16)
    case byteCountMismatch(declared: UInt32, actual: Int)
    case unsupportedOperation(UInt16)
    case unsupportedFlags(UInt16)
    case invalidOperationByteCount(
        operation: SDBGOperation,
        required: Int,
        actual: Int
    )
    case invalidArgument(operation: SDBGOperation, field: UInt16)
}

enum SDBGRequestDecodeResult: Equatable {
    case request(SDBGRequest)
    case rejected(SDBGRequestRejection)
}

enum SDBGRequestCodec {
    static func decode(
        _ payload: UnsafeRawBufferPointer
    ) -> SDBGRequestDecodeResult {
        guard payload.count == 0 || payload.baseAddress != nil else {
            return .rejected(.invalidBuffer)
        }
        guard payload.count >= Int(SDBGTypedPayloadProtocol.requestHeaderByteCount)
        else {
            return .rejected(
                .tooShort(
                    required: Int(
                        SDBGTypedPayloadProtocol.requestHeaderByteCount
                    ),
                    available: payload.count
                )
            )
        }

        let schema = SDBGPayloadWire.readUInt16(payload, at: 0)
        guard schema == SDBGTypedPayloadProtocol.schemaVersion else {
            return .rejected(.unsupportedSchema(schema))
        }
        let headerByteCount = SDBGPayloadWire.readUInt16(payload, at: 2)
        guard headerByteCount
                == SDBGTypedPayloadProtocol.requestHeaderByteCount
        else {
            return .rejected(.invalidHeaderByteCount(headerByteCount))
        }
        let declaredByteCount = SDBGWire.readUInt32(payload, at: 4)
        guard declaredByteCount == UInt32(payload.count) else {
            return .rejected(
                .byteCountMismatch(
                    declared: declaredByteCount,
                    actual: payload.count
                )
            )
        }
        let rawOperation = SDBGPayloadWire.readUInt16(payload, at: 8)
        guard let operation = SDBGOperation(rawValue: rawOperation) else {
            return .rejected(.unsupportedOperation(rawOperation))
        }
        let flags = SDBGPayloadWire.readUInt16(payload, at: 10)
        guard flags == 0 else {
            return .rejected(.unsupportedFlags(flags))
        }

        switch operation {
        case .identity:
            guard payload.count
                    == SDBGTypedPayloadProtocol.identityRequestByteCount
            else {
                return invalidByteCount(operation, actual: payload.count)
            }
            return .request(.identity)
        case .status:
            guard payload.count
                    == SDBGTypedPayloadProtocol.statusRequestByteCount
            else {
                return invalidByteCount(operation, actual: payload.count)
            }
            return .request(.status)
        case .logSnapshot:
            guard payload.count
                    == SDBGTypedPayloadProtocol.logSnapshotRequestByteCount
            else {
                return invalidByteCount(operation, actual: payload.count)
            }
            let startingSequence = SDBGWire.readUInt64(payload, at: 12)
            let maximumEntryCount = SDBGWire.readUInt32(payload, at: 20)
            guard startingSequence != 0 else {
                return .rejected(
                    .invalidArgument(operation: operation, field: 1)
                )
            }
            guard maximumEntryCount != 0 else {
                return .rejected(
                    .invalidArgument(operation: operation, field: 2)
                )
            }
            return .request(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: startingSequence,
                        maximumEntryCount: maximumEntryCount
                    )
                )
            )
        case .ping:
            guard payload.count
                    == SDBGTypedPayloadProtocol.pingRequestByteCount
            else {
                return invalidByteCount(operation, actual: payload.count)
            }
            return .request(.ping(token: SDBGWire.readUInt64(payload, at: 12)))
        }
    }

    static func encode(
        _ request: SDBGRequest,
        into output: UnsafeMutableRawBufferPointer
    ) -> Int? {
        let required: Int
        switch request {
        case .identity:
            required = SDBGTypedPayloadProtocol.identityRequestByteCount
        case .status:
            required = SDBGTypedPayloadProtocol.statusRequestByteCount
        case .logSnapshot:
            required = SDBGTypedPayloadProtocol.logSnapshotRequestByteCount
        case .ping:
            required = SDBGTypedPayloadProtocol.pingRequestByteCount
        }
        guard output.count >= required,
              output.baseAddress != nil
        else { return nil }

        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.schemaVersion,
            to: output,
            at: 0
        )
        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.requestHeaderByteCount,
            to: output,
            at: 2
        )
        SDBGWire.writeUInt32(UInt32(required), to: output, at: 4)
        SDBGPayloadWire.writeUInt16(
            request.operation.rawValue,
            to: output,
            at: 8
        )
        SDBGPayloadWire.writeUInt16(0, to: output, at: 10)
        switch request {
        case .identity, .status:
            break
        case .logSnapshot(let value):
            SDBGWire.writeUInt64(value.startingSequence, to: output, at: 12)
            SDBGWire.writeUInt32(value.maximumEntryCount, to: output, at: 20)
        case .ping(let token):
            SDBGWire.writeUInt64(token, to: output, at: 12)
        }
        return required
    }

    private static func invalidByteCount(
        _ operation: SDBGOperation,
        actual: Int
    ) -> SDBGRequestDecodeResult {
        let required: Int
        switch operation {
        case .identity:
            required = SDBGTypedPayloadProtocol.identityRequestByteCount
        case .status:
            required = SDBGTypedPayloadProtocol.statusRequestByteCount
        case .logSnapshot:
            required = SDBGTypedPayloadProtocol.logSnapshotRequestByteCount
        case .ping:
            required = SDBGTypedPayloadProtocol.pingRequestByteCount
        }
        return .rejected(
            .invalidOperationByteCount(
                operation: operation,
                required: required,
                actual: actual
            )
        )
    }
}

enum SDBGResponseStatus: UInt16, Equatable {
    case success = 0
    case malformedRequest = 1
    case unsupportedSchema = 2
    case unsupportedOperation = 3
    case unsupportedFlags = 4
    case invalidArgument = 5
    case bootSessionMismatch = 6
    case logSequenceLost = 7
    case logSequenceNotYetWritten = 8
    case logProviderInconsistent = 9
    case requestTooLarge = 10
}

struct SDBGResponseHeader: Equatable {
    let operationRawValue: UInt16
    let status: SDBGResponseStatus
    let payloadByteCount: UInt32
}

enum SDBGResponseHeaderDecodeResult: Equatable {
    case header(SDBGResponseHeader)
    case rejected(SDBGRequestRejection)
}

enum SDBGResponseCodec {
    static func decodeHeader(
        _ payload: UnsafeRawBufferPointer
    ) -> SDBGResponseHeaderDecodeResult {
        guard payload.count == 0 || payload.baseAddress != nil else {
            return .rejected(.invalidBuffer)
        }
        guard payload.count
                >= Int(SDBGTypedPayloadProtocol.responseHeaderByteCount)
        else {
            return .rejected(
                .tooShort(
                    required: Int(
                        SDBGTypedPayloadProtocol.responseHeaderByteCount
                    ),
                    available: payload.count
                )
            )
        }
        let schema = SDBGPayloadWire.readUInt16(payload, at: 0)
        guard schema == SDBGTypedPayloadProtocol.schemaVersion else {
            return .rejected(.unsupportedSchema(schema))
        }
        let header = SDBGPayloadWire.readUInt16(payload, at: 2)
        guard header == SDBGTypedPayloadProtocol.responseHeaderByteCount else {
            return .rejected(.invalidHeaderByteCount(header))
        }
        let count = SDBGWire.readUInt32(payload, at: 4)
        guard count == UInt32(payload.count) else {
            return .rejected(
                .byteCountMismatch(declared: count, actual: payload.count)
            )
        }
        let rawStatus = SDBGPayloadWire.readUInt16(payload, at: 10)
        guard let status = SDBGResponseStatus(rawValue: rawStatus) else {
            return .rejected(.unsupportedFlags(rawStatus))
        }
        return .header(
            SDBGResponseHeader(
                operationRawValue: SDBGPayloadWire.readUInt16(payload, at: 8),
                status: status,
                payloadByteCount: count
            )
        )
    }
}

struct SDBGLogSnapshotResponseFlags: RawRepresentable, Equatable {
    let rawValue: UInt16

    static let moreEntries = Self(rawValue: 1 << 0)
    static let sequenceExhausted = Self(rawValue: 1 << 1)

    func contains(_ flag: Self) -> Bool {
        rawValue & flag.rawValue == flag.rawValue
    }
}

enum SDBGPayloadWire {
    static func readUInt16(
        _ input: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(input[offset]) | (UInt16(input[offset + 1]) << 8)
    }

    static func writeUInt16(
        _ value: UInt16,
        to output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        output[offset] = UInt8(truncatingIfNeeded: value)
        output[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
