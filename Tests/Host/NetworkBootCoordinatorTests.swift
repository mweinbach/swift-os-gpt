@main
struct NetworkBootCoordinatorTests {
    private static let localMAC = MACAddress(0x02, 0x12, 0x34, 0x56, 0x78, 0x9a)
    private static let serverMAC = MACAddress(0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee)

    static func main() {
        buildsDeterministicServicePolicy()
        timesOutAcrossCounterRollover()
        exitsWhenDHCPConfiguresTheService()
        classifiesPollingFaultsExactly()
        print("Network boot coordinator: 4 groups passed")
    }

    private static func buildsDeterministicServicePolicy() {
        let startTicks: UInt64 = 0x1122_3344_5566_7788
        let counterFrequency: UInt64 = 1_000
        expect(
            NetworkBootCoordinator.packedMACAddress(localMAC)
                == 0x0000_0212_3456_789a,
            "MAC packing changed"
        )

        withScratch { receiveAddress, transmitAddress in
            guard let first = NetworkBootCoordinator.makeService(
                      link: FakeNetworkLink(macAddress: localMAC),
                      receiveScratchAddress: receiveAddress,
                      transmitScratchAddress: transmitAddress,
                      scratchByteCount: 2_048,
                      counterFrequency: counterFrequency,
                      startTicks: startTicks
                  ),
                  let second = NetworkBootCoordinator.makeService(
                      link: FakeNetworkLink(macAddress: localMAC),
                      receiveScratchAddress: receiveAddress,
                      transmitScratchAddress: transmitAddress,
                      scratchByteCount: 2_048,
                      counterFrequency: counterFrequency,
                      startTicks: startTicks
                  )
            else {
                fail("deterministic service policy was rejected")
            }

            let packedMAC = NetworkBootCoordinator.packedMACAddress(localMAC)
            let expectedTransaction = UInt32(
                truncatingIfNeeded: startTicks ^ packedMAC ^ (packedMAC >> 32)
            )
            expect(
                first.stack.dhcpClient.transactionIdentifier
                    == expectedTransaction,
                "transaction identifier does not follow the shared policy"
            )
            expect(
                second.stack.dhcpClient.transactionIdentifier
                    == first.stack.dhcpClient.transactionIdentifier,
                "identical service inputs produced different transactions"
            )
            expect(
                first.stack.dhcpClient.nextRetryDeadlineTicks == startTicks,
                "DHCP did not start at the injected tick"
            )
            expect(
                first.stack.timing.arpEntryLifetimeTicks == 300_000,
                "ARP lifetime does not scale with the counter frequency"
            )
            expect(
                first.stack.timing.arpProbeIntervalTicks == 1_000,
                "ARP probe interval does not scale with the counter frequency"
            )
            expect(
                first.stack.timing.dhcpRetryPolicy
                    == DHCPv4RetryPolicy(
                        initialRetryTicks: 100,
                        maximumRetryTicks: 1_000
                    ),
                "DHCP retry policy changed"
            )
            expect(
                NetworkBootCoordinator.makeService(
                    link: FakeNetworkLink(macAddress: localMAC),
                    receiveScratchAddress: receiveAddress,
                    transmitScratchAddress: transmitAddress,
                    scratchByteCount: 2_048,
                    counterFrequency: 0,
                    startTicks: startTicks
                ) == nil,
                "zero-frequency timing was accepted"
            )
            expect(
                NetworkBootCoordinator.makeService(
                    link: FakeNetworkLink(macAddress: localMAC),
                    receiveScratchAddress: receiveAddress,
                    transmitScratchAddress: transmitAddress,
                    scratchByteCount: 2_048,
                    counterFrequency: UInt64.max / 300 + 1,
                    startTicks: startTicks
                ) == nil,
                "overflowing ARP timing was accepted"
            )
        }
    }

