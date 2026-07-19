@main
struct USBDebugDisplayProtocolTests {
    static func main() {
        validatesCRCAndPacketRoundTrips()
        negotiatesAndCompletesAFullFrame()
        validatesDamageBoundsAndResetRecovery()
        rejectsChunkGapsAndRequiresReset()
        enforcesPacketBoundsAndStreamRecovery()
        print("USB debug display protocol host tests: 5 groups passed")
    }

    private static func validatesCRCAndPacketRoundTrips() {
        let vector = Array("123456789".utf8)
        let checksum = vector.withUnsafeBytes {
            USBDebugDisplayCRC32.checksum($0)
        }
        expect(checksum == 0xcbf4_3926, "CRC-32 reference vector")

        let mode = requireMode()
        let bytes = encode(.displayMode(mode), sequence: 3, frameID: 0)
        bytes.withUnsafeBytes { raw in
            let packet = requireDecoded(raw)
            expect(packet.sequence == 3, "mode sequence")
            expect(packet.frameID == 0, "control frame ID")
            expect(
                packet.encodedByteCount
                    == USBDebugDisplayProtocol.headerByteCount + 36,
                "mode packet length"
            )
            guard case .displayMode(let decodedMode) = packet.message else {
                fatalError("mode packet decoded as wrong type")
            }
            expect(decodedMode == mode, "display metadata round trip")
        }

        var corrupted = bytes
        corrupted[USBDebugDisplayProtocol.headerByteCount + 4] ^= 0x80
        corrupted.withUnsafeBytes { raw in
            expectDecodeRejection(
                USBDebugDisplayPacketDecoder.decodePrefix(raw),
                .payloadChecksumMismatch,
                "payload corruption was accepted"
            )
        }

        var damagedHeader = bytes
        damagedHeader[16] ^= 0x40
        damagedHeader.withUnsafeBytes { raw in
            expectDecodeRejection(
                USBDebugDisplayPacketDecoder.decodePrefix(raw),
                .headerChecksumMismatch,
                "header corruption was accepted"
            )
        }
    }

    private static func negotiatesAndCompletesAFullFrame() {
        var receiver = USBDebugDisplayReceiver()
        acceptHandshake(into: &receiver)
        expect(receiver.phase == .ready, "handshake did not reach ready")
        expect(receiver.mode == requireMode(), "mode metadata not retained")

        let frame = makeFrameBytes(count: 64)
        let first = Array(frame[0..<32])
        let second = Array(frame[32..<64])
        let frameCRC = frame.withUnsafeBytes {
            USBDebugDisplayCRC32.checksum($0)
        }
        expectAccepted(
            accept(
                encode(
                    .fullFrameBegin(
                        USBDebugDisplayFullFrameBegin(
                            totalDataByteCount: 64,
                            chunkCount: 2
                        )
                    ),
                    sequence: 4,
                    frameID: 1
                ),
                into: &receiver
            ),
            .frameBegan(kind: .fullFrame, frameID: 1),
            "full frame begin"
        )
        expectAccepted(
            acceptChunk(
                first,
                globalSequence: 5,
                frameID: 1,
                chunkSequence: 1,
                offset: 0,
                into: &receiver
            ),
            .chunkAccepted(frameID: 1, chunkSequence: 1),
            "first chunk"
        )
        expectAccepted(
            acceptChunk(
                second,
                globalSequence: 6,
                frameID: 1,
                chunkSequence: 2,
                offset: 32,
                into: &receiver
            ),
            .chunkAccepted(frameID: 1, chunkSequence: 2),
            "second chunk"
        )
        expectAccepted(
            accept(
                encode(
                    .frameEnd(
                        USBDebugDisplayFrameEnd(
                            chunkCount: 2,
                            frameCRC32: frameCRC,
                            totalDataByteCount: 64
                        )
                    ),
                    sequence: 7,
                    frameID: 1
                ),
                into: &receiver
            ),
            .frameCompleted(frameID: 1),
            "frame completion"
        )
        expect(receiver.phase == .ready, "completed frame did not return ready")
    }

