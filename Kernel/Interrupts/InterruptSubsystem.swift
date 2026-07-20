typealias TimerInterruptHook = @convention(c) (
    UnsafeMutableRawPointer
) -> Void

typealias SynchronousExceptionHook = @convention(c) (
    UnsafeMutableRawPointer
) -> UInt64

private enum ActiveInterruptController {
    case none
    case gicV2(GICv2)
    case gicV3(GICv3)

    var timerInterruptID: UInt32? {
        switch self {
        case .none:
            return nil
        case let .gicV2(driver):
            return driver.timerInterruptID
        case let .gicV3(driver):
            return driver.timerInterruptID
        }
    }

    func acknowledge() -> InterruptAcknowledgeToken? {
        switch self {
        case .none:
            return nil
        case let .gicV2(driver):
            return driver.acknowledge()
        case let .gicV3(driver):
            return driver.acknowledge()
        }
    }

    func end(_ token: InterruptAcknowledgeToken) {
        switch self {
        case .none:
            return
        case let .gicV2(driver):
            driver.end(token)
        case let .gicV3(driver):
            driver.end(token)
        }
    }

    func disable(interruptID: UInt32) {
        switch self {
        case .none:
            return
        case let .gicV2(driver):
            driver.disable(interruptID: interruptID)
        case let .gicV3(driver):
            driver.disable(interruptID: interruptID)
        }
    }

    func initializeCurrentProcessor() -> Bool {
        switch self {
        case .none:
            return false
        case let .gicV2(driver):
            return driver.initializeCurrentProcessor()
        case let .gicV3(driver):
            return driver.initializeCurrentProcessor()
        }
    }

    mutating func shutdown() -> Bool {
        switch self {
        case .none:
            return true
        case let .gicV2(driver):
            let local = driver.shutdownCurrentProcessor()
            let global = driver.shutdownDistributor()
            let result = local && global
            if result { self = .none }
            return result
        case let .gicV3(driver):
            let local = driver.shutdownCurrentProcessor()
            let global = driver.shutdownDistributor()
            let result = local && global
            if result { self = .none }
            return result
        }
    }
}

enum InterruptSubsystem {
    static let exceptionsReadyMarker: StaticString =
        "SWIFTOS:EXCEPTIONS_READY\n"
    static let controllerReadyMarker: StaticString =
        "SWIFTOS:GIC_READY\n"
    static let timerInterruptMarker: StaticString =
        "SWIFTOS:TIMER_IRQ\n"

    private static let maximumAcknowledgementsPerEntry = 32

    private nonisolated(unsafe) static var controller:
        ActiveInterruptController = .none
    private nonisolated(unsafe) static var timer = GenericPhysicalTimer()
    private nonisolated(unsafe) static var timerHook: TimerInterruptHook?
    private nonisolated(unsafe) static var synchronousHook:
        SynchronousExceptionHook?
    private nonisolated(unsafe) static var configured = false

    private nonisolated(unsafe) static var handledTimerCount: UInt64 = 0
    private nonisolated(unsafe) static var unexpectedInterruptCount: UInt64 = 0
    private nonisolated(unsafe) static var saturatedIRQEntryCount: UInt64 = 0
    private nonisolated(unsafe) static var exceptionCount: UInt64 = 0
    private nonisolated(unsafe) static var lastVectorSlot: UInt64 = 0
    private nonisolated(unsafe) static var lastSyndrome: UInt64 = 0
    private nonisolated(unsafe) static var lastFaultAddress: UInt64 = 0

    static var exceptionVectorsInstalled: Bool {
        AArch64.vectorBase != 0
            && MemoryLayout<AArch64ExceptionFrame>.size
                == AArch64ExceptionFrame.byteCount
    }

    static var timerInterruptCount: UInt64 {
        handledTimerCount
    }

    static var unhandledInterruptCount: UInt64 {
        unexpectedInterruptCount
    }

    static var boundedDrainCount: UInt64 {
        saturatedIRQEntryCount
    }

    static var synchronousExceptionCount: UInt64 {
        exceptionCount
    }

    static var lastExceptionDiagnostics: (
        vectorSlot: UInt64,
        syndrome: UInt64,
        faultAddress: UInt64
    ) {
        (lastVectorSlot, lastSyndrome, lastFaultAddress)
    }

    static func configure(
        _ description: InterruptControllerDescription,
        timerInterruptID: UInt32 = GenericPhysicalTimer.architecturalInterruptID
    ) -> Bool {
        switch description {
        case let .gicV2(distributor, cpuInterface):
            return configureGICv2(
                GICv2Configuration(
                    distributor: distributor,
                    cpuInterface: cpuInterface,
                    timerInterruptID: timerInterruptID
                )
            )
        case let .gicV3(distributor, redistributor):
            return configureGICv3(
                GICv3Configuration(
                    distributor: distributor,
                    redistributor: redistributor,
                    timerInterruptID: timerInterruptID
                )
            )
        }
    }

