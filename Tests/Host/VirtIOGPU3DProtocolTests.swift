@main
struct VirtIOGPU3DProtocolTests {
    static func main() {
        testConstantsAndFeatureNegotiation()
        testFencedHeaderEncoding()
        testCapsetInfoCommandAndResponse()
        testCapsetCommandAndResponse()
        testContextLifecycleEncoding()
        testContextResourceEncoding()
        testResourceCreate3DEncoding()
        testTransfer3DEncoding()
        testSubmit3DEncoding()
        testFencedNoDataResponseValidation()
        print("VirtIO-GPU 3D protocol host tests: 10 groups passed")
    }

    private static func testConstantsAndFeatureNegotiation() {
        expect(VirtIOGPU3DFeatureBit.virgl == 0, "VIRGL feature bit drifted")
        expect(
            VirtIOGPU3DFeatures.baseline3DRequestMask == 1,
            "baseline 3D request must contain only VIRGL"
        )
        expect(VirtIOGPU3DFeatureBit.edid == 1, "EDID feature bit drifted")
        expect(
            VirtIOGPU3DFeatureBit.resourceUUID == 2,
            "RESOURCE_UUID feature bit drifted"
        )
        expect(
            VirtIOGPU3DFeatureBit.resourceBlob == 3,
            "RESOURCE_BLOB feature bit drifted"
        )
        expect(
            VirtIOGPU3DFeatureBit.contextInitialization == 4,
            "CONTEXT_INIT feature bit drifted"
        )
        expect(
            VirtIOGPU3DFeatureBit.blobAlignment == 5,
            "BLOB_ALIGNMENT feature bit drifted"
        )
        expect(
            VirtIOGPU3DControlType.getCapsetInfo == 0x0108
                && VirtIOGPU3DControlType.getCapset == 0x0109,
            "capset control types drifted"
        )
        expect(
            VirtIOGPU3DControlType.contextCreate == 0x0200
                && VirtIOGPU3DControlType.submit3D == 0x0207,
            "3D control type range drifted"
        )
        expect(
            VirtIOGPU3DControlType.responseOKCapsetInfo == 0x1102
                && VirtIOGPU3DControlType.responseOKCapset == 0x1103,
            "capset response types drifted"
        )
        expect(
            VirtIOGPU3DCapsetID.virgl == 1
                && VirtIOGPU3DCapsetID.crossDomain == 5,
            "capset identifier range drifted"
        )
        expect(
            VirtIOGPU3DResourceFlag.yOriginTop == 1,
            "3D resource Y-origin flag drifted"
        )

        let virgl = mask(VirtIOGPU3DFeatureBit.virgl)
        let blob = mask(VirtIOGPU3DFeatureBit.resourceBlob)
        let context = mask(VirtIOGPU3DFeatureBit.contextInitialization)
        let alignment = mask(VirtIOGPU3DFeatureBit.blobAlignment)
        let offered = virgl | blob | context | alignment
        guard let features = VirtIOGPU3DFeatures.negotiated(
            offered: offered,
            requested: offered
        ) else {
            fatalError("valid feature dependency chain was rejected")
        }
        expect(features.supports3D, "negotiated VIRGL bit was lost")
        expect(
            features.supportsContextInitialization,
            "negotiated CONTEXT_INIT bit was lost"
        )
        expect(
            VirtIOGPU3DFeatures.negotiated(
                offered: context,
                requested: context
            ) == nil,
            "CONTEXT_INIT was accepted without VIRGL"
        )
        expect(
            VirtIOGPU3DFeatures.negotiated(
                offered: alignment,
                requested: alignment
            ) == nil,
            "BLOB_ALIGNMENT was accepted without RESOURCE_BLOB"
        )
        expect(
            VirtIOGPU3DFeatures.negotiated(
                offered: virgl,
                requested: virgl | blob
            ) == nil,
            "an unoffered feature was negotiated"
        )
        expect(
            VirtIOGPU3DFeatures(rawValue: UInt64(1) << 63) == nil,
            "an unknown device-specific feature was accepted"
        )
    }

