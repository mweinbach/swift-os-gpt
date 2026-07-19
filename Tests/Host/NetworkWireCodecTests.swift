@main
struct NetworkWireCodecTests {
    static func main() {
        validatesAddressAndChecksumPrimitives()
        roundTripsEthernetIIFrames()
        validatesARPEthernetIPv4Packets()
        validatesIPv4HeadersAndPackets()
        validatesUDPChecksumsAndLengths()
        validatesICMPEchoMessages()
        composesACompleteEthernetIPv4UDPFrame()
        rejectsInvalidBoundsBeforeAccess()
        print("network wire codecs: 8 groups passed")
    }

    private static func validatesAddressAndChecksumPrimitives() {
        let mac = MACAddress(0x02, 0x10, 0x20, 0x30, 0x40, 0x50)
        expect(mac.isUnicast, "locally administered MAC was not unicast")
        expect(!mac.isMulticast && !mac.isBroadcast, "unicast MAC flags")
        expect(MACAddress.broadcast.isBroadcast, "broadcast MAC flag")
        expect(MACAddress.broadcast.isMulticast, "broadcast group bit")
        expect(!MACAddress.zero.isUnicast, "zero MAC was accepted as unicast")

        var macBytes = [UInt8](repeating: 0, count: 6)
        let wroteMAC = macBytes.withUnsafeMutableBytes {
            mac.encode(to: $0, at: 0)
        }
        expect(wroteMAC, "MAC encode failed")
        expect(
            macBytes == [0x02, 0x10, 0x20, 0x30, 0x40, 0x50],
            "MAC wire order changed"
        )
        let decodedMAC = macBytes.withUnsafeBytes {
            MACAddress.decode(from: $0, at: 0)
        }
        expect(decodedMAC == mac, "MAC round trip failed")

        let address = IPv4Address(192, 168, 4, 17)
        expect(address.rawValue == 0xc0a8_0411, "IPv4 canonical value")
        expect(
            address.octet0 == 192 && address.octet3 == 17,
            "IPv4 octet projection"
        )
        expect(IPv4Address(224, 0, 0, 1).isMulticast, "IPv4 multicast")
        expect(
            IPv4Address.limitedBroadcast.isLimitedBroadcast,
            "IPv4 limited broadcast"
        )

        let checksumVector: [UInt8] = [
            0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7,
        ]
        let checksum = checksumVector.withUnsafeBytes {
            InternetChecksum.compute($0)
        }
        expect(checksum == 0x220d, "RFC 1071 checksum vector")
        checksumVector.withUnsafeBytes { bytes in
            guard let first = NetworkWire.view(bytes, offset: 0, count: 3),
                  let second = NetworkWire.view(bytes, offset: 3, count: 5)
            else {
                fail("checksum vector slicing failed")
            }
            var segmented = InternetChecksumAccumulator()
            expect(segmented.update(first), "first checksum segment rejected")
            expect(segmented.update(second), "second checksum segment rejected")
            expect(
                segmented.value == 0x220d,
                "odd checksum segment boundary changed the result"
            )
        }
    }

