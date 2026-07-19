@main
struct SDBGSerialSessionTests {
    static func main() {
        handshakesAcrossMultiplexedNoise()
        performsSingleAndSequentialTypedRequests()
        reportsBoundedTimeoutsAndDisconnects()
        print("SDBG serial session: 3 groups passed")
    }

    private static func handshakesAcrossMultiplexedNoise() {
        let fixture = Fixture()
        let clock = TestClock(now: 100)
        let channel = ScriptedChannel(clock: clock)
        let hello = fixture.hello()
        let capabilities = fixture.capabilities()
        channel.readActions = [
            .bytes(
                Array("SDDP-display-frame".utf8)
                    + Array(hello[0..<19]),
                advance: 1
            ),
            .bytes(
                Array(hello[19..<hello.count])
                    + Array("SUPD-update-status".utf8)
                    + capabilities,
                advance: 1
            ),
        ]
        let configuration = makeConfiguration(
            handshake: 100,
            request: 80,
            write: 20,
            read: 10,
            dtr: 7
        )
        let session = makeSession(
            channel: channel,
            clock: clock,
            configuration: configuration
        )

        let handshake: SwiftOSSDBGSerialHandshake
        do {
            handshake = try session.connect()
        } catch {
            fail("fragmented handshake failed: \(error)")
        }
        expect(handshake.hello.bootSessionID == fixture.sessionID,
               "HELLO session changed")
        expect(handshake.capabilities.capabilities == .readOnlyV1,
               "capability set changed")
        expect(channel.dtrPulses == [7], "DTR was not explicitly pulsed")
        expect(channel.readDeadlines.allSatisfy { $0 <= 200 },
               "handshake read exceeded its overall deadline")
        expect(channel.writes.isEmpty, "handshake wrote an unsolicited frame")
    }

    private static func performsSingleAndSequentialTypedRequests() {
        let fixture = Fixture()
        let clock = TestClock(now: 1_000)
        let channel = ScriptedChannel(clock: clock)
        queueHandshake(fixture, on: channel)
        channel.onWrite = { request in
            let response = fixture.response(to: request)
            return [
                .bytes(
                    Array("SDDP".utf8) + Array(response[0..<13]),
                    advance: 1
                ),
                .bytes(
                    Array(response[13..<response.count])
                        + Array("SUPD".utf8),
                    advance: 1
                ),
            ]
        }
        let configuration = makeConfiguration(
            handshake: 100,
            request: 50,
            write: 10,
            read: 5,
            dtr: 2
        )
        let session = makeSession(
            channel: channel,
            clock: clock,
            configuration: configuration
        )
        do {
            _ = try session.connect()
        } catch {
            fail("request fixture handshake failed: \(error)")
        }

        do {
            let single = try session.perform(.ping(token: 0xfeed_face))
            expect(single == .ping(token: 0xfeed_face),
                   "single ping response changed")

            let results = try session.perform([
                .identity,
                .status,
                .ping(token: 0x1234_5678),
            ])
            expect(results == [
                .identity(fixture.identity),
                .status(fixture.status),
                .ping(token: 0x1234_5678),
            ], "sequential typed responses changed")
        } catch {
            fail("typed request failed: \(error)")
        }
        expect(channel.writes.count == 4,
               "stop-and-wait runner did not write every request")
        expect(channel.maximumQueuedReadActionCount == 2,
               "runner issued another request before draining its response")
        for (index, deadline) in channel.writeDeadlines.enumerated() {
            expect(deadline > channel.writeTimes[index],
                   "write deadline was not in the future")
            expect(deadline - channel.writeTimes[index] <= 10,
                   "write deadline exceeded configured bound")
        }
    }

