@main
struct IPv4PollingStackTests {
    private static let localMAC = MACAddress(0x02, 0, 0, 0, 0, 0x10)
    private static let peerMAC = MACAddress(0x02, 0, 0, 0, 0, 0x20)
    private static let routerMAC = MACAddress(0x02, 0, 0, 0, 0, 0x01)
    private static let timing = IPv4PollingStackTiming(
        arpEntryLifetimeTicks: 1_000,
        arpProbeIntervalTicks: 20,
        dhcpRetryPolicy: DHCPv4RetryPolicy(
            initialRetryTicks: 10,
            maximumRetryTicks: 40
        )
    )

    static func main() {
        drivesDHCPDiscoverOfferRequestAndAck()
        validatesDHCPRetryDeadlinesAndOptions()
        resolvesARPAndComposesUDPFrames()
        answersARPRequestsAndBoundsTheCache()
        answersICMPEchoRequests()
        deliversInboundUDPAndRejectsInvalidBounds()
        print("IPv4 polling stack: 6 groups passed")
    }

    private static func drivesDHCPDiscoverOfferRequestAndAck() {
        let transaction: UInt32 = 0x1234_5678
        var stack = IPv4PollingStack(
            hardwareAddress: localMAC,
            dhcpTransactionIdentifier: transaction,
            timing: timing,
            startAtTicks: 100
        )
        var link = FakeNetworkLink(macAddress: localMAC)
        var receive = [UInt8](repeating: 0, count: 1_514)
        var transmit = [UInt8](repeating: 0, count: 1_514)

        expectIdle(
            poll(
                &stack,
                link: &link,
                nowTicks: 99,
                receive: &receive,
                transmit: &transmit
            ),
            "DHCP fired before its initial deadline"
        )
        let discoverEvent = poll(
            &stack,
            link: &link,
            nowTicks: 100,
            receive: &receive,
            transmit: &transmit
        )
        guard case .dhcpDiscoverSent = discoverEvent else {
            fail("initial poll did not send DHCPDISCOVER")
        }
        expectDHCPFrame(
            link.transmittedFrame,
            messageType: .discover,
            transactionIdentifier: transaction,
            requestedAddress: nil,
            serverIdentifier: nil
        )
        expect(
            stack.dhcpClient.nextRetryDeadlineTicks == 110,
            "discover retry deadline was not armed"
        )

        let offeredAddress = IPv4Address(192, 168, 50, 22)
        let serverAddress = IPv4Address(192, 168, 50, 1)
        let offerPayload = makeDHCPReply(
            messageType: .offer,
            transactionIdentifier: transaction,
            clientHardwareAddress: localMAC,
            offeredAddress: offeredAddress,
            serverIdentifier: serverAddress,
            subnetMask: IPv4Address(255, 255, 255, 0),
            router: serverAddress,
            domainNameServer: IPv4Address(1, 1, 1, 1),
            leaseDurationSeconds: 3_600
        )
        link.inboundFrame = makeUDPFrame(
            sourceHardwareAddress: routerMAC,
            destinationHardwareAddress: .broadcast,
            sourceAddress: serverAddress,
            destinationAddress: .limitedBroadcast,
            sourcePort: 67,
            destinationPort: 68,
            payload: offerPayload
        )
        let offerEvent = poll(
            &stack,
            link: &link,
            nowTicks: 105,
            receive: &receive,
            transmit: &transmit
        )
        guard case .dhcpRequestSent = offerEvent else {
            fail("DHCPOFFER did not trigger DHCPREQUEST")
        }
        expect(stack.dhcpClient.phase == .requesting, "DHCP phase after offer")
        expectDHCPFrame(
            link.transmittedFrame,
            messageType: .request,
            transactionIdentifier: transaction,
            requestedAddress: offeredAddress,
            serverIdentifier: serverAddress
        )

        let acknowledgementPayload = makeDHCPReply(
            messageType: .acknowledgement,
            transactionIdentifier: transaction,
            clientHardwareAddress: localMAC,
            offeredAddress: offeredAddress,
            serverIdentifier: serverAddress,
            subnetMask: IPv4Address(255, 255, 255, 0),
            router: serverAddress,
            domainNameServer: IPv4Address(1, 1, 1, 1),
            leaseDurationSeconds: 7_200
        )
        link.inboundFrame = makeUDPFrame(
            sourceHardwareAddress: routerMAC,
            destinationHardwareAddress: localMAC,
            sourceAddress: serverAddress,
            destinationAddress: offeredAddress,
            sourcePort: 67,
            destinationPort: 68,
            payload: acknowledgementPayload
        )
        let acknowledgementEvent = poll(
            &stack,
            link: &link,
            nowTicks: 106,
            receive: &receive,
            transmit: &transmit
        )
        guard case .dhcpConfigured(let lease) = acknowledgementEvent else {
            fail("DHCPACK did not bind the interface")
        }
        expect(lease.address == offeredAddress, "bound address changed")
        expect(lease.leaseDurationSeconds == 7_200, "ACK lease was not used")
        expect(stack.dhcpClient.phase == .bound, "DHCP phase after ACK")
        expect(
            stack.networkConfiguration == IPv4NetworkConfiguration(
                address: offeredAddress,
                subnetMask: IPv4Address(255, 255, 255, 0),
                defaultRouter: serverAddress,
                domainNameServer: IPv4Address(1, 1, 1, 1)
            ),
            "lease did not become the active network configuration"
        )
    }