    private static func roundTripsEthernetIIFrames() {
        let destination = MACAddress.broadcast
        let source = MACAddress(0x02, 0, 0, 0, 0, 1)
        let payload: [UInt8] = [1, 2, 3]
        var output = [UInt8](repeating: 0xaa, count: 60)
        let result = output.withUnsafeMutableBytes { destinationBytes in
            payload.withUnsafeBytes { payloadBytes in
                EthernetIIFrameEncoder.encode(
                    destination: destination,
                    source: source,
                    etherType: .arp,
                    payload: payloadBytes,
                    into: destinationBytes
                )
            }
        }
        expect(result == .encoded(byteCount: 60), "short Ethernet encode")
        expect(
            Array(output[0..<6]) == [UInt8](repeating: 0xff, count: 6),
            "Ethernet destination layout"
        )
        expect(Array(output[6..<12]) == [0x02, 0, 0, 0, 0, 1],
               "Ethernet source layout")
        expect(output[12] == 0x08 && output[13] == 0x06,
               "EtherType byte order")
        expect(Array(output[14..<17]) == payload, "Ethernet payload copy")
        expect(
            output[17..<60].allSatisfy { $0 == 0 },
            "Ethernet minimum-frame padding was not cleared"
        )

        output.withUnsafeBytes { bytes in
            guard case .decoded(let frame) = EthernetIIFrameDecoder.decode(bytes)
            else {
                fail("valid Ethernet II frame rejected")
            }
            expect(frame.destination == destination, "decoded destination")
            expect(frame.source == source, "decoded source")
            expect(frame.etherType == .arp, "decoded EtherType")
            expect(frame.payload.count == 46, "Ethernet padding view length")
            expect(
                frame.payload[0] == 1 && frame.payload[2] == 3,
                "decoded Ethernet payload"
            )
        }

        var lengthFrame = output
        lengthFrame[12] = 0x05
        lengthFrame[13] = 0xdc
        lengthFrame.withUnsafeBytes {
            guard case .rejected(.notEthernetII(typeOrLength: 1_500)) =
                    EthernetIIFrameDecoder.decode($0)
            else {
                fail("IEEE 802.3 length field accepted as EtherType")
            }
        }
        let shortFrame = [UInt8](repeating: 0, count: 13)
        shortFrame.withUnsafeBytes {
            guard case .rejected(.frameTooShort(minimum: 14, available: 13)) =
                    EthernetIIFrameDecoder.decode($0)
            else { fail("short Ethernet frame accepted") }
        }
        let oversizedFrame = [UInt8](repeating: 0, count: 1_515)
        oversizedFrame.withUnsafeBytes {
            guard case .rejected(.frameTooLarge(maximum: 1_514, available: 1_515)) =
                    EthernetIIFrameDecoder.decode($0)
            else { fail("oversized non-VLAN Ethernet frame accepted") }
        }
        let oversizedPayload = [UInt8](repeating: 0, count: 1_501)
        var largeOutput = [UInt8](repeating: 0, count: 1_515)
        let oversizedResult = largeOutput.withUnsafeMutableBytes { outputBytes in
            oversizedPayload.withUnsafeBytes {
                EthernetIIFrameEncoder.encode(
                    destination: destination,
                    source: source,
                    etherType: .ipv4,
                    payload: $0,
                    into: outputBytes
                )
            }
        }
        expect(
            oversizedResult == .rejected(
                .payloadTooLarge(requested: 1_501, maximum: 1_500)
            ),
            "oversized Ethernet payload encoded"
        )
        expect(EtherType(rawValue: 0x05ff) == nil, "reserved EtherType gap")
    }

    private static func validatesARPEthernetIPv4Packets() {
        let packet = ARPEthernetIPv4Packet(
            operation: .request,
            senderHardwareAddress: MACAddress(0x02, 0, 0, 0, 0, 1),
            senderProtocolAddress: IPv4Address(192, 168, 4, 10),
            targetHardwareAddress: .zero,
            targetProtocolAddress: IPv4Address(192, 168, 4, 1)
        )
        let expected: [UInt8] = [
            0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
            0xc0, 0xa8, 0x04, 0x0a,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xc0, 0xa8, 0x04, 0x01,
        ]
        var encoded = [UInt8](repeating: 0, count: 28)
        let result = encoded.withUnsafeMutableBytes {
            ARPEthernetIPv4Encoder.encode(packet, into: $0)
        }
        expect(result == .encoded(byteCount: 28), "ARP encode failed")
        expect(encoded == expected, "ARP Ethernet/IPv4 wire layout")

        var padded = encoded + [UInt8](repeating: 0, count: 18)
        padded.withUnsafeBytes {
            guard case .decoded(let decoded) =
                    ARPEthernetIPv4Decoder.decode($0)
            else { fail("valid padded ARP packet rejected") }
            expect(decoded == packet, "ARP packet round trip")
        }
        padded[4] = 5
        padded.withUnsafeBytes {
            guard case .rejected(.invalidHardwareAddressLength(5)) =
                    ARPEthernetIPv4Decoder.decode($0)
            else { fail("wrong ARP hardware length accepted") }
        }
        var unsupportedOperation = encoded
        unsupportedOperation[6] = 0
        unsupportedOperation[7] = 3
        unsupportedOperation.withUnsafeBytes {
            guard case .rejected(.unsupportedOperation(3)) =
                    ARPEthernetIPv4Decoder.decode($0)
            else { fail("unsupported ARP operation accepted") }
        }
        var tiny = [UInt8](repeating: 0, count: 27)
        let tinyEncode = tiny.withUnsafeMutableBytes {
            ARPEthernetIPv4Encoder.encode(packet, into: $0)
        }
        expect(
            tinyEncode == .rejected(
                .outputBufferTooSmall(required: 28, available: 27)
            ),
            "ARP encoded into short buffer"
        )
    }