    private static func reportsBoundedTimeoutsAndDisconnects() {
        let configuration = makeConfiguration(
            handshake: 30,
            request: 20,
            write: 5,
            read: 5,
            dtr: 1
        )

        do {
            let clock = TestClock(now: 10)
            let channel = ScriptedChannel(clock: clock)
            let session = makeSession(
                channel: channel,
                clock: clock,
                configuration: configuration
            )
            expectError(
                SwiftOSSDBGSerialSessionError.handshakeRequired,
                "request before handshake was accepted"
            ) {
                _ = try session.perform(.status)
            }
            expectError(
                SwiftOSSDBGSerialSessionError.handshakeTimedOut(path: channel.path),
                "silent device did not hit the handshake deadline"
            ) {
                _ = try session.connect()
            }
            expect(clock.nowNanoseconds() == 40,
                   "handshake timeout did not stop at its deadline")
            expect(channel.readDeadlines.count == 6,
                   "handshake did not use bounded read polls")
        }

        do {
            let fixture = Fixture()
            let clock = TestClock(now: 100)
            let channel = ScriptedChannel(clock: clock)
            queueHandshake(fixture, on: channel)
            let session = makeSession(
                channel: channel,
                clock: clock,
                configuration: configuration
            )
            do {
                _ = try session.connect()
            } catch {
                fail("timeout fixture handshake failed: \(error)")
            }
            expectError(
                SwiftOSSDBGSerialSessionError.requestTimedOut(
                    path: channel.path,
                    operation: .status
                ),
                "silent request did not hit its response deadline"
            ) {
                _ = try session.perform(.status)
            }
        }

        do {
            let fixture = Fixture()
            let clock = TestClock(now: 200)
            let channel = ScriptedChannel(clock: clock)
            queueHandshake(fixture, on: channel)
            let session = makeSession(
                channel: channel,
                clock: clock,
                configuration: configuration
            )
            do {
                _ = try session.connect()
            } catch {
                fail("disconnect fixture handshake failed: \(error)")
            }
            channel.readActions.append(.disconnect("cable removed"))
            expectError(
                SwiftOSSDBGSerialChannelError.disconnected(
                    path: channel.path,
                    detail: "cable removed"
                ),
                "disconnect was not surfaced distinctly"
            ) {
                _ = try session.perform(.ping(token: 9))
            }
        }
    }

    private static func queueHandshake(
        _ fixture: Fixture,
        on channel: ScriptedChannel
    ) {
        channel.readActions.append(
            .bytes(
                fixture.hello() + fixture.capabilities(),
                advance: 1
            )
        )
    }

    private static func makeConfiguration(
        handshake: UInt64,
        request: UInt64,
        write: UInt64,
        read: UInt64,
        dtr: UInt64
    ) -> SwiftOSSDBGSerialSessionConfiguration {
        guard let result = SwiftOSSDBGSerialSessionConfiguration(
            handshakeTimeoutNanoseconds: handshake,
            requestTimeoutNanoseconds: request,
            writeTimeoutNanoseconds: write,
            readPollNanoseconds: read,
            dtrLowNanoseconds: dtr,
            maximumReadByteCount: 1_024
        ) else { fail("test configuration was rejected") }
        return result
    }

    private static func makeSession(
        channel: ScriptedChannel,
        clock: TestClock,
        configuration: SwiftOSSDBGSerialSessionConfiguration
    ) -> SwiftOSSDBGSerialSession {
        do {
            return try SwiftOSSDBGSerialSession(
                channel: channel,
                clock: clock,
                configuration: configuration
            )
        } catch {
            fail("session initialization failed: \(error)")
        }
    }

    private final class TestClock: SwiftOSSDBGMonotonicClock {
        private(set) var now: UInt64

        init(now: UInt64) {
            self.now = now
        }

        func nowNanoseconds() -> UInt64 { now }

        func advance(by delta: UInt64) {
            now = now > UInt64.max - delta ? UInt64.max : now + delta
        }

        func advance(to deadline: UInt64) {
            if now < deadline { now = deadline }
        }
    }

    private final class ScriptedChannel: SwiftOSSDBGSerialByteChannel {
        enum ReadAction {
            case bytes([UInt8], advance: UInt64)
            case disconnect(String)
        }

