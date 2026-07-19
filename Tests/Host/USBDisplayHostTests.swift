@main
struct USBDisplayHostTests {
    static func main() {
        reassemblesFragmentedFullAndDamageFrames()
        recoversFromFramingGarbageWithinBounds()
        honorsSemanticResetRecovery()
        rejectsHostAllocationsBeyondTheConfiguredLimit()
        print("USB display host pipeline: 4 groups passed")
    }

    private static func reassemblesFragmentedFullAndDamageFrames() {
        let pipeline = USBDisplayHostPipeline(maximumFrameByteCount: 1_024)
        var events: [USBDisplayHostEvent] = []
        pipeline.onEvent = { events.append($0) }

        let displayMode = mode()
        let fullPixels = (0..<60).map { UInt8($0) }
        var wire: [UInt8] = [0xa5, 0x5a, 0x00]
        wire += handshake(mode: displayMode)
        wire += encode(
            .fullFrameBegin(
                USBDebugDisplayFullFrameBegin(
                    totalDataByteCount: 60,
                    chunkCount: 2
                )
            ),
            sequence: 4,
            frameID: 1
        )
        wire += encodeChunk(
            Array(fullPixels[0..<32]),
            sequence: 5,
            frameID: 1,
            chunkSequence: 1,
            offset: 0
        )
        wire += encodeChunk(
            Array(fullPixels[32..<60]),
            sequence: 6,
            frameID: 1,
            chunkSequence: 2,
            offset: 32
        )
        wire += encodeFrameEnd(
            pixels: fullPixels,
            chunkCount: 2,
            sequence: 7,
            frameID: 1
        )
        feedFragmented(wire, into: pipeline)

        let first = completedFrames(in: events)
        expect(first.count == 1, "full frame did not complete once")
        expect(first[0].frameID == 1, "full frame ID changed")
        expect(first[0].mode == displayMode, "mode metadata changed")
        expect(first[0].pixels == fullPixels, "full frame bytes changed")
        expect(first[0].updatedRectangle == nil, "full frame became damage")

        let rectangle = requireRectangle(x: 1, y: 1, width: 2, height: 2)
        let damage = [
            UInt8(201), 202, 203, 204, 211, 212, 213, 214,
            221, 222, 223, 224, 231, 232, 233, 234,
        ]
        var damageWire = encode(
            .damageFrameBegin(
                USBDebugDisplayDamageFrameBegin(
                    rectangle: rectangle,
                    totalDataByteCount: 16,
                    chunkCount: 1
                )
            ),
            sequence: 8,
            frameID: 2
        )
        damageWire += encodeChunk(
            damage,
            sequence: 9,
            frameID: 2,
            chunkSequence: 1,
            offset: 0
        )
        damageWire += encodeFrameEnd(
            pixels: damage,
            chunkCount: 1,
            sequence: 10,
            frameID: 2
        )
        feedFragmented(damageWire, into: pipeline)

        let frames = completedFrames(in: events)
        expect(frames.count == 2, "damage frame did not complete once")
        var expected = fullPixels
        expected.replaceSubrange(24..<32, with: damage[0..<8])
        expected.replaceSubrange(44..<52, with: damage[8..<16])
        expect(frames[1].pixels == expected, "damage rows were not assembled")
        expect(
            frames[1].updatedRectangle == rectangle,
            "damage rectangle metadata changed"
        )
        expect(
            Array(frames[1].pixels[36..<40]) == Array(fullPixels[36..<40])
                && Array(frames[1].pixels[56..<60])
                    == Array(fullPixels[56..<60]),
            "stride padding was overwritten by packed damage"
        )
    }

    private static func recoversFromFramingGarbageWithinBounds() {
        let pipeline = USBDisplayHostPipeline(maximumFrameByteCount: 1_024)
        var events: [USBDisplayHostEvent] = []
        pipeline.onEvent = { events.append($0) }

        var garbage = [UInt8](repeating: 0xcc, count: 256 * 1_024)
        // Leave a partial on-wire magic prefix at the end to exercise the
        // decoder's three-byte preservation rule across ingestion calls.
        garbage[garbage.count - 3] = 0x53
        garbage[garbage.count - 2] = 0x44
        garbage[garbage.count - 1] = 0x44
        garbage.withUnsafeBytes { pipeline.ingest($0) }

        let validHandshake = handshake(mode: mode())
        feedFragmented(validHandshake, into: pipeline)
        expect(
            events.contains(.modeChanged(mode())),
            "valid handshake was not recovered after bounded garbage"
        )
        expect(
            events.contains { event in
                if case .framingRejected = event { return true }
                return false
            },
            "garbage did not report a framing rejection"
        )
    }

    private static func honorsSemanticResetRecovery() {
        let pipeline = USBDisplayHostPipeline(maximumFrameByteCount: 1_024)
        var events: [USBDisplayHostEvent] = []
        pipeline.onEvent = { events.append($0) }
        handshake(mode: mode()).withUnsafeBytes { pipeline.ingest($0) }

        let badBegin = encode(
            .fullFrameBegin(
                USBDebugDisplayFullFrameBegin(
                    totalDataByteCount: 60,
                    chunkCount: 2
                )
            ),
            sequence: 5,
            frameID: 1
        )
        badBegin.withUnsafeBytes { pipeline.ingest($0) }
        expect(
            events.contains(
                .semanticRejected(.sequenceMismatch(expected: 4, actual: 5))
            ),
            "sequence violation was not rejected"
        )

        let reset = USBDebugDisplayReset(
            generation: 7,
            reason: .sequenceError,
            previousSessionID: sessionID
        )
        encode(.reset(reset), sequence: 900, frameID: 0)
            .withUnsafeBytes { pipeline.ingest($0) }
        expect(
            events.contains(.protocolReset(generation: 7)),
            "protocol reset was not accepted"
        )
        feedFragmented(handshake(mode: mode()), into: pipeline)
        let modeEvents = events.filter {
            if case .modeChanged = $0 { return true }
            return false
        }
        expect(modeEvents.count == 2, "reset did not permit a new handshake")
    }