    private static func validatesIPv4HeadersAndPackets() {
        let header = IPv4Header(
            differentiatedServicesAndECN: 0,
            identification: 0,
            dontFragment: true,
            timeToLive: 64,
            protocolNumber: IPv4Protocol.udp,
            source: IPv4Address(192, 168, 0, 1),
            destination: IPv4Address(192, 168, 0, 199)
        )
        let expectedHeader: [UInt8] = [
            0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00,
            0x40, 0x11, 0xb8, 0x61, 0xc0, 0xa8, 0x00, 0x01,
            0xc0, 0xa8, 0x00, 0xc7,
        ]
        var encoded = [UInt8](repeating: 0, count: 20)
        let result = encoded.withUnsafeMutableBytes {
            IPv4HeaderEncoder.encode(header, payloadByteCount: 95, into: $0)
        }
        expect(
            result == .encoded(headerByteCount: 20, totalByteCount: 115),
            "IPv4 header encode result"
        )
        expect(encoded == expectedHeader, "IPv4 checksum reference vector")

        var completePacket = encoded + [UInt8](repeating: 0x5a, count: 95)
        completePacket += [UInt8](repeating: 0, count: 5)
        completePacket.withUnsafeBytes {
            guard case .decoded(let packet) = IPv4Decoder.decode($0) else {
                fail("valid IPv4 packet rejected")
            }
            expect(packet.header == header, "IPv4 semantic header round trip")
            expect(packet.totalByteCount == 115, "IPv4 declared total length")
            expect(packet.payload.count == 95, "IPv4 excluded link padding")
            expect(packet.payload[0] == 0x5a, "IPv4 payload view")
        }

        var options = completePacket
        options[0] = 0x46
        options.withUnsafeBytes {
            guard case .rejected(.unsupportedOptions(headerWordCount: 6)) =
                    IPv4Decoder.decode($0)
            else { fail("IPv4 options accepted") }
        }
        var fragment = completePacket
        fragment[6] = 0x20
        fragment[7] = 0
        refreshIPv4Checksum(&fragment)
        fragment.withUnsafeBytes {
            guard case .rejected(.fragmentedPacket) = IPv4Decoder.decode($0)
            else { fail("fragmented IPv4 packet accepted") }
        }
        var corrupted = completePacket
        corrupted[8] ^= 1
        corrupted.withUnsafeBytes {
            guard case .rejected(.invalidHeaderChecksum) = IPv4Decoder.decode($0)
            else { fail("bad IPv4 header checksum accepted") }
        }
        expectedHeader.withUnsafeBytes {
            guard case .rejected(.truncatedPacket(declared: 115, available: 20)) =
                    IPv4Decoder.decode($0)
            else { fail("truncated IPv4 packet accepted") }
        }
        let maximumRejection = encoded.withUnsafeMutableBytes {
            IPv4HeaderEncoder.encode(
                header,
                payloadByteCount: IPv4Protocol.maximumPayloadByteCount + 1,
                into: $0
            )
        }
        expect(
            maximumRejection == .rejected(
                .invalidPayloadByteCount(
                    requested: IPv4Protocol.maximumPayloadByteCount + 1,
                    maximum: IPv4Protocol.maximumPayloadByteCount
                )
            ),
            "oversized IPv4 payload encoded"
        )
    }

