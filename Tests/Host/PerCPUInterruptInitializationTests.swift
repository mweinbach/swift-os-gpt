struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

private enum TestMMIOOperation: Equatable {
    case load32(cpu: Int, address: UInt, value: UInt32)
    case store8(cpu: Int, address: UInt, value: UInt8)
    case store32(cpu: Int, address: UInt, value: UInt32)
}

private enum TestHardware {
    nonisolated(unsafe) static var currentCPU = 0
    nonisolated(unsafe) static var operations: [TestMMIOOperation] = []
    nonisolated(unsafe) static var acknowledgeValues = [UInt32](
        repeating: 1_023,
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
    nonisolated(unsafe) static var barrierCount = 0

    static func reset() {
        currentCPU = 0
        operations.removeAll(keepingCapacity: true)
        acknowledgeValues = [UInt32](repeating: 1_023, count: 4)
        counterValues = [UInt64](repeating: 0, count: 4)
        timerDeadlines = [UInt64](repeating: 0, count: 4)
        timerDisableCounts = [Int](repeating: 0, count: 4)
        barrierCount = 0
    }
}

enum MMIO {
    static func load32(at address: UInt) -> UInt32 {
        let value: UInt32
        if address == PerCPUInterruptInitializationTests.cpuBase + 0x00c {
            value = TestHardware.acknowledgeValues[TestHardware.currentCPU]
        } else {
            value = 0
        }
        TestHardware.operations.append(
            .load32(
                cpu: TestHardware.currentCPU,
                address: address,
                value: value
            )
        )
        return value
    }

    static func store8(_ value: UInt8, at address: UInt) {
        TestHardware.operations.append(
            .store8(
                cpu: TestHardware.currentCPU,
                address: address,
                value: value
            )
        )
    }

    static func store32(_ value: UInt32, at address: UInt) {
        TestHardware.operations.append(
            .store32(
                cpu: TestHardware.currentCPU,
                address: address,
                value: value
            )
        )
    }
}

enum AArch64 {
    static var counterValue: UInt64 {
        TestHardware.counterValues[TestHardware.currentCPU]
    }

    static func synchronizeData() {
        TestHardware.barrierCount += 1
    }

    static func setPhysicalTimerDeadline(_ deadline: UInt64) {
        TestHardware.timerDeadlines[TestHardware.currentCPU] = deadline
    }

    static func disablePhysicalTimer() {
        TestHardware.timerDisableCounts[TestHardware.currentCPU] += 1
    }
}

@main
struct PerCPUInterruptInitializationTests {
    static let distributorBase: UInt = 0x1_0000
    static let cpuBase: UInt = 0x2_0000
    private static let timerInterruptID: UInt32 = 30
    private static let timerBit: UInt32 = 1 << timerInterruptID

    static func main() {
        initializesOneGlobalDistributorAndFourLocalGICCs()
        keepsAcknowledgeAndEOIStateLocalToTheCallingCPU()
        initializesAndProgramsIndependentPhysicalTimers()
        rejectsInvalidResourcesBeforeTouchingMMIO()
        print("per-CPU interrupt initialization host tests: 4 passed")
    }

    private static func initializesOneGlobalDistributorAndFourLocalGICCs() {
        TestHardware.reset()
        let driver = makeDriver()

        expect(driver.initializeDistributor(), "global distributor setup")
        expect(
            TestHardware.operations == [
                .store32(cpu: 0, address: distributorBase, value: 3)
            ],
            "global setup touched processor-local state"
        )

        var cpu = 0
        while cpu < 4 {
            TestHardware.currentCPU = cpu
            let operationStart = TestHardware.operations.count
            expect(
                driver.initializeCurrentProcessor(),
                "local GICC setup for CPU \(cpu)"
            )
            let localOperations = Array(
                TestHardware.operations[operationStart...]
            )
            expect(
                !localOperations.contains(
                    .store32(cpu: cpu, address: distributorBase, value: 3)
                ),
                "CPU \(cpu) rewrote global distributor control"
            )
            expect(
                localOperations.contains(
                    .store32(cpu: cpu, address: cpuBase, value: 0)
                ),
                "CPU \(cpu) did not mask its GICC"
            )
            expect(
                localOperations.contains(
                    .store32(
                        cpu: cpu,
                        address: distributorBase + 0x180,
                        value: timerBit
                    )
                ),
                "CPU \(cpu) did not disable its timer PPI before setup"
            )
            expect(
                localOperations.contains(
                    .store32(
                        cpu: cpu,
                        address: distributorBase + 0x100,
                        value: timerBit
                    )
                ),
                "CPU \(cpu) did not enable its timer PPI"
            )
            expect(
                localOperations.contains(
                    .store8(
                        cpu: cpu,
                        address: distributorBase + 0x400
                            + UInt(timerInterruptID),
                        value: 0x80
                    )
                ),
                "CPU \(cpu) did not program timer priority"
            )
            expect(
                localOperations.contains(
                    .store32(cpu: cpu, address: cpuBase + 4, value: 0xff)
                ),
                "CPU \(cpu) did not open its priority mask"
            )
            expect(
                localOperations.contains(
                    .store32(cpu: cpu, address: cpuBase + 8, value: 0)
                ),
                "CPU \(cpu) did not reset its binary point"
            )
            expect(
                localOperations.contains(
                    .store32(cpu: cpu, address: cpuBase, value: 7)
                ),
                "CPU \(cpu) did not enable its GICC"
            )
            cpu += 1
        }

        let globalControlWrites = TestHardware.operations.filter {
            $0 == .store32(cpu: 0, address: distributorBase, value: 3)
        }
        expect(
            globalControlWrites.count == 1,
            "local initialization repeated global distributor setup"
        )
    }

