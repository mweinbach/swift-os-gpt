@main
struct SDBGHostClientTests {
    static func main() {
        decodesEveryReadOnlyPayloadAsOwnedValues()
        correlatesFragmentedAndCoalescedTransactions()
        enforcesSessionRequestAndTimeoutBoundaries()
        rejectsMalformedTypedPayloads()
        print("SDBG host client: 4 groups passed")
    }

    private static func decodesEveryReadOnlyPayloadAsOwnedValues() {
        withFixture { fixture in
            let hello = fixture.emitHello()
            withDecodedFrame(hello) { frame in
                guard case .decoded(.hello(let value))
                        = SwiftOSSDBGHostPayloadDecoder.decode(frame)
                else { fail("HELLO did not decode") }
                expect(value.bootSessionID == session(fixture.identity),
                       "HELLO session changed")
                expect(value.buildID == fixture.identity.build.buildID,
                       "HELLO build changed")
            }

            let capabilities = fixture.emitCapabilities()
            withDecodedFrame(capabilities) { frame in
                guard case .decoded(.capabilities(let value))
                        = SwiftOSSDBGHostPayloadDecoder.decode(frame)
                else { fail("capabilities did not decode") }
                expect(value.capabilities == .readOnlyV1,
                       "capability bits changed")
                expect(value.logRecordByteCount == 48,
                       "log record size changed")
            }

            for (requestID, request) in [
                (UInt64(10), SDBGRequest.identity),
                (UInt64(11), SDBGRequest.status),
                (UInt64(12), SDBGRequest.ping(token: 0xfeed_face)),
                (
                    UInt64(13),
                    SDBGRequest.logSnapshot(
                        SDBGLogSnapshotRequest(
                            startingSequence: 1,
                            maximumEntryCount: 2
                        )
                    )
                ),
            ] {
                let response = fixture.respond(
                    to: encodeRequest(
                        request,
                        requestID: requestID,
                        session: session(fixture.identity)
                    )
                )
                withDecodedFrame(response) { frame in
                    switch (request, SwiftOSSDBGHostPayloadDecoder.decode(frame)) {
                    case (.identity, .decoded(.identity(let value))):
                        expect(value == fixture.identity,
                               "owned identity changed")
                    case (.status, .decoded(.status(let value))):
                        expect(value == fixture.status,
                               "owned status changed")
                    case (.ping(let token), .decoded(.ping(let returned))):
                        expect(token == returned, "ping token changed")
                    case (.logSnapshot, .decoded(.logSnapshot(let value))):
                        expect(value.entries.count == 2,
                               "log page count changed")
                        expect(value.entries[0].event.eventCode == 0x1001,
                               "first owned log changed")
                        expect(value.entries[1].event.argument0 == 0x2222,
                               "second owned log changed")
                        expect(value.flags.contains(.moreEntries),
                               "log pagination flag disappeared")
                    default:
                        fail("typed response did not decode for \(request)")
                    }
                }
            }

            let remoteError = fixture.respond(
                to: encodeRequest(
                    .logSnapshot(
                        SDBGLogSnapshotRequest(
                            startingSequence: 99,
                            maximumEntryCount: 1
                        )
                    ),
                    requestID: 14,
                    session: session(fixture.identity)
                )
            )
            withDecodedFrame(remoteError) { frame in
                guard case .decoded(.remoteError(let value))
                        = SwiftOSSDBGHostPayloadDecoder.decode(frame)
                else { fail("remote error did not decode") }
                expect(value.operationRawValue
                        == SDBGOperation.logSnapshot.rawValue,
                       "remote-error operation changed")
                expect(value.status == .logSequenceNotYetWritten,
                       "remote-error status changed")
                expect(value.detail0 == 3, "remote-error newest sequence changed")
            }
        }
    }

