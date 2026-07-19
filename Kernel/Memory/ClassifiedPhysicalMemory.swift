/// Stable identity for a pool of physical memory. A domain describes where an
/// allocation comes from; it deliberately does not describe the AArch64 page
/// table attributes used to map that allocation.
struct PhysicalMemoryAllocationDomain: Equatable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A firmware- or platform-defined locality identifier. Equal proximity
/// domains are expected to have similar access cost, but the allocator does
/// not assign architecture-specific meaning to the value.
struct PhysicalMemoryProximityDomain: Equatable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// Access properties of a physical memory domain. Absence of the CPU bits is
/// meaningful: a device-local heap can be represented without pretending that
/// the CPU can dereference it.
struct PhysicalMemoryCapabilities: Equatable {
    let rawValue: UInt64

    static let none = PhysicalMemoryCapabilities(rawValue: 0)
    static let cpuReadable = PhysicalMemoryCapabilities(rawValue: 1 << 0)
    static let cpuWritable = PhysicalMemoryCapabilities(rawValue: 1 << 1)
    static let deviceReadable = PhysicalMemoryCapabilities(rawValue: 1 << 2)
    static let deviceWritable = PhysicalMemoryCapabilities(rawValue: 1 << 3)
    static let cacheCoherent = PhysicalMemoryCapabilities(rawValue: 1 << 4)
    static let persistent = PhysicalMemoryCapabilities(rawValue: 1 << 5)

    static let cpuAccessible = cpuReadable.union(.cpuWritable)
    static let deviceAccessible = deviceReadable.union(.deviceWritable)

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    func contains(_ required: PhysicalMemoryCapabilities) -> Bool {
        rawValue & required.rawValue == required.rawValue
    }

    func union(
        _ other: PhysicalMemoryCapabilities
    ) -> PhysicalMemoryCapabilities {
        PhysicalMemoryCapabilities(rawValue: rawValue | other.rawValue)
    }
}

/// Complete allocation classification for one physical range. Mapping policy
/// remains a separate decision made by the address-space layer.
struct PhysicalMemoryClassification: Equatable {
    let allocationDomain: PhysicalMemoryAllocationDomain
    let capabilities: PhysicalMemoryCapabilities
    let proximityDomain: PhysicalMemoryProximityDomain

    init(
        allocationDomain: PhysicalMemoryAllocationDomain,
        capabilities: PhysicalMemoryCapabilities,
        proximityDomain: PhysicalMemoryProximityDomain
    ) {
        self.allocationDomain = allocationDomain
        self.capabilities = capabilities
        self.proximityDomain = proximityDomain
    }

    fileprivate static let empty = PhysicalMemoryClassification(
        allocationDomain: PhysicalMemoryAllocationDomain(0),
        capabilities: .none,
        proximityDomain: PhysicalMemoryProximityDomain(0)
    )
}

struct ClassifiedPhysicalPageRange: Equatable {
    let range: PhysicalPageRange
    let classification: PhysicalMemoryClassification

    static let empty = ClassifiedPhysicalPageRange(
        range: .empty,
        classification: .empty
    )

    init(
        range: PhysicalPageRange,
        classification: PhysicalMemoryClassification
    ) {
        self.range = range
        self.classification = classification
    }
}

enum PhysicalMemoryDomainFallback: Equatable {
    case disallowed
    case allowed
}

/// Selection is explicit about fallback. A caller that asks for local or
/// device-owned memory cannot silently receive a different class of memory.
enum PhysicalMemoryDomainSelection: Equatable {
    case any
    case preferred(
        PhysicalMemoryAllocationDomain,
        fallback: PhysicalMemoryDomainFallback
    )
}

struct ClassifiedPageAllocationConstraints: Equatable {
    let pageCount: UInt64
    let alignmentInPages: UInt64
    /// Lowest byte address at which the allocation may begin, inclusive.
    let minimumAddress: UInt64
    /// Highest byte address the allocation may occupy, inclusive.
    let maximumAddress: UInt64
    let requiredCapabilities: PhysicalMemoryCapabilities
    let domainSelection: PhysicalMemoryDomainSelection

