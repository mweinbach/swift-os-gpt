enum RaspberryPiABSelectorState: Equatable {
    case defaultA
    case defaultB

    var slot: BootSlot {
        switch self {
        case .defaultA: return .a
        case .defaultB: return .b
        }
    }
}

enum RaspberryPiABSelectorFailure: Equatable {
    case invalidGeometry
    case invalidScratch
    case read(block: UInt64, result: BlockDeviceIOResult)
    case malformedBootSector
    case malformedRescueManifest
    case malformedAllocationTables
    case malformedRootDirectory
    case corruptRescuePayload
    case malformedPolicy
    case write(BlockDeviceIOResult)
    case synchronize(BlockDeviceIOResult)
    case readback(BlockDeviceIOResult)
    case readbackMismatch
}

enum RaspberryPiABSelectorInspectionResult: Equatable {
    case state(RaspberryPiABSelectorState)
    case failure(RaspberryPiABSelectorFailure)
}

enum RaspberryPiABSelectorCommitResult: Equatable {
    case committed(RaspberryPiABSelectorState)
    case unchanged(RaspberryPiABSelectorState)
    /// Immutable validation or an input read failed before the mutable policy
    /// sector was offered to the block device. The existing selector is still
    /// authoritative, so board policy may leave the prior confirmed slot up.
    case rejectedBeforeWrite(RaspberryPiABSelectorFailure)
    /// A selector write may have reached media, or its durability/readback
    /// could not be proved. No caller may infer which policy firmware will see.
    case durabilityUncertain(RaspberryPiABSelectorFailure)
}

/// Strict writer for the deterministic selector produced by the host media
/// builder. It has authority over one 512-byte file cluster only; no MBR, FAT,
/// directory, payload-slot, log, or SwiftFS write is expressible here.
enum RaspberryPiABSelector {
    static let partitionBlockCount: UInt64 = 2_047
    static let autobootDataBlock: UInt64 = 15

    private struct RescueFileDescriptor {
        let byteCount: UInt64
        let firstCluster: UInt64
        let clusterCount: UInt64
        let digest: USBKernelUpdateSHA256Digest

        var lastCluster: UInt64 {
            firstCluster + clusterCount - 1
        }
    }

    private struct RescueLayout {
        let config: RescueFileDescriptor
        let kernel: RescueFileDescriptor
        let deviceTree: RescueFileDescriptor
        let overlayDirectoryCluster: UInt64
        let dwc2Overlay: RescueFileDescriptor

        func descriptor(at index: Int) -> RescueFileDescriptor? {
            switch index {
            case 0: return config
            case 1: return kernel
            case 2: return deviceTree
            case 3: return dwc2Overlay
            default: return nil
            }
        }
    }

    private static let selectorA: StaticString = """
    [all]
    tryboot_a_b=1
    boot_partition=2
    [tryboot]
    boot_partition=3

    """
    private static let selectorB: StaticString = """
    [all]
    tryboot_a_b=1
    boot_partition=3
    [tryboot]
    boot_partition=2

    """

