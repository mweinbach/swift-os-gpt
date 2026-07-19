private final class TestSDCardBoard: SDCardBoardControl {
    var result = SDCardBoardPreparationResult.ready
    var calls: [(UInt64, UInt64)] = []

    func prepareSDCard(
        maximumPollCount: UInt64,
        maximumElapsedTicks: UInt64
    ) -> SDCardBoardPreparationResult {
        calls.append((maximumPollCount, maximumElapsedTicks))
        return result
    }
}

private final class TestSDHCIHardware {
    var bytes = [UInt8](repeating: 0, count: 0x100)
    var commands: [(index: UInt8, argument: UInt32)] = []
    var counter: UInt64 = 0
    var ticksPerSpin: UInt64 = 1
    var spinCount = 0
    var resetStuck = false
    var clockStuck = false
    var operatingConditionsReady = true
    var suppressCommandCompletion = false
    var readBlock = [UInt8](repeating: 0, count: 512)
    var writtenBlock = [UInt8]()
    var dataWordIndex = 0
    var csdWords = [UInt32](repeating: 0, count: 4)

    init() {
        write32Raw(0x40, 1 << 24) // 3.3-V host capability.
        write16Raw(0xfe, 2) // SDHCI 3.00.
        setCSDField(high: 127, low: 126, value: 1)
        setCSDField(high: 69, low: 48, value: 31)
        var index = 0
        while index < readBlock.count {
            readBlock[index] = UInt8(truncatingIfNeeded: index ^ 0xa5)
            index += 1
        }
    }

    func read8(_ offset: UInt) -> UInt8 { bytes[Int(offset)] }

