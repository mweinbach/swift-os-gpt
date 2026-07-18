// This host test deliberately omits the volatile-MMIO transport. These small
// shims let the production VirtIO-GPU protocol and validation code compile as
// a host executable without changing the guest implementation.
enum VirtIOMMIORequestResult: Equatable {
    case completed(responseByteCount: UInt32)
    case invalidRequest
    case timedOut
    case malformedCompletion
    case deviceNeedsReset
}

struct VirtIOMMIOTransport {
    var requestAddress: UInt64 = 0
    var responseAddress: UInt64 = 0

    mutating func prepareBuffers() -> Bool { false }

    mutating func submit(
        requestByteCount: UInt32,
        responseCapacity: UInt32
    ) -> VirtIOMMIORequestResult {
        _ = requestByteCount
        _ = responseCapacity
        return .invalidRequest
    }

    mutating func failDevice() {}
}

enum AArch64 {
    static func synchronizeData() {}
}

@main
struct VirtIOGPUProtocolTests {
    static func main() {
        testControlHeaderEncoding()
        testRectangleEncoding()
        testFencedResponseValidation()
        testDisplayInfoScanoutSelection()
        testDMAAndScanoutBoundaries()
        testDriverScanoutRequirements()
        print("VirtIO-GPU protocol host tests: 6 groups passed")
    }

    private static func testControlHeaderEncoding() {
        withBuffer(byteCount: 64, alignment: 64) { address in
            fill(address: address, byteCount: 64, value: 0xa5)
            VirtIOGPUProtocol.writeHeader(
                type: 0x0102_0304,
                fenceID: 0x1122_3344_5566_7788,
                at: address
            )

            expectBytes(
                at: address,
                equalTo: [
                    0x04, 0x03, 0x02, 0x01,
                    0x01, 0x00, 0x00, 0x00,
                    0x88, 0x77, 0x66, 0x55,
                    0x44, 0x33, 0x22, 0x11,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ],
                "control header little-endian layout"
            )
            expect(
                PhysicalBytes.read8(at: address + 24) == 0xa5,
                "control header overwrote the following byte"
            )
        }
    }

    private static func testRectangleEncoding() {
        withBuffer(byteCount: 32, alignment: 16) { address in
            fill(address: address, byteCount: 32, value: 0xcc)
            VirtIOGPUProtocol.writeRectangle(
                VirtIOGPURectangle(
                    x: 0x0102_0304,
                    y: 0x1112_1314,
                    width: 0x2122_2324,
                    height: 0x3132_3334
                ),
                at: address
            )

            expectBytes(
                at: address,
                equalTo: [
                    0x04, 0x03, 0x02, 0x01,
                    0x14, 0x13, 0x12, 0x11,
                    0x24, 0x23, 0x22, 0x21,
                    0x34, 0x33, 0x32, 0x31,
                ],
                "rectangle little-endian layout"
            )
            expect(
                PhysicalBytes.read8(at: address + 16) == 0xcc,
                "rectangle overwrote the following byte"
            )
        }
    }

    private static func testFencedResponseValidation() {
        withBuffer(byteCount: 64, alignment: 64) { address in
            let expectedType = VirtIOGPUControlType.responseOKDisplayInfo
            let expectedFence: UInt64 = 0xfedc_ba98_7654_3210

            writeResponseHeader(
                type: expectedType,
                flags: VirtIOGPUProtocol.fenceFlag | 0x8000_0000,
                fenceID: expectedFence,
                at: address
            )
            expect(
                VirtIOGPUProtocol.responseIsValid(
                    at: address,
                    byteCount: VirtIOGPUProtocol.controlHeaderByteCount,
                    expectedType: expectedType,
                    fenceID: expectedFence
                ),
                "valid fenced response was rejected"
            )
            expect(
                !VirtIOGPUProtocol.responseIsValid(
                    at: address,
                    byteCount: VirtIOGPUProtocol.controlHeaderByteCount - 1,
                    expectedType: expectedType,
                    fenceID: expectedFence
                ),
                "truncated response was accepted"
            )
            expect(
                !VirtIOGPUProtocol.responseIsValid(
                    at: address,
                    byteCount: VirtIOGPUProtocol.controlHeaderByteCount,
                    expectedType: VirtIOGPUControlType.responseOKNoData,
                    fenceID: expectedFence
                ),
                "wrong response type was accepted"
            )

            PhysicalBytes.writeLE32(0x8000_0000, at: address + 4)
            expect(
                !VirtIOGPUProtocol.responseIsValid(
                    at: address,
                    byteCount: VirtIOGPUProtocol.controlHeaderByteCount,
                    expectedType: expectedType,
                    fenceID: expectedFence
                ),
                "response without the fence flag was accepted"
            )

            PhysicalBytes.writeLE32(VirtIOGPUProtocol.fenceFlag, at: address + 4)
            PhysicalBytes.writeLE64(expectedFence &+ 1, at: address + 8)
            expect(
                !VirtIOGPUProtocol.responseIsValid(
                    at: address,
                    byteCount: VirtIOGPUProtocol.controlHeaderByteCount,
                    expectedType: expectedType,
                    fenceID: expectedFence
                ),
                "response with the wrong fence ID was accepted"
            )
        }
    }

