@main
struct USBGadgetProtocolTests {
    static func main() {
        testTypedSetupPacketParsing()
        testDeviceAndQualifierDescriptors()
        testCompositeConfigurationDescriptors()
        testStringAndBoundedDescriptorReplies()
        testDeferredAddressAndConfigurationState()
        testStatusAndFeatureHandling()
        testInterfaceAndCDCControlRequests()
        testPreciseRejectionsAndReset()
        print("USB gadget protocol host tests: 8 groups passed")
    }

    private static func testTypedSetupPacketParsing() {
        let packet = parseSetup([
            0x81, 0x06, 0x02, 0x01, 0x09, 0x04, 0x40, 0x00,
        ])
        expect(packet.requestType.direction == .deviceToHost, "direction parse")
        expect(packet.requestType.kind == .standard, "kind parse")
        expect(packet.requestType.recipient == .interface, "recipient parse")
        expect(packet.request == 6, "request parse")
        expect(packet.value == 0x0102, "value little-endian parse")
        expect(packet.index == 0x0409, "index little-endian parse")
        expect(packet.length == 64, "length little-endian parse")
        expect(packet.valueLow == 2 && packet.valueHigh == 1, "value halves")
        expect(packet.indexLow == 9 && packet.indexHigh == 4, "index halves")
        expect(packet.requestType.rawValue == 0x81, "request type round trip")

        [UInt8](repeating: 0, count: 7).withUnsafeBytes { bytes in
            expect(USBSetupPacket.parse(bytes) == nil, "short SETUP accepted")
        }
        var reservedKind = [UInt8](repeating: 0, count: 8)
        reservedKind[0] = 0x60
        reservedKind.withUnsafeBytes { bytes in
            expect(USBSetupPacket.parse(bytes) == nil, "reserved kind accepted")
        }
        var reservedRecipient = [UInt8](repeating: 0, count: 8)
        reservedRecipient[0] = 0x04
        reservedRecipient.withUnsafeBytes { bytes in
            expect(
                USBSetupPacket.parse(bytes) == nil,
                "reserved recipient accepted"
            )
        }
    }

