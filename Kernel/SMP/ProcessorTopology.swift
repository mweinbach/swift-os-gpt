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

/// A scheduling class is descriptive policy input, not a claim about a
/// particular microarchitecture. Device discovery may leave it unspecified.
enum ProcessorClass: UInt8, Equatable {
    case unspecified = 0
    case generalPurpose = 1
    case performance = 2
    case efficiency = 3
}

/// Capabilities discovered from architectural registers or firmware. Keeping
/// this as an explicit mask lets future schedulers select compatible CPUs
/// without coupling topology to one processor family.
struct ProcessorCapabilities: Equatable {
    let rawValue: UInt16

    static let none = ProcessorCapabilities(rawValue: 0)
    static let floatingPoint = ProcessorCapabilities(rawValue: 1 << 0)
    static let advancedSIMD = ProcessorCapabilities(rawValue: 1 << 1)
    static let genericTimer = ProcessorCapabilities(rawValue: 1 << 2)
    static let virtualization = ProcessorCapabilities(rawValue: 1 << 3)
    static let largePhysicalAddress = ProcessorCapabilities(rawValue: 1 << 4)

    func contains(_ capability: ProcessorCapabilities) -> Bool {
        rawValue & capability.rawValue == capability.rawValue
    }

    func union(_ other: ProcessorCapabilities) -> ProcessorCapabilities {
        ProcessorCapabilities(rawValue: rawValue | other.rawValue)
    }
}

/// A bounded locality identifier. Its interpretation belongs to platform
/// discovery: it may represent a package, NUMA node, or shared-cache domain.
struct ProcessorProximity: Equatable {
    static let unknownDomain: UInt8 = .max
    static let unknown = ProcessorProximity(domain: unknownDomain)

    let domain: UInt8
}

/// Whether firmware permits this processor to be selected for CPU_ON. The boot
/// processor is identified independently because it is already executing.
enum ProcessorStartupEligibility: UInt8, Equatable {
    case eligible = 0
    case bootProcessorOnly = 1
    case disabled = 2
    case unsupported = 3

    var canStartAsSecondary: Bool { self == .eligible }
}

/// Compact CPU description stored before an allocator exists. Metadata lives
/// in MPIDR's architecturally unused affinity bits, so each description remains
/// eight bytes and the existing 64-entry early topology reservation is enough.
struct ProcessorDescription: Equatable {
    private static let classShift: UInt64 = 24
    private static let eligibilityShift: UInt64 = 28
    private static let capabilitiesShift: UInt64 = 40
    private static let proximityShift: UInt64 = 56

    private let storageWord: UInt64

    init(
        affinity: ProcessorAffinity,
        processorClass: ProcessorClass = .unspecified,
        capabilities: ProcessorCapabilities = .none,
        proximity: ProcessorProximity = .unknown,
        startupEligibility: ProcessorStartupEligibility = .eligible
    ) {
        storageWord = affinity.rawValue
            | (UInt64(processorClass.rawValue) << Self.classShift)
            | (UInt64(startupEligibility.rawValue) << Self.eligibilityShift)
            | (UInt64(capabilities.rawValue) << Self.capabilitiesShift)
            | (UInt64(proximity.domain) << Self.proximityShift)
    }

    var affinity: ProcessorAffinity {
        ProcessorAffinity.fromMPIDR(storageWord)
    }

    var processorClass: ProcessorClass {
        ProcessorClass(
            rawValue: UInt8(truncatingIfNeeded: storageWord >> Self.classShift)
                & 0x0f
        ) ?? .unspecified
    }

    var startupEligibility: ProcessorStartupEligibility {
        ProcessorStartupEligibility(
            rawValue: UInt8(
                truncatingIfNeeded: storageWord >> Self.eligibilityShift
            ) & 0x0f
        ) ?? .unsupported
    }

    var capabilities: ProcessorCapabilities {
        ProcessorCapabilities(
            rawValue: UInt16(
                truncatingIfNeeded: storageWord >> Self.capabilitiesShift
            )
        )
    }

    var proximity: ProcessorProximity {
        ProcessorProximity(
            domain: UInt8(
                truncatingIfNeeded: storageWord >> Self.proximityShift
            )
        )
    }

    fileprivate static let vacant = ProcessorDescription(affinity: .zero)
}

enum ProcessorRegistrationResult: Equatable {
    case inserted(index: Int)
    case duplicate(existingIndex: Int)
    case conflictingDescription(existingIndex: Int)
    case invalidAffinity
    case capacityExhausted
}

struct BootProcessorIdentity: Equatable {
    let topologyIndex: Int
    let description: ProcessorDescription

    var affinity: ProcessorAffinity { description.affinity }
}

