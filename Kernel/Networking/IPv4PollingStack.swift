/// A configured IPv4 interface. The first implementation intentionally
/// supports one address, one default router, and one DNS server; the packet
/// path remains independent of how the link device reaches memory.
struct IPv4NetworkConfiguration: Equatable {
    let address: IPv4Address
    let subnetMask: IPv4Address
    let defaultRouter: IPv4Address?
    let domainNameServer: IPv4Address?

    var directedBroadcastAddress: IPv4Address {
        IPv4Address(
            rawValue: (address.rawValue & subnetMask.rawValue)
                | ~subnetMask.rawValue
        )
    }

    func isOnLocalSubnet(_ other: IPv4Address) -> Bool {
        (other.rawValue & subnetMask.rawValue)
            == (address.rawValue & subnetMask.rawValue)
    }
}

struct ARPNeighborEntry: Equatable {
    let protocolAddress: IPv4Address
    let hardwareAddress: MACAddress
    let learnedAtTicks: UInt64
}

/// Eight inline slots keep neighbor resolution deterministic and allocation
/// free. Insertion replaces an existing address, then an empty slot, then the
/// oldest learned entry.
struct BoundedARPNeighborCache {
    static let capacity = 8

    private var slot0: ARPNeighborEntry?
    private var slot1: ARPNeighborEntry?
    private var slot2: ARPNeighborEntry?
    private var slot3: ARPNeighborEntry?
    private var slot4: ARPNeighborEntry?
    private var slot5: ARPNeighborEntry?
    private var slot6: ARPNeighborEntry?
    private var slot7: ARPNeighborEntry?

    init() {}

    var count: Int {
        var result = 0
        var index = 0
        while index < Self.capacity {
            if entry(at: index) != nil { result += 1 }
            index += 1
        }
        return result
    }

    mutating func removeAll() {
        slot0 = nil
        slot1 = nil
        slot2 = nil
        slot3 = nil
        slot4 = nil
        slot5 = nil
        slot6 = nil
        slot7 = nil
    }

    mutating func hardwareAddress(
        for protocolAddress: IPv4Address,
        nowTicks: UInt64,
        lifetimeTicks: UInt64
    ) -> MACAddress? {
        var index = 0
        while index < Self.capacity {
            if let candidate = entry(at: index),
               candidate.protocolAddress == protocolAddress
            {
                if isExpired(
                    candidate,
                    nowTicks: nowTicks,
                    lifetimeTicks: lifetimeTicks
                ) {
                    setEntry(nil, at: index)
                    return nil
                }
                return candidate.hardwareAddress
            }
            index += 1
        }
        return nil
    }

    mutating func insert(
        protocolAddress: IPv4Address,
        hardwareAddress: MACAddress,
        nowTicks: UInt64
    ) {
        guard isUsableUnicast(protocolAddress), hardwareAddress.isUnicast else {
            return
        }
        let replacement = ARPNeighborEntry(
            protocolAddress: protocolAddress,
            hardwareAddress: hardwareAddress,
            learnedAtTicks: nowTicks
        )
        var firstEmpty: Int?
        var oldestIndex = 0
        var oldestTicks = UInt64.max
        var index = 0
        while index < Self.capacity {
            if let candidate = entry(at: index) {
                if candidate.protocolAddress == protocolAddress {
                    setEntry(replacement, at: index)
                    return
                }
                if candidate.learnedAtTicks < oldestTicks {
                    oldestTicks = candidate.learnedAtTicks
                    oldestIndex = index
                }
            } else if firstEmpty == nil {
                firstEmpty = index
            }
            index += 1
        }
        setEntry(replacement, at: firstEmpty ?? oldestIndex)
    }

    func entryForTesting(at index: Int) -> ARPNeighborEntry? {
        entry(at: index)
    }

    private func entry(at index: Int) -> ARPNeighborEntry? {
        switch index {
        case 0: return slot0
        case 1: return slot1
        case 2: return slot2
        case 3: return slot3
        case 4: return slot4
        case 5: return slot5
        case 6: return slot6
        case 7: return slot7
        default: return nil
        }
    }