    init(
        pageCount: UInt64,
        alignmentInPages: UInt64 = 1,
        minimumAddress: UInt64 = 0,
        maximumAddress: UInt64 = .max,
        requiredCapabilities: PhysicalMemoryCapabilities = .none,
        domainSelection: PhysicalMemoryDomainSelection = .any
    ) {
        self.pageCount = pageCount
        self.alignmentInPages = alignmentInPages
        self.minimumAddress = minimumAddress
        self.maximumAddress = maximumAddress
        self.requiredCapabilities = requiredCapabilities
        self.domainSelection = domainSelection
    }
}

/// A release capability minted by the allocator. The identifier is checked
/// against a fixed-capacity active-allocation ledger; the range and complete
/// classification must also match that ledger entry.
struct ClassifiedPageAllocationToken: Equatable {
    let identifier: UInt64
    let range: PhysicalPageRange
    let classification: PhysicalMemoryClassification

    var owningDomain: PhysicalMemoryAllocationDomain {
        classification.allocationDomain
    }

    init(
        identifier: UInt64,
        range: PhysicalPageRange,
        classification: PhysicalMemoryClassification
    ) {
        self.identifier = identifier
        self.range = range
        self.classification = classification
    }

    static let empty = ClassifiedPageAllocationToken(
        identifier: 0,
        range: .empty,
        classification: .empty
    )
}

enum ClassifiedMemoryInsertResult: Equatable {
    case inserted
    case conflictingClassification
    case overlapsActiveAllocation
    case metadataExhausted
}

enum ClassifiedMemoryReservationResult: Equatable {
    case reserved
    case invalidRequest
    case overlapsActiveAllocation
    case metadataExhausted
}

enum ClassifiedPageAllocationResult: Equatable {
    case allocated(ClassifiedPageAllocationToken)
    case invalidRequest
    case outOfMemory
    case metadataExhausted
}

enum ClassifiedPageReleaseResult: Equatable {
    case released
    case unknownAllocation
    case tokenMismatch
    case freeRangeOverlap
    case metadataExhausted
}

/// Fixed-capacity physical allocator for heterogeneous memory. Both free-run
/// metadata and active-allocation ownership are supplied by the caller, so the
/// allocator itself never requires a heap and its failure modes are explicit.
struct ClassifiedPhysicalMemoryAllocator {
    private var freeStorage:
        UnsafeMutableBufferPointer<ClassifiedPhysicalPageRange>
    private var allocationStorage:
        UnsafeMutableBufferPointer<ClassifiedPageAllocationToken>
    private(set) var freeRunCount: Int = 0
    private(set) var activeAllocationCount: Int = 0
    private var nextAllocationIdentifier: UInt64 = 1

    init(
        freeStorage: UnsafeMutableBufferPointer<ClassifiedPhysicalPageRange>,
        allocationStorage:
            UnsafeMutableBufferPointer<ClassifiedPageAllocationToken>
    ) {
        self.freeStorage = freeStorage
        self.allocationStorage = allocationStorage

        var index = 0
        while index < freeStorage.count {
            freeStorage[index] = .empty
            index += 1
        }
        index = 0
        while index < allocationStorage.count {
            allocationStorage[index] = .empty
            index += 1
        }
    }

    var freeRunCapacity: Int {
        freeStorage.count
    }

    var activeAllocationCapacity: Int {
        allocationStorage.count
    }

    var totalFreePageCount: UInt64 {
        var total: UInt64 = 0
        var index = 0
        while index < freeRunCount {
            total += freeStorage[index].range.pageCount
            index += 1
        }
        return total
    }

    func freeRun(at index: Int) -> ClassifiedPhysicalPageRange? {
        guard index >= 0, index < freeRunCount else {
            return nil
        }
        return freeStorage[index]
    }

    func activeAllocation(
        at index: Int
    ) -> ClassifiedPageAllocationToken? {
        guard index >= 0, index < activeAllocationCount else {
            return nil
        }
        return allocationStorage[index]
    }

    func activeAllocation(
        matching range: PhysicalPageRange,
        classification: PhysicalMemoryClassification
    ) -> ClassifiedPageAllocationToken? {
        var index = 0
        while index < activeAllocationCount {
            let token = allocationStorage[index]
            if token.range == range,
               token.classification == classification {
                return token
            }
            index += 1
        }
        return nil
    }