/// Fixed-capacity CPU topology populated from `/cpus` device-tree nodes. The
/// caller supplies storage, making the type usable before an allocator exists.
struct ProcessorTopology {
    static let maximumProcessorCount = 64

    private var storage: UnsafeMutableBufferPointer<ProcessorDescription>
    private(set) var count: Int = 0

    init?(storage: UnsafeMutableBufferPointer<ProcessorDescription>) {
        guard !storage.isEmpty,
              storage.count <= Self.maximumProcessorCount
        else {
            return nil
        }
        self.storage = storage
        var index = 0
        while index < storage.count {
            storage[index] = .vacant
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
        return register(ProcessorDescription(affinity: affinity))
    }

    mutating func register(
        _ description: ProcessorDescription
    ) -> ProcessorRegistrationResult {
        if let existingIndex = index(of: description.affinity) {
            if storage[existingIndex] == description {
                return .duplicate(existingIndex: existingIndex)
            }
            return .conflictingDescription(existingIndex: existingIndex)
        }
        guard count < storage.count else {
            return .capacityExhausted
        }
        storage[count] = description
        count += 1
        return .inserted(index: count - 1)
    }

    func description(at index: Int) -> ProcessorDescription? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    func affinity(at index: Int) -> ProcessorAffinity? {
        description(at: index)?.affinity
    }

    func index(of affinity: ProcessorAffinity) -> Int? {
        var index = 0
        while index < count {
            if storage[index].affinity == affinity { return index }
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
            description: storage[topologyIndex]
        )
    }
}

/// Counts of the allocation-free buffers linked to a boot configuration.
/// These are capacities rather than discovered CPU counts.
struct ProcessorBootResourceCapacity: Equatable {
    let topologyDescriptions: Int
    let secondaryTargets: Int
    let bootStates: Int
    let startupReports: Int
}

/// A validated upper bound for one boot attempt. This separates the requested
/// CPU policy from both platform topology and the concrete early buffers.
struct ProcessorBootConfiguration: Equatable {
    let requestedProcessorLimit: Int
    let resources: ProcessorBootResourceCapacity

    init?(
        requestedProcessorLimit: Int,
        resources: ProcessorBootResourceCapacity
    ) {
        guard requestedProcessorLimit > 0,
              requestedProcessorLimit
                <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              resources.topologyDescriptions >= requestedProcessorLimit,
              resources.secondaryTargets >= requestedProcessorLimit - 1,
              resources.bootStates >= requestedProcessorLimit,
              resources.startupReports >= requestedProcessorLimit - 1
        else {
            return nil
        }
        self.requestedProcessorLimit = requestedProcessorLimit
        self.resources = resources
    }
}

struct SecondaryProcessorTarget: Equatable {
    /// Dense kernel CPU identifier. The boot processor is always logical 0.
    let logicalProcessorID: UInt8
    let topologyIndex: Int
    let description: ProcessorDescription
    /// Passed as PSCI CPU_ON's context_id and received by the entry veneer in x0.
    let contextID: UInt64

    var affinity: ProcessorAffinity { description.affinity }

    static let vacant = SecondaryProcessorTarget(
        logicalProcessorID: 0,
        topologyIndex: -1,
        description: .vacant,
        contextID: 0
    )
}

/// Selects at most four processors, including the boot processor. Secondary
/// context IDs are dense logical CPU IDs 1...3, independent of DT node order.
struct ProcessorStartupPlan {
    static let maximumOnlineProcessorCount = 4

    private var targetStorage:
        UnsafeMutableBufferPointer<SecondaryProcessorTarget>
    let configuration: ProcessorBootConfiguration
    let bootProcessor: BootProcessorIdentity
    private(set) var secondaryProcessorCount: Int = 0

    init?(
        topology: ProcessorTopology,
        bootMPIDR: UInt64,
        configuration: ProcessorBootConfiguration,
        targetStorage: UnsafeMutableBufferPointer<SecondaryProcessorTarget>
    ) {
        let maximumProcessorCount = configuration.requestedProcessorLimit
        guard targetStorage.count >= configuration.resources.secondaryTargets,
              topology.capacity
                >= configuration.resources.topologyDescriptions,
              let bootProcessor = topology.identifyBootProcessor(
                  mpidr: bootMPIDR
              )
        else {
            return nil
        }
        self.targetStorage = targetStorage
        self.configuration = configuration
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
            guard let description = topology.description(at: topologyIndex) else {
                return nil
            }
            if !description.startupEligibility.canStartAsSecondary { continue }
            let logicalProcessorID = UInt8(secondaryProcessorCount + 1)
            targetStorage[secondaryProcessorCount] = SecondaryProcessorTarget(
                logicalProcessorID: logicalProcessorID,
                topologyIndex: topologyIndex,
                description: description,
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
