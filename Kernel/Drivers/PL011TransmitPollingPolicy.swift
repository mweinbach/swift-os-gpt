enum PL011TransmitPollDecision: Equatable {
    case ready
    case retry
    case timedOut
}

protocol PL011TransmitRegisterAccess {
    mutating func readTransmitFlags() -> UInt32
    mutating func writeTransmitData(_ byte: UInt8)
    mutating func relaxTransmitPoll()
}

/// Bounds one UART byte wait without coupling the policy to MMIO. The final
/// full-FIFO observation consumes the budget and fails instead of spinning.
struct PL011TransmitPollingPolicy {
    static let productionMaximumFullObservations: UInt32 = 65_536

    private let maximumFullObservations: UInt32
    private(set) var fullObservationCount: UInt32 = 0

    init(
        maximumFullObservations: UInt32 =
            Self.productionMaximumFullObservations
    ) {
        self.maximumFullObservations = maximumFullObservations
    }

    mutating func observe(transmitFIFOIsFull: Bool) ->
        PL011TransmitPollDecision {
        guard transmitFIFOIsFull else { return .ready }
        guard fullObservationCount < maximumFullObservations else {
            return .timedOut
        }
        fullObservationCount &+= 1
        return fullObservationCount < maximumFullObservations
            ? .retry
            : .timedOut
    }
}

func transmitPL011Byte<Registers: PL011TransmitRegisterAccess>(
    _ byte: UInt8,
    registers: inout Registers,
    transmitFIFOFullMask: UInt32,
    maximumFullObservations: UInt32 =
        PL011TransmitPollingPolicy.productionMaximumFullObservations
) -> Bool {
    var polling = PL011TransmitPollingPolicy(
        maximumFullObservations: maximumFullObservations
    )
    while true {
        let fifoIsFull = registers.readTransmitFlags()
            & transmitFIFOFullMask != 0
        switch polling.observe(transmitFIFOIsFull: fifoIsFull) {
        case .ready:
            registers.writeTransmitData(byte)
            return true
        case .retry:
            registers.relaxTransmitPoll()
        case .timedOut:
            return false
        }
    }
}