    private static func validatesDHCPRetryDeadlinesAndOptions() {
        var client = DHCPv4Client(
            hardwareAddress: localMAC,
            transactionIdentifier: 7,
            retryPolicy: DHCPv4RetryPolicy(
                initialRetryTicks: 10,
                maximumRetryTicks: 40
            )
        )
        client.start(nowTicks: 1_000)
        expect(client.actionDue(nowTicks: 999) == nil, "early DHCP action")
        expect(
            client.actionDue(nowTicks: 1_000) == .sendDiscover,
            "discover was not due"
        )
        client.noteTransmitted(action: .sendDiscover, nowTicks: 1_000)
        expect(client.nextRetryDeadlineTicks == 1_010, "first retry")
        client.noteTransmitted(action: .sendDiscover, nowTicks: 1_010)
        expect(client.nextRetryDeadlineTicks == 1_030, "second retry")
        client.noteTransmitted(action: .sendDiscover, nowTicks: 1_030)
        expect(client.nextRetryDeadlineTicks == 1_070, "capped retry")
        client.noteTransmitted(action: .sendDiscover, nowTicks: 1_070)
        expect(client.nextRetryDeadlineTicks == 1_110, "retry cap changed")

        var encoded = [UInt8](repeating: 0xaa, count: 300)
        let encodedResult = encoded.withUnsafeMutableBytes {
            client.encode(action: .sendDiscover, into: $0)
        }
        expect(
            encodedResult == .encoded(byteCount: 300),
            "standalone discover encoding failed"
        )
        expect(encoded[0] == 1 && encoded[1] == 1 && encoded[2] == 6,
               "BOOTP hardware header")
        expect(encoded[10] == 0x80 && encoded[11] == 0,
               "DHCP broadcast flag")
        expect(
            readOption(53, from: encoded)?.first ==
                DHCPv4MessageType.discover.rawValue,
            "discover message type option"
        )
        expect(readOption(61, from: encoded)?.count == 7,
               "client identifier option")
        expect(readOption(55, from: encoded)?.count == 5,
               "parameter request list")

        var malformedReply = makeDHCPReply(
            messageType: .offer,
            transactionIdentifier: 7,
            clientHardwareAddress: localMAC,
            offeredAddress: IPv4Address(10, 0, 0, 9),
            serverIdentifier: IPv4Address(10, 0, 0, 1)
        )
        malformedReply.removeLast(malformedReply.count - 242)
        malformedReply[240] = 53
        malformedReply[241] = 8
        let malformedResult = malformedReply.withUnsafeBytes {
            client.receive($0, nowTicks: 2_000)
        }
        expect(
            malformedResult == .rejected(.malformedOptions),
            "truncated DHCP option was accepted"
        )

        let wrongTransaction = makeDHCPReply(
            messageType: .offer,
            transactionIdentifier: 8,
            clientHardwareAddress: localMAC,
            offeredAddress: IPv4Address(10, 0, 0, 9),
            serverIdentifier: IPv4Address(10, 0, 0, 1)
        )
        let wrongTransactionResult = wrongTransaction.withUnsafeBytes {
            client.receive($0, nowTicks: 2_000)
        }
        expect(
            wrongTransactionResult == .rejected(.transactionMismatch(8)),
            "foreign DHCP transaction was accepted"
        )
    }

