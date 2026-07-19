/// Caller-selected bounds advertised by the service. These are payload bounds,
/// excluding the SDBG envelope. They permit small early-boot transports while
/// never exceeding the protocol's fixed maximum.
struct SDBGServiceLimits: Equatable {
    let maximumRequestPayloadByteCount: UInt32
    let maximumResponsePayloadByteCount: UInt32
    let maximumLogEntriesPerResponse: UInt16

    init?(
        maximumRequestPayloadByteCount: UInt32,
        maximumResponsePayloadByteCount: UInt32,
        maximumLogEntriesPerResponse: UInt16
    ) {
        let largestPayload = UInt32(SDBGProtocol.maximumPayloadByteCount)
        let largestLogCount = UInt32(
            (SDBGProtocol.maximumPayloadByteCount
                - SDBGTypedPayloadProtocol.logSnapshotResponseHeaderByteCount)
                / KernelLogRing.recordByteCount
        )
        let configuredResponseByteCount = Int(
            maximumResponsePayloadByteCount
        )
        let configuredLogCount: UInt32
        if configuredResponseByteCount
                >= SDBGTypedPayloadProtocol.logSnapshotResponseHeaderByteCount {
            configuredLogCount = UInt32(
                (configuredResponseByteCount
                    - SDBGTypedPayloadProtocol
                        .logSnapshotResponseHeaderByteCount)
                    / KernelLogRing.recordByteCount
            )
        } else {
            configuredLogCount = 0
        }
        guard maximumRequestPayloadByteCount
                >= UInt32(SDBGTypedPayloadProtocol.logSnapshotRequestByteCount),
              maximumRequestPayloadByteCount <= largestPayload,
              maximumResponsePayloadByteCount
                >= UInt32(SDBGTypedPayloadProtocol.statusResponseByteCount),
              maximumResponsePayloadByteCount <= largestPayload,
              maximumLogEntriesPerResponse != 0,
              UInt32(maximumLogEntriesPerResponse) <= largestLogCount,
              UInt32(maximumLogEntriesPerResponse) <= configuredLogCount
        else { return nil }
        self.maximumRequestPayloadByteCount = maximumRequestPayloadByteCount
        self.maximumResponsePayloadByteCount = maximumResponsePayloadByteCount
        self.maximumLogEntriesPerResponse = maximumLogEntriesPerResponse
    }

    static var protocolMaximum: Self {
        Self(
            maximumRequestPayloadByteCount: UInt32(
                SDBGProtocol.maximumPayloadByteCount
            ),
            maximumResponsePayloadByteCount: UInt32(
                SDBGProtocol.maximumPayloadByteCount
            ),
            maximumLogEntriesPerResponse: UInt16(
                (SDBGProtocol.maximumPayloadByteCount
                    - SDBGTypedPayloadProtocol
                        .logSnapshotResponseHeaderByteCount)
                    / KernelLogRing.recordByteCount
            )
        )!
    }
}

/// Coherent read-only state sampled by the caller. Log lookup remains a
/// nonescaping provider so this layer neither owns the ring nor allocates a
/// snapshot copy. `KernelLogRing.entry(sequence:)` and a future synchronized
/// runtime adapter can both be injected directly.
struct SDBGServiceSnapshot {
    let bootIdentity: KernelBootIdentity
    let status: DebugStatusSnapshot
    let logStatistics: KernelLogStatistics

    init?(
        bootIdentity: KernelBootIdentity,
        status: DebugStatusSnapshot,
        logStatistics: KernelLogStatistics
    ) {
        guard bootIdentity.sessionID == status.bootSessionID,
              Self.validLogStatistics(logStatistics),
              Self.statusLogStateIsCoherent(
                  status,
                  statistics: logStatistics
              )
        else {
            return nil
        }
        self.bootIdentity = bootIdentity
        self.status = status
        self.logStatistics = logStatistics
    }