    /// Atomically replaces free-run state with an already normalized physical
    /// memory map. Active ownership prevents replacement; callers must never
    /// be able to make allocated pages free by reloading discovery metadata.
    @discardableResult
    mutating func load(
        from memoryMap: PhysicalMemoryMap,
        classification: PhysicalMemoryClassification
    ) -> Bool {
        guard activeAllocationCount == 0,
              memoryMap.count <= freeStorage.count
        else {
            return false
        }

        // Validate the complete source before touching the destination.
        var index = 0
        while index < memoryMap.count {
            guard memoryMap.range(at: index) != nil else {
                return false
            }
            index += 1
        }

        index = 0
        while index < memoryMap.count {
            freeStorage[index] = ClassifiedPhysicalPageRange(
                range: memoryMap.range(at: index)!,
                classification: classification
            )
            index += 1
        }
        while index < freeRunCount {
            freeStorage[index] = .empty
            index += 1
        }
        freeRunCount = memoryMap.count
        return true
    }

    /// Adds discovered memory. Same-class overlaps and adjacency normalize;
    /// differently classified overlaps are rejected before any state changes.
    @discardableResult
    mutating func addFreeRange(
        _ range: PhysicalPageRange,
        classification: PhysicalMemoryClassification
    ) -> ClassifiedMemoryInsertResult {
        let classified = ClassifiedPhysicalPageRange(
            range: range,
            classification: classification
        )
        return insertFreeRange(classified, overlappingSameClassIsValid: true)
    }

    /// Removes every page touched by a byte reservation. A split retains the
    /// original classification on both sides. Reservations cannot revoke an
    /// active allocation.
    @discardableResult
    mutating func reserve(
        baseAddress: UInt64,
        length: UInt64
    ) -> ClassifiedMemoryReservationResult {
        guard length > 0,
              let rawEnd = MemoryPageGeometry.adding(baseAddress, length),
              let reservationEnd = MemoryPageGeometry.alignUp(rawEnd),
              let reservation = PhysicalPageRange(
                  baseAddress: MemoryPageGeometry.alignDown(baseAddress),
                  pageCount: (
                      reservationEnd
                          - MemoryPageGeometry.alignDown(baseAddress)
                  ) / MemoryPageGeometry.pageSize
              )
        else {
            return .invalidRequest
        }

        var allocationIndex = 0
        while allocationIndex < activeAllocationCount {
            if overlaps(allocationStorage[allocationIndex].range, reservation) {
                return .overlapsActiveAllocation
            }
            allocationIndex += 1
        }

        var first = 0
        while first < freeRunCount,
              freeStorage[first].range.endAddress <= reservation.baseAddress {
            first += 1
        }
        guard first < freeRunCount,
              freeStorage[first].range.baseAddress < reservation.endAddress
        else {
            return .reserved
        }

        var end = first
        while end < freeRunCount,
              freeStorage[end].range.baseAddress < reservation.endAddress {
            end += 1
        }

        let firstRun = freeStorage[first]
        let lastRun = freeStorage[end - 1]
        var left: ClassifiedPhysicalPageRange?
        var right: ClassifiedPhysicalPageRange?
        if firstRun.range.baseAddress < reservation.baseAddress,
           let leftRange = PhysicalPageRange(
               baseAddress: firstRun.range.baseAddress,
               pageCount: (
                   reservation.baseAddress - firstRun.range.baseAddress
               ) / MemoryPageGeometry.pageSize
           ) {
            left = ClassifiedPhysicalPageRange(
                range: leftRange,
                classification: firstRun.classification
            )
        }
        if lastRun.range.endAddress > reservation.endAddress,
           let rightRange = PhysicalPageRange(
               baseAddress: reservation.endAddress,
               pageCount: (
                   lastRun.range.endAddress - reservation.endAddress
               ) / MemoryPageGeometry.pageSize
           ) {
            right = ClassifiedPhysicalPageRange(
                range: rightRange,
                classification: lastRun.classification
            )
        }

        let insertedCount = (left == nil ? 0 : 1) + (right == nil ? 0 : 1)
        guard freeRunCount - (end - first) + insertedCount
                <= freeStorage.count
        else {
            return .metadataExhausted
        }
        replaceFreeRuns(
            startingAt: first,
            removedCount: end - first,
            first: left,
            second: right
        )
        return .reserved
    }

