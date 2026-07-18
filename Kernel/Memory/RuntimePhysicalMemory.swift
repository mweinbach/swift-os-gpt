/// A nonempty physical byte interval. Unlike `PhysicalPageRange`, this type is
/// suitable for linker symbols and device-tree reservations that are not page
/// aligned. The memory bootstrap rounds reservations outward before excluding
/// them from the allocator.
struct PhysicalByteSpan: Equatable {
    let baseAddress: UInt64
    let length: UInt64

    init?(baseAddress: UInt64, length: UInt64) {
        guard length > 0,
              length <= UInt64.max - baseAddress
        else {
            return nil
        }
        self.baseAddress = baseAddress
        self.length = length
    }

    init?(startAddress: UInt64, endAddress: UInt64) {
        guard endAddress > startAddress else {
            return nil
        }
        self.init(
            baseAddress: startAddress,
            length: endAddress - startAddress
        )
    }

    var endAddress: UInt64 {
        baseAddress + length
    }
}

/// Clears the two linker-owned stack backings before they are exposed through
/// EL0 aliases. Validation covers the complete pair before either span is
/// touched, preventing a malformed layout from producing a partially scrubbed
/// userspace setup.
enum EL0StackMemoryScrubber {
    @_optimize(none)
    static func scrub(
        first: PhysicalByteSpan,
        second: PhysicalByteSpan
    ) -> Bool {
        guard valid(first),
              valid(second),
              first.endAddress <= second.baseAddress
                || second.endAddress <= first.baseAddress
        else {
            return false
        }

        zero(first)
        zero(second)
        return true
    }

    private static func valid(_ span: PhysicalByteSpan) -> Bool {
        MemoryPageGeometry.isPageAligned(span.baseAddress)
            && MemoryPageGeometry.isPageAligned(span.endAddress)
            && span.baseAddress <= UInt64(UInt.max)
            && span.length <= UInt64(Int.max)
            && UnsafeMutableRawPointer(
                bitPattern: UInt(span.baseAddress)
            ) != nil
    }

    private static func zero(_ span: PhysicalByteSpan) {
        let destination = UnsafeMutableRawPointer(
            bitPattern: UInt(span.baseAddress)
        )!
        var offset: UInt64 = 0
        while offset < span.length {
            destination.storeBytes(
                of: UInt64(0),
                toByteOffset: Int(offset),
                as: UInt64.self
            )
            offset += UInt64(MemoryLayout<UInt64>.stride)
        }
    }
}

/// Caller-owned reservations that cannot be inferred from firmware. The table
/// pool is separate so it is impossible to forget to reserve page-table pages.
/// `explicitReservations` normally contains the complete kernel image, user
/// image/stacks, per-CPU stacks, scheduler state, DMA buffers, and framebuffer.
struct RuntimeMemoryBootstrapLayout {
    let explicitReservations: UnsafeBufferPointer<PhysicalByteSpan>
    let translationTablePool: PhysicalPageRange
}

struct RuntimePhysicalMemorySummary: Equatable {
    let memoryTupleCount: Int
    let firmwareReservationCount: Int
    let reservedMemoryTupleCount: Int
    let explicitReservationCount: Int
    let discoveredPageCount: UInt64
    let usablePageCount: UInt64

    var reservedPageCount: UInt64 {
        discoveredPageCount - usablePageCount
    }
}

enum RuntimeMemoryBootstrapError: Equatable {
    case memoryMapMustBeEmpty
    case noMemory
    case malformedResource
    case deviceTreeOutsideRAM
    case explicitReservationOutsideRAM
    case translationTablePoolOutsideRAM
    case memoryMapMetadataExhausted
    case allocatorMetadataExhausted
    case discoveryLimitExceeded
}

enum RuntimeMemoryBootstrapResult: Equatable {
    case ready(RuntimePhysicalMemorySummary)
    case failed(RuntimeMemoryBootstrapError)
}

/// Converts firmware-owned discovery data into allocator-owned free runs. The
/// amount of metadata is proportional to ranges and fragmentation, never to
/// installed page count: a contiguous 8 GiB bank occupies one map record.
enum RuntimePhysicalMemoryBootstrap {
    private static let maximumResourceCount = 4096