    private static func timesOutAcrossCounterRollover() {
        let startTicks = UInt64.max - 2
        withScratch { receiveAddress, transmitAddress in
            guard var service = NetworkBootCoordinator.makeService(
                      link: FakeNetworkLink(macAddress: localMAC),
                      receiveScratchAddress: receiveAddress,
                      transmitScratchAddress: transmitAddress,
                      scratchByteCount: 2_048,
                      counterFrequency: 100,
                      startTicks: startTicks
                  )
            else {
                fail("rollover timeout service was rejected")
            }
            var clock = IncrementingClock(nextValue: startTicks)
            let outcome = NetworkBootCoordinator.poll(
                service: &service,
                startTicks: startTicks,
                deadlineDeltaTicks: 5,
                linkDownPolicy: .recoverable,
                clock: &clock
            )
            guard case .timedOut = outcome else {
                fail("wrap-safe deadline did not time out")
            }
            expect(
                clock.spinCount == 5,
                "rollover deadline iteration changed: \(clock.spinCount)"
            )

            let readsBeforeZeroDeadline = clock.readCount
            let zeroDeadline = NetworkBootCoordinator.poll(
                service: &service,
                startTicks: clock.nextValue,
                deadlineDeltaTicks: 0,
                linkDownPolicy: .recoverable,
                clock: &clock
            )
            guard case .timedOut = zeroDeadline else {
                fail("zero deadline did not time out immediately")
            }
            expect(
                clock.readCount == readsBeforeZeroDeadline,
                "zero deadline consulted the clock"
            )
        }
    }

    private static func exitsWhenDHCPConfiguresTheService() {
        let startTicks: UInt64 = 100
        let packedMAC = NetworkBootCoordinator.packedMACAddress(localMAC)
        let transactionIdentifier = UInt32(
            truncatingIfNeeded: startTicks ^ packedMAC ^ (packedMAC >> 32)
        )
        let offeredAddress = IPv4Address(10, 44, 0, 15)
        let serverAddress = IPv4Address(10, 44, 0, 2)
        let subnetMask = IPv4Address(255, 255, 255, 0)
        let router = IPv4Address(10, 44, 0, 1)
        let domainNameServer = IPv4Address(10, 44, 0, 53)
        let offer = makeDHCPFrame(
            messageType: .offer,
            transactionIdentifier: transactionIdentifier,
            offeredAddress: offeredAddress,
            serverAddress: serverAddress,
            subnetMask: subnetMask,
            router: router,
            domainNameServer: domainNameServer
        )
        let acknowledgement = makeDHCPFrame(
            messageType: .acknowledgement,
            transactionIdentifier: transactionIdentifier,
            offeredAddress: offeredAddress,
            serverAddress: serverAddress,
            subnetMask: subnetMask,
            router: router,
            domainNameServer: domainNameServer
        )

        withScratch { receiveAddress, transmitAddress in
            guard var service = NetworkBootCoordinator.makeService(
                      link: FakeNetworkLink(
                          macAddress: localMAC,
                          inboundFrames: [offer, acknowledgement]
                      ),
                      receiveScratchAddress: receiveAddress,
                      transmitScratchAddress: transmitAddress,
                      scratchByteCount: 2_048,
                      counterFrequency: 100,
                      startTicks: startTicks
                  )
            else {
                fail("DHCP coordinator service was rejected")
            }
            var clock = IncrementingClock(nextValue: startTicks)
            let outcome = NetworkBootCoordinator.poll(
                service: &service,
                startTicks: startTicks,
                deadlineDeltaTicks: 50,
                linkDownPolicy: .recoverable,
                clock: &clock
            )
            guard case .configured = outcome else {
                fail("coordinator did not exit after DHCP configuration")
            }
            guard let configuration = service.networkConfiguration else {
                fail("configured outcome has no network configuration")
            }
            expect(configuration.address == offeredAddress, "lease address changed")
            expect(configuration.subnetMask == subnetMask, "lease mask changed")
            expect(configuration.defaultRouter == router, "lease router changed")
            expect(
                configuration.domainNameServer == domainNameServer,
                "lease DNS changed"
            )
            expect(
                service.link.transmitCount == 2,
                "DHCP did not send exactly one discover and one request"
            )
            expect(clock.spinCount == 2, "configured exit performed extra polling")
        }
    }