    private static func testFencedHeaderEncoding() {
        let features = requireFeatures(
            mask(VirtIOGPU3DFeatureBit.virgl)
                | mask(VirtIOGPU3DFeatureBit.contextInitialization)
        )
        guard let header = VirtIOGPU3DFencedHeader(
            type: VirtIOGPU3DControlType.submit3D,
            fenceID: 0x1122_3344_5566_7788,
            contextID: 0xa1b2_c3d4,
            ringIndex: 63,
            features: features
        ) else {
            fatalError("valid ring-indexed header was rejected")
        }

        withBuffer(byteCount: 32, alignment: 16) { address in
            fill(address: address, byteCount: 32, value: 0xa5)
            expect(
                header.write(at: address, capacity: 32)
                    == VirtIOGPU3DWireLayout.controlHeaderByteCount,
                "valid fenced header did not encode"
            )
            expectBytes(
                at: address,
                equalTo: [
                    0x07, 0x02, 0x00, 0x00,
                    0x03, 0x00, 0x00, 0x00,
                    0x88, 0x77, 0x66, 0x55,
                    0x44, 0x33, 0x22, 0x11,
                    0xd4, 0xc3, 0xb2, 0xa1,
                    0x3f, 0x00, 0x00, 0x00,
                ],
                "fenced control header little-endian layout"
            )
            expect(
                PhysicalBytes.read8(at: address + 24) == 0xa5,
                "header encoder overwrote the next byte"
            )
        }

        expect(
            VirtIOGPU3DFencedHeader(
                type: VirtIOGPU3DControlType.submit3D,
                fenceID: 1,
                contextID: 0,
                features: features
            ) == nil,
            "context command accepted context ID zero"
        )
        expect(
            VirtIOGPU3DFencedHeader(
                type: VirtIOGPU3DControlType.resourceCreate3D,
                fenceID: 1,
                contextID: 1,
                features: features
            ) == nil,
            "global resource command accepted a context ID"
        )
        expect(
            VirtIOGPU3DFencedHeader(
                type: VirtIOGPU3DControlType.submit3D,
                fenceID: 1,
                contextID: 1,
                ringIndex: 64,
                features: features
            ) == nil,
            "out-of-range ring index was accepted"
        )
        expect(
            VirtIOGPU3DFencedHeader(
                type: VirtIOGPU3DControlType.submit3D,
                fenceID: 1,
                contextID: 1,
                features: .none
            ) == nil,
            "3D command header was accepted without VIRGL"
        )
    }

    private static func testCapsetInfoCommandAndResponse() {
        let header = requireHeader(
            type: VirtIOGPU3DControlType.getCapsetInfo,
            fenceID: 0x0102_0304_0506_0708,
            contextID: 0,
            features: .none
        )
        withBuffer(byteCount: 64, alignment: 16) { address in
            fill(address: address, byteCount: 64, value: 0xee)
            expect(
                VirtIOGPU3DProtocol.writeGetCapsetInfo(
                    header: header,
                    capsetIndex: 2,
                    availableCapsetCount: 3,
                    at: address,
                    capacity: 64
                ) == 32,
                "GET_CAPSET_INFO command did not encode"
            )
            expectBytes(
                at: address,
                equalTo: [
                    0x08, 0x01, 0x00, 0x00,
                    0x01, 0x00, 0x00, 0x00,
                    0x08, 0x07, 0x06, 0x05,
                    0x04, 0x03, 0x02, 0x01,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x02, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ],
                "GET_CAPSET_INFO little-endian layout"
            )
            expect(
                PhysicalBytes.read8(at: address + 32) == 0xee,
                "GET_CAPSET_INFO overwrote the following byte"
            )
            expect(
                VirtIOGPU3DProtocol.writeGetCapsetInfo(
                    header: header,
                    capsetIndex: 3,
                    availableCapsetCount: 3,
                    at: address,
                    capacity: 64
                ) == nil,
                "out-of-range capset index was accepted"
            )

            writeResponseHeader(
                type: VirtIOGPU3DControlType.responseOKCapsetInfo,
                flags: VirtIOGPU3DFencedHeader.fenceFlag,
                fenceID: header.fenceID,
                at: address
            )
            PhysicalBytes.writeLE32(VirtIOGPU3DCapsetID.virgl2, at: address + 24)
            PhysicalBytes.writeLE32(7, at: address + 28)
            PhysicalBytes.writeLE32(4096, at: address + 32)
            PhysicalBytes.writeLE32(0, at: address + 36)
            expect(
                VirtIOGPU3DProtocol.readCapsetInfoResponse(
                    at: address,
                    byteCount: 40,
                    fenceID: header.fenceID
                ) == VirtIOGPU3DCapsetInfo(
                    id: VirtIOGPU3DCapsetID.virgl2,
                    maximumVersion: 7,
                    maximumByteCount: 4096
                ),
                "CAPSET_INFO response was not decoded"
            )
            expect(
                VirtIOGPU3DProtocol.readCapsetInfoResponse(
                    at: address,
                    byteCount: 39,
                    fenceID: header.fenceID
                ) == nil,
                "truncated CAPSET_INFO response was accepted"
            )
            expect(
                VirtIOGPU3DProtocol.readCapsetInfoResponse(
                    at: address,
                    byteCount: 41,
                    fenceID: header.fenceID
                ) == nil,
                "oversized CAPSET_INFO response was accepted"
            )
            PhysicalBytes.writeLE32(6, at: address + 24)
            expect(
                VirtIOGPU3DProtocol.readCapsetInfoResponse(
                    at: address,
                    byteCount: 40,
                    fenceID: header.fenceID
                ) == nil,
                "undefined capset ID was accepted"
            )
        }
    }

