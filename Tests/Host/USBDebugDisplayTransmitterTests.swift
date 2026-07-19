@main
struct USBDebugDisplayTransmitterTests {
    static func main() {
        emitsHandshakeAndFullFrameWithoutAdvancingEarly()
        packsDamageRowsWithoutLeakingStridePadding()
        respectsTransportChunkLimit()
        coalescesQueuedDamageConservatively()
        rejectsUndersizedPacketStorage()
        print("USB debug display transmitter: 5 groups passed")
    }

    private static func emitsHandshakeAndFullFrameWithoutAdvancingEarly() {
        var pixels = Array(UInt8(0)..<UInt8(40))
        let expectedPixels = pixels
        pixels.withUnsafeMutableBytes { source in
            var transmitter = makeTransmitter(source: source)
            transmitter.requestFullFrame()
            var packet = [UInt8](
                repeating: 0,
                count: USBDebugDisplayProtocol.maximumPacketByteCount
            )
            var receiver = USBDebugDisplayReceiver()
            var messages: [USBDebugDisplayMessageType] = []
            var receivedFrame = [UInt8]()
            var firstPacket: [UInt8]?

            while messages.last != .frameEnd {
                let result = packet.withUnsafeMutableBytes {
                    transmitter.prepareNextPacket(into: $0)
                }
                guard case .packet(let byteCount) = result else {
                    fail("transmitter became idle before frame end")
                }
                if firstPacket == nil {
                    firstPacket = Array(packet.prefix(byteCount))
                    let repeated = packet.withUnsafeMutableBytes {
                        transmitter.prepareNextPacket(into: $0)
                    }
                    expect(
                        repeated == .packet(byteCount: byteCount),
                        "uncommitted packet changed state"
                    )
                    expect(
                        Array(packet.prefix(byteCount)) == firstPacket,
                        "uncommitted packet bytes changed"
                    )
                }
                let decoded = packet.withUnsafeBytes { bytes -> USBDebugDisplayDecodedPacket in
                    switch USBDebugDisplayPacketDecoder.decodePrefix(
                        UnsafeRawBufferPointer(start: bytes.baseAddress, count: byteCount)
                    ) {
                    case .decoded(let decoded): return decoded
                    default: fail("transmitter emitted an invalid packet")
                    }
                }
                expect(
                    isAccepted(receiver.accept(decoded)),
                    "semantic receiver rejected transmitter packet"
                )
                messages.append(decoded.message.type)
                if case .frameChunk(let chunk) = decoded.message {
                    receivedFrame.append(contentsOf: chunk.data)
                }
                expect(
                    transmitter.commitPreparedPacket(),
                    "prepared packet did not commit"
                )
            }
            expect(
                messages == [
                    .hello, .capabilities, .displayMode,
                    .fullFrameBegin, .frameChunk, .frameEnd,
                ],
                "full-frame sequence changed"
            )
            expect(receivedFrame == expectedPixels, "full frame bytes changed")
            expect(transmitter.phase == .ready, "transmitter did not become ready")
        }
    }

    private static func packsDamageRowsWithoutLeakingStridePadding() {
        var pixels = Array(UInt8(0)..<UInt8(40))
        let expectedDamage = Array(pixels[4..<12]) + Array(pixels[24..<32])
        pixels.withUnsafeMutableBytes { source in
            var transmitter = makeTransmitter(source: source)
            commitHandshake(&transmitter)
            guard let damage = DamageRectangle.clipped(
                      x: 1,
                      y: 0,
                      width: 2,
                      height: 2,
                      to: testMode()
                  )
            else {
                fail("damage fixture rejected")
            }
            transmitter.requestDamage(damage)
            var packet = [UInt8](
                repeating: 0,
                count: USBDebugDisplayProtocol.maximumPacketByteCount
            )
            var captured = [UInt8]()
            var sawDamageBegin = false
            while transmitter.phase != .ready || transmitter.hasQueuedFrame {
                let count = packet.withUnsafeMutableBytes { bytes -> Int in
                    guard case .packet(let count) = transmitter.prepareNextPacket(
                              into: bytes
                          )
                    else { fail("damage packet missing") }
                    return count
                }
                packet.withUnsafeBytes { bytes in
                    switch USBDebugDisplayPacketDecoder.decodePrefix(
                        UnsafeRawBufferPointer(start: bytes.baseAddress, count: count)
                    ) {
                    case .decoded(let decoded):
                        if case .damageFrameBegin = decoded.message {
                            sawDamageBegin = true
                        }
                        if case .frameChunk(let chunk) = decoded.message {
                            captured.append(contentsOf: chunk.data)
                        }
                    default:
                        fail("damage packet did not decode")
                    }
                }
                _ = transmitter.commitPreparedPacket()
            }
            expect(sawDamageBegin, "damage was promoted to a full frame")
            expect(
                captured == expectedDamage,
                "damage stream leaked row padding or wrong columns"
            )
        }
    }

