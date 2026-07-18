/// The affinity portion of MPIDR_EL1. Non-affinity flags such as MT and U are
/// deliberately excluded so a device-tree CPU identifier can be compared with
/// the processor executing the kernel.
struct ProcessorAffinity: Equatable {
    static let mpidrAffinityMask: UInt64 = 0x0000_00ff_00ff_ffff

    let rawValue: UInt64

    /// Device-tree CPU `reg` values must contain only Aff3:Aff2:Aff1:Aff0.
    init?(deviceTreeValue: UInt64) {
        guard deviceTreeValue & ~Self.mpidrAffinityMask == 0 else {
            return nil
        }
        rawValue = deviceTreeValue
    }

    private init(validatedRawValue: UInt64) {
        rawValue = validatedRawValue
    }

    static func fromMPIDR(_ mpidr: UInt64) -> ProcessorAffinity {
        ProcessorAffinity(
            validatedRawValue: mpidr & Self.mpidrAffinityMask
        )
    }

    var affinityLevel0: UInt8 {
        UInt8(truncatingIfNeeded: rawValue)
    }

    var affinityLevel1: UInt8 {
        UInt8(truncatingIfNeeded: rawValue >> 8)
    }

    var affinityLevel2: UInt8 {
        UInt8(truncatingIfNeeded: rawValue >> 16)
    }

    var affinityLevel3: UInt8 {
        UInt8(truncatingIfNeeded: rawValue >> 32)
    }

    fileprivate static let zero = ProcessorAffinity(validatedRawValue: 0)
}

enum ProcessorRegistrationResult: Equatable {
    case inserted(index: Int)
    case duplicate(existingIndex: Int)
    case invalidAffinity
    case capacityExhausted
}

struct BootProcessorIdentity: Equatable {
    let topologyIndex: Int
    let affinity: ProcessorAffinity
}

/// Fixed-capacity CPU topology populated from `/cpus` device-tree nodes. The
/// caller supplies storage, making the type usable before an allocator exists.
struct ProcessorTopology {
    static let maximumProcessorCount = 64

    private var storage: UnsafeMutableBufferPointer<ProcessorAffinity>
    private(set) var count: Int = 0

    init?(storage: UnsafeMutableBufferPointer<ProcessorAffinity>) {
        guard !storage.isEmpty,
              storage.count <= Self.maximumProcessorCount
        else {
            return nil
        }
        self.storage = storage
        var index = 0
        while index < storage.count {
            storage[index] = .zero
            index += 1
        }
    }

    var capacity: Int {
        storage.count
    }

    mutating func register(
        deviceTreeAffinity: UInt64
    ) -> ProcessorRegistrationResult {
        guard let affinity = ProcessorAffinity(
            deviceTreeValue: deviceTreeAffinity
        ) else {
            return .invalidAffinity
        }
        if let existingIndex = index(of: affinity) {
            return .duplicate(existingIndex: existingIndex)
        }
        guard count < storage.count else {
            return .capacityExhausted
        }
        storage[count] = affinity
        count += 1
        return .inserted(index: count - 1)
    }

    func affinity(at index: Int) -> ProcessorAffinity? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    func index(of affinity: ProcessorAffinity) -> Int? {
        var index = 0
        while index < count {
            if storage[index] == affinity { return index }
            index += 1
        }
        return nil
    }

    /// Matches every affinity level, including Aff3 at MPIDR bits 39:32.
    func identifyBootProcessor(mpidr: UInt64) -> BootProcessorIdentity? {
        let affinity = ProcessorAffinity.fromMPIDR(mpidr)
        guard let topologyIndex = index(of: affinity) else { return nil }
        return BootProcessorIdentity(
            topologyIndex: topologyIndex,
            affinity: affinity
        )
    }
}

struct SecondaryProcessorTarget: Equatable {
    /// Dense kernel CPU identifier. The boot processor is always logical 0.
    let logicalProcessorID: UInt8
    let topologyIndex: Int
    let affinity: ProcessorAffinity
    /// Passed as PSCI CPU_ON's context_id and received by the entry veneer in x0.
    let contextID: UInt64

    static let vacant = SecondaryProcessorTarget(
        logicalProcessorID: 0,
        topologyIndex: -1,
        affinity: .zero,
        contextID: 0
    )
}

/// Selects at most four processors, including the boot processor. Secondary
/// context IDs are dense logical CPU IDs 1...3, independent of DT node order.
struct ProcessorStartupPlan {
    static let maximumOnlineProcessorCount = 4

    private var targetStorage:
        UnsafeMutableBufferPointer<SecondaryProcessorTarget>
    let bootProcessor: BootProcessorIdentity
    private(set) var secondaryProcessorCount: Int = 0

    init?(
        topology: ProcessorTopology,
        bootMPIDR: UInt64,
        maximumProcessorCount: Int = maximumOnlineProcessorCount,
        targetStorage: UnsafeMutableBufferPointer<SecondaryProcessorTarget>
    ) {
        guard maximumProcessorCount > 0,
              maximumProcessorCount <= Self.maximumOnlineProcessorCount,
              targetStorage.count >= maximumProcessorCount - 1,
              let bootProcessor = topology.identifyBootProcessor(
                  mpidr: bootMPIDR
              )
        else {
            return nil
        }
        self.targetStorage = targetStorage
        self.bootProcessor = bootProcessor

        var clearIndex = 0
        while clearIndex < targetStorage.count {
            targetStorage[clearIndex] = .vacant
            clearIndex += 1
        }

        var topologyIndex = 0
        while topologyIndex < topology.count,
              secondaryProcessorCount < maximumProcessorCount - 1 {
            defer { topologyIndex += 1 }
            if topologyIndex == bootProcessor.topologyIndex { continue }
            guard let affinity = topology.affinity(at: topologyIndex) else {
                return nil
            }
            let logicalProcessorID = UInt8(secondaryProcessorCount + 1)
            targetStorage[secondaryProcessorCount] = SecondaryProcessorTarget(
                logicalProcessorID: logicalProcessorID,
                topologyIndex: topologyIndex,
                affinity: affinity,
                contextID: UInt64(logicalProcessorID)
            )
            secondaryProcessorCount += 1
        }
    }

    var processorCount: Int {
        secondaryProcessorCount + 1
    }

    func secondaryProcessor(at index: Int) -> SecondaryProcessorTarget? {
        guard index >= 0, index < secondaryProcessorCount else { return nil }
        return targetStorage[index]
    }
}