    private static func testCapsetCommandAndResponse() {
        let header = requireHeader(
            type: VirtIOGPU3DControlType.getCapset,
            fenceID: 0xaabb_ccdd_eeff_0011,
            contextID: 0,
            features: .none
        )
        withBuffer(byteCount: 64, alignment: 16) { address in
            fill(address: address, byteCount: 64, value: 0xcc)
            expect(
                VirtIOGPU3DProtocol.writeGetCapset(
                    header: header,
                    capsetID: VirtIOGPU3DCapsetID.virgl2,
                    version: 4,
                    maximumVersion: 4,
                    at: address,
                    capacity: 64
                ) == 32,
                "GET_CAPSET command did not encode"
            )
            expect(PhysicalBytes.readLE32(at: address) == 0x0109, "wrong GET_CAPSET type")
            expect(PhysicalBytes.readLE32(at: address + 24) == 2, "wrong capset ID")
            expect(PhysicalBytes.readLE32(at: address + 28) == 4, "wrong capset version")
            expect(
                VirtIOGPU3DProtocol.writeGetCapset(
                    header: header,
                    capsetID: VirtIOGPU3DCapsetID.virgl2,
                    version: 5,
                    maximumVersion: 4,
                    at: address,
                    capacity: 64
                ) == nil,
                "unsupported capset version was accepted"
            )

            writeResponseHeader(
                type: VirtIOGPU3DControlType.responseOKCapset,
                flags: VirtIOGPU3DFencedHeader.fenceFlag,
                fenceID: header.fenceID,
                at: address
            )
            PhysicalBytes.write8(0xde, at: address + 24)
            PhysicalBytes.write8(0xad, at: address + 25)
            PhysicalBytes.write8(0xbe, at: address + 26)
            PhysicalBytes.write8(0xef, at: address + 27)
            expect(
                VirtIOGPU3DProtocol.readCapsetResponse(
                    at: address,
                    byteCount: 28,
                    expectedPayloadByteCount: 4,
                    fenceID: header.fenceID
                ) == VirtIOGPU3DByteRange(address: address + 24, byteCount: 4),
                "CAPSET payload range was not validated"
            )
            expect(
                VirtIOGPU3DProtocol.readCapsetResponse(
                    at: address,
                    byteCount: 29,
                    expectedPayloadByteCount: 4,
                    fenceID: header.fenceID
                ) == nil,
                "CAPSET response with an unexpected length was accepted"
            )
        }
    }

