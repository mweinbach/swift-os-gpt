enum MemoryPageGeometry {
    static let pageShift: UInt64 = 12
    static let pageSize: UInt64 = 1 << pageShift
    static let pageMask: UInt64 = pageSize - 1

    static func isPageAligned(_ address: UInt64) -> Bool {
        address & pageMask == 0
    }

    static func alignDown(_ address: UInt64) -> UInt64 {
        address & ~pageMask
    }

    static func alignUp(_ address: UInt64) -> UInt64? {
        if isPageAligned(address) {
            return address
        }
        guard address <= UInt64.max - pageMask else {
            return nil
        }
        return (address + pageMask) & ~pageMask
    }

    static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard right <= UInt64.max - left else {
            return nil
        }
        return left + right
    }

    static func byteCount(forPageCount pageCount: UInt64) -> UInt64? {
        guard pageCount <= UInt64.max / pageSize else {
            return nil
        }
        return pageCount * pageSize
    }
}

struct PhysicalPageRange: Equatable {
    let baseAddress: UInt64
    let pageCount: UInt64

    static let empty = PhysicalPageRange(
        uncheckedBaseAddress: 0,
        pageCount: 0
    )

    init?(baseAddress: UInt64, pageCount: UInt64) {
        guard MemoryPageGeometry.isPageAligned(baseAddress),
              pageCount > 0,
              let byteCount = MemoryPageGeometry.byteCount(forPageCount: pageCount),
              byteCount <= UInt64.max - baseAddress
        else {
            return nil
        }
        self.baseAddress = baseAddress
        self.pageCount = pageCount
    }

    private init(uncheckedBaseAddress: UInt64, pageCount: UInt64) {
        baseAddress = uncheckedBaseAddress
        self.pageCount = pageCount
    }

    var byteCount: UInt64 {
        pageCount * MemoryPageGeometry.pageSize
    }

    var endAddress: UInt64 {
        baseAddress + byteCount
    }

    func contains(address: UInt64) -> Bool {
        address >= baseAddress && address < endAddress
    }

    func contains(_ other: PhysicalPageRange) -> Bool {
        other.baseAddress >= baseAddress && other.endAddress <= endAddress
    }
}

/// A normalized set of page-aligned physical RAM ranges. Storage is supplied by
/// the caller so discovering more RAM never creates a heap dependency or a
/// bitmap proportional to installed memory.
struct PhysicalMemoryMap {
    private var storage: UnsafeMutableBufferPointer<PhysicalPageRange>
    private(set) var count: Int = 0

    init(storage: UnsafeMutableBufferPointer<PhysicalPageRange>) {
        self.storage = storage
        var index = 0
        while index < storage.count {
            storage[index] = .empty
            index += 1
        }
    }

    var capacity: Int {
        storage.count
    }

    var totalPageCount: UInt64 {
        var total: UInt64 = 0
        var index = 0
        while index < count {
            total += storage[index].pageCount
            index += 1
        }
        return total
    }

    func range(at index: Int) -> PhysicalPageRange? {
        guard index >= 0, index < count else {
            return nil
        }
        return storage[index]
    }

    /// Adds a `reg` tuple from a device-tree memory node. Partial pages at the
    /// tuple boundaries are excluded; overlapping and adjacent tuples merge.
    @discardableResult
    mutating func addDeviceTreeMemory(
        baseAddress: UInt64,
        length: UInt64
    ) -> Bool {
        guard let rawEnd = MemoryPageGeometry.adding(baseAddress, length) else {
            return false
        }
        guard length > 0 else {
            return true
        }
        guard let alignedBase = MemoryPageGeometry.alignUp(baseAddress) else {
            return false
        }
        let alignedEnd = MemoryPageGeometry.alignDown(rawEnd)
        guard alignedBase < alignedEnd else {
            return true
        }
        guard let range = PhysicalPageRange(
            baseAddress: alignedBase,
            pageCount: (alignedEnd - alignedBase) / MemoryPageGeometry.pageSize
        ) else {
            return false
        }
        return insertAvailableRange(range)
    }

