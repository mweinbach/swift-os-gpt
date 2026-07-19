enum PSCIConduit: UInt8, Equatable {
    /// Used by QEMU virt when the kernel runs at EL1 beneath a hypervisor.
    case hypervisorCall
    /// Used by Raspberry Pi 5 firmware's PSCI node (`method = "smc"`).
    case secureMonitorCall
}

enum PSCIFunctionID {
    /// PSCI v0.2+ CPU_ON using the SMCCC 64-bit calling convention.
    static let cpuOn64: UInt64 = 0xc400_0003
    /// PSCI v0.2+ AFFINITY_INFO for a 64-bit target affinity argument.
    static let affinityInfo64: UInt64 = 0xc400_0004
}

enum PSCIAffinityInfoResult: Equatable {
    case on
    case off
    case onPending
    case failure(PSCIReturnValue)

    init(rawRegisterValue: UInt64) {
        switch rawRegisterValue {
        case 0: self = .on
        case 1: self = .off
        case 2: self = .onPending
        default:
            self = .failure(
                PSCIReturnValue(rawRegisterValue: rawRegisterValue)
            )
        }
    }
}

/// Signed PSCI return values decoded from the raw x0 register bit pattern.
enum PSCIReturnValue: Equatable {
    case success
    case notSupported
    case invalidParameters
    case denied
    case alreadyOn
    case onPending
    case internalFailure
    case notPresent
    case disabled
    case invalidAddress
    case unknown(Int64)

    init(rawRegisterValue: UInt64) {
        switch Int64(bitPattern: rawRegisterValue) {
        case 0: self = .success
        case -1: self = .notSupported
        case -2: self = .invalidParameters
        case -3: self = .denied
        case -4: self = .alreadyOn
        case -5: self = .onPending
        case -6: self = .internalFailure
        case -7: self = .notPresent
        case -8: self = .disabled
        case -9: self = .invalidAddress
        case let value: self = .unknown(value)
        }
    }
}

enum ProcessorBootState: UInt64, Equatable {
    case absent = 0
    case offline = 1
    case starting = 2
    case online = 3
    case failed = 4
    /// Firmware reported ALREADY_ON, but our secondary entry did not run.
    case firmwareAlreadyOn = 5
}

/// Single-writer state logic for topology setup and host tests. Concurrent
/// publication uses the acquire/release hooks in SMPRuntime.swift instead.
struct ProcessorBootStateTable {
    private var storage: UnsafeMutableBufferPointer<UInt64>
    let processorCount: Int

    init?(
        storage: UnsafeMutableBufferPointer<UInt64>,
        processorCount: Int
    ) {
        guard processorCount > 0,
              processorCount <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              storage.count >= processorCount,
              let baseAddress = storage.baseAddress,
              UInt(bitPattern: baseAddress) & 0x7 == 0
        else {
            return nil
        }
        self.storage = storage
        self.processorCount = processorCount

        var index = 0
        while index < storage.count {
            storage[index] = ProcessorBootState.absent.rawValue
            index += 1
        }
        index = 0
        while index < processorCount {
            storage[index] = ProcessorBootState.offline.rawValue
            index += 1
        }
        storage[0] = ProcessorBootState.online.rawValue
    }

    func state(of logicalProcessorID: Int) -> ProcessorBootState? {
        guard logicalProcessorID >= 0,
              logicalProcessorID < processorCount
        else {
            return nil
        }
        return ProcessorBootState(rawValue: storage[logicalProcessorID])
    }

    mutating func transition(
        logicalProcessorID: Int,
        from expected: ProcessorBootState,
        to next: ProcessorBootState
    ) -> Bool {
        guard logicalProcessorID > 0,
              logicalProcessorID < processorCount,
              state(of: logicalProcessorID) == expected
        else {
            return false
        }
        storage[logicalProcessorID] = next.rawValue
        return true
    }
}

enum SecondaryProcessorStartOutcome: Equatable {
    case online
    case timedOut
    case firmwareAlreadyOn
    case rejected(PSCIReturnValue)
}

struct SecondaryProcessorStartReport: Equatable {
    let target: SecondaryProcessorTarget
    let outcome: SecondaryProcessorStartOutcome
    let pollCount: UInt64

    static let vacant = SecondaryProcessorStartReport(
        target: .vacant,
        outcome: .rejected(.unknown(0)),
        pollCount: 0
    )
}

struct SMPStartupSummary: Equatable {
    let selectedProcessorCount: Int
    let onlineProcessorCount: Int
    let firmwareAlreadyOnCount: Int
    let timedOutCount: Int
    let rejectedCount: Int
}

enum SMPStartupConfigurationError: Equatable {
    case invalidSecondaryEntryAddress
    case invalidPollLimit
}

enum SMPStartupResult: Equatable {
    case completed(SMPStartupSummary)
    case invalidConfiguration(SMPStartupConfigurationError)
}