    private static func testContextLifecycleEncoding() {
        let virglOnly = requireFeatures(mask(VirtIOGPU3DFeatureBit.virgl))
        let features = requireFeatures(
            mask(VirtIOGPU3DFeatureBit.virgl)
                | mask(VirtIOGPU3DFeatureBit.contextInitialization)
        )
        let create = requireHeader(
            type: VirtIOGPU3DControlType.contextCreate,
            fenceID: 9,
            contextID: 17,
            features: features
        )
        let destroy = requireHeader(
            type: VirtIOGPU3DControlType.contextDestroy,
            fenceID: 10,
            contextID: 17,
            features: features
        )

        withBuffer(byteCount: 16, alignment: 8) { nameAddress in
            let name: [UInt8] = [0x53, 0x77, 0x69, 0x66, 0x74, 0x4f, 0x53]
            writeBytes(name, at: nameAddress)
            withBuffer(byteCount: 112, alignment: 16) { address in
                fill(address: address, byteCount: 112, value: 0xa5)
                expect(
                    VirtIOGPU3DProtocol.writeContextCreate(
                        header: create,
                        contextInitialization: VirtIOGPU3DCapsetID.virgl2,
                        features: features,
                        debugNameAddress: nameAddress,
                        debugNameByteCount: UInt32(name.count),
                        at: address,
                        capacity: 112
                    ) == 96,
                    "CTX_CREATE command did not encode"
                )
                expect(PhysicalBytes.readLE32(at: address) == 0x0200, "wrong CTX_CREATE type")
                expect(PhysicalBytes.readLE32(at: address + 16) == 17, "wrong context ID")
                expect(PhysicalBytes.readLE32(at: address + 24) == 7, "wrong debug-name length")
                expect(PhysicalBytes.readLE32(at: address + 28) == 2, "wrong context_init")
                expectBytes(
                    at: address + 32,
                    equalTo: name,
                    "CTX_CREATE debug-name bytes"
                )
                expectZeroes(
                    at: address + 39,
                    byteCount: 57,
                    "CTX_CREATE debug-name tail was not zero padded"
                )
                expect(
                    PhysicalBytes.read8(at: address + 96) == 0xa5,
                    "CTX_CREATE overwrote the following byte"
                )
                expect(
                    VirtIOGPU3DProtocol.writeContextCreate(
                        header: create,
                        contextInitialization: VirtIOGPU3DCapsetID.virgl2,
                        features: virglOnly,
                        debugNameAddress: nameAddress,
                        debugNameByteCount: 7,
                        at: address,
                        capacity: 112
                    ) == nil,
                    "context_init was accepted without CONTEXT_INIT"
                )
                expect(
                    VirtIOGPU3DProtocol.writeContextCreate(
                        header: create,
                        contextInitialization: 0x0000_0101,
                        features: features,
                        debugNameAddress: nameAddress,
                        debugNameByteCount: 7,
                        at: address,
                        capacity: 112
                    ) == nil,
                    "reserved context_init bits were accepted"
                )
                expect(
                    VirtIOGPU3DProtocol.writeContextCreate(
                        header: create,
                        contextInitialization: 0,
                        features: features,
                        debugNameAddress: address + 32,
                        debugNameByteCount: 1,
                        at: address,
                        capacity: 112
                    ) == nil,
                    "overlapping debug-name source was accepted"
                )

                fill(address: address, byteCount: 112, value: 0xcc)
                expect(
                    VirtIOGPU3DProtocol.writeContextDestroy(
                        header: destroy,
                        at: address,
                        capacity: 112
                    ) == 24,
                    "CTX_DESTROY command did not encode"
                )
                expect(PhysicalBytes.readLE32(at: address) == 0x0201, "wrong CTX_DESTROY type")
                expect(
                    PhysicalBytes.read8(at: address + 24) == 0xcc,
                    "CTX_DESTROY overwrote the following byte"
                )
            }
        }
    }