    private static func validatesDamageBoundsAndResetRecovery() {
        var receiver = USBDebugDisplayReceiver()
        acceptHandshake(into: &receiver)
        let outside = requireRectangle(x: 3, y: 1, width: 2, height: 2)
        let result = accept(
            encode(
                .damageFrameBegin(
                    USBDebugDisplayDamageFrameBegin(
                        rectangle: outside,
                        totalDataByteCount: 16,
                        chunkCount: 1
                    )
                ),
                sequence: 4,
                frameID: 1
            ),
            into: &receiver
        )
        expectRejected(result, .unsupportedDisplayMode, "damage escaped mode")
        expect(receiver.phase == .awaitingReset, "bounds fault was not sticky")

        let hello = encode(.hello(requireHello()), sequence: 4, frameID: 0)
        expectRejected(
            accept(hello, into: &receiver),
            .resetRequired,
            "faulted receiver accepted handshake without reset"
        )
        let reset = USBDebugDisplayReset(
            generation: 9,
            reason: .boundsError,
            previousSessionID: 0x1020_3040_5060_7080
        )
        expectAccepted(
            accept(
                encode(.reset(reset), sequence: 999, frameID: 0),
                into: &receiver
            ),
            .resetAccepted(generation: 9),
            "reset recovery"
        )
        expect(receiver.phase == .awaitingHello, "reset did not clear session")
        acceptHandshake(into: &receiver)

        let rectangle = requireRectangle(x: 1, y: 1, width: 2, height: 2)
        let pixels = makeFrameBytes(count: 16)
        let crc = pixels.withUnsafeBytes {
            USBDebugDisplayCRC32.checksum($0)
        }
        expectAccepted(
            accept(
                encode(
                    .damageFrameBegin(
                        USBDebugDisplayDamageFrameBegin(
                            rectangle: rectangle,
                            totalDataByteCount: 16,
                            chunkCount: 1
                        )
                    ),
                    sequence: 4,
                    frameID: 1
                ),
                into: &receiver
            ),
            .frameBegan(kind: .damageRectangle, frameID: 1),
            "bounded damage begin"
        )
        _ = acceptChunk(
            pixels,
            globalSequence: 5,
            frameID: 1,
            chunkSequence: 1,
            offset: 0,
            into: &receiver
        )
        expectAccepted(
            accept(
                encode(
                    .frameEnd(
                        USBDebugDisplayFrameEnd(
                            chunkCount: 1,
                            frameCRC32: crc,
                            totalDataByteCount: 16
                        )
                    ),
                    sequence: 6,
                    frameID: 1
                ),
                into: &receiver
            ),
            .frameCompleted(frameID: 1),
            "bounded damage completion"
        )
    }

    private static func rejectsChunkGapsAndRequiresReset() {
        var receiver = USBDebugDisplayReceiver()
        acceptHandshake(into: &receiver)
        let rectangle = requireRectangle(x: 0, y: 0, width: 2, height: 2)
        _ = accept(
            encode(
                .damageFrameBegin(
                    USBDebugDisplayDamageFrameBegin(
                        rectangle: rectangle,
                        totalDataByteCount: 16,
                        chunkCount: 1
                    )
                ),
                sequence: 4,
                frameID: 1
            ),
            into: &receiver
        )
        let pixels = makeFrameBytes(count: 16)
        expectRejected(
            acceptChunk(
                pixels,
                globalSequence: 5,
                frameID: 1,
                chunkSequence: 1,
                offset: 1,
                into: &receiver
            ),
            .chunkOffsetMismatch(expected: 0, actual: 1),
            "chunk gap was accepted"
        )
        expect(receiver.phase == .awaitingReset, "chunk fault was not sticky")

        let reset = USBDebugDisplayReset(
            generation: 10,
            reason: .sequenceError,
            previousSessionID: 0x1020_3040_5060_7080
        )
        _ = accept(
            encode(.reset(reset), sequence: UInt32.max, frameID: 0),
            into: &receiver
        )
        expect(receiver.phase == .awaitingHello, "arbitrary reset sequence failed")

        var missingFeaturesReceiver = USBDebugDisplayReceiver()
        _ = accept(
            encode(.hello(requireHello()), sequence: 1, frameID: 0),
            into: &missingFeaturesReceiver
        )
        let incomplete = requireCapabilities(
            featureBits: USBDebugDisplayCapabilityBits.fullFrames
        )
        expectRejected(
            accept(
                encode(.capabilities(incomplete), sequence: 2, frameID: 0),
                into: &missingFeaturesReceiver
            ),
            .requiredCapabilitiesMissing,
            "required diagnostic capabilities were optional"
        )

        var checksumReceiver = USBDebugDisplayReceiver()
        acceptHandshake(into: &checksumReceiver)
        let checksumRectangle = requireRectangle(
            x: 0,
            y: 0,
            width: 2,
            height: 2
        )
        _ = accept(
            encode(
                .damageFrameBegin(
                    USBDebugDisplayDamageFrameBegin(
                        rectangle: checksumRectangle,
                        totalDataByteCount: 16,
                        chunkCount: 1
                    )
                ),
                sequence: 4,
                frameID: 1
            ),
            into: &checksumReceiver
        )
        _ = acceptChunk(
            pixels,
            globalSequence: 5,
            frameID: 1,
            chunkSequence: 1,
            offset: 0,
            into: &checksumReceiver
        )
        let actualCRC = pixels.withUnsafeBytes {
            USBDebugDisplayCRC32.checksum($0)
        }
        expectRejected(
            accept(
                encode(
                    .frameEnd(
                        USBDebugDisplayFrameEnd(
                            chunkCount: 1,
                            frameCRC32: actualCRC ^ 1,
                            totalDataByteCount: 16
                        )
                    ),
                    sequence: 6,
                    frameID: 1
                ),
                into: &checksumReceiver
            ),
            .frameChecksumMismatch(
                expected: actualCRC,
                actual: actualCRC ^ 1
            ),
            "aggregate frame checksum was not enforced"
        )
    }

