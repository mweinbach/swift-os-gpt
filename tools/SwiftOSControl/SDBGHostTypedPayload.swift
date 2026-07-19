/// Owned, host-side views of the typed payloads carried by SDBG v1.
///
/// The kernel codecs deliberately return raw-buffer views. This decoder copies
/// variable-length records into bounded Swift collections before the stream
/// decoder can reuse its receive buffer, and validates every offset before it
/// is read. The resulting values can therefore outlive the transport callback.
struct SwiftOSSDBGHostRemoteError: Equatable {
    let operationRawValue: UInt16
    let status: SDBGResponseStatus
    let detail0: UInt64
    let detail1: UInt64
}

struct SwiftOSSDBGHostLogSnapshot: Equatable {
    let requestedStartingSequence: UInt64
    let oldestAvailableSequence: UInt64
    let newestAvailableSequence: UInt64
    let returnedStartingSequence: UInt64
    let nextSequence: UInt64
    let lostEntryCount: UInt64
    let flags: SDBGLogSnapshotResponseFlags
    let entries: [KernelLogEntry]
}

enum SwiftOSSDBGHostTypedPayload: Equatable {
    case hello(SDBGHelloPayload)
    case capabilities(SDBGCapabilitiesPayload)
    case identity(KernelBootIdentity)
    case status(DebugStatusSnapshot)
    case ping(token: UInt64)
    case logSnapshot(SwiftOSSDBGHostLogSnapshot)
    case remoteError(SwiftOSSDBGHostRemoteError)
}

enum SwiftOSSDBGHostPayloadRejection: Equatable {
    case unsupportedMessageKind(SDBGMessageKind)
    case discoveryPayload(SDBGDiscoveryPayloadRejection)
    case responseHeader(SDBGRequestRejection)
    case unexpectedEnvelopeFlags(UInt8)
    case envelopePayloadSessionMismatch
    case invalidByteCount(required: Int, actual: Int)
    case invalidSchema(field: UInt16, value: UInt16)
    case invalidEnum(field: UInt16, rawValue: UInt64)
    case unsupportedBits(field: UInt16, rawValue: UInt64)
    case nonzeroReserved(field: UInt16, rawValue: UInt64)
    case zeroIdentity(field: UInt16)
    case invalidValue(field: UInt16)
    case invalidInvariant(field: UInt16)
}

enum SwiftOSSDBGHostPayloadDecodeResult: Equatable {
    case decoded(SwiftOSSDBGHostTypedPayload)
    case rejected(SwiftOSSDBGHostPayloadRejection)
}

enum SwiftOSSDBGHostPayloadDecoder {
    private static let statusFlagMask = DebugStatusFlags.interruptsEnabled.rawValue
        | DebugStatusFlags.virtualMemoryEnabled.rawValue
        | DebugStatusFlags.preemptionEnabled.rawValue
        | DebugStatusFlags.userlandIsolated.rawValue
        | DebugStatusFlags.degraded.rawValue
    private static let logFlagMask = SDBGLogSnapshotResponseFlags.moreEntries.rawValue
        | SDBGLogSnapshotResponseFlags.sequenceExhausted.rawValue

    static func decode(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        switch frame.envelope.kind {
        case .hello:
            return decodeHello(frame)
        case .capabilities:
            return decodeCapabilities(frame)
        case .response:
            return decodeResponse(frame)
        case .request, .event, .logChunk:
            return .rejected(.unsupportedMessageKind(frame.envelope.kind))
        }
    }