    private static func testDeviceAndQualifierDescriptors() {
        withBuffer(byteCount: 64) { output in
            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.device,
                    descriptorIndex: 0,
                    languageID: 0,
                    speed: .high,
                    requestedLength: 64,
                    to: output
                ) == .written(18),
                "device descriptor write"
            )
            expectBytes(
                output,
                [
                    18, 1, 0x00, 0x02, 0xef, 0x02, 0x01, 64,
                    0x09, 0x12, 0x17, 0x5a, 0x01, 0x00,
                    1, 2, 3, 1,
                ],
                "device descriptor"
            )

            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.deviceQualifier,
                    descriptorIndex: 0,
                    languageID: 0,
                    speed: .full,
                    requestedLength: 64,
                    to: output
                ) == .written(10),
                "qualifier descriptor write"
            )
            expectBytes(
                output,
                [10, 6, 0, 2, 0xef, 2, 1, 64, 1, 0],
                "device qualifier descriptor"
            )
        }
    }

    private static func testCompositeConfigurationDescriptors() {
        withBuffer(byteCount: 128) { output in
            writeConfiguration(.full, type: USBDescriptorType.configuration, output)
            expect(output[0] == 9 && output[1] == 2, "configuration header")
            expect(read16(output, 2) == 98, "configuration total length")
            expect(output[4] == 3 && output[5] == 1, "configuration identity")
            expect(output[7] == 0x80 && output[8] == 250, "power attributes")

            expectBytes(
                output,
                [8, 11, 0, 2, 2, 2, 1, 4],
                at: 9,
                "CDC interface association"
            )
            expectBytes(
                output,
                [9, 4, 0, 0, 1, 2, 2, 1, 4],
                at: 17,
                "CDC control interface"
            )
            expectBytes(
                output,
                [5, 0x24, 0, 0x20, 0x01],
                at: 26,
                "CDC header functional descriptor"
            )
            expectBytes(
                output,
                [5, 0x24, 1, 0, 1, 4, 0x24, 2, 6],
                at: 31,
                "CDC call management and ACM descriptors"
            )
            expectBytes(
                output,
                [5, 0x24, 6, 0, 1],
                at: 40,
                "CDC union descriptor"
            )
            expectBytes(
                output,
                [7, 5, 0x81, 3, 16, 0, 16],
                at: 45,
                "CDC notification endpoint"
            )
            expectBytes(
                output,
                [9, 4, 1, 0, 2, 0x0a, 0, 0, 4],
                at: 52,
                "CDC data interface"
            )
            expectEndpoint(output, at: 61, address: 0x02, packetSize: 64)
            expectEndpoint(output, at: 68, address: 0x82, packetSize: 64)
            expectBytes(
                output,
                [9, 4, 2, 0, 2, 0xff, 0x42, 1, 5],
                at: 75,
                "debug-display interface"
            )
            expectEndpoint(output, at: 84, address: 0x03, packetSize: 64)
            expectEndpoint(output, at: 91, address: 0x83, packetSize: 64)
            validateDescriptorWalk(output, byteCount: 98)

            writeConfiguration(.high, type: USBDescriptorType.configuration, output)
            expect(read16(output, 65) == 512, "high-speed CDC OUT packet")
            expect(read16(output, 72) == 512, "high-speed CDC IN packet")
            expect(read16(output, 88) == 512, "high-speed debug OUT packet")
            expect(read16(output, 95) == 512, "high-speed debug IN packet")
            expect(output[51] == 8, "high-speed interrupt interval")

            writeConfiguration(
                .high,
                type: USBDescriptorType.otherSpeedConfiguration,
                output
            )
            expect(output[1] == 7, "other-speed descriptor type")
            expect(read16(output, 65) == 64, "other-speed used full-speed MPS")
        }
    }

    private static func testStringAndBoundedDescriptorReplies() {
        withBuffer(byteCount: 64, fill: 0xa5) { output in
            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.string,
                    descriptorIndex: 0,
                    languageID: 0,
                    speed: .full,
                    requestedLength: 255,
                    to: output
                ) == .written(4),
                "language descriptor write"
            )
            expectBytes(output, [4, 3, 9, 4], "language descriptor")

            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.string,
                    descriptorIndex: 1,
                    languageID: 0x0409,
                    speed: .full,
                    requestedLength: 255,
                    to: output
                ) == .written(16),
                "manufacturer string write"
            )
            expect(output[0] == 16 && output[1] == 3, "string header")
            expectUTF16ASCII(output, "SwiftOS", at: 2)

            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.string,
                    descriptorIndex: 5,
                    languageID: 0x0409,
                    speed: .full,
                    requestedLength: 8,
                    to: output
                ) == .written(8),
                "host-length string truncation"
            )
            expect(output[0] == 44 && output[1] == 3, "full string length retained")
            expectUTF16ASCII(output, "Swi", at: 2)
        }

        withBuffer(byteCount: 8, fill: 0x6d) { output in
            expect(
                USBDebugDescriptorSet.write(
                    descriptorType: USBDescriptorType.device,
                    descriptorIndex: 0,
                    languageID: 0,
                    speed: .full,
                    requestedLength: 18,
                    to: output
                ) == .bufferTooSmall(requiredByteCount: 18),
                "short staging buffer was not reported"
            )
            var index = 0
            while index < output.count {
                expect(output[index] == 0x6d, "short buffer was modified")
                index += 1
            }
        }
    }

    private static func testDeferredAddressAndConfigurationState() {
        var endpoint = USBControlEndpoint(speed: .high)
        withBuffer(byteCount: 128) { reply in
            expect(endpoint.state == .default && endpoint.address == 0, "reset state")
            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 8, length: 1),
                    reply: reply
                ) == .stall(.invalidState),
                "GET_CONFIGURATION accepted in default state"
            )

            let setAddress = setup(type: 0x00, request: 5, value: 7)
            expect(endpoint.handle(setAddress, reply: reply) == .statusIn, "SET_ADDRESS")
            expect(
                endpoint.state == .default && endpoint.address == 0,
                "address took effect before status stage"
            )
            expect(
                endpoint.completeStatusStage(succeeded: false) == .none,
                "failed status committed address"
            )
            expect(endpoint.state == .default && endpoint.address == 0, "failed address state")

            expect(endpoint.handle(setAddress, reply: reply) == .statusIn, "SET_ADDRESS retry")
            expect(
                endpoint.completeStatusStage(succeeded: true) == .deviceAddress(7),
                "address commit"
            )
            expect(endpoint.state == .addressed && endpoint.address == 7, "addressed state")

            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 8, length: 1),
                    reply: reply
                ) == .dataIn(byteCount: 1),
                "GET_CONFIGURATION addressed"
            )
            expect(reply[0] == 0, "addressed configuration value")
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 3, value: 1),
                    reply: reply
                ) == .stall(.unsupportedFeature),
                "addressed remote-wakeup claim"
            )
            expect(!endpoint.remoteWakeupEnabled, "addressed remote-wakeup state")
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 1, value: 1),
                    reply: reply
                ) == .stall(.unsupportedFeature),
                "addressed remote-wakeup clear claim"
            )

            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 9, value: 1),
                    reply: reply
                ) == .statusIn,
                "SET_CONFIGURATION one"
            )
            expect(
                endpoint.state == .configured && endpoint.configurationValue == 1,
                "configured state"
            )
            expect(
                endpoint.handle(setAddress, reply: reply) == .stall(.invalidState),
                "SET_ADDRESS accepted while configured"
            )

            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 9, value: 0),
                    reply: reply
                ) == .statusIn,
                "deconfigure"
            )
            expect(endpoint.state == .addressed, "deconfigure state")

            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 5, value: 0),
                    reply: reply
                ) == .statusIn,
                "return to address zero"
            )
            expect(
                endpoint.completeStatusStage(succeeded: true) == .deviceAddress(0),
                "zero address commit"
            )
            expect(endpoint.state == .default && endpoint.address == 0, "default transition")
        }
    }

    private static func testStatusAndFeatureHandling() {
        var endpoint = configuredEndpoint()
        withBuffer(byteCount: 16) { reply in
            expect(
                endpoint.handle(
                    setup(type: 0x02, request: 3, index: 0x83),
                    reply: reply
                ) == .statusIn,
                "precondition debug endpoint halt"
            )
            expect(endpoint.isEndpointHalted(0x83), "precondition halt state")
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 3, value: 1),
                    reply: reply
                ) == .stall(.unsupportedFeature),
                "SET_FEATURE remote wakeup"
            )
            expect(!endpoint.remoteWakeupEnabled, "remote wakeup feature state")
            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 0, length: 2),
                    reply: reply
                ) == .dataIn(byteCount: 2),
                "device GET_STATUS"
            )
            expect(reply[0] == 0 && reply[1] == 0, "device status bits")
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 1, value: 1),
                    reply: reply
                ) == .stall(.unsupportedFeature),
                "CLEAR_FEATURE remote wakeup"
            )

            let endpointAddress = UInt16(
                USBDebugDeviceIdentity.debugDisplayInEndpoint
            )
            expect(
                endpoint.handle(
                    setup(type: 0x02, request: 3, index: endpointAddress),
                    reply: reply
                ) == .statusIn,
                "SET_FEATURE endpoint halt"
            )
            expect(
                endpoint.isEndpointHalted(UInt8(endpointAddress)),
                "endpoint halt state"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x82, request: 0, index: endpointAddress, length: 2),
                    reply: reply
                ) == .dataIn(byteCount: 2),
                "endpoint GET_STATUS"
            )
            expect(reply[0] == 1 && reply[1] == 0, "endpoint halt status")
            expect(
                endpoint.handle(
                    setup(type: 0x02, request: 1, index: endpointAddress),
                    reply: reply
                ) == .statusIn,
                "CLEAR_FEATURE endpoint halt"
            )
            expect(!endpoint.isEndpointHalted(UInt8(endpointAddress)), "halt clear")

            expect(
                endpoint.handle(
                    setup(type: 0x81, request: 0, index: 2, length: 2),
                    reply: reply
                ) == .dataIn(byteCount: 2),
                "interface GET_STATUS"
            )
            expect(reply[0] == 0 && reply[1] == 0, "interface status zero")
        }
    }

    private static func testInterfaceAndCDCControlRequests() {
        var endpoint = configuredEndpoint()
        withBuffer(byteCount: 16) { reply in
            expect(
                endpoint.handle(
                    setup(type: 0x81, request: 10, index: 2, length: 1),
                    reply: reply
                ) == .dataIn(byteCount: 1),
                "GET_INTERFACE"
            )
            expect(reply[0] == 0, "alternate setting")
            expect(
                endpoint.handle(
                    setup(type: 0x01, request: 11, value: 0, index: 2),
                    reply: reply
                ) == .statusIn,
                "SET_INTERFACE zero"
            )
            expect(
                !endpoint.isEndpointHalted(0x83),
                "SET_INTERFACE did not reset interface halt state"
            )

            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x20, index: 0, length: 7),
                    reply: reply
                ) == .dataOut(expectedByteCount: 7),
                "CDC SET_LINE_CODING setup"
            )
            let lineBytes: [UInt8] = [0x00, 0x10, 0x0e, 0x00, 0, 0, 8]
            lineBytes.withUnsafeBytes { bytes in
                expect(
                    endpoint.acceptDataOut(bytes) == .statusIn,
                    "CDC SET_LINE_CODING data"
                )
            }
            expect(
                endpoint.lineCoding == USBLineCoding(
                    dataRate: 921_600,
                    stopBits: 0,
                    parity: 0,
                    dataBits: 8
                ),
                "line coding state"
            )
            expect(
                endpoint.handle(
                    setup(type: 0xa1, request: 0x21, index: 0, length: 7),
                    reply: reply
                ) == .dataIn(byteCount: 7),
                "CDC GET_LINE_CODING"
            )
            expectBytes(reply, lineBytes, "line coding reply")

            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x22, value: 3, index: 0),
                    reply: reply
                ) == .statusIn,
                "CDC SET_CONTROL_LINE_STATE"
            )
            expect(endpoint.controlLineState == 3, "DTR and RTS state")
            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x23, value: 250, index: 0),
                    reply: reply
                ) == .statusIn,
                "CDC SEND_BREAK"
            )
            expect(endpoint.breakDuration == 250, "break duration")
        }
    }

    private static func testPreciseRejectionsAndReset() {
        var endpoint = configuredEndpoint()
        withBuffer(byteCount: 128) { reply in
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 6, value: 0x0100, length: 18),
                    reply: reply
                ) == .stall(.invalidDirection),
                "wrong GET_DESCRIPTOR direction"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 6, value: 0x9900, length: 8),
                    reply: reply
                ) == .stall(.unknownDescriptor),
                "unknown descriptor"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 6, value: 0x0301, index: 0x0411, length: 16),
                    reply: reply
                ) == .stall(.unknownDescriptor),
                "unknown string language"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 9, value: 2),
                    reply: reply
                ) == .stall(.invalidValue),
                "unknown configuration"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x81, request: 10, index: 3, length: 1),
                    reply: reply
                ) == .stall(.unknownInterface),
                "unknown interface"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x82, request: 0, index: 0x84, length: 2),
                    reply: reply
                ) == .stall(.unknownEndpoint),
                "unknown endpoint"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x02, request: 3, value: 1, index: 0x83),
                    reply: reply
                ) == .stall(.unsupportedFeature),
                "unknown endpoint feature"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x22, value: 4, index: 0),
                    reply: reply
                ) == .stall(.invalidValue),
                "unsupported control-line bit"
            )

            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x20, index: 0, length: 7),
                    reply: reply
                ) == .dataOut(expectedByteCount: 7),
                "pending line setup"
            )
            _ = endpoint.handle(
                setup(type: 0x80, request: 8, length: 1),
                reply: reply
            )
            let lineBytes: [UInt8] = [0x00, 0xc2, 0x01, 0, 0, 0, 8]
            lineBytes.withUnsafeBytes { bytes in
                expect(
                    endpoint.acceptDataOut(bytes) == .stall(.unexpectedDataOut),
                    "new SETUP did not abort OUT data stage"
                )
            }

            let malformed: [UInt8] = [0, 0, 0, 0, 3, 5, 4]
            expect(
                endpoint.handle(
                    setup(type: 0x21, request: 0x20, index: 0, length: 7),
                    reply: reply
                ) == .dataOut(expectedByteCount: 7),
                "malformed line setup"
            )
            malformed.withUnsafeBytes { bytes in
                expect(
                    endpoint.acceptDataOut(bytes) == .stall(.malformedClassData),
                    "malformed line coding accepted"
                )
            }

            let shortReply = UnsafeMutableRawBufferPointer(start: reply.baseAddress, count: 8)
            expect(
                endpoint.handle(
                    setup(type: 0x80, request: 6, value: 0x0200, length: 98),
                    reply: shortReply
                ) == .replyBufferTooSmall(requiredByteCount: 98),
                "short EP0 staging result"
            )

            endpoint.busReset()
            expect(endpoint.state == .default, "bus reset state")
            expect(endpoint.address == 0 && endpoint.configurationValue == 0, "bus reset identity")
            expect(!endpoint.remoteWakeupEnabled, "bus reset wakeup")
            expect(endpoint.lineCoding == .consoleDefault, "bus reset line coding")
            expect(endpoint.controlLineState == 0, "bus reset control lines")
        }
    }

    private static func configuredEndpoint() -> USBControlEndpoint {
        var endpoint = USBControlEndpoint(speed: .high)
        withBuffer(byteCount: 16) { reply in
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 5, value: 5),
                    reply: reply
                ) == .statusIn,
                "test enumeration address setup"
            )
            expect(
                endpoint.completeStatusStage(succeeded: true) == .deviceAddress(5),
                "test enumeration address commit"
            )
            expect(
                endpoint.handle(
                    setup(type: 0x00, request: 9, value: 1),
                    reply: reply
                ) == .statusIn,
                "test enumeration configuration"
            )
        }
        return endpoint
    }

    private static func writeConfiguration(
        _ speed: USBDeviceSpeed,
        type: UInt8,
        _ output: UnsafeMutableRawBufferPointer
    ) {
        expect(
            USBDebugDescriptorSet.write(
                descriptorType: type,
                descriptorIndex: 0,
                languageID: 0,
                speed: speed,
                requestedLength: 255,
                to: output
            ) == .written(98),
            "configuration descriptor write"
        )
    }

    private static func validateDescriptorWalk(
        _ output: UnsafeMutableRawBufferPointer,
        byteCount: Int
    ) {
        var offset = 0
        var descriptors = 0
        while offset < byteCount {
            let length = Int(output[offset])
            expect(length >= 2, "zero/short descriptor in graph")
            expect(offset + length <= byteCount, "descriptor exceeds total length")
            offset += length
            descriptors += 1
        }
        expect(offset == byteCount, "descriptor graph did not end at total length")
        expect(descriptors == 14, "descriptor count")
    }

    private static func expectEndpoint(
        _ output: UnsafeMutableRawBufferPointer,
        at offset: Int,
        address: UInt8,
        packetSize: UInt16
    ) {
        expect(output[offset] == 7, "endpoint length")
        expect(output[offset + 1] == 5, "endpoint type")
        expect(output[offset + 2] == address, "endpoint address")
        expect(output[offset + 3] == 2, "bulk endpoint attributes")
        expect(read16(output, offset + 4) == packetSize, "endpoint packet size")
        expect(output[offset + 6] == 0, "bulk endpoint interval")
    }

    private static func setup(
        type: UInt8,
        request: UInt8,
        value: UInt16 = 0,
        index: UInt16 = 0,
        length: UInt16 = 0
    ) -> USBSetupPacket {
        parseSetup([
            type,
            request,
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: index),
            UInt8(truncatingIfNeeded: index >> 8),
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
        ])
    }

    private static func parseSetup(_ bytes: [UInt8]) -> USBSetupPacket {
        bytes.withUnsafeBytes { raw in
            guard let packet = USBSetupPacket.parse(raw) else {
                fail("valid SETUP packet rejected")
            }
            return packet
        }
    }

    private static func withBuffer(
        byteCount: Int,
        fill: UInt8 = 0,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 16
        )
        let buffer = UnsafeMutableRawBufferPointer(start: pointer, count: byteCount)
        var index = 0
        while index < byteCount {
            buffer[index] = fill
            index += 1
        }
        body(buffer)
        pointer.deallocate()
    }

    private static func read16(
        _ bytes: UnsafeMutableRawBufferPointer,
        _ offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func expectBytes(
        _ actual: UnsafeMutableRawBufferPointer,
        _ expected: [UInt8],
        at offset: Int = 0,
        _ context: StaticString
    ) {
        var index = 0
        while index < expected.count {
            if actual[offset + index] != expected[index] { fail(context) }
            index += 1
        }
    }

    private static func expectUTF16ASCII(
        _ actual: UnsafeMutableRawBufferPointer,
        _ expected: StaticString,
        at offset: Int
    ) {
        var index = 0
        while index < expected.utf8CodeUnitCount {
            expect(
                actual[offset + index * 2] == expected.utf8Start[index]
                    && actual[offset + index * 2 + 1] == 0,
                "UTF-16LE string payload"
            )
            index += 1
        }
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