    private static func testContextResourceEncoding() {
        let features = requireFeatures(mask(VirtIOGPU3DFeatureBit.virgl))
        let attach = requireHeader(
            type: VirtIOGPU3DControlType.contextAttachResource,
            fenceID: 31,
            contextID: 7,
            features: features
        )
        let detach = requireHeader(
            type: VirtIOGPU3DControlType.contextDetachResource,
            fenceID: 32,
            contextID: 7,
            features: features
        )
        withBuffer(byteCount: 48, alignment: 16) { address in
            fill(address: address, byteCount: 48, value: 0xa5)
            expect(
                VirtIOGPU3DProtocol.writeContextAttachResource(
                    header: attach,
                    resourceID: 0x4433_2211,
                    at: address,
                    capacity: 48
                ) == 32,
                "CTX_ATTACH_RESOURCE command did not encode"
            )
            expect(PhysicalBytes.readLE32(at: address) == 0x0202, "wrong attach type")
            expect(
                PhysicalBytes.readLE32(at: address + 24) == 0x4433_2211,
                "wrong attached resource ID"
            )
            expect(PhysicalBytes.readLE32(at: address + 28) == 0, "attach padding was not zero")

            expect(
                VirtIOGPU3DProtocol.writeContextDetachResource(
                    header: detach,
                    resourceID: 0x8877_6655,
                    at: address,
                    capacity: 48
                ) == 32,
                "CTX_DETACH_RESOURCE command did not encode"
            )
            expect(PhysicalBytes.readLE32(at: address) == 0x0203, "wrong detach type")
            expect(
                PhysicalBytes.readLE32(at: address + 24) == 0x8877_6655,
                "wrong detached resource ID"
            )
            expect(
                VirtIOGPU3DProtocol.writeContextAttachResource(
                    header: attach,
                    resourceID: 0,
                    at: address,
                    capacity: 48
                ) == nil,
                "resource ID zero was accepted"
            )
        }
    }

    private static func testResourceCreate3DEncoding() {
        let features = requireFeatures(mask(VirtIOGPU3DFeatureBit.virgl))
        let header = requireHeader(
            type: VirtIOGPU3DControlType.resourceCreate3D,
            fenceID: 0x91,
            contextID: 0,
            features: features
        )
        guard let resource = VirtIOGPU3DResourceDescriptor(
            resourceID: 0x0102_0304,
            target: 0x1112_1314,
            format: 0x2122_2324,
            bind: 0x3132_3334,
            width: 1920,
            height: 1080,
            depth: 1,
            arraySize: 1,
            lastLevel: 4,
            sampleCount: 8,
            flags: 0x4142_4344
        ) else {
            fatalError("valid 3D resource descriptor was rejected")
        }
        withBuffer(byteCount: 80, alignment: 16) { address in
            fill(address: address, byteCount: 80, value: 0xa5)
            expect(
                VirtIOGPU3DProtocol.writeResourceCreate3D(
                    header: header,
                    resource: resource,
                    at: address,
                    capacity: 80
                ) == 72,
                "RESOURCE_CREATE_3D command did not encode"
            )
            let expected: [UInt32] = [
                0x0102_0304, 0x1112_1314, 0x2122_2324, 0x3132_3334,
                1920, 1080, 1, 1, 4, 8, 0x4142_4344, 0,
            ]
            var index = 0
            while index < expected.count {
                expect(
                    PhysicalBytes.readLE32(at: address + 24 + UInt64(index * 4))
                        == expected[index],
                    "RESOURCE_CREATE_3D field differed"
                )
                index += 1
            }
            expect(
                PhysicalBytes.read8(at: address + 72) == 0xa5,
                "RESOURCE_CREATE_3D overwrote the following byte"
            )
            expectBytes(
                at: address + 24,
                equalTo: [
                    0x04, 0x03, 0x02, 0x01,
                    0x14, 0x13, 0x12, 0x11,
                    0x24, 0x23, 0x22, 0x21,
                    0x34, 0x33, 0x32, 0x31,
                ],
                "RESOURCE_CREATE_3D leading field byte order"
            )
        }
        expect(
            VirtIOGPU3DResourceDescriptor(
                resourceID: 1,
                target: 1,
                format: 1,
                bind: 1,
                width: 0,
                height: 1,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                sampleCount: 0,
                flags: 0
            ) == nil,
            "zero-width 3D resource was accepted"
        )
    }