    private static func enforcesPacketBoundsAndStreamRecovery() {
        let hello = encode(.hello(requireHello()), sequence: 1, frameID: 0)
        hello.withUnsafeBytes { raw in
            let truncated = UnsafeRawBufferPointer(
                rebasing: raw[0..<USBDebugDisplayProtocol.headerByteCount]
            )
            guard case .needMoreBytes(let required) =
                    USBDebugDisplayPacketDecoder.decodePrefix(truncated)
            else {
                fatalError("truncated packet was not deferred")
            }
            expect(required == hello.count, "truncated packet requirement")
        }

        var invalidLength = hello
        invalidLength[32] &+= 1
        invalidLength.withUnsafeBytes { raw in
            expectDecodeRejection(
                USBDebugDisplayPacketDecoder.decodePrefix(raw),
                .inconsistentPacketLength,
                "inconsistent packet length"
            )
        }

        var stream: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd, 0xee]
        stream.append(contentsOf: hello)
        stream.withUnsafeBytes { raw in
            guard case .rejected(
                      .invalidMagic,
                      let discard
                  ) = USBDebugDisplayPacketDecoder.decodePrefix(raw)
            else {
                fatalError("stream junk was accepted")
            }
            expect(discard == 5, "stream recovery did not find next magic")
            let recovered = UnsafeRawBufferPointer(rebasing: raw[discard...])
            let packet = requireDecoded(recovered)
            expect(packet.sequence == 1, "stream did not recover packet")
        }

        var tiny = [UInt8](repeating: 0, count: 8)
        tiny.withUnsafeMutableBytes { raw in
            expect(
                USBDebugDisplayPacketEncoder.encode(
                    .hello(requireHello()),
                    sequence: 1,
                    frameID: 0,
                    into: raw
                ) == .rejected(
                    .outputBufferTooSmall(required: 56, available: 8)
                ),
                "undersized output buffer"
            )
            expect(
                USBDebugDisplayPacketEncoder.encode(
                    .hello(requireHello()),
                    sequence: 0,
                    frameID: 0,
                    into: raw
                ) == .rejected(.zeroSequence),
                "zero sequence encoded"
            )
        }

