@main
struct DWC2ControllerModelTests {
    static func main() {
        validatesRegisterGeometry()
        validatesCoreIdentityAndCapabilities()
        rejectsHostOnlyAndUndersizedControllers()
        buildsBoundedCompositeFIFOPlans()
        parsesReceiveStatusEntries()
        validatesTransferSizeEncoding()
        print("DWC2 controller model: 6 groups passed")
    }

    private static func validatesRegisterGeometry() {
        expect(
            DWC2RegisterLayout.inEndpointControl(3) == 0x960,
            "wrong IN endpoint control offset"
        )
        expect(
            DWC2RegisterLayout.outEndpointTransferSize(3) == 0xb70,
            "wrong OUT endpoint transfer-size offset"
        )
        expect(
            DWC2RegisterLayout.transmitFIFOSize(for: 3) == 0x10c,
            "wrong transmit FIFO-size offset"
        )
        expect(
            DWC2RegisterLayout.fifoData(3) == 0x4000,
            "wrong FIFO data aperture"
        )
        expect(
            DWC2RegisterLayout.inEndpointControl(16) == nil
                && DWC2RegisterLayout.fifoData(16) == nil,
            "out-of-range endpoint accepted"
        )
    }

    private static func validatesCoreIdentityAndCapabilities() {
        guard let identifier = DWC2CoreIdentifier(rawValue: 0x4f54_280a) else {
            fail("valid DWC2 identity rejected")
        }
        expect(identifier.revision == 0x280a, "revision was not preserved")
        expect(
            DWC2CoreIdentifier(rawValue: 0x1234_280a) == nil,
            "foreign controller identity accepted"
        )

        let configuration2: UInt32 = 2
            | (2 << 3)
            | (1 << 6)
            | (7 << 10)
            | (1 << 19)
        let configuration3: UInt32 = 4_080 << 16
        let configuration4: UInt32 = (7 << 26) | (1 << 25)
        guard let capabilities = DWC2HardwareCapabilities(
                  hardwareConfiguration2: configuration2,
                  hardwareConfiguration3: configuration3,
                  hardwareConfiguration4: configuration4
              )
        else {
            fail("device-capable controller rejected")
        }
        expect(capabilities.deviceEndpointCount == 8, "wrong endpoint count")
        expect(capabilities.inEndpointCount == 8, "wrong IN endpoint count")
        expect(capabilities.fifoDepthInWords == 4_080, "wrong FIFO depth")
        expect(
            capabilities.busArchitecture == .internalDMA,
            "wrong bus architecture"
        )
        expect(
            capabilities.highSpeedPHYType == .utmi
                && capabilities.utmiDataWidth == .bits8,
            "UTMI capabilities were not decoded"
        )
        expect(
            capabilities.supportsSwiftOSDebugCompositeDevice,
            "capable composite controller rejected"
        )
    }

    private static func rejectsHostOnlyAndUndersizedControllers() {
        let hostOnly: UInt32 = 6 | (1 << 6) | (7 << 10) | (1 << 19)
        expect(
            DWC2HardwareCapabilities(
                hardwareConfiguration2: hostOnly,
                hardwareConfiguration3: 4_080 << 16,
                hardwareConfiguration4: (7 << 26) | (1 << 25)
            ) == nil,
            "host-only controller accepted"
        )

        guard let small = DWC2HardwareCapabilities(
                  hardwareConfiguration2: 4 | (1 << 6)
                      | (2 << 10) | (1 << 19),
                  hardwareConfiguration3: 512 << 16,
                  hardwareConfiguration4: (2 << 26) | (1 << 25)
              )
        else {
            fail("small device controller could not be described")
        }
        expect(
            !small.supportsSwiftOSDebugCompositeDevice,
            "undersized endpoint set accepted"
        )
        guard let ulpiOnly = DWC2HardwareCapabilities(
                  hardwareConfiguration2: 4 | (2 << 6)
                      | (7 << 10) | (1 << 19),
                  hardwareConfiguration3: 4_080 << 16,
                  hardwareConfiguration4: (7 << 26) | (1 << 25)
              )
        else { fail("ULPI-only capabilities were not decoded") }
        expect(
            !ulpiOnly.supportsSwiftOSDebugCompositeDevice,
            "ULPI-only core entered the UTMI initialization path"
        )
        expect(
            DWC2CompositeFIFOPlan(availableDepthInWords: 591) == nil,
            "undersized FIFO accepted"
        )
    }