    private static func testTransfer3DEncoding() {
        let features = requireFeatures(mask(VirtIOGPU3DFeatureBit.virgl))
        let toHost = requireHeader(
            type: VirtIOGPU3DControlType.transferToHost3D,
            fenceID: 100,
            contextID: 12,
            features: features
        )
        let fromHost = requireHeader(
            type: VirtIOGPU3DControlType.transferFromHost3D,
            fenceID: 101,
            contextID: 12,
            features: features
        )
        guard let box = VirtIOGPU3DBox(
            x: 1,
            y: 2,
            z: 3,
            width: 640,
            height: 480,
            depth: 4
        ),
        let transfer = VirtIOGPU3DTransfer(
            box: box,
            offset: 0x1122_3344_5566_7788,
            resourceID: 0xaabb_ccdd,
            level: 5,
            stride: 2560,
            layerStride: 1_228_800
        ) else {
            fatalError("valid 3D transfer fixture was rejected")
        }
        withBuffer(byteCount: 80, alignment: 16) { address in
            expect(
                VirtIOGPU3DProtocol.writeTransferToHost3D(
                    header: toHost,
                    transfer: transfer,
                    at: address,
                    capacity: 80
                ) == 72,
                "TRANSFER_TO_HOST_3D did not encode"
            )
            expect(PhysicalBytes.readLE32(at: address) == 0x0205, "wrong transfer-to type")
            expect(PhysicalBytes.readLE32(at: address + 24) == 1, "wrong box x")
            expect(PhysicalBytes.readLE32(at: address + 28) == 2, "wrong box y")
            expect(PhysicalBytes.readLE32(at: address + 32) == 3, "wrong box z")
            expect(PhysicalBytes.readLE32(at: address + 36) == 640, "wrong box width")
            expect(PhysicalBytes.readLE32(at: address + 40) == 480, "wrong box height")
            expect(PhysicalBytes.readLE32(at: address + 44) == 4, "wrong box depth")
            expect(
                PhysicalBytes.readLE64(at: address + 48)
                    == 0x1122_3344_5566_7788,
                "wrong transfer offset"
            )
            expectBytes(
                at: address + 48,
                equalTo: [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11],
                "TRANSFER_3D offset byte order"
            )
            expect(
                PhysicalBytes.readLE32(at: address + 56) == 0xaabb_ccdd,
                "wrong transfer resource ID"
            )
            expect(PhysicalBytes.readLE32(at: address + 60) == 5, "wrong transfer level")
            expect(PhysicalBytes.readLE32(at: address + 64) == 2560, "wrong transfer stride")
            expect(
                PhysicalBytes.readLE32(at: address + 68) == 1_228_800,
                "wrong transfer layer stride"
            )
            expect(
                VirtIOGPU3DProtocol.writeTransferFromHost3D(
                    header: fromHost,
                    transfer: transfer,
                    at: address,
                    capacity: 80
                ) == 72,
                "TRANSFER_FROM_HOST_3D did not encode"
            )
            expect(PhysicalBytes.readLE32(at: address) == 0x0206, "wrong transfer-from type")
        }
        expect(
            VirtIOGPU3DBox(
                x: UInt32.max,
                y: 0,
                z: 0,
                width: 2,
                height: 1,
                depth: 1
            ) == nil,
            "overflowing transfer box was accepted"
        )
    }