    private static func validLogStatistics(
        _ statistics: KernelLogStatistics
    ) -> Bool {
        guard statistics.capacity > 0,
              statistics.retainedCount >= 0,
              statistics.retainedCount <= statistics.capacity
        else { return false }
        if statistics.retainedCount == 0 {
            return statistics.oldestSequence == nil
                && statistics.newestSequence == nil
                && statistics.nextSequence != nil
        }
        guard let oldest = statistics.oldestSequence,
              let newest = statistics.newestSequence,
              oldest != 0,
              oldest <= newest,
              newest - oldest == UInt64(statistics.retainedCount - 1)
        else { return false }
        if newest == UInt64.max {
            return statistics.nextSequence == nil
        }
        return statistics.nextSequence == newest + 1
    }

    private static func statusLogStateIsCoherent(
        _ status: DebugStatusSnapshot,
        statistics: KernelLogStatistics
    ) -> Bool {
        status.oldestLogSequence == (statistics.oldestSequence ?? 0)
            && status.newestLogSequence == (statistics.newestSequence ?? 0)
            && status.lostLogEntryCount == saturatingAdd(
                statistics.overwrittenEntryCount,
                statistics.rejectedEntryCount
            )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }
}

enum SDBGServiceRejection: Equatable {
    case invalidOutputBuffer
    case outputBufferTooSmall(required: Int, available: Int)
    case requestPayloadExceedsLimit(requested: Int, maximum: UInt32)
    case invalidMessageKind(SDBGMessageKind)
    case encoderRejected(SDBGEncodeRejection)
}

enum SDBGServiceResult: Equatable {
    case emitted(byteCount: Int)
    case rejected(SDBGServiceRejection)
}

struct SDBGService {
    let limits: SDBGServiceLimits

    init(limits: SDBGServiceLimits = .protocolMaximum) {
        self.limits = limits
    }

