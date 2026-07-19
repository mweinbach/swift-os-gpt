/// Owns one layer-two device and its board-neutral IPv4 state machine.
///
/// Scratch storage is supplied as stable kernel addresses so the service can
/// live in static runtime state without retaining a borrowed Swift buffer.
/// Every call performs bounded work and retains no packet view after return.
struct PollingNetworkService<Link: NetworkLink> {
    private(set) var link: Link
    private(set) var stack: IPv4PollingStack

    let receiveScratchAddress: UInt64
    let transmitScratchAddress: UInt64
    let scratchByteCount: Int

    init?(
        link: Link,
        receiveScratchAddress: UInt64,
        transmitScratchAddress: UInt64,
        scratchByteCount: UInt64,
        dhcpTransactionIdentifier: UInt32,
        timing: IPv4PollingStackTiming,
        startAtTicks: UInt64
    ) {
        let minimumScratchByteCount = EthernetIIProtocol.headerByteCount
            + Int(link.mtu)
        guard link.macAddress.isUnicast,
              scratchByteCount >= UInt64(minimumScratchByteCount),
              scratchByteCount <= UInt64(Int.max),
              receiveScratchAddress > 0,
              transmitScratchAddress > 0,
              scratchByteCount <= UInt64.max - receiveScratchAddress,
              scratchByteCount <= UInt64.max - transmitScratchAddress,
              receiveScratchAddress + scratchByteCount
                    <= transmitScratchAddress
                || transmitScratchAddress + scratchByteCount
                    <= receiveScratchAddress,
              receiveScratchAddress <= UInt64(UInt.max),
              transmitScratchAddress <= UInt64(UInt.max),
              UnsafeMutableRawPointer(
                  bitPattern: UInt(receiveScratchAddress)
              ) != nil,
              UnsafeMutableRawPointer(
                  bitPattern: UInt(transmitScratchAddress)
              ) != nil
        else {
            return nil
        }

        self.link = link
        stack = IPv4PollingStack(
            hardwareAddress: link.macAddress,
            dhcpTransactionIdentifier: dhcpTransactionIdentifier,
            timing: timing,
            startAtTicks: startAtTicks
        )
        self.receiveScratchAddress = receiveScratchAddress
        self.transmitScratchAddress = transmitScratchAddress
        self.scratchByteCount = Int(scratchByteCount)
    }

    var networkConfiguration: IPv4NetworkConfiguration? {
        stack.networkConfiguration
    }

    mutating func poll(nowTicks: UInt64) -> IPv4PollingStackEvent {
        guard let receive = scratch(at: receiveScratchAddress),
              let transmit = scratch(at: transmitScratchAddress)
        else {
            return .deviceFault
        }
        return stack.poll(
            link: &link,
            nowTicks: nowTicks,
            receiveScratch: receive,
            transmitScratch: transmit
        )
    }

    mutating func sendUDP(
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: UnsafeRawBufferPointer,
        nowTicks: UInt64
    ) -> IPv4UDPSendResult {
        guard let transmit = scratch(at: transmitScratchAddress) else {
            return .transmitScratchTooSmall(required: scratchByteCount)
        }
        return stack.sendUDP(
            link: &link,
            destinationAddress: destinationAddress,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload,
            nowTicks: nowTicks,
            transmitScratch: transmit
        )
    }

    private func scratch(
        at address: UInt64
    ) -> UnsafeMutableRawBufferPointer? {
        guard let base = UnsafeMutableRawPointer(bitPattern: UInt(address))
        else { return nil }
        return UnsafeMutableRawBufferPointer(
            start: base,
            count: scratchByteCount
        )
    }
}
