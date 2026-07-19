@main
struct SDBGTransportSessionTests {
    static func main() {
        validatesCallerOwnedStorageContract()
        negotiatesWithPartialWriteBackpressure()
        reassemblesAndQueuesOrderedRequests()
        preservesRequestsAcrossSnapshotMismatch()
        resynchronizesAndRejectsUnexpectedDirections()
        dispatchesLogLookupAndRestartsStreams()
        print("SDBG transport session: 6 groups passed")
    }

    private static func validatesCallerOwnedStorageContract() {
        let service = makeService()
        let identity = makeIdentity()
        var receive = [UInt8](repeating: 0, count: 512)
        var outbound = [UInt8](repeating: 0, count: 256)
        receive.withUnsafeMutableBytes { receiveBytes in
            outbound.withUnsafeMutableBytes { outboundBytes in
                let receiveAddress = UInt(bitPattern: receiveBytes.baseAddress!)
                let outboundAddress = UInt(bitPattern: outboundBytes.baseAddress!)
                expect(
                    SDBGTransportSession(
                        bootIdentity: identity,
                        service: service,
                        receiveStorageBaseAddress: receiveAddress,
                        receiveStorageByteCount: 103,
                        outboundStorageBaseAddress: outboundAddress,
                        outboundStorageByteCount: outboundBytes.count
                    ) == nil,
                    "undersized receive storage was accepted"
                )
                expect(
                    SDBGTransportSession(
                        bootIdentity: identity,
                        service: service,
                        receiveStorageBaseAddress: receiveAddress,
                        receiveStorageByteCount: receiveBytes.count,
                        outboundStorageBaseAddress: outboundAddress,
                        outboundStorageByteCount: 203
                    ) == nil,
                    "undersized outbound storage was accepted"
                )
                expect(
                    SDBGTransportSession(
                        bootIdentity: identity,
                        service: service,
                        receiveStorageBaseAddress: receiveAddress,
                        receiveStorageByteCount: receiveBytes.count,
                        outboundStorageBaseAddress: receiveAddress + 8,
                        outboundStorageByteCount: 256
                    ) == nil,
                    "overlapping session storage was accepted"
                )
                expect(
                    SDBGTransportSession(
                        bootIdentity: identity,
                        service: service,
                        receiveStorageBaseAddress: UInt.max - 8,
                        receiveStorageByteCount: receiveBytes.count,
                        outboundStorageBaseAddress: outboundAddress,
                        outboundStorageByteCount: outboundBytes.count
                    ) == nil,
                    "overflowing receive range was accepted"
                )
            }
        }
    }

    private static func negotiatesWithPartialWriteBackpressure() {
        withSession { session in
            let snapshot = makeSnapshot(identity: session.bootIdentity)
            let earlyRequest = requestFrame(
                .ping(token: 0x1122_3344_5566_7788),
                requestID: 17,
                identity: session.bootIdentity
            )
            expect(
                receive(earlyRequest, into: &session)
                    == .accepted(byteCount: earlyRequest.count),
                "early request was not buffered"
            )

            guard case .outboundReady(let helloMetadata) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("HELLO was not emitted first") }
            expect(helloMetadata.kind == .hello, "first frame was not HELLO")
            expect(helloMetadata.requestID == 0, "HELLO had request ID")
            inspectFrame(Array(session.outboundBytes)) { frame in
                expect(frame.envelope.kind == .hello, "HELLO envelope kind")
                guard case .hello(let hello)
                        = SDBGDiscoveryPayloadCodec.decodeHello(frame.payload)
                else { fail("HELLO payload did not decode") }
                expect(
                    hello.bootSessionID.high
                        == session.bootIdentity.sessionID.high
                        && hello.bootSessionID.low
                            == session.bootIdentity.sessionID.low,
                    "HELLO advertised another boot"
                )
            }

            expect(
                session.consumeOutboundBytes(7)
                    == .consumed(
                        byteCount: 7,
                        remainingByteCount: helloMetadata.totalByteCount - 7
                    ),
                "partial HELLO acknowledgement changed"
            )
            guard case .outboundBackpressured(let partial) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("partial HELLO did not backpressure the pump") }
            expect(
                partial.kind == .hello
                    && partial.remainingByteCount
                        == helloMetadata.totalByteCount - 7,
                "HELLO backpressure metadata changed"
            )
            expect(
                session.consumeOutboundBytes(partial.remainingByteCount)
                    == .consumed(
                        byteCount: partial.remainingByteCount,
                        remainingByteCount: 0
                    ),
                "HELLO did not fully drain"
            )

