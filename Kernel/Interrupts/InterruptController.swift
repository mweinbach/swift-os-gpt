struct InterruptAcknowledgeToken {
    let rawValue: UInt64
    let interruptID: UInt32
}

protocol InterruptControllerDriver {
    var timerInterruptID: UInt32 { get }

    /// Performs controller-global setup. Only the boot processor may call this
    /// while all participating processors still have IRQs masked.
    func initializeDistributor() -> Bool

    /// Initializes the calling processor's banked CPU interface, PPI state,
    /// and priority mask. This must never rewrite distributor-global state.
    func initializeCurrentProcessor() -> Bool
    func acknowledge() -> InterruptAcknowledgeToken?
    func end(_ token: InterruptAcknowledgeToken)
    func disable(interruptID: UInt32)
    func shutdownCurrentProcessor() -> Bool
    func shutdownDistributor() -> Bool
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
