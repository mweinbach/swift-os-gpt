/// One exact, identity-mapped memory span retained by an early driver across
/// the bootstrap-to-final page-table transition.
struct DriverMemoryResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
    let role: MemoryRegionRole
    let reservesSystemMemory: Bool

    init?(
        baseAddress: UInt64,
        length: UInt64,
        role: MemoryRegionRole,
        reservesSystemMemory: Bool
    ) {
        guard length > 0,
              length <= UInt64.max - baseAddress,
              let alignedEnd = MemoryPageGeometry.alignUp(
                  baseAddress + length
              )
        else {
            return nil
        }
        let alignedBase = MemoryPageGeometry.alignDown(baseAddress)
        guard alignedEnd > alignedBase,
              role == .kernelData
        else {
            return nil
        }
        self.baseAddress = alignedBase
        self.length = alignedEnd - alignedBase
        self.role = role
        self.reservesSystemMemory = reservesSystemMemory
    }

    var endAddress: UInt64 {
        baseAddress + length
    }
}

/// Heap-free resources emitted by early driver discovery. The fixed capacity
/// is an explicit boot contract: adding a driver never silently grows metadata
/// or changes the page-table layout after the MMU switches.
struct BootDriverResourceSet {
    static let maximumMemoryResourceCount = 8
    static let maximumMMIOResourceCount = 8

    private var memory0: DriverMemoryResource?
    private var memory1: DriverMemoryResource?
    private var memory2: DriverMemoryResource?
    private var memory3: DriverMemoryResource?
    private var memory4: DriverMemoryResource?
    private var memory5: DriverMemoryResource?
    private var memory6: DriverMemoryResource?
    private var memory7: DriverMemoryResource?

    private var mmio0: DeviceResource?
    private var mmio1: DeviceResource?
    private var mmio2: DeviceResource?
    private var mmio3: DeviceResource?
    private var mmio4: DeviceResource?
    private var mmio5: DeviceResource?
    private var mmio6: DeviceResource?
    private var mmio7: DeviceResource?

    private(set) var memoryResourceCount = 0
    private(set) var mmioResourceCount = 0

    init() {}

    mutating func append(memory resource: DriverMemoryResource) -> Bool {
        guard memoryResourceCount < Self.maximumMemoryResourceCount else {
            return false
        }
        var index = 0
        while index < memoryResourceCount {
            guard let existing = memoryResource(at: index) else {
                return false
            }
            if overlaps(existing, resource) {
                return false
            }
            index += 1
        }
        index = 0
        while index < mmioResourceCount {
            guard let existing = mmioResource(at: index),
                  !overlaps(resource, existing)
            else {
                return false
            }
            index += 1
        }
        switch memoryResourceCount {
        case 0: memory0 = resource
        case 1: memory1 = resource
        case 2: memory2 = resource
        case 3: memory3 = resource
        case 4: memory4 = resource
        case 5: memory5 = resource
        case 6: memory6 = resource
        default: memory7 = resource
        }
        memoryResourceCount += 1
        return true
    }

    mutating func append(mmio resource: DeviceResource) -> Bool {
        guard normalizedInterval(for: resource) != nil,
              mmioResourceCount < Self.maximumMMIOResourceCount
        else {
            return false
        }
        var index = 0
        while index < mmioResourceCount {
            guard let existing = mmioResource(at: index) else {
                return false
            }
            if overlaps(existing, resource) {
                return false
            }
            index += 1
        }
        index = 0
        while index < memoryResourceCount {
            guard let existing = memoryResource(at: index),
                  !overlaps(existing, resource)
            else {
                return false
            }
            index += 1
        }
        switch mmioResourceCount {
        case 0: mmio0 = resource
        case 1: mmio1 = resource
        case 2: mmio2 = resource
        case 3: mmio3 = resource
        case 4: mmio4 = resource
        case 5: mmio5 = resource
        case 6: mmio6 = resource
        default: mmio7 = resource
        }
        mmioResourceCount += 1
        return true
    }

    func memoryResource(at index: Int) -> DriverMemoryResource? {
        guard index >= 0, index < memoryResourceCount else { return nil }
        switch index {
        case 0: return memory0
        case 1: return memory1
        case 2: return memory2
        case 3: return memory3
        case 4: return memory4
        case 5: return memory5
        case 6: return memory6
        default: return memory7
        }
    }

    func mmioResource(at index: Int) -> DeviceResource? {
        guard index >= 0, index < mmioResourceCount else { return nil }
        switch index {
        case 0: return mmio0
        case 1: return mmio1
        case 2: return mmio2
        case 3: return mmio3
        case 4: return mmio4
        case 5: return mmio5
        case 6: return mmio6
        default: return mmio7
        }
    }

    private func overlaps(
        _ first: DriverMemoryResource,
        _ second: DriverMemoryResource
    ) -> Bool {
        first.baseAddress < second.endAddress
            && second.baseAddress < first.endAddress
    }

    private func overlaps(
        _ first: DeviceResource,
        _ second: DeviceResource
    ) -> Bool {
        guard let first = normalizedInterval(for: first),
              let second = normalizedInterval(for: second)
        else {
            return true
        }
        return first.base < second.end && second.base < first.end
    }

    private func overlaps(
        _ memory: DriverMemoryResource,
        _ mmio: DeviceResource
    ) -> Bool {
        guard let mmio = normalizedInterval(for: mmio) else {
            return true
        }
        return memory.baseAddress < mmio.end
            && mmio.base < memory.endAddress
    }

    private func normalizedInterval(
        for resource: DeviceResource
    ) -> (base: UInt64, end: UInt64)? {
        guard resource.length > 0,
              resource.length <= UInt64.max - resource.baseAddress,
              let end = MemoryPageGeometry.alignUp(
                  resource.baseAddress + resource.length
              )
        else {
            return nil
        }
        let base = MemoryPageGeometry.alignDown(resource.baseAddress)
        guard end > base else { return nil }
        return (base: base, end: end)
    }
}