    private static func classifiesPollingFaultsExactly() {
        expectFault(.deviceFault, policy: .recoverable, is: .device)
        expectFault(
            .linkIdentityMismatch(expected: localMAC, actual: serverMAC),
            policy: .recoverable,
            is: .identity
        )
        expectFault(
            .receiveScratchTooSmall(required: 2_048),
            policy: .recoverable,
            is: .scratch
        )
        expectFault(
            .transmitScratchTooSmall(required: 2_048),
            policy: .recoverable,
            is: .scratch
        )
        expectFault(
            .transmitFailed(.invalidFrame),
            policy: .recoverable,
            is: .invalidTransmitFrame
        )
        expectFault(
            .transmitFailed(.timedOut),
            policy: .recoverable,
            is: .transmitTimeout
        )
        expectFault(
            .transmitFailed(.deviceFault),
            policy: .recoverable,
            is: .transmitDevice
        )
        expect(
            NetworkBootCoordinator.pollingFault(
                for: .linkDown,
                linkDownPolicy: .recoverable
            ) == nil,
            "passive link-down was not recoverable"
        )
        expect(
            NetworkBootCoordinator.pollingFault(
                for: .linkDown,
                linkDownPolicy: .fault
            ) == nil,
            "passive link-down became fatal under transmit policy"
        )
        expect(
            NetworkBootCoordinator.pollingFault(
                for: .transmitFailed(.linkDown),
                linkDownPolicy: .recoverable
            ) == nil,
            "recoverable transmit link-down became fatal"
        )
        expectFault(
            .transmitFailed(.linkDown),
            policy: .fault,
            is: .transmitLinkDown
        )
        expect(
            NetworkBootCoordinator.pollingFault(
                for: .transmitFailed(.sent),
                linkDownPolicy: .fault
            ) == nil,
            "successful transmission was classified as a fault"
        )
        expect(
            NetworkBootCoordinator.pollingFault(
                for: .malformedProtocolPacket,
                linkDownPolicy: .fault
            ) == nil,
            "discardable protocol input was classified as fatal"
        )
    }

    private enum ExpectedFault {
        case device
        case identity
        case scratch
        case transmitLinkDown
        case invalidTransmitFrame
        case transmitTimeout
        case transmitDevice
    }

    private static func expectFault(
        _ event: IPv4PollingStackEvent,
        policy: NetworkLinkDownPolicy,
        is expected: ExpectedFault
    ) {
        guard let actual = NetworkBootCoordinator.pollingFault(
                  for: event,
                  linkDownPolicy: policy
              )
        else {
            fail("expected polling fault was not classified")
        }
        let matches: Bool
        switch (expected, actual) {
        case (.device, .device),
             (.identity, .identity),
             (.scratch, .scratch),
             (.transmitLinkDown, .transmitLinkDown),
             (.invalidTransmitFrame, .invalidTransmitFrame),
             (.transmitTimeout, .transmitTimeout),
             (.transmitDevice, .transmitDevice):
            matches = true
        default:
            matches = false
        }
        expect(matches, "polling fault was classified into the wrong case")
    }