    mutating func allocate(
        _ constraints: ClassifiedPageAllocationConstraints
    ) -> ClassifiedPageAllocationResult {
        guard constraints.pageCount > 0,
              constraints.alignmentInPages > 0,
              constraints.minimumAddress <= constraints.maximumAddress,
              MemoryPageGeometry.alignUp(constraints.minimumAddress) != nil,
              MemoryPageGeometry.byteCount(
                  forPageCount: constraints.pageCount
              ) != nil
        else {
            return .invalidRequest
        }
        guard activeAllocationCount < allocationStorage.count,
              let identifier = nextAvailableAllocationIdentifier()
        else {
            return .metadataExhausted
        }

        switch constraints.domainSelection {
        case .any:
            return allocate(
                constraints,
                domain: nil,
                excludingDomain: nil,
                identifier: identifier
            ).result

        case let .preferred(domain, fallback):
            let preferred = allocate(
                constraints,
                domain: domain,
                excludingDomain: nil,
                identifier: identifier
            )
            if preferred.didAllocate {
                return preferred.result
            }
            guard fallback == .allowed else {
                return preferred.result
            }
            let alternate = allocate(
                constraints,
                domain: nil,
                excludingDomain: domain,
                identifier: identifier
            )
            if alternate.didAllocate {
                return alternate.result
            }
            if preferred.metadataPreventedAllocation
                || alternate.metadataPreventedAllocation {
                return .metadataExhausted
            }
            return .outOfMemory
        }
    }

    /// Releases only a currently active, byte-for-byte matching token. Failed
    /// validation and failed free-list insertion both leave ownership intact.
    @discardableResult
    mutating func release(
        _ token: ClassifiedPageAllocationToken
    ) -> ClassifiedPageReleaseResult {
        var allocationIndex = 0
        while allocationIndex < activeAllocationCount,
              allocationStorage[allocationIndex].identifier != token.identifier {
            allocationIndex += 1
        }
        guard allocationIndex < activeAllocationCount else {
            return .unknownAllocation
        }
        guard allocationStorage[allocationIndex] == token else {
            return .tokenMismatch
        }

        let insertion = insertFreeRange(
            ClassifiedPhysicalPageRange(
                range: token.range,
                classification: token.classification
            ),
            overlappingSameClassIsValid: false,
            ignoringAllocationIdentifier: token.identifier
        )
        switch insertion {
        case .inserted:
            removeActiveAllocation(at: allocationIndex)
            return .released
        case .metadataExhausted:
            return .metadataExhausted
        case .conflictingClassification, .overlapsActiveAllocation:
            return .freeRangeOverlap
        }
    }

    private struct AllocationAttempt {
        let result: ClassifiedPageAllocationResult
        let didAllocate: Bool
        let metadataPreventedAllocation: Bool
    }