            guard case .outboundReady(let capabilitiesMetadata) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("CAPABILITIES did not follow HELLO") }
            expect(
                capabilitiesMetadata.kind == .capabilities,
                "second frame was not CAPABILITIES"
            )
            expect(
                !session.discoveryIsComplete,
                "discovery completed before CAPABILITIES was transmitted"
            )
            inspectFrame(Array(session.outboundBytes)) { frame in
                guard case .capabilities(let capabilities)
                        = SDBGDiscoveryPayloadCodec.decodeCapabilities(
                            frame.payload
                        )
                else { fail("CAPABILITIES payload did not decode") }
                expect(
                    capabilities.maximumRequestPayloadByteCount == 64
                        && capabilities.maximumResponsePayloadByteCount == 164,
                    "session limits were not advertised"
                )
            }
            drainOutbound(&session)
            expect(session.discoveryIsComplete, "discovery did not complete")

            guard case .outboundReady(let responseMetadata) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("buffered request was not dispatched") }
            expect(
                responseMetadata.kind == .response
                    && responseMetadata.requestID == 17,
                "response correlation changed"
            )
            inspectFrame(Array(session.outboundBytes)) { frame in
                expect(frame.envelope.requestID == 17, "response request ID")
                guard case .header(let header)
                        = SDBGResponseCodec.decodeHeader(frame.payload)
                else { fail("ping response header did not decode") }
                expect(
                    header.operationRawValue == SDBGOperation.ping.rawValue
                        && header.status == .success,
                    "ping response was not successful"
                )
                expect(
                    SDBGWire.readUInt64(frame.payload, at: 12)
                        == 0x1122_3344_5566_7788,
                    "ping token changed"
                )
            }
        }
    }

    private static func reassemblesAndQueuesOrderedRequests() {
        withSession { session in
            let snapshot = makeSnapshot(identity: session.bootIdentity)
            completeDiscovery(&session, snapshot: snapshot)
            let identityRequest = requestFrame(
                .identity,
                requestID: 31,
                identity: session.bootIdentity
            )
            let pingRequest = requestFrame(
                .ping(token: 0xaabb_ccdd),
                requestID: 32,
                identity: session.bootIdentity
            )

            expect(
                receive(Array(identityRequest[0..<3]), into: &session)
                    == .accepted(byteCount: 3),
                "fragmented magic prefix was rejected"
            )
            guard case .needsMoreBytes(let required) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("fragmented request did not need bytes") }
            expect(required == 4, "fragmented magic requirement changed")

            var coalesced = Array(identityRequest[3..<identityRequest.count])
            coalesced.append(contentsOf: pingRequest)
            expect(
                receive(coalesced, into: &session)
                    == .accepted(byteCount: coalesced.count),
                "coalesced request tail was rejected"
            )
            guard case .outboundReady(let first) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("first coalesced request did not dispatch") }
            expect(first.requestID == 31, "request order changed")
            expect(
                session.inboundBufferedByteCount == pingRequest.count,
                "second request was not retained"
            )
            expect(
                session.consumeOutboundBytes(first.totalByteCount - 1)
                    == .consumed(
                        byteCount: first.totalByteCount - 1,
                        remainingByteCount: 1
                    ),
                "response partial drain changed"
            )
            guard case .outboundBackpressured = pump(
                &session,
                snapshot: snapshot
            ) else { fail("response did not enforce backpressure") }
            drainOutbound(&session)

            guard case .outboundReady(let second) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("second coalesced request did not dispatch") }
            expect(second.requestID == 32, "second request correlation changed")
            inspectFrame(Array(session.outboundBytes)) { frame in
                expect(
                    SDBGWire.readUInt64(frame.payload, at: 12) == 0xaabb_ccdd,
                    "second request payload changed"
                )
            }
        }
    }

    private static func preservesRequestsAcrossSnapshotMismatch() {
        withSession { session in
            let snapshot = makeSnapshot(identity: session.bootIdentity)
            completeDiscovery(&session, snapshot: snapshot)
            let request = requestFrame(
                .status,
                requestID: 41,
                identity: session.bootIdentity
            )
            _ = receive(request, into: &session)

            let otherIdentity = makeIdentity(sessionLow: 0x9999)
            let otherSnapshot = makeSnapshot(identity: otherIdentity)
            expect(
                pump(&session, snapshot: otherSnapshot)
                    == .snapshotIdentityMismatch(
                        expected: session.bootIdentity.sessionID,
                        actual: otherIdentity.sessionID
                    ),
                "cross-boot snapshot was accepted"
            )
            expect(
                session.inboundBufferedByteCount == request.count,
                "request was consumed on snapshot mismatch"
            )
            guard case .outboundReady(let recovered) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("request could not retry with coherent snapshot") }
            expect(recovered.requestID == 41, "retried request ID changed")
            drainOutbound(&session)

            let staleIdentity = makeIdentity(sessionLow: 0x7777)
            let staleRequest = requestFrame(
                .identity,
                requestID: 42,
                identity: staleIdentity
            )
            _ = receive(staleRequest, into: &session)
            guard case .outboundReady = pump(&session, snapshot: snapshot)
            else { fail("stale session request did not receive an error") }
            inspectFrame(Array(session.outboundBytes)) { frame in
                expect(frame.envelope.flags == .error, "stale response flag")
                guard case .header(let header)
                        = SDBGResponseCodec.decodeHeader(frame.payload)
                else { fail("stale-session response did not decode") }
                expect(
                    header.status == .bootSessionMismatch,
                    "stale session was not rejected by the service"
                )
            }
        }
    }

    private static func resynchronizesAndRejectsUnexpectedDirections() {
        withSession(receiveByteCount: 256) { session in
            let snapshot = makeSnapshot(identity: session.bootIdentity)
            completeDiscovery(&session, snapshot: snapshot)

            let tooLarge = [UInt8](
                repeating: 0xa5,
                count: session.inboundWritableByteCount + 1
            )
            expect(
                receive(tooLarge, into: &session)
                    == .wouldBlock(
                        requiredByteCount: tooLarge.count,
                        availableByteCount: tooLarge.count - 1
                    ),
                "receive overflow was not all-or-none"
            )
            expect(
                session.inboundBufferedByteCount == 0,
                "receive overflow mutated buffered bytes"
            )

            let event = frame(
                kind: .event,
                requestID: 0,
                identity: session.bootIdentity,
                payload: [0x01]
            )
            let request = requestFrame(
                .ping(token: 99),
                requestID: 51,
                identity: session.bootIdentity
            )
            var stream: [UInt8] = [0xee]
            stream.append(contentsOf: event)
            stream.append(contentsOf: request)
            _ = receive(stream, into: &session)

            expect(
                pump(&session, snapshot: snapshot)
                    == .discardedMalformedFrame(
                        rejection: .invalidMagic,
                        byteCount: 1
                    ),
                "leading garbage was not resynchronized"
            )
            expect(
                pump(&session, snapshot: snapshot)
                    == .discardedUnexpectedMessage(
                        kind: .event,
                        byteCount: event.count
                    ),
                "host-to-guest EVENT direction was accepted"
            )
            guard case .outboundReady(let response) = pump(
                &session,
                snapshot: snapshot
            ) else { fail("valid request after garbage did not recover") }
            expect(response.requestID == 51, "recovered request ID changed")
        }
    }

    private static func dispatchesLogLookupAndRestartsStreams() {
        var logStorage = [UInt8](repeating: 0, count: 96)
        logStorage.withUnsafeMutableBytes { storage in
            var ring = KernelLogRing(storage: storage)!
            _ = ring.append(
                KernelLogEvent(
                    timestampTicks: 77,
                    level: .notice,
                    subsystem: .graphics,
                    eventCode: 0x1234,
                    processorID: 2,
                    argument0: 0xfeed
                )
            )
            withSession { session in
                let snapshot = makeSnapshot(
                    identity: session.bootIdentity,
                    statistics: ring.statistics
                )
                completeDiscovery(&session, snapshot: snapshot)
                let request = requestFrame(
                    .logSnapshot(
                        SDBGLogSnapshotRequest(
                            startingSequence: 1,
                            maximumEntryCount: 1
                        )
                    ),
                    requestID: 61,
                    identity: session.bootIdentity
                )
                _ = receive(request, into: &session)
                var lookupCount = 0
                guard case .outboundReady = session.pump(
                    snapshot: snapshot,
                    lookupLogEntry: { sequence in
                        lookupCount += 1
                        return ring.entry(sequence: sequence)
                    }
                ) else { fail("log request did not dispatch") }
                expect(lookupCount == 1, "log provider was not injected")
                inspectFrame(Array(session.outboundBytes)) { response in
                    guard case .header(let header)
                            = SDBGResponseCodec.decodeHeader(response.payload)
                    else { fail("log response header did not decode") }
                    expect(
                        header.operationRawValue
                            == SDBGOperation.logSnapshot.rawValue
                            && header.status == .success,
                        "log response was unsuccessful"
                    )
                    expect(
                        SDBGWire.readUInt32(response.payload, at: 60) == 1,
                        "log record was not returned"
                    )
                    expect(
                        SDBGWire.readUInt32(response.payload, at: 88) == 0x1234,
                        "log provider record changed"
                    )
                }

                session.resetStream()
                expect(
                    session.pendingOutboundByteCount == 0
                        && session.inboundBufferedByteCount == 0
                        && !session.discoveryIsComplete,
                    "stream reset retained transport state"
                )
                guard case .outboundReady(let hello) = session.pump(
                    snapshot: snapshot,
                    lookupLogEntry: { ring.entry(sequence: $0) }
                ) else { fail("stream reset did not restart discovery") }
                expect(hello.kind == .hello, "reset did not re-emit HELLO")
                inspectFrame(Array(session.outboundBytes)) { frame in
                    expect(
                        frame.envelope.bootSessionID.high
                            == session.bootIdentity.sessionID.high
                            && frame.envelope.bootSessionID.low
                                == session.bootIdentity.sessionID.low,
                        "stream reset changed boot identity"
                    )
                }
            }
        }
    }

    private static func makeService() -> SDBGService {
        SDBGService(
            limits: SDBGServiceLimits(
                maximumRequestPayloadByteCount: 64,
                maximumResponsePayloadByteCount: 164,
                maximumLogEntriesPerResponse: 2
            )!
        )
    }

    private static func withSession(
        receiveByteCount: Int = 512,
        _ body: (inout SDBGTransportSession) -> Void
    ) {
        var receiveStorage = [UInt8](
            repeating: 0,
            count: receiveByteCount
        )
        var outboundStorage = [UInt8](repeating: 0, count: 256)
        receiveStorage.withUnsafeMutableBytes { receiveBytes in
            outboundStorage.withUnsafeMutableBytes { outboundBytes in
                var session = SDBGTransportSession(
                    bootIdentity: makeIdentity(),
                    service: makeService(),
                    receiveStorageBaseAddress: UInt(
                        bitPattern: receiveBytes.baseAddress!
                    ),
                    receiveStorageByteCount: receiveBytes.count,
                    outboundStorageBaseAddress: UInt(
                        bitPattern: outboundBytes.baseAddress!
                    ),
                    outboundStorageByteCount: outboundBytes.count
                )!
                body(&session)
            }
        }
    }

    private static func completeDiscovery(
        _ session: inout SDBGTransportSession,
        snapshot: SDBGServiceSnapshot
    ) {
        guard case .outboundReady(let hello) = pump(
            &session,
            snapshot: snapshot
        ) else { fail("discovery HELLO missing") }
        expect(hello.kind == .hello, "discovery order changed")
        drainOutbound(&session)
        guard case .outboundReady(let capabilities) = pump(
            &session,
            snapshot: snapshot
        ) else { fail("discovery CAPABILITIES missing") }
        expect(capabilities.kind == .capabilities, "capability order changed")
        drainOutbound(&session)
    }

    private static func pump(
        _ session: inout SDBGTransportSession,
        snapshot: SDBGServiceSnapshot
    ) -> SDBGTransportPumpResult {
        session.pump(
            snapshot: snapshot,
            lookupLogEntry: { _ in .notYetWritten }
        )
    }

    private static func receive(
        _ bytes: [UInt8],
        into session: inout SDBGTransportSession
    ) -> SDBGTransportReceiveResult {
        bytes.withUnsafeBytes { session.receive($0) }
    }

    private static func drainOutbound(
        _ session: inout SDBGTransportSession
    ) {
        let count = session.pendingOutboundByteCount
        expect(count > 0, "attempted to drain an empty frame")
        expect(
            session.consumeOutboundBytes(count)
                == .consumed(byteCount: count, remainingByteCount: 0),
            "outbound frame did not drain"
        )
    }

    private static func makeIdentity(
        sessionLow: UInt64 = 0x0203_0405_0607_0809
    ) -> KernelBootIdentity {
        KernelBootIdentity(
            sessionID: KernelIdentity128(
                high: 0x1112_1314_1516_1718,
                low: sessionLow
            )!,
            build: KernelBuildIdentity(
                buildID: KernelIdentity128(
                    high: 0x2122_2324_2526_2728,
                    low: 0x3132_3334_3536_3738
                )!,
                sourceRevision: 0x4142_4344_4546_4748,
                imageDigestPrefix: 0x5152_5354_5556_5758,
                flavor: .diagnostic,
                abiRevision: 7
            ),
            bootOrdinal: 9,
            startedAtTicks: 10,
            reason: .cold
        )
    }

    private static func makeSnapshot(
        identity: KernelBootIdentity,
        statistics: KernelLogStatistics = KernelLogStatistics(
            capacity: 2,
            retainedCount: 0,
            oldestSequence: nil,
            newestSequence: nil,
            nextSequence: 1,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
    ) -> SDBGServiceSnapshot {
        let status = DebugStatusSnapshot(
            snapshotSequence: 1,
            monotonicTicks: 200,
            bootSessionID: identity.sessionID,
            phase: .schedulerRunning,
            flags: .preemptionEnabled,
            configuredProcessorCount: 4,
            onlineProcessorCount: 4,
            runnableThreadCount: 3,
            managedMemoryByteCount: 8 * 1_024 * 1_024 * 1_024,
            freeMemoryByteCount: 7 * 1_024 * 1_024 * 1_024,
            displayState: .presenting,
            displayWidthPixels: 1_920,
            displayHeightPixels: 1_080,
            displayRefreshMilliHertz: 60_000,
            debugLinkState: .connected,
            updateState: .idle,
            oldestLogSequence: statistics.oldestSequence ?? 0,
            newestLogSequence: statistics.newestSequence ?? 0,
            lostLogEntryCount: statistics.overwrittenEntryCount
                + statistics.rejectedEntryCount,
            lastError: .none
        )!
        return SDBGServiceSnapshot(
            bootIdentity: identity,
            status: status,
            logStatistics: statistics
        )!
    }

    private static func requestFrame(
        _ request: SDBGRequest,
        requestID: UInt64,
        identity: KernelBootIdentity
    ) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 24)
        let payloadByteCount = payload.withUnsafeMutableBytes {
            SDBGRequestCodec.encode(request, into: $0)
        }!
        payload.removeLast(payload.count - payloadByteCount)
        return frame(
            kind: .request,
            requestID: requestID,
            identity: identity,
            payload: payload
        )
    }

    private static func frame(
        kind: SDBGMessageKind,
        requestID: UInt64,
        identity: KernelBootIdentity,
        payload: [UInt8]
    ) -> [UInt8] {
        var encoded = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + payload.count
        )
        let result = encoded.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { source in
                SDBGFrameEncoder.encode(
                    envelope: SDBGEnvelope(
                        kind: kind,
                        flags: .none,
                        bootSessionID: SDBGBootSessionID(
                            high: identity.sessionID.high,
                            low: identity.sessionID.low
                        ),
                        requestID: requestID
                    ),
                    payload: source,
                    into: output
                )
            }
        }
        guard case .encoded(let count) = result, count == encoded.count else {
            fail("test frame did not encode")
        }
        return encoded
    }

    private static func inspectFrame(
        _ bytes: [UInt8],
        _ body: (SDBGDecodedFrame) -> Void
    ) {
        var storage = [UInt8](repeating: 0, count: bytes.count)
        storage.withUnsafeMutableBytes { storageBytes in
            var decoder = SDBGStreamDecoder(
                storageBaseAddress: UInt(bitPattern: storageBytes.baseAddress!),
                storageByteCount: storageBytes.count,
                maximumPayloadByteCount: bytes.count
                    - SDBGProtocol.headerByteCount
            )!
            let appendResult = bytes.withUnsafeBytes { decoder.append($0) }
            expect(appendResult == .appended, "test frame did not append")
            guard case .frame(let frame) = decoder.pump() else {
                fail("outbound frame did not decode")
            }
            body(frame)
        }
    }

    private static func expect(_ condition: Bool, _ message: StaticString) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
