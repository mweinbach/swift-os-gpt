@main
struct SDBGServiceTests {
    static func main() {
        validatesTypedRequestCodec()
        emitsVersionedHelloAndCapabilities()
        servesIdentityStatusAndPing()
        paginatesLogSnapshotsWithoutAllocatingInService()
        reportsLogLossFutureAndProviderInconsistency()
        rejectsMalformedSessionAndBufferInputs()
        print("SDBG typed service: 6 groups passed")
    }

    private static func validatesTypedRequestCodec() {
        let cases: [SDBGRequest] = [
            .identity,
            .status,
            .ping(token: 0x0102_0304_0506_0708),
            .logSnapshot(
                SDBGLogSnapshotRequest(
                    startingSequence: 0x1112_1314_1516_1718,
                    maximumEntryCount: 37
                )
            ),
        ]
        for request in cases {
            var bytes = [UInt8](repeating: 0, count: 24)
            let count = bytes.withUnsafeMutableBytes {
                SDBGRequestCodec.encode(request, into: $0)
            }
            guard let count else { fail("typed request did not encode") }
            let result = bytes.withUnsafeBytes {
                SDBGRequestCodec.decode(
                    UnsafeRawBufferPointer(
                        start: $0.baseAddress,
                        count: count
                    )
                )
            }
            expect(result == .request(request), "typed request changed")
        }

        var malformed = encodeRequestPayload(.identity)
        malformed[0] = 2
        expect(
            decodeRequest(malformed) == .rejected(.unsupportedSchema(2)),
            "unsupported request schema was accepted"
        )
        malformed = encodeRequestPayload(.identity)
        malformed[2] = 8
        expect(
            decodeRequest(malformed)
                == .rejected(.invalidHeaderByteCount(8)),
            "invalid request header size was accepted"
        )
        malformed = encodeRequestPayload(.identity)
        malformed[4] = 13
        expect(
            decodeRequest(malformed)
                == .rejected(.byteCountMismatch(declared: 13, actual: 12)),
            "invalid declared request size was accepted"
        )
        malformed = encodeRequestPayload(.identity)
        malformed[8] = 0xff
        malformed[9] = 0xff
        expect(
            decodeRequest(malformed)
                == .rejected(.unsupportedOperation(UInt16.max)),
            "unknown operation was accepted"
        )
        malformed = encodeRequestPayload(.identity)
        malformed[10] = 1
        expect(
            decodeRequest(malformed) == .rejected(.unsupportedFlags(1)),
            "request flags were accepted"
        )
        malformed = encodeRequestPayload(
            .logSnapshot(
                SDBGLogSnapshotRequest(startingSequence: 1, maximumEntryCount: 1)
            )
        )
        write64(0, to: &malformed, at: 12)
        expect(
            decodeRequest(malformed)
                == .rejected(
                    .invalidArgument(operation: .logSnapshot, field: 1)
                ),
            "zero log sequence was accepted"
        )
        write64(1, to: &malformed, at: 12)
        write32(0, to: &malformed, at: 20)
        expect(
            decodeRequest(malformed)
                == .rejected(
                    .invalidArgument(operation: .logSnapshot, field: 2)
                ),
            "zero log count was accepted"
        )
    }

