struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

struct InterruptAcknowledgeToken {
    let rawValue: UInt64
    let interruptID: UInt32
}

struct GICv2Configuration {
    let distributor: DeviceResource
    let cpuInterface: DeviceResource
    let timerInterruptID: UInt32
}

struct GICv3Configuration {
    let distributor: DeviceResource
    let redistributor: DeviceResource
    let timerInterruptID: UInt32
}

enum InterruptControllerDescription {
    case gicV2(distributor: DeviceResource, cpuInterface: DeviceResource)
    case gicV3(distributor: DeviceResource, redistributor: DeviceResource)
}

private struct TestEndOfInterrupt: Equatable {
    let cpu: Int
    let rawValue: UInt64
}

private enum TestHardware {
    nonisolated(unsafe) static var currentCPU = 0
    nonisolated(unsafe) static var pendingInterrupts = [[UInt64]](
        repeating: [],
        count: 4
    )
    nonisolated(unsafe) static var localInitializationCounts = [Int](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var physicalTimerInitializationCounts = [Int](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var counterValues = [UInt64](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var timerDeadlines = [UInt64](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var timerDisableCounts = [Int](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var irqEnabled = [Bool](
        repeating: false,
        count: 4
    )
    nonisolated(unsafe) static var disabledInterrupts = [[UInt32]](
        repeating: [],
        count: 4
    )
    nonisolated(unsafe) static var ends: [TestEndOfInterrupt] = []
    nonisolated(unsafe) static var distributorInitializationCount = 0
    nonisolated(unsafe) static var localShutdownCount = 0
    nonisolated(unsafe) static var distributorShutdownCount = 0
    nonisolated(unsafe) static var hookCounts = [Int](
        repeating: 0,
        count: 4
    )
    nonisolated(unsafe) static var replacementHookCount = 0
    nonisolated(unsafe) static var replacementInstallationSucceeded = false
    nonisolated(unsafe) static var countObservedInsideHook: UInt64?

    static func reset() {
        currentCPU = 0
        pendingInterrupts = [[UInt64]](repeating: [], count: 4)
        localInitializationCounts = [Int](repeating: 0, count: 4)
        physicalTimerInitializationCounts = [Int](repeating: 0, count: 4)
        counterValues = [UInt64](repeating: 0, count: 4)
        timerDeadlines = [UInt64](repeating: 0, count: 4)
        timerDisableCounts = [Int](repeating: 0, count: 4)
        irqEnabled = [Bool](repeating: false, count: 4)
        disabledInterrupts = [[UInt32]](repeating: [], count: 4)
        ends.removeAll(keepingCapacity: true)
        distributorInitializationCount = 0
        localShutdownCount = 0
        distributorShutdownCount = 0
        hookCounts = [Int](repeating: 0, count: 4)
        replacementHookCount = 0
        replacementInstallationSucceeded = false
        countObservedInsideHook = nil
    }

    static func enqueueTimerInterrupt(
        cpu: Int,
        interruptID: UInt32
    ) {
        let sourceCPU = UInt64(cpu) << 10
        pendingInterrupts[cpu].append(sourceCPU | UInt64(interruptID))
    }

    static func acknowledge() -> InterruptAcknowledgeToken? {
        guard !pendingInterrupts[currentCPU].isEmpty else { return nil }
        let rawValue = pendingInterrupts[currentCPU].removeFirst()
        return InterruptAcknowledgeToken(
            rawValue: rawValue,
            interruptID: UInt32(rawValue & 0x3ff)
        )
    }
}

struct GICv2 {
    private let configuration: GICv2Configuration

    var timerInterruptID: UInt32 {
        configuration.timerInterruptID
    }

    init(configuration: GICv2Configuration) {
        self.configuration = configuration
    }

    func initializeDistributor() -> Bool {
        guard configuration.distributor.length > 0 else { return false }
        TestHardware.distributorInitializationCount += 1
        return true
    }

    func initializeCurrentProcessor() -> Bool {
        guard configuration.cpuInterface.length > 0 else { return false }
        TestHardware.localInitializationCounts[TestHardware.currentCPU] += 1
        return true
    }

    func acknowledge() -> InterruptAcknowledgeToken? {
        TestHardware.acknowledge()
    }

    func end(_ token: InterruptAcknowledgeToken) {
        TestHardware.ends.append(
            TestEndOfInterrupt(
                cpu: TestHardware.currentCPU,
                rawValue: token.rawValue
            )
        )
    }

    func disable(interruptID: UInt32) {
        TestHardware.disabledInterrupts[TestHardware.currentCPU].append(
            interruptID
        )
    }

    func shutdownCurrentProcessor() -> Bool {
        TestHardware.localShutdownCount += 1
        return true
    }

    func shutdownDistributor() -> Bool {
        TestHardware.distributorShutdownCount += 1
        return true
    }
}

struct GICv3 {
    private let configuration: GICv3Configuration

    var timerInterruptID: UInt32 {
        configuration.timerInterruptID
    }

    init(configuration: GICv3Configuration) {
        self.configuration = configuration
    }

    func initializeDistributor() -> Bool {
        guard configuration.distributor.length > 0 else { return false }
        TestHardware.distributorInitializationCount += 1
        return true
    }

    func initializeCurrentProcessor() -> Bool {
        guard configuration.redistributor.length > 0 else { return false }
        TestHardware.localInitializationCounts[TestHardware.currentCPU] += 1
        return true
    }

    func acknowledge() -> InterruptAcknowledgeToken? {
        TestHardware.acknowledge()
    }

    func end(_ token: InterruptAcknowledgeToken) {
        TestHardware.ends.append(
            TestEndOfInterrupt(
                cpu: TestHardware.currentCPU,
                rawValue: token.rawValue
            )
        )
    }

    func disable(interruptID: UInt32) {
        TestHardware.disabledInterrupts[TestHardware.currentCPU].append(
            interruptID
        )
    }

    func shutdownCurrentProcessor() -> Bool {
        TestHardware.localShutdownCount += 1
        return true
    }

    func shutdownDistributor() -> Bool {
        TestHardware.distributorShutdownCount += 1
        return true
    }
}

struct GenericPhysicalTimer {
    private static let maximumCatchUpPeriods = 8

    private var periodTicks: UInt64 = 0
    private var nextDeadline: UInt64 = 0
    private var isRunning = false

    static func initializeCurrentProcessor() {
        TestHardware.physicalTimerInitializationCounts[
            TestHardware.currentCPU
        ] += 1
        AArch64.disablePhysicalTimer()
    }

    mutating func start(periodTicks: UInt64) -> Bool {
        guard periodTicks > 0 else { return false }
        self.periodTicks = periodTicks
        nextDeadline = AArch64.counterValue &+ periodTicks
        isRunning = true
        AArch64.setPhysicalTimerDeadline(nextDeadline)
        return true
    }

    mutating func rearmAfterInterrupt() {
        guard isRunning, periodTicks > 0 else {
            AArch64.disablePhysicalTimer()
            return
        }
        let now = AArch64.counterValue
        var deadline = nextDeadline &+ periodTicks
        var catchUpCount = 0
        while deadline <= now,
              catchUpCount < Self.maximumCatchUpPeriods {
            deadline &+= periodTicks
            catchUpCount += 1
        }
        if deadline <= now {
            deadline = now &+ periodTicks
        }
        nextDeadline = deadline
        AArch64.setPhysicalTimerDeadline(deadline)
    }

    mutating func stop() {
        AArch64.disablePhysicalTimer()
        isRunning = false
        periodTicks = 0
        nextDeadline = 0
    }
}

enum AArch64ExceptionKind {
    case irq
    case synchronous
    case fiq
    case systemError
}

struct AArch64ExceptionFrame {
    static var byteCount: Int { MemoryLayout<Self>.size }

    var vectorSlot: UInt64
    var syndrome: UInt64
    var faultAddress: UInt64
    var exceptionKind: AArch64ExceptionKind?
}

enum AArch64 {
    static var logicalProcessorID: UInt64 {
        UInt64(TestHardware.currentCPU)
    }

    static let vectorBase: UInt64 = 0x8_0000

    static var counterValue: UInt64 {
        TestHardware.counterValues[TestHardware.currentCPU]
    }

    static func disableIRQs() {
        TestHardware.irqEnabled[TestHardware.currentCPU] = false
    }

    static func enableIRQs() {
        TestHardware.irqEnabled[TestHardware.currentCPU] = true
    }

    static func disablePhysicalTimer() {
        TestHardware.timerDisableCounts[TestHardware.currentCPU] += 1
    }

    static func setPhysicalTimerDeadline(_ deadline: UInt64) {
        TestHardware.timerDeadlines[TestHardware.currentCPU] = deadline
    }

    static func waitForEvent() {
        fatalError("unexpected fatal exception path")
    }
}

@_cdecl("swiftos_test_cpu0_timer_hook")
func swiftOSTestCPU0TimerHook(_ rawFrame: UnsafeMutableRawPointer) {
    _ = rawFrame
    TestHardware.hookCounts[0] += 1
}

@_cdecl("swiftos_test_cpu1_timer_hook")
func swiftOSTestCPU1TimerHook(_ rawFrame: UnsafeMutableRawPointer) {
    _ = rawFrame
    TestHardware.hookCounts[1] += 1
}

@_cdecl("swiftos_test_cpu2_initial_timer_hook")
func swiftOSTestCPU2InitialTimerHook(_ rawFrame: UnsafeMutableRawPointer) {
    _ = rawFrame
    TestHardware.hookCounts[2] += 1
    TestHardware.countObservedInsideHook =
        InterruptSubsystem.timerInterruptCount(logicalProcessorID: 2)
    TestHardware.replacementInstallationSucceeded =
        InterruptSubsystem.setTimerInterruptHook(
            swiftOSTestCPU2ReplacementTimerHook
        )
}

@_cdecl("swiftos_test_cpu2_replacement_timer_hook")
func swiftOSTestCPU2ReplacementTimerHook(
    _ rawFrame: UnsafeMutableRawPointer
) {
    _ = rawFrame
    TestHardware.replacementHookCount += 1
}

@_cdecl("swiftos_test_cpu3_timer_hook")
func swiftOSTestCPU3TimerHook(_ rawFrame: UnsafeMutableRawPointer) {
    _ = rawFrame
    TestHardware.hookCounts[3] += 1
}

@main
struct InterruptSubsystemProcessorLocalTests {
    private static let timerInterruptID: UInt32 = 30

    static func main() {
        configuresFourProcessorLocalContextsAndRejectsMismatches()
        isolatesHooksTimersCountsAndSupportsHookReplacement()
        clearsProcessorLocalTimersAndHooksBeforeGlobalShutdown()
        print("interrupt subsystem processor-local host tests: 3 passed")
    }

    private static func configuresFourProcessorLocalContextsAndRejectsMismatches() {
        TestHardware.reset()
        expect(InterruptSubsystem.exceptionVectorsInstalled, "exception vectors")
        expect(
            InterruptSubsystem.configureGICv2(
                GICv2Configuration(
                    distributor: DeviceResource(
                        baseAddress: 0x1000,
                        length: 0x1000
                    ),
                    cpuInterface: DeviceResource(
                        baseAddress: 0x2000,
                        length: 0x1000
                    ),
                    timerInterruptID: timerInterruptID
                ),
                processorCount: 4
            ),
            "four-processor controller configuration"
        )
        expect(
            TestHardware.distributorInitializationCount == 1,
            "distributor initialized more than once"
        )
        expect(
            TestHardware.localInitializationCounts == [1, 0, 0, 0],
            "boot processor local interface initialization"
        )

        TestHardware.currentCPU = 2
        let localCountsBeforeMismatch = TestHardware.localInitializationCounts
        expect(
            !InterruptSubsystem.configureCurrentProcessor(
                logicalProcessorID: 1
            ),
            "mismatched TPIDR/context was accepted"
        )
        expect(
            TestHardware.localInitializationCounts == localCountsBeforeMismatch,
            "mismatched TPIDR/context touched the GIC CPU interface"
        )
        expect(
            TestHardware.physicalTimerInitializationCounts[2] == 1,
            "mismatch path did not force the caller's timer off"
        )

        for cpu in 1..<4 {
            TestHardware.currentCPU = cpu
            expect(
                InterruptSubsystem.configureCurrentProcessor(
                    logicalProcessorID: UInt64(cpu)
                ),
                "processor \(cpu) local configuration"
            )
        }
        expect(
            TestHardware.localInitializationCounts == [1, 1, 1, 1],
            "not every logical processor received one local GIC setup"
        )

        TestHardware.currentCPU = 3
        expect(
            !InterruptSubsystem.configureCurrentProcessor(
                logicalProcessorID: 3
            ),
            "duplicate local configuration was accepted"
        )
        expect(
            TestHardware.localInitializationCounts[3] == 1,
            "duplicate local configuration reached the controller"
        )
    }

    private static func isolatesHooksTimersCountsAndSupportsHookReplacement() {
        let counters: [UInt64] = [100, 200, 300, 400]
        let periods: [UInt64] = [10, 20, 30, 40]
        let hooks: [TimerInterruptHook] = [
            swiftOSTestCPU0TimerHook,
            swiftOSTestCPU1TimerHook,
            swiftOSTestCPU2InitialTimerHook,
            swiftOSTestCPU3TimerHook,
        ]
        TestHardware.counterValues = counters

        for cpu in 0..<4 {
            TestHardware.currentCPU = cpu
            expect(
                InterruptSubsystem.setTimerInterruptHook(hooks[cpu]),
                "processor \(cpu) hook installation"
            )
            expect(
                InterruptSubsystem.startPhysicalTimer(
                    periodTicks: periods[cpu]
                ),
                "processor \(cpu) timer start"
            )
            expect(
                TestHardware.timerDeadlines[cpu] == counters[cpu] + periods[cpu],
                "processor \(cpu) initial timer deadline"
            )
            expect(
                TestHardware.irqEnabled[cpu],
                "processor \(cpu) IRQ remained masked"
            )
        }

        for cpu in 0..<4 {
            TestHardware.currentCPU = cpu
            TestHardware.enqueueTimerInterrupt(
                cpu: cpu,
                interruptID: timerInterruptID
            )
            dispatchIRQ()
        }

        expect(
            TestHardware.hookCounts == [1, 1, 1, 1],
            "timer hook crossed a processor-local boundary"
        )
        expect(
            TestHardware.replacementInstallationSucceeded,
            "timer callback could not replace its own processor's hook"
        )
        expect(
            TestHardware.countObservedInsideHook == 1,
            "timer count was not published before invoking the hook"
        )
        expect(
            timerCounts() == [1, 1, 1, 1],
            "processor-local timer counts were not independent"
        )
        expect(
            TestHardware.timerDeadlines == [120, 240, 360, 480],
            "processor-local timers did not rearm independently"
        )

        TestHardware.currentCPU = 2
        TestHardware.enqueueTimerInterrupt(
            cpu: 2,
            interruptID: timerInterruptID
        )
        dispatchIRQ()
        expect(
            TestHardware.hookCounts == [1, 1, 1, 1],
            "replaced hook ran after installing its replacement"
        )
        expect(
            TestHardware.replacementHookCount == 1,
            "replacement hook did not run on the next timer interrupt"
        )
        expect(
            timerCounts() == [1, 1, 2, 1],
            "hook replacement changed another processor's count"
        )
        expect(
            TestHardware.timerDeadlines[2] == 390,
            "processor 2 timer did not preserve its private deadline"
        )
        expect(
            TestHardware.ends.count == 5,
            "acknowledged timer interrupts were not all EOIed"
        )
    }

    private static func clearsProcessorLocalTimersAndHooksBeforeGlobalShutdown() {
        for cpu in 0..<4 {
            TestHardware.currentCPU = cpu
            InterruptSubsystem.stopPhysicalTimer()
            expect(
                InterruptSubsystem.setTimerInterruptHook(nil),
                "processor \(cpu) hook cleanup"
            )
            expect(
                !TestHardware.irqEnabled[cpu],
                "processor \(cpu) IRQ remained enabled during cleanup"
            )
        }

        let hookCountBeforeClearedDispatch = TestHardware.hookCounts[3]
        TestHardware.currentCPU = 3
        TestHardware.enqueueTimerInterrupt(
            cpu: 3,
            interruptID: timerInterruptID
        )
        dispatchIRQ()
        expect(
            TestHardware.hookCounts[3] == hookCountBeforeClearedDispatch,
            "cleared processor-local hook was invoked"
        )

        TestHardware.currentCPU = 0
        expect(
            InterruptSubsystem.quiesceForKernelRestart(),
            "global interrupt shutdown"
        )
        expect(
            TestHardware.localShutdownCount == 1,
            "boot processor interface was not shut down"
        )
        expect(
            TestHardware.distributorShutdownCount == 1,
            "interrupt distributor was not shut down"
        )
        expect(
            InterruptSubsystem.timerInterruptCount(logicalProcessorID: 0)
                == nil,
            "processor-local counts survived global shutdown"
        )
        expect(
            !InterruptSubsystem.setTimerInterruptHook(
                swiftOSTestCPU0TimerHook
            ),
            "hook installation succeeded after global shutdown"
        )
        expect(
            !InterruptSubsystem.startPhysicalTimer(periodTicks: 10),
            "timer start succeeded after global shutdown"
        )
        expect(
            TestHardware.timerDisableCounts.allSatisfy { $0 > 0 },
            "one or more processor-local timers were not stopped"
        )
    }

    private static func dispatchIRQ() {
        var frame = AArch64ExceptionFrame(
            vectorSlot: 1,
            syndrome: 0,
            faultAddress: 0,
            exceptionKind: .irq
        )
        withUnsafeMutablePointer(to: &frame) {
            swiftOSExceptionDispatch(UnsafeMutableRawPointer($0))
        }
    }

    private static func timerCounts() -> [UInt64] {
        (0..<4).map {
            guard let count = InterruptSubsystem.timerInterruptCount(
                logicalProcessorID: $0
            ) else {
                fatalError("missing processor-local timer count for CPU \($0)")
            }
            return count
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError("interrupt subsystem processor-local test failed: \(message)")
        }
    }
}