    func read16(_ offset: UInt) -> UInt16 {
        let index = Int(offset)
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    func read32(_ offset: UInt) -> UInt32 {
        if offset == 0x20 {
            let byteIndex = dataWordIndex * 4
            dataWordIndex += 1
            return UInt32(readBlock[byteIndex])
                | UInt32(readBlock[byteIndex + 1]) << 8
                | UInt32(readBlock[byteIndex + 2]) << 16
                | UInt32(readBlock[byteIndex + 3]) << 24
        }
        return read32Raw(offset)
    }

    func write8(_ value: UInt8, _ offset: UInt) {
        if offset == 0x2f {
            bytes[Int(offset)] = resetStuck ? value : 0
            return
        }
        bytes[Int(offset)] = value
    }

    func write16(_ value: UInt16, _ offset: UInt) {
        if offset == 0x2c {
            var clock = value
            if value & 1 != 0, !clockStuck { clock |= 1 << 1 }
            write16Raw(offset, clock)
            return
        }
        write16Raw(offset, value)
    }

    func write32(_ value: UInt32, _ offset: UInt) {
        switch offset {
        case 0x0c:
            write32Raw(offset, value)
            issueCommand(value)
        case 0x20:
            writtenBlock.append(UInt8(truncatingIfNeeded: value))
            writtenBlock.append(UInt8(truncatingIfNeeded: value >> 8))
            writtenBlock.append(UInt8(truncatingIfNeeded: value >> 16))
            writtenBlock.append(UInt8(truncatingIfNeeded: value >> 24))
        case 0x30:
            write32Raw(offset, read32Raw(offset) & ~value)
        default:
            write32Raw(offset, value)
        }
    }

    private func issueCommand(_ combined: UInt32) {
        let index = UInt8(truncatingIfNeeded: combined >> 24) & 0x3f
        let argument = read32Raw(0x08)
        commands.append((index, argument))
        if suppressCommandCompletion { return }

        switch index {
        case 8:
            write32Raw(0x10, 0x1aa)
        case 41:
            write32Raw(
                0x10,
                operatingConditionsReady ? 0xc0ff_8000 : 0x40ff_8000
            )
        case 3:
            write32Raw(0x10, 0x1234_0000)
        case 9:
            publishLongResponse(csdWords)
        case 13:
            write32Raw(0x10, (1 << 8) | (4 << 9))
        case 17:
            write32Raw(0x10, 0)
            dataWordIndex = 0
        case 24:
            write32Raw(0x10, 0)
            writtenBlock.removeAll(keepingCapacity: true)
        default:
            write32Raw(0x10, 0)
        }

        var status: UInt32 = 1
        if index == 17 { status |= (1 << 5) | (1 << 1) }
        if index == 24 { status |= (1 << 4) | (1 << 1) }
        write32Raw(0x30, read32Raw(0x30) | status)
    }

    private func publishLongResponse(_ words: [UInt32]) {
        // Inverse of the SDHCI response-window reconstruction in the driver.
        write32Raw(0x1c, words[0] >> 8)
        write32Raw(0x18, (words[0] & 0xff) << 24 | words[1] >> 8)
        write32Raw(0x14, (words[1] & 0xff) << 24 | words[2] >> 8)
        write32Raw(0x10, (words[2] & 0xff) << 24 | words[3] >> 8)
    }

    func setCSDField(high: Int, low: Int, value: UInt32) {
        var source = 0
        var bit = low
        while bit <= high {
            let word = 3 - bit / 32
            let wordBit = bit & 31
            csdWords[word] &= ~(UInt32(1) << UInt32(wordBit))
            csdWords[word] |= ((value >> UInt32(source)) & 1)
                << UInt32(wordBit)
            source += 1
            bit += 1
        }
    }

    private func write16Raw(_ offset: UInt, _ value: UInt16) {
        let index = Int(offset)
        bytes[index] = UInt8(truncatingIfNeeded: value)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func write32Raw(_ offset: UInt, _ value: UInt32) {
        let index = Int(offset)
        bytes[index] = UInt8(truncatingIfNeeded: value)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func read32Raw(_ offset: UInt) -> UInt32 {
        let index = Int(offset)
        let byte0 = UInt32(bytes[index])
        let byte1 = UInt32(bytes[index + 1]) << 8
        let byte2 = UInt32(bytes[index + 2]) << 16
        let byte3 = UInt32(bytes[index + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }
}

private struct TestSDHCIRegisters: SDHCIRegisterAccess {
    let hardware: TestSDHCIHardware

    mutating func read8(at offset: UInt) -> UInt8 { hardware.read8(offset) }
    mutating func read16(at offset: UInt) -> UInt16 { hardware.read16(offset) }
    mutating func read32(at offset: UInt) -> UInt32 { hardware.read32(offset) }
    mutating func write8(_ value: UInt8, at offset: UInt) {
        hardware.write8(value, offset)
    }
    mutating func write16(_ value: UInt16, at offset: UInt) {
        hardware.write16(value, offset)
    }
    mutating func write32(_ value: UInt32, at offset: UInt) {
        hardware.write32(value, offset)
    }
    mutating func synchronizePostedWrites() {}
    mutating func counterValue() -> UInt64 { hardware.counter }
    mutating func spinWaitHint() {
        hardware.spinCount += 1
        hardware.counter &+= hardware.ticksPerSpin
    }
}

@main
struct SDHCIBlockDeviceTests {
    static func main() {
        selectsBoundedVersion3ClockDivisors()
        parsesVersion1AndVersion2CSDCapacity()
        initializesAndTransfersExactlyOneBlock()
        preservesBoundsFailuresWithoutFaultingDevice()
        boundsResetClockAndCardNegotiationStalls()
        print("SDHCI block device: 5 groups passed")
    }

    private static func selectsBoundedVersion3ClockDivisors() {
        let initialization = SDHCIClockSelection.select(
            inputClockHertz: 200_000_000,
            maximumClockHertz: 400_000
        )
        expect(initialization?.encodedDivisor == 0xfa00, "bad 400-kHz divisor")
        expect(initialization?.actualClockHertz == 400_000, "bad init clock")
        let transfer = SDHCIClockSelection.select(
            inputClockHertz: 200_000_000,
            maximumClockHertz: 25_000_000
        )
        expect(transfer?.encodedDivisor == 0x0400, "bad 25-MHz divisor")
        expect(transfer?.actualClockHertz == 25_000_000, "bad transfer clock")
        expect(
            SDHCIClockSelection.select(
                inputClockHertz: 2_000_000_000,
                maximumClockHertz: 1
            ) == nil,
            "unencodable divisor was accepted"
        )
    }

    private static func parsesVersion1AndVersion2CSDCapacity() {
        let hardware = TestSDHCIHardware()
        let version2 = SDCardCSD(
            word0: hardware.csdWords[0],
            word1: hardware.csdWords[1],
            word2: hardware.csdWords[2],
            word3: hardware.csdWords[3]
        )
        expect(version2.logicalBlockCount == 32 * 1_024, "bad CSD v2 size")

        let version1Hardware = TestSDHCIHardware()
        version1Hardware.csdWords = [0, 0, 0, 0]
        version1Hardware.setCSDField(high: 83, low: 80, value: 9)
        version1Hardware.setCSDField(high: 73, low: 62, value: 1_023)
        version1Hardware.setCSDField(high: 49, low: 47, value: 7)
        let version1 = SDCardCSD(
            word0: version1Hardware.csdWords[0],
            word1: version1Hardware.csdWords[1],
            word2: version1Hardware.csdWords[2],
            word3: version1Hardware.csdWords[3]
        )
        expect(version1.logicalBlockCount == 524_288, "bad CSD v1 size")
    }

    private static func initializesAndTransfersExactlyOneBlock() {
        let hardware = TestSDHCIHardware()
        let board = TestSDCardBoard()
        var device = makeDevice(hardware: hardware, board: board)
        expect(device.initialize() == .ready, "valid card did not initialize")
        expect(device.geometry.logicalBlockByteCount == 512, "wrong block size")
        expect(device.geometry.logicalBlockCount == 32_768, "wrong geometry")
        expect(
            hardware.commands.map(\.index) == [0, 8, 55, 41, 2, 3, 9, 7, 55, 6, 13],
            "unexpected initialization command sequence"
        )
        expect(board.calls.count == 1, "board was not prepared exactly once")
        expect(hardware.read16(0x2c) & 4 != 0, "card clock was not enabled")
        expect(hardware.read8(0x28) & 2 != 0, "four-bit bus was not selected")
        expect(hardware.read8(0x28) & 4 == 0, "high-speed mode was enabled")
        expect(hardware.read16(0x3e) & 0x800f == 0, "UHS state was retained")

        var output = [UInt8](repeating: 0, count: 512)
        let readResult = output.withUnsafeMutableBytes {
            device.readBlock(at: 7, into: $0)
        }
        expect(readResult == .success, "single-block read failed")
        expect(output == hardware.readBlock, "PIO read bytes were reordered")
        expect(hardware.commands.last?.index == 17, "CMD17 was not issued")
        expect(hardware.commands.last?.argument == 7, "SDHC LBA was not used")

        var input = [UInt8](repeating: 0, count: 512)
        var index = 0
        while index < input.count {
            input[index] = UInt8(truncatingIfNeeded: index &* 3)
            index += 1
        }
        let writeResult = input.withUnsafeBytes {
            device.writeBlock(at: 9, from: $0)
        }
        expect(writeResult == .success, "single-block write failed")
        expect(hardware.writtenBlock == input, "PIO write bytes were reordered")
        expect(hardware.commands.last?.index == 24, "CMD24 was not issued")
        expect(device.synchronize() == .success, "CMD13 flush failed")
    }

    private static func preservesBoundsFailuresWithoutFaultingDevice() {
        let hardware = TestSDHCIHardware()
        let board = TestSDCardBoard()
        var device = makeDevice(hardware: hardware, board: board)
        expect(device.initialize() == .ready, "setup failed")
        var small = [UInt8](repeating: 0, count: 511)
        expect(
            small.withUnsafeMutableBytes {
                device.readBlock(at: 0, into: $0)
            } == .invalidBuffer,
            "short read buffer was accepted"
        )
        var sector = [UInt8](repeating: 0, count: 512)
        expect(
            sector.withUnsafeMutableBytes {
                device.readBlock(at: device.geometry.logicalBlockCount, into: $0)
            } == .invalidBlock,
            "out-of-range LBA was accepted"
        )
        expect(
            sector.withUnsafeMutableBytes {
                device.readBlock(at: 1, into: $0)
            } == .success,
            "validation failure incorrectly faulted the transport"
        )
    }

    private static func boundsResetClockAndCardNegotiationStalls() {
        let resetHardware = TestSDHCIHardware()
        resetHardware.resetStuck = true
        var resetDevice = makeDevice(
            hardware: resetHardware,
            board: TestSDCardBoard(),
            maximumPollCount: 8
        )
        expect(resetDevice.initialize() == .hostResetTimedOut, "reset stall escaped")
        expect(resetHardware.spinCount == 8, "reset poll bound was not exact")

        let clockHardware = TestSDHCIHardware()
        clockHardware.clockStuck = true
        var clockDevice = makeDevice(
            hardware: clockHardware,
            board: TestSDCardBoard(),
            maximumPollCount: 8
        )
        expect(clockDevice.initialize() == .clockTimedOut, "clock stall escaped")
        expect(clockHardware.spinCount == 8, "clock poll bound was not exact")

        let cardHardware = TestSDHCIHardware()
        cardHardware.operatingConditionsReady = false
        var cardDevice = makeDevice(
            hardware: cardHardware,
            board: TestSDCardBoard(),
            maximumPollCount: 8
        )
        expect(
            cardDevice.initialize() == .cardInitializationTimedOut,
            "ACMD41 stall escaped"
        )
        expect(cardHardware.spinCount <= 10, "card negotiation exceeded its bound")
    }

    private static func makeDevice(
        hardware: TestSDHCIHardware,
        board: TestSDCardBoard,
        maximumPollCount: UInt64 = 64
    ) -> SDHCIBlockDevice<TestSDHCIRegisters, TestSDCardBoard> {
        let configuration = SDHCIDeviceConfiguration(
            inputClockHertz: 200_000_000,
            counterFrequency: 1_000,
            maximumPollCount: maximumPollCount,
            commandTimeoutMilliseconds: 10,
            initializationTimeoutMilliseconds: 20
        )!
        return SDHCIBlockDevice(
            registers: TestSDHCIRegisters(hardware: hardware),
            board: board,
            configuration: configuration
        )!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
