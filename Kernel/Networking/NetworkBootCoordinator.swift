/// Fatal failures shared by virtual and physical polling links. Passive
/// link-down remains recoverable; transmit link-down follows the platform's
/// explicit bootstrap policy.
enum NetworkPollingFault {
    case device
    case identity
    case scratch
    case transmitLinkDown
    case invalidTransmitFrame
    case transmitTimeout
    case transmitDevice
}

enum NetworkBootstrapPollOutcome {
    case configured
    case timedOut
    case fault(NetworkPollingFault)
}

enum NetworkLinkDownPolicy: Equatable {
    case recoverable
    case fault
}

/// Counter access remains injected so the shared DHCP bootstrap policy does
/// not know which CPU or timer implementation backs a platform.
protocol NetworkBootClock {
    mutating func counterValue() -> UInt64
    mutating func spinWaitHint()
}

struct AArch64NetworkBootClock: NetworkBootClock {
    @inline(__always)
    mutating func counterValue() -> UInt64 {
        AArch64.counterValue
    }

    @inline(__always)
    mutating func spinWaitHint() {
        AArch64.spinHint()
    }
}

/// Allocation-free IPv4/DHCP boot policy shared by every `NetworkLink`.
/// Register discovery, DMA translation, and device initialization remain below
/// this boundary in their respective virtual or physical drivers.
enum NetworkBootCoordinator {
    static func makeService<Link: NetworkLink>(
        link: Link,
        receiveScratchAddress: UInt64,
        transmitScratchAddress: UInt64,
        scratchByteCount: UInt64,
        counterFrequency: UInt64,
        startTicks: UInt64
    ) -> PollingNetworkService<Link>? {
        guard counterFrequency > 0,
              counterFrequency <= UInt64.max / 300
        else {
            return nil
        }
        let packedMAC = packedMACAddress(link.macAddress)
        let transactionIdentifier = UInt32(
            truncatingIfNeeded: startTicks ^ packedMAC ^ (packedMAC >> 32)
        )
        let retryTicks = max(counterFrequency / 10, 1)
        let maximumRetryTicks = max(counterFrequency, retryTicks)
        return PollingNetworkService(
            link: link,
            receiveScratchAddress: receiveScratchAddress,
            transmitScratchAddress: transmitScratchAddress,
            scratchByteCount: scratchByteCount,
            dhcpTransactionIdentifier: transactionIdentifier,
            timing: IPv4PollingStackTiming(
                arpEntryLifetimeTicks: counterFrequency * 300,
                arpProbeIntervalTicks: counterFrequency,
                dhcpRetryPolicy: DHCPv4RetryPolicy(
                    initialRetryTicks: retryTicks,
                    maximumRetryTicks: maximumRetryTicks
                )
            ),
            startAtTicks: startTicks
        )
    }

    static func poll<Link: NetworkLink, Clock: NetworkBootClock>(
        service: inout PollingNetworkService<Link>,
        startTicks: UInt64,
        deadlineDeltaTicks: UInt64,
        linkDownPolicy: NetworkLinkDownPolicy,
        clock: inout Clock
    ) -> NetworkBootstrapPollOutcome {
        guard deadlineDeltaTicks > 0 else { return .timedOut }
        while true {
            let nowTicks = clock.counterValue()
            guard nowTicks &- startTicks < deadlineDeltaTicks else {
                break
            }
            let event = service.poll(nowTicks: nowTicks)
            if service.networkConfiguration != nil {
                return .configured
            }
            if let fault = pollingFault(
                for: event,
                linkDownPolicy: linkDownPolicy
            ) {
                return .fault(fault)
            }
            clock.spinWaitHint()
        }
        return service.networkConfiguration == nil ? .timedOut : .configured
    }

    static func pollingFault(
        for event: IPv4PollingStackEvent,
        linkDownPolicy: NetworkLinkDownPolicy
    ) -> NetworkPollingFault? {
        switch event {
        case .deviceFault:
            return .device
        case .linkIdentityMismatch:
            return .identity
        case .receiveScratchTooSmall, .transmitScratchTooSmall:
            return .scratch
        case .transmitFailed(let failure):
            switch failure {
            case .sent:
                return nil
            case .linkDown:
                return linkDownPolicy == .fault ? .transmitLinkDown : nil
            case .invalidFrame:
                return .invalidTransmitFrame
            case .timedOut:
                return .transmitTimeout
            case .deviceFault:
                return .transmitDevice
            }
        default:
            return nil
        }
    }

    static func packedMACAddress(_ address: MACAddress) -> UInt64 {
        UInt64(address.octet0) << 40
            | UInt64(address.octet1) << 32
            | UInt64(address.octet2) << 24
            | UInt64(address.octet3) << 16
            | UInt64(address.octet4) << 8
            | UInt64(address.octet5)
    }
}