    private static func resolvesARPAndComposesUDPFrames() {
        let localAddress = IPv4Address(10, 0, 0, 10)
        let peerAddress = IPv4Address(10, 0, 0, 20)
        var stack = staticallyConfiguredStack(
            address: localAddress,
            router: IPv4Address(10, 0, 0, 1)
        )
        var link = FakeNetworkLink(macAddress: localMAC)
        var transmit = [UInt8](repeating: 0, count: 1_514)
        let payload: [UInt8] = [0xde, 0xad, 0xbe, 0xef]

        let firstResult = sendUDP(
            &stack,
            link: &link,
            destinationAddress: peerAddress,
            sourcePort: 4_000,
            destinationPort: 5_000,
            payload: payload,
            nowTicks: 50,
            transmit: &transmit
        )
        expect(
            firstResult == .arpRequestSent(target: peerAddress),
            "unresolved peer did not trigger ARP"
        )
        expectARPFrame(
            link.transmittedFrame,
            operation: .request,
            senderHardwareAddress: localMAC,
            senderProtocolAddress: localAddress,
            targetHardwareAddress: .zero,
            targetProtocolAddress: peerAddress,
            ethernetDestination: .broadcast
        )

        let throttled = sendUDP(
            &stack,
            link: &link,
            destinationAddress: peerAddress,
            sourcePort: 4_000,
            destinationPort: 5_000,
            payload: payload,
            nowTicks: 60,
            transmit: &transmit
        )
        expect(
            throttled == .awaitingARP(target: peerAddress, retryAtTicks: 70),
            "ARP retry was not throttled"
        )

        link.inboundFrame = makeARPFrame(
            operation: .reply,
            senderHardwareAddress: peerMAC,
            senderProtocolAddress: peerAddress,
            targetHardwareAddress: localMAC,
            targetProtocolAddress: localAddress,
            ethernetDestination: localMAC
        )
        var receive = [UInt8](repeating: 0, count: 1_514)
        let learnedEvent = poll(
            &stack,
            link: &link,
            nowTicks: 61,
            receive: &receive,
            transmit: &transmit
        )
        guard case .arpNeighborLearned(let learnedAddress) = learnedEvent,
              learnedAddress == peerAddress
        else {
            fail("ARP reply did not populate the neighbor cache")
        }

        let sentResult = sendUDP(
            &stack,
            link: &link,
            destinationAddress: peerAddress,
            sourcePort: 4_000,
            destinationPort: 5_000,
            payload: payload,
            nowTicks: 62,
            transmit: &transmit
        )
        guard case .sent = sentResult else {
            fail("resolved UDP datagram was not transmitted")
        }
        expectUDPFrame(
            link.transmittedFrame,
            sourceHardwareAddress: localMAC,
            destinationHardwareAddress: peerMAC,
            sourceAddress: localAddress,
            destinationAddress: peerAddress,
            sourcePort: 4_000,
            destinationPort: 5_000,
            payload: payload
        )

        let internetAddress = IPv4Address(1, 1, 1, 1)
        let routedResult = sendUDP(
            &stack,
            link: &link,
            destinationAddress: internetAddress,
            sourcePort: 4_000,
            destinationPort: 53,
            payload: payload,
            nowTicks: 63,
            transmit: &transmit
        )
        expect(
            routedResult == .arpRequestSent(target: IPv4Address(10, 0, 0, 1)),
            "off-subnet traffic did not resolve the router"
        )
    }

    private static func answersARPRequestsAndBoundsTheCache() {
        let localAddress = IPv4Address(10, 1, 0, 10)
        let peerAddress = IPv4Address(10, 1, 0, 20)
        var stack = staticallyConfiguredStack(address: localAddress)
        var link = FakeNetworkLink(macAddress: localMAC)
        link.inboundFrame = makeARPFrame(
            operation: .request,
            senderHardwareAddress: peerMAC,
            senderProtocolAddress: peerAddress,
            targetHardwareAddress: .zero,
            targetProtocolAddress: localAddress,
            ethernetDestination: .broadcast
        )
        var receive = [UInt8](repeating: 0, count: 1_514)
        var transmit = [UInt8](repeating: 0, count: 1_514)
        let event = poll(
            &stack,
            link: &link,
            nowTicks: 10,
            receive: &receive,
            transmit: &transmit
        )
        guard case .arpReplySent(let destination) = event,
              destination == peerAddress
        else {
            fail("ARP request did not receive a reply")
        }
        expectARPFrame(
            link.transmittedFrame,
            operation: .reply,
            senderHardwareAddress: localMAC,
            senderProtocolAddress: localAddress,
            targetHardwareAddress: peerMAC,
            targetProtocolAddress: peerAddress,
            ethernetDestination: peerMAC
        )

        var cache = BoundedARPNeighborCache()
        var index = 0
        while index < BoundedARPNeighborCache.capacity {
            cache.insert(
                protocolAddress: IPv4Address(10, 2, 0, UInt8(index + 1)),
                hardwareAddress: MACAddress(
                    0x02,
                    0,
                    0,
                    0,
                    1,
                    UInt8(index + 1)
                ),
                nowTicks: UInt64(index)
            )
            index += 1
        }
        expect(cache.count == 8, "ARP cache did not fill all bounded slots")
        let evictedAddress = IPv4Address(10, 2, 0, 1)
        cache.insert(
            protocolAddress: IPv4Address(10, 2, 0, 99),
            hardwareAddress: MACAddress(0x02, 0, 0, 0, 1, 99),
            nowTicks: 99
        )
        expect(cache.count == 8, "ARP cache exceeded its capacity")
        expect(
            cache.hardwareAddress(
                for: evictedAddress,
                nowTicks: 100,
                lifetimeTicks: 1_000
            ) == nil,
            "ARP cache did not evict its oldest entry"
        )
        let expiringAddress = IPv4Address(10, 2, 0, 2)
        expect(
            cache.hardwareAddress(
                for: expiringAddress,
                nowTicks: 1_001,
                lifetimeTicks: 1_000
            ) == nil,
            "stale ARP entry did not expire"
        )
    }