    private static func decodeHello(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        switch SDBGDiscoveryPayloadCodec.decodeHello(frame.payload) {
        case .rejected(let rejection):
            return .rejected(.discoveryPayload(rejection))
        case .hello(let hello):
            guard session(hello.bootSessionID)
                    == frame.envelope.bootSessionID
            else { return .rejected(.envelopePayloadSessionMismatch) }
            guard hello.protocolMajor == SDBGProtocol.versionMajor,
                  hello.protocolMinor == SDBGProtocol.versionMinor
            else {
                return .rejected(
                    .invalidSchema(
                        field: 1,
                        value: UInt16(hello.protocolMajor) << 8
                            | UInt16(hello.protocolMinor)
                    )
                )
            }
            guard hello.buildIdentitySchemaVersion
                    == KernelBuildIdentity.schemaVersion
            else {
                return .rejected(
                    .invalidSchema(
                        field: 2,
                        value: hello.buildIdentitySchemaVersion
                    )
                )
            }
            guard hello.bootIdentitySchemaVersion
                    == KernelBootIdentity.schemaVersion
            else {
                return .rejected(
                    .invalidSchema(
                        field: 3,
                        value: hello.bootIdentitySchemaVersion
                    )
                )
            }
            return .decoded(.hello(hello))
        }
    }

    private static func decodeCapabilities(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        switch SDBGDiscoveryPayloadCodec.decodeCapabilities(frame.payload) {
        case .rejected(let rejection):
            return .rejected(.discoveryPayload(rejection))
        case .capabilities(let capabilities):
            return .decoded(.capabilities(capabilities))
        }
    }

    private static func decodeResponse(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        let header: SDBGResponseHeader
        switch SDBGResponseCodec.decodeHeader(frame.payload) {
        case .rejected(let rejection):
            return .rejected(.responseHeader(rejection))
        case .header(let decoded):
            header = decoded
        }

        if header.status != .success {
            guard frame.envelope.flags == .error else {
                return .rejected(
                    .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
                )
            }
            guard frame.payload.count
                    == SDBGTypedPayloadProtocol.errorResponseByteCount
            else {
                return .rejected(
                    .invalidByteCount(
                        required: SDBGTypedPayloadProtocol.errorResponseByteCount,
                        actual: frame.payload.count
                    )
                )
            }
            return .decoded(
                .remoteError(
                    SwiftOSSDBGHostRemoteError(
                        operationRawValue: header.operationRawValue,
                        status: header.status,
                        detail0: SDBGWire.readUInt64(frame.payload, at: 12),
                        detail1: SDBGWire.readUInt64(frame.payload, at: 20)
                    )
                )
            )
        }

        guard !frame.envelope.flags.contains(.error) else {
            return .rejected(
                .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
            )
        }
        guard let operation = SDBGOperation(rawValue: header.operationRawValue)
        else {
            return .rejected(
                .invalidEnum(
                    field: 4,
                    rawValue: UInt64(header.operationRawValue)
                )
            )
        }

        switch operation {
        case .identity:
            guard frame.envelope.flags == .none else {
                return .rejected(
                    .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
                )
            }
            return decodeIdentity(frame)
        case .status:
            guard frame.envelope.flags == .none else {
                return .rejected(
                    .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
                )
            }
            return decodeStatus(frame)
        case .ping:
            guard frame.envelope.flags == .none else {
                return .rejected(
                    .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
                )
            }
            return decodePing(frame)
        case .logSnapshot:
            return decodeLogSnapshot(frame)
        }
    }

