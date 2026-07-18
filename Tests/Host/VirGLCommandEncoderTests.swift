@main
struct VirGLCommandEncoderTests {
    static func main() {
        testPacketHeadersAndArenaBoundaries()
        testGenericObjectLifecycle()
        testSurfaceAndFramebufferPackets()
        testViewportAndScissorPackets()
        testResourceCopyRegionPackets()
        testClearPackets()
        testFixedFunctionStatePackets()
        testVertexAndConstantPackets()
        testInlineResourceWrite()
        testShaderObjectFragments()
        testShaderBindAndLinkPackets()
        testDrawPacketAndAtomicRejections()
        print("VirGL command encoder host tests: 12 groups passed")
    }

    private static func testPacketHeadersAndArenaBoundaries() {
        expect(
            VirGLWire.packetHeader(
                command: .createObject,
                objectType: .surface,
                payloadDWordCount: 5
            ) == 0x0005_0801,
            "CREATE_OBJECT/SURFACE packet header"
        )
        expect(
            VirGLWire.packetHeader(
                command: .drawVBO,
                payloadDWordCount: 12
            ) == 0x000c_0008,
            "DRAW_VBO packet header"
        )
        expect(
            VirGLWire.packetHeader(
                command: .clearTexture,
                payloadDWordCount: 12
            ) == 0x000c_002f,
            "CLEAR_TEXTURE packet header"
        )
        expect(
            VirGLWire.packetHeader(
                command: .linkShader,
                payloadDWordCount: 6
            ) == 0x0006_0034,
            "LINK_SHADER packet header"
        )
        expect(
            VirGLWire.packetHeader(
                command: .clear,
                payloadDWordCount: VirGLWire.maximumPayloadDWordCount + 1
            ) == nil,
            "oversized packet header was accepted"
        )

        let empty = UnsafeMutableBufferPointer<UInt32>(start: nil, count: 0)
        expect(
            VirGLDWordArena(storage: empty) == nil,
            "empty arena was accepted"
        )

        withArena(capacity: 8) { arena, storage in
            let clear = requireClearValue(bufferMask: 1 << 2)
            expectRejected(
                arena.encodeClear(clear),
                .capacityExhausted,
                "clear exceeding arena"
            )
            expect(arena.dwordCount == 0, "failed packet advanced cursor")
            expect(
                UInt32(littleEndian: storage[0]) == 0xa5a5_a5a5,
                "failed packet overwrote arena"
            )
        }
    }

    private static func testGenericObjectLifecycle() {
        withArena(capacity: 32) { arena, _ in
            let state: [UInt32] = [0x1122_3344, 0x5566_7788]
            state.withUnsafeBufferPointer { words in
                expectEncoded(
                    arena.encodeCreateObject(
                        type: .samplerState,
                        handle: 0x44,
                        stateDWords: words
                    ),
                    start: 0,
                    count: 4,
                    "generic CREATE_OBJECT"
                )
            }
            expectEncoded(
                arena.encodeBindObject(type: .samplerState, handle: 0x44),
                start: 4,
                count: 2,
                "BIND_OBJECT"
            )
            expectEncoded(
                arena.encodeBindObject(type: .samplerState, handle: nil),
                start: 6,
                count: 2,
                "BIND_OBJECT unbind"
            )
            expectEncoded(
                arena.encodeDestroyObject(type: .samplerState, handle: 0x44),
                start: 8,
                count: 2,
                "DESTROY_OBJECT"
            )
            expectDWords(
                arena,
                [
                    0x0003_0701, 0x44, 0x1122_3344, 0x5566_7788,
                    0x0001_0702, 0x44,
                    0x0001_0702, 0,
                    0x0001_0703, 0x44,
                ],
                "generic object lifecycle layout"
            )

            let before = arena.dwordCount
            state.withUnsafeBufferPointer { words in
                expectRejected(
                    arena.encodeCreateObject(
                        type: .blend,
                        handle: 0,
                        stateDWords: words
                    ),
                    .invalidObjectHandle,
                    "zero CREATE_OBJECT handle"
                )
            }
            expect(arena.dwordCount == before, "invalid handle advanced cursor")
            expectRejected(
                arena.encodeBindObject(type: .null, handle: 1),
                .invalidObjectType,
                "NULL object type"
            )
        }
    }