    private static func testDisplayInfoScanoutSelection() {
        withBuffer(
            byteCount: Int(VirtIOGPUProtocol.displayInfoResponseByteCount),
            alignment: 64
        ) { address in
            _ = PhysicalBytes.zero(
                address: address,
                byteCount: UInt64(VirtIOGPUProtocol.displayInfoResponseByteCount)
            )

            writeScanout(
                index: 0,
                width: 799,
                height: 600,
                enabled: true,
                at: address
            )
            writeScanout(
                index: 1,
                width: 1920,
                height: 1080,
                enabled: false,
                at: address
            )
            writeScanout(
                index: 2,
                width: 800,
                height: 600,
                enabled: true,
                at: address
            )
            writeScanout(
                index: 3,
                width: 3840,
                height: 2160,
                enabled: true,
                at: address
            )

            expect(
                VirtIOGPUProtocol.firstEnabledScanout(
                    responseAddress: address,
                    responseByteCount:
                        VirtIOGPUProtocol.displayInfoResponseByteCount,
                    minimumWidth: 800,
                    minimumHeight: 600
                ) == 2,
                "first qualifying enabled scanout was not selected"
            )
            expect(
                VirtIOGPUProtocol.firstEnabledScanout(
                    responseAddress: address,
                    responseByteCount:
                        VirtIOGPUProtocol.displayInfoResponseByteCount - 1,
                    minimumWidth: 1,
                    minimumHeight: 1
                ) == nil,
                "truncated display-info response was accepted"
            )
            expect(
                VirtIOGPUProtocol.firstEnabledScanout(
                    responseAddress: address,
                    responseByteCount:
                        VirtIOGPUProtocol.displayInfoResponseByteCount,
                    minimumWidth: 4096,
                    minimumHeight: 2160
                ) == nil,
                "undersized scanout satisfied the requested mode"
            )

            writeScanout(
                index: VirtIOGPUProtocol.maximumScanoutCount - 1,
                width: 4096,
                height: 2160,
                enabled: true,
                at: address
            )
            expect(
                VirtIOGPUProtocol.firstEnabledScanout(
                    responseAddress: address,
                    responseByteCount:
                        VirtIOGPUProtocol.displayInfoResponseByteCount,
                    minimumWidth: 4096,
                    minimumHeight: 2160
                ) == 15,
                "last protocol-defined scanout was not inspected"
            )
        }
    }

    private static func testDMAAndScanoutBoundaries() {
        let width = DMAAddressWidth.bits32
        expect(
            width.contains(address: 0xffff_f000, byteCount: 0x1000),
            "DMA range ending at the address-width limit was rejected"
        )
        expect(
            !width.contains(address: 0xffff_f000, byteCount: 0x1001),
            "DMA range crossing the address-width limit was accepted"
        )
        expect(
            !DMAAddressWidth.bits64.contains(
                address: UInt64.max,
                byteCount: 2
            ),
            "overflowing 64-bit DMA range was accepted"
        )

        let mode = requireMode(width: 800, height: 600)
        let exactByteCount = mode.minimumByteCount
        guard let exactMapping = DMAMapping(
            cpuPhysicalAddress: 0x1_4000_0000,
            deviceAddress: 0x4000_0000,
            byteCount: exactByteCount,
            deviceAddressWidth: .bits32,
            coherency: .hardwareCoherent
        ) else {
            fatalError("valid translated DMA boundary fixture was rejected")
        }
        expect(
            !exactMapping.isIdentityMapped,
            "translated DMA mapping lost its device address domain"
        )
        expect(
            ScanoutBuffer(
                mode: mode,
                bytesPerRow: mode.minimumBytesPerRow,
                mapping: exactMapping
            )?.requiredByteCount == exactByteCount,
            "exactly-sized scanout mapping was rejected"
        )

        guard let shortMapping = DMAMapping(
            cpuPhysicalAddress: 0x5000_0000,
            deviceAddress: 0x5000_0000,
            byteCount: exactByteCount - 1,
            deviceAddressWidth: .bits32,
            coherency: .hardwareCoherent
        ) else {
            fatalError("short DMA mapping fixture was rejected too early")
        }
        expect(
            ScanoutBuffer(
                mode: mode,
                bytesPerRow: mode.minimumBytesPerRow,
                mapping: shortMapping
            ) == nil,
            "scanout accepted a DMA mapping one byte too short"
        )
    }