    private static func buildsBoundedCompositeFIFOPlans() {
        guard let compact = DWC2CompositeFIFOPlan(
                  availableDepthInWords: 592
              ), let preferred = DWC2CompositeFIFOPlan(
                  availableDepthInWords: 4_080
              )
        else {
            fail("valid FIFO plan rejected")
        }
        expect(compact.receiveDepthInWords == 256, "wrong compact RX FIFO")
        expect(
            compact.debugDisplayTransmit.depthInWords == 128,
            "compact display FIFO lost its minimum burst"
        )
        expect(compact.consumedDepthInWords == 592, "compact plan overflow")
        expect(preferred.receiveDepthInWords == 512, "wrong preferred RX FIFO")
        expect(
            preferred.debugDisplayTransmit.depthInWords == 1_024,
            "preferred display FIFO was not capped"
        )
        expect(
            preferred.transmitRegion(for: 0)?.startWord == 512
                && preferred.transmitRegion(for: 3)?.startWord == 720,
            "FIFO regions are not contiguous"
        )
        expect(
            preferred.consumedDepthInWords <= 4_080,
            "FIFO plan exceeded hardware depth"
        )
    }

    private static func parsesReceiveStatusEntries() {
        let setupRaw: UInt32 = 8 << 4 | 2 << 15 | 6 << 17 | 12 << 25
        guard let setup = DWC2ReceiveStatus(rawValue: setupRaw) else {
            fail("valid setup receive status rejected")
        }
        expect(setup.endpoint == 0, "setup endpoint changed")
        expect(setup.byteCount == 8, "setup byte count changed")
        expect(setup.dataPID == 2, "setup PID changed")
        expect(setup.frameNumber == 12, "frame number changed")
        expect(setup.packetStatus == .setupDataReceived, "wrong setup status")

        let outRaw: UInt32 = 3 | 512 << 4 | 2 << 17
        expect(
            DWC2ReceiveStatus(rawValue: outRaw)?.byteCount == 512,
            "bulk OUT status rejected"
        )
        expect(
            DWC2ReceiveStatus(rawValue: setupRaw | 1) == nil,
            "setup packet on a nonzero endpoint accepted"
        )
        expect(
            DWC2ReceiveStatus(rawValue: 7 << 17) == nil,
            "host-mode packet status accepted"
        )
        expect(
            DWC2ReceiveStatus(rawValue: outRaw, maximumEndpointNumber: 2) == nil,
            "endpoint beyond configured hardware accepted"
        )
    }

    private static func validatesTransferSizeEncoding() {
        let available = DWC2NonPeriodicTransmitStatus(
            rawValue: 2 << 16 | 16
        )
        expect(
            available.fifoAvailableWords == 16
                && available.requestQueueAvailableEntries == 2
                && available.canQueue(wordCount: 16),
            "non-periodic transmit availability decoded incorrectly"
        )
        expect(
            !DWC2NonPeriodicTransmitStatus(rawValue: 16)
                .canQueue(wordCount: 1),
            "empty non-periodic request queue accepted"
        )
        expect(
            DWC2TransferSize.endpoint0SetupReception
                == (3 << 29 | 1 << 19 | 24),
            "EP0 setup window did not reserve three eight-byte packets"
        )
        expect(
            DWC2TransferSize.endpoint0In(byteCount: 64) == (1 << 19 | 64),
            "EP0 IN size encoded incorrectly"
        )
        expect(
            DWC2TransferSize.endpoint0Out(byteCount: 65) == nil,
            "oversized EP0 OUT transfer accepted"
        )
        expect(
            DWC2TransferSize.bulk(byteCount: 513, maximumPacketSize: 512)
                == (2 << 19 | 513),
            "bulk packet count encoded incorrectly"
        )
        expect(
            DWC2TransferSize.bulk(byteCount: 0, maximumPacketSize: 512) == nil,
            "empty bulk transfer accepted"
        )
        expect(
            DWC2TransferSize.bulk(
                byteCount: 0x8_0000,
                maximumPacketSize: 512
            ) == nil,
            "oversized hardware transfer accepted"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
