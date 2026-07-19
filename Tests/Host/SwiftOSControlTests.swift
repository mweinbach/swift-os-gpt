@main
struct SwiftOSControlTests {
    static func main() {
        classifiesAbsentDevice()
        classifiesEnumeratedDeviceWithoutTTY()
        classifiesReadyDeviceAndFiltersForeignUSB()
        classifiesAmbiguousControlEndpoints()
        validatesInjectedProvider()
        print("SwiftOS control discovery: 5 groups passed")
    }

    private static func classifiesAbsentDevice() {
        let report = SwiftOSDoctor.report(
            from: SwiftOSHostSnapshot(usbDevices: [], cdcTTYPaths: [])
        )
        expect(report.stage == .absent, "empty snapshot was not absent")
        expect(!report.ready, "absent device was ready")
        expect(report.expectedVendorID == "0x1209", "VID changed")
        expect(report.expectedProductID == "0x5a17", "PID changed")
    }

    private static func classifiesEnumeratedDeviceWithoutTTY() {
        let report = SwiftOSDoctor.report(
            from: SwiftOSHostSnapshot(
                usbDevices: [device(id: 1)],
                cdcTTYPaths: []
            )
        )
        expect(report.stage == .noTTY, "missing tty was misclassified")
        expect(report.devices.count == 1, "matching device disappeared")
    }

    private static func classifiesReadyDeviceAndFiltersForeignUSB() {
        let path = "/dev/cu.usbmodem-SWIFTOS1"
        let foreign = SwiftOSUSBDevice(
            registryID: 90,
            vendorID: 0x1234,
            productID: 0xabcd,
            productName: "Foreign device",
            serialNumber: nil,
            ttyPaths: ["/dev/cu.usbmodem-FOREIGN"]
        )
        let report = SwiftOSDoctor.report(
            from: SwiftOSHostSnapshot(
                usbDevices: [foreign, device(id: 2, ttyPaths: [path])],
                cdcTTYPaths: ["/dev/cu.usbmodem-FOREIGN", path]
            )
        )
        expect(report.stage == .ready, "single exact device was not ready")
        expect(report.ready, "ready flag was false")
        expect(report.devices.count == 1, "foreign VID/PID was included")
        expect(report.devices[0].ttyPaths == [path], "tty association changed")
    }

    private static func classifiesAmbiguousControlEndpoints() {
        let report = SwiftOSDoctor.report(
            from: SwiftOSHostSnapshot(
                usbDevices: [
                    device(id: 1, ttyPaths: ["/dev/cu.usbmodem-A"]),
                    device(id: 2, ttyPaths: ["/dev/cu.usbmodem-B"])
                ],
                cdcTTYPaths: [
                    "/dev/cu.usbmodem-A",
                    "/dev/cu.usbmodem-B"
                ]
            )
        )
        expect(report.stage == .enumerated, "ambiguity was not reported")
        expect(!report.ready, "ambiguous devices were ready")
    }

    private static func validatesInjectedProvider() {
        let provider = FixtureProvider(
            value: SwiftOSHostSnapshot(
                usbDevices: [
                    device(
                        id: 42,
                        ttyPaths: ["/dev/cu.usbmodem-SWIFTOS42"]
                    )
                ],
                cdcTTYPaths: ["/dev/cu.usbmodem-SWIFTOS42"]
            )
        )
        let report: SwiftOSDoctorReport
        do {
            report = SwiftOSDoctor.report(from: try provider.snapshot())
        } catch {
            fail("fixture provider failed: \(error)")
        }
        expect(report.devices[0].serialNumber == "swiftos-42",
               "injected snapshot serial changed")
    }

    private static func device(
        id: UInt64,
        ttyPaths: [String] = []
    ) -> SwiftOSUSBDevice {
        SwiftOSUSBDevice(
            registryID: id,
            vendorID: SwiftOSUSBIdentity.vendorID,
            productID: SwiftOSUSBIdentity.productID,
            productName: "SwiftOS Debug",
            serialNumber: "swiftos-\(id)",
            ttyPaths: ttyPaths
        )
    }

    private struct FixtureProvider: SwiftOSDiscoveryProvider {
        let value: SwiftOSHostSnapshot

        func snapshot() throws -> SwiftOSHostSnapshot { value }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("SwiftOSControlTests: \(message)")
    }
}
