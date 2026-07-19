struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

enum PlatformStorageControllerKind: UInt8, Equatable {
    case bcm2712SDHCI
}

enum PlatformInterruptTrigger: UInt32, Equatable {
    case levelHigh = 4
}

struct PlatformStorageInterruptRoute: Equatable {
    let spiNumber: UInt32
    let trigger: PlatformInterruptTrigger
}

enum PlatformGPIOLevel: UInt8, Equatable {
    case low
    case high
}

struct PlatformSDCardPowerResources: Equatable {
    let gpioControllerPhandle: UInt32
    let gpioRegisters: DeviceResource
    let ioVoltageSelectLine: UInt32
    let io3V3SelectLevel: PlatformGPIOLevel
    let cardPowerEnableLine: UInt32
    let cardPowerEnabledLevel: PlatformGPIOLevel
    let cardDetectLine: UInt32
    let cardDetectPresentLevel: PlatformGPIOLevel
    let voltageSettlingMicroseconds: UInt32
}

struct PlatformStorageDeviceDescription: Equatable {
    let controller: PlatformStorageControllerKind
    let hostRegisters: DeviceResource
    let configurationRegisters: DeviceResource
    let interrupt: PlatformStorageInterruptRoute
    let inputClockHertz: UInt32
    let busWidth: UInt32
    let power: PlatformSDCardPowerResources
}

enum MMIO {
    static func load8(at address: UInt) -> UInt8 {
        UnsafeRawPointer(bitPattern: address)!.load(as: UInt8.self)
    }
    static func load16(at address: UInt) -> UInt16 {
        UnsafeRawPointer(bitPattern: address)!.load(as: UInt16.self)
    }
    static func load32(at address: UInt) -> UInt32 {
        UnsafeRawPointer(bitPattern: address)!.load(as: UInt32.self)
    }
    static func store8(_ value: UInt8, at address: UInt) {
        UnsafeMutableRawPointer(bitPattern: address)!.storeBytes(of: value, as: UInt8.self)
    }
    static func store16(_ value: UInt16, at address: UInt) {
        UnsafeMutableRawPointer(bitPattern: address)!.storeBytes(of: value, as: UInt16.self)
    }
    static func store32(_ value: UInt32, at address: UInt) {
        UnsafeMutableRawPointer(bitPattern: address)!.storeBytes(of: value, as: UInt32.self)
    }
}

enum AArch64 {
    static var counterFrequency: UInt64 { 1_000 }
    static var counterValue: UInt64 { 0 }
    static func synchronizeData() {}
    static func spinHint() {}
}

private enum BoardEvent: Equatable {
    case read(UInt)
    case write(UInt, UInt32)
    case barrier
    case frequency
    case counter
    case spin
}

private final class TestBoardAccess: BCM2712SDCardBoardRegisterAccess {
    var registers: [UInt: UInt32] = [:]
    var events: [BoardEvent] = []
    var ignoredWrites: Set<UInt> = []
    var frequency: UInt64 = 1_000
    var counter: UInt64 = 0
    var ticksPerSpin: UInt64 = 1

    func read32(at address: UInt) -> UInt32 {
        events.append(.read(address))
        return registers[address, default: 0]
    }

    func write32(_ value: UInt32, at address: UInt) {
        events.append(.write(address, value))
        if !ignoredWrites.contains(address) { registers[address] = value }
    }

    func synchronizePostedWrites() { events.append(.barrier) }
    func counterFrequency() -> UInt64 {
        events.append(.frequency)
        return frequency
    }
    func counterValue() -> UInt64 {
        events.append(.counter)
        return counter
    }
    func spinWaitHint() {
        events.append(.spin)
        counter &+= ticksPerSpin
    }
}

@main
struct BCM2712SDCardTests {
    private static let host: UInt64 = 0x10_00fff000
    private static let configuration: UInt64 = 0x10_00fff400
    private static let gpio: UInt64 = 0x10_7d517c00

    static func main() {
        powerCyclesToDerivedThreeVoltPolicyAndProgramsTimer()
        refusesAbsentOrAmbiguousSlotsWithoutWrites()
        rejectsUnsupportedClockAndResourceContractsBeforeWrites()
        boundsStoppedCountersAndRejectsPostedWriteFailures()
        derivesOppositeGPIOPolaritiesWithoutFixedLevels()
        exercisesConcreteHostRegisterAccess()
        print("BCM2712 SD card board control: 6 groups passed")
    }