    private static func makeDHCPFrame(
        messageType: DHCPv4MessageType,
        transactionIdentifier: UInt32,
        offeredAddress: IPv4Address,
        serverAddress: IPv4Address,
        subnetMask: IPv4Address,
        router: IPv4Address,
        domainNameServer: IPv4Address
    ) -> [UInt8] {
        let payload = makeDHCPPayload(
            messageType: messageType,
            transactionIdentifier: transactionIdentifier,
            offeredAddress: offeredAddress,
            serverAddress: serverAddress,
            subnetMask: subnetMask,
            router: router,
            domainNameServer: domainNameServer
        )
        var output = [UInt8](repeating: 0, count: 1_514)
        let udpByteCount = UDPProtocol.headerByteCount + payload.count
        let ipv4ByteCount = IPv4Protocol.headerByteCount + udpByteCount
        var frameByteCount = 0
        output.withUnsafeMutableBytes { bytes in
            guard let udpOutput = mutableView(
                      bytes,
                      offset: EthernetIIProtocol.headerByteCount
                          + IPv4Protocol.headerByteCount,
                      count: udpByteCount
                  ),
                  let ipv4Header = mutableView(
                      bytes,
                      offset: EthernetIIProtocol.headerByteCount,
                      count: IPv4Protocol.headerByteCount
                  )
            else {
                fail("DHCP frame scratch slicing failed")
            }
            let udpResult = payload.withUnsafeBytes {
                UDPEncoder.encode(
                    sourceAddress: serverAddress,
                    destinationAddress: .limitedBroadcast,
                    sourcePort: 67,
                    destinationPort: 68,
                    payload: $0,
                    includeChecksum: true,
                    into: udpOutput
                )
            }
            guard case .encoded = udpResult else {
                fail("DHCP UDP envelope encoding failed")
            }
            guard case .encoded = IPv4HeaderEncoder.encode(
                IPv4Header(
                    differentiatedServicesAndECN: 0,
                    identification: 1,
                    dontFragment: true,
                    timeToLive: 64,
                    protocolNumber: IPv4Protocol.udp,
                    source: serverAddress,
                    destination: .limitedBroadcast
                ),
                payloadByteCount: udpByteCount,
                into: ipv4Header
            ) else {
                fail("DHCP IPv4 envelope encoding failed")
            }
            guard let ipv4Packet = rawView(
                      bytes,
                      offset: EthernetIIProtocol.headerByteCount,
                      count: ipv4ByteCount
                  )
            else {
                fail("DHCP IPv4 packet view failed")
            }
            guard case .encoded(let byteCount) = EthernetIIFrameEncoder.encode(
                destination: .broadcast,
                source: serverMAC,
                etherType: .ipv4,
                payload: ipv4Packet,
                into: bytes
            ) else {
                fail("DHCP Ethernet envelope encoding failed")
            }
            frameByteCount = byteCount
        }
        return Array(output[0..<frameByteCount])
    }

