/// Fixed linker-owned DMA and network-stack workspace for RP1 GEM.
///
/// The first page is reserved exclusively for two-word GEM descriptors and is
/// mapped Normal Non-Cacheable by the final address space. The remaining three
/// pages stay Normal Write-Back and contain packet buffers plus disjoint IPv4
/// scratch. No allocation or retained borrowed pointer is involved.
struct RP1GEMBootstrapMemory: Equatable {
    static let workspacePageCount: UInt64 = 4
    static let workspaceByteCount = workspacePageCount
        * MemoryPageGeometry.pageSize
    static let descriptorPageByteCount = MemoryPageGeometry.pageSize
    static let descriptorCount: UInt16 = 2
    static let descriptorRegionByteCount: UInt64 = 64
    static let packetBufferByteCount = CadenceGEMConfiguration
        .packetBufferByteCount
    static let bufferSetByteCount = UInt64(descriptorCount)
        * packetBufferByteCount
    static let scratchByteCount: UInt64 = 1_536

    private enum Offset {
        static let receiveDescriptors: UInt64 = 0
        static let transmitDescriptors = descriptorRegionByteCount
        static let receiveBuffers = descriptorPageByteCount
        static let transmitBuffers = receiveBuffers + bufferSetByteCount
        static let receiveScratch = transmitBuffers + bufferSetByteCount
        static let transmitScratch = receiveScratch + scratchByteCount
        static let usedEnd = transmitScratch + scratchByteCount
    }

    let cpuBaseAddress: UInt64
    let deviceBaseAddress: UInt64
    let storage: CadenceGEMDMAStorage
    let descriptorPage: LinkerRegion
    let cacheablePages: LinkerRegion
    let receiveScratchAddress: UInt64
    let transmitScratchAddress: UInt64

    /// Accepts one contiguous CPU-to-device translation for the entire linked
    /// workspace. RP1's DMA address is allowed to differ from its CPU physical
    /// address, but every translated byte must fit the advertised width.
    init?(
        cpuBaseAddress: UInt64,
        byteCount: UInt64,
        deviceBaseAddress: UInt64,
        deviceAddressWidth: DMAAddressWidth
    ) {
        guard byteCount == Self.workspaceByteCount,
              MemoryPageGeometry.isPageAligned(cpuBaseAddress),
              MemoryPageGeometry.isPageAligned(deviceBaseAddress),
              byteCount <= UInt64.max - cpuBaseAddress,
              cpuBaseAddress <= UInt64(UInt.max),
              byteCount - 1 <= UInt64(UInt.max) - cpuBaseAddress,
              UnsafeMutableRawPointer(
                  bitPattern: UInt(cpuBaseAddress)
              ) != nil,
              deviceAddressWidth.contains(
                  address: deviceBaseAddress,
                  byteCount: byteCount
              ),
              Offset.usedEnd <= byteCount,
              let descriptorEnd = Self.adding(
                  cpuBaseAddress,
                  Self.descriptorPageByteCount
              ),
              let workspaceEnd = Self.adding(cpuBaseAddress, byteCount),
              descriptorEnd > cpuBaseAddress,
              workspaceEnd > descriptorEnd,
              let receiveDescriptors = Self.region(
                  cpuBaseAddress: cpuBaseAddress,
                  deviceBaseAddress: deviceBaseAddress,
                  offset: Offset.receiveDescriptors,
                  byteCount: Self.descriptorRegionByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  cacheMode: .uncached
              ),
              let transmitDescriptors = Self.region(
                  cpuBaseAddress: cpuBaseAddress,
                  deviceBaseAddress: deviceBaseAddress,
                  offset: Offset.transmitDescriptors,
                  byteCount: Self.descriptorRegionByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  cacheMode: .uncached
              ),
              let receiveBuffers = Self.region(
                  cpuBaseAddress: cpuBaseAddress,
                  deviceBaseAddress: deviceBaseAddress,
                  offset: Offset.receiveBuffers,
                  byteCount: Self.bufferSetByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  cacheMode: .writeBack
              ),
              let transmitBuffers = Self.region(
                  cpuBaseAddress: cpuBaseAddress,
                  deviceBaseAddress: deviceBaseAddress,
                  offset: Offset.transmitBuffers,
                  byteCount: Self.bufferSetByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  cacheMode: .writeBack
              ),
              let storage = CadenceGEMDMAStorage(
                  receiveDescriptors: receiveDescriptors,
                  receiveDescriptorCount: Self.descriptorCount,
                  transmitDescriptors: transmitDescriptors,
                  transmitDescriptorCount: Self.descriptorCount,
                  receiveBuffers: receiveBuffers,
                  transmitBuffers: transmitBuffers
              ),
              let receiveScratchAddress = Self.adding(
                  cpuBaseAddress,
                  Offset.receiveScratch
              ),
              let transmitScratchAddress = Self.adding(
                  cpuBaseAddress,
                  Offset.transmitScratch
              )
        else {
            return nil
        }

        self.cpuBaseAddress = cpuBaseAddress
        self.deviceBaseAddress = deviceBaseAddress
        self.storage = storage
        descriptorPage = LinkerRegion(
            start: cpuBaseAddress,
            end: descriptorEnd
        )
        cacheablePages = LinkerRegion(
            start: descriptorEnd,
            end: workspaceEnd
        )
        self.receiveScratchAddress = receiveScratchAddress
        self.transmitScratchAddress = transmitScratchAddress
    }

    var workspace: LinkerRegion {
        LinkerRegion(
            start: cpuBaseAddress,
            end: cpuBaseAddress + Self.workspaceByteCount
        )
    }

    private static func region(
        cpuBaseAddress: UInt64,
        deviceBaseAddress: UInt64,
        offset: UInt64,
        byteCount: UInt64,
        deviceAddressWidth: DMAAddressWidth,
        cacheMode: CadenceGEMCPUCacheMode
    ) -> CadenceGEMDMARegion? {
        guard let cpuAddress = adding(cpuBaseAddress, offset),
              let deviceAddress = adding(deviceBaseAddress, offset),
              let mapping = DMAMapping(
                  cpuPhysicalAddress: cpuAddress,
                  deviceAddress: deviceAddress,
                  byteCount: byteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: .softwareManaged
              )
        else {
            return nil
        }
        return CadenceGEMDMARegion(
            mapping: mapping,
            cpuCacheMode: cacheMode
        )
    }

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard right <= UInt64.max - left else { return nil }
        return left + right
    }
}