    private static func decodeIdentity(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        let required = SDBGTypedPayloadProtocol.identityResponseByteCount
        guard frame.payload.count == required else {
            return .rejected(
                .invalidByteCount(required: required, actual: frame.payload.count)
            )
        }
        let buildSchema = SDBGPayloadWire.readUInt16(frame.payload, at: 12)
        guard buildSchema == KernelBuildIdentity.schemaVersion else {
            return .rejected(.invalidSchema(field: 5, value: buildSchema))
        }
        let bootSchema = SDBGPayloadWire.readUInt16(frame.payload, at: 14)
        guard bootSchema == KernelBootIdentity.schemaVersion else {
            return .rejected(.invalidSchema(field: 6, value: bootSchema))
        }
        guard let flavor = KernelBuildFlavor(rawValue: frame.payload[18]) else {
            return .rejected(
                .invalidEnum(field: 7, rawValue: UInt64(frame.payload[18]))
            )
        }
        guard let reason = KernelBootReason(rawValue: frame.payload[19]) else {
            return .rejected(
                .invalidEnum(field: 8, rawValue: UInt64(frame.payload[19]))
            )
        }
        guard let sessionID = identity(frame.payload, at: 20) else {
            return .rejected(.zeroIdentity(field: 9))
        }
        guard session(sessionID) == frame.envelope.bootSessionID else {
            return .rejected(.envelopePayloadSessionMismatch)
        }
        guard let buildID = identity(frame.payload, at: 36) else {
            return .rejected(.zeroIdentity(field: 10))
        }
        let build = KernelBuildIdentity(
            buildID: buildID,
            sourceRevision: SDBGWire.readUInt64(frame.payload, at: 52),
            imageDigestPrefix: SDBGWire.readUInt64(frame.payload, at: 60),
            flavor: flavor,
            abiRevision: SDBGPayloadWire.readUInt16(frame.payload, at: 16)
        )
        return .decoded(
            .identity(
                KernelBootIdentity(
                    sessionID: sessionID,
                    build: build,
                    bootOrdinal: SDBGWire.readUInt64(frame.payload, at: 68),
                    startedAtTicks: SDBGWire.readUInt64(frame.payload, at: 76),
                    reason: reason
                )
            )
        )
    }

    private static func decodeStatus(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        let required = SDBGTypedPayloadProtocol.statusResponseByteCount
        guard frame.payload.count == required else {
            return .rejected(
                .invalidByteCount(required: required, actual: frame.payload.count)
            )
        }
        guard let sessionID = identity(frame.payload, at: 28) else {
            return .rejected(.zeroIdentity(field: 11))
        }
        guard session(sessionID) == frame.envelope.bootSessionID else {
            return .rejected(.envelopePayloadSessionMismatch)
        }
        guard let phase = DebugKernelPhase(rawValue: frame.payload[44]) else {
            return .rejected(
                .invalidEnum(field: 12, rawValue: UInt64(frame.payload[44]))
            )
        }
        guard let displayState = DebugDisplayState(rawValue: frame.payload[45])
        else {
            return .rejected(
                .invalidEnum(field: 13, rawValue: UInt64(frame.payload[45]))
            )
        }
        guard let linkState = DebugLinkState(rawValue: frame.payload[46]) else {
            return .rejected(
                .invalidEnum(field: 14, rawValue: UInt64(frame.payload[46]))
            )
        }
        guard let updateState = DebugUpdateState(rawValue: frame.payload[47])
        else {
            return .rejected(
                .invalidEnum(field: 15, rawValue: UInt64(frame.payload[47]))
            )
        }
        let rawFlags = SDBGWire.readUInt32(frame.payload, at: 48)
        guard rawFlags & ~statusFlagMask == 0 else {
            return .rejected(
                .unsupportedBits(field: 16, rawValue: UInt64(rawFlags))
            )
        }
        let reserved = SDBGWire.readUInt32(frame.payload, at: 88)
        guard reserved == 0 else {
            return .rejected(
                .nonzeroReserved(field: 17, rawValue: UInt64(reserved))
            )
        }
        let snapshot = DebugStatusSnapshot(
            snapshotSequence: SDBGWire.readUInt64(frame.payload, at: 12),
            monotonicTicks: SDBGWire.readUInt64(frame.payload, at: 20),
            bootSessionID: sessionID,
            phase: phase,
            flags: DebugStatusFlags(rawValue: rawFlags),
            configuredProcessorCount: SDBGPayloadWire.readUInt16(
                frame.payload,
                at: 52
            ),
            onlineProcessorCount: SDBGPayloadWire.readUInt16(
                frame.payload,
                at: 54
            ),
            runnableThreadCount: SDBGWire.readUInt32(frame.payload, at: 56),
            managedMemoryByteCount: SDBGWire.readUInt64(frame.payload, at: 60),
            freeMemoryByteCount: SDBGWire.readUInt64(frame.payload, at: 68),
            displayState: displayState,
            displayWidthPixels: SDBGWire.readUInt32(frame.payload, at: 76),
            displayHeightPixels: SDBGWire.readUInt32(frame.payload, at: 80),
            displayRefreshMilliHertz: SDBGWire.readUInt32(
                frame.payload,
                at: 84
            ),
            debugLinkState: linkState,
            updateState: updateState,
            oldestLogSequence: SDBGWire.readUInt64(frame.payload, at: 92),
            newestLogSequence: SDBGWire.readUInt64(frame.payload, at: 100),
            lostLogEntryCount: SDBGWire.readUInt64(frame.payload, at: 108),
            lastError: DebugStatusError(
                domain: SDBGPayloadWire.readUInt16(frame.payload, at: 116),
                code: SDBGPayloadWire.readUInt16(frame.payload, at: 118),
                detail: SDBGWire.readUInt32(frame.payload, at: 120)
            )
        )
        guard let snapshot else {
            return .rejected(.invalidInvariant(field: 18))
        }
        return .decoded(.status(snapshot))
    }