        let path = "/dev/cu.swiftos-test"
        let clock: TestClock
        var readActions: [ReadAction] = []
        var onWrite: (([UInt8]) -> [ReadAction])?
        private(set) var dtrPulses: [UInt64] = []
        private(set) var writes: [[UInt8]] = []
        private(set) var writeDeadlines: [UInt64] = []
        private(set) var writeTimes: [UInt64] = []
        private(set) var readDeadlines: [UInt64] = []
        private(set) var maximumQueuedReadActionCount = 0

        init(clock: TestClock) {
            self.clock = clock
        }

        func pulseDTR(lowNanoseconds: UInt64) throws {
            dtrPulses.append(lowNanoseconds)
        }

        func writeAll(
            _ bytes: [UInt8],
            deadlineNanoseconds: UInt64
        ) throws {
            writeTimes.append(clock.nowNanoseconds())
            writeDeadlines.append(deadlineNanoseconds)
            guard clock.nowNanoseconds() < deadlineNanoseconds else {
                throw SwiftOSSDBGSerialChannelError.timedOut(
                    path: path,
                    operation: .write
                )
            }
            writes.append(bytes)
            if let generated = onWrite?(bytes) {
                readActions.append(contentsOf: generated)
                maximumQueuedReadActionCount = max(
                    maximumQueuedReadActionCount,
                    readActions.count
                )
            }
        }

        func read(
            maximumByteCount: Int,
            deadlineNanoseconds: UInt64
        ) throws -> [UInt8] {
            readDeadlines.append(deadlineNanoseconds)
            guard !readActions.isEmpty else {
                clock.advance(to: deadlineNanoseconds)
                throw SwiftOSSDBGSerialChannelError.timedOut(
                    path: path,
                    operation: .read
                )
            }
            let action = readActions.removeFirst()
            switch action {
            case .disconnect(let detail):
                throw SwiftOSSDBGSerialChannelError.disconnected(
                    path: path,
                    detail: detail
                )
            case .bytes(let source, let delta):
                clock.advance(by: delta)
                guard source.count <= maximumByteCount else {
                    fail("scripted read exceeded the caller buffer")
                }
                return source
            }
        }
    }

    private struct Fixture {
        let identity: KernelBootIdentity
        let status: DebugStatusSnapshot

        var sessionID: SDBGBootSessionID {
            SDBGBootSessionID(
                high: identity.sessionID.high,
                low: identity.sessionID.low
            )
        }

        init() {
            let session = KernelIdentity128(
                high: 0x1111_2222_3333_4444,
                low: 0x5555_6666_7777_8888
            )!
            identity = KernelBootIdentity(
                sessionID: session,
                build: KernelBuildIdentity(
                    buildID: KernelIdentity128(
                        high: 0x9999_aaaa_bbbb_cccc,
                        low: 0xdddd_eeee_ffff_0001
                    )!,
                    sourceRevision: 0x1234,
                    imageDigestPrefix: 0x5678,
                    flavor: .diagnostic,
                    abiRevision: 7
                ),
                bootOrdinal: 4,
                startedAtTicks: 42,
                reason: .cold
            )
            status = DebugStatusSnapshot(
                snapshotSequence: 3,
                monotonicTicks: 99,
                bootSessionID: session,
                phase: .userlandRunning,
                flags: DebugStatusFlags(
                    rawValue: DebugStatusFlags.interruptsEnabled.rawValue
                        | DebugStatusFlags.virtualMemoryEnabled.rawValue
                        | DebugStatusFlags.preemptionEnabled.rawValue
                ),
                configuredProcessorCount: 4,
                onlineProcessorCount: 4,
                runnableThreadCount: 6,
                managedMemoryByteCount: 8 * 1_024 * 1_024 * 1_024,
                freeMemoryByteCount: 7 * 1_024 * 1_024 * 1_024,
                displayState: .presenting,
                displayWidthPixels: 3_840,
                displayHeightPixels: 2_160,
                displayRefreshMilliHertz: 60_000,
                debugLinkState: .connected,
                updateState: .idle,
                oldestLogSequence: 0,
                newestLogSequence: 0,
                lostLogEntryCount: 0,
                lastError: .none
            )!
        }