    private static func answersICMPEchoRequests() {
        let localAddress = IPv4Address(172, 16, 0, 10)
        let peerAddress = IPv4Address(172, 16, 0, 20)
        var stack = staticallyConfiguredStack(address: localAddress)
        var link = FakeNetworkLink(macAddress: localMAC)
        let echoPayload: [UInt8] = [1, 3, 3, 7, 0, 0xff]
        link.inboundFrame = makeICMPEchoFrame(
            sourceHardwareAddress: peerMAC,
            destinationHardwareAddress: localMAC,
            sourceAddress: peerAddress,
            destinationAddress: localAddress,
            type: .request,
            identifier: 0xabcd,
            sequenceNumber: 9,
            payload: echoPayload
        )
        var receive = [UInt8](repeating: 0, count: 1_514)
        var transmit = [UInt8](repeating: 0, count: 1_514)
        let event = poll(
            &stack,
            link: &link,
            nowTicks: 10,
            receive: &receive,
            transmit: &transmit
        )
        guard case .icmpEchoReplySent(let destination) = event,
              destination == peerAddress
        else {
            fail("ICMP echo request did not receive a reply")
        }
        expectICMPEchoFrame(
            link.transmittedFrame,
            sourceHardwareAddress: localMAC,
            destinationHardwareAddress: peerMAC,
            sourceAddress: localAddress,
            destinationAddress: peerAddress,
            type: .reply,
            identifier: 0xabcd,
            sequenceNumber: 9,
            payload: echoPayload
        )
    }

    private static func deliversInboundUDPAndRejectsInvalidBounds() {
        let localAddress = IPv4Address(192, 0, 2, 10)
        let peerAddress = IPv4Address(192, 0, 2, 20)
        var stack = staticallyConfiguredStack(address: localAddress)
        var link = FakeNetworkLink(macAddress: localMAC)
        let payload: [UInt8] = [9, 8, 7, 6]
        link.inboundFrame = makeUDPFrame(
            sourceHardwareAddress: peerMAC,
            destinationHardwareAddress: localMAC,
            sourceAddress: peerAddress,
            destinationAddress: localAddress,
            sourcePort: 4_444,
            destinationPort: 5_555,
            payload: payload
        )
        var receive = [UInt8](repeating: 0, count: 1_514)
        var transmit = [UInt8](repeating: 0, count: 1_514)
        let event = poll(
            &stack,
            link: &link,
            nowTicks: 0,
            receive: &receive,
            transmit: &transmit
        )
        guard case .udpDatagram(let datagram) = event else {
            fail("inbound UDP datagram was not delivered")
        }
        expect(datagram.sourceAddress == peerAddress, "inbound UDP source")
        expect(datagram.destinationAddress == localAddress,
               "inbound UDP destination")
        expect(datagram.sourcePort == 4_444 && datagram.destinationPort == 5_555,
               "inbound UDP ports")
        expect(bytesEqual(datagram.payload, payload), "inbound UDP payload")

        var dhcpStack = IPv4PollingStack(
            hardwareAddress: localMAC,
            dhcpTransactionIdentifier: 1,
            timing: timing
        )
        var smallTransmit = [UInt8](repeating: 0, count: 341)
        var emptyLink = FakeNetworkLink(macAddress: localMAC)
        let smallEvent = poll(
            &dhcpStack,
            link: &emptyLink,
            nowTicks: 0,
            receive: &receive,
            transmit: &smallTransmit
        )
        guard case .transmitScratchTooSmall(let required) = smallEvent,
              required == 342
        else {
            fail("undersized DHCP transmit scratch was not rejected exactly")
        }

        let largePayload = [UInt8](repeating: 0, count: 1_473)
        let largeResult = sendUDP(
            &stack,
            link: &link,
            destinationAddress: .limitedBroadcast,
            sourcePort: 1,
            destinationPort: 2,
            payload: largePayload,
            nowTicks: 1,
            transmit: &transmit
        )
        expect(
            largeResult == .payloadTooLarge(requested: 1_473, maximum: 1_472),
            "MTU overflow was not rejected before encoding"
        )

        var mismatchedLink = FakeNetworkLink(macAddress: peerMAC)
        let mismatchEvent = poll(
            &stack,
            link: &mismatchedLink,
            nowTicks: 1,
            receive: &receive,
            transmit: &transmit
        )
        guard case .linkIdentityMismatch = mismatchEvent else {
            fail("stack accepted a different link identity")
        }
    }

