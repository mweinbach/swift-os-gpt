enum PlatformWatchdogDescription: Equatable {
    case bcm2712PM(registers: DeviceResource)
}

enum PlatformWatchdogDiscovery {
    static func watchdog(
        in tree: FlattenedDeviceTree,
        board: BoardKind
    ) -> PlatformWatchdogDescription? {
        guard board == .raspberryPi5,
              tree.hasCompatibleNode("brcm,bcm2712-pm", nodeIndex: 0),
              !tree.hasCompatibleNode("brcm,bcm2712-pm", nodeIndex: 1),
              let registers = tree.resource(
                  compatibleWith: "brcm,bcm2712-pm"
              ),
              tree.hasProperty(
                  compatibleWith: "brcm,bcm2712-pm",
                  property: "system-power-controller"
              ),
              registers.baseAddress & 0x3 == 0,
              registers.length >= 0x28,
              registers.length <= UInt64.max - registers.baseAddress
        else { return nil }
        return .bcm2712PM(registers: registers)
    }
}

extension Platform {
    var systemWatchdog: PlatformWatchdogDescription? {
        PlatformWatchdogDiscovery.watchdog(in: deviceTree, board: kind)
    }
}
