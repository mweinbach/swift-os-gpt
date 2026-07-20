import Foundation

@main
struct PlatformStoragePinnedDeviceTreeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ProbeError.usage }
        try withTree(path: CommandLine.arguments[1]) { tree, address in
            try validatesExactRemovableSlot(tree: tree, address: address)
            validatesBoundedBootResources(tree: tree)
            validatesHostileDisjointResourcesDoNotMapTheirGap()
        }
        print("pinned Pi 5 storage Device Tree: 3 groups passed")
    }

    private static func validatesExactRemovableSlot(
        tree: FlattenedDeviceTree,
        address: UInt64
    ) throws {
        let expected = PlatformStorageDeviceDescription(
            controller: .bcm2712SDHCI,
            hostRegisters: DeviceResource(
                baseAddress: 0x10_00ff_f000,
                length: 0x260
            ),
            configurationRegisters: DeviceResource(
                baseAddress: 0x10_00ff_f400,
                length: 0x200
            ),
            interrupt: .sharedPeripheral(
                number: 0x111,
                trigger: .levelHigh
            ),
            inputClockHertz: 200_000_000,
            busWidth: 4,
            power: PlatformSDCardPowerResources(
                gpioControllerPhandle: 0x0d,
                gpioRegisters: DeviceResource(
                    baseAddress: 0x10_7d51_7c00,
                    length: 0x40
                ),
                ioVoltageSelectLine: 3,
                io3V3SelectLevel: .low,
                cardPowerEnableLine: 4,
                cardPowerEnabledLevel: .high,
                cardDetectLine: 5,
                cardDetectPresentLevel: .low,
                voltageSettlingMicroseconds: 5_000
            )
        )
        guard PlatformStorageDeviceDiscovery.systemDevice(
                  in: tree,
                  board: .raspberryPi5
              ) == expected,
              expected.interrupt.architecturalInterruptID == 0x131,
              Platform.discover(deviceTreeAddress: address)?
                  .systemStorageDevice == expected,
              PlatformStorageDeviceDiscovery.systemDevice(
                  in: tree,
                  board: .qemuVirt
              ) == nil
        else { throw ProbeError.invalidPinnedDescription }
    }

    private static func validatesBoundedBootResources(
        tree: FlattenedDeviceTree
    ) {
        let description = PlatformStorageDeviceDiscovery.systemDevice(
            in: tree,
            board: .raspberryPi5
        )!
        var resources = BootDriverResourceSet()
        expect(
            PlatformStorageBootResources.append(
                description: description,
                to: &resources
            ),
            "pinned storage apertures were not retained"
        )
        expect(resources.mmioResourceCount == 2, "same-page host/cfg were duplicated")
        expect(
            resources.mmioResource(at: 0) == DeviceResource(
                baseAddress: 0x10_00ff_f000,
                length: 0x1_000
            ),
            "controller page was not normalized exactly"
        )
        expect(
            resources.mmioResource(at: 1) == description.power.gpioRegisters,
            "AON GPIO aperture was not retained separately"
        )
        var index = resources.mmioResourceCount
        while index < BootDriverResourceSet.maximumMMIOResourceCount {
            expect(
                resources.append(
                    mmio: DeviceResource(
                        baseAddress: 0x20_0000_0000 + UInt64(index) * 0x2_000,
                        length: 0x100
                    )
                ),
                "declared MMIO capacity was not usable"
            )
            index += 1
        }
        expect(
            !resources.append(
                mmio: DeviceResource(baseAddress: 0x30_0000_0000, length: 0x100)
            ),
            "seventeenth retained MMIO resource exceeded the fixed contract"
        )
    }

    private static func validatesHostileDisjointResourcesDoNotMapTheirGap() {
        let hostile = syntheticDescription(
            host: DeviceResource(baseAddress: 0x1003, length: 0x100),
            configuration: DeviceResource(
                baseAddress: 0x9000_0007,
                length: 0x200
            )
        )
        var resources = BootDriverResourceSet()
        expect(
            PlatformStorageBootResources.append(
                description: hostile,
                to: &resources
            ),
            "disjoint controller pages were rejected"
        )
        expect(resources.mmioResourceCount == 3, "disjoint pages were coalesced")
        expect(
            resources.mmioResource(at: 0) == DeviceResource(
                baseAddress: 0x1000,
                length: 0x1000
            ),
            "host page was broadened"
        )
        expect(
            resources.mmioResource(at: 1) == DeviceResource(
                baseAddress: 0x9000_0000,
                length: 0x1000
            ),
            "configuration page was broadened"
        )

        // Two byte-disjoint tuples that share only one normalized page cannot
        // become separate entries. The append must fail transactionally.
        let ambiguous = syntheticDescription(
            host: DeviceResource(baseAddress: 0x2000, length: 0x1100),
            configuration: DeviceResource(baseAddress: 0x3800, length: 0x100)
        )
        var unchanged = BootDriverResourceSet()
        expect(
            !PlatformStorageBootResources.append(
                description: ambiguous,
                to: &unchanged
            ),
            "partially overlapping normalized pages were accepted"
        )
        expect(unchanged.mmioResourceCount == 0, "failed append was not transactional")
    }

    private static func syntheticDescription(
        host: DeviceResource,
        configuration: DeviceResource
    ) -> PlatformStorageDeviceDescription {
        PlatformStorageDeviceDescription(
            controller: .bcm2712SDHCI,
            hostRegisters: host,
            configurationRegisters: configuration,
            interrupt: .sharedPeripheral(number: 1, trigger: .levelHigh),
            inputClockHertz: 200_000_000,
            busWidth: 4,
            power: PlatformSDCardPowerResources(
                gpioControllerPhandle: 1,
                gpioRegisters: DeviceResource(
                    baseAddress: 0xa000_0000,
                    length: 0x40
                ),
                ioVoltageSelectLine: 3,
                io3V3SelectLevel: .low,
                cardPowerEnableLine: 4,
                cardPowerEnabledLevel: .high,
                cardDetectLine: 5,
                cardDetectPresentLevel: .low,
                voltageSettlingMicroseconds: 5_000
            )
        )
    }

    private static func withTree(
        path: String,
        body: (FlattenedDeviceTree, UInt64) throws -> Void
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: data.count,
            alignment: 8
        )
        defer { storage.deallocate() }
        data.copyBytes(
            to: storage.assumingMemoryBound(to: UInt8.self),
            count: data.count
        )
        let address = UInt64(UInt(bitPattern: storage))
        guard let tree = FlattenedDeviceTree(address: address) else {
            throw ProbeError.invalidBlob(path)
        }
        try body(tree, address)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}

private enum ProbeError: Error {
    case usage
    case invalidBlob(String)
    case invalidPinnedDescription
}
