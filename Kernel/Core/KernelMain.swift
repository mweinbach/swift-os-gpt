private nonisolated(unsafe) var zeroProbe: UInt64 = 0
private nonisolated(unsafe) var dataProbe: UInt64 = 0x5357_4946_544f_5301

@_cdecl("swiftos_main")
func swiftOSMain(_ deviceTreeAddress: UInt64) {
    let console = EarlyConsole(uart: PL011(baseAddress: 0x0900_0000))

    console.write("SWIFTOS:BOOT\n")

    guard AArch64.currentExceptionLevel == 1 else {
        console.write("SWIFTOS:PANIC:BAD_EL\n")
        park()
    }
    console.write("SWIFTOS:EL1\n")

    guard zeroProbe == 0 else {
        console.write("SWIFTOS:PANIC:BSS\n")
        park()
    }
    zeroProbe = 0x4253_535f_4f4b
    guard zeroProbe == 0x4253_535f_4f4b else {
        console.write("SWIFTOS:PANIC:BSS_WRITE\n")
        park()
    }
    console.write("SWIFTOS:BSS_OK\n")

    guard dataProbe == 0x5357_4946_544f_5301 else {
        console.write("SWIFTOS:PANIC:DATA\n")
        park()
    }
    dataProbe &+= 1
    guard dataProbe == 0x5357_4946_544f_5302 else {
        console.write("SWIFTOS:PANIC:DATA_WRITE\n")
        park()
    }
    console.write("SWIFTOS:DATA_OK\n")

    guard AArch64.stackPointer & 0xf == 0 else {
        console.write("SWIFTOS:PANIC:STACK_ALIGNMENT\n")
        park()
    }
    guard AArch64.systemControl & 0x1005 == 0x1005 else {
        console.write("SWIFTOS:PANIC:MMU_CACHE\n")
        park()
    }

    console.write("SWIFTOS:DTB=")
    console.writeHex(deviceTreeAddress)
    console.write("\n")

    guard let deviceTree = FlattenedDeviceTree(address: deviceTreeAddress),
          let serial = deviceTree.resource(compatibleWith: "arm,pl011"),
          serial.baseAddress == 0x0900_0000,
          serial.length >= 0x30,
          let firmwareConfiguration = deviceTree.resource(
              compatibleWith: "qemu,fw-cfg-mmio"
          ),
          firmwareConfiguration.length >= 0x18
    else {
        console.write("SWIFTOS:PANIC:FDT\n")
        park()
    }
    console.write("SWIFTOS:FDT_OK\n")
    console.write("SWIFTOS:SWIFT_OK\n")

    timerBeat(console: console, marker: "SWIFTOS:TIMER_1\n")
    timerBeat(console: console, marker: "SWIFTOS:TIMER_2\n")
    timerBeat(console: console, marker: "SWIFTOS:TIMER_3\n")
    console.write("SWIFTOS:READY\n")
    park()
}

private func timerBeat(console: EarlyConsole, marker: StaticString) {
    let frequency = AArch64.counterFrequency
    guard frequency > 0 else {
        console.write("SWIFTOS:PANIC:TIMER_FREQUENCY\n")
        park()
    }

    let start = AArch64.counterValue
    let duration = frequency / 100
    while AArch64.counterValue &- start < duration {}
    console.write(marker)
}

private func park() -> Never {
    while true {
        AArch64.waitForEvent()
    }
}
