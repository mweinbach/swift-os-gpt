/// Validates early driver resources against the discovered platform and turns
/// them into the exact reservations and mappings consumed by the final memory
/// runtime. Keeping this policy independent of linker-owned storage makes the
/// nonempty driver path host-testable without introducing a second planner.
struct BootDriverResourcePlan {
    private let resources: BootDriverResourceSet
    private let systemMemoryReservationMask: UInt8

    var memoryResourceCount: Int {
        resources.memoryResourceCount
    }

    var mmioResourceCount: Int {
        resources.mmioResourceCount
    }

    init?(
        resources: BootDriverResourceSet,
        platform: Platform,
        kernelImage: DeviceResource
    ) {
        guard Self.resourcesAreValid(
                  resources,
                  platform: platform,
                  kernelImage: kernelImage
              )
        else {
            return nil
        }
        var reservationMask: UInt8 = 0
        var memoryIndex = 0
        while memoryIndex < resources.memoryResourceCount {
            guard let resource = resources.memoryResource(at: memoryIndex)
            else {
                return nil
            }
            if platform.containsSystemMemory(
                baseAddress: resource.baseAddress,
                length: resource.length
            ) {
                reservationMask |= UInt8(1) << UInt8(memoryIndex)
            }
            memoryIndex += 1
        }
        self.resources = resources
        systemMemoryReservationMask = reservationMask
    }

    /// Returns an allocator exclusion only for a driver span backed by system
    /// RAM. External apertures can be identity-mapped but cannot be submitted
    /// to the system-RAM bootstrap as explicit reservations.
    func systemMemoryReservation(
        at index: Int
    ) -> PhysicalByteSpan? {
        guard index >= 0,
              index < resources.memoryResourceCount,
              systemMemoryReservationMask
                & (UInt8(1) << UInt8(index)) != 0,
              let resource = resources.memoryResource(at: index)
        else {
            return nil
        }
        return PhysicalByteSpan(
            baseAddress: resource.baseAddress,
            length: resource.length
        )
    }

    func memoryMapping(at index: Int) -> FinalMappingRegion? {
        guard let resource = resources.memoryResource(at: index) else {
            return nil
        }
        return FinalMappingRegion(
            virtualBaseAddress: resource.baseAddress,
            physicalBaseAddress: resource.baseAddress,
            byteCount: resource.length,
            role: resource.role
        )
    }

    func mmioMapping(at index: Int) -> FinalMappingRegion? {
        guard let resource = resources.mmioResource(at: index),
              let interval = Self.pageAlignedInterval(
                  baseAddress: resource.baseAddress,
                  length: resource.length
              )
        else {
            return nil
        }
        return FinalMappingRegion(
            virtualBaseAddress: interval.base,
            physicalBaseAddress: interval.base,
            byteCount: interval.end - interval.base,
            role: .device
        )
    }

    private static func resourcesAreValid(
        _ resources: BootDriverResourceSet,
        platform: Platform,
        kernelImage: DeviceResource
    ) -> Bool {
        guard pageAlignedInterval(
                  baseAddress: kernelImage.baseAddress,
                  length: kernelImage.length
              ) != nil
        else {
            return false
        }

        var memoryIndex = 0
        while memoryIndex < resources.memoryResourceCount {
            guard let resource = resources.memoryResource(at: memoryIndex),
                  resource.endAddress
                    <= FinalTranslationTableGeometry.virtualAddressLimit,
                  resource.endAddress
                    <= FinalTranslationTableGeometry.outputAddressLimit
            else {
                return false
            }
            let containedInRAM = platform.containsSystemMemory(
                baseAddress: resource.baseAddress,
                length: resource.length
            )
            let overlapsRAM = platform.overlapsSystemMemory(
                baseAddress: resource.baseAddress,
                length: resource.length
            )
            guard (!overlapsRAM || containedInRAM),
                  (!containedInRAM || resource.reservesSystemMemory),
                  !overlapsProtectedMemory(
                      baseAddress: resource.baseAddress,
                      length: resource.length,
                      platform: platform,
                      kernelImage: kernelImage
                  ),
                  !overlapsBasePlatformMMIO(
                      baseAddress: resource.baseAddress,
                      length: resource.length,
                      platform: platform
                  )
            else {
                return false
            }
            memoryIndex += 1
        }

        var mmioIndex = 0
        while mmioIndex < resources.mmioResourceCount {
            guard let resource = resources.mmioResource(at: mmioIndex),
                  let interval = pageAlignedInterval(
                      baseAddress: resource.baseAddress,
                      length: resource.length
                  ),
                  interval.end
                    <= FinalTranslationTableGeometry.virtualAddressLimit,
                  interval.end
                    <= FinalTranslationTableGeometry.outputAddressLimit,
                  !platform.overlapsSystemMemory(
                      baseAddress: interval.base,
                      length: interval.end - interval.base
                  ),
                  !overlapsProtectedMemory(
                      baseAddress: interval.base,
                      length: interval.end - interval.base,
                      platform: platform,
                      kernelImage: kernelImage
                  ),
                  !overlapsBasePlatformMMIO(
                      baseAddress: interval.base,
                      length: interval.end - interval.base,
                      platform: platform
                  )
            else {
                return false
            }
            mmioIndex += 1
        }
        return true
    }