    private static func makeDHCPPayload(
        messageType: DHCPv4MessageType,
        transactionIdentifier: UInt32,
        offeredAddress: IPv4Address,
        serverAddress: IPv4Address,
        subnetMask: IPv4Address,
        router: IPv4Address,
        domainNameServer: IPv4Address
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 300)
        output[0] = 2
        output[1] = 1
        output[2] = UInt8(MACAddress.byteCount)
        output.withUnsafeMutableBytes { bytes in
            expect(
                NetworkWire.writeUInt32BE(
                    transactionIdentifier,
                    to: bytes,
                    at: 4
                ),
                "DHCP transaction write failed"
            )
            expect(
                offeredAddress.encode(to: bytes, at: 16),
                "DHCP offered address write failed"
            )
            expect(
                serverAddress.encode(to: bytes, at: 20),
                "DHCP server address write failed"
            )
            expect(
                localMAC.encode(to: bytes, at: 28),
                "DHCP client address write failed"
            )
            expect(
                NetworkWire.writeUInt32BE(0x6382_5363, to: bytes, at: 236),
                "DHCP cookie write failed"
            )
        }
        var offset = 240
        appendOption(53, bytes: [messageType.rawValue], to: &output, at: &offset)
        appendAddressOption(54, serverAddress, to: &output, at: &offset)
        appendAddressOption(1, subnetMask, to: &output, at: &offset)
        appendAddressOption(3, router, to: &output, at: &offset)
        appendAddressOption(6, domainNameServer, to: &output, at: &offset)
        appendOption(51, bytes: [0, 0, 0x0e, 0x10], to: &output, at: &offset)
        output[offset] = 255
        return output
    }

    private static func appendAddressOption(
        _ code: UInt8,
        _ address: IPv4Address,
        to output: inout [UInt8],
        at offset: inout Int
    ) {
        appendOption(
            code,
            bytes: [
                address.octet0,
                address.octet1,
                address.octet2,
                address.octet3,
            ],
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
        expect(offset + 2 + bytes.count < output.count, "DHCP options overflowed")
        output[offset] = code
        output[offset + 1] = UInt8(bytes.count)
        var index = 0
        while index < bytes.count {
            output[offset + 2 + index] = bytes[index]
            index += 1
        }
        offset += 2 + bytes.count
    }

    private static func mutableView(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeMutableRawBufferPointer? {
        guard NetworkWire.contains(bytes, offset: offset, count: count),
              let baseAddress = bytes.baseAddress
        else {
            return nil
        }
        return UnsafeMutableRawBufferPointer(
            start: baseAddress.advanced(by: offset),
            count: count
        )
    }

    private static func rawView(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeRawBufferPointer? {
        guard NetworkWire.contains(bytes, offset: offset, count: count),
              let baseAddress = bytes.baseAddress
        else {
            return nil
        }
        return UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: offset),
            count: count
        )
    }

    private static func withScratch(
        _ body: (_ receiveAddress: UInt64, _ transmitAddress: UInt64) -> Void
    ) {
        var receive = [UInt8](repeating: 0, count: 2_048)
        var transmit = [UInt8](repeating: 0, count: 2_048)
        receive.withUnsafeMutableBytes { receiveBytes in
            transmit.withUnsafeMutableBytes { transmitBytes in
                guard let receiveBase = receiveBytes.baseAddress,
                      let transmitBase = transmitBytes.baseAddress
                else {
                    fail("test scratch has no storage")
                }
                body(
                    UInt64(UInt(bitPattern: receiveBase)),
                    UInt64(UInt(bitPattern: transmitBase))
                )
            }
        }
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

private struct IncrementingClock: NetworkBootClock {
    var nextValue: UInt64
    private(set) var readCount = 0
    private(set) var spinCount = 0

    mutating func counterValue() -> UInt64 {
        let result = nextValue
        nextValue &+= 1
        readCount += 1
        return result
    }

    mutating func spinWaitHint() {
        spinCount += 1
    }
}

private struct FakeNetworkLink: NetworkLink {
    let macAddress: MACAddress
    var mtu: UInt16 = 1_500
    var linkState: NetworkLinkState = .up
    var inboundFrames: [[UInt8]] = []
    private(set) var receiveIndex = 0
    private(set) var transmitCount = 0

    mutating func pollReceive(
        into output: UnsafeMutableRawBufferPointer
    ) -> NetworkLinkReceiveResult {
        guard receiveIndex < inboundFrames.count else { return .noPacket }
        let frame = inboundFrames[receiveIndex]
        guard output.count >= frame.count else {
            return .outputTooSmall(requiredByteCount: frame.count)
        }
        var index = 0
        while index < frame.count {
            output[index] = frame[index]
            index += 1
        }
        receiveIndex += 1
        return .received(byteCount: frame.count)
    }

    mutating func transmit(
        _ frame: UnsafeRawBufferPointer
    ) -> NetworkLinkTransmitResult {
        guard frame.baseAddress != nil, frame.count > 0 else {
            return .invalidFrame
        }
        transmitCount += 1
        return .sent
    }
}

/// The production counter implementation is intentionally not linked into
/// host codec tests. This same-module stub only satisfies the concrete clock
/// adapter while every coordinator path under test uses `IncrementingClock`.
enum AArch64 {
    static var counterValue: UInt64 { 0 }
    static func spinHint() {}
}