    static func configureGICv2(
        _ configuration: GICv2Configuration
    ) -> Bool {
        prepareForConfiguration()
        let driver = GICv2(configuration: configuration)
        guard driver.initializeDistributor() else { return false }
        guard driver.initializeCurrentProcessor() else {
            _ = driver.shutdownDistributor()
            return false
        }
        controller = .gicV2(driver)
        configured = true
        return true
    }

    static func configureGICv3(
        _ configuration: GICv3Configuration
    ) -> Bool {
        prepareForConfiguration()
        let driver = GICv3(configuration: configuration)
        guard driver.initializeDistributor() else { return false }
        guard driver.initializeCurrentProcessor() else {
            _ = driver.shutdownDistributor()
            return false
        }
        controller = .gicV3(driver)
        configured = true
        return true
    }

    /// Prepares one secondary processor after it has installed the shared EL1
    /// exception vectors and before it publishes ONLINE. IRQs remain masked and
    /// the local physical timer remains stopped. The distributor is never
    /// rewritten, so every participating processor may call this exactly once
    /// without racing the boot processor's global controller setup.
    static func configureCurrentProcessor() -> Bool {
        AArch64.disableIRQs()
        GenericPhysicalTimer.initializeCurrentProcessor()
        guard configured else { return false }
        return controller.initializeCurrentProcessor()
    }

    /// Installs one noncapturing callback. It runs once per acknowledged timer
    /// IRQ after CVAL has been rearmed. The raw pointer addresses one mutable
    /// `AArch64ExceptionFrame` and may be rebound to replace the whole context.
    static func setTimerInterruptHook(_ hook: TimerInterruptHook?) {
        timerHook = hook
    }

    /// Installs a bounded synchronous-exception handler. Returning nonzero
    /// declares the frame handled; returning zero enters the fatal path.
    static func setSynchronousExceptionHook(
        _ hook: SynchronousExceptionHook?
    ) {
        synchronousHook = hook
    }

    static func startPhysicalTimer(
        periodTicks: UInt64,
        unmaskIRQs: Bool = true
    ) -> Bool {
        guard configured,
              controller.timerInterruptID
                == GenericPhysicalTimer.architecturalInterruptID,
              timer.start(periodTicks: periodTicks)
        else {
            return false
        }
        if unmaskIRQs {
            AArch64.enableIRQs()
        }
        return true
    }

    static func stopPhysicalTimer() {
        AArch64.disableIRQs()
        timer.stop()
    }

    /// Final bounded interrupt shutdown for a no-return kernel handoff.
    static func quiesceForKernelRestart() -> Bool {
        AArch64.disableIRQs()
        timer.stop()
        timerHook = nil
        synchronousHook = nil
        guard controller.shutdown() else { return false }
        configured = false
        return true
    }

    fileprivate static func dispatch(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>
    ) {
        guard let kind = frame.pointee.exceptionKind else {
            recordFatalException(frame: frame)
        }
        switch kind {
        case .irq:
            dispatchIRQ(frame: frame)
        case .synchronous:
            if synchronousHook?(UnsafeMutableRawPointer(frame)) != 0 {
                return
            }
            recordFatalException(frame: frame)
        case .fiq, .systemError:
            recordFatalException(frame: frame)
        }
    }

    private static func dispatchIRQ(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>
    ) {
        var acknowledgementCount = 0
        while acknowledgementCount < maximumAcknowledgementsPerEntry,
              let token = controller.acknowledge() {
            if token.interruptID == controller.timerInterruptID {
                timer.rearmAfterInterrupt()
                handledTimerCount &+= 1
                timerHook?(UnsafeMutableRawPointer(frame))
            } else {
                unexpectedInterruptCount &+= 1
                controller.disable(interruptID: token.interruptID)
            }
            controller.end(token)
            acknowledgementCount += 1
        }
        if acknowledgementCount == maximumAcknowledgementsPerEntry {
            saturatedIRQEntryCount &+= 1
        }
    }

    private static func prepareForConfiguration() {
        AArch64.disableIRQs()
        timer.stop()
        controller = .none
        configured = false
        timerHook = nil
        synchronousHook = nil
        handledTimerCount = 0
        unexpectedInterruptCount = 0
        saturatedIRQEntryCount = 0
    }

    private static func recordFatalException(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>
    ) -> Never {
        exceptionCount &+= 1
        lastVectorSlot = frame.pointee.vectorSlot
        lastSyndrome = frame.pointee.syndrome
        lastFaultAddress = frame.pointee.faultAddress
        AArch64.disableIRQs()
        timer.stop()
        while true {
            AArch64.waitForEvent()
        }
    }
}

@_cdecl("swiftos_exception_dispatch")
func swiftOSExceptionDispatch(_ rawFrame: UnsafeMutableRawPointer?) {
    guard let rawFrame else {
        AArch64.disableIRQs()
        while true {
            AArch64.waitForEvent()
        }
    }
    InterruptSubsystem.dispatch(
        frame: rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
    )
}
