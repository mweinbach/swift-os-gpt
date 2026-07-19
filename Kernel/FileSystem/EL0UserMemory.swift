struct EL0UserMemoryPermissions: RawRepresentable, Equatable {
    let rawValue: UInt8

    init?(rawValue: UInt8) {
        guard rawValue & ~Self.knownBits == 0 else { return nil }
        self.rawValue = rawValue
    }

    static let none = Self(rawValue: 0)!
    static let read = Self(rawValue: 1 << 0)!
    static let write = Self(rawValue: 1 << 1)!
    static let readWrite = Self(rawValue: read.rawValue | write.rawValue)!

    func contains(_ required: Self) -> Bool {
        rawValue & required.rawValue == required.rawValue
    }

    private static let knownBits: UInt8 = (1 << 2) - 1
}

/// One user-visible range paired with an EL1-only kernel mapping of its same
/// backing bytes. The mapped pointer is intentionally private: callers can
/// move bytes only through `EL0UserMemoryMap` after checking the user range.
struct EL0UserMemoryRegion {
    let virtualBaseAddress: UInt64
    let byteCount: UInt64
    let permissions: EL0UserMemoryPermissions
    private let kernelMappedBaseAddress: UnsafeMutableRawPointer

    init?(
        virtualBaseAddress: UInt64,
        byteCount: UInt64,
        permissions: EL0UserMemoryPermissions,
        kernelMappedBaseAddress: UnsafeMutableRawPointer?
    ) {
        guard virtualBaseAddress != 0,
              byteCount > 0,
              byteCount <= UInt64.max - virtualBaseAddress,
              byteCount <= UInt64(Int.max),
              permissions != .none,
              let kernelMappedBaseAddress
        else { return nil }
        self.virtualBaseAddress = virtualBaseAddress
        self.byteCount = byteCount
        self.permissions = permissions
        self.kernelMappedBaseAddress = kernelMappedBaseAddress
    }

    var virtualEndAddress: UInt64 {
        virtualBaseAddress + byteCount
    }

    fileprivate func contains(_ virtualAddress: UInt64) -> Bool {
        virtualAddress >= virtualBaseAddress
            && virtualAddress < virtualEndAddress
    }

    fileprivate func mappedAddress(
        for virtualAddress: UInt64
    ) -> UnsafeMutableRawPointer? {
        guard contains(virtualAddress) else { return nil }
        let offset = virtualAddress - virtualBaseAddress
        guard offset <= UInt64(Int.max) else { return nil }
        return kernelMappedBaseAddress.advanced(by: Int(offset))
    }
}

enum EL0UserMemoryAccess: UInt8 {
    case read
    case write

    fileprivate var permission: EL0UserMemoryPermissions {
        switch self {
        case .read: return .read
        case .write: return .write
        }
    }
}

/// Sorted, fixed-capacity user mapping view used only at syscall copy
/// boundaries. Validation walks every covered region before the first byte is
/// copied, so a range ending in a guard page cannot produce a partial copy.
struct EL0UserMemoryMap {
    /// Current AArch64 TTBR0 configuration uses 39 input bits. A future
    /// address-space configuration supplies its own limit at construction.
    static let defaultVirtualAddressLimit: UInt64 = 1 << 39

    private let regions: UnsafeBufferPointer<EL0UserMemoryRegion>
    private let virtualAddressLimit: UInt64

    init?(
        regions: UnsafeBufferPointer<EL0UserMemoryRegion>,
        virtualAddressLimit: UInt64 = defaultVirtualAddressLimit
    ) {
        guard !regions.isEmpty, virtualAddressLimit > 1 else { return nil }
        var index = 0
        var previousEnd: UInt64 = 0
        while index < regions.count {
            let region = regions[index]
            guard region.virtualEndAddress <= virtualAddressLimit,
                  index == 0 || region.virtualBaseAddress >= previousEnd
            else {
                return nil
            }
            previousEnd = region.virtualEndAddress
            index += 1
        }
        self.regions = regions
        self.virtualAddressLimit = virtualAddressLimit
    }

    func validate(
        virtualAddress: UInt64,
        byteCount: UInt64,
        access: EL0UserMemoryAccess
    ) -> Bool {
        if byteCount == 0 { return true }
        guard virtualAddress != 0,
              virtualAddress < virtualAddressLimit,
              byteCount <= virtualAddressLimit - virtualAddress
        else { return false }

        let endAddress = virtualAddress + byteCount
        var cursor = virtualAddress
        while cursor < endAddress {
            guard let regionIndex = index(containing: cursor) else {
                return false
            }
            let region = regions[regionIndex]
            guard region.permissions.contains(access.permission) else {
                return false
            }
            cursor = min(endAddress, region.virtualEndAddress)
        }
        return true
    }

    func copyIn(
        from virtualAddress: UInt64,
        into destination: UnsafeMutableRawBufferPointer
    ) -> Bool {
        let byteCount = UInt64(destination.count)
        guard validate(
            virtualAddress: virtualAddress,
            byteCount: byteCount,
            access: .read
        ) else { return false }
        if destination.isEmpty { return true }

        var cursor = virtualAddress
        var destinationOffset = 0
        let endAddress = virtualAddress + byteCount
        while cursor < endAddress {
            guard let regionIndex = index(containing: cursor),
                  let source = regions[regionIndex].mappedAddress(for: cursor)
            else { return false }
            let chunk = Int(
                min(endAddress, regions[regionIndex].virtualEndAddress) - cursor
            )
            copyBytes(
                from: UnsafeRawPointer(source),
                to: destination.baseAddress!.advanced(by: destinationOffset),
                count: chunk
            )
            cursor += UInt64(chunk)
            destinationOffset += chunk
        }
        return true
    }

    func copyOut(
        _ source: UnsafeRawBufferPointer,
        to virtualAddress: UInt64
    ) -> Bool {
        let byteCount = UInt64(source.count)
        guard validate(
            virtualAddress: virtualAddress,
            byteCount: byteCount,
            access: .write
        ) else { return false }
        if source.isEmpty { return true }

        var cursor = virtualAddress
        var sourceOffset = 0
        let endAddress = virtualAddress + byteCount
        while cursor < endAddress {
            guard let regionIndex = index(containing: cursor),
                  let destination = regions[regionIndex].mappedAddress(for: cursor)
            else { return false }
            let chunk = Int(
                min(endAddress, regions[regionIndex].virtualEndAddress) - cursor
            )
            copyBytes(
                from: source.baseAddress!.advanced(by: sourceOffset),
                to: destination,
                count: chunk
            )
            cursor += UInt64(chunk)
            sourceOffset += chunk
        }
        return true
    }

    private func index(containing virtualAddress: UInt64) -> Int? {
        var low = 0
        var high = regions.count
        while low < high {
            let middle = low + (high - low) / 2
            let region = regions[middle]
            if virtualAddress < region.virtualBaseAddress {
                high = middle
            } else if virtualAddress >= region.virtualEndAddress {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    private func copyBytes(
        from source: UnsafeRawPointer,
        to destination: UnsafeMutableRawPointer,
        count: Int
    ) {
        var index = 0
        while index < count {
            destination.storeBytes(
                of: source.load(fromByteOffset: index, as: UInt8.self),
                toByteOffset: index,
                as: UInt8.self
            )
            index += 1
        }
    }
}
