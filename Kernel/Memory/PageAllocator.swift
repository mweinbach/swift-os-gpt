enum PageAllocationResult: Equatable {
    case allocated(PhysicalPageRange)
    case invalidRequest
    case outOfMemory
    case metadataExhausted
}

/// Deterministic first-fit allocator backed by sorted free runs. Metadata grows
/// with fragmentation, not installed RAM: an 8 GiB range occupies one record.
struct PhysicalPageAllocator {
    private var storage: UnsafeMutableBufferPointer<PhysicalPageRange>
    private(set) var freeRunCount: Int = 0

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

    var totalFreePageCount: UInt64 {
        var total: UInt64 = 0
        var index = 0
        while index < freeRunCount {
            total += storage[index].pageCount
            index += 1
        }
        return total
    }

    func freeRun(at index: Int) -> PhysicalPageRange? {
        guard index >= 0, index < freeRunCount else {
            return nil
        }
        return storage[index]
    }

    /// Atomically replaces allocator state with a normalized memory map.
    @discardableResult
    mutating func load(from memoryMap: PhysicalMemoryMap) -> Bool {
        guard memoryMap.count <= storage.count else {
            return false
        }
        var index = 0
        while index < memoryMap.count {
            guard let range = memoryMap.range(at: index) else {
                return false
            }
            storage[index] = range
            index += 1
        }
        while index < freeRunCount {
            storage[index] = .empty
            index += 1
        }
        freeRunCount = memoryMap.count
        return true
    }

    /// Allocates the lowest representable run satisfying the page alignment.
    /// Alignment is expressed in pages and need not be a power of two.
    mutating func allocate(
        pageCount requestedPageCount: UInt64,
        alignmentInPages: UInt64 = 1
    ) -> PageAllocationResult {
        guard requestedPageCount > 0, alignmentInPages > 0 else {
            return .invalidRequest
        }

        var metadataPreventedAllocation = false
        var index = 0
        while index < freeRunCount {
            let run = storage[index]
            let startPage = run.baseAddress / MemoryPageGeometry.pageSize
            let remainder = startPage % alignmentInPages
            let pageAdjustment = remainder == 0 ? 0 : alignmentInPages - remainder
            guard pageAdjustment <= UInt64.max - startPage else {
                index += 1
                continue
            }
            let allocationStartPage = startPage + pageAdjustment
            guard allocationStartPage <= UInt64.max / MemoryPageGeometry.pageSize else {
                index += 1
                continue
            }
            let prefixPageCount = allocationStartPage - startPage
            guard prefixPageCount <= run.pageCount,
                  requestedPageCount <= run.pageCount - prefixPageCount
            else {
                index += 1
                continue
            }
            let suffixPageCount = run.pageCount
                - prefixPageCount
                - requestedPageCount
            if prefixPageCount > 0,
               suffixPageCount > 0,
               freeRunCount == storage.count {
                metadataPreventedAllocation = true
                index += 1
                continue
            }

            let allocationBase = allocationStartPage * MemoryPageGeometry.pageSize
            guard let allocation = PhysicalPageRange(
                baseAddress: allocationBase,
                pageCount: requestedPageCount
            ) else {
                return .invalidRequest
            }

            if prefixPageCount == 0 && suffixPageCount == 0 {
                removeRun(at: index)
            } else if prefixPageCount == 0 {
                guard let suffix = PhysicalPageRange(
                    baseAddress: allocation.endAddress,
                    pageCount: suffixPageCount
                ) else {
                    return .invalidRequest
                }
                storage[index] = suffix
            } else if suffixPageCount == 0 {
                guard let prefix = PhysicalPageRange(
                    baseAddress: run.baseAddress,
                    pageCount: prefixPageCount
                ) else {
                    return .invalidRequest
                }
                storage[index] = prefix
            } else {
                guard let prefix = PhysicalPageRange(
                    baseAddress: run.baseAddress,
                    pageCount: prefixPageCount
                ),
                let suffix = PhysicalPageRange(
                    baseAddress: allocation.endAddress,
                    pageCount: suffixPageCount
                ) else {
                    return .invalidRequest
                }
                var move = freeRunCount
                while move > index + 1 {
                    storage[move] = storage[move - 1]
                    move -= 1
                }
                storage[index] = prefix
                storage[index + 1] = suffix
                freeRunCount += 1
            }
            return .allocated(allocation)
        }
        return metadataPreventedAllocation ? .metadataExhausted : .outOfMemory
    }

    /// Returns a previously allocated run. Overlap is rejected, while adjacent
    /// runs coalesce immediately to keep long-running metadata deterministic.
    @discardableResult
    mutating func release(_ range: PhysicalPageRange) -> Bool {
        guard range.pageCount > 0 else {
            return false
        }
        var insertion = 0
        while insertion < freeRunCount,
              storage[insertion].baseAddress < range.baseAddress {
            insertion += 1
        }

        let previousIndex = insertion - 1
        if previousIndex >= 0,
           storage[previousIndex].endAddress > range.baseAddress {
            return false
        }
        if insertion < freeRunCount,
           storage[insertion].baseAddress < range.endAddress {
            return false
        }

        let joinsPrevious = previousIndex >= 0
            && storage[previousIndex].endAddress == range.baseAddress
        let joinsNext = insertion < freeRunCount
            && range.endAddress == storage[insertion].baseAddress

        if joinsPrevious && joinsNext {
            let previous = storage[previousIndex]
            let next = storage[insertion]
            guard let merged = PhysicalPageRange(
                baseAddress: previous.baseAddress,
                pageCount: previous.pageCount + range.pageCount + next.pageCount
            ) else {
                return false
            }
            storage[previousIndex] = merged
            removeRun(at: insertion)
            return true
        }
        if joinsPrevious {
            let previous = storage[previousIndex]
            guard let merged = PhysicalPageRange(
                baseAddress: previous.baseAddress,
                pageCount: previous.pageCount + range.pageCount
            ) else {
                return false
            }
            storage[previousIndex] = merged
            return true
        }
        if joinsNext {
            let next = storage[insertion]
            guard let merged = PhysicalPageRange(
                baseAddress: range.baseAddress,
                pageCount: range.pageCount + next.pageCount
            ) else {
                return false
            }
            storage[insertion] = merged
            return true
        }

        guard freeRunCount < storage.count else {
            return false
        }
        var move = freeRunCount
        while move > insertion {
            storage[move] = storage[move - 1]
            move -= 1
        }
        storage[insertion] = range
        freeRunCount += 1
        return true
    }

    private mutating func removeRun(at index: Int) {
        var move = index
        while move + 1 < freeRunCount {
            storage[move] = storage[move + 1]
            move += 1
        }
        freeRunCount -= 1
        storage[freeRunCount] = .empty
    }
}