    private mutating func allocate(
        _ constraints: ClassifiedPageAllocationConstraints,
        domain: PhysicalMemoryAllocationDomain?,
        excludingDomain: PhysicalMemoryAllocationDomain?,
        identifier: UInt64
    ) -> AllocationAttempt {
        let allocationByteCount = MemoryPageGeometry.byteCount(
            forPageCount: constraints.pageCount
        )!
        var metadataPreventedAllocation = false
        var index = 0
        while index < freeRunCount {
            let classifiedRun = freeStorage[index]
            let classification = classifiedRun.classification
            if let domain,
               classification.allocationDomain != domain {
                index += 1
                continue
            }
            if let excludingDomain,
               classification.allocationDomain == excludingDomain {
                index += 1
                continue
            }
            guard classification.capabilities.contains(
                      constraints.requiredCapabilities
                  )
            else {
                index += 1
                continue
            }

            let run = classifiedRun.range
            guard let minimumBase = MemoryPageGeometry.alignUp(
                      constraints.minimumAddress
                  )
            else {
                index += 1
                continue
            }
            let firstAllowedBase = run.baseAddress > minimumBase
                ? run.baseAddress
                : minimumBase
            let startPage = firstAllowedBase / MemoryPageGeometry.pageSize
            let remainder = startPage % constraints.alignmentInPages
            let pageAdjustment = remainder == 0
                ? 0
                : constraints.alignmentInPages - remainder
            guard pageAdjustment <= UInt64.max - startPage else {
                index += 1
                continue
            }
            let allocationStartPage = startPage + pageAdjustment
            guard allocationStartPage
                    <= UInt64.max / MemoryPageGeometry.pageSize
            else {
                index += 1
                continue
            }
            let allocationBase = allocationStartPage
                * MemoryPageGeometry.pageSize
            guard allocationByteCount <= UInt64.max - allocationBase else {
                index += 1
                continue
            }
            let allocationEnd = allocationBase + allocationByteCount
            guard allocationBase >= run.baseAddress,
                  allocationEnd <= run.endAddress,
                  allocationEnd - 1 <= constraints.maximumAddress
            else {
                index += 1
                continue
            }

            let prefixPageCount = (
                allocationBase - run.baseAddress
            ) / MemoryPageGeometry.pageSize
            let suffixPageCount = (
                run.endAddress - allocationEnd
            ) / MemoryPageGeometry.pageSize
            if prefixPageCount > 0,
               suffixPageCount > 0,
               freeRunCount == freeStorage.count {
                metadataPreventedAllocation = true
                index += 1
                continue
            }

            let allocationRange = PhysicalPageRange(
                baseAddress: allocationBase,
                pageCount: constraints.pageCount
            )!
            let token = ClassifiedPageAllocationToken(
                identifier: identifier,
                range: allocationRange,
                classification: classification
            )
            consumeFreeRun(
                at: index,
                allocation: allocationRange,
                prefixPageCount: prefixPageCount,
                suffixPageCount: suffixPageCount
            )
            allocationStorage[activeAllocationCount] = token
            activeAllocationCount += 1
            advanceAllocationIdentifier(after: identifier)
            return AllocationAttempt(
                result: .allocated(token),
                didAllocate: true,
                metadataPreventedAllocation: false
            )
        }
        return AllocationAttempt(
            result: metadataPreventedAllocation
                ? .metadataExhausted
                : .outOfMemory,
            didAllocate: false,
            metadataPreventedAllocation: metadataPreventedAllocation
        )
    }

    private mutating func insertFreeRange(
        _ newRun: ClassifiedPhysicalPageRange,
        overlappingSameClassIsValid: Bool,
        ignoringAllocationIdentifier: UInt64? = nil
    ) -> ClassifiedMemoryInsertResult {
        var allocationIndex = 0
        while allocationIndex < activeAllocationCount {
            let allocation = allocationStorage[allocationIndex]
            if allocation.identifier != ignoringAllocationIdentifier,
               overlaps(
                allocation.range,
                newRun.range
            ) {
                return .overlapsActiveAllocation
            }
            allocationIndex += 1
        }

        var index = 0
        while index < freeRunCount {
            let existing = freeStorage[index]
            if overlaps(existing.range, newRun.range) {
                guard existing.classification == newRun.classification else {
                    return .conflictingClassification
                }
                guard overlappingSameClassIsValid else {
                    return .overlapsActiveAllocation
                }
            }
            index += 1
        }

        var insertion = 0
        while insertion < freeRunCount,
              freeStorage[insertion].range.baseAddress
                < newRun.range.baseAddress {
            insertion += 1
        }

        var mergedBase = newRun.range.baseAddress
        var mergedEnd = newRun.range.endAddress
        var first = insertion
        if insertion > 0 {
            let previous = freeStorage[insertion - 1]
            if previous.classification == newRun.classification,
               previous.range.endAddress >= mergedBase {
                first = insertion - 1
                mergedBase = previous.range.baseAddress
                if previous.range.endAddress > mergedEnd {
                    mergedEnd = previous.range.endAddress
                }
            }
        }

        var end = insertion
        while end < freeRunCount {
            let existing = freeStorage[end]
            guard existing.range.baseAddress <= mergedEnd else {
                break
            }
            guard existing.classification == newRun.classification else {
                // A differently classified range can only be adjacent here;
                // an overlap was rejected in the validation pass above.
                break
            }
            if existing.range.endAddress > mergedEnd {
                mergedEnd = existing.range.endAddress
            }
            end += 1
        }

        let removedCount = end - first
        guard freeRunCount - removedCount + 1 <= freeStorage.count else {
            return .metadataExhausted
        }
        let mergedRange = PhysicalPageRange(
            baseAddress: mergedBase,
            pageCount: (mergedEnd - mergedBase)
                / MemoryPageGeometry.pageSize
        )!
        replaceFreeRuns(
            startingAt: first,
            removedCount: removedCount,
            first: ClassifiedPhysicalPageRange(
                range: mergedRange,
                classification: newRun.classification
            ),
            second: nil
        )
        return .inserted
    }