    static func inspect<Device: BlockDevice>(
        _ device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> RaspberryPiABSelectorInspectionResult {
        guard device.geometry.logicalBlockByteCount == 512,
              device.geometry.logicalBlockCount == partitionBlockCount
        else { return .failure(.invalidGeometry) }
        guard scratch.count >= 1_024, let scratchBase = scratch.baseAddress else {
            return .failure(.invalidScratch)
        }
        let first = UnsafeMutableRawBufferPointer(start: scratchBase, count: 512)
        let second = UnsafeMutableRawBufferPointer(
            start: scratchBase.advanced(by: 512),
            count: 512
        )
        if let failure = validateImmutableLayout(
            on: &device,
            first: first,
            second: second
        ) {
            return .failure(failure)
        }
        if let failure = read(
            &device,
            block: autobootDataBlock,
            into: first
        ) {
            return .failure(failure)
        }
        if matchesPolicy(first, expected: selectorA) {
            return .state(.defaultA)
        }
        if matchesPolicy(first, expected: selectorB) {
            return .state(.defaultB)
        }
        return .failure(.malformedPolicy)
    }

    static func commit<Device: BlockDevice>(
        defaultSlot: BootSlot,
        to device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> RaspberryPiABSelectorCommitResult {
        let desired: RaspberryPiABSelectorState = defaultSlot == .a
            ? .defaultA : .defaultB
        guard device.geometry.logicalBlockByteCount == 512,
              device.geometry.logicalBlockCount == partitionBlockCount
        else { return .rejectedBeforeWrite(.invalidGeometry) }
        guard scratch.count >= 1_024, let base = scratch.baseAddress else {
            return .rejectedBeforeWrite(.invalidScratch)
        }
        let block = UnsafeMutableRawBufferPointer(start: base, count: 512)
        let second = UnsafeMutableRawBufferPointer(
            start: base.advanced(by: 512),
            count: 512
        )
        if let failure = validateImmutableLayout(
            on: &device,
            first: block,
            second: second
        ) {
            return .rejectedBeforeWrite(failure)
        }
        if let failure = read(
            &device,
            block: autobootDataBlock,
            into: block
        ) {
            return .rejectedBeforeWrite(failure)
        }
        let desiredPolicy = defaultSlot == .a ? selectorA : selectorB
        if matchesPolicy(block, expected: desiredPolicy) {
            let synchronized = device.synchronize()
            guard synchronized == .success else {
                return .durabilityUncertain(.synchronize(synchronized))
            }
            let readback = device.readBlock(
                at: autobootDataBlock,
                into: block
            )
            guard readback == .success else {
                return .durabilityUncertain(.readback(readback))
            }
            guard matchesPolicy(block, expected: desiredPolicy) else {
                return .durabilityUncertain(.readbackMismatch)
            }
            return .unchanged(desired)
        }

        // A power cut may tear the sole mutable sector after the immutable
        // rescue layout was validated. Transaction replay is allowed to repair
        // either the opposite valid policy or an unparseable policy, while no
        // malformed FAT, directory, manifest, or rescue payload gains write
        // authority.
        var index = 0
        while index < block.count {
            block[index] = 0
            index += 1
        }
        desiredPolicy.withUTF8Buffer { bytes in
            var byte = 0
            while byte < bytes.count {
                block[byte] = bytes[byte]
                byte += 1
            }
        }
        let write = device.writeBlock(
            at: autobootDataBlock,
            from: UnsafeRawBufferPointer(start: base, count: 512)
        )
        guard write == .success else {
            return .durabilityUncertain(.write(write))
        }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .durabilityUncertain(.synchronize(synchronized))
        }
        let readback = device.readBlock(at: autobootDataBlock, into: block)
        guard readback == .success else {
            return .durabilityUncertain(.readback(readback))
        }
        guard matchesPolicy(block, expected: desiredPolicy) else {
            return .durabilityUncertain(.readbackMismatch)
        }
        return .committed(desired)
    }

    private static func validateImmutableLayout<Device: BlockDevice>(
        on device: inout Device,
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) -> RaspberryPiABSelectorFailure? {
        if let failure = read(&device, block: 0, into: first) {
            return failure
        }
        guard validBootSector(first) else { return .malformedBootSector }
        guard let rescue = rescueLayout(from: first) else {
            return .malformedRescueManifest
        }

        var fatBlock: UInt64 = 0
        while fatBlock < 6 {
            let primary = 1 + fatBlock
            let backup = 7 + fatBlock
            if let failure = read(&device, block: primary, into: first) {
                return failure
            }
            if let failure = read(&device, block: backup, into: second) {
                return failure
            }
            guard buffersEqual(first, second),
                  validAllocationBlock(
                      first,
                      index: fatBlock,
                      rescue: rescue
                  )
            else { return .malformedAllocationTables }
            fatBlock += 1
        }

        if let failure = read(&device, block: 13, into: first) {
            return failure
        }
        guard validRootDirectory(first, rescue: rescue) else {
            return .malformedRootDirectory
        }
        if let failure = read(&device, block: 14, into: first) {
            return failure
        }
        guard allZero(first) else { return .malformedRootDirectory }
        if let failure = read(
            &device,
            block: autobootDataBlock + rescue.overlayDirectoryCluster - 2,
            into: first
        ) {
            return failure
        }
        guard validOverlayDirectory(first, rescue: rescue) else {
            return .malformedRootDirectory
        }
        return validateRescuePayload(
            on: &device,
            scratch: first,
            layout: rescue
        )
    }

    private static func read<Device: BlockDevice>(
        _ device: inout Device,
        block: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> RaspberryPiABSelectorFailure? {
        let result = device.readBlock(at: block, into: output)
        return result == .success ? nil : .read(block: block, result: result)
    }

    private static func validBootSector(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        bytes[0] == 0xeb && bytes[1] == 0x3c && bytes[2] == 0x90
            && matches(bytes, at: 3, expected: "SWIFTOS ")
            && bytes[510] == 0x55 && bytes[511] == 0xaa
            && readLE16(bytes, at: 11) == 512
            && bytes[13] == 1
            && readLE16(bytes, at: 14) == 1
            && bytes[16] == 2
            && readLE16(bytes, at: 17) == 32
            && readLE16(bytes, at: 19) == 2_047
            && bytes[21] == 0xf8
            && readLE16(bytes, at: 22) == 6
            && readLE16(bytes, at: 24) == 63
            && readLE16(bytes, at: 26) == 255
            && readLE32(bytes, at: 28) == 1
            && readLE32(bytes, at: 32) == 0
            && bytes[36] == 0x80
            && bytes[37] == 0
            && bytes[38] == 0x29
            && readLE32(bytes, at: 39) == 0x4354_4c31
            && matches(bytes, at: 43, expected: "SWIFTOS-CTL")
            && matches(bytes, at: 54, expected: "FAT12   ")
            && bytes[62] == 0 && bytes[63] == 0
            && allZero(bytes, from: 224, to: 252)
            && allZero(bytes, from: 256, to: 510)
    }

    private static func rescueLayout(
        from bytes: UnsafeMutableRawBufferPointer
    ) -> RescueLayout? {
        let base = 64
        guard matches(bytes, at: base, expected: "SWRSQ001"),
              readLE16(bytes, at: base + 8) == 2,
              readLE16(bytes, at: base + 10) == 192,
              readLE16(bytes, at: base + 12) == 4,
              readLE16(bytes, at: base + 14) == 0,
              allZero(bytes, from: base + 160, to: base + 188),
              let address = bytes.baseAddress?.advanced(by: base),
              readLE32(bytes, at: base + 188)
                == StorageCRC32.checksum(UnsafeRawBufferPointer(
                    start: address,
                    count: 188
                ))
        else { return nil }

        let configCount = UInt64(readLE32(bytes, at: base + 16))
        let kernelCount = UInt64(readLE32(bytes, at: base + 20))
        let treeCount = UInt64(readLE32(bytes, at: base + 24))
        let overlayCount = UInt64(readLE32(bytes, at: base + 28))
        guard configCount != 0, kernelCount != 0, treeCount != 0,
              overlayCount != 0,
              let configDigest = digest(bytes, at: base + 32),
              let kernelDigest = digest(bytes, at: base + 64),
              let treeDigest = digest(bytes, at: base + 96),
              let overlayDigest = digest(bytes, at: base + 128),
              let configClusters = clusterCount(for: configCount),
              let kernelClusters = clusterCount(for: kernelCount),
              let treeClusters = clusterCount(for: treeCount),
              let overlayClusters = clusterCount(for: overlayCount)
        else { return nil }

        let config = RescueFileDescriptor(
            byteCount: configCount,
            firstCluster: 3,
            clusterCount: configClusters,
            digest: configDigest
        )
        guard config.lastCluster < UInt64.max,
              config.lastCluster + 1 <= UInt64.max - kernelClusters
        else { return nil }
        let kernel = RescueFileDescriptor(
            byteCount: kernelCount,
            firstCluster: config.lastCluster + 1,
            clusterCount: kernelClusters,
            digest: kernelDigest
        )
        guard kernel.lastCluster < UInt64.max,
              kernel.lastCluster + 1 <= UInt64.max - treeClusters
        else { return nil }
        let deviceTree = RescueFileDescriptor(
            byteCount: treeCount,
            firstCluster: kernel.lastCluster + 1,
            clusterCount: treeClusters,
            digest: treeDigest
        )
        guard deviceTree.lastCluster < UInt64.max - 1,
              deviceTree.lastCluster + 2 <= UInt64.max - overlayClusters
        else { return nil }
        let overlayDirectoryCluster = deviceTree.lastCluster + 1
        let dwc2Overlay = RescueFileDescriptor(
            byteCount: overlayCount,
            firstCluster: overlayDirectoryCluster + 1,
            clusterCount: overlayClusters,
            digest: overlayDigest
        )
        // 2,032 one-sector data clusters map to FAT cluster IDs 2...2,033.
        guard dwc2Overlay.lastCluster <= 2_033 else { return nil }
        return RescueLayout(
            config: config,
            kernel: kernel,
            deviceTree: deviceTree,
            overlayDirectoryCluster: overlayDirectoryCluster,
            dwc2Overlay: dwc2Overlay
        )
    }

    private static func digest(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> USBKernelUpdateSHA256Digest? {
        guard let base = bytes.baseAddress, offset >= 0,
              offset <= bytes.count - 32
        else { return nil }
        return USBKernelUpdateSHA256Digest(bytes: UnsafeRawBufferPointer(
            start: base.advanced(by: offset),
            count: 32
        ))
    }

    private static func clusterCount(for byteCount: UInt64) -> UInt64? {
        guard byteCount != 0, byteCount <= UInt64.max - 511 else { return nil }
        return (byteCount + 511) / 512
    }

    private static func validAllocationBlock(
        _ bytes: UnsafeMutableRawBufferPointer,
        index: UInt64,
        rescue: RescueLayout
    ) -> Bool {
        let base = index * 512
        var byte = 0
        while byte < bytes.count {
            guard bytes[byte] == expectedFATByte(
                      at: base + UInt64(byte),
                      rescue: rescue
                  )
            else { return false }
            byte += 1
        }
        return true
    }

    private static func expectedFATByte(
        at byte: UInt64,
        rescue: RescueLayout
    ) -> UInt8 {
        let pair = byte / 3
        let evenCluster = pair * 2
        let even = expectedFATEntry(evenCluster, rescue: rescue)
        let odd = expectedFATEntry(evenCluster + 1, rescue: rescue)
        switch byte % 3 {
        case 0: return UInt8(truncatingIfNeeded: even)
        case 1:
            return UInt8(truncatingIfNeeded: even >> 8)
                | UInt8(truncatingIfNeeded: odd << 4)
        default: return UInt8(truncatingIfNeeded: odd >> 4)
        }
    }

    private static func expectedFATEntry(
        _ cluster: UInt64,
        rescue: RescueLayout
    ) -> UInt16 {
        if cluster == 0 { return 0x0ff8 }
        if cluster == 1 || cluster == 2 { return 0x0fff }
        if cluster == rescue.overlayDirectoryCluster { return 0x0fff }
        var index = 0
        while let file = rescue.descriptor(at: index) {
            if cluster >= file.firstCluster, cluster <= file.lastCluster {
                return cluster == file.lastCluster
                    ? 0x0fff : UInt16(cluster + 1)
            }
            index += 1
        }
        return 0
    }

    private static func validRootDirectory(
        _ bytes: UnsafeMutableRawBufferPointer,
        rescue: RescueLayout
    ) -> Bool {
        guard validLongNameEntry(
                  bytes,
                  at: 0,
                  name: "autoboot.txt",
                  shortName: "AUTOBOOTTXT",
                  ordinal: 1,
                  entryCount: 1
              ), validRootEntry(
                  bytes,
                  at: 32,
                  name: "AUTOBOOTTXT",
                  firstCluster: 2,
                  byteCount: UInt32(selectorA.utf8CodeUnitCount),
                  attributes: 0x20
              ), selectorA.utf8CodeUnitCount == selectorB.utf8CodeUnitCount,
              validLongNameEntry(
                  bytes,
                  at: 64,
                  name: "config.txt",
                  shortName: "CONFIG  TXT",
                  ordinal: 1,
                  entryCount: 1
              ), validRootEntry(
                  bytes,
                  at: 96,
                  name: "CONFIG  TXT",
                  firstCluster: rescue.config.firstCluster,
                  byteCount: UInt32(rescue.config.byteCount),
                  attributes: 0x20
              ), validLongNameEntry(
                  bytes,
                  at: 128,
                  name: "kernel8.img",
                  shortName: "KERNEL8 IMG",
                  ordinal: 1,
                  entryCount: 1
              ), validRootEntry(
                  bytes,
                  at: 160,
                  name: "KERNEL8 IMG",
                  firstCluster: rescue.kernel.firstCluster,
                  byteCount: UInt32(rescue.kernel.byteCount),
                  attributes: 0x20
              ), validLongNameEntry(
                  bytes,
                  at: 192,
                  name: "bcm2712-rpi-5-b.dtb",
                  shortName: "BCM271~1DTB",
                  ordinal: 2,
                  entryCount: 2
              ), validLongNameEntry(
                  bytes,
                  at: 224,
                  name: "bcm2712-rpi-5-b.dtb",
                  shortName: "BCM271~1DTB",
                  ordinal: 1,
                  entryCount: 2
              ), validRootEntry(
                  bytes,
                  at: 256,
                  name: "BCM271~1DTB",
                  firstCluster: rescue.deviceTree.firstCluster,
                  byteCount: UInt32(rescue.deviceTree.byteCount),
                  attributes: 0x20
              ), validLongNameEntry(
                  bytes,
                  at: 288,
                  name: "overlays",
                  shortName: "OVERLAYS   ",
                  ordinal: 1,
                  entryCount: 1
              ), validRootEntry(
                  bytes,
                  at: 320,
                  name: "OVERLAYS   ",
                  firstCluster: rescue.overlayDirectoryCluster,
                  byteCount: 0,
                  attributes: 0x10
              ), allZero(bytes, from: 352, to: bytes.count)
        else { return false }
        return true
    }

    private static func validOverlayDirectory(
        _ bytes: UnsafeMutableRawBufferPointer,
        rescue: RescueLayout
    ) -> Bool {
        validRootEntry(
            bytes,
            at: 0,
            name: ".          ",
            firstCluster: rescue.overlayDirectoryCluster,
            byteCount: 0,
            attributes: 0x10
        ) && validRootEntry(
            bytes,
            at: 32,
            name: "..         ",
            firstCluster: 0,
            byteCount: 0,
            attributes: 0x10
        ) && validLongNameEntry(
            bytes,
            at: 64,
            name: "dwc2.dtbo",
            shortName: "DWC2~1  DTB",
            ordinal: 1,
            entryCount: 1
        ) && validRootEntry(
            bytes,
            at: 96,
            name: "DWC2~1  DTB",
            firstCluster: rescue.dwc2Overlay.firstCluster,
            byteCount: UInt32(rescue.dwc2Overlay.byteCount),
            attributes: 0x20
        ) && allZero(bytes, from: 128, to: bytes.count)
    }

    private static func validLongNameEntry(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int,
        name: StaticString,
        shortName: StaticString,
        ordinal: Int,
        entryCount: Int
    ) -> Bool {
        guard ordinal > 0, ordinal <= entryCount,
              entryCount > 0, entryCount <= 0x1f,
              offset >= 0, offset <= bytes.count - 32,
              shortName.utf8CodeUnitCount == 11
        else { return false }
        let sequence = ordinal | (ordinal == entryCount ? 0x40 : 0)
        guard bytes[offset] == UInt8(sequence), bytes[offset + 11] == 0x0f,
              bytes[offset + 12] == 0, bytes[offset + 26] == 0,
              bytes[offset + 27] == 0,
              bytes[offset + 13] == longNameChecksum(shortName)
        else { return false }
        return name.withUTF8Buffer { nameBytes in
            var index = 0
            while index < 13 {
                let nameIndex = (ordinal - 1) * 13 + index
                let expected: UInt16
                if nameIndex < nameBytes.count {
                    expected = UInt16(nameBytes[nameIndex])
                } else if nameIndex == nameBytes.count {
                    expected = 0
                } else {
                    expected = 0xffff
                }
                if readLE16(
                    bytes,
                    at: offset + longNameUnitOffset(index)
                ) != expected {
                    return false
                }
                index += 1
            }
            return true
        }
    }

    private static func longNameUnitOffset(_ index: Int) -> Int {
        switch index {
        case 0: return 1
        case 1: return 3
        case 2: return 5
        case 3: return 7
        case 4: return 9
        case 5: return 14
        case 6: return 16
        case 7: return 18
        case 8: return 20
        case 9: return 22
        case 10: return 24
        case 11: return 28
        default: return 30
        }
    }

    private static func longNameChecksum(_ shortName: StaticString) -> UInt8 {
        shortName.withUTF8Buffer { bytes in
            var checksum: UInt8 = 0
            var index = 0
            while index < bytes.count {
                checksum = (checksum >> 1) | ((checksum & 1) << 7)
                checksum &+= bytes[index]
                index += 1
            }
            return checksum
        }
    }

    private static func validRootEntry(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int,
        name: StaticString,
        firstCluster: UInt64,
        byteCount: UInt32,
        attributes: UInt8
    ) -> Bool {
        guard firstCluster <= UInt64(UInt16.max) else { return false }
        return matches(bytes, at: offset, expected: name)
            && bytes[offset + 11] == attributes
            && allZero(bytes, from: offset + 12, to: offset + 16)
            && readLE16(bytes, at: offset + 16) == 0x0021
            && readLE16(bytes, at: offset + 18) == 0x0021
            && readLE16(bytes, at: offset + 20) == 0
            && readLE16(bytes, at: offset + 22) == 0
            && readLE16(bytes, at: offset + 24) == 0x0021
            && readLE16(bytes, at: offset + 26) == UInt16(firstCluster)
            && readLE32(bytes, at: offset + 28) == byteCount
    }

    private static func validateRescuePayload<Device: BlockDevice>(
        on device: inout Device,
        scratch: UnsafeMutableRawBufferPointer,
        layout: RescueLayout
    ) -> RaspberryPiABSelectorFailure? {
        var index = 0
        while let file = layout.descriptor(at: index) {
            var hash = USBKernelUpdateSHA256()
            var remaining = file.byteCount
            var cluster = file.firstCluster
            while cluster <= file.lastCluster {
                let block = autobootDataBlock + cluster - 2
                if let failure = read(&device, block: block, into: scratch) {
                    return failure
                }
                let count = remaining < 512 ? Int(remaining) : 512
                guard let base = scratch.baseAddress,
                      hash.update(UnsafeRawBufferPointer(
                          start: base,
                          count: count
                      )), allZero(scratch, from: count, to: scratch.count)
                        || count == scratch.count
                else { return .corruptRescuePayload }
                remaining -= UInt64(count)
                cluster += 1
            }
            guard remaining == 0, hash.finalizedDigest() == file.digest else {
                return .corruptRescuePayload
            }
            index += 1
        }
        // The builder keeps every unallocated selector cluster zero. Scan it
        // too so selector-write authority cannot be gained from a volume whose
        // declared rescue files are intact but whose supposedly immutable free
        // area carries untracked bytes.
        var cluster = layout.dwc2Overlay.lastCluster + 1
        while cluster <= 2_033 {
            let block = autobootDataBlock + cluster - 2
            if let failure = read(&device, block: block, into: scratch) {
                return failure
            }
            guard allZero(scratch) else { return .corruptRescuePayload }
            cluster += 1
        }
        return nil
    }

    private static func matchesPolicy(
        _ bytes: UnsafeMutableRawBufferPointer,
        expected: StaticString
    ) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            guard expectedBytes.count <= bytes.count else { return false }
            var index = 0
            while index < expectedBytes.count {
                if bytes[index] != expectedBytes[index] { return false }
                index += 1
            }
            while index < bytes.count {
                if bytes[index] != 0 { return false }
                index += 1
            }
            return true
        }
    }

    private static func buffersEqual(
        _ first: UnsafeMutableRawBufferPointer,
        _ second: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard first.count == second.count else { return false }
        var index = 0
        while index < first.count {
            if first[index] != second[index] { return false }
            index += 1
        }
        return true
    }

    private static func allZero(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        allZero(bytes, from: 0, to: bytes.count)
    }

    private static func allZero(
        _ bytes: UnsafeMutableRawBufferPointer,
        from start: Int,
        to end: Int
    ) -> Bool {
        guard start >= 0, end >= start, end <= bytes.count else { return false }
        var index = start
        while index < end {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private static func matches(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int,
        expected: StaticString
    ) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            guard offset >= 0, expectedBytes.count <= bytes.count - offset
            else { return false }
            var index = 0
            while index < expectedBytes.count {
                if bytes[offset + index] != expectedBytes[index] { return false }
                index += 1
            }
            return true
        }
    }

    private static func readLE16(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readLE32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(readLE16(bytes, at: offset))
            | UInt32(readLE16(bytes, at: offset + 2)) << 16
    }
}