    /// Removes every page touched by a reserved byte range. Reservations are
    /// rounded outward so a kernel image, DT blob, DMA area, or MMIO aperture
    /// can never share a page with the allocator.
    @discardableResult
    mutating func reserve(baseAddress: UInt64, length: UInt64) -> Bool {
        guard let rawEnd = MemoryPageGeometry.adding(baseAddress, length) else {
            return false
        }
        guard length > 0 else {
            return true
        }
        let reservedBase = MemoryPageGeometry.alignDown(baseAddress)
        guard let reservedEnd = MemoryPageGeometry.alignUp(rawEnd) else {
            return false
        }

        var first = 0
        while first < count && storage[first].endAddress <= reservedBase {
            first += 1
        }
        guard first < count, storage[first].baseAddress < reservedEnd else {
            return true
        }

        var end = first
        while end < count && storage[end].baseAddress < reservedEnd {
            end += 1
        }

        let firstRange = storage[first]
        let lastRange = storage[end - 1]
        var left: PhysicalPageRange?
        var right: PhysicalPageRange?
        if firstRange.baseAddress < reservedBase {
            left = PhysicalPageRange(
                baseAddress: firstRange.baseAddress,
                pageCount: (reservedBase - firstRange.baseAddress)
                    / MemoryPageGeometry.pageSize
            )
        }
        if lastRange.endAddress > reservedEnd {
            right = PhysicalPageRange(
                baseAddress: reservedEnd,
                pageCount: (lastRange.endAddress - reservedEnd)
                    / MemoryPageGeometry.pageSize
            )
        }

        let insertedCount = (left == nil ? 0 : 1) + (right == nil ? 0 : 1)
        return replaceRanges(
            startingAt: first,
            removedCount: end - first,
            insertedCount: insertedCount,
            first: left ?? right,
            second: left == nil ? nil : right
        )
    }

    private mutating func insertAvailableRange(_ newRange: PhysicalPageRange) -> Bool {
        var first = 0
        while first < count && storage[first].endAddress < newRange.baseAddress {
            first += 1
        }

        var mergedBase = newRange.baseAddress
        var mergedEnd = newRange.endAddress
        var end = first
        while end < count && storage[end].baseAddress <= mergedEnd {
            let existing = storage[end]
            if existing.baseAddress < mergedBase {
                mergedBase = existing.baseAddress
            }
            if existing.endAddress > mergedEnd {
                mergedEnd = existing.endAddress
            }
            end += 1
        }

        guard let merged = PhysicalPageRange(
            baseAddress: mergedBase,
            pageCount: (mergedEnd - mergedBase) / MemoryPageGeometry.pageSize
        ) else {
            return false
        }
        return replaceRanges(
            startingAt: first,
            removedCount: end - first,
            insertedCount: 1,
            first: merged,
            second: nil
        )
    }

    private mutating func replaceRanges(
        startingAt start: Int,
        removedCount: Int,
        insertedCount: Int,
        first: PhysicalPageRange?,
        second: PhysicalPageRange?
    ) -> Bool {
        let oldCount = count
        let newCount = oldCount - removedCount + insertedCount
        guard newCount <= storage.count else {
            return false
        }

        if insertedCount > removedCount {
            let distance = insertedCount - removedCount
            var source = oldCount
            while source > start + removedCount {
                source -= 1
                storage[source + distance] = storage[source]
            }
        } else if insertedCount < removedCount {
            var source = start + removedCount
            var destination = start + insertedCount
            while source < oldCount {
                storage[destination] = storage[source]
                source += 1
                destination += 1
            }
        }

        if insertedCount > 0, let first {
            storage[start] = first
        }
        if insertedCount > 1, let second {
            storage[start + 1] = second
        }
        if newCount < oldCount {
            var index = newCount
            while index < oldCount {
                storage[index] = .empty
                index += 1
            }
        }
        count = newCount
        return true
    }
}
