enum PlatformStorageControllerKind: UInt8, Equatable {
    case bcm2712SDHCI
}

/// The SD slot is polled during bring-up, but its interrupt route is retained
/// so a later asynchronous transport can use the same discovery result.
struct PlatformStorageInterruptRoute: Equatable {
    /// Zero-based SPI number from the Arm GIC Device Tree binding.
    let spiNumber: UInt32
    let trigger: PlatformInterruptTrigger

    var architecturalGICInterruptID: UInt32? {
        guard spiNumber <= UInt32.max - 32 else { return nil }
        return spiNumber + 32
    }
}

enum PlatformGPIOLevel: UInt8, Equatable {
    case low
    case high
}

/// Firmware-described GPIO policy needed to return the removable Pi 5 slot to
/// a known 3.3-V initialization state. Both supplies are marked boot-on in the
/// board DT, but SwiftOS still power-cycles VMMC so it never inherits a card
/// protocol state or signalling voltage from the boot firmware.
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

/// Board-neutral description consumed by a standard SDHCI transport. Both
/// register tuples are already translated into CPU physical addresses.
struct PlatformStorageDeviceDescription: Equatable {
    let controller: PlatformStorageControllerKind
    let hostRegisters: DeviceResource
    let configurationRegisters: DeviceResource
    let interrupt: PlatformStorageInterruptRoute
    let inputClockHertz: UInt32
    let busWidth: UInt32
    let power: PlatformSDCardPowerResources
}

/// Allocation-free Device Tree discovery for the system data device. The Pi 5
/// tree also has a non-removable BCM2712 SDHCI Wi-Fi function and disabled RP1
/// MMC nodes; removable-slot properties select the boot microSD without fixed
/// addresses or node-order policy.
struct PlatformStorageDeviceDiscovery {
    static let maximumCandidateCount = 8

    static func systemDevice(
        in tree: FlattenedDeviceTree,
        board: BoardKind
    ) -> PlatformStorageDeviceDescription? {
        switch board {
        case .qemuVirt:
            return nil
        case .raspberryPi5:
            return raspberryPi5BootSD(in: tree)
        }
    }

    private static func raspberryPi5BootSD(
        in tree: FlattenedDeviceTree
    ) -> PlatformStorageDeviceDescription? {
        var selected: PlatformStorageDeviceDescription?
        var nodeIndex = 0
        while nodeIndex < maximumCandidateCount,
              tree.resource(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  registerIndex: 0
              ) != nil {
            defer { nodeIndex += 1 }

            // The on-board Wi-Fi controller is non-removable. The physical
            // microSD slot instead publishes an external card-detect GPIO.
            if tree.hasProperty(
                compatibleWith: "brcm,bcm2712-sdhci",
                nodeIndex: nodeIndex,
                property: "non-removable"
            ) {
                continue
            }
            guard tree.hasProperty(
                      compatibleWith: "brcm,bcm2712-sdhci",
                      nodeIndex: nodeIndex,
                      property: "cd-gpios"
                  ), selected == nil,
                  let description = raspberryPi5RemovableSD(
                      in: tree,
                      nodeIndex: nodeIndex
                  )
            else {
                return nil
            }
            selected = description
        }
        guard nodeIndex < maximumCandidateCount else { return nil }
        return selected
    }