    static func initialize(
        platform: Platform,
        layout: RuntimeMemoryBootstrapLayout,
        memoryMap: inout PhysicalMemoryMap,
        allocator: inout PhysicalPageAllocator
    ) -> RuntimeMemoryBootstrapResult {
        guard memoryMap.count == 0 else {
            return .failed(.memoryMapMustBeEmpty)
        }

        guard let deviceTree = PhysicalByteSpan(
            baseAddress: platform.deviceTreeAddress,
            length: platform.deviceTreeSize
        ) else {
            return .failed(.deviceTreeOutsideRAM)
        }

        var memoryTupleCount = 0
        var deviceTreeIsInsideRAM = false
        while memoryTupleCount < maximumResourceCount,
              let resource = platform.memoryRegion(at: memoryTupleCount) {
            guard validResource(resource) else {
                return .failed(.malformedResource)
            }
            if contains(deviceTree, in: resource) {
                deviceTreeIsInsideRAM = true
            }
            guard
                  memoryMap.addDeviceTreeMemory(
                      baseAddress: resource.baseAddress,
                      length: resource.length
                  )
            else {
                return .failed(.memoryMapMetadataExhausted)
            }
            memoryTupleCount += 1
        }
        if memoryTupleCount == maximumResourceCount,
           platform.memoryRegion(at: memoryTupleCount) != nil {
            return .failed(.discoveryLimitExceeded)
        }
        guard memoryTupleCount > 0 else {
            return .failed(.noMemory)
        }
        guard deviceTreeIsInsideRAM else {
            return .failed(.deviceTreeOutsideRAM)
        }
        var explicitIndex = 0
        while explicitIndex < layout.explicitReservations.count {
            guard isInsideDiscoveredRAM(
                layout.explicitReservations[explicitIndex],
                platform: platform
            ) else {
                return .failed(.explicitReservationOutsideRAM)
            }
            explicitIndex += 1
        }
        guard memoryMap.totalPageCount > 0 else {
            return .failed(.noMemory)
        }

        let discoveredPageCount = memoryMap.totalPageCount
        guard memoryMap.contains(layout.translationTablePool) else {
            return .failed(.translationTablePoolOutsideRAM)
        }

        guard reserve(deviceTree, from: &memoryMap) else {
            return .failed(.memoryMapMetadataExhausted)
        }

        var firmwareReservationCount = 0
        while firmwareReservationCount < maximumResourceCount,
              let resource = platform.firmwareReservation(
                  at: firmwareReservationCount
              ) {
            guard let span = span(for: resource) else {
                return .failed(.malformedResource)
            }
            guard reserve(span, from: &memoryMap) else {
                return .failed(.memoryMapMetadataExhausted)
            }
            firmwareReservationCount += 1
        }
        if firmwareReservationCount == maximumResourceCount,
           platform.firmwareReservation(at: firmwareReservationCount) != nil {
            return .failed(.discoveryLimitExceeded)
        }

        var reservedMemoryTupleCount = 0
        while reservedMemoryTupleCount < maximumResourceCount,
              let resource = platform.reservedMemoryRegion(
                  at: reservedMemoryTupleCount
              ) {
            guard let span = span(for: resource) else {
                return .failed(.malformedResource)
            }
            guard reserve(span, from: &memoryMap) else {
                return .failed(.memoryMapMetadataExhausted)
            }
            reservedMemoryTupleCount += 1
        }
        if reservedMemoryTupleCount == maximumResourceCount,
           platform.reservedMemoryRegion(at: reservedMemoryTupleCount) != nil {
            return .failed(.discoveryLimitExceeded)
        }

        guard reserve(layout.translationTablePool, from: &memoryMap) else {
            return .failed(.memoryMapMetadataExhausted)
        }

        explicitIndex = 0
        while explicitIndex < layout.explicitReservations.count {
            guard reserve(
                layout.explicitReservations[explicitIndex],
                from: &memoryMap
            ) else {
                return .failed(.memoryMapMetadataExhausted)
            }
            explicitIndex += 1
        }

        guard memoryMap.totalPageCount > 0 else {
            return .failed(.noMemory)
        }
        guard allocator.load(from: memoryMap) else {
            return .failed(.allocatorMetadataExhausted)
        }

        return .ready(
            RuntimePhysicalMemorySummary(
                memoryTupleCount: memoryTupleCount,
                firmwareReservationCount: firmwareReservationCount,
                reservedMemoryTupleCount: reservedMemoryTupleCount,
                explicitReservationCount: layout.explicitReservations.count,
                discoveredPageCount: discoveredPageCount,
                usablePageCount: memoryMap.totalPageCount
            )
        )
    }

    private static func validResource(_ resource: DeviceResource) -> Bool {
        resource.length > 0
            && resource.length <= UInt64.max - resource.baseAddress
    }

    private static func span(for resource: DeviceResource) -> PhysicalByteSpan? {
        PhysicalByteSpan(
            baseAddress: resource.baseAddress,
            length: resource.length
        )
    }

    private static func contains(
        _ span: PhysicalByteSpan,
        in resource: DeviceResource
    ) -> Bool {
        span.baseAddress >= resource.baseAddress
            && span.endAddress <= resource.baseAddress + resource.length
    }

    private static func isInsideDiscoveredRAM(
        _ span: PhysicalByteSpan,
        platform: Platform
    ) -> Bool {
        var index = 0
        while index < maximumResourceCount,
              let resource = platform.memoryRegion(at: index) {
            if validResource(resource), contains(span, in: resource) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func reserve(
        _ span: PhysicalByteSpan,
        from memoryMap: inout PhysicalMemoryMap
    ) -> Bool {
        // `PhysicalMemoryMap.reserve` rounds the end upward. Reject a span at
        // the top of the address space when that rounding would overflow.
        guard MemoryPageGeometry.alignUp(span.endAddress) != nil else {
            return false
        }
        return memoryMap.reserve(
            baseAddress: span.baseAddress,
            length: span.length
        )
    }

    private static func reserve(
        _ range: PhysicalPageRange,
        from memoryMap: inout PhysicalMemoryMap
    ) -> Bool {
        memoryMap.reserve(
            baseAddress: range.baseAddress,
            length: range.byteCount
        )
    }
}

extension PhysicalMemoryMap {
    /// Tests whether a page range lies wholly inside one normalized RAM bank.
    /// The table pool must satisfy this before it is removed from free memory.
    func contains(_ range: PhysicalPageRange) -> Bool {
        var index = 0
        while index < count {
            if let candidate = self.range(at: index),
               candidate.contains(range) {
                return true
            }
            index += 1
        }
        return false
    }
}