    private static func correlatesFragmentedAndCoalescedTransactions() {
        withFixture { fixture in
            let transport = CaptureTransport()
            guard let client = SwiftOSSDBGHostStreamClient(transport: transport)
            else { fail("host client initialization failed") }

            let hello = fixture.emitHello()
            let capabilities = fixture.emitCapabilities()
            expect(client.receive(Array(hello[0..<7]), now: 1).isEmpty,
                   "partial HELLO emitted an event")
            var discoveryTail = Array(hello[7..<hello.count])
            discoveryTail.append(contentsOf: capabilities)
            let discovery = client.receive(discoveryTail, now: 2)
            expect(discovery.count == 2, "coalesced discovery was not drained")
            guard case .hello = discovery[0],
                  case .capabilities = discovery[1]
            else { fail("discovery event order changed") }
            expect(client.isReady, "client did not reach ready state")

            let identityID = begin(client, .identity, now: 10, timeout: 100)
            let pingToken: UInt64 = 0x1234_5678_9abc_def0
            let pingID = begin(
                client,
                .ping(token: pingToken),
                now: 10,
                timeout: 100
            )
            expect(identityID == 1 && pingID == 2,
                   "request IDs were not monotonic")
            expect(transport.frames.count == 2,
                   "transport did not receive both requests")

            let identityResponse = fixture.respond(to: transport.frames[0])
            let pingResponse = fixture.respond(to: transport.frames[1])
            var reversed = pingResponse
            reversed.append(contentsOf: identityResponse)
            let completions = client.receive(reversed, now: 11)
            expect(completions.count == 2,
                   "coalesced responses were not drained")
            guard case .completed(
                requestID: pingID,
                result: .ping(let returnedToken)
            ) = completions[0] else { fail("ping was not correlated") }
            expect(returnedToken == pingToken, "correlated ping token changed")
            guard case .completed(
                requestID: identityID,
                result: .identity(let returnedIdentity)
            ) = completions[1] else { fail("identity was not correlated") }
            expect(returnedIdentity == fixture.identity,
                   "correlated identity changed")

            let statusID = begin(client, .status, now: 12, timeout: 100)
            let statusResponse = fixture.respond(to: transport.frames[2])
            let statusEvents = client.receive(statusResponse, now: 13)
            guard statusEvents == [
                .completed(
                    requestID: statusID,
                    result: .status(fixture.status)
                )
            ] else { fail("status transaction changed") }

            let logID = begin(
                client,
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: 1,
                        maximumEntryCount: 2
                    )
                ),
                now: 14,
                timeout: 100
            )
            let logResponse = fixture.respond(to: transport.frames[3])
            let logEvents = client.receive(logResponse, now: 15)
            guard case .completed(
                requestID: logID,
                result: .logSnapshot(let page)
            ) = logEvents.first else { fail("log transaction changed") }
            expect(page.entries.map(\.sequence) == [1, 2],
                   "owned log sequences changed")