    private static func decodePing(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        let required = SDBGTypedPayloadProtocol.pingResponseByteCount
        guard frame.payload.count == required else {
            return .rejected(
                .invalidByteCount(required: required, actual: frame.payload.count)
            )
        }
        return .decoded(
            .ping(token: SDBGWire.readUInt64(frame.payload, at: 12))
        )
    }

    private static func decodeLogSnapshot(
        _ frame: SDBGDecodedFrame
    ) -> SwiftOSSDBGHostPayloadDecodeResult {
        let headerCount = SDBGTypedPayloadProtocol
            .logSnapshotResponseHeaderByteCount
        guard frame.payload.count >= headerCount else {
            return .rejected(
                .invalidByteCount(
                    required: headerCount,
                    actual: frame.payload.count
                )
            )
        }
        let recordByteCount = SDBGPayloadWire.readUInt16(
            frame.payload,
            at: 64
        )
        guard recordByteCount == UInt16(KernelLogRing.recordByteCount) else {
            return .rejected(.invalidValue(field: 19))
        }
        let rawFlags = SDBGPayloadWire.readUInt16(frame.payload, at: 66)
        guard rawFlags & ~logFlagMask == 0 else {
            return .rejected(
                .unsupportedBits(field: 20, rawValue: UInt64(rawFlags))
            )
        }
        let flags = SDBGLogSnapshotResponseFlags(rawValue: rawFlags)
        let envelopeHasMore = frame.envelope.flags.contains(.moreFragments)
        guard envelopeHasMore == flags.contains(.moreEntries) else {
            return .rejected(.invalidInvariant(field: 21))
        }
        guard frame.envelope.flags.rawValue
                & ~(SDBGMessageFlags.moreFragments.rawValue) == 0
        else {
            return .rejected(
                .unexpectedEnvelopeFlags(frame.envelope.flags.rawValue)
            )
        }

        let recordBytes = frame.payload.count - headerCount
        guard recordBytes % KernelLogRing.recordByteCount == 0 else {
            return .rejected(.invalidInvariant(field: 22))
        }
        let retainedRecordCount = recordBytes / KernelLogRing.recordByteCount
        let declaredRecordCount = SDBGWire.readUInt32(frame.payload, at: 60)
        guard UInt64(declaredRecordCount) == UInt64(retainedRecordCount) else {
            return .rejected(.invalidInvariant(field: 23))
        }

        let requestedStart = SDBGWire.readUInt64(frame.payload, at: 12)
        let oldest = SDBGWire.readUInt64(frame.payload, at: 20)
        let newest = SDBGWire.readUInt64(frame.payload, at: 28)
        let returnedStart = SDBGWire.readUInt64(frame.payload, at: 36)
        let next = SDBGWire.readUInt64(frame.payload, at: 44)
        let lost = SDBGWire.readUInt64(frame.payload, at: 52)
        guard requestedStart != 0 else {
            return .rejected(.invalidValue(field: 24))
        }
        guard (oldest == 0 && newest == 0)
                || (oldest != 0 && oldest <= newest)
        else { return .rejected(.invalidInvariant(field: 25)) }

        if retainedRecordCount == 0 {
            guard returnedStart == 0,
                  oldest == 0,
                  newest == 0,
                  !flags.contains(.moreEntries)
            else { return .rejected(.invalidInvariant(field: 26)) }
        } else {
            guard returnedStart == requestedStart,
                  oldest != 0,
                  requestedStart >= oldest,
                  requestedStart <= newest,
                  UInt64(retainedRecordCount - 1)
                    <= UInt64.max - requestedStart
            else { return .rejected(.invalidInvariant(field: 27)) }
            let last = requestedStart + UInt64(retainedRecordCount - 1)
            guard last <= newest else {
                return .rejected(.invalidInvariant(field: 28))
            }
            let expectedNext = last == UInt64.max ? 0 : last + 1
            guard next == expectedNext else {
                return .rejected(.invalidInvariant(field: 29))
            }
            if flags.contains(.moreEntries) {
                guard last < newest else {
                    return .rejected(.invalidInvariant(field: 30))
                }
            } else {
                guard last == newest else {
                    return .rejected(.invalidInvariant(field: 31))
                }
            }
        }

        var entries: [KernelLogEntry] = []
        entries.reserveCapacity(retainedRecordCount)
        var index = 0
        while index < retainedRecordCount {
            let offset = headerCount + index * KernelLogRing.recordByteCount
            let reserved = frame.payload[offset + 17]
            guard reserved == 0 else {
                return .rejected(
                    .nonzeroReserved(field: 32, rawValue: UInt64(reserved))
                )
            }
            guard let level = KernelLogLevel(rawValue: frame.payload[offset + 16])
            else {
                return .rejected(
                    .invalidEnum(
                        field: 33,
                        rawValue: UInt64(frame.payload[offset + 16])
                    )
                )
            }
            let sequence = SDBGWire.readUInt64(frame.payload, at: offset)
            guard sequence == requestedStart + UInt64(index) else {
                return .rejected(.invalidInvariant(field: 34))
            }
            entries.append(
                KernelLogEntry(
                    sequence: sequence,
                    event: KernelLogEvent(
                        timestampTicks: SDBGWire.readUInt64(
                            frame.payload,
                            at: offset + 8
                        ),
                        level: level,
                        subsystem: KernelLogSubsystem(
                            rawValue: SDBGPayloadWire.readUInt16(
                                frame.payload,
                                at: offset + 18
                            )
                        ),
                        eventCode: SDBGWire.readUInt32(
                            frame.payload,
                            at: offset + 20
                        ),
                        processorID: SDBGWire.readUInt32(
                            frame.payload,
                            at: offset + 24
                        ),
                        flags: SDBGWire.readUInt32(
                            frame.payload,
                            at: offset + 28
                        ),
                        argument0: SDBGWire.readUInt64(
                            frame.payload,
                            at: offset + 32
                        ),
                        argument1: SDBGWire.readUInt64(
                            frame.payload,
                            at: offset + 40
                        )
                    )
                )
            )
            index += 1
        }
        return .decoded(
            .logSnapshot(
                SwiftOSSDBGHostLogSnapshot(
                    requestedStartingSequence: requestedStart,
                    oldestAvailableSequence: oldest,
                    newestAvailableSequence: newest,
                    returnedStartingSequence: returnedStart,
                    nextSequence: next,
                    lostEntryCount: lost,
                    flags: flags,
                    entries: entries
                )
            )
        )
    }

    private static func identity(
        _ payload: UnsafeRawBufferPointer,
        at offset: Int
    ) -> KernelIdentity128? {
        KernelIdentity128(
            high: SDBGWire.readUInt64(payload, at: offset),
            low: SDBGWire.readUInt64(payload, at: offset + 8)
        )
    }

    private static func session(
        _ identity: KernelIdentity128
    ) -> SDBGBootSessionID {
        SDBGBootSessionID(high: identity.high, low: identity.low)
    }

    private static func session(
        _ identity: SDBGBootSessionID
    ) -> SDBGBootSessionID {
        identity
    }
}