    private static func testSurfaceAndFramebufferPackets() {
        withArena(capacity: 32) { arena, _ in
            expectEncoded(
                arena.encodeCreateSurface(
                    handle: 0x10,
                    resourceHandle: 0x20,
                    format: 0x43,
                    view: .texture(level: 2, firstLayer: 3, lastLayer: 7)
                ),
                start: 0,
                count: 6,
                "surface create"
            )
            let colors: [UInt32] = [0x10, 0]
            colors.withUnsafeBufferPointer { handles in
                expectEncoded(
                    arena.encodeSetFramebuffer(
                        colorSurfaceHandles: handles,
                        depthStencilSurfaceHandle: 0x30
                    ),
                    start: 6,
                    count: 5,
                    "framebuffer state"
                )
            }
            expectDWords(
                arena,
                [
                    0x0005_0801, 0x10, 0x20, 0x43, 2, 0x0007_0003,
                    0x0004_0005, 2, 0x30, 0x10, 0,
                ],
                "surface/framebuffer layout"
            )

            expectRejected(
                arena.encodeCreateSurface(
                    handle: 1,
                    resourceHandle: 0,
                    format: 1,
                    view: .buffer(firstElement: 0, lastElement: 1)
                ),
                .invalidResourceHandle,
                "surface resource zero"
            )
            expectRejected(
                arena.encodeCreateSurface(
                    handle: 1,
                    resourceHandle: 2,
                    format: 1,
                    view: .texture(
                        level: 0,
                        firstLayer: 8,
                        lastLayer: 7
                    )
                ),
                .invalidSurfaceView,
                "reversed texture layers"
            )
            let tooMany = Array(repeating: UInt32(1), count: 9)
            tooMany.withUnsafeBufferPointer { handles in
                expectRejected(
                    arena.encodeSetFramebuffer(
                        colorSurfaceHandles: handles,
                        depthStencilSurfaceHandle: nil
                    ),
                    .invalidCount,
                    "too many color surfaces"
                )
            }
        }
    }

