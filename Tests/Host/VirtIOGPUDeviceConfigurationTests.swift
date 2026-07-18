@main
struct VirtIOGPUDeviceConfigurationTests {
    static func main() {
        acceptsTheSpecifiedConfigurationBounds()
        rejectsImpossibleScanoutCounts()
        preservesEventsAndCapsetDiscovery()
        print("VirtIO-GPU device configuration: 3 groups passed")
    }

    private static func acceptsTheSpecifiedConfigurationBounds() {
        let minimum = VirtIOGPUDeviceConfiguration(
            pendingEvents: 0,
            scanoutCount: 1,
            capsetCount: 0
        )
        expect(minimum?.scanoutCount == 1, "minimum scanout count")
        expect(minimum?.capsetCount == 0, "2D-only configuration")

        let maximum = VirtIOGPUDeviceConfiguration(
            pendingEvents: 0,
            scanoutCount: 16,
            capsetCount: UInt32.max
        )
        expect(maximum?.scanoutCount == 16, "maximum scanout count")
        expect(maximum?.capsetCount == UInt32.max, "capset count was truncated")
    }

    private static func rejectsImpossibleScanoutCounts() {
        expect(
            VirtIOGPUDeviceConfiguration(
                pendingEvents: 0,
                scanoutCount: 0,
                capsetCount: 0
            ) == nil,
            "zero scanouts accepted"
        )
        expect(
            VirtIOGPUDeviceConfiguration(
                pendingEvents: 0,
                scanoutCount: 17,
                capsetCount: 0
            ) == nil,
            "more than sixteen scanouts accepted"
        )
    }

    private static func preservesEventsAndCapsetDiscovery() {
        let configuration = VirtIOGPUDeviceConfiguration(
            pendingEvents: VirtIOGPUDeviceConfiguration.displayEvent
                | 0x8000_0000,
            scanoutCount: 2,
            capsetCount: 3
        )
        expect(configuration?.displayConfigurationChanged == true, "display event")
        expect(
            configuration?.pendingEvents == 0x8000_0001,
            "future event bits were discarded"
        )
        expect(configuration?.capsetCount == 3, "capset discovery count")
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: StaticString
) {
    if !condition() { fatalError("\(message)") }
}