        func hello() -> [UInt8] {
            var payload = typedPayload(
                byteCount: SDBGTypedPayloadProtocol.helloByteCount,
                headerByteCount: SDBGTypedPayloadProtocol.typedHeaderByteCount
            )
            payload[8] = SDBGProtocol.versionMajor
            payload[9] = SDBGProtocol.versionMinor
            writeIdentity(identity.sessionID, to: &payload, at: 12)
            writeIdentity(identity.build.buildID, to: &payload, at: 28)
            writeUInt16(
                KernelBuildIdentity.schemaVersion,
                to: &payload,
                at: 44
            )
            writeUInt16(
                KernelBootIdentity.schemaVersion,
                to: &payload,
                at: 46
            )
            return frame(kind: .hello, requestID: 0, payload: payload)
        }

        func capabilities() -> [UInt8] {
            var payload = typedPayload(
                byteCount: SDBGTypedPayloadProtocol.capabilitiesByteCount,
                headerByteCount: SDBGTypedPayloadProtocol.typedHeaderByteCount
            )
            writeUInt32(
                SDBGCapabilitySet.readOnlyV1.rawValue,
                to: &payload,
                at: 8
            )
            writeUInt32(128, to: &payload, at: 12)
            writeUInt32(512, to: &payload, at: 16)
            writeUInt16(
                UInt16(KernelLogRing.recordByteCount),
                to: &payload,
                at: 20
            )
            writeUInt16(8, to: &payload, at: 22)
            return frame(
                kind: .capabilities,
                requestID: 0,
                payload: payload
            )
        }

        func response(to request: [UInt8]) -> [UInt8] {
            expect(request.count >= SDBGProtocol.headerByteCount + 12,
                   "request frame was too short")
            let requestID = readUInt64(request, at: 24)
            let operationRaw = readUInt16(
                request,
                at: SDBGProtocol.headerByteCount + 8
            )
            guard let operation = SDBGOperation(rawValue: operationRaw) else {
                fail("request used an unknown operation")
            }

            var payload: [UInt8]
            switch operation {
            case .identity:
                payload = responsePayload(
                    byteCount: SDBGTypedPayloadProtocol
                        .identityResponseByteCount,
                    operation: operation
                )
                writeUInt16(
                    KernelBuildIdentity.schemaVersion,
                    to: &payload,
                    at: 12
                )
                writeUInt16(
                    KernelBootIdentity.schemaVersion,
                    to: &payload,
                    at: 14
                )
                writeUInt16(identity.build.abiRevision, to: &payload, at: 16)
                payload[18] = identity.build.flavor.rawValue
                payload[19] = identity.reason.rawValue
                writeIdentity(identity.sessionID, to: &payload, at: 20)
                writeIdentity(identity.build.buildID, to: &payload, at: 36)
                writeUInt64(
                    identity.build.sourceRevision,
                    to: &payload,
                    at: 52
                )
                writeUInt64(
                    identity.build.imageDigestPrefix,
                    to: &payload,
                    at: 60
                )
                writeUInt64(identity.bootOrdinal, to: &payload, at: 68)
                writeUInt64(identity.startedAtTicks, to: &payload, at: 76)
            case .status:
                payload = responsePayload(
                    byteCount: SDBGTypedPayloadProtocol.statusResponseByteCount,
                    operation: operation
                )
                writeUInt64(status.snapshotSequence, to: &payload, at: 12)
                writeUInt64(status.monotonicTicks, to: &payload, at: 20)
                writeIdentity(status.bootSessionID, to: &payload, at: 28)
                payload[44] = status.phase.rawValue
                payload[45] = status.displayState.rawValue
                payload[46] = status.debugLinkState.rawValue
                payload[47] = status.updateState.rawValue
                writeUInt32(status.flags.rawValue, to: &payload, at: 48)
                writeUInt16(
                    status.configuredProcessorCount,
                    to: &payload,
                    at: 52
                )
                writeUInt16(
                    status.onlineProcessorCount,
                    to: &payload,
                    at: 54
                )
                writeUInt32(
                    status.runnableThreadCount,
                    to: &payload,
                    at: 56
                )
                writeUInt64(
                    status.managedMemoryByteCount,
                    to: &payload,
                    at: 60
                )
                writeUInt64(
                    status.freeMemoryByteCount,
                    to: &payload,
                    at: 68
                )
                writeUInt32(status.displayWidthPixels, to: &payload, at: 76)
                writeUInt32(status.displayHeightPixels, to: &payload, at: 80)
                writeUInt32(
                    status.displayRefreshMilliHertz,
                    to: &payload,
                    at: 84
                )
                writeUInt64(status.oldestLogSequence, to: &payload, at: 92)
                writeUInt64(status.newestLogSequence, to: &payload, at: 100)
                writeUInt64(status.lostLogEntryCount, to: &payload, at: 108)
                writeUInt16(status.lastError.domain, to: &payload, at: 116)
                writeUInt16(status.lastError.code, to: &payload, at: 118)
                writeUInt32(status.lastError.detail, to: &payload, at: 120)
            case .ping:
                payload = responsePayload(
                    byteCount: SDBGTypedPayloadProtocol.pingResponseByteCount,
                    operation: operation
                )
                writeUInt64(
                    readUInt64(
                        request,
                        at: SDBGProtocol.headerByteCount + 12
                    ),
                    to: &payload,
                    at: 12
                )
            case .logSnapshot:
                fail("log response fixture is not used by this test")
            }
            return frame(
                kind: .response,
                requestID: requestID,
                payload: payload
            )
        }