    private static func overlapsProtectedMemory(
        baseAddress: UInt64,
        length: UInt64,
        platform: Platform,
        kernelImage: DeviceResource
    ) -> Bool {
        pageAlignedRegionsOverlap(
            firstBase: baseAddress,
            firstLength: length,
            second: kernelImage
        ) || pageAlignedRegionsOverlap(
            firstBase: baseAddress,
            firstLength: length,
            secondBase: platform.deviceTreeAddress,
            secondLength: platform.deviceTreeSize
        )
    }

    private static func overlapsBasePlatformMMIO(
        baseAddress: UInt64,
        length: UInt64,
        platform: Platform
    ) -> Bool {
        if pageAlignedRegionsOverlap(
            firstBase: baseAddress,
            firstLength: length,
            second: platform.serial
        ) {
            return true
        }
        switch platform.interruptController {
        case let .gicV2(distributor, cpuInterface):
            if pageAlignedRegionsOverlap(
                firstBase: baseAddress,
                firstLength: length,
                second: distributor
            ) || pageAlignedRegionsOverlap(
                firstBase: baseAddress,
                firstLength: length,
                second: cpuInterface
            ) {
                return true
            }
        case let .gicV3(distributor, redistributor):
            if pageAlignedRegionsOverlap(
                firstBase: baseAddress,
                firstLength: length,
                second: distributor
            ) || pageAlignedRegionsOverlap(
                firstBase: baseAddress,
                firstLength: length,
                second: redistributor
            ) {
                return true
            }
        }
        if let firmware = platform.firmwareConfiguration,
           pageAlignedRegionsOverlap(
               firstBase: baseAddress,
               firstLength: length,
               second: firmware
           ) {
            return true
        }
        if let virtio = platform.virtioTransportWindow,
           pageAlignedRegionsOverlap(
               firstBase: baseAddress,
               firstLength: length,
               second: virtio
           ) {
            return true
        }
        return false
    }

    private static func pageAlignedRegionsOverlap(
        firstBase: UInt64,
        firstLength: UInt64,
        second: DeviceResource
    ) -> Bool {
        pageAlignedRegionsOverlap(
            firstBase: firstBase,
            firstLength: firstLength,
            secondBase: second.baseAddress,
            secondLength: second.length
        )
    }

    private static func pageAlignedRegionsOverlap(
        firstBase: UInt64,
        firstLength: UInt64,
        secondBase: UInt64,
        secondLength: UInt64
    ) -> Bool {
        guard let first = pageAlignedInterval(
                  baseAddress: firstBase,
                  length: firstLength
              ),
              let second = pageAlignedInterval(
                  baseAddress: secondBase,
                  length: secondLength
              )
        else {
            return true
        }
        return first.base < second.end && second.base < first.end
    }

    private static func pageAlignedInterval(
        baseAddress: UInt64,
        length: UInt64
    ) -> (base: UInt64, end: UInt64)? {
        guard length > 0,
              length <= UInt64.max - baseAddress,
              let end = MemoryPageGeometry.alignUp(baseAddress + length)
        else {
            return nil
        }
        let base = MemoryPageGeometry.alignDown(baseAddress)
        guard end > base else { return nil }
        return (base: base, end: end)
    }
}
