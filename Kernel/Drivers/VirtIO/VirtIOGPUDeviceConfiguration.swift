struct VirtIOGPUDeviceConfiguration: Equatable {
    static let maximumScanoutCount: UInt32 = 16
    static let displayEvent: UInt32 = 1 << 0

    let pendingEvents: UInt32
    let scanoutCount: UInt32
    let capsetCount: UInt32

    init?(
        pendingEvents: UInt32,
        scanoutCount: UInt32,
        capsetCount: UInt32
    ) {
        guard scanoutCount > 0,
              scanoutCount <= Self.maximumScanoutCount
        else {
            return nil
        }
        self.pendingEvents = pendingEvents
        self.scanoutCount = scanoutCount
        self.capsetCount = capsetCount
    }

    var displayConfigurationChanged: Bool {
        pendingEvents & Self.displayEvent != 0
    }
}

enum VirtIOGPUDeviceConfigurationReadResult: Equatable {
    case ready(VirtIOGPUDeviceConfiguration)
    case invalidAttemptLimit
    case wrongDevice
    case invalidConfiguration
    case unstable
}