    private static func testDriverScanoutRequirements() {
        let mode = requireMode(width: 800, height: 600)
        let byteCount = mode.minimumByteCount

        guard let coherentMapping = DMAMapping(
            cpuPhysicalAddress: 0x4800_0000,
            deviceAddress: 0x0800_0000,
            byteCount: byteCount,
            deviceAddressWidth: .bits32,
            coherency: .hardwareCoherent
        ),
        let coherentScanout = ScanoutBuffer(
            mode: mode,
            bytesPerRow: mode.minimumBytesPerRow,
            mapping: coherentMapping
        ) else {
            fatalError("valid coherent scanout fixture was rejected")
        }
        expect(
            VirtIOGPU(
                transport: VirtIOMMIOTransport(),
                scanout: coherentScanout
            ) != nil,
            "driver rejected a coherent translated scanout"
        )

        guard let managedMapping = DMAMapping(
            cpuPhysicalAddress: 0x4800_0000,
            deviceAddress: 0x0800_0000,
            byteCount: byteCount,
            deviceAddressWidth: .bits32,
            coherency: .softwareManaged
        ),
        let managedScanout = ScanoutBuffer(
            mode: mode,
            bytesPerRow: mode.minimumBytesPerRow,
            mapping: managedMapping
        ) else {
            fatalError("valid software-managed scanout fixture was rejected")
        }
        expect(
            VirtIOGPU(
                transport: VirtIOMMIOTransport(),
                scanout: managedScanout
            ) == nil,
            "driver accepted a scanout without a cache-maintenance path"
        )

        let largeMode = requireMode(width: 65_536, height: 16_384)
        guard let largeMapping = DMAMapping(
            cpuPhysicalAddress: 0x2_0000_0000,
            deviceAddress: 0x2_0000_0000,
            byteCount: largeMode.minimumByteCount,
            deviceAddressWidth: .bits64,
            coherency: .hardwareCoherent
        ),
        let largeScanout = ScanoutBuffer(
            mode: largeMode,
            bytesPerRow: largeMode.minimumBytesPerRow,
            mapping: largeMapping
        ) else {
            fatalError("valid large scanout fixture was rejected")
        }
        expect(
            largeScanout.requiredByteCount == UInt64(UInt32.max) + 1,
            "large scanout fixture did not cross the protocol size limit"
        )
        expect(
            VirtIOGPU(
                transport: VirtIOMMIOTransport(),
                scanout: largeScanout
            ) == nil,
            "driver accepted a backing length that cannot fit the protocol"
        )
    }

    private static func writeResponseHeader(
        type: UInt32,
        flags: UInt32,
        fenceID: UInt64,
        at address: UInt64
    ) {
        PhysicalBytes.writeLE32(type, at: address)
        PhysicalBytes.writeLE32(flags, at: address + 4)
        PhysicalBytes.writeLE64(fenceID, at: address + 8)
        PhysicalBytes.writeLE32(0, at: address + 16)
        PhysicalBytes.writeLE32(0, at: address + 20)
    }

    private static func writeScanout(
        index: Int,
        width: UInt32,
        height: UInt32,
        enabled: Bool,
        at responseAddress: UInt64
    ) {
        let mode = responseAddress
            + UInt64(VirtIOGPUProtocol.controlHeaderByteCount)
            + UInt64(index * 24)
        PhysicalBytes.writeLE32(width, at: mode + 8)
        PhysicalBytes.writeLE32(height, at: mode + 12)
        PhysicalBytes.writeLE32(enabled ? 1 : 0, at: mode + 16)
    }

    private static func requireMode(
        width: UInt32,
        height: UInt32
    ) -> DisplayMode {
        guard let mode = DisplayMode(
            widthInPixels: width,
            heightInPixels: height,
            refreshRateMilliHertz: 60_000,
            pixelFormat: .b8g8r8x8
        ) else {
            fatalError("valid display-mode fixture was rejected")
        }
        return mode
    }

    private static func withBuffer(
        byteCount: Int,
        alignment: Int,
        _ body: (UInt64) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: alignment
        )
        defer { pointer.deallocate() }
        body(UInt64(UInt(bitPattern: pointer)))
    }

    private static func fill(
        address: UInt64,
        byteCount: Int,
        value: UInt8
    ) {
        var offset = 0
        while offset < byteCount {
            PhysicalBytes.write8(value, at: address + UInt64(offset))
            offset += 1
        }
    }

    private static func expectBytes(
        at address: UInt64,
        equalTo expected: [UInt8],
        _ message: StaticString
    ) {
        var index = 0
        while index < expected.count {
            if PhysicalBytes.read8(at: address + UInt64(index))
                != expected[index] {
                fatalError("\(message): byte \(index) differed")
            }
            index += 1
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("VirtIO-GPU protocol assertion failed: \(message)")
        }
    }
}
