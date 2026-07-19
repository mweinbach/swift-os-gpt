@main
struct SDBGProtocolTests {
    static func main() {
        verifiesCRCAndWireLayout()
        roundTripsEveryMessageKind()
        enforcesEnvelopeSemanticsAndBounds()
        reassemblesFragmentedAndCoalescedFrames()
        resynchronizesAfterGarbageAndCorruption()
        rejectsMalformedHeadersAndRecovers()
        print("SDBG protocol: 6 groups passed")
    }

    private static func verifiesCRCAndWireLayout() {
        var crc = SDBGCRC32()
        Array("123456789".utf8).withUnsafeBytes {
            crc.update($0, count: $0.count)
        }
        expect(crc.value == 0xcbf4_3926, "CRC-32 check vector changed")

        let bytes = encode(
            kind: .request,
            flags: .none,
            bootSessionIDHigh: 0x0102_0304_0506_0708,
            bootSessionIDLow: 0x2122_2324_2526_2728,
            requestID: 0x1112_1314_1516_1718,
            payload: [0xaa, 0xbb, 0xcc]
        )
        expect(Array(bytes[0..<4]) == [0x53, 0x44, 0x42, 0x47],
               "SDBG magic is not little-endian")
        expect(bytes[4] == 1 && bytes[5] == 0 && bytes[6] == 3,
               "version or message kind moved")
        expect(read64(bytes, at: 8) == 0x0102_0304_0506_0708,
               "boot-session high word layout changed")
        expect(read64(bytes, at: 16) == 0x2122_2324_2526_2728,
               "boot-session low word layout changed")
        expect(read64(bytes, at: 24) == 0x1112_1314_1516_1718,
               "request ID layout changed")
        expect(read32(bytes, at: 32) == 3,
               "payload length layout changed")
        expect(Array(bytes[40..<43]) == [0xaa, 0xbb, 0xcc],
               "payload moved")
        expect(read32(bytes, at: 36) == frameCRC(bytes),
               "encoded frame CRC is incorrect")
    }

    private static func roundTripsEveryMessageKind() {
        let fixtures: [(SDBGMessageKind, SDBGMessageFlags, UInt64)] = [
            (.hello, .none, 0),
            (.capabilities, .none, 0),
            (.request, .none, 41),
            (.response, .error, 41),
            (.event, .moreFragments, 0),
            (.logChunk, .moreFragments, 0),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let payload = [UInt8(index), 0x80, 0xff]
            let encoded = encode(
                kind: fixture.0,
                flags: fixture.1,
                bootSessionIDHigh: 0xa0a0,
                bootSessionIDLow: 0xb0b0,
                requestID: fixture.2,
                payload: payload
            )
            withDecoder(maximumPayloadByteCount: 64) { decoder in
                encoded.withUnsafeBytes {
                    expect(decoder.append($0) == .appended,
                           "valid frame append failed")
                }
                guard case .frame(let frame) = decoder.pump() else {
                    fail("valid SDBG frame did not decode")
                }
                expect(frame.envelope.kind == fixture.0,
                       "decoded kind changed")
                expect(frame.envelope.flags == fixture.1,
                       "decoded flags changed")
                expect(
                    frame.envelope.bootSessionID
                        == SDBGBootSessionID(high: 0xa0a0, low: 0xb0b0),
                       "decoded session changed")
                expect(frame.envelope.requestID == fixture.2,
                       "decoded request changed")
                expect(Array(frame.payload) == payload,
                       "decoded payload changed")
                expect(frame.encodedByteCount == encoded.count,
                       "decoded byte count changed")
            }
        }
    }