    private static func testSubmit3DEncoding() {
        let features = requireFeatures(mask(VirtIOGPU3DFeatureBit.virgl))
        let header = requireHeader(
            type: VirtIOGPU3DControlType.submit3D,
            fenceID: 0xfedc_ba98_7654_3210,
            contextID: 42,
            features: features
        )
        withBuffer(byteCount: 16, alignment: 8) { streamAddress in
            let stream: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x21, 0x43, 0x65]
            writeBytes(stream, at: streamAddress)
            withBuffer(byteCount: 48, alignment: 16) { address in
                fill(address: address, byteCount: 48, value: 0xa5)
                expect(
                    VirtIOGPU3DProtocol.writeSubmit3D(
                        header: header,
                        commandStreamAddress: streamAddress,
                        commandStreamByteCount: UInt32(stream.count),
                        at: address,
                        capacity: 48
                    ) == 39,
                    "SUBMIT_3D command did not encode"
                )
                expect(PhysicalBytes.readLE32(at: address) == 0x0207, "wrong SUBMIT_3D type")
                expect(PhysicalBytes.readLE32(at: address + 16) == 42, "wrong submit context ID")
                expect(PhysicalBytes.readLE32(at: address + 24) == 7, "wrong submit size")
                expect(PhysicalBytes.readLE32(at: address + 28) == 0, "submit padding was not zero")
                expectBytes(
                    at: address + 32,
                    equalTo: stream,
                    "opaque SUBMIT_3D payload"
                )
                expect(
                    PhysicalBytes.read8(at: address + 39) == 0xa5,
                    "SUBMIT_3D overwrote the following byte"
                )
                expect(
                    VirtIOGPU3DProtocol.writeSubmit3D(
                        header: header,
                        commandStreamAddress: streamAddress,
                        commandStreamByteCount: 7,
                        at: address,
                        capacity: 38
                    ) == nil,
                    "undersized submit buffer was accepted"
                )
                expect(
                    VirtIOGPU3DProtocol.writeSubmit3D(
                        header: header,
                        commandStreamAddress: address + 32,
                        commandStreamByteCount: 1,
                        at: address,
                        capacity: 48
                    ) == nil,
                    "overlapping submit source was accepted"
                )
                expect(
                    VirtIOGPU3DProtocol.writeSubmit3D(
                        header: header,
                        commandStreamAddress: streamAddress,
                        commandStreamByteCount: 0,
                        at: address,
                        capacity: 48
                    ) == nil,
                    "empty submit was accepted"
                )
            }
        }
    }

    private static func testFencedNoDataResponseValidation() {
        withBuffer(byteCount: 32, alignment: 16) { address in
            let fence: UInt64 = 0x0102_0304_0506_0708
            writeResponseHeader(
                type: VirtIOGPU3DControlType.responseOKNoData,
                flags: VirtIOGPU3DFencedHeader.fenceFlag,
                fenceID: fence,
                at: address
            )
            expect(
                VirtIOGPU3DProtocol.noDataResponseIsValid(
                    at: address,
                    byteCount: 24,
                    fenceID: fence
                ),
                "valid fenced no-data response was rejected"
            )
            expect(
                !VirtIOGPU3DProtocol.noDataResponseIsValid(
                    at: address,
                    byteCount: 25,
                    fenceID: fence
                ),
                "oversized no-data response was accepted"
            )
            PhysicalBytes.writeLE32(0, at: address + 4)
            expect(
                !VirtIOGPU3DProtocol.noDataResponseIsValid(
                    at: address,
                    byteCount: 24,
                    fenceID: fence
                ),
                "unfenced response was accepted"
            )
            PhysicalBytes.writeLE32(VirtIOGPU3DFencedHeader.fenceFlag, at: address + 4)
            expect(
                !VirtIOGPU3DProtocol.noDataResponseIsValid(
                    at: address,
                    byteCount: 24,
                    fenceID: fence + 1
                ),
                "response with wrong fence ID was accepted"
            )
        }
    }

    private static func requireFeatures(_ rawValue: UInt64) -> VirtIOGPU3DFeatures {
        guard let features = VirtIOGPU3DFeatures(rawValue: rawValue) else {
            fatalError("valid feature fixture was rejected")
        }
        return features
    }

    private static func requireHeader(
        type: UInt32,
        fenceID: UInt64,
        contextID: UInt32,
        ringIndex: UInt8? = nil,
        features: VirtIOGPU3DFeatures
    ) -> VirtIOGPU3DFencedHeader {
        guard let header = VirtIOGPU3DFencedHeader(
            type: type,
            fenceID: fenceID,
            contextID: contextID,
            ringIndex: ringIndex,
            features: features
        ) else {
            fatalError("valid fenced-header fixture was rejected")
        }
        return header
    }

    private static func writeResponseHeader(
        type: UInt32,
        flags: UInt32,
        fenceID: UInt64,
        at address: UInt64
    ) {
        _ = PhysicalBytes.zero(address: address, byteCount: 24)
        PhysicalBytes.writeLE32(type, at: address)
        PhysicalBytes.writeLE32(flags, at: address + 4)
        PhysicalBytes.writeLE64(fenceID, at: address + 8)
    }

    private static func mask(_ bit: UInt32) -> UInt64 {
        UInt64(1) << UInt64(bit)
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

    private static func writeBytes(_ bytes: [UInt8], at address: UInt64) {
        var index = 0
        while index < bytes.count {
            PhysicalBytes.write8(bytes[index], at: address + UInt64(index))
            index += 1
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

    private static func expectZeroes(
        at address: UInt64,
        byteCount: Int,
        _ message: StaticString
    ) {
        var index = 0
        while index < byteCount {
            if PhysicalBytes.read8(at: address + UInt64(index)) != 0 {
                fatalError("\(message): byte \(index) was nonzero")
            }
            index += 1
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("VirtIO-GPU 3D protocol assertion failed: \(message)")
        }
    }
}