    private mutating func consumeFreeRun(
        at index: Int,
        allocation: PhysicalPageRange,
        prefixPageCount: UInt64,
        suffixPageCount: UInt64
    ) {
        let original = freeStorage[index]
        if prefixPageCount == 0, suffixPageCount == 0 {
            replaceFreeRuns(
                startingAt: index,
                removedCount: 1,
                first: nil,
                second: nil
            )
            return
        }

        var prefix: ClassifiedPhysicalPageRange?
        var suffix: ClassifiedPhysicalPageRange?
        if prefixPageCount > 0 {
            prefix = ClassifiedPhysicalPageRange(
                range: PhysicalPageRange(
                    baseAddress: original.range.baseAddress,
                    pageCount: prefixPageCount
                )!,
                classification: original.classification
            )
        }
        if suffixPageCount > 0 {
            suffix = ClassifiedPhysicalPageRange(
                range: PhysicalPageRange(
                    baseAddress: allocation.endAddress,
                    pageCount: suffixPageCount
                )!,
                classification: original.classification
            )
        }
        replaceFreeRuns(
            startingAt: index,
            removedCount: 1,
            first: prefix,
            second: suffix
        )
    }

    private mutating func replaceFreeRuns(
        startingAt start: Int,
        removedCount: Int,
        first: ClassifiedPhysicalPageRange?,
        second: ClassifiedPhysicalPageRange?
    ) {
        let insertedCount = (first == nil ? 0 : 1) + (second == nil ? 0 : 1)
        let oldCount = freeRunCount
        let newCount = oldCount - removedCount + insertedCount

        if insertedCount > removedCount {
            let distance = insertedCount - removedCount
            var source = oldCount
            while source > start + removedCount {
                source -= 1
                freeStorage[source + distance] = freeStorage[source]
            }
        } else if insertedCount < removedCount {
            var source = start + removedCount
            var destination = start + insertedCount
            while source < oldCount {
                freeStorage[destination] = freeStorage[source]
                source += 1
                destination += 1
            }
        }

        var destination = start
        if let first {
            freeStorage[destination] = first
            destination += 1
        }
        if let second {
            freeStorage[destination] = second
        }
        if newCount < oldCount {
            var clear = newCount
            while clear < oldCount {
                freeStorage[clear] = .empty
                clear += 1
            }
        }
        freeRunCount = newCount
    }

    private mutating func removeActiveAllocation(at index: Int) {
        var move = index
        while move + 1 < activeAllocationCount {
            allocationStorage[move] = allocationStorage[move + 1]
            move += 1
        }
        activeAllocationCount -= 1
        allocationStorage[activeAllocationCount] = .empty
    }

    private func nextAvailableAllocationIdentifier() -> UInt64? {
        var candidate = nextAllocationIdentifier == 0
            ? 1
            : nextAllocationIdentifier
        var attempts = 0
        while attempts <= activeAllocationCount {
            var inUse = false
            var index = 0
            while index < activeAllocationCount {
                if allocationStorage[index].identifier == candidate {
                    inUse = true
                    break
                }
                index += 1
            }
            if !inUse {
                return candidate
            }
            candidate &+= 1
            if candidate == 0 {
                candidate = 1
            }
            attempts += 1
        }
        return nil
    }

    private mutating func advanceAllocationIdentifier(after used: UInt64) {
        nextAllocationIdentifier = used &+ 1
        if nextAllocationIdentifier == 0 {
            nextAllocationIdentifier = 1
        }
    }

    private func overlaps(
        _ first: PhysicalPageRange,
        _ second: PhysicalPageRange
    ) -> Bool {
        first.baseAddress < second.endAddress
            && second.baseAddress < first.endAddress
    }
}