    private static func validatesUDPChecksumsAndLengths() {
        let source = IPv4Address(192, 168, 0, 1)
        let destination = IPv4Address(192, 168, 0, 199)
        let payload = Array("swiftos".utf8)
        let expected: [UInt8] = [
            0x30, 0x39, 0x00, 0x35, 0x00, 0x0f, 0x88, 0xfb,
            0x73, 0x77, 0x69, 0x66, 0x74, 0x6f, 0x73,
        ]
        var encoded = [UInt8](repeating: 0, count: expected.count)
        let result = encoded.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: source,
                    destinationAddress: destination,
                    sourcePort: 12_345,
                    destinationPort: 53,
                    payload: $0,
                    includeChecksum: true,
                    into: output
                )
            }
        }
        expect(
            result == .encoded(byteCount: 15, checksum: 0x88fb),
            "UDP encode result"
        )
        expect(encoded == expected, "UDP IPv4 checksum reference vector")
        encoded.withUnsafeBytes {
            guard case .decoded(let datagram) = UDPDecoder.decode(
                      $0,
                      sourceAddress: source,
                      destinationAddress: destination
                  )
            else { fail("valid UDP datagram rejected") }
            expect(datagram.sourcePort == 12_345, "UDP source port")
            expect(datagram.destinationPort == 53, "UDP destination port")
            expect(datagram.checksumDisposition == .verified,
                   "UDP checksum was not verified")
            expect(Array(datagram.payload) == payload, "UDP payload round trip")
        }

        var corrupted = encoded
        corrupted[14] ^= 1
        corrupted.withUnsafeBytes {
            guard case .rejected(.invalidChecksum) = UDPDecoder.decode(
                      $0,
                      sourceAddress: source,
                      destinationAddress: destination
                  )
            else { fail("bad UDP checksum accepted") }
        }

        var omitted = [UInt8](repeating: 0, count: expected.count)
        let omittedResult = omitted.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: source,
                    destinationAddress: destination,
                    sourcePort: 12_345,
                    destinationPort: 53,
                    payload: $0,
                    includeChecksum: false,
                    into: output
                )
            }
        }
        expect(
            omittedResult == .encoded(byteCount: 15, checksum: 0),
            "zero-checksum UDP encode"
        )
        omitted.withUnsafeBytes {
            guard case .decoded(let datagram) = UDPDecoder.decode(
                      $0,
                      sourceAddress: source,
                      destinationAddress: destination
                  )
            else { fail("IPv4 UDP zero checksum rejected") }
            expect(datagram.checksumDisposition == .omitted,
                   "zero checksum semantics lost")
        }

        let zeroChecksumPayload: [UInt8] = [0x4d, 0x53]
        var encodedZero = [UInt8](repeating: 0, count: 10)
        let encodedZeroResult = encodedZero.withUnsafeMutableBytes { output in
            zeroChecksumPayload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: source,
                    destinationAddress: destination,
                    sourcePort: 12_345,
                    destinationPort: 53,
                    payload: $0,
                    includeChecksum: true,
                    into: output
                )
            }
        }
        expect(
            encodedZeroResult == .encoded(byteCount: 10, checksum: 0xffff),
            "computed zero UDP checksum was not sent as all ones"
        )
        encodedZero.withUnsafeBytes {
            guard case .decoded(let datagram) = UDPDecoder.decode(
                      $0,
                      sourceAddress: source,
                      destinationAddress: destination
                  ), datagram.checksumDisposition == .verified
            else { fail("all-ones UDP checksum did not verify") }
        }

        var trailing = encoded + [0]
        trailing.withUnsafeBytes {
            guard case .rejected(.trailingBytes(declared: 15, available: 16)) =
                    UDPDecoder.decode(
                        $0,
                        sourceAddress: source,
                        destinationAddress: destination
                    )
            else { fail("UDP trailing bytes accepted") }
        }
        trailing[4] = 0
        trailing[5] = 17
        trailing.withUnsafeBytes {
            guard case .rejected(.truncatedDatagram(declared: 17, available: 16)) =
                    UDPDecoder.decode(
                        $0,
                        sourceAddress: source,
                        destinationAddress: destination
                    )
            else { fail("truncated UDP datagram accepted") }
        }
    }

    private static func validatesICMPEchoMessages() {
        let empty = [UInt8]()
        var reference = [UInt8](repeating: 0, count: 8)
        let referenceResult = reference.withUnsafeMutableBytes { output in
            empty.withUnsafeBytes {
                ICMPEchoEncoder.encode(
                    type: .request,
                    identifier: 0,
                    sequenceNumber: 0,
                    payload: $0,
                    into: output
                )
            }
        }
        expect(
            referenceResult == .encoded(byteCount: 8, checksum: 0xf7ff),
            "ICMP echo checksum reference result"
        )
        expect(
            reference == [0x08, 0x00, 0xf7, 0xff, 0, 0, 0, 0],
            "ICMP echo checksum reference vector"
        )

        let payload = Array("ping".utf8)
        var encoded = [UInt8](repeating: 0, count: 12)
        _ = encoded.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes {
                ICMPEchoEncoder.encode(
                    type: .reply,
                    identifier: 0x1234,
                    sequenceNumber: 7,
                    payload: $0,
                    into: output
                )
            }
        }
        encoded.withUnsafeBytes {
            guard case .decoded(let message) = ICMPEchoDecoder.decode($0) else {
                fail("valid ICMP echo reply rejected")
            }
            expect(message.type == .reply, "ICMP echo type")
            expect(message.identifier == 0x1234, "ICMP echo identifier")
            expect(message.sequenceNumber == 7, "ICMP echo sequence")
            expect(Array(message.payload) == payload, "ICMP echo payload")
        }
        var corrupted = encoded
        corrupted[11] ^= 1
        corrupted.withUnsafeBytes {
            guard case .rejected(.invalidChecksum) = ICMPEchoDecoder.decode($0)
            else { fail("bad ICMP echo checksum accepted") }
        }
        var wrongType = encoded
        wrongType[0] = 3
        wrongType.withUnsafeBytes {
            guard case .rejected(.unsupportedType(3)) = ICMPEchoDecoder.decode($0)
            else { fail("non-echo ICMP type accepted") }
        }
        var wrongCode = encoded
        wrongCode[1] = 1
        wrongCode.withUnsafeBytes {
            guard case .rejected(.nonzeroCode(1)) = ICMPEchoDecoder.decode($0)
            else { fail("nonzero ICMP echo code accepted") }
        }
        let short = [UInt8](repeating: 0, count: 7)
        short.withUnsafeBytes {
            guard case .rejected(.insufficientBytes(required: 8, available: 7)) =
                    ICMPEchoDecoder.decode($0)
            else { fail("short ICMP echo message accepted") }
        }
    }

    private static func composesACompleteEthernetIPv4UDPFrame() {
        let sourceMAC = MACAddress(0x02, 0, 0, 0, 0, 1)
        let destinationMAC = MACAddress(0x02, 0, 0, 0, 0, 2)
        let sourceIP = IPv4Address(192, 168, 4, 10)
        let destinationIP = IPv4Address(192, 168, 4, 20)
        let applicationPayload: [UInt8] = [0x53, 0x44, 0x42, 0x47, 1, 0]

        var udpBytes = [UInt8](repeating: 0, count: 14)
        let udpResult = udpBytes.withUnsafeMutableBytes { output in
            applicationPayload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: sourceIP,
                    destinationAddress: destinationIP,
                    sourcePort: 47_777,
                    destinationPort: 47_777,
                    payload: $0,
                    includeChecksum: true,
                    into: output
                )
            }
        }
        guard case .encoded(let udpByteCount, _) = udpResult else {
            fail("composed UDP encode failed")
        }

        var ipv4Bytes = [UInt8](repeating: 0, count: 20 + udpByteCount)
        var copyIndex = 0
        while copyIndex < udpByteCount {
            ipv4Bytes[20 + copyIndex] = udpBytes[copyIndex]
            copyIndex += 1
        }
        let ipv4Header = IPv4Header(
            differentiatedServicesAndECN: 0,
            identification: 1,
            dontFragment: true,
            timeToLive: 64,
            protocolNumber: IPv4Protocol.udp,
            source: sourceIP,
            destination: destinationIP
        )
        let ipv4Result = ipv4Bytes.withUnsafeMutableBytes {
            IPv4HeaderEncoder.encode(
                ipv4Header,
                payloadByteCount: udpByteCount,
                into: $0
            )
        }
        guard case .encoded(_, let ipv4ByteCount) = ipv4Result else {
            fail("composed IPv4 encode failed")
        }

        var ethernetBytes = [UInt8](repeating: 0, count: 60)
        let ethernetResult = ethernetBytes.withUnsafeMutableBytes { output in
            ipv4Bytes.withUnsafeBytes {
                EthernetIIFrameEncoder.encode(
                    destination: destinationMAC,
                    source: sourceMAC,
                    etherType: .ipv4,
                    payload: $0,
                    into: output
                )
            }
        }
        expect(
            ethernetResult == .encoded(byteCount: 60),
            "composed Ethernet encode"
        )

        ethernetBytes.withUnsafeBytes { ethernetInput in
            guard case .decoded(let ethernet) =
                    EthernetIIFrameDecoder.decode(ethernetInput),
                  ethernet.etherType == .ipv4,
                  case .decoded(let ipv4) = IPv4Decoder.decode(ethernet.payload),
                  ipv4.totalByteCount == ipv4ByteCount,
                  ipv4.header.protocolNumber == IPv4Protocol.udp,
                  case .decoded(let udp) = UDPDecoder.decode(
                      ipv4.payload,
                      sourceAddress: ipv4.header.source,
                      destinationAddress: ipv4.header.destination
                  )
            else {
                fail("composed Ethernet/IPv4/UDP decode failed")
            }
            expect(udp.sourcePort == 47_777, "composed UDP source port")
            expect(udp.destinationPort == 47_777,
                   "composed UDP destination port")
            expect(Array(udp.payload) == applicationPayload,
                   "composed application payload")
            expect(udp.checksumDisposition == .verified,
                   "composed UDP checksum")
        }
    }

    private static func rejectsInvalidBoundsBeforeAccess() {
        let probe: [UInt8] = [1, 2, 3, 4]
        probe.withUnsafeBytes {
            expect(
                NetworkWire.readUInt16BE($0, at: -1) == nil,
                "negative wire offset accepted"
            )
            expect(
                NetworkWire.readUInt32BE($0, at: Int.max) == nil,
                "overflowing wire offset accepted"
            )
        }

        let sourceMAC = MACAddress(0x02, 0, 0, 0, 0, 1)
        let smallPayload: [UInt8] = [1, 2, 3, 4]
        var shortEthernet = [UInt8](repeating: 0, count: 59)
        let ethernetResult = shortEthernet.withUnsafeMutableBytes { output in
            smallPayload.withUnsafeBytes {
                EthernetIIFrameEncoder.encode(
                    destination: .broadcast,
                    source: sourceMAC,
                    etherType: .ipv4,
                    payload: $0,
                    into: output
                )
            }
        }
        expect(
            ethernetResult == .rejected(
                .outputBufferTooSmall(required: 60, available: 59)
            ),
            "Ethernet encoder crossed a short output buffer"
        )

        let header = IPv4Header(
            differentiatedServicesAndECN: 0,
            identification: 0,
            dontFragment: true,
            timeToLive: 64,
            protocolNumber: IPv4Protocol.udp,
            source: IPv4Address(10, 0, 0, 1),
            destination: IPv4Address(10, 0, 0, 2)
        )
        var shortIPv4 = [UInt8](repeating: 0, count: 19)
        let ipv4Result = shortIPv4.withUnsafeMutableBytes {
            IPv4HeaderEncoder.encode(header, payloadByteCount: 0, into: $0)
        }
        expect(
            ipv4Result == .rejected(
                .outputBufferTooSmall(required: 20, available: 19)
            ),
            "IPv4 encoder crossed a short output buffer"
        )

        var shortUDP = [UInt8](repeating: 0, count: 11)
        let udpResult = shortUDP.withUnsafeMutableBytes { output in
            smallPayload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: header.source,
                    destinationAddress: header.destination,
                    sourcePort: 1,
                    destinationPort: 2,
                    payload: $0,
                    includeChecksum: true,
                    into: output
                )
            }
        }
        expect(
            udpResult == .rejected(
                .outputBufferTooSmall(required: 12, available: 11)
            ),
            "UDP encoder crossed a short output buffer"
        )
        let oversizedUDP = [UInt8](
            repeating: 0,
            count: UDPProtocol.maximumPayloadByteCount + 1
        )
        let udpOversizedResult = shortUDP.withUnsafeMutableBytes { output in
            oversizedUDP.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: header.source,
                    destinationAddress: header.destination,
                    sourcePort: 1,
                    destinationPort: 2,
                    payload: $0,
                    includeChecksum: true,
                    into: output
                )
            }
        }
        expect(
            udpOversizedResult == .rejected(
                .payloadTooLarge(
                    requested: UDPProtocol.maximumPayloadByteCount + 1,
                    maximum: UDPProtocol.maximumPayloadByteCount
                )
            ),
            "oversized UDP payload encoded"
        )

        var shortICMP = [UInt8](repeating: 0, count: 11)
        let icmpResult = shortICMP.withUnsafeMutableBytes { output in
            smallPayload.withUnsafeBytes {
                ICMPEchoEncoder.encode(
                    type: .request,
                    identifier: 1,
                    sequenceNumber: 1,
                    payload: $0,
                    into: output
                )
            }
        }
        expect(
            icmpResult == .rejected(
                .outputBufferTooSmall(required: 12, available: 11)
            ),
            "ICMP encoder crossed a short output buffer"
        )
        let oversizedICMP = [UInt8](
            repeating: 0,
            count: ICMPEchoProtocol.maximumPayloadByteCount + 1
        )
        let icmpOversizedResult = shortICMP.withUnsafeMutableBytes { output in
            oversizedICMP.withUnsafeBytes {
                ICMPEchoEncoder.encode(
                    type: .request,
                    identifier: 1,
                    sequenceNumber: 1,
                    payload: $0,
                    into: output
                )
            }
        }
        expect(
            icmpOversizedResult == .rejected(
                .payloadTooLarge(
                    requested: ICMPEchoProtocol.maximumPayloadByteCount + 1,
                    maximum: ICMPEchoProtocol.maximumPayloadByteCount
                )
            ),
            "oversized ICMP echo payload encoded"
        )

        let shortARP = [UInt8](repeating: 0, count: 27)
        shortARP.withUnsafeBytes {
            guard case .rejected(.insufficientBytes(required: 28, available: 27)) =
                    ARPEthernetIPv4Decoder.decode($0)
            else { fail("short ARP packet decoded") }
        }
        var invalidUDP = [UInt8](repeating: 0, count: 8)
        invalidUDP[4] = 0
        invalidUDP[5] = 7
        invalidUDP.withUnsafeBytes {
            guard case .rejected(.invalidLength(7)) = UDPDecoder.decode(
                      $0,
                      sourceAddress: header.source,
                      destinationAddress: header.destination
                  )
            else { fail("undersized UDP length decoded") }
        }
        let oversizedICMPMessage = [UInt8](
            repeating: 0,
            count: ICMPEchoProtocol.maximumMessageByteCount + 1
        )
        oversizedICMPMessage.withUnsafeBytes {
            guard case .rejected(
                .messageTooLarge(
                    maximum: ICMPEchoProtocol.maximumMessageByteCount,
                    available: ICMPEchoProtocol.maximumMessageByteCount + 1
                )
            ) = ICMPEchoDecoder.decode($0)
            else { fail("oversized ICMP echo message decoded") }
        }
    }

    private static func refreshIPv4Checksum(_ bytes: inout [UInt8]) {
        bytes[10] = 0
        bytes[11] = 0
        let checksum = bytes.withUnsafeBytes { input -> UInt16 in
            guard let header = NetworkWire.view(input, offset: 0, count: 20),
                  let value = InternetChecksum.compute(header)
            else {
                fail("could not recompute IPv4 test checksum")
            }
            return value
        }
        bytes[10] = UInt8(truncatingIfNeeded: checksum >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: checksum)
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
