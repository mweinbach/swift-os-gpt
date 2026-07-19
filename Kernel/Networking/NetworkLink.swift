/// Board-neutral state reported by a polling layer-two network device.
enum NetworkLinkState: UInt8, Equatable {
    case down
    case up
    case faulted
}

enum NetworkLinkReceiveResult: Equatable {
    case noPacket
    case received(byteCount: Int)
    /// The packet was dropped and its hardware buffer was recycled.
    case outputTooSmall(requiredByteCount: Int)
    case malformedFrame
    case deviceFault
}

enum NetworkLinkTransmitResult: Equatable {
    case sent
    case linkDown
    case invalidFrame
    case timedOut
    case deviceFault
}

/// Allocation-free Ethernet link contract shared by virtual and physical
/// drivers. The caller owns every transmit and receive buffer. Implementations
/// retain no borrowed pointer after either method returns and are expected to
/// be externally serialized by their owning network stack. Frames include the
/// Ethernet header and exclude the hardware frame-check sequence in both
/// directions.
protocol NetworkLink {
    var macAddress: MACAddress { get }
    var mtu: UInt16 { get }
    var linkState: NetworkLinkState { get }

    mutating func pollReceive(
        into output: UnsafeMutableRawBufferPointer
    ) -> NetworkLinkReceiveResult

    mutating func transmit(
        _ frame: UnsafeRawBufferPointer
    ) -> NetworkLinkTransmitResult
}
