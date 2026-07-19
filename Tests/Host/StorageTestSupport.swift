final class MemoryBlockDevice: BlockDevice {
    let geometry: BlockDeviceGeometry
    var bytes: [UInt8]
    var failReads = false
    var failWrites = false
    var failSynchronization = false

    init(blockCount: UInt64, blockByteCount: Int = 512) {
        geometry = BlockDeviceGeometry(
            logicalBlockByteCount: blockByteCount,
            logicalBlockCount: blockCount
        )!
        bytes = [UInt8](
            repeating: 0,
            count: Int(blockCount) * blockByteCount
        )
    }

    func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard !failReads else { return .transportFailure }
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard output.count >= geometry.logicalBlockByteCount,
              let destination = output.baseAddress
        else { return .invalidBuffer }
        let offset = Int(logicalBlock) * geometry.logicalBlockByteCount
        bytes.withUnsafeBytes { source in
            destination.copyMemory(
                from: source.baseAddress!.advanced(by: offset),
                byteCount: geometry.logicalBlockByteCount
            )
        }
        return .success
    }

    func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard !failWrites else { return .transportFailure }
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard input.count >= geometry.logicalBlockByteCount,
              let source = input.baseAddress
        else { return .invalidBuffer }
        let offset = Int(logicalBlock) * geometry.logicalBlockByteCount
        bytes.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: offset).copyMemory(
                from: source,
                byteCount: geometry.logicalBlockByteCount
            )
        }
        return .success
    }

    func synchronize() -> BlockDeviceIOResult {
        failSynchronization ? .transportFailure : .success
    }
}
