enum RaspberryPiKernelUpdatePreparationRejection: Equatable {
    case wrongBoard
    case destinationUnavailable
    case invalidImage
    case invalidDeviceTree
    case invalidTrampoline
    case invalidStagingAddress
    case copyFailed
    case cacheCleanFailed
}

struct PreparedRaspberryPiKernelUpdate: Equatable {
    let staging: KernelUpdateStagingLayout
    let image: RaspberryPiKernelImageMetadata
    let preservedDeviceTreeByteCount: UInt64
    let trampolineByteCount: UInt64
}

enum RaspberryPiKernelUpdatePreparationResult: Equatable {
    case prepared(PreparedRaspberryPiKernelUpdate)
    case rejected(RaspberryPiKernelUpdatePreparationRejection)
}

/// Pi-specific boot-image policy above the shared USB/session layers. It owns
/// no transport state and performs no activation until the caller has returned
/// COMMITTED to the host and quiesced every active driver.
enum RaspberryPiKernelUpdateActivator {
    static func prepare(
        platform: Platform,
        reservedDestination: KernelUpdateDestinationWindow?,
        staging: KernelUpdateStagingLayout,
        rawImageByteCount: UInt64
    ) -> RaspberryPiKernelUpdatePreparationResult {
        guard platform.kind == .raspberryPi5 else {
            return .rejected(.wrongBoard)
        }
        let expectedDestination = RaspberryPiKernelUpdateContract
            .destinationWindow
        guard reservedDestination == expectedDestination else {
            return .rejected(.destinationUnavailable)
        }
        guard rawImageByteCount >= UInt64(
                  RaspberryPiKernelImageValidator.headerByteCount
              ),
              rawImageByteCount <= staging.image.byteCount,
              rawImageByteCount <= UInt64(Int.max),
              let imageBytes = rawBuffer(
                  at: staging.image.baseAddress,
                  byteCount: rawImageByteCount
              )
        else {
            return .rejected(.invalidStagingAddress)
        }
        let metadata: RaspberryPiKernelImageMetadata
        switch RaspberryPiKernelImageValidator.validate(imageBytes) {
        case .accepted(let value):
            metadata = value
        case .rejected:
            return .rejected(.invalidImage)
        }
        guard metadata.runtimeImageByteCount
                <= expectedDestination.byteCount else {
            return .rejected(.invalidImage)
        }

        let deviceTreeByteCount = platform.deviceTreeSize
        guard deviceTreeByteCount > 0,
              deviceTreeByteCount <= staging.deviceTree.byteCount,
              deviceTreeByteCount <= UInt64(Int.max),
              let deviceTreeSource = rawBuffer(
                  at: platform.deviceTreeAddress,
                  byteCount: deviceTreeByteCount
              ),
              let deviceTreeDestination = mutableRawBuffer(
                  at: staging.deviceTree.baseAddress,
                  byteCount: deviceTreeByteCount
              )
        else {
            return .rejected(.invalidDeviceTree)
        }

        let trampolineSourceAddress = AArch64
            .softRestartTrampolineSourceAddress
        let trampolineByteCount = AArch64.softRestartTrampolineByteCount
        guard trampolineByteCount > 0,
              trampolineByteCount <= staging.trampoline.byteCount,
              trampolineByteCount <= UInt64(Int.max),
              let trampolineSource = rawBuffer(
                  at: trampolineSourceAddress,
                  byteCount: trampolineByteCount
              ),
              let trampolineDestination = mutableRawBuffer(
                  at: staging.trampoline.baseAddress,
                  byteCount: trampolineByteCount
              ),
              staging.activationStackTopAddress & 0xf == 0
        else {
            return .rejected(.invalidTrampoline)
        }

        copy(deviceTreeSource, to: deviceTreeDestination)
        copy(trampolineSource, to: trampolineDestination)
        guard deviceTreeDestination.count == Int(deviceTreeByteCount),
              trampolineDestination.count == Int(trampolineByteCount)
        else {
            return .rejected(.copyFailed)
        }
        guard AArch64.cleanDataCache(
                  address: staging.deviceTree.baseAddress,
                  byteCount: deviceTreeByteCount
              )
        else {
            return .rejected(.cacheCleanFailed)
        }

        return .prepared(
            PreparedRaspberryPiKernelUpdate(
                staging: staging,
                image: metadata,
                preservedDeviceTreeByteCount: deviceTreeByteCount,
                trampolineByteCount: trampolineByteCount
            )
        )
    }