    private static func keepsAcknowledgeAndEOIStateLocalToTheCallingCPU() {
        TestHardware.reset()
        let driver = makeDriver()
        let rawCPU0 = timerInterruptID | (1 << 10)
        let rawCPU3 = timerInterruptID | (3 << 10)
        TestHardware.acknowledgeValues[0] = rawCPU0
        TestHardware.acknowledgeValues[3] = rawCPU3

        TestHardware.currentCPU = 0
        guard let cpu0Token = driver.acknowledge() else {
            fatalError("CPU0 timer acknowledgement was spurious")
        }
        expect(cpu0Token.interruptID == timerInterruptID, "CPU0 INTID")
        expect(cpu0Token.rawValue == UInt64(rawCPU0), "CPU0 raw IAR")
        driver.end(cpu0Token)

        TestHardware.currentCPU = 3
        guard let cpu3Token = driver.acknowledge() else {
            fatalError("CPU3 timer acknowledgement was spurious")
        }
        expect(cpu3Token.interruptID == timerInterruptID, "CPU3 INTID")
        expect(cpu3Token.rawValue == UInt64(rawCPU3), "CPU3 raw IAR")
        driver.end(cpu3Token)

        expect(
            TestHardware.operations.contains(
                .store32(
                    cpu: 0,
                    address: cpuBase + 0x010,
                    value: rawCPU0
                )
            ),
            "CPU0 EOI lost its complete acknowledge token"
        )
        expect(
            TestHardware.operations.contains(
                .store32(
                    cpu: 3,
                    address: cpuBase + 0x010,
                    value: rawCPU3
                )
            ),
            "CPU3 EOI used another processor's token"
        )

        TestHardware.acknowledgeValues[2] = 1_023
        TestHardware.currentCPU = 2
        expect(driver.acknowledge() == nil, "spurious INTID was acknowledged")
    }

    private static func initializesAndProgramsIndependentPhysicalTimers() {
        TestHardware.reset()
        TestHardware.currentCPU = 0
        GenericPhysicalTimer.initializeCurrentProcessor()
        expect(TestHardware.timerDisableCounts[0] == 1, "CPU0 timer reset")

        var cpu0Timer = GenericPhysicalTimer()
        TestHardware.counterValues[0] = 100
        expect(cpu0Timer.start(periodTicks: 25), "CPU0 timer start")
        expect(TestHardware.timerDeadlines[0] == 125, "CPU0 CVAL")

        TestHardware.currentCPU = 1
        GenericPhysicalTimer.initializeCurrentProcessor()
        expect(TestHardware.timerDisableCounts[1] == 1, "CPU1 timer reset")
        expect(cpu0Timer.isRunning, "CPU1 reset mutated CPU0 software state")
        expect(TestHardware.timerDeadlines[0] == 125, "CPU1 reset changed CPU0 CVAL")

        var cpu1Timer = GenericPhysicalTimer()
        TestHardware.counterValues[1] = 1_000
        expect(cpu1Timer.start(periodTicks: 40), "CPU1 timer start")
        expect(TestHardware.timerDeadlines[1] == 1_040, "CPU1 CVAL")

        TestHardware.currentCPU = 0
        TestHardware.counterValues[0] = 126
        cpu0Timer.rearmAfterInterrupt()
        expect(TestHardware.timerDeadlines[0] == 150, "CPU0 timer rearm")
        expect(cpu0Timer.nextDeadline == 150, "CPU0 deadline state")
        expect(cpu1Timer.nextDeadline == 1_040, "CPU0 rearm changed CPU1")

        TestHardware.currentCPU = 1
        TestHardware.counterValues[1] = 1_041
        cpu1Timer.rearmAfterInterrupt()
        expect(TestHardware.timerDeadlines[1] == 1_080, "CPU1 timer rearm")
        expect(cpu1Timer.nextDeadline == 1_080, "CPU1 deadline state")
        expect(cpu0Timer.nextDeadline == 150, "CPU1 rearm changed CPU0")
    }

    private static func rejectsInvalidResourcesBeforeTouchingMMIO() {
        TestHardware.reset()
        let invalidDistributor = GICv2(
            configuration: GICv2Configuration(
                distributor: DeviceResource(baseAddress: 0, length: 0x1_000),
                cpuInterface: DeviceResource(
                    baseAddress: UInt64(cpuBase),
                    length: 0x1_000
                ),
                timerInterruptID: timerInterruptID
            )
        )
        expect(
            !invalidDistributor.initializeDistributor(),
            "zero distributor base was accepted"
        )
        expect(
            !invalidDistributor.initializeCurrentProcessor(),
            "zero distributor base reached local setup"
        )
        expect(TestHardware.operations.isEmpty, "invalid setup touched MMIO")
    }

    private static func makeDriver() -> GICv2 {
        GICv2(
            configuration: GICv2Configuration(
                distributor: DeviceResource(
                    baseAddress: UInt64(distributorBase),
                    length: 0x2_000
                ),
                cpuInterface: DeviceResource(
                    baseAddress: UInt64(cpuBase),
                    length: 0x1_000
                ),
                timerInterruptID: timerInterruptID
            )
        )
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() { fatalError(message) }
}