    private static func raspberryPi5RemovableSD(
        in tree: FlattenedDeviceTree,
        nodeIndex: Int
    ) -> PlatformStorageDeviceDescription? {
        guard let host = tree.resource(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  registerIndex: 0
              ), let configuration = tree.resource(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  registerIndex: 1
              ), valid(host, minimumLength: 0x100),
              valid(configuration, minimumLength: 0x1b0),
              disjoint(host, configuration),
              let registerNames = tree.propertyBytes(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "reg-names"
              ), registerNames.cStringCount == 2,
              registerNames.cString(at: 0, equals: "host"),
              registerNames.cString(at: 1, equals: "cfg"),
              let interruptCells = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "interrupts"
              ), interruptCells.count == 3,
              interruptCells.cell(at: 0) == 0,
              let spiNumber = interruptCells.cell(at: 1),
              let triggerValue = interruptCells.cell(at: 2),
              let trigger = PlatformInterruptTrigger(rawValue: triggerValue),
              let clockCells = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "clocks"
              ), clockCells.count == 1,
              let clockPhandle = clockCells.cell(at: 0),
              clockPhandle != 0,
              let clockNames = tree.propertyBytes(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "clock-names"
              ), clockNames.cStringCount == 1,
              clockNames.cString(at: 0, equals: "sw_sdio"),
              let frequencyCells = tree.propertyCells(
                  nodePhandle: clockPhandle,
                  property: "clock-frequency"
              ), frequencyCells.count == 1,
              let inputClockHertz = frequencyCells.cell(at: 0),
              inputClockHertz >= 1_000_000,
              let busWidthCells = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "bus-width"
              ), busWidthCells.count == 1,
              busWidthCells.cell(at: 0) == 4,
              let power = powerResources(in: tree, nodeIndex: nodeIndex)
        else {
            return nil
        }

        return PlatformStorageDeviceDescription(
            controller: .bcm2712SDHCI,
            hostRegisters: host,
            configurationRegisters: configuration,
            interrupt: PlatformStorageInterruptRoute(
                spiNumber: spiNumber,
                trigger: trigger
            ),
            inputClockHertz: inputClockHertz,
            busWidth: 4,
            power: power
        )
    }

    private static func powerResources(
        in tree: FlattenedDeviceTree,
        nodeIndex: Int
    ) -> PlatformSDCardPowerResources? {
        guard let vmmcCells = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "vmmc-supply"
              ), vmmcCells.count == 1,
              let vmmc = vmmcCells.cell(at: 0),
              vmmc != 0,
              let vqmmcCells = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "vqmmc-supply"
              ), vqmmcCells.count == 1,
              let vqmmc = vqmmcCells.cell(at: 0),
              vqmmc != 0,
              vmmc != vqmmc,
              tree.hasProperty(nodePhandle: vmmc, property: "regulator-boot-on"),
              tree.hasProperty(nodePhandle: vmmc, property: "enable-active-high"),
              tree.hasProperty(nodePhandle: vqmmc, property: "regulator-boot-on"),
              tree.hasProperty(nodePhandle: vqmmc, property: "regulator-always-on"),
              fixed3V3Supply(phandle: vmmc, in: tree),
              let voltageGPIO = tree.propertyCells(
                  nodePhandle: vqmmc,
                  property: "gpios"
              ), voltageGPIO.count == 3,
              let voltageController = voltageGPIO.cell(at: 0),
              let voltageLine = voltageGPIO.cell(at: 1),
              voltageGPIO.cell(at: 2) == 0,
              let voltageStates = tree.propertyCells(
                  nodePhandle: vqmmc,
                  property: "states"
              ), voltageStates.count == 4,
              let threeVoltState = stateValue(
                  forMicrovolts: 3_300_000,
                  in: voltageStates
              ), threeVoltState < 2,
              let powerGPIO = tree.propertyCells(
                  nodePhandle: vmmc,
                  property: "gpios"
              ), powerGPIO.count == 3,
              powerGPIO.cell(at: 0) == voltageController,
              let powerLine = powerGPIO.cell(at: 1),
              powerGPIO.cell(at: 2) == 0,
              let detectGPIO = tree.propertyCells(
                  compatibleWith: "brcm,bcm2712-sdhci",
                  nodeIndex: nodeIndex,
                  property: "cd-gpios"
              ), detectGPIO.count == 3,
              detectGPIO.cell(at: 0) == voltageController,
              let detectLine = detectGPIO.cell(at: 1),
              detectGPIO.cell(at: 2) == 1,
              voltageLine < 32,
              powerLine < 32,
              detectLine < 32,
              voltageLine != powerLine,
              voltageLine != detectLine,
              powerLine != detectLine,
              let gpio = gpioController(
                  phandle: voltageController,
                  in: tree
              ), let settlingCells = tree.propertyCells(
                  nodePhandle: vqmmc,
                  property: "regulator-settling-time-us"
              ), settlingCells.count == 1,
              let settlingMicroseconds = settlingCells.cell(at: 0),
              settlingMicroseconds > 0,
              settlingMicroseconds <= 1_000_000
        else {
            return nil
        }

        return PlatformSDCardPowerResources(
            gpioControllerPhandle: voltageController,
            gpioRegisters: gpio,
            ioVoltageSelectLine: voltageLine,
            io3V3SelectLevel: threeVoltState == 0 ? .low : .high,
            cardPowerEnableLine: powerLine,
            cardPowerEnabledLevel: .high,
            cardDetectLine: detectLine,
            cardDetectPresentLevel: .low,
            voltageSettlingMicroseconds: settlingMicroseconds
        )
    }

    private static func fixed3V3Supply(
        phandle: UInt32,
        in tree: FlattenedDeviceTree
    ) -> Bool {
        guard let minimum = tree.propertyCells(
                  nodePhandle: phandle,
                  property: "regulator-min-microvolt"
              ), minimum.count == 1,
              minimum.cell(at: 0) == 3_300_000,
              let maximum = tree.propertyCells(
                  nodePhandle: phandle,
                  property: "regulator-max-microvolt"
              ), maximum.count == 1,
              maximum.cell(at: 0) == 3_300_000
        else {
            return false
        }
        return true
    }

    private static func stateValue(
        forMicrovolts microvolts: UInt32,
        in cells: DeviceTreePropertyCells
    ) -> UInt32? {
        guard cells.count > 0, cells.count & 1 == 0 else { return nil }
        var index = 0
        var match: UInt32?
        while index < cells.count {
            guard let voltage = cells.cell(at: index),
                  let state = cells.cell(at: index + 1)
            else {
                return nil
            }
            if voltage == microvolts {
                guard match == nil else { return nil }
                match = state
            }
            index += 2
        }
        return match
    }

    private static func gpioController(
        phandle: UInt32,
        in tree: FlattenedDeviceTree
    ) -> DeviceResource? {
        var selected: DeviceResource?
        var index = 0
        while index < maximumCandidateCount,
              let resource = tree.resource(
                  compatibleWith: "brcm,brcmstb-gpio",
                  nodeIndex: index
              ) {
            let standard = tree.propertyCells(
                compatibleWith: "brcm,brcmstb-gpio",
                nodeIndex: index,
                property: "phandle"
            )
            let legacy = tree.propertyCells(
                compatibleWith: "brcm,brcmstb-gpio",
                nodeIndex: index,
                property: "linux,phandle"
            )
            let standardMatches = standard?.count == 1
                && standard?.cell(at: 0) == phandle
            let legacyMatches = legacy?.count == 1
                && legacy?.cell(at: 0) == phandle
            if standardMatches || legacyMatches {
                guard selected == nil,
                      let widths = tree.propertyCells(
                          compatibleWith: "brcm,brcmstb-gpio",
                          nodeIndex: index,
                          property: "brcm,gpio-bank-widths"
                      ), widths.count > 0,
                      let firstWidth = widths.cell(at: 0),
                      firstWidth >= 6,
                      valid(resource, minimumLength: 0x20)
                else {
                    return nil
                }
                selected = resource
            }
            index += 1
        }
        guard index < maximumCandidateCount else { return nil }
        return selected
    }

    private static func valid(
        _ resource: DeviceResource,
        minimumLength: UInt64
    ) -> Bool {
        resource.baseAddress & 0x3 == 0
            && resource.length >= minimumLength
            && resource.length <= UInt64.max - resource.baseAddress
    }

    private static func disjoint(
        _ first: DeviceResource,
        _ second: DeviceResource
    ) -> Bool {
        first.baseAddress + first.length <= second.baseAddress
            || second.baseAddress + second.length <= first.baseAddress
    }
}

extension Platform {
    var systemStorageDevice: PlatformStorageDeviceDescription? {
        PlatformStorageDeviceDiscovery.systemDevice(
            in: deviceTree,
            board: kind
        )
    }
}