    private static func enforcesEnvelopeSemanticsAndBounds() {
        let empty = [UInt8]()
        var output = [UInt8](repeating: 0, count: 128)
        func rejection(
            _ envelope: SDBGEnvelope,
            payload: [UInt8] = []
        ) -> SDBGEncodeRejection {
            output.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    switch SDBGFrameEncoder.encode(
                        envelope: envelope,
                        payload: source,
                        into: destination
                    ) {
                    case .encoded:
                        fail("invalid envelope encoded")
                    case .rejected(let reason):
                        return reason
                    }
                }
            }
        }

        expect(
            rejection(SDBGEnvelope(
                kind: .hello,
                flags: .none,
                bootSessionID: SDBGBootSessionID(high: 0, low: 0),
                requestID: 0
            )) == .invalidEnvelope(.zeroBootSessionID),
            "zero session was accepted"
        )
        expect(
            rejection(SDBGEnvelope(
                kind: .request,
                flags: .none,
                bootSessionID: SDBGBootSessionID(high: 0, low: 1),
                requestID: 0
            )) == .invalidEnvelope(.missingRequestID),
            "request without ID was accepted"
        )
        expect(
            rejection(SDBGEnvelope(
                kind: .event,
                flags: .none,
                bootSessionID: SDBGBootSessionID(high: 0, low: 1),
                requestID: 9
            )) == .invalidEnvelope(.unexpectedRequestID),
            "event with request ID was accepted"
        )
        expect(
            rejection(SDBGEnvelope(
                kind: .hello,
                flags: .error,
                bootSessionID: SDBGBootSessionID(high: 0, low: 1),
                requestID: 0
            )) == .invalidEnvelope(
                .flagsNotAllowed(kind: .hello, rawValue: 2)
            ),
            "HELLO error flag was accepted"
        )
        expect(
            rejection(SDBGEnvelope(
                kind: .response,
                flags: SDBGMessageFlags(rawValue: 0x80),
                bootSessionID: SDBGBootSessionID(high: 0, low: 1),
                requestID: 9
            )) == .invalidEnvelope(.unsupportedFlags(rawValue: 0x80)),
            "unknown flag was accepted"
        )

        var tiny = [UInt8](repeating: 0, count: 39)
        let valid = SDBGEnvelope(
            kind: .hello,
            flags: .none,
            bootSessionID: SDBGBootSessionID(high: 0, low: 1),
            requestID: 0
        )
        let smallResult = tiny.withUnsafeMutableBytes { destination in
            empty.withUnsafeBytes { source in
                SDBGFrameEncoder.encode(
                    envelope: valid,
                    payload: source,
                    into: destination
                )
            }
        }
        expect(
            smallResult == .rejected(
                .outputBufferTooSmall(required: 40, available: 39)
            ),
            "short output buffer was accepted"
        )

        let oversizedPayload = [UInt8](
            repeating: 0,
            count: SDBGProtocol.maximumPayloadByteCount + 1
        )
        let oversizedResult = output.withUnsafeMutableBytes { destination in
            oversizedPayload.withUnsafeBytes { source in
                SDBGFrameEncoder.encode(
                    envelope: valid,
                    payload: source,
                    into: destination
                )
            }
        }
        expect(
            oversizedResult == .rejected(
                .payloadTooLarge(
                    requested: SDBGProtocol.maximumPayloadByteCount + 1,
                    maximum: SDBGProtocol.maximumPayloadByteCount
                )
            ),
            "protocol payload bound was not enforced"
        )
    }

    private static func reassemblesFragmentedAndCoalescedFrames() {
        let first = encode(
            kind: .hello,
            flags: .none,
            bootSessionIDHigh: 0,
            bootSessionIDLow: 0xabc,
            requestID: 0,
            payload: [1, 2, 3, 4, 5]
        )
        let second = encode(
            kind: .request,
            flags: .none,
            bootSessionIDHigh: 0,
            bootSessionIDLow: 0xabc,
            requestID: 7,
            payload: [6, 7]
        )
        withDecoder(maximumPayloadByteCount: 64) { decoder in
            append(Array(first[0..<3]), to: &decoder)
            guard case .needsMoreBytes(let required) = decoder.pump() else {
                fail("split magic did not request more bytes")
            }
            expect(required == 4, "split magic requirement changed")

            append(Array(first[3..<17]), to: &decoder)
            guard case .needsMoreBytes(let headerRequired) = decoder.pump()
            else { fail("split header did not request more bytes") }
            expect(headerRequired == 40, "header requirement changed")

            var tail = Array(first[17..<first.count])
            tail.append(contentsOf: second)
            append(tail, to: &decoder)
            guard case .frame(let hello) = decoder.pump() else {
                fail("fragmented HELLO did not decode")
            }
            expect(Array(hello.payload) == [1, 2, 3, 4, 5],
                   "fragmented payload changed")
            guard case .frame(let request) = decoder.pump() else {
                fail("coalesced REQUEST did not decode")
            }
            expect(request.envelope.requestID == 7
                    && Array(request.payload) == [6, 7],
                   "coalesced frame changed")
            guard case .needsMoreBytes = decoder.pump() else {
                fail("decoder retained a phantom frame")
            }
        }
    }

    private static func resynchronizesAfterGarbageAndCorruption() {
        let valid = encode(
            kind: .logChunk,
            flags: .none,
            bootSessionIDHigh: 0,
            bootSessionIDLow: 99,
            requestID: 0,
            payload: [0x6f, 0x6b]
        )
        var corrupt = encode(
            kind: .event,
            flags: .none,
            bootSessionIDHigh: 0,
            bootSessionIDLow: 99,
            requestID: 0,
            payload: [0xde, 0xad]
        )
        corrupt[corrupt.count - 1] ^= 1

        withDecoder(maximumPayloadByteCount: 64) { decoder in
            append([0xee, 0x53, 0x44], to: &decoder)
            guard case .discarded(.invalidMagic, let discarded) = decoder.pump()
            else { fail("leading garbage was not discarded") }
            expect(discarded == 1, "partial magic prefix was not retained")

            var remainder: [UInt8] = [0x42, 0x47]
            // The retained S,D plus B,G form a false header; add a corrupt
            // complete frame and then a valid frame to exercise both paths.
            remainder.append(contentsOf: corrupt)
            remainder.append(contentsOf: valid)
            append(remainder, to: &decoder)
            drainUntilFrame(decoder: &decoder) { frame in
                expect(frame.envelope.kind == .logChunk,
                       "decoder did not recover to valid LOG_CHUNK")
                expect(Array(frame.payload) == [0x6f, 0x6b],
                       "recovered payload changed")
            }
        }
    }

    private static func rejectsMalformedHeadersAndRecovers() {
        let valid = encode(
            kind: .hello,
            flags: .none,
            bootSessionIDHigh: 0,
            bootSessionIDLow: 3,
            requestID: 0,
            payload: []
        )
        let mutations: [(Int, UInt8, SDBGDecodeRejection)] = [
            (4, 2, .unsupportedVersion(major: 2, minor: 0)),
            (6, 0xff, .unknownMessageKind(rawValue: 0xff)),
            (16, 0, .invalidEnvelope(.zeroBootSessionID)),
        ]
        for mutation in mutations {
            var malformed = valid
            malformed[mutation.0] = mutation.1
            withDecoder(maximumPayloadByteCount: 64) { decoder in
                append(malformed, to: &decoder)
                guard case .discarded(let rejection, let count) = decoder.pump()
                else { fail("malformed header was not rejected") }
                expect(rejection == mutation.2 && count == 1,
                       "malformed header rejection changed")
            }
        }

        var oversized = valid
        write32(65, to: &oversized, at: 32)
        withDecoder(maximumPayloadByteCount: 64) { decoder in
            append(oversized, to: &decoder)
            guard case .discarded(
                .payloadTooLarge(let requested, let maximum),
                let count
            ) = decoder.pump() else {
                fail("oversized payload was not rejected")
            }
            expect(requested == 65 && maximum == 64 && count == 1,
                   "oversized rejection details changed")
        }
    }

    private static func encode(
        kind: SDBGMessageKind,
        flags: SDBGMessageFlags,
        bootSessionIDHigh: UInt64,
        bootSessionIDLow: UInt64,
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
                        bootSessionID: SDBGBootSessionID(
                            high: bootSessionIDHigh,
                            low: bootSessionIDLow
                        ),
                        requestID: requestID
                    ),
                    payload: source,
                    into: destination
                )
            }
        }
        expect(result == .encoded(byteCount: output.count),
               "valid fixture did not encode")
        return output
    }

    private static func withDecoder(
        maximumPayloadByteCount: Int,
        _ body: (inout SDBGStreamDecoder) -> Void
    ) {
        var storage = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + maximumPayloadByteCount + 256
        )
        storage.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress,
                  var decoder = SDBGStreamDecoder(
                      storageBaseAddress: UInt(bitPattern: base),
                      storageByteCount: bytes.count,
                      maximumPayloadByteCount: maximumPayloadByteCount
                  )
            else { fail("decoder fixture failed") }
            body(&decoder)
        }
    }

    private static func append(
        _ bytes: [UInt8],
        to decoder: inout SDBGStreamDecoder
    ) {
        bytes.withUnsafeBytes {
            expect(decoder.append($0) == .appended, "stream append failed")
        }
    }

    private static func drainUntilFrame(
        decoder: inout SDBGStreamDecoder,
        _ body: (SDBGDecodedFrame) -> Void
    ) {
        var attempts = 0
        while attempts < 256 {
            attempts += 1
            switch decoder.pump() {
            case .frame(let frame):
                body(frame)
                return
            case .discarded:
                continue
            case .needsMoreBytes:
                fail("decoder stopped before finding the valid frame")
            }
        }
        fail("decoder did not converge while resynchronizing")
    }

    private static func frameCRC(_ frame: [UInt8]) -> UInt32 {
        var crc = SDBGCRC32()
        frame.withUnsafeBytes { bytes in
            crc.update(bytes, offset: 0, count: 36)
            crc.update(bytes, offset: 40, count: bytes.count - 40)
        }
        return crc.value
    }

    private static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(read32(bytes, at: offset))
            | UInt64(read32(bytes, at: offset + 4)) << 32
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

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError(message)
    }
}