    /// Requires the boot processor to be affinity zero and every other CPU
    /// described by firmware to report PSCI OFF. QEMU and active secondaries
    /// are deliberately rejected until a stop rendezvous exists.
    static func processorsAreQuiescent(platform: Platform) -> Bool {
        guard platform.kind == .raspberryPi5 else { return false }
        let executing = ProcessorAffinity.fromMPIDR(
            AArch64.multiprocessorAffinity
        )
        guard executing.rawValue == 0 else { return false }

        let conduit: PSCIConduit
        switch platform.firmwareCallConduit {
        case .hypervisorCall:
            conduit = .hypervisorCall
        case .secureMonitorCall:
            conduit = .secureMonitorCall
        case nil:
            return false
        }

        var sawExecutingProcessor = false
        var processorIndex = 0
        while processorIndex < 64,
              let rawAffinity = platform.processorAffinity(
                  at: processorIndex
              ) {
            guard let affinity = ProcessorAffinity(
                      deviceTreeValue: rawAffinity
                  )
            else { return false }
            var priorIndex = 0
            while priorIndex < processorIndex {
                if platform.processorAffinity(at: priorIndex)
                    == rawAffinity {
                    return false
                }
                priorIndex += 1
            }
            if affinity == executing {
                sawExecutingProcessor = true
            } else if PSCIFirmware.affinityInfo(
                        conduit: conduit,
                        targetAffinity: affinity.rawValue
                      ) != .off {
                return false
            }
            processorIndex += 1
        }
        guard processorIndex > 0,
              platform.processorAffinity(at: processorIndex) == nil,
              sawExecutingProcessor
        else {
            return false
        }
        return true
    }

    static func activate(_ prepared: PreparedRaspberryPiKernelUpdate) -> Never {
        AArch64.activateStagedKernel(
            sourceAddress: prepared.staging.image.baseAddress,
            rawImageByteCount: prepared.image.rawImageByteCount,
            destinationAddress: RaspberryPiKernelUpdateContract
                .destinationWindow.baseAddress,
            deviceTreeAddress: prepared.staging.deviceTree.baseAddress,
            trampolineAddress: prepared.staging.trampoline.baseAddress,
            stackTopAddress: prepared.staging.activationStackTopAddress,
            destinationRuntimeByteCount:
                prepared.image.runtimeImageByteCount,
            trampolineByteCount: prepared.trampolineByteCount
        )
    }

    private static func rawBuffer(
        at address: UInt64,
        byteCount: UInt64
    ) -> UnsafeRawBufferPointer? {
        guard address <= UInt64(UInt.max),
              byteCount <= UInt64(Int.max),
              byteCount <= UInt64.max - address,
              let pointer = UnsafeRawPointer(bitPattern: UInt(address))
        else { return nil }
        return UnsafeRawBufferPointer(
            start: pointer,
            count: Int(byteCount)
        )
    }

    private static func mutableRawBuffer(
        at address: UInt64,
        byteCount: UInt64
    ) -> UnsafeMutableRawBufferPointer? {
        guard address <= UInt64(UInt.max),
              byteCount <= UInt64(Int.max),
              byteCount <= UInt64.max - address,
              let pointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(address)
              )
        else { return nil }
        return UnsafeMutableRawBufferPointer(
            start: pointer,
            count: Int(byteCount)
        )
    }

    private static func copy(
        _ source: UnsafeRawBufferPointer,
        to destination: UnsafeMutableRawBufferPointer
    ) {
        var index = 0
        while index < source.count {
            destination[index] = source[index]
            index += 1
        }
    }
}
