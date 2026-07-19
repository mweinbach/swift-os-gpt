import Foundation

@main
struct PlatformNetworkPinnedDeviceTreeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw ProbeError.usage
        }
        try validateQEMU(path: CommandLine.arguments[1])
        try validateRaspberryPi(path: CommandLine.arguments[2])
        print("pinned platform network Device Tree probes passed")
    }

    private static func validateQEMU(path: String) throws {
        try withTree(path: path) { tree, address in
            guard let first = PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .qemuVirt,
                      at: 0
                  ),
                  first.controller == .virtioMMIOCandidate,
                  first.registers == DeviceResource(
                      baseAddress: 0x0a00_0000,
                      length: 0x200
                  ),
                  first.interrupt == .gicSPI(
                      number: 0x10,
                      trigger: .edgeRising
                  ),
                  first.dma == PlatformNetworkDMARequirements(
                      addressing: .directSystemPhysical,
                      coherency: .hardwareCoherent
                  ),
                  let last = PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .qemuVirt,
                      at: 31
                  ),
                  last.registers == DeviceResource(
                      baseAddress: 0x0a00_3e00,
                      length: 0x200
                  ),
                  last.interrupt == .gicSPI(
                      number: 0x2f,
                      trigger: .edgeRising
                  ),
                  PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .qemuVirt,
                      at: 32
                  ) == nil,
                  Platform.discover(deviceTreeAddress: address)?
                      .networkDeviceCandidate(at: 0) == first
            else {
                throw ProbeError.invalidQEMUDescription
            }
        }
    }

    private static func validateRaspberryPi(path: String) throws {
        try withTree(path: path) { tree, address in
            guard let description = PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .raspberryPi5,
                      at: 0
                  ),
                  description.controller == .rp1GEM,
                  description.registers == DeviceResource(
                      baseAddress: 0x1f_0010_0000,
                      length: 0x4_000
                  ),
                  description.interrupt == .rp1MSIX(
                      vector: 6,
                      trigger: .levelHigh
                  ),
                  description.dma == PlatformNetworkDMARequirements(
                      addressing: .translatedByParentBus,
                      coherency: .softwareManaged
                  ),
                  let boardResources = description.boardResources,
                  case .rp1GEM(let rp1) = boardResources,
                  rp1.gemRegisters == description.registers,
                  rp1.ethernetConfigurationRegisters == DeviceResource(
                      baseAddress: 0x1f_0010_4000,
                      length: 0x4_000
                  ),
                  rp1.clocks == RP1GEMClockResources(
                      controllerPhandle: 2,
                      controllerRegisters: DeviceResource(
                          baseAddress: 0x1f_0001_8000,
                          length: 0x1_0038
                      ),
                      peripheralClockID: 12,
                      hostClockID: 12,
                      timestampClockID: 29,
                      transmitClockID: 16
                  ),
                  rp1.phy == PlatformNetworkPHYDescription(
                      clause22Address: 1,
                      mode: .rgmiiID
                  ),
                  rp1.phyReset == PlatformPHYResetDescription(
                      gpioControllerPhandle: 0x2e,
                      gpioRegisters: RP1GPIORegisterResources(
                          ioBank: DeviceResource(
                              baseAddress: 0x1f_000d_0000,
                              length: 0xc_000
                          ),
                          rio: DeviceResource(
                              baseAddress: 0x1f_000e_0000,
                              length: 0xc_000
                          ),
                          padsBank: DeviceResource(
                              baseAddress: 0x1f_000f_0000,
                              length: 0xc_000
                          )
                      ),
                      line: 32,
                      assertedLevel: .low,
                      durationMilliseconds: 5
                  ),
                  rp1.localMACAddress == PlatformMACAddressBytes(
                      byte0: 0,
                      byte1: 0,
                      byte2: 0,
                      byte3: 0,
                      byte4: 0,
                      byte5: 0
                  ),
                  rp1.localMACAddress?.isAllZero == true,
                  rp1.localMACAddress?.isUsableUnicast == false,
                  PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .raspberryPi5,
                      at: 1
                  ) == nil,
                  Platform.discover(deviceTreeAddress: address)?
                      .networkDeviceCandidate(at: 0) == description
            else {
                throw ProbeError.invalidRaspberryPiDescription
            }
        }
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
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case invalidBlob(String)
    case invalidQEMUDescription
    case invalidRaspberryPiDescription

    var description: String {
        switch self {
        case .usage:
            return "usage: probe <qemu-virt.dtb> <bcm2712-rpi-5-b.dtb>"
        case .invalidBlob(let path):
            return "invalid Device Tree blob: \(path)"
        case .invalidQEMUDescription:
            return "QEMU network discovery did not match the pinned DTB"
        case .invalidRaspberryPiDescription:
            return "Pi 5 network discovery did not match the pinned DTB"
        }
    }
}