    private static func powerCyclesToDerivedThreeVoltPolicyAndProgramsTimer() {
        let access = preparedAccess()
        access.registers[UInt(configuration + 0x44)] = 0xa5a5_5a5d
        var board = makeBoard(access: access)!
        expect(
            board.prepareSDCard(
                maximumPollCount: 64,
                maximumElapsedTicks: 100
            ) == .ready,
            "valid Pi slot preparation failed"
        )
        expect(access.registers[UInt(gpio + 0x04)] == 1 << 4, "VMMC not enabled")
        expect(
            access.registers[UInt(gpio + 0x08)] == 1 << 5,
            "supply GPIO direction is not output"
        )
        expect(
            access.registers[UInt(configuration + 0x44)] == 0xa5a5_5a5e,
            "SD pin selector fields were not preserved"
        )
        expect(
            access.registers[UInt(configuration + 0x4c)] == 0x30c8,
            "200-MHz timer estimate was not programmed exactly"
        )
        let writes = access.events.compactMap { event -> (UInt, UInt32)? in
            if case let .write(address, value) = event { return (address, value) }
            return nil
        }
        expect(
            writes.map { $0.0 } == [
                UInt(gpio + 0x04), UInt(gpio + 0x08),
                UInt(configuration + 0x44), UInt(configuration + 0x4c),
                UInt(gpio + 0x04),
            ],
            "board sequence touched an unexpected register"
        )
        expect(access.events.filter { $0 == .spin }.count == 10, "settling was wrong")
        let eventCount = access.events.count
        expect(
            board.prepareSDCard(
                maximumPollCount: 1,
                maximumElapsedTicks: 1
            ) == .ready,
            "ready board was not idempotent"
        )
        expect(access.events.count == eventCount, "idempotent prepare touched hardware")
    }

    private static func refusesAbsentOrAmbiguousSlotsWithoutWrites() {
        let absent = preparedAccess()
        absent.registers[UInt(gpio + 0x04)] = (1 << 4) | (1 << 5)
        var absentBoard = makeBoard(access: absent)!
        expect(
            absentBoard.prepareSDCard(
                maximumPollCount: 8,
                maximumElapsedTicks: 8
            ) == .cardAbsent,
            "active-low absent card was accepted"
        )
        expect(!hasWrites(absent.events), "absent card toggled supplies")

        let ambiguous = preparedAccess()
        ambiguous.registers[UInt(gpio + 0x08)] = 0
        var ambiguousBoard = makeBoard(access: ambiguous)!
        expect(
            ambiguousBoard.prepareSDCard(
                maximumPollCount: 8,
                maximumElapsedTicks: 8
            ) == .failed,
            "output-configured card detect was accepted"
        )
        expect(!hasWrites(ambiguous.events), "ambiguous detect direction caused writes")
    }

    private static func rejectsUnsupportedClockAndResourceContractsBeforeWrites() {
        let access = preparedAccess()
        expect(
            makeBoard(access: access, inputClockHertz: 199_500_000) == nil,
            "fractional-MHz wrapper timer was accepted"
        )
        expect(
            makeBoard(access: access, configurationLength: 0x4f) == nil,
            "short wrapper aperture was accepted"
        )
        expect(!hasWrites(access.events), "failable construction touched hardware")
    }

    private static func boundsStoppedCountersAndRejectsPostedWriteFailures() {
        let stopped = preparedAccess()
        stopped.ticksPerSpin = 0
        var stoppedBoard = makeBoard(access: stopped)!
        expect(
            stoppedBoard.prepareSDCard(
                maximumPollCount: 8,
                maximumElapsedTicks: 100
            ) == .timedOut,
            "stopped architectural counter escaped poll bound"
        )
        expect(stopped.events.filter { $0 == .spin }.count == 8, "poll limit drifted")

        let ignored = preparedAccess()
        ignored.ignoredWrites.insert(UInt(configuration + 0x4c))
        var ignoredBoard = makeBoard(access: ignored)!
        expect(
            ignoredBoard.prepareSDCard(
                maximumPollCount: 64,
                maximumElapsedTicks: 100
            ) == .failed,
            "failed timer-estimate readback was ignored"
        )
    }