    private mutating func setEntry(
        _ entry: ARPNeighborEntry?,
        at index: Int
    ) {
        switch index {
        case 0: slot0 = entry
        case 1: slot1 = entry
        case 2: slot2 = entry
        case 3: slot3 = entry
        case 4: slot4 = entry
        case 5: slot5 = entry
        case 6: slot6 = entry
        case 7: slot7 = entry
        default: break
        }
    }

    private func isExpired(
        _ entry: ARPNeighborEntry,
        nowTicks: UInt64,
        lifetimeTicks: UInt64
    ) -> Bool {
        guard lifetimeTicks != UInt64.max else { return false }
        guard nowTicks >= entry.learnedAtTicks else { return false }
        return nowTicks - entry.learnedAtTicks >= lifetimeTicks
    }

    private func isUsableUnicast(_ address: IPv4Address) -> Bool {
        !address.isUnspecified
            && !address.isLimitedBroadcast
            && !address.isMulticast
    }
}

struct IPv4PollingStackTiming: Equatable {
    let arpEntryLifetimeTicks: UInt64
    let arpProbeIntervalTicks: UInt64
    let dhcpRetryPolicy: DHCPv4RetryPolicy

    init(
        arpEntryLifetimeTicks: UInt64,
        arpProbeIntervalTicks: UInt64,
        dhcpRetryPolicy: DHCPv4RetryPolicy
    ) {
        self.arpEntryLifetimeTicks = arpEntryLifetimeTicks
        self.arpProbeIntervalTicks = arpProbeIntervalTicks == 0
            ? 1
            : arpProbeIntervalTicks
        self.dhcpRetryPolicy = dhcpRetryPolicy
    }
}

/// The payload view borrows the caller's RX scratch and is valid only until
/// that storage is reused by another receive operation.
struct IPv4InboundUDPDatagram {
    let sourceAddress: IPv4Address
    let destinationAddress: IPv4Address
    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: UnsafeRawBufferPointer
}

enum IPv4PollingStackEvent {
    case idle
    case linkDown
    case linkIdentityMismatch(expected: MACAddress, actual: MACAddress)
    case receiveScratchTooSmall(required: Int)
    case transmitScratchTooSmall(required: Int)
    case malformedLinkFrame
    case malformedProtocolPacket
    case deviceFault
    case packetIgnored
    case arpNeighborLearned(IPv4Address)
    case arpReplySent(IPv4Address)
    case icmpEchoReplySent(destination: IPv4Address)
    case dhcpDiscoverSent
    case dhcpRequestSent
    case dhcpConfigured(DHCPv4Lease)
    case dhcpRejected(DHCPv4ReceiveRejection)
    case udpDatagram(IPv4InboundUDPDatagram)
    case transmitFailed(NetworkLinkTransmitResult)
}

enum IPv4UDPSendResult: Equatable {
    case sent(frameByteCount: Int)
    case arpRequestSent(target: IPv4Address)
    case awaitingARP(target: IPv4Address, retryAtTicks: UInt64)
    case noNetworkConfiguration
    case noRoute(destination: IPv4Address)
    case payloadTooLarge(requested: Int, maximum: Int)
    case transmitScratchTooSmall(required: Int)
    case linkIdentityMismatch(expected: MACAddress, actual: MACAddress)
    case transmitFailed(NetworkLinkTransmitResult)
}

private enum IPv4StackTransmitOutcome {
    case sent(frameByteCount: Int)
    case scratchTooSmall(required: Int)
    case invalidPacket
    case linkFailure(NetworkLinkTransmitResult)
}

struct IPv4PollingStack {
    static let ethernetHeaderByteCount = EthernetIIProtocol.headerByteCount
    static let ipv4HeaderByteCount = IPv4Protocol.headerByteCount
    static let udpHeaderByteCount = UDPProtocol.headerByteCount
    static let udpPayloadOffset = ethernetHeaderByteCount
        + ipv4HeaderByteCount
        + udpHeaderByteCount

    let hardwareAddress: MACAddress
    let timing: IPv4PollingStackTiming

    private(set) var dhcpClient: DHCPv4Client
    private(set) var networkConfiguration: IPv4NetworkConfiguration?
    private(set) var neighbors = BoundedARPNeighborCache()
    private var nextIPv4Identification: UInt16 = 1
    private var pendingARPAddress: IPv4Address?
    private var nextARPProbeDeadlineTicks: UInt64 = 0