    private static func coalescesQueuedDamageConservatively() {
        var pixels = Array(UInt8(0)..<UInt8(40))
        pixels.withUnsafeMutableBytes { source in
            var transmitter = makeTransmitter(source: source)
            let first = DamageRectangle.clipped(
                x: 1, y: 0, width: 1, height: 1, to: testMode()
            )!
            let second = DamageRectangle.clipped(
                x: 3, y: 1, width: 1, height: 1, to: testMode()
            )!
            transmitter.requestDamage(first)
            transmitter.requestDamage(second)
            commitHandshake(&transmitter)
            var packet = [UInt8](
                repeating: 0,
                count: USBDebugDisplayProtocol.maximumPacketByteCount
            )
            let count = packet.withUnsafeMutableBytes { bytes -> Int in
                guard case .packet(let count) = transmitter.prepareNextPacket(
                          into: bytes
                      )
                else { fail("coalesced frame begin missing") }
                return count
            }
            packet.withUnsafeBytes { bytes in
                guard case .decoded(let decoded) = USBDebugDisplayPacketDecoder.decodePrefix(
                          UnsafeRawBufferPointer(start: bytes.baseAddress, count: count)
                      ), case .damageFrameBegin(let begin) = decoded.message
                else { fail("coalesced damage begin did not decode") }
                expect(
                    begin.rectangle == USBDebugDisplayDamageRectangle(
                        x: 1, y: 0, width: 3, height: 2
                    ),
                    "damage union did not cover both updates"
                )
            }
        }
    }

    private static func respectsTransportChunkLimit() {
        var pixels = [UInt8](repeating: 0xa5, count: 1_200)
        pixels.withUnsafeMutableBytes { source in
            let mode = DisplayMode(
                widthInPixels: 100,
                heightInPixels: 3,
                refreshRateMilliHertz: nil,
                pixelFormat: .b8g8r8x8
            )!
            guard let base = source.baseAddress,
                  var transmitter = USBDebugDisplayTransmitter(
                      sourceBaseAddress: UInt64(UInt(bitPattern: base)),
                      sourceByteCount: UInt64(source.count),
                      mode: mode,
                      bytesPerRow: 400,
                      scaleNumerator: 1,
                      sessionID: 7,
                      maximumChunkDataByteCount: 456
                  )
            else { fail("limited transmitter fixture rejected") }
            transmitter.requestFullFrame()
            var packet = [UInt8](
                repeating: 0,
                count: USBDebugDisplayProtocol.maximumPacketByteCount
            )
            var chunkLengths: [Int] = []
            while transmitter.phase != .ready || transmitter.hasQueuedFrame {
                guard case .packet(let count) = packet.withUnsafeMutableBytes({
                    transmitter.prepareNextPacket(into: $0)
                }) else { fail("limited transmitter packet missing") }
                packet.withUnsafeBytes { bytes in
                    guard case .decoded(let decoded)
                            = USBDebugDisplayPacketDecoder.decodePrefix(
                                UnsafeRawBufferPointer(
                                    start: bytes.baseAddress,
                                    count: count
                                )
                            )
                    else { fail("limited packet failed decode") }
                    if case .frameChunk(let chunk) = decoded.message {
                        chunkLengths.append(chunk.data.count)
                    }
                }
                _ = transmitter.commitPreparedPacket()
            }
            expect(
                chunkLengths == [456, 456, 288],
                "transport chunk limit was not honored"
            )
        }
    }

    private static func rejectsUndersizedPacketStorage() {
        var pixels = Array(UInt8(0)..<UInt8(40))
        pixels.withUnsafeMutableBytes { source in
            var transmitter = makeTransmitter(source: source)
            var output = [UInt8](repeating: 0, count: 64)
            expect(
                output.withUnsafeMutableBytes {
                    transmitter.prepareNextPacket(into: $0)
                } == .outputBufferTooSmall(
                    requiredByteCount: USBDebugDisplayProtocol.maximumPacketByteCount
                ),
                "undersized staging buffer was accepted"
            )
            expect(transmitter.phase == .hello, "buffer pressure corrupted state")
        }
    }

    private static func commitHandshake(
        _ transmitter: inout USBDebugDisplayTransmitter
    ) {
        var packet = [UInt8](
            repeating: 0,
            count: USBDebugDisplayProtocol.maximumPacketByteCount
        )
        var count = 0
        while count < 3 {
            guard case .packet = packet.withUnsafeMutableBytes({
                transmitter.prepareNextPacket(into: $0)
            }), transmitter.commitPreparedPacket() else {
                fail("handshake did not commit")
            }
            count += 1
        }
        expect(transmitter.phase == .ready, "handshake did not reach ready")
    }

    private static func makeTransmitter(
        source: UnsafeMutableRawBufferPointer
    ) -> USBDebugDisplayTransmitter {
        guard let base = source.baseAddress,
              let transmitter = USBDebugDisplayTransmitter(
                  sourceBaseAddress: UInt64(UInt(bitPattern: base)),
                  sourceByteCount: UInt64(source.count),
                  mode: testMode(),
                  bytesPerRow: 20,
                  scaleNumerator: 1,
                  sessionID: 0x1234
              )
        else {
            fail("transmitter fixture rejected")
        }
        return transmitter
    }

    private static func testMode() -> DisplayMode {
        DisplayMode(
            widthInPixels: 4,
            heightInPixels: 2,
            refreshRateMilliHertz: 60_000,
            pixelFormat: .b8g8r8x8
        )!
    }

    private static func isAccepted(
        _ result: USBDebugDisplayReceiverResult
    ) -> Bool {
        if case .accepted = result { return true }
        return false
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