    private static func derivesOppositeGPIOPolaritiesWithoutFixedLevels() {
        let access = preparedAccess()
        // Active-high card detect, active-high 3.3-V select, active-low VMMC.
        access.registers[UInt(gpio + 0x04)] = (1 << 5)
        var board = makeBoard(
            access: access,
            io3V3Level: .high,
            powerEnabledLevel: .low,
            detectPresentLevel: .high
        )!
        expect(
            board.prepareSDCard(
                maximumPollCount: 64,
                maximumElapsedTicks: 100
            ) == .ready,
            "derived opposite polarities failed"
        )
        let data = access.registers[UInt(gpio + 0x04), default: 0]
        expect(data & (1 << 3) != 0, "3.3-V select polarity was fixed")
        expect(data & (1 << 4) == 0, "power-enable polarity was fixed")
    }

    private static func exercisesConcreteHostRegisterAccess() {
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: 0x200, alignment: 8)
        defer { allocation.deallocate() }
        allocation.initializeMemory(as: UInt8.self, repeating: 0, count: 0x200)
        let description = makeDescription(
            hostBase: UInt64(UInt(bitPattern: allocation)),
            configurationLength: 0x200
        )
        var access = BCM2712SDHCIMMIORegisterAccess(description: description)!
        access.write8(0x5a, at: 3)
        access.write16(0xa55a, at: 4)
        access.write32(0x1234_5678, at: 8)
        expect(access.read8(at: 3) == 0x5a, "MMIO byte access failed")
        expect(access.read16(at: 4) == 0xa55a, "MMIO halfword access failed")
        expect(access.read32(at: 8) == 0x1234_5678, "MMIO word access failed")
    }

    private static func preparedAccess() -> TestBoardAccess {
        let access = TestBoardAccess()
        access.registers[UInt(gpio + 0x04)] = 1 << 4
        access.registers[UInt(gpio + 0x08)] = 1 << 5
        return access
    }

    private static func makeBoard(
        access: TestBoardAccess,
        inputClockHertz: UInt32 = 200_000_000,
        configurationLength: UInt64 = 0x200,
        io3V3Level: PlatformGPIOLevel = .low,
        powerEnabledLevel: PlatformGPIOLevel = .high,
        detectPresentLevel: PlatformGPIOLevel = .low
    ) -> BCM2712SDCardBoardControl<TestBoardAccess>? {
        BCM2712SDCardBoardControl(
            description: makeDescription(
                inputClockHertz: inputClockHertz,
                configurationLength: configurationLength,
                io3V3Level: io3V3Level,
                powerEnabledLevel: powerEnabledLevel,
                detectPresentLevel: detectPresentLevel
            ),
            access: access
        )
    }

    private static func makeDescription(
        hostBase: UInt64 = host,
        inputClockHertz: UInt32 = 200_000_000,
        configurationLength: UInt64 = 0x200,
        io3V3Level: PlatformGPIOLevel = .low,
        powerEnabledLevel: PlatformGPIOLevel = .high,
        detectPresentLevel: PlatformGPIOLevel = .low
    ) -> PlatformStorageDeviceDescription {
        PlatformStorageDeviceDescription(
            controller: .bcm2712SDHCI,
            hostRegisters: DeviceResource(baseAddress: hostBase, length: 0x260),
            configurationRegisters: DeviceResource(
                baseAddress: configuration,
                length: configurationLength
            ),
            interrupt: PlatformStorageInterruptRoute(
                spiNumber: 0x111,
                trigger: .levelHigh
            ),
            inputClockHertz: inputClockHertz,
            busWidth: 4,
            power: PlatformSDCardPowerResources(
                gpioControllerPhandle: 0x0d,
                gpioRegisters: DeviceResource(baseAddress: gpio, length: 0x40),
                ioVoltageSelectLine: 3,
                io3V3SelectLevel: io3V3Level,
                cardPowerEnableLine: 4,
                cardPowerEnabledLevel: powerEnabledLevel,
                cardDetectLine: 5,
                cardDetectPresentLevel: detectPresentLevel,
                voltageSettlingMicroseconds: 5_000
            )
        )
    }

    private static func hasWrites(_ events: [BoardEvent]) -> Bool {
        events.contains { event in
            if case .write = event { return true }
            return false
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