        let impossible = USBDebugDisplayMode(
            width: UInt32.max,
            height: 1,
            bytesPerRow: UInt32.max,
            pixelFormat: .b8g8r8a8,
            scaleNumerator: 1,
            scaleDenominator: 1,
            horizontalPixelsPerInchMilli: 0,
            verticalPixelsPerInchMilli: 0,
            refreshRateMilliHertz: 0
        )
        expect(impossible == nil, "oversized display mode accepted")
        expect(
            USBDebugDisplayDamageRectangle(
                x: UInt32.max,
                y: 0,
                width: 2,
                height: 1
            ) == nil,
            "overflowing damage rectangle accepted"
        )
    }

    private static func acceptHandshake(
        into receiver: inout USBDebugDisplayReceiver
    ) {
        expectAccepted(
            accept(
                encode(.hello(requireHello()), sequence: 1, frameID: 0),
                into: &receiver
            ),
            .helloAccepted,
            "hello"
        )
        expectAccepted(
            accept(
                encode(
                    .capabilities(requireCapabilities()),
                    sequence: 2,
                    frameID: 0
                ),
                into: &receiver
            ),
            .capabilitiesAccepted,
            "capabilities"
        )
        expectAccepted(
            accept(
                encode(
                    .displayMode(requireMode()),
                    sequence: 3,
                    frameID: 0
                ),
                into: &receiver
            ),
            .displayModeAccepted,
            "display mode"
        )
    }

    private static func requireHello() -> USBDebugDisplayHello {
        guard let hello = USBDebugDisplayHello(
                  sessionID: 0x1020_3040_5060_7080,
                  role: .guest
              )
        else { fatalError("valid hello rejected") }
        return hello
    }

    private static func requireCapabilities(
        featureBits: UInt32 = USBDebugDisplayCapabilityBits.required
    ) -> USBDebugDisplayCapabilities {
        guard let capabilities = USBDebugDisplayCapabilities(
                  sessionID: 0x1020_3040_5060_7080,
                  features: USBDebugDisplayCapabilityBits(
                      rawValue: featureBits
                  ),
                  maximumPayloadByteCount: 64,
                  maximumChunkDataByteCount: 32,
                  maximumWidth: 4_096,
                  maximumHeight: 2_160,
                  pixelFormatMask:
                    USBDebugDisplayPixelFormat.b8g8r8x8.capabilityMask
                    | USBDebugDisplayPixelFormat.b8g8r8a8.capabilityMask
              )
        else { fatalError("valid capabilities rejected") }
        return capabilities
    }

    private static func requireMode() -> USBDebugDisplayMode {
        guard let mode = USBDebugDisplayMode(
                  width: 4,
                  height: 4,
                  bytesPerRow: 16,
                  pixelFormat: .b8g8r8a8,
                  scaleNumerator: 2,
                  scaleDenominator: 1,
                  horizontalPixelsPerInchMilli: 109_000,
                  verticalPixelsPerInchMilli: 110_000,
                  refreshRateMilliHertz: 59_940
              )
        else { fatalError("valid mode rejected") }
        return mode
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
        else { fatalError("valid rectangle rejected") }
        return rectangle
    }

    private static func makeFrameBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11)
            index += 1
        }
        return bytes
    }

    private static func encode(
        _ message: USBDebugDisplayMessage,
        sequence: UInt32,
        frameID: UInt64
    ) -> [UInt8] {
        var bytes = [UInt8](
            repeating: 0,
            count: USBDebugDisplayProtocol.maximumPacketByteCount
        )
        let count = bytes.withUnsafeMutableBytes { raw -> Int in
            switch USBDebugDisplayPacketEncoder.encode(
                message,
                sequence: sequence,
                frameID: frameID,
                into: raw
            ) {
            case .encoded(let byteCount): return byteCount
            case .rejected(let rejection):
                fatalError("valid message rejected: \(rejection)")
            }
        }
        bytes.removeSubrange(count...)
        return bytes
    }

    private static func acceptChunk(
        _ data: [UInt8],
        globalSequence: UInt32,
        frameID: UInt64,
        chunkSequence: UInt32,
        offset: UInt64,
        into receiver: inout USBDebugDisplayReceiver
    ) -> USBDebugDisplayReceiverResult {
        data.withUnsafeBytes { raw in
            let message = USBDebugDisplayMessage.frameChunk(
                USBDebugDisplayFrameChunk(
                    chunkSequence: chunkSequence,
                    offset: offset,
                    data: raw
                )
            )
            return accept(
                encode(
                    message,
                    sequence: globalSequence,
                    frameID: frameID
                ),
                into: &receiver
            )
        }
    }

    private static func accept(
        _ bytes: [UInt8],
        into receiver: inout USBDebugDisplayReceiver
    ) -> USBDebugDisplayReceiverResult {
        bytes.withUnsafeBytes { raw in
            receiver.accept(requireDecoded(raw))
        }
    }

    private static func requireDecoded(
        _ bytes: UnsafeRawBufferPointer
    ) -> USBDebugDisplayDecodedPacket {
        switch USBDebugDisplayPacketDecoder.decodePrefix(bytes) {
        case .decoded(let packet): return packet
        case .needMoreBytes(let required):
            fatalError("complete packet requested \(required) bytes")
        case .rejected(let rejection, _):
            fatalError("valid packet rejected: \(rejection)")
        }
    }

    private static func expectDecodeRejection(
        _ result: USBDebugDisplayDecodeResult,
        _ expected: USBDebugDisplayDecodeRejection,
        _ message: String
    ) {
        guard case .rejected(let actual, let discard) = result,
              actual == expected,
              discard > 0
        else { fatalError(message) }
    }

    private static func expectAccepted(
        _ result: USBDebugDisplayReceiverResult,
        _ expected: USBDebugDisplayReceiverEvent,
        _ message: String
    ) {
        guard result == .accepted(expected) else { fatalError(message) }
    }

    private static func expectRejected(
        _ result: USBDebugDisplayReceiverResult,
        _ expected: USBDebugDisplayReceiverRejection,
        _ message: String
    ) {
        guard result == .rejected(expected) else { fatalError(message) }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