    func emitHello(
        identity: KernelBootIdentity,
        into output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let payloadCount = SDBGTypedPayloadProtocol.helloByteCount
        if let rejection = prepare(output, payloadByteCount: payloadCount) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: payloadCount)
        writeTypedHeader(payloadByteCount: payloadCount, to: payload)
        payload[8] = SDBGProtocol.versionMajor
        payload[9] = SDBGProtocol.versionMinor
        SDBGPayloadWire.writeUInt16(0, to: payload, at: 10)
        writeIdentity(identity.sessionID, to: payload, at: 12)
        writeIdentity(identity.build.buildID, to: payload, at: 28)
        SDBGPayloadWire.writeUInt16(
            KernelBuildIdentity.schemaVersion,
            to: payload,
            at: 44
        )
        SDBGPayloadWire.writeUInt16(
            KernelBootIdentity.schemaVersion,
            to: payload,
            at: 46
        )
        return encode(
            kind: .hello,
            flags: .none,
            identity: identity,
            requestID: 0,
            payloadByteCount: payloadCount,
            output: output
        )
    }

    func emitCapabilities(
        identity: KernelBootIdentity,
        into output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let payloadCount = SDBGTypedPayloadProtocol.capabilitiesByteCount
        if let rejection = prepare(output, payloadByteCount: payloadCount) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: payloadCount)
        writeTypedHeader(payloadByteCount: payloadCount, to: payload)
        SDBGWire.writeUInt32(
            SDBGCapabilitySet.readOnlyV1.rawValue,
            to: payload,
            at: 8
        )
        SDBGWire.writeUInt32(
            limits.maximumRequestPayloadByteCount,
            to: payload,
            at: 12
        )
        SDBGWire.writeUInt32(
            limits.maximumResponsePayloadByteCount,
            to: payload,
            at: 16
        )
        SDBGPayloadWire.writeUInt16(
            UInt16(KernelLogRing.recordByteCount),
            to: payload,
            at: 20
        )
        SDBGPayloadWire.writeUInt16(
            limits.maximumLogEntriesPerResponse,
            to: payload,
            at: 22
        )
        return encode(
            kind: .capabilities,
            flags: .none,
            identity: identity,
            requestID: 0,
            payloadByteCount: payloadCount,
            output: output
        )
    }

    func handleRequest(
        _ frame: SDBGDecodedFrame,
        snapshot: SDBGServiceSnapshot,
        lookupLogEntry: (UInt64) -> KernelLogLookupResult,
        into output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        guard frame.envelope.kind == .request else {
            return .rejected(.invalidMessageKind(frame.envelope.kind))
        }
        guard frame.payload.count
                <= Int(limits.maximumRequestPayloadByteCount)
        else {
            return emitError(
                operationRawValue: operationRawValue(in: frame.payload),
                status: .requestTooLarge,
                detail0: UInt64(frame.payload.count),
                detail1: UInt64(limits.maximumRequestPayloadByteCount),
                requestID: frame.envelope.requestID,
                identity: snapshot.bootIdentity,
                output: output
            )
        }

        let currentSession = sessionID(for: snapshot.bootIdentity)
        guard frame.envelope.bootSessionID == currentSession else {
            return emitError(
                operationRawValue: operationRawValue(in: frame.payload),
                status: .bootSessionMismatch,
                detail0: currentSession.high,
                detail1: currentSession.low,
                requestID: frame.envelope.requestID,
                identity: snapshot.bootIdentity,
                output: output
            )
        }

        switch SDBGRequestCodec.decode(frame.payload) {
        case .request(let request):
            return respond(
                to: request,
                requestID: frame.envelope.requestID,
                snapshot: snapshot,
                lookupLogEntry: lookupLogEntry,
                output: output
            )
        case .rejected(let rejection):
            let mapped = responseError(for: rejection)
            return emitError(
                operationRawValue: operationRawValue(in: frame.payload),
                status: mapped.status,
                detail0: mapped.detail0,
                detail1: mapped.detail1,
                requestID: frame.envelope.requestID,
                identity: snapshot.bootIdentity,
                output: output
            )
        }
    }

    private func respond(
        to request: SDBGRequest,
        requestID: UInt64,
        snapshot: SDBGServiceSnapshot,
        lookupLogEntry: (UInt64) -> KernelLogLookupResult,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        switch request {
        case .identity:
            return emitIdentity(
                snapshot.bootIdentity,
                requestID: requestID,
                output: output
            )
        case .status:
            return emitStatus(
                snapshot.status,
                identity: snapshot.bootIdentity,
                requestID: requestID,
                output: output
            )
        case .ping(let token):
            return emitPing(
                token,
                identity: snapshot.bootIdentity,
                requestID: requestID,
                output: output
            )
        case .logSnapshot(let request):
            return emitLogSnapshot(
                request,
                statistics: snapshot.logStatistics,
                lookupLogEntry: lookupLogEntry,
                identity: snapshot.bootIdentity,
                requestID: requestID,
                output: output
            )
        }
    }

    private func emitIdentity(
        _ identity: KernelBootIdentity,
        requestID: UInt64,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let count = SDBGTypedPayloadProtocol.identityResponseByteCount
        if let rejection = prepare(output, payloadByteCount: count) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: count)
        writeResponseHeader(
            operation: .identity,
            status: .success,
            payloadByteCount: count,
            to: payload
        )
        SDBGPayloadWire.writeUInt16(
            KernelBuildIdentity.schemaVersion,
            to: payload,
            at: 12
        )
        SDBGPayloadWire.writeUInt16(
            KernelBootIdentity.schemaVersion,
            to: payload,
            at: 14
        )
        SDBGPayloadWire.writeUInt16(identity.build.abiRevision, to: payload, at: 16)
        payload[18] = identity.build.flavor.rawValue
        payload[19] = identity.reason.rawValue
        writeIdentity(identity.sessionID, to: payload, at: 20)
        writeIdentity(identity.build.buildID, to: payload, at: 36)
        SDBGWire.writeUInt64(identity.build.sourceRevision, to: payload, at: 52)
        SDBGWire.writeUInt64(
            identity.build.imageDigestPrefix,
            to: payload,
            at: 60
        )
        SDBGWire.writeUInt64(identity.bootOrdinal, to: payload, at: 68)
        SDBGWire.writeUInt64(identity.startedAtTicks, to: payload, at: 76)
        return encodeResponse(
            identity: identity,
            requestID: requestID,
            payloadByteCount: count,
            output: output
        )
    }

    private func emitStatus(
        _ status: DebugStatusSnapshot,
        identity: KernelBootIdentity,
        requestID: UInt64,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let count = SDBGTypedPayloadProtocol.statusResponseByteCount
        if let rejection = prepare(output, payloadByteCount: count) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: count)
        writeResponseHeader(
            operation: .status,
            status: .success,
            payloadByteCount: count,
            to: payload
        )
        SDBGWire.writeUInt64(status.snapshotSequence, to: payload, at: 12)
        SDBGWire.writeUInt64(status.monotonicTicks, to: payload, at: 20)
        writeIdentity(status.bootSessionID, to: payload, at: 28)
        payload[44] = status.phase.rawValue
        payload[45] = status.displayState.rawValue
        payload[46] = status.debugLinkState.rawValue
        payload[47] = status.updateState.rawValue
        SDBGWire.writeUInt32(status.flags.rawValue, to: payload, at: 48)
        SDBGPayloadWire.writeUInt16(
            status.configuredProcessorCount,
            to: payload,
            at: 52
        )
        SDBGPayloadWire.writeUInt16(
            status.onlineProcessorCount,
            to: payload,
            at: 54
        )
        SDBGWire.writeUInt32(status.runnableThreadCount, to: payload, at: 56)
        SDBGWire.writeUInt64(status.managedMemoryByteCount, to: payload, at: 60)
        SDBGWire.writeUInt64(status.freeMemoryByteCount, to: payload, at: 68)
        SDBGWire.writeUInt32(status.displayWidthPixels, to: payload, at: 76)
        SDBGWire.writeUInt32(status.displayHeightPixels, to: payload, at: 80)
        SDBGWire.writeUInt32(
            status.displayRefreshMilliHertz,
            to: payload,
            at: 84
        )
        SDBGWire.writeUInt32(0, to: payload, at: 88)
        SDBGWire.writeUInt64(status.oldestLogSequence, to: payload, at: 92)
        SDBGWire.writeUInt64(status.newestLogSequence, to: payload, at: 100)
        SDBGWire.writeUInt64(status.lostLogEntryCount, to: payload, at: 108)
        SDBGPayloadWire.writeUInt16(status.lastError.domain, to: payload, at: 116)
        SDBGPayloadWire.writeUInt16(status.lastError.code, to: payload, at: 118)
        SDBGWire.writeUInt32(status.lastError.detail, to: payload, at: 120)
        return encodeResponse(
            identity: identity,
            requestID: requestID,
            payloadByteCount: count,
            output: output
        )
    }

    private func emitPing(
        _ token: UInt64,
        identity: KernelBootIdentity,
        requestID: UInt64,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let count = SDBGTypedPayloadProtocol.pingResponseByteCount
        if let rejection = prepare(output, payloadByteCount: count) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: count)
        writeResponseHeader(
            operation: .ping,
            status: .success,
            payloadByteCount: count,
            to: payload
        )
        SDBGWire.writeUInt64(token, to: payload, at: 12)
        return encodeResponse(
            identity: identity,
            requestID: requestID,
            payloadByteCount: count,
            output: output
        )
    }

    private func emitLogSnapshot(
        _ request: SDBGLogSnapshotRequest,
        statistics: KernelLogStatistics,
        lookupLogEntry: (UInt64) -> KernelLogLookupResult,
        identity: KernelBootIdentity,
        requestID: UInt64,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        if let oldest = statistics.oldestSequence,
           request.startingSequence < oldest {
            return emitError(
                operationRawValue: SDBGOperation.logSnapshot.rawValue,
                status: .logSequenceLost,
                detail0: oldest,
                detail1: statistics.newestSequence ?? 0,
                requestID: requestID,
                identity: identity,
                output: output
            )
        }
        if let newest = statistics.newestSequence,
           request.startingSequence > newest {
            return emitError(
                operationRawValue: SDBGOperation.logSnapshot.rawValue,
                status: .logSequenceNotYetWritten,
                detail0: newest,
                detail1: statistics.nextSequence ?? 0,
                requestID: requestID,
                identity: identity,
                output: output
            )
        }

        let headerCount = SDBGTypedPayloadProtocol
            .logSnapshotResponseHeaderByteCount
        if let rejection = prepare(output, payloadByteCount: headerCount) {
            return rejection
        }
        let outputPayloadCapacity = output.count - SDBGProtocol.headerByteCount
        let boundedPayloadCapacity = outputPayloadCapacity
            < Int(limits.maximumResponsePayloadByteCount)
            ? outputPayloadCapacity
            : Int(limits.maximumResponsePayloadByteCount)
        var capacity = (boundedPayloadCapacity - headerCount)
            / KernelLogRing.recordByteCount
        let configuredLimit = Int(limits.maximumLogEntriesPerResponse)
        if capacity > configuredLimit { capacity = configuredLimit }
        let requestedLimit = Int(request.maximumEntryCount)
        if capacity > requestedLimit { capacity = requestedLimit }
        if capacity == 0, statistics.newestSequence != nil {
            return .rejected(
                .outputBufferTooSmall(
                    required: SDBGProtocol.headerByteCount
                        + headerCount
                        + KernelLogRing.recordByteCount,
                    available: output.count
                )
            )
        }

        var recordsWritten = 0
        var sequence = request.startingSequence
        var providerInconsistent = false
        while recordsWritten < capacity {
            guard let newest = statistics.newestSequence,
                  sequence <= newest
            else { break }
            switch lookupLogEntry(sequence) {
            case .entry(let entry):
                guard entry.sequence == sequence else {
                    providerInconsistent = true
                    break
                }
                let payload = mutablePayload(
                    in: output,
                    count: headerCount
                        + (recordsWritten + 1) * KernelLogRing.recordByteCount
                )
                writeLogEntry(
                    entry,
                    to: payload,
                    at: headerCount
                        + recordsWritten * KernelLogRing.recordByteCount
                )
                recordsWritten += 1
                if sequence == UInt64.max { break }
                sequence += 1
            case .lost, .notYetWritten:
                providerInconsistent = true
            }
            if providerInconsistent { break }
        }
        if providerInconsistent {
            return emitError(
                operationRawValue: SDBGOperation.logSnapshot.rawValue,
                status: .logProviderInconsistent,
                detail0: sequence,
                detail1: recordsWritten == 0 ? 0 : UInt64(recordsWritten),
                requestID: requestID,
                identity: identity,
                output: output
            )
        }

        let newest = statistics.newestSequence ?? 0
        let lastReturned = recordsWritten == 0
            ? 0
            : request.startingSequence + UInt64(recordsWritten - 1)
        let hasMore = recordsWritten != 0 && lastReturned < newest
        let nextSequence: UInt64
        if recordsWritten == 0 {
            nextSequence = statistics.nextSequence ?? 0
        } else if lastReturned == UInt64.max {
            nextSequence = 0
        } else {
            nextSequence = lastReturned + 1
        }
        var responseFlags = SDBGLogSnapshotResponseFlags(rawValue: 0)
        if hasMore {
            responseFlags = SDBGLogSnapshotResponseFlags(
                rawValue: responseFlags.rawValue
                    | SDBGLogSnapshotResponseFlags.moreEntries.rawValue
            )
        }
        if statistics.nextSequence == nil {
            responseFlags = SDBGLogSnapshotResponseFlags(
                rawValue: responseFlags.rawValue
                    | SDBGLogSnapshotResponseFlags.sequenceExhausted.rawValue
            )
        }

        let count = headerCount
            + recordsWritten * KernelLogRing.recordByteCount
        let payload = mutablePayload(in: output, count: count)
        writeResponseHeader(
            operation: .logSnapshot,
            status: .success,
            payloadByteCount: count,
            to: payload
        )
        SDBGWire.writeUInt64(request.startingSequence, to: payload, at: 12)
        SDBGWire.writeUInt64(statistics.oldestSequence ?? 0, to: payload, at: 20)
        SDBGWire.writeUInt64(newest, to: payload, at: 28)
        SDBGWire.writeUInt64(
            recordsWritten == 0 ? 0 : request.startingSequence,
            to: payload,
            at: 36
        )
        SDBGWire.writeUInt64(nextSequence, to: payload, at: 44)
        SDBGWire.writeUInt64(
            saturatingAdd(
                statistics.overwrittenEntryCount,
                statistics.rejectedEntryCount
            ),
            to: payload,
            at: 52
        )
        SDBGWire.writeUInt32(UInt32(recordsWritten), to: payload, at: 60)
        SDBGPayloadWire.writeUInt16(
            UInt16(KernelLogRing.recordByteCount),
            to: payload,
            at: 64
        )
        SDBGPayloadWire.writeUInt16(responseFlags.rawValue, to: payload, at: 66)
        return encode(
            kind: .response,
            flags: hasMore ? .moreFragments : .none,
            identity: identity,
            requestID: requestID,
            payloadByteCount: count,
            output: output
        )
    }

    private func emitError(
        operationRawValue: UInt16,
        status: SDBGResponseStatus,
        detail0: UInt64,
        detail1: UInt64,
        requestID: UInt64,
        identity: KernelBootIdentity,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let count = SDBGTypedPayloadProtocol.errorResponseByteCount
        if let rejection = prepare(output, payloadByteCount: count) {
            return rejection
        }
        let payload = mutablePayload(in: output, count: count)
        writeResponseHeader(
            operationRawValue: operationRawValue,
            status: status,
            payloadByteCount: count,
            to: payload
        )
        SDBGWire.writeUInt64(detail0, to: payload, at: 12)
        SDBGWire.writeUInt64(detail1, to: payload, at: 20)
        return encode(
            kind: .response,
            flags: .error,
            identity: identity,
            requestID: requestID,
            payloadByteCount: count,
            output: output
        )
    }

    private func prepare(
        _ output: UnsafeMutableRawBufferPointer,
        payloadByteCount: Int
    ) -> SDBGServiceResult? {
        guard output.count == 0 || output.baseAddress != nil else {
            return .rejected(.invalidOutputBuffer)
        }
        let required = SDBGProtocol.headerByteCount + payloadByteCount
        guard output.count >= required else {
            return .rejected(
                .outputBufferTooSmall(required: required, available: output.count)
            )
        }
        guard payloadByteCount <= Int(limits.maximumResponsePayloadByteCount)
        else {
            return .rejected(
                .outputBufferTooSmall(
                    required: required,
                    available: SDBGProtocol.headerByteCount
                        + Int(limits.maximumResponsePayloadByteCount)
                )
            )
        }
        return nil
    }

    private func mutablePayload(
        in output: UnsafeMutableRawBufferPointer,
        count: Int
    ) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: output.baseAddress!.advanced(by: SDBGProtocol.headerByteCount),
            count: count
        )
    }

    private func writeTypedHeader(
        payloadByteCount: Int,
        to payload: UnsafeMutableRawBufferPointer
    ) {
        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.schemaVersion,
            to: payload,
            at: 0
        )
        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.typedHeaderByteCount,
            to: payload,
            at: 2
        )
        SDBGWire.writeUInt32(UInt32(payloadByteCount), to: payload, at: 4)
    }

    private func writeResponseHeader(
        operation: SDBGOperation,
        status: SDBGResponseStatus,
        payloadByteCount: Int,
        to payload: UnsafeMutableRawBufferPointer
    ) {
        writeResponseHeader(
            operationRawValue: operation.rawValue,
            status: status,
            payloadByteCount: payloadByteCount,
            to: payload
        )
    }

    private func writeResponseHeader(
        operationRawValue: UInt16,
        status: SDBGResponseStatus,
        payloadByteCount: Int,
        to payload: UnsafeMutableRawBufferPointer
    ) {
        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.schemaVersion,
            to: payload,
            at: 0
        )
        SDBGPayloadWire.writeUInt16(
            SDBGTypedPayloadProtocol.responseHeaderByteCount,
            to: payload,
            at: 2
        )
        SDBGWire.writeUInt32(UInt32(payloadByteCount), to: payload, at: 4)
        SDBGPayloadWire.writeUInt16(operationRawValue, to: payload, at: 8)
        SDBGPayloadWire.writeUInt16(status.rawValue, to: payload, at: 10)
    }

    private func encodeResponse(
        identity: KernelBootIdentity,
        requestID: UInt64,
        payloadByteCount: Int,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        encode(
            kind: .response,
            flags: .none,
            identity: identity,
            requestID: requestID,
            payloadByteCount: payloadByteCount,
            output: output
        )
    }

    private func encode(
        kind: SDBGMessageKind,
        flags: SDBGMessageFlags,
        identity: KernelBootIdentity,
        requestID: UInt64,
        payloadByteCount: Int,
        output: UnsafeMutableRawBufferPointer
    ) -> SDBGServiceResult {
        let payload = UnsafeRawBufferPointer(
            start: output.baseAddress!.advanced(by: SDBGProtocol.headerByteCount),
            count: payloadByteCount
        )
        let result = SDBGFrameEncoder.encode(
            envelope: SDBGEnvelope(
                kind: kind,
                flags: flags,
                bootSessionID: sessionID(for: identity),
                requestID: requestID
            ),
            payload: payload,
            into: output
        )
        switch result {
        case .encoded(let byteCount):
            return .emitted(byteCount: byteCount)
        case .rejected(let rejection):
            return .rejected(.encoderRejected(rejection))
        }
    }

    private func writeIdentity(
        _ identity: KernelIdentity128,
        to output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        SDBGWire.writeUInt64(identity.high, to: output, at: offset)
        SDBGWire.writeUInt64(identity.low, to: output, at: offset + 8)
    }

    private func sessionID(for identity: KernelBootIdentity) -> SDBGBootSessionID {
        SDBGBootSessionID(
            high: identity.sessionID.high,
            low: identity.sessionID.low
        )
    }

    private func operationRawValue(
        in payload: UnsafeRawBufferPointer
    ) -> UInt16 {
        guard payload.count >= 10, payload.baseAddress != nil else { return 0 }
        return SDBGPayloadWire.readUInt16(payload, at: 8)
    }

    private func responseError(
        for rejection: SDBGRequestRejection
    ) -> (status: SDBGResponseStatus, detail0: UInt64, detail1: UInt64) {
        switch rejection {
        case .unsupportedSchema(let schema):
            return (.unsupportedSchema, UInt64(schema), 0)
        case .unsupportedOperation(let operation):
            return (.unsupportedOperation, UInt64(operation), 0)
        case .unsupportedFlags(let flags):
            return (.unsupportedFlags, UInt64(flags), 0)
        case .invalidArgument(_, let field):
            return (.invalidArgument, UInt64(field), 0)
        case .tooShort(let required, let available):
            return (.malformedRequest, UInt64(required), UInt64(available))
        case .invalidOperationByteCount(_, let required, let actual):
            return (.malformedRequest, UInt64(required), UInt64(actual))
        case .byteCountMismatch(let declared, let actual):
            return (.malformedRequest, UInt64(declared), UInt64(actual))
        case .invalidHeaderByteCount(let header):
            return (
                .malformedRequest,
                UInt64(SDBGTypedPayloadProtocol.requestHeaderByteCount),
                UInt64(header)
            )
        case .invalidBuffer:
            return (.malformedRequest, 0, 0)
        }
    }

    private func writeLogEntry(
        _ entry: KernelLogEntry,
        to output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        SDBGWire.writeUInt64(entry.sequence, to: output, at: offset)
        SDBGWire.writeUInt64(entry.event.timestampTicks, to: output, at: offset + 8)
        output[offset + 16] = entry.event.level.rawValue
        output[offset + 17] = 0
        SDBGPayloadWire.writeUInt16(
            entry.event.subsystem.rawValue,
            to: output,
            at: offset + 18
        )
        SDBGWire.writeUInt32(entry.event.eventCode, to: output, at: offset + 20)
        SDBGWire.writeUInt32(entry.event.processorID, to: output, at: offset + 24)
        SDBGWire.writeUInt32(entry.event.flags, to: output, at: offset + 28)
        SDBGWire.writeUInt64(entry.event.argument0, to: output, at: offset + 32)
        SDBGWire.writeUInt64(entry.event.argument1, to: output, at: offset + 40)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }
}
