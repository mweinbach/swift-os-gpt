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
    case malformedAllocationTables
    case malformedRootDirectory
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
    case failure(RaspberryPiABSelectorFailure)
}

/// Strict writer for the deterministic selector produced by the host media
/// builder. It has authority over one 512-byte file cluster only; no MBR, FAT,
/// directory, payload-slot, log, or SwiftFS write is expressible here.
enum RaspberryPiABSelector {
    static let partitionBlockCount: UInt64 = 2_047
    static let autobootDataBlock: UInt64 = 15

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

        if let failure = read(&device, block: 0, into: first) {
            return .failure(failure)
        }
        guard validBootSector(first) else {
            return .failure(.malformedBootSector)
        }

        var fatBlock: UInt64 = 0
        while fatBlock < 6 {
            let primary = 1 + fatBlock
            let backup = 7 + fatBlock
            if let failure = read(&device, block: primary, into: first) {
                return .failure(failure)
            }
            if let failure = read(&device, block: backup, into: second) {
                return .failure(failure)
            }
            guard buffersEqual(first, second),
                  validAllocationBlock(first, index: fatBlock)
            else { return .failure(.malformedAllocationTables) }
            fatBlock += 1
        }

        if let failure = read(&device, block: 13, into: first) {
            return .failure(failure)
        }
        guard validRootDirectory(first) else {
            return .failure(.malformedRootDirectory)
        }
        if let failure = read(&device, block: 14, into: first) {
            return .failure(failure)
        }
        guard allZero(first) else {
            return .failure(.malformedRootDirectory)
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
        switch inspect(&device, scratch: scratch) {
        case .state(let current) where current == desired:
            return .unchanged(current)
        case .state:
            break
        case .failure(let failure):
            return .failure(failure)
        }
        guard scratch.count >= 1_024, let base = scratch.baseAddress else {
            return .failure(.invalidScratch)
        }
        let block = UnsafeMutableRawBufferPointer(start: base, count: 512)
        var index = 0
        while index < block.count {
            block[index] = 0
            index += 1
        }
        let expected = defaultSlot == .a ? selectorA : selectorB
        expected.withUTF8Buffer { bytes in
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
        guard write == .success else { return .failure(.write(write)) }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .failure(.synchronize(synchronized))
        }
        let readback = device.readBlock(at: autobootDataBlock, into: block)
        guard readback == .success else {
            return .failure(.readback(readback))
        }
        guard matchesPolicy(block, expected: expected) else {
            return .failure(.readbackMismatch)
        }
        return .committed(desired)
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
        bytes[510] == 0x55 && bytes[511] == 0xaa
            && readLE16(bytes, at: 11) == 512
            && bytes[13] == 1
            && readLE16(bytes, at: 14) == 1
            && bytes[16] == 2
            && readLE16(bytes, at: 17) == 32
            && readLE16(bytes, at: 19) == 2_047
            && bytes[21] == 0xf8
            && readLE16(bytes, at: 22) == 6
            && readLE32(bytes, at: 28) == 1
            && matches(bytes, at: 43, expected: "SWIFTOS-CTL")
            && matches(bytes, at: 54, expected: "FAT12   ")
    }

    private static func validAllocationBlock(
        _ bytes: UnsafeMutableRawBufferPointer,
        index: UInt64
    ) -> Bool {
        var byte = 0
        if index == 0 {
            guard bytes[0] == 0xf8,
                  bytes[1] == 0xff,
                  bytes[2] == 0xff,
                  bytes[3] == 0xff,
                  bytes[4] == 0x0f
            else { return false }
            byte = 5
        }
        while byte < bytes.count {
            if bytes[byte] != 0 { return false }
            byte += 1
        }
        return true
    }

    private static func validRootDirectory(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard matches(bytes, at: 0, expected: "AUTOBOOTTXT"),
              bytes[11] == 0x20,
              readLE16(bytes, at: 26) == 2,
              readLE32(bytes, at: 28) == UInt32(selectorA.utf8CodeUnitCount),
              selectorA.utf8CodeUnitCount == selectorB.utf8CodeUnitCount
        else { return false }
        var index = 32
        while index < bytes.count {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
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
        var index = 0
        while index < bytes.count {
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