    private static func staticallyConfiguredStack(
        address: IPv4Address,
        router: IPv4Address? = nil
    ) -> IPv4PollingStack {
        var stack = IPv4PollingStack(
            hardwareAddress: localMAC,
            dhcpTransactionIdentifier: 0x0102_0304,
            timing: timing
        )
        stack.configureStatically(
            IPv4NetworkConfiguration(
                address: address,
                subnetMask: IPv4Address(255, 255, 255, 0),
                defaultRouter: router,
                domainNameServer: nil
            )
        )
        return stack
    }

    private static func poll(
        _ stack: inout IPv4PollingStack,
        link: inout FakeNetworkLink,
        nowTicks: UInt64,
        receive: inout [UInt8],
        transmit: inout [UInt8]
    ) -> IPv4PollingStackEvent {
        receive.withUnsafeMutableBytes { receiveBytes in
            transmit.withUnsafeMutableBytes { transmitBytes in
                stack.poll(
                    link: &link,
                    nowTicks: nowTicks,
                    receiveScratch: receiveBytes,
                    transmitScratch: transmitBytes
                )
            }
        }
    }

    private static func sendUDP(
        _ stack: inout IPv4PollingStack,
        link: inout FakeNetworkLink,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: [UInt8],
        nowTicks: UInt64,
        transmit: inout [UInt8]
    ) -> IPv4UDPSendResult {
        transmit.withUnsafeMutableBytes { transmitBytes in
            payload.withUnsafeBytes { payloadBytes in
                stack.sendUDP(
                    link: &link,
                    destinationAddress: destinationAddress,
                    sourcePort: sourcePort,
                    destinationPort: destinationPort,
                    payload: payloadBytes,
                    nowTicks: nowTicks,
                    transmitScratch: transmitBytes
                )
            }
        }
    }