    private static func emitsVersionedHelloAndCapabilities() {
        let identity = makeIdentity()
        let limits = SDBGServiceLimits(
            maximumRequestPayloadByteCount: 128,
            maximumResponsePayloadByteCount: 164,
            maximumLogEntriesPerResponse: 2
        )!
        let service = SDBGService(limits: limits)

        let hello = emit { output in
            service.emitHello(identity: identity, into: output)
        }
        withDecodedFrame(hello) { frame in
            expect(frame.envelope.kind == .hello, "HELLO kind")
            expect(frame.payload.count == 48, "HELLO length")
            expect(read16(frame.payload, at: 0) == 1, "HELLO schema")
            expect(read16(frame.payload, at: 2) == 8, "HELLO header")
            expect(read32(frame.payload, at: 4) == 48, "HELLO byte count")
            expect(frame.payload[8] == 1 && frame.payload[9] == 0,
                   "HELLO protocol version")
            expect(read64(frame.payload, at: 12) == identity.sessionID.high,
                   "HELLO session high truncated")
            expect(read64(frame.payload, at: 20) == identity.sessionID.low,
                   "HELLO session low truncated")
            expect(read64(frame.payload, at: 28) == identity.build.buildID.high,
                   "HELLO build high truncated")
            expect(read64(frame.payload, at: 36) == identity.build.buildID.low,
                   "HELLO build low truncated")
            guard case .hello(let decoded)
                    = SDBGDiscoveryPayloadCodec.decodeHello(frame.payload)
            else { fail("typed HELLO did not decode") }
            expect(decoded.bootSessionID == session(identity),
                   "typed HELLO session changed")
            expect(decoded.buildID == identity.build.buildID,
                   "typed HELLO build changed")
        }

        let capabilities = emit { output in
            service.emitCapabilities(identity: identity, into: output)
        }
        withDecodedFrame(capabilities) { frame in
            expect(frame.envelope.kind == .capabilities, "capabilities kind")
            expect(frame.payload.count == 24, "capabilities length")
            let set = SDBGCapabilitySet(
                rawValue: read32(frame.payload, at: 8)
            )
            expect(set == .readOnlyV1, "capability set changed")
            expect(set.contains(.identity) && set.contains(.status),
                   "core capability missing")
            expect(read32(frame.payload, at: 12) == 128,
                   "request limit changed")
            expect(read32(frame.payload, at: 16) == 164,
                   "response limit changed")
            expect(read16(frame.payload, at: 20) == 48,
                   "log record size changed")
            expect(read16(frame.payload, at: 22) == 2,
                   "log response limit changed")
            guard case .capabilities(let decoded)
                    = SDBGDiscoveryPayloadCodec.decodeCapabilities(frame.payload)
            else { fail("typed capabilities did not decode") }
            expect(decoded.capabilities == .readOnlyV1,
                   "typed capability set changed")
            expect(decoded.maximumLogEntriesPerResponse == 2,
                   "typed log limit changed")
        }

        expect(
            SDBGServiceLimits(
                maximumRequestPayloadByteCount: 23,
                maximumResponsePayloadByteCount: 164,
                maximumLogEntriesPerResponse: 2
            ) == nil,
            "undersized request limit accepted"
        )
        expect(
            SDBGServiceLimits(
                maximumRequestPayloadByteCount: 24,
                maximumResponsePayloadByteCount: 124,
                maximumLogEntriesPerResponse: 2
            ) == nil,
            "unrepresentable log capability accepted"
        )
        expect(
            SDBGServiceLimits(
                maximumRequestPayloadByteCount: 24,
                maximumResponsePayloadByteCount: 0,
                maximumLogEntriesPerResponse: 1
            ) == nil,
            "zero response limit trapped or was accepted"
        )

        let identityForInvalidSnapshot = makeIdentity()
        let inconsistentStatistics = KernelLogStatistics(
            capacity: 2,
            retainedCount: 2,
            oldestSequence: 9,
            newestSequence: 9,
            nextSequence: 10,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
        expect(
            SDBGServiceSnapshot(
                bootIdentity: identityForInvalidSnapshot,
                status: makeStatus(
                    identity: identityForInvalidSnapshot,
                    logStatistics: inconsistentStatistics
                ),
                logStatistics: inconsistentStatistics
            ) == nil,
            "inconsistent log snapshot was accepted"
        )

        let emptyStatistics = KernelLogStatistics(
            capacity: 2,
            retainedCount: 0,
            oldestSequence: nil,
            newestSequence: nil,
            nextSequence: 1,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
        let oneEntryStatistics = KernelLogStatistics(
            capacity: 2,
            retainedCount: 1,
            oldestSequence: 1,
            newestSequence: 1,
            nextSequence: 2,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
        expect(
            SDBGServiceSnapshot(
                bootIdentity: identityForInvalidSnapshot,
                status: makeStatus(
                    identity: identityForInvalidSnapshot,
                    logStatistics: emptyStatistics
                ),
                logStatistics: oneEntryStatistics
            ) == nil,
            "status and retained-log cursors were allowed to disagree"
        )
    }

    private static func servesIdentityStatusAndPing() {
        withRing(capacity: 2) { ring in
            let identity = makeIdentity()
            let status = makeStatus(
                identity: identity,
                logStatistics: ring.statistics
            )
            let snapshot = SDBGServiceSnapshot(
                bootIdentity: identity,
                status: status,
                logStatistics: ring.statistics
            )!
            let service = SDBGService()

            let identityResponse = transact(
                .identity,
                requestID: 41,
                service: service,
                snapshot: snapshot,
                ring: ring
            )
            withDecodedFrame(identityResponse) { frame in
                expect(frame.envelope.kind == .response, "identity kind")
                expect(frame.envelope.requestID == 41, "identity request ID")
                expectSuccess(frame.payload, operation: .identity, count: 84)
                expect(read64(frame.payload, at: 20) == identity.sessionID.high,
                       "identity session high truncated")
                expect(read64(frame.payload, at: 28) == identity.sessionID.low,
                       "identity session low truncated")
                expect(read64(frame.payload, at: 36) == identity.build.buildID.high,
                       "identity build high truncated")
                expect(read64(frame.payload, at: 44) == identity.build.buildID.low,
                       "identity build low truncated")
                expect(read64(frame.payload, at: 52)
                        == identity.build.sourceRevision,
                       "identity source revision")
                expect(read64(frame.payload, at: 60)
                        == identity.build.imageDigestPrefix,
                       "identity digest")
            }

            let statusResponse = transact(
                .status,
                requestID: 42,
                service: service,
                snapshot: snapshot,
                ring: ring
            )
            withDecodedFrame(statusResponse) { frame in
                expectSuccess(frame.payload, operation: .status, count: 124)
                expect(read64(frame.payload, at: 12) == status.snapshotSequence,
                       "status sequence")
                expect(read64(frame.payload, at: 28) == identity.sessionID.high,
                       "status session high truncated")
                expect(read64(frame.payload, at: 36) == identity.sessionID.low,
                       "status session low truncated")
                expect(read32(frame.payload, at: 76) == 3840,
                       "status display width")
                expect(read64(frame.payload, at: 108) == 0,
                       "status lost-log count")
                expect(read16(frame.payload, at: 116) == 3,
                       "status error domain")
            }

            let token: UInt64 = 0xfedc_ba98_7654_3210
            let pingResponse = transact(
                .ping(token: token),
                requestID: 43,
                service: service,
                snapshot: snapshot,
                ring: ring
            )
            withDecodedFrame(pingResponse) { frame in
                expectSuccess(frame.payload, operation: .ping, count: 20)
                expect(read64(frame.payload, at: 12) == token,
                       "ping token changed")
            }
        }
    }

    private static func paginatesLogSnapshotsWithoutAllocatingInService() {
        withRing(capacity: 4) { ring in
            var ring = ring
            _ = ring.append(logEvent(code: 10, argument0: 0x1111))
            _ = ring.append(logEvent(code: 20, argument0: 0x2222))
            _ = ring.append(logEvent(code: 30, argument0: 0x3333))
            let identity = makeIdentity()
            let snapshot = SDBGServiceSnapshot(
                bootIdentity: identity,
                status: makeStatus(
                    identity: identity,
                    logStatistics: ring.statistics
                ),
                logStatistics: ring.statistics
            )!
            let service = SDBGService(
                limits: SDBGServiceLimits(
                    maximumRequestPayloadByteCount: 64,
                    maximumResponsePayloadByteCount: 164,
                    maximumLogEntriesPerResponse: 2
                )!
            )
            let response = transact(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 1,
                        maximumEntryCount: 99
                    )
                ),
                requestID: 50,
                service: service,
                snapshot: snapshot,
                ring: ring,
                outputByteCount: 512
            )
            withDecodedFrame(response) { frame in
                expect(frame.envelope.flags == .moreFragments,
                       "log continuation envelope flag")
                expectSuccess(frame.payload, operation: .logSnapshot, count: 164)
                expect(read64(frame.payload, at: 12) == 1, "requested sequence")
                expect(read64(frame.payload, at: 20) == 1, "oldest sequence")
                expect(read64(frame.payload, at: 28) == 3, "newest sequence")
                expect(read64(frame.payload, at: 36) == 1, "first returned")
                expect(read64(frame.payload, at: 44) == 3, "next sequence")
                expect(read32(frame.payload, at: 60) == 2, "record count")
                expect(read16(frame.payload, at: 64) == 48, "record size")
                let flags = SDBGLogSnapshotResponseFlags(
                    rawValue: read16(frame.payload, at: 66)
                )
                expect(flags.contains(.moreEntries), "log more flag")
                expect(read64(frame.payload, at: 68) == 1, "first log sequence")
                expect(read32(frame.payload, at: 88) == 10, "first event code")
                expect(read64(frame.payload, at: 100) == 0x1111,
                       "first event argument")
                expect(read64(frame.payload, at: 116) == 2, "second log sequence")
                expect(read32(frame.payload, at: 136) == 20, "second event code")
            }

            let boundedRequest = requestFrame(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 1,
                        maximumEntryCount: 3
                    )
                ),
                requestID: 51,
                identity: identity
            )
            withDecodedFrame(boundedRequest) { frame in
                var output = [UInt8](repeating: 0, count: 108)
                let result = output.withUnsafeMutableBytes {
                    SDBGService().handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { ring.entry(sequence: $0) },
                        into: $0
                    )
                }
                expect(
                    result == .rejected(
                        .outputBufferTooSmall(required: 156, available: 108)
                    ),
                    "no-progress log page was emitted"
                )
            }
        }
    }

    private static func reportsLogLossFutureAndProviderInconsistency() {
        withRing(capacity: 2) { initial in
            var ring = initial
            _ = ring.append(logEvent(code: 1))
            _ = ring.append(logEvent(code: 2))
            _ = ring.append(logEvent(code: 3))
            let identity = makeIdentity()
            let snapshot = SDBGServiceSnapshot(
                bootIdentity: identity,
                status: makeStatus(
                    identity: identity,
                    logStatistics: ring.statistics
                ),
                logStatistics: ring.statistics
            )!

            let lost = transact(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 1,
                        maximumEntryCount: 1
                    )
                ),
                requestID: 60,
                service: SDBGService(),
                snapshot: snapshot,
                ring: ring
            )
            expectError(
                lost,
                operation: .logSnapshot,
                status: .logSequenceLost,
                detail0: 2,
                detail1: 3
            )

            let future = transact(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 4,
                        maximumEntryCount: 1
                    )
                ),
                requestID: 61,
                service: SDBGService(),
                snapshot: snapshot,
                ring: ring
            )
            expectError(
                future,
                operation: .logSnapshot,
                status: .logSequenceNotYetWritten,
                detail0: 3,
                detail1: 4
            )

            let request = requestFrame(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 2,
                        maximumEntryCount: 1
                    )
                ),
                requestID: 62,
                identity: identity
            )
            let inconsistent = withDecodedFrameReturning(request) { frame in
                emit { output in
                    SDBGService().handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { _ in .notYetWritten },
                        into: output
                    )
                }
            }
            expectError(
                inconsistent,
                operation: .logSnapshot,
                status: .logProviderInconsistent,
                detail0: 2,
                detail1: 0
            )
        }
    }

    private static func rejectsMalformedSessionAndBufferInputs() {
        withRing(capacity: 1) { ring in
            let identity = makeIdentity()
            let snapshot = SDBGServiceSnapshot(
                bootIdentity: identity,
                status: makeStatus(
                    identity: identity,
                    logStatistics: ring.statistics
                ),
                logStatistics: ring.statistics
            )!
            var malformed = encodeRequestPayload(.identity)
            malformed[0] = 2
            let malformedFrame = requestFrame(
                payload: malformed,
                requestID: 70,
                session: session(identity)
            )
            let response = withDecodedFrameReturning(malformedFrame) { frame in
                emit { output in
                    SDBGService().handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { ring.entry(sequence: $0) },
                        into: output
                    )
                }
            }
            expectError(
                response,
                operation: .identity,
                status: .unsupportedSchema,
                detail0: 2,
                detail1: 0
            )

            let wrongSession = requestFrame(
                payload: encodeRequestPayload(.status),
                requestID: 71,
                session: SDBGBootSessionID(high: 9, low: 10)
            )
            let mismatch = withDecodedFrameReturning(wrongSession) { frame in
                emit { output in
                    SDBGService().handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { ring.entry(sequence: $0) },
                        into: output
                    )
                }
            }
            expectError(
                mismatch,
                operation: .status,
                status: .bootSessionMismatch,
                detail0: identity.sessionID.high,
                detail1: identity.sessionID.low
            )

            var tiny = [UInt8](repeating: 0, count: 87)
            let tinyResult = tiny.withUnsafeMutableBytes {
                SDBGService().emitHello(identity: identity, into: $0)
            }
            expect(
                tinyResult == .rejected(
                    .outputBufferTooSmall(required: 88, available: 87)
                ),
                "short HELLO buffer was accepted"
            )

            let limited = SDBGService(
                limits: SDBGServiceLimits(
                    maximumRequestPayloadByteCount: 24,
                    maximumResponsePayloadByteCount: 164,
                    maximumLogEntriesPerResponse: 2
                )!
            )
            var oversizedPayload = [UInt8](repeating: 0, count: 25)
            oversizedPayload[8] = UInt8(SDBGOperation.identity.rawValue)
            let oversizedFrame = requestFrame(
                payload: oversizedPayload,
                requestID: 72,
                session: session(identity)
            )
            withDecodedFrame(oversizedFrame) { frame in
                var output = [UInt8](repeating: 0, count: 256)
                let result = output.withUnsafeMutableBytes {
                    limited.handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { ring.entry(sequence: $0) },
                        into: $0
                    )
                }
                guard case .emitted(let count) = result else {
                    fail("oversized request did not receive an error")
                }
                let response = Array(output[0..<count])
                expectError(
                    response,
                    operation: .identity,
                    status: .requestTooLarge,
                    detail0: 25,
                    detail1: 24
                )
            }
        }
    }

    private static func makeIdentity() -> KernelBootIdentity {
        KernelBootIdentity(
            sessionID: KernelIdentity128(
                high: 0x0102_0304_0506_0708,
                low: 0x1112_1314_1516_1718
            )!,
            build: KernelBuildIdentity(
                buildID: KernelIdentity128(
                    high: 0x2122_2324_2526_2728,
                    low: 0x3132_3334_3536_3738
                )!,
                sourceRevision: 0x4142_4344_4546_4748,
                imageDigestPrefix: 0x5152_5354_5556_5758,
                flavor: .diagnostic,
                abiRevision: 9
            ),
            bootOrdinal: 0x6162_6364_6566_6768,
            startedAtTicks: 0x7172_7374_7576_7778,
            reason: .softwareUpdate
        )
    }

    private static func makeStatus(
        identity: KernelBootIdentity,
        logStatistics: KernelLogStatistics
    ) -> DebugStatusSnapshot {
        DebugStatusSnapshot(
            snapshotSequence: 99,
            monotonicTicks: 123_456,
            bootSessionID: identity.sessionID,
            phase: .userlandRunning,
            flags: DebugStatusFlags(
                rawValue: DebugStatusFlags.interruptsEnabled.rawValue
                    | DebugStatusFlags.virtualMemoryEnabled.rawValue
            ),
            configuredProcessorCount: 4,
            onlineProcessorCount: 4,
            runnableThreadCount: 11,
            managedMemoryByteCount: 8 * 1_024 * 1_024 * 1_024,
            freeMemoryByteCount: 6 * 1_024 * 1_024 * 1_024,
            displayState: .presenting,
            displayWidthPixels: 3840,
            displayHeightPixels: 2160,
            displayRefreshMilliHertz: 60_000,
            debugLinkState: .connected,
            updateState: .idle,
            oldestLogSequence: logStatistics.oldestSequence ?? 0,
            newestLogSequence: logStatistics.newestSequence ?? 0,
            lostLogEntryCount: saturatingAdd(
                logStatistics.overwrittenEntryCount,
                logStatistics.rejectedEntryCount
            ),
            lastError: DebugStatusError(domain: 3, code: 4, detail: 5)
        )!
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }

    private static func logEvent(
        code: UInt32,
        argument0: UInt64 = 0
    ) -> KernelLogEvent {
        KernelLogEvent(
            timestampTicks: UInt64(code) * 10,
            level: .notice,
            subsystem: .kernel,
            eventCode: code,
            processorID: 2,
            flags: 3,
            argument0: argument0,
            argument1: UInt64(code) << 32
        )
    }

    private static func transact(
        _ request: SDBGRequest,
        requestID: UInt64,
        service: SDBGService,
        snapshot: SDBGServiceSnapshot,
        ring: KernelLogRing,
        outputByteCount: Int = 512
    ) -> [UInt8] {
        let requestBytes = requestFrame(
            request,
            requestID: requestID,
            identity: snapshot.bootIdentity
        )
        return withDecodedFrameReturning(requestBytes) { frame in
            emit(outputByteCount: outputByteCount) { output in
                service.handleRequest(
                    frame,
                    snapshot: snapshot,
                    lookupLogEntry: { ring.entry(sequence: $0) },
                    into: output
                )
            }
        }
    }

    private static func requestFrame(
        _ request: SDBGRequest,
        requestID: UInt64,
        identity: KernelBootIdentity
    ) -> [UInt8] {
        requestFrame(
            payload: encodeRequestPayload(request),
            requestID: requestID,
            session: session(identity)
        )
    }

    private static func requestFrame(
        payload: [UInt8],
        requestID: UInt64,
        session: SDBGBootSessionID
    ) -> [UInt8] {
        var output = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + payload.count
        )
        let result = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                SDBGFrameEncoder.encode(
                    envelope: SDBGEnvelope(
                        kind: .request,
                        flags: .none,
                        bootSessionID: session,
                        requestID: requestID
                    ),
                    payload: source,
                    into: destination
                )
            }
        }
        expect(result == .encoded(byteCount: output.count),
               "request fixture did not encode")
        return output
    }

    private static func encodeRequestPayload(_ request: SDBGRequest) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24)
        let count = bytes.withUnsafeMutableBytes {
            SDBGRequestCodec.encode(request, into: $0)
        }
        guard let count else { fail("request payload fixture failed") }
        return Array(bytes[0..<count])
    }

    private static func decodeRequest(
        _ bytes: [UInt8]
    ) -> SDBGRequestDecodeResult {
        bytes.withUnsafeBytes { SDBGRequestCodec.decode($0) }
    }

    private static func emit(
        outputByteCount: Int = 512,
        _ body: (UnsafeMutableRawBufferPointer) -> SDBGServiceResult
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: outputByteCount)
        let result = output.withUnsafeMutableBytes { body($0) }
        guard case .emitted(let count) = result else {
            fail("service fixture did not emit")
        }
        return Array(output[0..<count])
    }

    private static func withDecodedFrame(
        _ bytes: [UInt8],
        _ body: (SDBGDecodedFrame) -> Void
    ) {
        _ = withDecodedFrameReturning(bytes) { frame in
            body(frame)
            return true
        }
    }

    private static func withDecodedFrameReturning<T>(
        _ bytes: [UInt8],
        _ body: (SDBGDecodedFrame) -> T
    ) -> T {
        var storage = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount
                + SDBGProtocol.maximumPayloadByteCount
        )
        return storage.withUnsafeMutableBytes { storageBytes in
            var decoder = SDBGStreamDecoder(
                storageBaseAddress: UInt(bitPattern: storageBytes.baseAddress!),
                storageByteCount: storageBytes.count
            )!
            bytes.withUnsafeBytes {
                expect(decoder.append($0) == .appended, "decoder append")
            }
            guard case .frame(let frame) = decoder.pump() else {
                fail("service frame did not decode")
            }
            return body(frame)
        }
    }

    private static func expectSuccess(
        _ payload: UnsafeRawBufferPointer,
        operation: SDBGOperation,
        count: Int
    ) {
        guard case .header(let header) = SDBGResponseCodec.decodeHeader(payload)
        else { fail("response header did not decode") }
        expect(header.operationRawValue == operation.rawValue,
               "response operation changed")
        expect(header.status == .success, "response was not successful")
        expect(header.payloadByteCount == UInt32(count),
               "response byte count changed")
    }

    private static func expectError(
        _ bytes: [UInt8],
        operation: SDBGOperation,
        status: SDBGResponseStatus,
        detail0: UInt64,
        detail1: UInt64
    ) {
        withDecodedFrame(bytes) { frame in
            expect(frame.envelope.flags == .error, "error envelope flag")
            guard case .header(let header)
                    = SDBGResponseCodec.decodeHeader(frame.payload)
            else { fail("error response header did not decode") }
            expect(header.operationRawValue == operation.rawValue,
                   "error operation changed")
            expect(header.status == status, "error status changed")
            expect(frame.payload.count == 28, "error payload length")
            expect(read64(frame.payload, at: 12) == detail0, "error detail 0")
            expect(read64(frame.payload, at: 20) == detail1, "error detail 1")
        }
    }

    private static func withRing(
        capacity: Int,
        _ body: (KernelLogRing) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity * KernelLogRing.recordByteCount,
            alignment: 1
        )
        defer { pointer.deallocate() }
        let buffer = UnsafeMutableRawBufferPointer(
            start: pointer,
            count: capacity * KernelLogRing.recordByteCount
        )
        body(KernelLogRing(storage: buffer)!)
    }

    private static func session(
        _ identity: KernelBootIdentity
    ) -> SDBGBootSessionID {
        SDBGBootSessionID(
            high: identity.sessionID.high,
            low: identity.sessionID.low
        )
    }

    private static func read16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        SDBGPayloadWire.readUInt16(bytes, at: offset)
    }

    private static func read32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        SDBGWire.readUInt32(bytes, at: offset)
    }

    private static func read64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        SDBGWire.readUInt64(bytes, at: offset)
    }

    private static func write32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes.withUnsafeMutableBytes {
            SDBGWire.writeUInt32(value, to: $0, at: offset)
        }
    }

    private static func write64(
        _ value: UInt64,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes.withUnsafeMutableBytes {
            SDBGWire.writeUInt64(value, to: $0, at: offset)
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