    init(
        hardwareAddress: MACAddress,
        dhcpTransactionIdentifier: UInt32,
        timing: IPv4PollingStackTiming,
        startAtTicks: UInt64 = 0
    ) {
        self.hardwareAddress = hardwareAddress
        self.timing = timing
        dhcpClient = DHCPv4Client(
            hardwareAddress: hardwareAddress,
            transactionIdentifier: dhcpTransactionIdentifier,
            retryPolicy: timing.dhcpRetryPolicy
        )
        dhcpClient.start(nowTicks: startAtTicks)
    }

    mutating func configureStatically(_ configuration: IPv4NetworkConfiguration) {
        networkConfiguration = configuration
        dhcpClient.stop()
        neighbors.removeAll()
        pendingARPAddress = nil
        nextARPProbeDeadlineTicks = 0
    }

    mutating func restartDHCP(nowTicks: UInt64) {
        networkConfiguration = nil
        neighbors.removeAll()
        pendingARPAddress = nil
        nextARPProbeDeadlineTicks = 0
        dhcpClient.start(nowTicks: nowTicks)
    }

    /// Receives at most one frame and transmits at most one response per call.
    /// This bounded work makes the API suitable for cooperative polling and
    /// preemptible kernel network workers alike.
    mutating func poll<Link: NetworkLink>(
        link: inout Link,
        nowTicks: UInt64,
        receiveScratch: UnsafeMutableRawBufferPointer,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4PollingStackEvent {
        guard link.macAddress == hardwareAddress else {
            return .linkIdentityMismatch(
                expected: hardwareAddress,
                actual: link.macAddress
            )
        }
        switch link.linkState {
        case .down:
            return .linkDown
        case .faulted:
            return .deviceFault
        case .up:
            break
        }

        // Service a due control-plane deadline before consuming another RX
        // frame. Otherwise a continuously busy receive ring could starve DHCP
        // retransmission indefinitely.
        if dhcpClient.actionDue(nowTicks: nowTicks) != nil {
            return serviceDHCPDeadline(
                link: &link,
                nowTicks: nowTicks,
                transmitScratch: transmitScratch
            )
        }

        switch link.pollReceive(into: receiveScratch) {
        case .noPacket:
            return .idle
        case .outputTooSmall(let requiredByteCount):
            return .receiveScratchTooSmall(required: requiredByteCount)
        case .malformedFrame:
            return .malformedLinkFrame
        case .deviceFault:
            return .deviceFault
        case .received(let byteCount):
            guard byteCount >= EthernetIIProtocol.headerByteCount,
                  byteCount <= receiveScratch.count,
                  let bytes = Self.rawView(
                      receiveScratch,
                      offset: 0,
                      count: byteCount
                  )
            else {
                return .malformedLinkFrame
            }
            return processReceivedFrame(
                bytes,
                link: &link,
                nowTicks: nowTicks,
                transmitScratch: transmitScratch
            )
        }
    }

    mutating func sendUDP<Link: NetworkLink>(
        link: inout Link,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: UnsafeRawBufferPointer,
        nowTicks: UInt64,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4UDPSendResult {
        guard link.macAddress == hardwareAddress else {
            return .linkIdentityMismatch(
                expected: hardwareAddress,
                actual: link.macAddress
            )
        }
        guard let configuration = networkConfiguration else {
            return .noNetworkConfiguration
        }
        guard !destinationAddress.isUnspecified else {
            return .noRoute(destination: destinationAddress)
        }
        guard NetworkWire.contains(payload, offset: 0, count: payload.count)
        else {
            return .transmitFailed(.invalidFrame)
        }
        let linkIPv4MTU = Int(link.mtu) < EthernetIIProtocol.maximumPayloadByteCount
            ? Int(link.mtu)
            : EthernetIIProtocol.maximumPayloadByteCount
        let maximumPayload = linkIPv4MTU >=
            IPv4Protocol.headerByteCount + UDPProtocol.headerByteCount
            ? linkIPv4MTU
                - IPv4Protocol.headerByteCount
                - UDPProtocol.headerByteCount
            : 0
        guard payload.count <= maximumPayload else {
            return .payloadTooLarge(
                requested: payload.count,
                maximum: maximumPayload
            )
        }

        let destinationHardwareAddress: MACAddress
        if destinationAddress.isLimitedBroadcast
            || destinationAddress == configuration.directedBroadcastAddress
        {
            destinationHardwareAddress = .broadcast
        } else if destinationAddress.isMulticast {
            destinationHardwareAddress = Self.multicastMAC(
                for: destinationAddress
            )
        } else if destinationAddress == configuration.address {
            destinationHardwareAddress = hardwareAddress
        } else {
            let nextHop: IPv4Address
            if configuration.isOnLocalSubnet(destinationAddress) {
                nextHop = destinationAddress
            } else if let router = configuration.defaultRouter,
                      !router.isUnspecified
            {
                nextHop = router
            } else {
                return .noRoute(destination: destinationAddress)
            }

            if let resolved = neighbors.hardwareAddress(
                for: nextHop,
                nowTicks: nowTicks,
                lifetimeTicks: timing.arpEntryLifetimeTicks
            ) {
                destinationHardwareAddress = resolved
            } else if pendingARPAddress == nextHop,
                      nowTicks < nextARPProbeDeadlineTicks
            {
                return .awaitingARP(
                    target: nextHop,
                    retryAtTicks: nextARPProbeDeadlineTicks
                )
            } else {
                let outcome = transmitARPRequest(
                    target: nextHop,
                    sourceAddress: configuration.address,
                    link: &link,
                    transmitScratch: transmitScratch
                )
                switch outcome {
                case .sent:
                    pendingARPAddress = nextHop
                    nextARPProbeDeadlineTicks = Self.saturatingAdd(
                        nowTicks,
                        timing.arpProbeIntervalTicks
                    )
                    return .arpRequestSent(target: nextHop)
                case .scratchTooSmall(let required):
                    return .transmitScratchTooSmall(required: required)
                case .invalidPacket:
                    return .transmitFailed(.invalidFrame)
                case .linkFailure(let failure):
                    return .transmitFailed(failure)
                }
            }
        }

        let outcome = transmitUDPFrame(
            sourceAddress: configuration.address,
            destinationAddress: destinationAddress,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload,
            destinationHardwareAddress: destinationHardwareAddress,
            link: &link,
            transmitScratch: transmitScratch
        )
        switch outcome {
        case .sent(let frameByteCount):
            return .sent(frameByteCount: frameByteCount)
        case .scratchTooSmall(let required):
            return .transmitScratchTooSmall(required: required)
        case .invalidPacket:
            return .transmitFailed(.invalidFrame)
        case .linkFailure(let failure):
            return .transmitFailed(failure)
        }
    }

    private mutating func processReceivedFrame<Link: NetworkLink>(
        _ bytes: UnsafeRawBufferPointer,
        link: inout Link,
        nowTicks: UInt64,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4PollingStackEvent {
        let frame: EthernetIIFrame
        switch EthernetIIFrameDecoder.decode(bytes) {
        case .decoded(let decoded):
            frame = decoded
        case .rejected:
            return .malformedProtocolPacket
        }
        guard frame.destination == hardwareAddress
                || frame.destination.isBroadcast
                || frame.destination.isMulticast
        else {
            return .packetIgnored
        }

        if frame.etherType == .arp {
            return processARP(
                frame,
                link: &link,
                nowTicks: nowTicks,
                transmitScratch: transmitScratch
            )
        }
        guard frame.etherType == .ipv4 else { return .packetIgnored }

        let packet: IPv4DecodedPacket
        switch IPv4Decoder.decode(frame.payload) {
        case .decoded(let decoded):
            packet = decoded
        case .rejected:
            return .malformedProtocolPacket
        }

        if packet.header.protocolNumber == IPv4Protocol.udp {
            let datagram: UDPDatagram
            switch UDPDecoder.decode(
                packet.payload,
                sourceAddress: packet.header.source,
                destinationAddress: packet.header.destination
            ) {
            case .decoded(let decoded):
                datagram = decoded
            case .rejected:
                return .malformedProtocolPacket
            }

            if datagram.sourcePort == 67, datagram.destinationPort == 68 {
                return processDHCPDatagram(
                    datagram.payload,
                    link: &link,
                    nowTicks: nowTicks,
                    transmitScratch: transmitScratch
                )
            }
            guard acceptsConfiguredDestination(packet.header.destination) else {
                return .packetIgnored
            }
            return .udpDatagram(
                IPv4InboundUDPDatagram(
                    sourceAddress: packet.header.source,
                    destinationAddress: packet.header.destination,
                    sourcePort: datagram.sourcePort,
                    destinationPort: datagram.destinationPort,
                    payload: datagram.payload
                )
            )
        }

        guard packet.header.protocolNumber == IPv4Protocol.icmp,
              let configuration = networkConfiguration,
              packet.header.destination == configuration.address,
              Self.isUsableUnicast(packet.header.source)
        else {
            return .packetIgnored
        }
        let echo: ICMPEchoMessage
        switch ICMPEchoDecoder.decode(packet.payload) {
        case .decoded(let decoded):
            echo = decoded
        case .rejected:
            return .malformedProtocolPacket
        }
        guard echo.type == .request, frame.source.isUnicast else {
            return .packetIgnored
        }
        let outcome = transmitICMPEchoReply(
            request: echo,
            sourceAddress: configuration.address,
            destinationAddress: packet.header.source,
            destinationHardwareAddress: frame.source,
            link: &link,
            transmitScratch: transmitScratch
        )
        return event(
            for: outcome,
            success: .icmpEchoReplySent(destination: packet.header.source)
        )
    }

    private mutating func processARP<Link: NetworkLink>(
        _ frame: EthernetIIFrame,
        link: inout Link,
        nowTicks: UInt64,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4PollingStackEvent {
        let packet: ARPEthernetIPv4Packet
        switch ARPEthernetIPv4Decoder.decode(frame.payload) {
        case .decoded(let decoded):
            packet = decoded
        case .rejected:
            return .malformedProtocolPacket
        }
        guard packet.senderHardwareAddress == frame.source,
              packet.senderHardwareAddress.isUnicast
        else {
            return .malformedProtocolPacket
        }

        let canLearn = Self.isUsableUnicast(packet.senderProtocolAddress)
        let configuration = networkConfiguration
        let targetsUs = configuration != nil
            && packet.targetProtocolAddress == configuration?.address
        let replyTargetsUs = packet.operation == .reply
            && targetsUs
            && packet.targetHardwareAddress == hardwareAddress
        let learned = canLearn
            && (packet.operation == .request || replyTargetsUs)
        if learned
        {
            neighbors.insert(
                protocolAddress: packet.senderProtocolAddress,
                hardwareAddress: packet.senderHardwareAddress,
                nowTicks: nowTicks
            )
            if pendingARPAddress == packet.senderProtocolAddress {
                pendingARPAddress = nil
                nextARPProbeDeadlineTicks = 0
            }
        }

        guard packet.operation == .request,
              let configuration,
              packet.targetProtocolAddress == configuration.address
        else {
            return learned
                ? .arpNeighborLearned(packet.senderProtocolAddress)
                : .packetIgnored
        }
        let outcome = transmitARPReply(
            request: packet,
            sourceAddress: configuration.address,
            link: &link,
            transmitScratch: transmitScratch
        )
        return event(
            for: outcome,
            success: .arpReplySent(packet.senderProtocolAddress)
        )
    }

    private mutating func processDHCPDatagram<Link: NetworkLink>(
        _ payload: UnsafeRawBufferPointer,
        link: inout Link,
        nowTicks: UInt64,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4PollingStackEvent {
        switch dhcpClient.receive(payload, nowTicks: nowTicks) {
        case .ignored:
            return .packetIgnored
        case .rejected(let rejection):
            return .dhcpRejected(rejection)
        case .restartedAfterNegativeAcknowledgement:
            return serviceDHCPDeadline(
                link: &link,
                nowTicks: nowTicks,
                transmitScratch: transmitScratch
            )
        case .offered:
            return serviceDHCPDeadline(
                link: &link,
                nowTicks: nowTicks,
                transmitScratch: transmitScratch
            )
        case .bound(let lease):
            networkConfiguration = IPv4NetworkConfiguration(
                address: lease.address,
                subnetMask: lease.subnetMask
                    ?? IPv4Address(255, 255, 255, 255),
                defaultRouter: Self.usableOptionalAddress(lease.router),
                domainNameServer:
                    Self.usableOptionalAddress(lease.domainNameServer)
            )
            neighbors.removeAll()
            pendingARPAddress = nil
            nextARPProbeDeadlineTicks = 0
            return .dhcpConfigured(lease)
        }
    }

    private mutating func serviceDHCPDeadline<Link: NetworkLink>(
        link: inout Link,
        nowTicks: UInt64,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4PollingStackEvent {
        guard let action = dhcpClient.actionDue(nowTicks: nowTicks) else {
            return .idle
        }
        let payloadOffset = Self.udpPayloadOffset
        let payloadByteCount = 300
        guard let payloadOutput = Self.mutableView(
                  transmitScratch,
                  offset: payloadOffset,
                  count: payloadByteCount
              )
        else {
            return .transmitScratchTooSmall(
                required: payloadOffset + payloadByteCount
            )
        }
        let encodedByteCount: Int
        switch dhcpClient.encode(action: action, into: payloadOutput) {
        case .encoded(let byteCount):
            encodedByteCount = byteCount
        case .rejected(.outputBufferTooSmall(let required, _)):
            return .transmitScratchTooSmall(required: payloadOffset + required)
        case .rejected:
            return .malformedProtocolPacket
        }
        guard let payload = Self.rawView(
                  transmitScratch,
                  offset: payloadOffset,
                  count: encodedByteCount
              )
        else {
            return .malformedProtocolPacket
        }
        let outcome = transmitUDPFrame(
            sourceAddress: .unspecified,
            destinationAddress: .limitedBroadcast,
            sourcePort: 68,
            destinationPort: 67,
            payload: payload,
            destinationHardwareAddress: .broadcast,
            link: &link,
            transmitScratch: transmitScratch
        )
        switch outcome {
        case .sent:
            dhcpClient.noteTransmitted(action: action, nowTicks: nowTicks)
            return action == .sendDiscover
                ? .dhcpDiscoverSent
                : .dhcpRequestSent
        case .scratchTooSmall(let required):
            return .transmitScratchTooSmall(required: required)
        case .invalidPacket:
            return .malformedProtocolPacket
        case .linkFailure(let failure):
            return .transmitFailed(failure)
        }
    }

    private mutating func transmitARPRequest<Link: NetworkLink>(
        target: IPv4Address,
        sourceAddress: IPv4Address,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        transmitARPPacket(
            ARPEthernetIPv4Packet(
                operation: .request,
                senderHardwareAddress: hardwareAddress,
                senderProtocolAddress: sourceAddress,
                targetHardwareAddress: .zero,
                targetProtocolAddress: target
            ),
            destinationHardwareAddress: .broadcast,
            link: &link,
            transmitScratch: transmitScratch
        )
    }

    private mutating func transmitARPReply<Link: NetworkLink>(
        request: ARPEthernetIPv4Packet,
        sourceAddress: IPv4Address,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        transmitARPPacket(
            ARPEthernetIPv4Packet(
                operation: .reply,
                senderHardwareAddress: hardwareAddress,
                senderProtocolAddress: sourceAddress,
                targetHardwareAddress: request.senderHardwareAddress,
                targetProtocolAddress: request.senderProtocolAddress
            ),
            destinationHardwareAddress: request.senderHardwareAddress,
            link: &link,
            transmitScratch: transmitScratch
        )
    }

    private mutating func transmitARPPacket<Link: NetworkLink>(
        _ packet: ARPEthernetIPv4Packet,
        destinationHardwareAddress: MACAddress,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        let payloadOffset = Self.ethernetHeaderByteCount
        let payloadByteCount = ARPEthernetIPv4Protocol.packetByteCount
        let minimumRequired = EthernetIIProtocol.minimumFrameByteCountWithoutFCS
        guard transmitScratch.count >= minimumRequired,
              let payloadOutput = Self.mutableView(
                  transmitScratch,
                  offset: payloadOffset,
                  count: payloadByteCount
              )
        else {
            return .scratchTooSmall(required: minimumRequired)
        }
        guard case .encoded = ARPEthernetIPv4Encoder.encode(
                  packet,
                  into: payloadOutput
              ),
              let payload = Self.rawView(
                  transmitScratch,
                  offset: payloadOffset,
                  count: payloadByteCount
              )
        else {
            return .invalidPacket
        }
        return encodeAndTransmitEthernet(
            destinationHardwareAddress: destinationHardwareAddress,
            etherType: .arp,
            payload: payload,
            link: &link,
            transmitScratch: transmitScratch
        )
    }

    private mutating func transmitUDPFrame<Link: NetworkLink>(
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: UnsafeRawBufferPointer,
        destinationHardwareAddress: MACAddress,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        let udpByteCount = UDPProtocol.headerByteCount + payload.count
        let ipv4ByteCount = IPv4Protocol.headerByteCount + udpByteCount
        let frameByteCount = Self.paddedEthernetFrameByteCount(
            payloadByteCount: ipv4ByteCount
        )
        guard ipv4ByteCount <= Int(link.mtu),
              ipv4ByteCount <= EthernetIIProtocol.maximumPayloadByteCount
        else {
            return .invalidPacket
        }
        guard transmitScratch.count >= frameByteCount,
              let udpOutput = Self.mutableView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount
                      + Self.ipv4HeaderByteCount,
                  count: udpByteCount
              ),
              let ipv4HeaderOutput = Self.mutableView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount,
                  count: Self.ipv4HeaderByteCount
              )
        else {
            return .scratchTooSmall(required: frameByteCount)
        }
        guard case .encoded = UDPEncoder.encode(
                  sourceAddress: sourceAddress,
                  destinationAddress: destinationAddress,
                  sourcePort: sourcePort,
                  destinationPort: destinationPort,
                  payload: payload,
                  includeChecksum: true,
                  into: udpOutput
              ),
              case .encoded = IPv4HeaderEncoder.encode(
                  IPv4Header(
                      differentiatedServicesAndECN: 0,
                      identification: takeIPv4Identification(),
                      dontFragment: true,
                      timeToLive: 64,
                      protocolNumber: IPv4Protocol.udp,
                      source: sourceAddress,
                      destination: destinationAddress
                  ),
                  payloadByteCount: udpByteCount,
                  into: ipv4HeaderOutput
              ),
              let ipv4Packet = Self.rawView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount,
                  count: ipv4ByteCount
              )
        else {
            return .invalidPacket
        }
        return encodeAndTransmitEthernet(
            destinationHardwareAddress: destinationHardwareAddress,
            etherType: .ipv4,
            payload: ipv4Packet,
            link: &link,
            transmitScratch: transmitScratch
        )
    }

    private mutating func transmitICMPEchoReply<Link: NetworkLink>(
        request: ICMPEchoMessage,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        destinationHardwareAddress: MACAddress,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        let icmpByteCount = ICMPEchoProtocol.headerByteCount
            + request.payload.count
        let ipv4ByteCount = IPv4Protocol.headerByteCount + icmpByteCount
        let frameByteCount = Self.paddedEthernetFrameByteCount(
            payloadByteCount: ipv4ByteCount
        )
        guard ipv4ByteCount <= Int(link.mtu),
              ipv4ByteCount <= EthernetIIProtocol.maximumPayloadByteCount
        else {
            return .invalidPacket
        }
        guard transmitScratch.count >= frameByteCount,
              let icmpOutput = Self.mutableView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount
                      + Self.ipv4HeaderByteCount,
                  count: icmpByteCount
              ),
              let ipv4HeaderOutput = Self.mutableView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount,
                  count: Self.ipv4HeaderByteCount
              )
        else {
            return .scratchTooSmall(required: frameByteCount)
        }
        guard case .encoded = ICMPEchoEncoder.encode(
                  type: .reply,
                  identifier: request.identifier,
                  sequenceNumber: request.sequenceNumber,
                  payload: request.payload,
                  into: icmpOutput
              ),
              case .encoded = IPv4HeaderEncoder.encode(
                  IPv4Header(
                      differentiatedServicesAndECN: 0,
                      identification: takeIPv4Identification(),
                      dontFragment: true,
                      timeToLive: 64,
                      protocolNumber: IPv4Protocol.icmp,
                      source: sourceAddress,
                      destination: destinationAddress
                  ),
                  payloadByteCount: icmpByteCount,
                  into: ipv4HeaderOutput
              ),
              let ipv4Packet = Self.rawView(
                  transmitScratch,
                  offset: Self.ethernetHeaderByteCount,
                  count: ipv4ByteCount
              )
        else {
            return .invalidPacket
        }
        return encodeAndTransmitEthernet(
            destinationHardwareAddress: destinationHardwareAddress,
            etherType: .ipv4,
            payload: ipv4Packet,
            link: &link,
            transmitScratch: transmitScratch
        )
    }

    private func encodeAndTransmitEthernet<Link: NetworkLink>(
        destinationHardwareAddress: MACAddress,
        etherType: EtherType,
        payload: UnsafeRawBufferPointer,
        link: inout Link,
        transmitScratch: UnsafeMutableRawBufferPointer
    ) -> IPv4StackTransmitOutcome {
        let required = Self.paddedEthernetFrameByteCount(
            payloadByteCount: payload.count
        )
        guard transmitScratch.count >= required else {
            return .scratchTooSmall(required: required)
        }
        let encodedByteCount: Int
        switch EthernetIIFrameEncoder.encode(
            destination: destinationHardwareAddress,
            source: hardwareAddress,
            etherType: etherType,
            payload: payload,
            into: transmitScratch
        ) {
        case .encoded(let byteCount):
            encodedByteCount = byteCount
        case .rejected(.outputBufferTooSmall(let required, _)):
            return .scratchTooSmall(required: required)
        case .rejected:
            return .invalidPacket
        }
        guard let frame = Self.rawView(
                  transmitScratch,
                  offset: 0,
                  count: encodedByteCount
              )
        else {
            return .invalidPacket
        }
        switch link.transmit(frame) {
        case .sent:
            return .sent(frameByteCount: encodedByteCount)
        case let failure:
            return .linkFailure(failure)
        }
    }

    private func acceptsConfiguredDestination(_ address: IPv4Address) -> Bool {
        guard let configuration = networkConfiguration else { return false }
        return address == configuration.address
            || address.isLimitedBroadcast
            || address == configuration.directedBroadcastAddress
            || address.isMulticast
    }

    private mutating func takeIPv4Identification() -> UInt16 {
        let result = nextIPv4Identification
        nextIPv4Identification &+= 1
        return result
    }

    private func event(
        for outcome: IPv4StackTransmitOutcome,
        success: IPv4PollingStackEvent
    ) -> IPv4PollingStackEvent {
        switch outcome {
        case .sent:
            return success
        case .scratchTooSmall(let required):
            return .transmitScratchTooSmall(required: required)
        case .invalidPacket:
            return .malformedProtocolPacket
        case .linkFailure(let failure):
            return .transmitFailed(failure)
        }
    }

    private static func usableOptionalAddress(
        _ address: IPv4Address?
    ) -> IPv4Address? {
        guard let address,
              isUsableUnicast(address)
        else {
            return nil
        }
        return address
    }

    private static func isUsableUnicast(_ address: IPv4Address) -> Bool {
        !address.isUnspecified
            && !address.isLimitedBroadcast
            && !address.isMulticast
    }

    private static func multicastMAC(for address: IPv4Address) -> MACAddress {
        let low23Bits = address.rawValue & 0x007f_ffff
        return MACAddress(
            0x01,
            0x00,
            0x5e,
            UInt8(truncatingIfNeeded: low23Bits >> 16),
            UInt8(truncatingIfNeeded: low23Bits >> 8),
            UInt8(truncatingIfNeeded: low23Bits)
        )
    }

    private static func paddedEthernetFrameByteCount(
        payloadByteCount: Int
    ) -> Int {
        let unpadded = EthernetIIProtocol.headerByteCount + payloadByteCount
        return unpadded < EthernetIIProtocol.minimumFrameByteCountWithoutFCS
            ? EthernetIIProtocol.minimumFrameByteCountWithoutFCS
            : unpadded
    }

    private static func mutableView(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeMutableRawBufferPointer? {
        guard NetworkWire.contains(bytes, offset: offset, count: count) else {
            return nil
        }
        if count == 0 {
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }
        guard let baseAddress = bytes.baseAddress else { return nil }
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
        guard NetworkWire.contains(bytes, offset: offset, count: count) else {
            return nil
        }
        if count == 0 { return UnsafeRawBufferPointer(start: nil, count: 0) }
        guard let baseAddress = bytes.baseAddress else { return nil }
        return UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: offset),
            count: count
        )
    }

    private static func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? UInt64.max : sum
    }
}
