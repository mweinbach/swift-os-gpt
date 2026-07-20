typealias TimerInterruptHook = @convention(c) (
    UnsafeMutableRawPointer
) -> Void

typealias SynchronousExceptionHook = @convention(c) (
    UnsafeMutableRawPointer
) -> UInt64

/// Software state for one architectural processor-local interrupt context.
/// Four distinct static instances are used below so no processor ever takes
/// an `inout` access to storage concurrently owned by another processor.
private struct ProcessorLocalInterruptState {
    var timer = GenericPhysicalTimer()
    var timerHook: TimerInterruptHook?
    var synchronousHook: SynchronousExceptionHook?
    var isConfigured = false
    var handledTimerCount: UInt64 = 0
    var unexpectedInterruptCount: UInt64 = 0
    var saturatedIRQEntryCount: UInt64 = 0
    var exceptionCount: UInt64 = 0
    var lastVectorSlot: UInt64 = 0
    var lastSyndrome: UInt64 = 0
    var lastFaultAddress: UInt64 = 0
}

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
    private static let maximumProcessorCount = 4

    private nonisolated(unsafe) static var controller:
        ActiveInterruptController = .none
    private nonisolated(unsafe) static var configured = false
    private nonisolated(unsafe) static var configuredProcessorCount = 0

    private nonisolated(unsafe) static var processor0 =
        ProcessorLocalInterruptState()
    private nonisolated(unsafe) static var processor1 =
        ProcessorLocalInterruptState()
    private nonisolated(unsafe) static var processor2 =
        ProcessorLocalInterruptState()
    private nonisolated(unsafe) static var processor3 =
        ProcessorLocalInterruptState()

    static var exceptionVectorsInstalled: Bool {
        AArch64.vectorBase != 0
            && MemoryLayout<AArch64ExceptionFrame>.size
                == AArch64ExceptionFrame.byteCount
    }

    static var timerInterruptCount: UInt64 {
        guard let index = currentProcessorIndex() else { return 0 }
        return timerInterruptCount(logicalProcessorID: index) ?? 0
    }

    static func timerInterruptCount(
        logicalProcessorID: Int
    ) -> UInt64? {
        guard validConfiguredProcessor(logicalProcessorID),
              processorIsConfigured(logicalProcessorID)
        else { return nil }
        switch logicalProcessorID {
        case 0: return processor0.handledTimerCount
        case 1: return processor1.handledTimerCount
        case 2: return processor2.handledTimerCount
        case 3: return processor3.handledTimerCount
        default: return nil
        }
    }

    static var unhandledInterruptCount: UInt64 {
        guard let index = currentProcessorIndex() else { return 0 }
        switch index {
        case 0: return processor0.unexpectedInterruptCount
        case 1: return processor1.unexpectedInterruptCount
        case 2: return processor2.unexpectedInterruptCount
        case 3: return processor3.unexpectedInterruptCount
        default: return 0
        }
    }

    static var boundedDrainCount: UInt64 {
        guard let index = currentProcessorIndex() else { return 0 }
        switch index {
        case 0: return processor0.saturatedIRQEntryCount
        case 1: return processor1.saturatedIRQEntryCount
        case 2: return processor2.saturatedIRQEntryCount
        case 3: return processor3.saturatedIRQEntryCount
        default: return 0
        }
    }

    static var synchronousExceptionCount: UInt64 {
        guard let index = currentProcessorIndex() else { return 0 }
        switch index {
        case 0: return processor0.exceptionCount
        case 1: return processor1.exceptionCount
        case 2: return processor2.exceptionCount
        case 3: return processor3.exceptionCount
        default: return 0
        }
    }

    static var lastExceptionDiagnostics: (
        vectorSlot: UInt64,
        syndrome: UInt64,
        faultAddress: UInt64
    ) {
        guard let index = currentProcessorIndex() else { return (0, 0, 0) }
        switch index {
        case 0:
            return (
                processor0.lastVectorSlot,
                processor0.lastSyndrome,
                processor0.lastFaultAddress
            )
        case 1:
            return (
                processor1.lastVectorSlot,
                processor1.lastSyndrome,
                processor1.lastFaultAddress
            )
        case 2:
            return (
                processor2.lastVectorSlot,
                processor2.lastSyndrome,
                processor2.lastFaultAddress
            )
        case 3:
            return (
                processor3.lastVectorSlot,
                processor3.lastSyndrome,
                processor3.lastFaultAddress
            )
        default:
            return (0, 0, 0)
        }
    }

    static func configure(
        _ description: InterruptControllerDescription,
        timerInterruptID: UInt32,
        processorCount: Int
    ) -> Bool {
        guard AArch64.logicalProcessorID == 0,
              processorCount > 0,
              processorCount <= maximumProcessorCount
        else {
            return false
        }
        switch description {
        case let .gicV2(distributor, cpuInterface):
            return configureGICv2(
                GICv2Configuration(
                    distributor: distributor,
                    cpuInterface: cpuInterface,
                    timerInterruptID: timerInterruptID
                ),
                processorCount: processorCount
            )
        case let .gicV3(distributor, redistributor):
            return configureGICv3(
                GICv3Configuration(
                    distributor: distributor,
                    redistributor: redistributor,
                    timerInterruptID: timerInterruptID
                ),
                processorCount: processorCount
            )
        }
    }

    static func configureGICv2(
        _ configuration: GICv2Configuration,
        processorCount: Int
    ) -> Bool {
        guard prepareForConfiguration(processorCount: processorCount) else {
            return false
        }
        let driver = GICv2(configuration: configuration)
        guard driver.initializeDistributor() else {
            abandonConfiguration()
            return false
        }
        guard driver.initializeCurrentProcessor() else {
            _ = driver.shutdownDistributor()
            abandonConfiguration()
            return false
        }
        controller = .gicV2(driver)
        configured = true
        processor0.isConfigured = true
        return true
    }

    static func configureGICv3(
        _ configuration: GICv3Configuration,
        processorCount: Int
    ) -> Bool {
        guard prepareForConfiguration(processorCount: processorCount) else {
            return false
        }
        let driver = GICv3(configuration: configuration)
        guard driver.initializeDistributor() else {
            abandonConfiguration()
            return false
        }
        guard driver.initializeCurrentProcessor() else {
            _ = driver.shutdownDistributor()
            abandonConfiguration()
            return false
        }
        controller = .gicV3(driver)
        configured = true
        processor0.isConfigured = true
        return true
    }

    /// Prepares one secondary processor after it has installed the shared EL1
    /// exception vectors and before it publishes ONLINE. IRQs remain masked and
    /// the local physical timer remains stopped. The distributor is never
    /// rewritten, so every participating processor may call this exactly once
    /// without racing the boot processor's global controller setup.
    static func configureCurrentProcessor(
        logicalProcessorID: UInt64
    ) -> Bool {
        AArch64.disableIRQs()
        // Fail closed even when the PSCI context does not match TPIDR_EL1.
        GenericPhysicalTimer.initializeCurrentProcessor()
        guard configured,
              AArch64.logicalProcessorID == logicalProcessorID,
              logicalProcessorID > 0,
              logicalProcessorID < UInt64(configuredProcessorCount),
              logicalProcessorID <= UInt64(Int.max)
        else {
            return false
        }
        let index = Int(logicalProcessorID)
        guard !processorIsConfigured(index),
              controller.initializeCurrentProcessor()
        else {
            return false
        }
        resetProcessorState(index)
        setProcessorConfigured(index)
        return true
    }

    /// Installs one noncapturing callback. It runs once per acknowledged timer
    /// IRQ after CVAL has been rearmed, the count published, and the controller
    /// token ended. The raw pointer addresses one live mutable
    /// `AArch64ExceptionFrame` and may be rebound to replace the whole context.
    @discardableResult
    static func setTimerInterruptHook(_ hook: TimerInterruptHook?) -> Bool {
        guard let index = currentProcessorIndex(),
              processorIsConfigured(index)
        else {
            return false
        }
        switch index {
        case 0: processor0.timerHook = hook
        case 1: processor1.timerHook = hook
        case 2: processor2.timerHook = hook
        case 3: processor3.timerHook = hook
        default: return false
        }
        return true
    }

    /// Installs a bounded synchronous-exception handler. Returning nonzero
    /// declares the frame handled; returning zero enters the fatal path.
    @discardableResult
    static func setSynchronousExceptionHook(
        _ hook: SynchronousExceptionHook?
    ) -> Bool {
        guard let index = currentProcessorIndex(),
              processorIsConfigured(index)
        else {
            return false
        }
        switch index {
        case 0: processor0.synchronousHook = hook
        case 1: processor1.synchronousHook = hook
        case 2: processor2.synchronousHook = hook
        case 3: processor3.synchronousHook = hook
        default: return false
        }
        return true
    }

    static func startPhysicalTimer(
        periodTicks: UInt64,
        unmaskIRQs: Bool = true
    ) -> Bool {
        guard configured,
              controller.timerInterruptID != nil,
              let index = currentProcessorIndex(),
              processorIsConfigured(index),
              startTimer(index, periodTicks: periodTicks)
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
        guard let index = rawCurrentProcessorIndex() else {
            AArch64.disablePhysicalTimer()
            return
        }
        stopTimer(index)
    }

    /// Final bounded interrupt shutdown for a no-return kernel handoff.
    static func quiesceForKernelRestart() -> Bool {
        guard AArch64.logicalProcessorID == 0 else { return false }
        AArch64.disableIRQs()
        processor0.timer.stop()
        processor0.timerHook = nil
        processor0.synchronousHook = nil
        guard controller.shutdown() else { return false }
        configured = false
        configuredProcessorCount = 0
        processor0 = ProcessorLocalInterruptState()
        processor1 = ProcessorLocalInterruptState()
        processor2 = ProcessorLocalInterruptState()
        processor3 = ProcessorLocalInterruptState()
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
            if let hook = currentSynchronousHook() {
                if hook(UnsafeMutableRawPointer(frame)) != 0 {
                    return
                }
            }
            recordFatalException(frame: frame)
        case .fiq, .systemError:
            recordFatalException(frame: frame)
        }
    }

    private static func dispatchIRQ(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>
    ) {
        guard let processorIndex = currentProcessorIndex(),
              processorIsConfigured(processorIndex)
        else {
            recordFatalException(frame: frame)
        }
        var acknowledgementCount = 0
        while acknowledgementCount < maximumAcknowledgementsPerEntry,
              let token = controller.acknowledge() {
            var timerHook: TimerInterruptHook?
            if token.interruptID == controller.timerInterruptID {
                // Rearm and update the current processor's state first, then
                // copy its callback out. No inout access remains live while
                // arbitrary hook code executes in exception context.
                timerHook = rearmTimerAndRecordInterrupt(processorIndex)
            } else {
                recordUnexpectedInterrupt(processorIndex)
                controller.disable(interruptID: token.interruptID)
            }
            controller.end(token)
            acknowledgementCount += 1
            // End and deactivate the PPI before invoking policy. A timer hook
            // may enter a no-return CPU_OFF path, while a returning hook may
            // still replace the live exception frame before exception return.
            timerHook?(UnsafeMutableRawPointer(frame))
        }
        if acknowledgementCount == maximumAcknowledgementsPerEntry {
            recordSaturatedEntry(processorIndex)
        }
    }

    private static func prepareForConfiguration(
        processorCount: Int
    ) -> Bool {
        guard AArch64.logicalProcessorID == 0,
              processorCount > 0,
              processorCount <= maximumProcessorCount
        else {
            return false
        }
        AArch64.disableIRQs()
        processor0.timer.stop()
        controller = .none
        configured = false
        configuredProcessorCount = processorCount
        processor0 = ProcessorLocalInterruptState()
        processor1 = ProcessorLocalInterruptState()
        processor2 = ProcessorLocalInterruptState()
        processor3 = ProcessorLocalInterruptState()
        return true
    }

    private static func abandonConfiguration() {
        controller = .none
        configured = false
        configuredProcessorCount = 0
    }

    private static func recordFatalException(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>
    ) -> Never {
        if let index = rawCurrentProcessorIndex() {
            switch index {
            case 0:
                processor0.exceptionCount &+= 1
                processor0.lastVectorSlot = frame.pointee.vectorSlot
                processor0.lastSyndrome = frame.pointee.syndrome
                processor0.lastFaultAddress = frame.pointee.faultAddress
            case 1:
                processor1.exceptionCount &+= 1
                processor1.lastVectorSlot = frame.pointee.vectorSlot
                processor1.lastSyndrome = frame.pointee.syndrome
                processor1.lastFaultAddress = frame.pointee.faultAddress
            case 2:
                processor2.exceptionCount &+= 1
                processor2.lastVectorSlot = frame.pointee.vectorSlot
                processor2.lastSyndrome = frame.pointee.syndrome
                processor2.lastFaultAddress = frame.pointee.faultAddress
            case 3:
                processor3.exceptionCount &+= 1
                processor3.lastVectorSlot = frame.pointee.vectorSlot
                processor3.lastSyndrome = frame.pointee.syndrome
                processor3.lastFaultAddress = frame.pointee.faultAddress
            default:
                break
            }
        }
        AArch64.disableIRQs()
        if let index = rawCurrentProcessorIndex() {
            stopTimer(index)
        } else {
            AArch64.disablePhysicalTimer()
        }
        while true {
            AArch64.waitForEvent()
        }
    }

    private static func rawCurrentProcessorIndex() -> Int? {
        let raw = AArch64.logicalProcessorID
        guard raw < UInt64(maximumProcessorCount),
              raw <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(raw)
    }

    private static func currentProcessorIndex() -> Int? {
        guard let index = rawCurrentProcessorIndex(),
              validConfiguredProcessor(index),
              processorIsConfigured(index)
        else {
            return nil
        }
        return index
    }

    private static func validConfiguredProcessor(_ index: Int) -> Bool {
        configured
            && index >= 0
            && index < configuredProcessorCount
            && index < maximumProcessorCount
    }

    private static func processorIsConfigured(_ index: Int) -> Bool {
        switch index {
        case 0: return processor0.isConfigured
        case 1: return processor1.isConfigured
        case 2: return processor2.isConfigured
        case 3: return processor3.isConfigured
        default: return false
        }
    }

    private static func setProcessorConfigured(_ index: Int) {
        switch index {
        case 0: processor0.isConfigured = true
        case 1: processor1.isConfigured = true
        case 2: processor2.isConfigured = true
        case 3: processor3.isConfigured = true
        default: break
        }
    }

    private static func resetProcessorState(_ index: Int) {
        switch index {
        case 0: processor0 = ProcessorLocalInterruptState()
        case 1: processor1 = ProcessorLocalInterruptState()
        case 2: processor2 = ProcessorLocalInterruptState()
        case 3: processor3 = ProcessorLocalInterruptState()
        default: break
        }
    }

    private static func startTimer(
        _ index: Int,
        periodTicks: UInt64
    ) -> Bool {
        switch index {
        case 0: return processor0.timer.start(periodTicks: periodTicks)
        case 1: return processor1.timer.start(periodTicks: periodTicks)
        case 2: return processor2.timer.start(periodTicks: periodTicks)
        case 3: return processor3.timer.start(periodTicks: periodTicks)
        default: return false
        }
    }

    private static func stopTimer(_ index: Int) {
        switch index {
        case 0: processor0.timer.stop()
        case 1: processor1.timer.stop()
        case 2: processor2.timer.stop()
        case 3: processor3.timer.stop()
        default: AArch64.disablePhysicalTimer()
        }
    }

    private static func rearmTimerAndRecordInterrupt(
        _ index: Int
    ) -> TimerInterruptHook? {
        switch index {
        case 0:
            processor0.timer.rearmAfterInterrupt()
            processor0.handledTimerCount &+= 1
            return processor0.timerHook
        case 1:
            processor1.timer.rearmAfterInterrupt()
            processor1.handledTimerCount &+= 1
            return processor1.timerHook
        case 2:
            processor2.timer.rearmAfterInterrupt()
            processor2.handledTimerCount &+= 1
            return processor2.timerHook
        case 3:
            processor3.timer.rearmAfterInterrupt()
            processor3.handledTimerCount &+= 1
            return processor3.timerHook
        default:
            return nil
        }
    }

    private static func recordUnexpectedInterrupt(_ index: Int) {
        switch index {
        case 0: processor0.unexpectedInterruptCount &+= 1
        case 1: processor1.unexpectedInterruptCount &+= 1
        case 2: processor2.unexpectedInterruptCount &+= 1
        case 3: processor3.unexpectedInterruptCount &+= 1
        default: break
        }
    }

    private static func recordSaturatedEntry(_ index: Int) {
        switch index {
        case 0: processor0.saturatedIRQEntryCount &+= 1
        case 1: processor1.saturatedIRQEntryCount &+= 1
        case 2: processor2.saturatedIRQEntryCount &+= 1
        case 3: processor3.saturatedIRQEntryCount &+= 1
        default: break
        }
    }

    private static func currentSynchronousHook() -> SynchronousExceptionHook? {
        guard let index = currentProcessorIndex(),
              processorIsConfigured(index)
        else {
            return nil
        }
        switch index {
        case 0: return processor0.synchronousHook
        case 1: return processor1.synchronousHook
        case 2: return processor2.synchronousHook
        case 3: return processor3.synchronousHook
        default: return nil
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
