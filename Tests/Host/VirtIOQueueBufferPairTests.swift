@main
struct VirtIOQueueBufferPairTests {
    static func main() {
        acceptsDisjointLargeMappings()
        rejectsShortAndNoncoherentMappings()
        rejectsCPUAndDeviceAliases()
        protectsSplitQueueMetadata()
        print("VirtIO external queue buffers: 4 groups passed")
    }

    private static func acceptsDisjointLargeMappings() {
        let pair = VirtIOQueueBufferPair(
            request: mapping(cpu: 0x20_0000, device: 0x120_0000, bytes: 0x8000),
            requestByteCount: 24_000,
            response: mapping(cpu: 0x30_0000, device: 0x130_0000, bytes: 0x4000),
            responseCapacity: 12_000,
            protectedQueueMapping: queueMapping()
        )
        require(pair?.requestByteCount == 24_000, "large request was rejected")
        require(pair?.responseCapacity == 12_000, "response capacity changed")

        let topOfAddressSpace = VirtIOQueueBufferPair(
            request: mapping(
                cpu: 0x40_0000,
                device: UInt64.max - 0xff,
                bytes: 0x100
            ),
            requestByteCount: 0x100,
            response: mapping(
                cpu: 0x50_0000,
                device: 0x150_0000,
                bytes: 0x100
            ),
            responseCapacity: 0x100,
            protectedQueueMapping: queueMapping()
        )
        require(
            topOfAddressSpace != nil,
            "mapping ending at UInt64.max overflowed validation"
        )
    }

    private static func rejectsShortAndNoncoherentMappings() {
        require(
            VirtIOQueueBufferPair(
                request: mapping(cpu: 0x20_0000, device: 0x20_0000, bytes: 64),
                requestByteCount: 65,
                response: mapping(cpu: 0x30_0000, device: 0x30_0000, bytes: 64),
                responseCapacity: 24,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "short request mapping was accepted"
        )
        require(
            VirtIOQueueBufferPair(
                request: mapping(
                    cpu: 0x20_0000,
                    device: 0x20_0000,
                    bytes: 64,
                    coherency: .softwareManaged
                ),
                requestByteCount: 32,
                response: mapping(cpu: 0x30_0000, device: 0x30_0000, bytes: 64),
                responseCapacity: 24,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "noncoherent request was accepted without cache lifecycle"
        )
    }

    private static func rejectsCPUAndDeviceAliases() {
        require(
            VirtIOQueueBufferPair(
                request: mapping(cpu: 0x20_0000, device: 0x40_0000, bytes: 0x1000),
                requestByteCount: 0x100,
                response: mapping(cpu: 0x20_0080, device: 0x50_0000, bytes: 0x1000),
                responseCapacity: 0x100,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "CPU-overlapping request and response were accepted"
        )
        require(
            VirtIOQueueBufferPair(
                request: mapping(cpu: 0x20_0000, device: 0x60_0000, bytes: 0x1000),
                requestByteCount: 0x100,
                response: mapping(cpu: 0x30_0000, device: 0x60_0080, bytes: 0x1000),
                responseCapacity: 0x100,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "device-overlapping request and response were accepted"
        )
    }

    private static func protectsSplitQueueMetadata() {
        require(
            VirtIOQueueBufferPair(
                request: mapping(cpu: 0x10_0800, device: 0x110_0800, bytes: 0x1000),
                requestByteCount: 0x100,
                response: mapping(cpu: 0x30_0000, device: 0x130_0000, bytes: 0x1000),
                responseCapacity: 0x100,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "CPU alias with queue metadata was accepted"
        )
        require(
            VirtIOQueueBufferPair(
                request: mapping(cpu: 0x20_0000, device: 0x110_0800, bytes: 0x1000),
                requestByteCount: 0x100,
                response: mapping(cpu: 0x30_0000, device: 0x130_0000, bytes: 0x1000),
                responseCapacity: 0x100,
                protectedQueueMapping: queueMapping()
            ) == nil,
            "device alias with queue metadata was accepted"
        )
    }

    private static func queueMapping() -> DMAMapping {
        mapping(cpu: 0x10_0000, device: 0x110_0000, bytes: 0x1000)
    }

    private static func mapping(
        cpu: UInt64,
        device: UInt64,
        bytes: UInt64,
        coherency: DMACoherency = .hardwareCoherent
    ) -> DMAMapping {
        guard let result = DMAMapping(
            cpuPhysicalAddress: cpu,
            deviceAddress: device,
            byteCount: bytes,
            deviceAddressWidth: .bits64,
            coherency: coherency
        ) else {
            fatalError("invalid DMA fixture")
        }
        return result
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fatalError("\(message)") }
    }
}