    private static func makeDHCPReply(
        messageType: DHCPv4MessageType,
        transactionIdentifier: UInt32,
        clientHardwareAddress: MACAddress,
        offeredAddress: IPv4Address,
        serverIdentifier: IPv4Address?,
        subnetMask: IPv4Address? = nil,
        router: IPv4Address? = nil,
        domainNameServer: IPv4Address? = nil,
        leaseDurationSeconds: UInt32? = nil
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 300)
        result[0] = 2
        result[1] = 1
        result[2] = 6
        withMutableBytes(&result) { output in
            expect(
                NetworkWire.writeUInt32BE(
                    transactionIdentifier,
                    to: output,
                    at: 4
                ),
                "DHCP reply transaction write"
            )
            expect(offeredAddress.encode(to: output, at: 16), "DHCP yiaddr")
            if let serverIdentifier {
                expect(serverIdentifier.encode(to: output, at: 20), "DHCP siaddr")
            }
            expect(clientHardwareAddress.encode(to: output, at: 28),
                   "DHCP chaddr")
            expect(NetworkWire.writeUInt32BE(0x6382_5363, to: output, at: 236),
                   "DHCP cookie")
        }
        var offset = 240
        appendOption(53, bytes: [messageType.rawValue], to: &result, at: &offset)
        if let serverIdentifier {
            appendAddressOption(54, serverIdentifier, to: &result, at: &offset)
        }
        if let subnetMask {
            appendAddressOption(1, subnetMask, to: &result, at: &offset)
        }
        if let router {
            appendAddressOption(3, router, to: &result, at: &offset)
        }
        if let domainNameServer {
            appendAddressOption(6, domainNameServer, to: &result, at: &offset)
        }
        if let leaseDurationSeconds {
            let bytes = [
                UInt8(truncatingIfNeeded: leaseDurationSeconds >> 24),
                UInt8(truncatingIfNeeded: leaseDurationSeconds >> 16),
                UInt8(truncatingIfNeeded: leaseDurationSeconds >> 8),
                UInt8(truncatingIfNeeded: leaseDurationSeconds),
            ]
            appendOption(51, bytes: bytes, to: &result, at: &offset)
        }
        result[offset] = 255
        return result
    }

    private static func makeUDPFrame(
        sourceHardwareAddress: MACAddress,
        destinationHardwareAddress: MACAddress,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: [UInt8]
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1_514)
        let udpByteCount = 8 + payload.count
        let ipByteCount = 20 + udpByteCount
        var frameByteCount = 0
        output.withUnsafeMutableBytes { bytes in
            guard let udpOutput = mutableView(bytes, offset: 34, count: udpByteCount),
                  let ipHeader = mutableView(bytes, offset: 14, count: 20)
            else {
                fail("UDP frame scratch slicing")
            }
            let udpResult = payload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: sourceAddress,
                    destinationAddress: destinationAddress,
                    sourcePort: sourcePort,
                    destinationPort: destinationPort,
                    payload: $0,
                    includeChecksum: true,
                    into: udpOutput
                )
            }
            guard case .encoded = udpResult else { fail("test UDP encode") }
            guard case .encoded = IPv4HeaderEncoder.encode(
                IPv4Header(
                    differentiatedServicesAndECN: 0,
                    identification: 1,
                    dontFragment: true,
                    timeToLive: 64,
                    protocolNumber: IPv4Protocol.udp,
                    source: sourceAddress,
                    destination: destinationAddress
                ),
                payloadByteCount: udpByteCount,
                into: ipHeader
            ) else {
                fail("test IPv4 encode")
            }
            guard let ipPacket = rawView(bytes, offset: 14, count: ipByteCount)
            else {
                fail("test IPv4 packet view")
            }
            guard case .encoded(let count) = EthernetIIFrameEncoder.encode(
                destination: destinationHardwareAddress,
                source: sourceHardwareAddress,
                etherType: .ipv4,
                payload: ipPacket,
                into: bytes
            ) else {
                fail("test Ethernet encode")
            }
            frameByteCount = count
        }
        return Array(output[0..<frameByteCount])
    }

    private static func makeARPFrame(
        operation: ARPOperation,
        senderHardwareAddress: MACAddress,
        senderProtocolAddress: IPv4Address,
        targetHardwareAddress: MACAddress,
        targetProtocolAddress: IPv4Address,
        ethernetDestination: MACAddress
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 60)
        var frameByteCount = 0
        output.withUnsafeMutableBytes { bytes in
            guard let arpOutput = mutableView(bytes, offset: 14, count: 28)
            else {
                fail("ARP frame scratch slicing")
            }
            guard case .encoded = ARPEthernetIPv4Encoder.encode(
                ARPEthernetIPv4Packet(
                    operation: operation,
                    senderHardwareAddress: senderHardwareAddress,
                    senderProtocolAddress: senderProtocolAddress,
                    targetHardwareAddress: targetHardwareAddress,
                    targetProtocolAddress: targetProtocolAddress
                ),
                into: arpOutput
            ) else {
                fail("test ARP encode")
            }
            guard let arpPacket = rawView(bytes, offset: 14, count: 28) else {
                fail("test ARP packet view")
            }
            guard case .encoded(let count) = EthernetIIFrameEncoder.encode(
                destination: ethernetDestination,
                source: senderHardwareAddress,
                etherType: .arp,
                payload: arpPacket,
                into: bytes
            ) else {
                fail("test ARP Ethernet encode")
            }
            frameByteCount = count
        }
        return Array(output[0..<frameByteCount])
    }

    private static func makeICMPEchoFrame(
        sourceHardwareAddress: MACAddress,
        destinationHardwareAddress: MACAddress,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        type: ICMPEchoType,
        identifier: UInt16,
        sequenceNumber: UInt16,
        payload: [UInt8]
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1_514)
        let icmpByteCount = 8 + payload.count
        let ipByteCount = 20 + icmpByteCount
        var frameByteCount = 0
        output.withUnsafeMutableBytes { bytes in
            guard let icmpOutput = mutableView(
                      bytes,
                      offset: 34,
                      count: icmpByteCount
                  ),
                  let ipHeader = mutableView(bytes, offset: 14, count: 20)
            else {
                fail("ICMP frame scratch slicing")
            }
            let icmpResult = payload.withUnsafeBytes {
                ICMPEchoEncoder.encode(
                    type: type,
                    identifier: identifier,
                    sequenceNumber: sequenceNumber,
                    payload: $0,
                    into: icmpOutput
                )
            }
            guard case .encoded = icmpResult else { fail("test ICMP encode") }
            guard case .encoded = IPv4HeaderEncoder.encode(
                IPv4Header(
                    differentiatedServicesAndECN: 0,
                    identification: 1,
                    dontFragment: true,
                    timeToLive: 64,
                    protocolNumber: IPv4Protocol.icmp,
                    source: sourceAddress,
                    destination: destinationAddress
                ),
                payloadByteCount: icmpByteCount,
                into: ipHeader
            ) else {
                fail("test ICMP IPv4 encode")
            }
            guard let ipPacket = rawView(bytes, offset: 14, count: ipByteCount)
            else {
                fail("test ICMP IPv4 view")
            }
            guard case .encoded(let count) = EthernetIIFrameEncoder.encode(
                destination: destinationHardwareAddress,
                source: sourceHardwareAddress,
                etherType: .ipv4,
                payload: ipPacket,
                into: bytes
            ) else {
                fail("test ICMP Ethernet encode")
            }
            frameByteCount = count
        }
        return Array(output[0..<frameByteCount])
    }

    private static func expectDHCPFrame(
        _ frameBytes: [UInt8],
        messageType: DHCPv4MessageType,
        transactionIdentifier: UInt32,
        requestedAddress: IPv4Address?,
        serverIdentifier: IPv4Address?
    ) {
        frameBytes.withUnsafeBytes { bytes in
            guard case .decoded(let frame) = EthernetIIFrameDecoder.decode(bytes),
                  frame.destination == .broadcast,
                  frame.source == localMAC,
                  frame.etherType == .ipv4,
                  case .decoded(let packet) = IPv4Decoder.decode(frame.payload),
                  packet.header.source == .unspecified,
                  packet.header.destination == .limitedBroadcast,
                  case .decoded(let datagram) = UDPDecoder.decode(
                      packet.payload,
                      sourceAddress: packet.header.source,
                      destinationAddress: packet.header.destination
                  ),
                  datagram.sourcePort == 68,
                  datagram.destinationPort == 67,
                  let xid = NetworkWire.readUInt32BE(datagram.payload, at: 4),
                  xid == transactionIdentifier
            else {
                fail("invalid DHCP Ethernet/IPv4/UDP envelope")
            }
            expect(
                optionByte(53, in: datagram.payload) == messageType.rawValue,
                "DHCP message type changed"
            )
            expect(
                optionAddress(50, in: datagram.payload) == requestedAddress,
                "DHCP requested address option changed"
            )
            expect(
                optionAddress(54, in: datagram.payload) == serverIdentifier,
                "DHCP server identifier option changed"
            )
        }
    }

    private static func expectUDPFrame(
        _ frameBytes: [UInt8],
        sourceHardwareAddress: MACAddress,
        destinationHardwareAddress: MACAddress,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: [UInt8]
    ) {
        frameBytes.withUnsafeBytes { bytes in
            guard case .decoded(let frame) = EthernetIIFrameDecoder.decode(bytes),
                  frame.source == sourceHardwareAddress,
                  frame.destination == destinationHardwareAddress,
                  case .decoded(let packet) = IPv4Decoder.decode(frame.payload),
                  packet.header.source == sourceAddress,
                  packet.header.destination == destinationAddress,
                  case .decoded(let datagram) = UDPDecoder.decode(
                      packet.payload,
                      sourceAddress: sourceAddress,
                      destinationAddress: destinationAddress
                  )
            else {
                fail("invalid UDP frame envelope")
            }
            expect(datagram.sourcePort == sourcePort, "UDP source port")
            expect(datagram.destinationPort == destinationPort,
                   "UDP destination port")
            expect(bytesEqual(datagram.payload, payload), "UDP payload")
            expect(datagram.checksumDisposition == .verified, "UDP checksum")
        }
    }

    private static func expectARPFrame(
        _ frameBytes: [UInt8],
        operation: ARPOperation,
        senderHardwareAddress: MACAddress,
        senderProtocolAddress: IPv4Address,
        targetHardwareAddress: MACAddress,
        targetProtocolAddress: IPv4Address,
        ethernetDestination: MACAddress
    ) {
        frameBytes.withUnsafeBytes { bytes in
            guard case .decoded(let frame) = EthernetIIFrameDecoder.decode(bytes),
                  frame.destination == ethernetDestination,
                  frame.source == senderHardwareAddress,
                  frame.etherType == .arp,
                  case .decoded(let packet) =
                      ARPEthernetIPv4Decoder.decode(frame.payload)
            else {
                fail("invalid ARP frame envelope")
            }
            expect(packet.operation == operation, "ARP operation")
            expect(packet.senderHardwareAddress == senderHardwareAddress,
                   "ARP sender hardware address")
            expect(packet.senderProtocolAddress == senderProtocolAddress,
                   "ARP sender protocol address")
            expect(packet.targetHardwareAddress == targetHardwareAddress,
                   "ARP target hardware address")
            expect(packet.targetProtocolAddress == targetProtocolAddress,
                   "ARP target protocol address")
        }
    }

    private static func expectICMPEchoFrame(
        _ frameBytes: [UInt8],
        sourceHardwareAddress: MACAddress,
        destinationHardwareAddress: MACAddress,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        type: ICMPEchoType,
        identifier: UInt16,
        sequenceNumber: UInt16,
        payload: [UInt8]
    ) {
        frameBytes.withUnsafeBytes { bytes in
            guard case .decoded(let frame) = EthernetIIFrameDecoder.decode(bytes),
                  frame.source == sourceHardwareAddress,
                  frame.destination == destinationHardwareAddress,
                  case .decoded(let packet) = IPv4Decoder.decode(frame.payload),
                  packet.header.source == sourceAddress,
                  packet.header.destination == destinationAddress,
                  case .decoded(let echo) = ICMPEchoDecoder.decode(packet.payload)
            else {
                fail("invalid ICMP echo frame envelope")
            }
            expect(echo.type == type, "ICMP echo type")
            expect(echo.identifier == identifier, "ICMP echo identifier")
            expect(echo.sequenceNumber == sequenceNumber, "ICMP echo sequence")
            expect(bytesEqual(echo.payload, payload), "ICMP echo payload")
        }
    }

    private static func appendAddressOption(
        _ code: UInt8,
        _ address: IPv4Address,
        to output: inout [UInt8],
        at offset: inout Int
    ) {
        appendOption(
            code,
            bytes: [address.octet0, address.octet1, address.octet2, address.octet3],
            to: &output,
            at: &offset
        )
    }

    private static func appendOption(
        _ code: UInt8,
        bytes: [UInt8],
        to output: inout [UInt8],
        at offset: inout Int
    ) {
        expect(offset + 2 + bytes.count < output.count, "test DHCP options fit")
        output[offset] = code
        output[offset + 1] = UInt8(bytes.count)
        var index = 0
        while index < bytes.count {
            output[offset + 2 + index] = bytes[index]
            index += 1
        }
        offset += 2 + bytes.count
    }

    private static func readOption(
        _ wantedCode: UInt8,
        from packet: [UInt8]
    ) -> [UInt8]? {
        var result: [UInt8]?
        packet.withUnsafeBytes { bytes in
            if let option = optionView(wantedCode, in: bytes) {
                result = Array(option)
            }
        }
        return result
    }

    private static func optionByte(
        _ wantedCode: UInt8,
        in packet: UnsafeRawBufferPointer
    ) -> UInt8? {
        guard let option = optionView(wantedCode, in: packet), option.count == 1
        else {
            return nil
        }
        return option[0]
    }

    private static func optionAddress(
        _ wantedCode: UInt8,
        in packet: UnsafeRawBufferPointer
    ) -> IPv4Address? {
        guard let option = optionView(wantedCode, in: packet), option.count == 4
        else {
            return nil
        }
        return IPv4Address.decode(from: option, at: 0)
    }

    private static func optionView(
        _ wantedCode: UInt8,
        in packet: UnsafeRawBufferPointer
    ) -> UnsafeRawBufferPointer? {
        var offset = 240
        while offset < packet.count {
            let code = packet[offset]
            offset += 1
            if code == 0 { continue }
            if code == 255 { return nil }
            guard offset < packet.count else { return nil }
            let length = Int(packet[offset])
            offset += 1
            guard let value = NetworkWire.view(
                      packet,
                      offset: offset,
                      count: length
                  )
            else {
                return nil
            }
            if code == wantedCode { return value }
            offset += length
        }
        return nil
    }

    private static func bytesEqual(
        _ borrowed: UnsafeRawBufferPointer,
        _ expected: [UInt8]
    ) -> Bool {
        guard borrowed.count == expected.count else { return false }
        var index = 0
        while index < expected.count {
            if borrowed[index] != expected[index] { return false }
            index += 1
        }
        return true
    }

    private static func mutableView(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeMutableRawBufferPointer? {
        guard NetworkWire.contains(bytes, offset: offset, count: count),
              let base = bytes.baseAddress
        else {
            return nil
        }
        return UnsafeMutableRawBufferPointer(
            start: base.advanced(by: offset),
            count: count
        )
    }

    private static func rawView(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeRawBufferPointer? {
        guard NetworkWire.contains(bytes, offset: offset, count: count),
              let base = bytes.baseAddress
        else {
            return nil
        }
        return UnsafeRawBufferPointer(
            start: base.advanced(by: offset),
            count: count
        )
    }

    private static func withMutableBytes(
        _ bytes: inout [UInt8],
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        bytes.withUnsafeMutableBytes(body)
    }

    private static func expectIdle(
        _ event: IPv4PollingStackEvent,
        _ message: String
    ) {
        guard case .idle = event else { fail(message) }
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

private struct FakeNetworkLink: NetworkLink {
    let macAddress: MACAddress
    var mtu: UInt16 = 1_500
    var linkState: NetworkLinkState = .up
    var inboundFrame: [UInt8]?
    var transmittedFrame: [UInt8] = []
    var transmitResult: NetworkLinkTransmitResult = .sent

    mutating func pollReceive(
        into output: UnsafeMutableRawBufferPointer
    ) -> NetworkLinkReceiveResult {
        guard let frame = inboundFrame else { return .noPacket }
        guard output.count >= frame.count else {
            return .outputTooSmall(requiredByteCount: frame.count)
        }
        var index = 0
        while index < frame.count {
            output[index] = frame[index]
            index += 1
        }
        inboundFrame = nil
        return .received(byteCount: frame.count)
    }

    mutating func transmit(
        _ frame: UnsafeRawBufferPointer
    ) -> NetworkLinkTransmitResult {
        transmittedFrame = Array(frame)
        return transmitResult
    }
}