            // Force another decoder mutation and then re-read the retained page.
            _ = client.receive(fixture.emitHello(), now: 16)
            expect(page.entries[0].event.argument0 == 0x1111,
                   "log page still aliased decoder storage")
            expect(client.pendingRequestCount == 0,
                   "completed requests remained pending")
        }
    }

    private static func enforcesSessionRequestAndTimeoutBoundaries() {
        withFixture { fixture in
            let transport = CaptureTransport()
            let client = SwiftOSSDBGHostStreamClient(transport: transport)!
            var capabilitiesOnly = client.receive(
                fixture.emitCapabilities(),
                now: 0
            )
            guard case .protocolViolation(.messageBeforeHello(.capabilities))
                    = capabilitiesOnly.first
            else { fail("capabilities-before-HELLO was accepted") }

            _ = client.receive(fixture.emitHello(), now: 1)
            _ = client.receive(fixture.emitCapabilities(), now: 1)
            let statusID = begin(client, .status, now: 100, timeout: 10)
            let validResponse = fixture.respond(to: transport.frames[0])
            let unexpected = rewriteEnvelope(
                validResponse,
                requestID: statusID + 99
            )
            let unexpectedEvents = client.receive(unexpected, now: 105)
            guard case .protocolViolation(.unexpectedRequestID(statusID + 99))
                    = unexpectedEvents.first
            else { fail("unexpected request ID was accepted") }
            expect(client.pendingRequestCount == 1,
                   "unrelated response consumed pending request")
            expect(client.expire(now: 109).isEmpty,
                   "request timed out too early")
            expect(client.expire(now: 110) == [
                .timedOut(requestID: statusID, operation: .status)
            ], "request did not time out at its deadline")

            let pingID = begin(
                client,
                .ping(token: 77),
                now: 200,
                timeout: 50
            )
            let nextIdentity = makeIdentity(sessionLow: 0x9002)
            let validPingResponse = fixture.respond(to: transport.frames[1])
            let wrongSessionResponse = rewriteEnvelope(
                validPingResponse,
                session: session(nextIdentity),
                requestID: pingID
            )
            let wrongSessionEvents = client.receive(
                wrongSessionResponse,
                now: 200
            )
            expect(wrongSessionEvents == [
                .protocolViolation(
                    .responseSessionMismatch(
                        expected: session(fixture.identity),
                        actual: session(nextIdentity)
                    )
                )
            ], "response from another boot session was accepted")
            expect(client.pendingRequestCount == 1,
                   "wrong-session response consumed the request")

            let nextHello = fixture.emitHello(identity: nextIdentity)
            let rebootEvents = client.receive(nextHello, now: 201)
            expect(rebootEvents.contains(
                .cancelledForSessionChange(
                    requestID: pingID,
                    operation: .ping
                )
            ), "reboot did not cancel the pending request")
            expect(rebootEvents.contains(
                .sessionChanged(
                    previous: session(fixture.identity),
                    current: session(nextIdentity)
                )
            ), "reboot session transition was not surfaced")
            expect(!client.isReady,
                   "old capabilities survived a boot-session change")

            capabilitiesOnly.removeAll()
            expectThrows(.handshakeIncomplete) {
                _ = try client.begin(.identity, now: 202, timeoutTicks: 1)
            }
            expectThrows(.invalidTimeout) {
                let isolated = SwiftOSSDBGHostStreamClient(
                    transport: CaptureTransport()
                )!
                _ = isolated.receive(fixture.emitHello(), now: 0)
                _ = isolated.receive(fixture.emitCapabilities(), now: 0)
                _ = try isolated.begin(.identity, now: 0, timeoutTicks: 0)
            }

            let failingTransport = FailingTransport()
            let failingClient = SwiftOSSDBGHostStreamClient(
                transport: failingTransport
            )!
            _ = failingClient.receive(fixture.emitHello(), now: 0)
            _ = failingClient.receive(fixture.emitCapabilities(), now: 0)
            do {
                _ = try failingClient.begin(
                    .identity,
                    now: 0,
                    timeoutTicks: 1
                )
                fail("transport failure was swallowed")
            } catch FixtureTransportError.stopped {
                expect(failingClient.pendingRequestCount == 0,
                       "failed transport left a pending transaction")
            } catch {
                fail("transport error identity changed: \(error)")
            }
        }
    }

    private static func rejectsMalformedTypedPayloads() {
        withFixture { fixture in
            let logResponse = fixture.respond(
                to: encodeRequest(
                    .logSnapshot(
                        SDBGLogSnapshotRequest(
                            startingSequence: 3,
                            maximumEntryCount: 1
                        )
                    ),
                    requestID: 50,
                    session: session(fixture.identity)
                )
            )
            let malformedCount = rewritePayload(logResponse) { payload in
                write32(2, to: &payload, at: 60)
            }
            withDecodedFrame(malformedCount) { frame in
                expect(
                    SwiftOSSDBGHostPayloadDecoder.decode(frame)
                        == .rejected(.invalidInvariant(field: 23)),
                    "malformed log count was accepted"
                )
            }

            let statusResponse = fixture.respond(
                to: encodeRequest(
                    .status,
                    requestID: 51,
                    session: session(fixture.identity)
                )
            )
            let nonzeroReserved = rewritePayload(statusResponse) { payload in
                write32(1, to: &payload, at: 88)
            }
            withDecodedFrame(nonzeroReserved) { frame in
                expect(
                    SwiftOSSDBGHostPayloadDecoder.decode(frame)
                        == .rejected(
                            .nonzeroReserved(field: 17, rawValue: 1)
                        ),
                    "nonzero status reserved field was accepted"
                )
            }
        }
    }

    private final class CaptureTransport: SwiftOSSDBGHostTransport {
        private(set) var frames: [[UInt8]] = []

        func send(_ frame: [UInt8]) throws {
            frames.append(frame)
        }
    }

    private enum FixtureTransportError: Error {
        case stopped
    }

    private final class FailingTransport: SwiftOSSDBGHostTransport {
        func send(_ frame: [UInt8]) throws {
            throw FixtureTransportError.stopped
        }
    }

    private struct Fixture {
        let identity: KernelBootIdentity
        let status: DebugStatusSnapshot
        let statistics: KernelLogStatistics
        let ring: KernelLogRing
        let service: SDBGService

        func emitHello(
            identity requestedIdentity: KernelBootIdentity? = nil
        ) -> [UInt8] {
            emit { output in
                service.emitHello(
                    identity: requestedIdentity ?? identity,
                    into: output
                )
            }
        }

        func emitCapabilities() -> [UInt8] {
            emit { output in
                service.emitCapabilities(identity: identity, into: output)
            }
        }

        func respond(to request: [UInt8]) -> [UInt8] {
            let snapshot = SDBGServiceSnapshot(
                bootIdentity: identity,
                status: status,
                logStatistics: statistics
            )!
            return withDecodedFrame(request) { frame in
                emit { output in
                    service.handleRequest(
                        frame,
                        snapshot: snapshot,
                        lookupLogEntry: { ring.entry(sequence: $0) },
                        into: output
                    )
                }
            }
        }
    }

    private static func withFixture(_ body: (Fixture) -> Void) {
        var storage = [UInt8](repeating: 0, count: 4 * 48)
        storage.withUnsafeMutableBytes { raw in
            var ring = KernelLogRing(storage: raw)!
            _ = ring.append(
                KernelLogEvent(
                    timestampTicks: 10,
                    level: .info,
                    subsystem: .boot,
                    eventCode: 0x1001,
                    argument0: 0x1111
                )
            )
            _ = ring.append(
                KernelLogEvent(
                    timestampTicks: 20,
                    level: .warning,
                    subsystem: .drivers,
                    eventCode: 0x1002,
                    processorID: 1,
                    argument0: 0x2222
                )
            )
            _ = ring.append(
                KernelLogEvent(
                    timestampTicks: 30,
                    level: .error,
                    subsystem: .graphics,
                    eventCode: 0x1003,
                    argument1: 0x3333
                )
            )
            let identity = makeIdentity(sessionLow: 0x9001)
            let statistics = ring.statistics
            let status = makeStatus(identity: identity, statistics: statistics)
            body(
                Fixture(
                    identity: identity,
                    status: status,
                    statistics: statistics,
                    ring: ring,
                    service: SDBGService(
                        limits: SDBGServiceLimits(
                            maximumRequestPayloadByteCount: 128,
                            maximumResponsePayloadByteCount: 260,
                            maximumLogEntriesPerResponse: 4
                        )!
                    )
                )
            )
        }
    }

    private static func makeIdentity(sessionLow: UInt64) -> KernelBootIdentity {
        KernelBootIdentity(
            sessionID: KernelIdentity128(high: 0x1111, low: sessionLow)!,
            build: KernelBuildIdentity(
                buildID: KernelIdentity128(
                    high: 0x2222,
                    low: 0x3333
                )!,
                sourceRevision: 0x4444,
                imageDigestPrefix: 0x5555,
                flavor: .development,
                abiRevision: 7
            ),
            bootOrdinal: 9,
            startedAtTicks: 10,
            reason: .cold
        )
    }

    private static func makeStatus(
        identity: KernelBootIdentity,
        statistics: KernelLogStatistics
    ) -> DebugStatusSnapshot {
        DebugStatusSnapshot(
            snapshotSequence: 1,
            monotonicTicks: 77,
            bootSessionID: identity.sessionID,
            phase: .schedulerRunning,
            flags: DebugStatusFlags(
                rawValue: DebugStatusFlags.interruptsEnabled.rawValue
                    | DebugStatusFlags.virtualMemoryEnabled.rawValue
            ),
            configuredProcessorCount: 4,
            onlineProcessorCount: 4,
            runnableThreadCount: 3,
            managedMemoryByteCount: 8 * 1_024 * 1_024 * 1_024,
            freeMemoryByteCount: 7 * 1_024 * 1_024 * 1_024,
            displayState: .presenting,
            displayWidthPixels: 3_840,
            displayHeightPixels: 2_160,
            displayRefreshMilliHertz: 60_000,
            debugLinkState: .connected,
            updateState: .idle,
            oldestLogSequence: statistics.oldestSequence ?? 0,
            newestLogSequence: statistics.newestSequence ?? 0,
            lostLogEntryCount: 0,
            lastError: .none
        )!
    }

    private static func session(
        _ identity: KernelBootIdentity
    ) -> SDBGBootSessionID {
        SDBGBootSessionID(
            high: identity.sessionID.high,
            low: identity.sessionID.low
        )
    }

    private static func begin(
        _ client: SwiftOSSDBGHostStreamClient,
        _ request: SDBGRequest,
        now: UInt64,
        timeout: UInt64
    ) -> UInt64 {
        do {
            return try client.begin(
                request,
                now: now,
                timeoutTicks: timeout
            )
        } catch {
            fail("request start failed: \(error)")
        }
    }

    private static func encodeRequest(
        _ request: SDBGRequest,
        requestID: UInt64,
        session: SDBGBootSessionID
    ) -> [UInt8] {
        let payloadCount: Int
        switch request {
        case .identity, .status:
            payloadCount = 12
        case .ping:
            payloadCount = 20
        case .logSnapshot:
            payloadCount = 24
        }
        var payload = [UInt8](repeating: 0, count: payloadCount)
        expect(payload.withUnsafeMutableBytes {
            SDBGRequestCodec.encode(request, into: $0)
        } == payloadCount, "request payload encoding failed")
        return encodeFrame(
            kind: .request,
            flags: .none,
            session: session,
            requestID: requestID,
            payload: payload
        )
    }

    private static func rewriteEnvelope(
        _ frame: [UInt8],
        session requestedSession: SDBGBootSessionID? = nil,
        requestID: UInt64
    ) -> [UInt8] {
        withDecodedFrame(frame) { decoded in
            encodeFrame(
                kind: decoded.envelope.kind,
                flags: decoded.envelope.flags,
                session: requestedSession
                    ?? decoded.envelope.bootSessionID,
                requestID: requestID,
                payload: Array(decoded.payload)
            )
        }
    }

    private static func rewritePayload(
        _ frame: [UInt8],
        mutate: (inout [UInt8]) -> Void
    ) -> [UInt8] {
        withDecodedFrame(frame) { decoded in
            var payload = Array(decoded.payload)
            mutate(&payload)
            return encodeFrame(
                kind: decoded.envelope.kind,
                flags: decoded.envelope.flags,
                session: decoded.envelope.bootSessionID,
                requestID: decoded.envelope.requestID,
                payload: payload
            )
        }
    }

    private static func encodeFrame(
        kind: SDBGMessageKind,
        flags: SDBGMessageFlags,
        session: SDBGBootSessionID,
        requestID: UInt64,
        payload: [UInt8]
    ) -> [UInt8] {
        var output = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + payload.count
        )
        let result = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                SDBGFrameEncoder.encode(
                    envelope: SDBGEnvelope(
                        kind: kind,
                        flags: flags,
                        bootSessionID: session,
                        requestID: requestID
                    ),
                    payload: source,
                    into: destination
                )
            }
        }
        guard case .encoded(let count) = result,
              count == output.count
        else { fail("frame encoding failed") }
        return output
    }

    private static func emit(
        _ operation: (UnsafeMutableRawBufferPointer) -> SDBGServiceResult
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1_024)
        let result = output.withUnsafeMutableBytes(operation)
        guard case .emitted(let count) = result else {
            fail("service emission failed: \(result)")
        }
        return Array(output[0..<count])
    }

    private static func withDecodedFrame<T>(
        _ bytes: [UInt8],
        _ body: (SDBGDecodedFrame) -> T
    ) -> T {
        var storage = [UInt8](repeating: 0, count: bytes.count)
        return storage.withUnsafeMutableBytes { raw in
            var decoder = SDBGStreamDecoder(
                storageBaseAddress: UInt(bitPattern: raw.baseAddress!),
                storageByteCount: raw.count,
                maximumPayloadByteCount: raw.count - SDBGProtocol.headerByteCount
            )!
            bytes.withUnsafeBytes {
                expect(decoder.append($0) == .appended,
                       "frame append failed")
            }
            guard case .frame(let frame) = decoder.pump() else {
                fail("encoded frame did not decode")
            }
            return body(frame)
        }
    }

    private static func write32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func expectThrows(
        _ expected: SwiftOSSDBGHostClientError,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            fail("expected error \(expected) was not thrown")
        } catch let error as SwiftOSSDBGHostClientError {
            expect(error == expected, "wrong error: \(error)")
        } catch {
            fail("unexpected error type: \(error)")
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("SDBGHostClientTests: \(message)")
    }
}