        private func responsePayload(
            byteCount: Int,
            operation: SDBGOperation
        ) -> [UInt8] {
            var payload = typedPayload(
                byteCount: byteCount,
                headerByteCount: SDBGTypedPayloadProtocol
                    .responseHeaderByteCount
            )
            writeUInt16(operation.rawValue, to: &payload, at: 8)
            writeUInt16(
                SDBGResponseStatus.success.rawValue,
                to: &payload,
                at: 10
            )
            return payload
        }

        private func typedPayload(
            byteCount: Int,
            headerByteCount: UInt16
        ) -> [UInt8] {
            var payload = [UInt8](repeating: 0, count: byteCount)
            writeUInt16(
                SDBGTypedPayloadProtocol.schemaVersion,
                to: &payload,
                at: 0
            )
            writeUInt16(headerByteCount, to: &payload, at: 2)
            writeUInt32(UInt32(byteCount), to: &payload, at: 4)
            return payload
        }

        private func frame(
            kind: SDBGMessageKind,
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
                            flags: .none,
                            bootSessionID: sessionID,
                            requestID: requestID
                        ),
                        payload: source,
                        into: destination
                    )
                }
            }
            guard case .encoded(let byteCount) = result,
                  byteCount == output.count
            else { fail("fixture frame encoding failed") }
            return output
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 24)
            | (UInt64(bytes[offset + 4]) << 32)
            | (UInt64(bytes[offset + 5]) << 40)
            | (UInt64(bytes[offset + 6]) << 48)
            | (UInt64(bytes[offset + 7]) << 56)
    }

    private static func writeUInt16(
        _ value: UInt16,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeUInt32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func writeUInt64(
        _ value: UInt64,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        writeUInt32(UInt32(truncatingIfNeeded: value), to: &bytes, at: offset)
        writeUInt32(
            UInt32(truncatingIfNeeded: value >> 32),
            to: &bytes,
            at: offset + 4
        )
    }

    private static func writeIdentity(
        _ value: KernelIdentity128,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        writeUInt64(value.high, to: &bytes, at: offset)
        writeUInt64(value.low, to: &bytes, at: offset + 8)
    }

    private static func expectError<E: Error & Equatable>(
        _ expected: E,
        _ message: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
        } catch let actual as E {
            expect(actual == expected, "\(message): \(actual)")
            return
        } catch {
            fail("\(message): wrong error \(error)")
        }
        fail(message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("SDBGSerialSessionTests: \(message)")
    }
}