    private static func testViewportAndScissorPackets() {
        withArena(capacity: 32) { arena, _ in
            let viewports = [
                VirGLViewport(
                    scaleXBits: 1,
                    scaleYBits: 2,
                    scaleZBits: 3,
                    translateXBits: 4,
                    translateYBits: 5,
                    translateZBits: 6
                ),
            ]
            viewports.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeSetViewports(startSlot: 2, viewports: values),
                    start: 0,
                    count: 8,
                    "viewport state"
                )
            }
            let scissors = [
                requireScissor(1, 2, 300, 400),
                requireScissor(0, 0, 0, 0),
            ]
            scissors.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeSetScissors(startSlot: 1, scissors: values),
                    start: 8,
                    count: 6,
                    "scissor state"
                )
            }
            expectDWords(
                arena,
                [
                    0x0007_0004, 2, 1, 2, 3, 4, 5, 6,
                    0x0005_000f, 1,
                    0x0002_0001, 0x0190_012c,
                    0, 0,
                ],
                "viewport/scissor layout"
            )
            expect(
                VirGLScissorRectangle(
                    minimumX: 0,
                    minimumY: 0,
                    maximumX: 65_536,
                    maximumY: 1
                ) == nil,
                "out-of-range scissor was accepted"
            )
        }
    }

    private static func testResourceCopyRegionPackets() {
        let sourceBox = requireTextureBox(
            x: 11,
            y: 12,
            z: 13,
            width: 14,
            height: 15,
            depth: 16
        )
        withArena(capacity: 24) { arena, storage in
            expectEncoded(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 0x21,
                    destinationLevel: 2,
                    destinationX: 3,
                    destinationY: 4,
                    destinationZ: 5,
                    sourceResourceHandle: 0x31,
                    sourceLevel: 6,
                    sourceBox: sourceBox
                ),
                start: 0,
                count: 14,
                "RESOURCE_COPY_REGION"
            )
            expectDWords(
                arena,
                [
                    0x000d_0011,
                    0x21, 2, 3, 4, 5,
                    0x31, 6, 11, 12, 13, 14, 15, 16,
                ],
                "resource-copy-region layout"
            )

            let before = arena.dwordCount
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 0,
                    destinationLevel: 0,
                    destinationX: 0,
                    destinationY: 0,
                    destinationZ: 0,
                    sourceResourceHandle: 1,
                    sourceLevel: 0,
                    sourceBox: sourceBox
                ),
                .invalidResourceHandle,
                "zero copy destination resource"
            )
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 1,
                    destinationLevel: 0,
                    destinationX: 0,
                    destinationY: 0,
                    destinationZ: 0,
                    sourceResourceHandle: 0,
                    sourceLevel: 0,
                    sourceBox: sourceBox
                ),
                .invalidResourceHandle,
                "zero copy source resource"
            )
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 1,
                    destinationLevel: UInt32.max,
                    destinationX: UInt32.max - 13,
                    destinationY: 0,
                    destinationZ: 0,
                    sourceResourceHandle: 2,
                    sourceLevel: UInt32.max,
                    sourceBox: sourceBox
                ),
                .invalidCopyRegion,
                "overflowing copy destination x"
            )
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 1,
                    destinationLevel: 0,
                    destinationX: 0,
                    destinationY: UInt32.max - 14,
                    destinationZ: 0,
                    sourceResourceHandle: 2,
                    sourceLevel: 0,
                    sourceBox: sourceBox
                ),
                .invalidCopyRegion,
                "overflowing copy destination y"
            )
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 1,
                    destinationLevel: 0,
                    destinationX: 0,
                    destinationY: 0,
                    destinationZ: UInt32.max - 15,
                    sourceResourceHandle: 2,
                    sourceLevel: 0,
                    sourceBox: sourceBox
                ),
                .invalidCopyRegion,
                "overflowing copy destination z"
            )
            expect(
                arena.dwordCount == before,
                "invalid resource copy advanced cursor"
            )
            expect(
                UInt32(littleEndian: storage[before]) == 0xa5a5_a5a5,
                "invalid resource copy overwrote arena"
            )
        }

        withArena(capacity: 13) { arena, storage in
            expectRejected(
                arena.encodeResourceCopyRegion(
                    destinationResourceHandle: 1,
                    destinationLevel: 0,
                    destinationX: 0,
                    destinationY: 0,
                    destinationZ: 0,
                    sourceResourceHandle: 2,
                    sourceLevel: 0,
                    sourceBox: sourceBox
                ),
                .capacityExhausted,
                "resource copy exceeding arena"
            )
            expect(arena.dwordCount == 0, "failed copy advanced cursor")
            expect(
                UInt32(littleEndian: storage[0]) == 0xa5a5_a5a5,
                "failed resource copy overwrote arena"
            )
        }

        expect(
            VirGLTextureBox(
                x: 0,
                y: 0,
                z: 0,
                width: 0,
                height: 1,
                depth: 1
            ) == nil,
            "zero-width copy source box was accepted"
        )
        expect(
            VirGLTextureBox(
                x: UInt32.max,
                y: 0,
                z: 0,
                width: 1,
                height: 1,
                depth: 1
            ) == nil,
            "overflowing copy source box was accepted"
        )
    }

    private static func testClearPackets() {
        withArena(capacity: 32) { arena, _ in
            let clear = requireClearValue(
                bufferMask: (1 << 0) | (1 << 2),
                colors: (1, 2, 3, 4),
                depth: 0x1122_3344_5566_7788,
                stencil: 0x99
            )
            expectEncoded(
                arena.encodeClear(clear),
                start: 0,
                count: 9,
                "CLEAR"
            )

            let capabilities = fullCapabilities()
            let box = requireTextureBox(
                x: 10,
                y: 20,
                z: 0,
                width: 30,
                height: 40,
                depth: 1
            )
            expectEncoded(
                arena.encodeClearTexture(
                    capabilities: capabilities,
                    resourceHandle: 0x77,
                    level: 2,
                    box: box,
                    value: VirGLClearTextureValue(
                        word0: 0xaa,
                        word1: 0xbb,
                        word2: 0xcc,
                        word3: 0xdd
                    )
                ),
                start: 9,
                count: 13,
                "CLEAR_TEXTURE"
            )
            expectDWords(
                arena,
                [
                    0x0008_0007,
                    0x5, 1, 2, 3, 4,
                    0x5566_7788, 0x1122_3344, 0x99,
                    0x000c_002f,
                    0x77, 2, 10, 20, 0, 30, 40, 1,
                    0xaa, 0xbb, 0xcc, 0xdd,
                ],
                "clear packet layouts"
            )

            let unsupported = VirGLContextCapabilities(
                capsetID: 2,
                capsetVersion: 2,
                capabilityBits: 0,
                capabilityBitsV2: 0
            )
            expectRejected(
                arena.encodeClearTexture(
                    capabilities: unsupported,
                    resourceHandle: 1,
                    level: 0,
                    box: box,
                    value: VirGLClearTextureValue(
                        word0: 0,
                        word1: 0,
                        word2: 0,
                        word3: 0
                    )
                ),
                .unsupportedCapability,
                "CLEAR_TEXTURE without cap bit"
            )
        }
    }

    private static func testFixedFunctionStatePackets() {
        withArena(capacity: 64) { arena, _ in
            let global = requireBlendGlobal(flags: 0x1b, logicOperation: 0xe)
            let target = requireBlendTarget()
            let targets = Array(repeating: target, count: 8)
            targets.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeCreateBlendState(
                        handle: 0x101,
                        global: global,
                        targets: values
                    ),
                    start: 0,
                    count: 12,
                    "blend state"
                )
            }

            let rasterizer = VirGLRasterizerState(
                flags: 1,
                pointSizeBits: 2,
                spriteCoordinateEnableMask: 3,
                lineAndClipState: 4,
                lineWidthBits: 5,
                offsetUnitsBits: 6,
                offsetScaleBits: 7,
                offsetClampBits: 8
            )
            expectEncoded(
                arena.encodeCreateRasterizerState(
                    handle: 0x202,
                    state: rasterizer
                ),
                start: 12,
                count: 10,
                "rasterizer state"
            )

            let dsa = requireDSA(
                depthAlpha: 0x0000_0f1f,
                front: 0x1fff_ffff,
                back: 0x0102_0304,
                alpha: 0x3f00_0000
            )
            expectEncoded(
                arena.encodeCreateDepthStencilAlphaState(
                    handle: 0x303,
                    state: dsa
                ),
                start: 22,
                count: 6,
                "DSA state"
            )

            var expected: [UInt32] = [0x000b_0101, 0x101, 0x1b, 0xe]
            expected += Array(repeating: target.packedDWord, count: 8)
            expected += [
                0x0009_0201, 0x202, 1, 2, 3, 4, 5, 6, 7, 8,
                0x0005_0301, 0x303,
                0x0000_0f1f, 0x1fff_ffff, 0x0102_0304, 0x3f00_0000,
            ]
            expectDWords(arena, expected, "fixed-function state layouts")

            expect(
                VirGLBlendGlobalState(
                    flags: 0x20,
                    logicOperation: 0
                ) == nil,
                "reserved blend flag was accepted"
            )
            expect(
                VirGLDepthStencilAlphaState(
                    depthAlphaDWord: 0x20,
                    frontStencilDWord: 0,
                    backStencilDWord: 0,
                    alphaReferenceBits: 0
                ) == nil,
                "reserved DSA bit was accepted"
            )
        }
    }

    private static func testVertexAndConstantPackets() {
        withArena(capacity: 64) { arena, _ in
            let buffers = [
                VirGLVertexBuffer(stride: 16, offset: 32, resourceHandle: 7),
                VirGLVertexBuffer(stride: 8, offset: 4, resourceHandle: 8),
            ]
            buffers.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeSetVertexBuffers(values),
                    start: 0,
                    count: 7,
                    "vertex buffers"
                )
            }
            let elements = [
                VirGLVertexElement(
                    sourceOffset: 0,
                    instanceDivisor: 0,
                    vertexBufferIndex: 0,
                    sourceFormat: 10
                ),
                VirGLVertexElement(
                    sourceOffset: 8,
                    instanceDivisor: 1,
                    vertexBufferIndex: 1,
                    sourceFormat: 11
                ),
            ]
            elements.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeCreateVertexElements(
                        handle: 9,
                        elements: values
                    ),
                    start: 7,
                    count: 10,
                    "vertex elements"
                )
            }
            let constants: [UInt32] = [0x10, 0x20, 0x30]
            constants.withUnsafeBufferPointer { values in
                expectEncoded(
                    arena.encodeSetConstantBuffer(
                        stage: .vertex,
                        index: 2,
                        dwords: values
                    ),
                    start: 17,
                    count: 6,
                    "constant buffer"
                )
            }
            expectDWords(
                arena,
                [
                    0x0006_0006, 16, 32, 7, 8, 4, 8,
                    0x0009_0501, 9,
                    0, 0, 0, 10,
                    8, 1, 1, 11,
                    0x0005_000c, 0, 2, 0x10, 0x20, 0x30,
                ],
                "vertex/constant layouts"
            )

            let invalid = [
                VirGLVertexBuffer(stride: 4, offset: 0, resourceHandle: 0),
            ]
            invalid.withUnsafeBufferPointer { values in
                expectRejected(
                    arena.encodeSetVertexBuffers(values),
                    .invalidResourceHandle,
                    "zero vertex resource"
                )
            }
        }
    }

    private static func testInlineResourceWrite() {
        withArena(capacity: 32) { arena, _ in
            let box = requireTextureBox(
                x: 4,
                y: 0,
                z: 0,
                width: 5,
                height: 1,
                depth: 1
            )
            let layout = requireBlockLayout(
                blockWidth: 1,
                blockHeight: 1,
                bytesPerBlock: 1
            )
            let bytes: [UInt8] = [1, 2, 3, 4, 5]
            bytes.withUnsafeBytes { data in
                expectEncoded(
                    arena.encodeResourceInlineWrite(
                        resourceHandle: 0x55,
                        level: 0,
                        usage: 0x123,
                        stride: 0,
                        layerStride: 0,
                        box: box,
                        blockLayout: layout,
                        bytes: data
                    ),
                    start: 0,
                    count: 14,
                    "RESOURCE_INLINE_WRITE"
                )
            }
            expectDWords(
                arena,
                [
                    0x000d_0009,
                    0x55, 0, 0x123, 0, 0,
                    4, 0, 0, 5, 1, 1,
                    0x0403_0201, 0x0000_0005,
                ],
                "inline-write layout and byte padding"
            )

            let before = arena.dwordCount
            let shortBytes: [UInt8] = [1, 2, 3, 4]
            shortBytes.withUnsafeBytes { data in
                expectRejected(
                    arena.encodeResourceInlineWrite(
                        resourceHandle: 0x55,
                        level: 0,
                        usage: 0,
                        stride: 0,
                        layerStride: 0,
                        box: box,
                        blockLayout: layout,
                        bytes: data
                    ),
                    .invalidDataSize,
                    "inline-write short data"
                )
            }
            expect(
                arena.dwordCount == before,
                "invalid inline write advanced cursor"
            )

            let paddedBox = requireTextureBox(
                x: 0,
                y: 0,
                z: 0,
                width: 2,
                height: 2,
                depth: 1
            )
            let paddedData = Array(repeating: UInt8(0xaa), count: 8)
            paddedData.withUnsafeBytes { data in
                expectEncoded(
                    arena.encodeResourceInlineWrite(
                        resourceHandle: 1,
                        level: 0,
                        usage: 0,
                        stride: 4,
                        layerStride: 8,
                        box: paddedBox,
                        blockLayout: layout,
                        bytes: data
                    ),
                    start: 14,
                    count: 14,
                    "inline-write padded rows"
                )
            }
        }
    }

    private static func testShaderObjectFragments() {
        withArena(capacity: 32) { arena, _ in
            let first: [UInt8] = [0x54, 0x47, 0x53, 0x49]
            first.withUnsafeBytes { bytes in
                expectEncoded(
                    arena.encodeCreateShaderObjectFragment(
                        handle: 0x40,
                        stage: .vertex,
                        tokenCount: 12,
                        totalByteCount: 7,
                        fragmentOffset: 0,
                        bytes: bytes
                    ),
                    start: 0,
                    count: 7,
                    "first shader fragment"
                )
            }
            let continuation: [UInt8] = [0xaa, 0xbb, 0]
            continuation.withUnsafeBytes { bytes in
                expectEncoded(
                    arena.encodeCreateShaderObjectFragment(
                        handle: 0x40,
                        stage: .vertex,
                        tokenCount: 12,
                        totalByteCount: 7,
                        fragmentOffset: 4,
                        bytes: bytes
                    ),
                    start: 7,
                    count: 7,
                    "shader continuation"
                )
            }
            expectDWords(
                arena,
                [
                    0x0006_0401, 0x40, 0, 7, 12, 0, 0x4953_4754,
                    0x0006_0401, 0x40, 0, 0x8000_0004, 12, 0,
                    0x0000_bbaa,
                ],
                "shader fragment framing"
            )

            let before = arena.dwordCount
            continuation.withUnsafeBytes { bytes in
                expectRejected(
                    arena.encodeCreateShaderObjectFragment(
                        handle: 0x40,
                        stage: .vertex,
                        tokenCount: 12,
                        totalByteCount: 6,
                        fragmentOffset: 4,
                        bytes: bytes
                    ),
                    .invalidShaderFragment,
                    "shader fragment beyond total"
                )
            }
            expect(arena.dwordCount == before, "bad shader advanced cursor")

            let unterminated: [UInt8] = [0xaa, 0xbb, 0xcc]
            unterminated.withUnsafeBytes { bytes in
                expectRejected(
                    arena.encodeCreateShaderObjectFragment(
                        handle: 0x41,
                        stage: .fragment,
                        tokenCount: 8,
                        totalByteCount: 3,
                        fragmentOffset: 0,
                        bytes: bytes
                    ),
                    .invalidShaderFragment,
                    "unterminated final shader fragment"
                )
            }
        }
    }

    private static func testShaderBindAndLinkPackets() {
        withArena(capacity: 32) { arena, _ in
            let capabilities = fullCapabilities()
            expectEncoded(
                arena.encodeBindShader(
                    capabilities: capabilities,
                    stage: .vertex,
                    handle: 0x11
                ),
                start: 0,
                count: 3,
                "BIND_SHADER"
            )
            expectEncoded(
                arena.encodeBindShader(
                    capabilities: capabilities,
                    stage: .fragment,
                    handle: nil
                ),
                start: 3,
                count: 3,
                "BIND_SHADER unbind"
            )
            let program = requireProgram(vertex: 0x11, fragment: 0x22)
            expectEncoded(
                arena.encodeLinkShader(
                    capabilities: capabilities,
                    program: program
                ),
                start: 6,
                count: 7,
                "LINK_SHADER"
            )
            expectDWords(
                arena,
                [
                    0x0002_001f, 0x11, 0,
                    0x0002_001f, 0, 1,
                    0x0006_0034, 0x11, 0x22, 0, 0, 0, 0,
                ],
                "shader bind/link layouts"
            )

            let noSSO = VirGLContextCapabilities(
                capsetID: 2,
                capsetVersion: 2,
                capabilityBits: VirGLContextCapabilities.clearTextureBit,
                capabilityBitsV2: 0
            )
            expectRejected(
                arena.encodeLinkShader(capabilities: noSSO, program: program),
                .unsupportedCapability,
                "LINK_SHADER without SSO"
            )
            let future = VirGLContextCapabilities(
                capsetID: 2,
                capsetVersion: 3,
                capabilityBits: UInt32.max,
                capabilityBitsV2: UInt32.max
            )
            expectRejected(
                arena.encodeBindShader(
                    capabilities: future,
                    stage: .vertex,
                    handle: 1
                ),
                .unsupportedCapability,
                "unknown VirGL2 version"
            )
            expect(
                VirGLShaderProgramHandles(vertex: 1, fragment: 1, compute: 1)
                    == nil,
                "mixed graphics/compute program was accepted"
            )
            expect(
                VirGLShaderProgramHandles(
                    vertex: 1,
                    fragment: 2,
                    tessellationControl: 3
                ) == nil,
                "TCS without TES was accepted"
            )
        }
    }

    private static func testDrawPacketAndAtomicRejections() {
        withArena(capacity: 32) { arena, _ in
            let draw = VirGLDrawDescriptor(
                start: 2,
                count: 6,
                topology: .triangles,
                indexed: true,
                instanceCount: 3,
                indexBias: -2,
                startInstance: 4,
                primitiveRestartEnabled: true,
                restartIndex: 0xffff,
                minimumIndex: 1,
                maximumIndex: 99,
                countFromStreamOutputHandle: 0x88
            )
            expectEncoded(
                arena.encodeDrawVBO(draw),
                start: 0,
                count: 13,
                "DRAW_VBO"
            )
            expectDWords(
                arena,
                [
                    0x000c_0008,
                    2, 6, 4, 1, 3, 0xffff_fffe,
                    4, 1, 0xffff, 1, 99, 0x88,
                ],
                "DRAW_VBO layout"
            )

            let before = arena.dwordCount
            let invalid = VirGLDrawDescriptor(
                start: 0,
                count: 1,
                topology: .points,
                indexed: false,
                instanceCount: 1,
                indexBias: 0,
                startInstance: 0,
                primitiveRestartEnabled: false,
                restartIndex: 0,
                minimumIndex: 0,
                maximumIndex: 0,
                countFromStreamOutputHandle: 0
            )
            expectRejected(
                arena.encodeDrawVBO(invalid),
                .invalidObjectHandle,
                "zero stream-output handle"
            )
            expect(arena.dwordCount == before, "bad draw advanced cursor")
            arena.reset()
            expect(arena.dwordCount == 0, "arena reset did not rewind")
            expect(arena.dword(at: 0) == nil, "reset exposed stale dword")
        }
    }

    private static func fullCapabilities() -> VirGLContextCapabilities {
        VirGLContextCapabilities(
            capsetID: 2,
            capsetVersion: 2,
            capabilityBits: VirGLContextCapabilities.clearTextureBit,
            capabilityBitsV2:
                VirGLContextCapabilities.separateShaderObjectsBit
        )
    }

    private static func requireClearValue(
        bufferMask: UInt32,
        colors: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0),
        depth: UInt64 = 0,
        stencil: UInt32 = 0
    ) -> VirGLClearValue {
        guard let result = VirGLClearValue(
            bufferMask: bufferMask,
            color0Bits: colors.0,
            color1Bits: colors.1,
            color2Bits: colors.2,
            color3Bits: colors.3,
            depthBits: depth,
            stencil: stencil
        ) else {
            fatalError("valid clear value rejected")
        }
        return result
    }

    private static func requireScissor(
        _ minimumX: UInt32,
        _ minimumY: UInt32,
        _ maximumX: UInt32,
        _ maximumY: UInt32
    ) -> VirGLScissorRectangle {
        guard let result = VirGLScissorRectangle(
            minimumX: minimumX,
            minimumY: minimumY,
            maximumX: maximumX,
            maximumY: maximumY
        ) else {
            fatalError("valid scissor rejected")
        }
        return result
    }

    private static func requireTextureBox(
        x: UInt32,
        y: UInt32,
        z: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32
    ) -> VirGLTextureBox {
        guard let result = VirGLTextureBox(
            x: x,
            y: y,
            z: z,
            width: width,
            height: height,
            depth: depth
        ) else {
            fatalError("valid texture box rejected")
        }
        return result
    }

    private static func requireBlockLayout(
        blockWidth: UInt32,
        blockHeight: UInt32,
        bytesPerBlock: UInt32
    ) -> VirGLTransferBlockLayout {
        guard let result = VirGLTransferBlockLayout(
            blockWidth: blockWidth,
            blockHeight: blockHeight,
            bytesPerBlock: bytesPerBlock
        ) else {
            fatalError("valid transfer block layout rejected")
        }
        return result
    }

    private static func requireBlendGlobal(
        flags: UInt32,
        logicOperation: UInt8
    ) -> VirGLBlendGlobalState {
        guard let result = VirGLBlendGlobalState(
            flags: flags,
            logicOperation: logicOperation
        ) else {
            fatalError("valid blend global state rejected")
        }
        return result
    }

    private static func requireBlendTarget() -> VirGLBlendTargetState {
        guard let result = VirGLBlendTargetState(
            blendEnabled: true,
            rgbFunction: 2,
            rgbSourceFactor: 3,
            rgbDestinationFactor: 4,
            alphaFunction: 5,
            alphaSourceFactor: 6,
            alphaDestinationFactor: 7,
            colorMask: 0xf
        ) else {
            fatalError("valid blend target rejected")
        }
        return result
    }

    private static func requireDSA(
        depthAlpha: UInt32,
        front: UInt32,
        back: UInt32,
        alpha: UInt32
    ) -> VirGLDepthStencilAlphaState {
        guard let result = VirGLDepthStencilAlphaState(
            depthAlphaDWord: depthAlpha,
            frontStencilDWord: front,
            backStencilDWord: back,
            alphaReferenceBits: alpha
        ) else {
            fatalError("valid DSA state rejected")
        }
        return result
    }

    private static func requireProgram(
        vertex: UInt32,
        fragment: UInt32
    ) -> VirGLShaderProgramHandles {
        guard let result = VirGLShaderProgramHandles(
            vertex: vertex,
            fragment: fragment
        ) else {
            fatalError("valid graphics program rejected")
        }
        return result
    }

    private static func withArena(
        capacity: Int,
        _ body: (
            inout VirGLDWordArena,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        let storage = UnsafeMutableBufferPointer<UInt32>.allocate(
            capacity: capacity
        )
        storage.initialize(repeating: UInt32(0xa5a5_a5a5).littleEndian)
        defer {
            storage.deinitialize()
            storage.deallocate()
        }
        guard var arena = VirGLDWordArena(storage: storage) else {
            fatalError("valid arena rejected")
        }
        body(&arena, storage)
    }

    private static func expectEncoded(
        _ result: VirGLEncodeResult,
        start: Int,
        count: Int,
        _ message: String
    ) {
        expect(
            result == .encoded(startDWord: start, dwordCount: count),
            message
        )
    }

    private static func expectRejected(
        _ result: VirGLEncodeResult,
        _ rejection: VirGLEncodeRejection,
        _ message: String
    ) {
        expect(result == .rejected(rejection), message)
    }

    private static func expectDWords(
        _ arena: VirGLDWordArena,
        _ expected: [UInt32],
        _ message: String
    ) {
        expect(arena.dwordCount == expected.count, "\(message): count")
        var index = 0
        while index < expected.count {
            expect(
                arena.dword(at: index) == expected[index],
                "\(message): dword \(index)"
            )
            index += 1
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