    private static func rejectsHostAllocationsBeyondTheConfiguredLimit() {
        let pipeline = USBDisplayHostPipeline(maximumFrameByteCount: 32)
        var events: [USBDisplayHostEvent] = []
        pipeline.onEvent = { events.append($0) }
        handshake(mode: mode()).withUnsafeBytes { pipeline.ingest($0) }
        expect(
            events.contains(
                .assemblyRejected(
                    .frameTooLarge(requested: 60, maximum: 32)
                )
            ),
            "host allocation bound was not enforced"
        )
    }

    private static let sessionID: UInt64 = 0x1122_3344_5566_7788

    private static func mode() -> USBDebugDisplayMode {
        guard let value = USBDebugDisplayMode(
                  width: 4,
                  height: 3,
                  bytesPerRow: 20,
                  pixelFormat: .b8g8r8x8,
                  scaleNumerator: 2,
                  scaleDenominator: 1,
                  horizontalPixelsPerInchMilli: 110_000,
                  verticalPixelsPerInchMilli: 109_500,
                  refreshRateMilliHertz: 60_000
              )
        else { fail("display mode fixture rejected") }
        return value
    }

    private static func handshake(
        mode displayMode: USBDebugDisplayMode
    ) -> [UInt8] {
        guard let hello = USBDebugDisplayHello(
                  sessionID: sessionID,
                  role: .guest
              ),
              let capabilities = USBDebugDisplayCapabilities(
                  sessionID: sessionID,
                  features: USBDebugDisplayCapabilityBits(
                      rawValue: USBDebugDisplayCapabilityBits.required
                  ),
                  maximumPayloadByteCount: UInt32(
                      USBDebugDisplayProtocol.maximumPayloadByteCount
                  ),
                  maximumChunkDataByteCount: 32,
                  maximumWidth: 4,
                  maximumHeight: 3,
                  pixelFormatMask: displayMode.pixelFormat.capabilityMask
              )
        else { fail("handshake fixture rejected") }
        return encode(.hello(hello), sequence: 1, frameID: 0)
            + encode(.capabilities(capabilities), sequence: 2, frameID: 0)
            + encode(.displayMode(displayMode), sequence: 3, frameID: 0)
    }

    private static func encode(
        _ message: USBDebugDisplayMessage,
        sequence: UInt32,
        frameID: UInt64
    ) -> [UInt8] {
        var storage = [UInt8](
            repeating: 0,
            count: USBDebugDisplayProtocol.maximumPacketByteCount
        )
        let count = storage.withUnsafeMutableBytes { bytes -> Int in
            switch USBDebugDisplayPacketEncoder.encode(
                message,
                sequence: sequence,
                frameID: frameID,
                into: bytes
            ) {
            case .encoded(let byteCount): return byteCount
            case .rejected: fail("test packet failed to encode")
            }
        }
        return Array(storage.prefix(count))
    }

    private static func encodeChunk(
        _ bytes: [UInt8],
        sequence: UInt32,
        frameID: UInt64,
        chunkSequence: UInt32,
        offset: UInt64
    ) -> [UInt8] {
        bytes.withUnsafeBytes { raw in
            encode(
                .frameChunk(
                    USBDebugDisplayFrameChunk(
                        chunkSequence: chunkSequence,
                        offset: offset,
                        data: raw
                    )
                ),
                sequence: sequence,
                frameID: frameID
            )
        }
    }

    private static func encodeFrameEnd(
        pixels: [UInt8],
        chunkCount: UInt32,
        sequence: UInt32,
        frameID: UInt64
    ) -> [UInt8] {
        let crc = pixels.withUnsafeBytes {
            USBDebugDisplayCRC32.checksum($0)
        }
        return encode(
            .frameEnd(
                USBDebugDisplayFrameEnd(
                    chunkCount: chunkCount,
                    frameCRC32: crc,
                    totalDataByteCount: UInt64(pixels.count)
                )
            ),
            sequence: sequence,
            frameID: frameID
        )
    }

    private static func feedFragmented(
        _ bytes: [UInt8],
        into pipeline: USBDisplayHostPipeline
    ) {
        let fragmentSizes = [1, 2, 7, 3, 41, 5, 997, 11]
        var offset = 0
        var fragment = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let requested = fragmentSizes[fragment % fragmentSizes.count]
                let count = min(requested, raw.count - offset)
                pipeline.ingest(
                    UnsafeRawBufferPointer(
                        start: base.advanced(by: offset),
                        count: count
                    )
                )
                offset += count
                fragment += 1
            }
        }
    }

    private static func completedFrames(
        in events: [USBDisplayHostEvent]
    ) -> [USBDisplayCompletedFrame] {
        events.compactMap { event in
            if case .frameCompleted(let frame) = event { return frame }
            return nil
        }
    }

    private static func requireRectangle(
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32
    ) -> USBDebugDisplayDamageRectangle {
        guard let rectangle = USBDebugDisplayDamageRectangle(
                  x: x,
                  y: y,
                  width: width,
                  height: height
              )
        else { fail("damage rectangle fixture rejected") }
        return rectangle
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
