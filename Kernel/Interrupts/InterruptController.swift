struct InterruptAcknowledgeToken {
    let rawValue: UInt64
    let interruptID: UInt32
}

protocol InterruptControllerDriver {
    var timerInterruptID: UInt32 { get }

    mutating func initialize() -> Bool
    func acknowledge() -> InterruptAcknowledgeToken?
    func end(_ token: InterruptAcknowledgeToken)
    func disable(interruptID: UInt32)
}

struct GICv2Configuration {
    let distributor: DeviceResource
    let cpuInterface: DeviceResource
    let timerInterruptID: UInt32

    init(
        distributor: DeviceResource,
        cpuInterface: DeviceResource,
        timerInterruptID: UInt32 = 30
    ) {
        self.distributor = distributor
        self.cpuInterface = cpuInterface
        self.timerInterruptID = timerInterruptID
    }
}

struct GICv3Configuration {
    let distributor: DeviceResource
    let redistributor: DeviceResource
    let timerInterruptID: UInt32

    init(
        distributor: DeviceResource,
        redistributor: DeviceResource,
        timerInterruptID: UInt32 = 30
    ) {
        self.distributor = distributor
        self.redistributor = redistributor
        self.timerInterruptID = timerInterruptID
    }
}
