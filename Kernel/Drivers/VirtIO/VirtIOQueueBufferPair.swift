/// Validated external request/response buffers for one polling VirtIO queue
/// transaction. The transport keeps its split-ring metadata in a protected
/// mapping; larger GPU command streams and capsets use allocator-owned DMA
/// mappings which must not alias that metadata or each other.
struct VirtIOQueueBufferPair: Equatable {
    let request: DMAMapping
    let requestByteCount: UInt32
    let response: DMAMapping
    let responseCapacity: UInt32

    init?(
        request: DMAMapping,
        requestByteCount: UInt32,
        response: DMAMapping,
        responseCapacity: UInt32,
        protectedQueueMapping: DMAMapping
    ) {
        guard request.coherency == .hardwareCoherent,
              response.coherency == .hardwareCoherent,
              protectedQueueMapping.coherency == .hardwareCoherent,
              requestByteCount > 0,
              responseCapacity >= 24,
              UInt64(requestByteCount) <= request.byteCount,
              UInt64(responseCapacity) <= response.byteCount,
              request.cpuPhysicalAddress <= UInt64(UInt.max),
              response.cpuPhysicalAddress <= UInt64(UInt.max),
              !Self.overlap(
                  request.cpuPhysicalAddress,
                  UInt64(requestByteCount),
                  response.cpuPhysicalAddress,
                  UInt64(responseCapacity)
              ),
              !Self.overlap(
                  request.deviceAddress,
                  UInt64(requestByteCount),
                  response.deviceAddress,
                  UInt64(responseCapacity)
              ),
              !Self.overlap(
                  request.cpuPhysicalAddress,
                  UInt64(requestByteCount),
                  protectedQueueMapping.cpuPhysicalAddress,
                  protectedQueueMapping.byteCount
              ),
              !Self.overlap(
                  response.cpuPhysicalAddress,
                  UInt64(responseCapacity),
                  protectedQueueMapping.cpuPhysicalAddress,
                  protectedQueueMapping.byteCount
              ),
              !Self.overlap(
                  request.deviceAddress,
                  UInt64(requestByteCount),
                  protectedQueueMapping.deviceAddress,
                  protectedQueueMapping.byteCount
              ),
              !Self.overlap(
                  response.deviceAddress,
                  UInt64(responseCapacity),
                  protectedQueueMapping.deviceAddress,
                  protectedQueueMapping.byteCount
              )
        else {
            return nil
        }
        self.request = request
        self.requestByteCount = requestByteCount
        self.response = response
        self.responseCapacity = responseCapacity
    }

    private static func overlap(
        _ firstAddress: UInt64,
        _ firstByteCount: UInt64,
        _ secondAddress: UInt64,
        _ secondByteCount: UInt64
    ) -> Bool {
        guard firstByteCount > 0, secondByteCount > 0 else { return false }
        // DMAMapping validation guarantees these inclusive endpoints cannot
        // overflow, including a legal range whose last byte is UInt64.max.
        let firstLast = firstAddress + (firstByteCount - 1)
        let secondLast = secondAddress + (secondByteCount - 1)
        return firstAddress <= secondLast && secondAddress <= firstLast
    }
}
