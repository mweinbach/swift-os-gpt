@main
struct VirGLIRCompilerTests {
    static func main() {
        validatesResourceContracts()
        initializesPipelineTransactionally()
        lowersGPUClearWithoutShaderPipeline()
        lowersTransformedScissoredSolidQuads()
        lowersAnalyticRoundedQuads()
        validatesRoundedTransformsAndRollback()
        rejectsUnsupportedDrawsBeforeEncoding()
        rejectsInvalidPassContracts()
        rejectsShortArenaWithoutPartialPublication()
        print("VirGL IR compiler host tests: 9 groups passed")
    }

    private static func validatesResourceContracts() {
        expect(
            VirGLIRUnitQuadVertexLayout.r32g32Float.format == 29,
            "vec2 vertex format"
        )
        expect(
            VirGLIRUnitQuadVertexLayout.r32g32b32a32Float.stride == 16,
            "vec4 vertex stride"
        )
        expect(
            VirGLIRPipelineHandles(
                vertexShader: 1,
                fragmentShader: 1,
                roundedVertexShader: 8,
                roundedFragmentShader: 9,
                vertexElements: 3,
                rasterizer: 4,
                depthStencilAlpha: 5,
                copyBlend: 6,
                sourceOverBlend: 7,
                unitQuadVertexResource: 8
            ) == nil,
            "duplicate object handles accepted"
        )
        expect(
            VirGLIRPipelineHandles(
                vertexShader: 1,
                fragmentShader: 2,
                roundedVertexShader: 8,
                roundedFragmentShader: 2,
                vertexElements: 3,
                rasterizer: 4,
                depthStencilAlpha: 5,
                copyBlend: 6,
                sourceOverBlend: 7,
                unitQuadVertexResource: 0x80
            ) == nil,
            "rounded shader collision accepted"
        )
        expect(
            VirGLIRPipelineHandles(
                vertexShader: 1,
                fragmentShader: 2,
                roundedVertexShader: 8,
                roundedFragmentShader: nil,
                vertexElements: 3,
                rasterizer: 4,
                depthStencilAlpha: 5,
                copyBlend: 6,
                sourceOverBlend: 7,
                unitQuadVertexResource: 0x80
            ) == nil,
            "incomplete rounded shader pair accepted"
        )
        expect(
            VirGLIRPipelineHandles(
                vertexShader: 1,
                fragmentShader: 2,
                vertexElements: 3,
                rasterizer: 4,
                depthStencilAlpha: 5,
                copyBlend: 6,
                sourceOverBlend: 7,
                unitQuadVertexResource: 0
            ) == nil,
            "zero vertex resource accepted"
        )
        expect(
            VirGLIRRenderTarget(
                id: targetID(1),
                surfaceHandle: 0,
                extent: extent(10, 10),
                format: .bgra8UNormSRGB,
                virglSurfaceFormat: VirGLIRRenderTarget.b8g8r8a8SRGBFormat
            ) == nil,
            "zero surface handle accepted"
        )

        withArena(capacity: 256) { arena, _ in
            var compiler = makeCompiler(explicitShaderBinding: false)
            expect(
                compiler.initializePipeline(into: &arena)
                    == .rejected(.unsupportedShaderBinding),
                "legacy capset initialized shaders"
            )
            expect(arena.dwordCount == 0, "unsupported init advanced arena")
            expect(!compiler.isPipelineInitialized, "failed init changed state")
        }
    }

    private static func initializesPipelineTransactionally() {
        var requiredDWords = 0
        withArena(capacity: 1024) { arena, _ in
            var compiler = makeCompiler(supportsShaderLink: true)
            let result = compiler.initializePipeline(into: &arena)
            guard case .initialized(let start, let count) = result else {
                fatalError("pipeline initialization rejected: \(result)")
            }
            expect(start == 0, "pipeline init start")
            expect(count == arena.dwordCount, "pipeline init count")
            expect(compiler.isPipelineInitialized, "pipeline init state")
            requiredDWords = count

            let starts = packetStarts(arena)
            expect(starts.count == 11, "pipeline packet count")
            expect(packetCommand(arena, starts[0]) == 1, "vertex element create")
            expect(packetObjectType(arena, starts[0]) == 5, "vertex element type")
            expect(packetObjectType(arena, starts[1]) == 2, "rasterizer type")
            expect(packetObjectType(arena, starts[2]) == 3, "DSA type")
            expect(packetObjectType(arena, starts[3]) == 1, "copy blend type")
            expect(packetObjectType(arena, starts[4]) == 1, "source blend type")
            expect(packetObjectType(arena, starts[5]) == 4, "vertex shader type")
            expect(packetObjectType(arena, starts[6]) == 4, "fragment shader type")
            expect(packetObjectType(arena, starts[7]) == 4, "rounded vertex type")
            expect(packetObjectType(arena, starts[8]) == 4, "rounded fragment type")
            expect(packetCommand(arena, starts[9]) == 52, "solid shader link")
            expect(packetCommand(arena, starts[10]) == 52, "rounded shader link")

            expect(arena.dword(at: starts[5] + 2) == 0, "vertex shader stage")
            expect(arena.dword(at: starts[6] + 2) == 1, "fragment shader stage")
            expect(arena.dword(at: starts[7] + 2) == 0, "rounded vertex stage")
            expect(arena.dword(at: starts[8] + 2) == 1, "rounded fragment stage")
            expect(arena.dword(at: starts[5] + 4) == 256, "shader token bound")
            expect(shaderTerminalByte(arena, start: starts[5]) == 0, "vertex shader NUL")
            expect(shaderTerminalByte(arena, start: starts[6]) == 0, "fragment shader NUL")
            expect(
                shaderTerminalByte(arena, start: starts[7]) == 0,
                "rounded vertex shader NUL"
            )
            expect(
                shaderTerminalByte(arena, start: starts[8]) == 0,
                "rounded fragment shader NUL"
            )
            expect(arena.dword(at: starts[9] + 1) == 1, "solid link vertex")
            expect(arena.dword(at: starts[9] + 2) == 2, "solid link fragment")
            expect(arena.dword(at: starts[10] + 1) == 8, "rounded link vertex")
            expect(arena.dword(at: starts[10] + 2) == 9, "rounded link fragment")

            expect(
                compiler.initializePipeline(into: &arena)
                    == .rejected(.alreadyInitialized),
                "double pipeline initialization"
            )
            expect(arena.dwordCount == count, "double init advanced arena")
        }

        withArena(capacity: requiredDWords - 1) { arena, storage in
            var compiler = makeCompiler(supportsShaderLink: true)
            expect(
                compiler.initializePipeline(into: &arena)
                    == .rejected(
                        .capacityExhausted(
                            requiredDWords: requiredDWords,
                            availableDWords: requiredDWords - 1
                        )
                    ),
                "short initialization arena rejection"
            )
            expect(arena.dwordCount == 0, "short init advanced cursor")
            expect(storage[0] == 0xa5a5_a5a5, "short init touched storage")
        }
    }

    private static func lowersGPUClearWithoutShaderPipeline() {
        withArena(capacity: 64) { arena, _ in
            var compiler = makeCompiler()
            let color = requireColor(
                red: .max,
                green: 0,
                blue: 0x8000,
                alpha: .max
            )
            let buffer = commandBuffer(
                id: 1,
                commands: [
                    .beginRenderPass(
                        pass(width: 320, height: 200, load: .clear(color))
                    ),
                    .endRenderPass,
                ]
            )
            let result = compiler.lower(
                buffer,
                renderTarget: renderTarget(width: 320, height: 200),
                into: &arena
            )
            expect(
                result == .lowered(
                    startDWord: 0,
                    dwordCount: 25,
                    renderPassCount: 1,
                    drawCount: 0
                ),
                "clear lowering result"
            )
            expect(!compiler.isPipelineInitialized, "clear initialized pipeline")

            expect(arena.dword(at: 0) == 0x0003_0005, "framebuffer header")
            expect(arena.dword(at: 1) == 1, "framebuffer color count")
            expect(arena.dword(at: 3) == 0x40, "framebuffer surface")
            expect(arena.dword(at: 4) == 0x0007_0004, "viewport header")
            expect(
                Float(bitPattern: requireDWord(arena, 6)) == 160,
                "viewport x scale"
            )
            expect(
                Float(bitPattern: requireDWord(arena, 7)) == 100,
                "viewport y scale"
            )
            expect(arena.dword(at: 12) == 0x0003_000f, "full scissor header")
            expect(arena.dword(at: 14) == 0, "full scissor minimum")
            expect(
                arena.dword(at: 15) == UInt32(320) | (UInt32(200) << 16),
                "full scissor maximum"
            )
            expect(arena.dword(at: 16) == 0x0008_0007, "clear header")
            expect(arena.dword(at: 17) == 4, "color clear mask")
            expect(
                Float(bitPattern: requireDWord(arena, 18)) == 1,
                "clear red"
            )
            expect(
                Float(bitPattern: requireDWord(arena, 21)) == 1,
                "clear alpha"
            )
        }
    }

    private static func lowersTransformedScissoredSolidQuads() {
        withArena(capacity: 512) { arena, _ in
            var compiler = makeCompiler(roundedPipeline: false)
            _ = compiler.initializePipeline(into: &arena)
            arena.reset()

            let first = requireQuad(
                x: 10,
                y: 20,
                width: 30,
                height: 40,
                color: requireColor(
                    red: 0x8000,
                    green: 0x4000,
                    blue: 0,
                    alpha: .max
                ),
                blend: .sourceOver
            )
            let second = requireQuad(
                x: 1,
                y: 2,
                width: 3,
                height: 4,
                color: .opaqueWhite,
                blend: .copy
            )
            let translated = GPUTransform2D.translation(
                x: fixed(2),
                y: fixed(3)
            )
            let buffer = commandBuffer(
                id: 2,
                commands: [
                    .beginRenderPass(pass(width: 200, height: 100)),
                    .setScissor(
                        .rectangle(scissor(x: 5, y: 10, width: 20, height: 30))
                    ),
                    .setTransform(translated),
                    .drawQuad(first),
                    .drawQuad(second),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    buffer,
                    renderTarget: renderTarget(width: 200, height: 100),
                    into: &arena
                ) == .lowered(
                    startDWord: 0,
                    dwordCount: 104,
                    renderPassCount: 1,
                    drawCount: 2
                ),
                "solid quad lowering result"
            )

            expect(arena.dword(at: 16) == 0x0003_000f, "custom scissor header")
            expect(
                arena.dword(at: 18) == UInt32(5) | (UInt32(60) << 16),
                "top-left scissor minimum conversion"
            )
            expect(
                arena.dword(at: 19) == UInt32(25) | (UInt32(90) << 16),
                "top-left scissor maximum conversion"
            )
            expect(arena.dword(at: 20) == 0x0001_0202, "rasterizer bind")
            expect(arena.dword(at: 26) == 0x0002_001f, "vertex shader bind")
            expect(arena.dword(at: 29) == 0x0002_001f, "fragment shader bind")
            expect(arena.dword(at: 32) == 0x0003_0006, "vertex buffer packet")
            expect(arena.dword(at: 34) == 0, "unit quad buffer offset")
            expect(arena.dword(at: 35) == 0x80, "unit quad resource")
            expect(arena.dword(at: 36) == 0x0001_0102, "source-over bind")
            expect(arena.dword(at: 37) == 7, "source-over handle")
            expect(arena.dword(at: 38) == 0x0012_000c, "constant packet")

            expectClose(floatDWord(arena, 41), 0.3, "quad basis x")
            expectClose(floatDWord(arena, 42), 0, "quad basis xy")
            expectClose(floatDWord(arena, 45), 0, "quad basis yx")
            expectClose(floatDWord(arena, 46), -0.8, "quad basis y")
            expectClose(floatDWord(arena, 49), -0.88, "quad origin x")
            expectClose(floatDWord(arena, 50), 0.54, "quad origin y")
            expectClose(floatDWord(arena, 53), Float(0x8000) / 65535, "quad red")
            expectClose(floatDWord(arena, 56), 1, "quad alpha")

            expect(arena.dword(at: 57) == 0x000c_0008, "first draw header")
            expect(arena.dword(at: 59) == 6, "triangle vertex count")
            expect(arena.dword(at: 60) == 4, "triangle topology")
            expect(arena.dword(at: 70) == 0x0001_0102, "copy blend bind")
            expect(arena.dword(at: 71) == 6, "copy blend handle")
            expect(arena.dword(at: 91) == 0x000c_0008, "second draw header")
        }
    }

    private static func lowersAnalyticRoundedQuads() {
        withArena(capacity: 1024) { arena, _ in
            var compiler = makeCompiler()
            _ = compiler.initializePipeline(into: &arena)
            arena.reset()

            let rounded = requireRoundedQuad(
                x: 10,
                y: 20,
                width: 20,
                height: 12,
                topLeft: 1,
                topRight: 2,
                bottomRight: 3,
                bottomLeft: 4,
                color: requireColor(
                    red: 0x8000,
                    green: 0x4000,
                    blue: 0,
                    alpha: .max
                )
            )
            let buffer = commandBuffer(
                id: 3,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawQuad(rounded),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    buffer,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .lowered(
                    startDWord: 0,
                    dwordCount: 77,
                    renderPassCount: 1,
                    drawCount: 1
                ),
                "rounded quad lowering result"
            )

            expect(arena.dword(at: 22) == 0x0002_001f, "rounded VS bind")
            expect(arena.dword(at: 23) == 8, "rounded VS handle")
            expect(arena.dword(at: 25) == 0x0002_001f, "rounded FS bind")
            expect(arena.dword(at: 26) == 9, "rounded FS handle")
            expect(arena.dword(at: 32) == 0x0001_0102, "rounded blend bind")
            expect(arena.dword(at: 33) == 7, "rounded source-over handle")
            expect(arena.dword(at: 34) == 0x0012_000c, "rounded VS constants")

            // Identity maps the 20x12 local rect at (10,20) to a 22x14
            // screen AABB padded by one target pixel on every side.
            expectClose(floatDWord(arena, 37), 0.44, "rounded clip basis x")
            expectClose(floatDWord(arena, 38), 0, "rounded clip basis xy")
            expectClose(floatDWord(arena, 39), 22, "rounded local basis x")
            expectClose(floatDWord(arena, 40), 0, "rounded local basis xy")
            expectClose(floatDWord(arena, 41), 0, "rounded clip basis yx")
            expectClose(floatDWord(arena, 42), -0.28, "rounded clip basis y")
            expectClose(floatDWord(arena, 43), 0, "rounded local basis yx")
            expectClose(floatDWord(arena, 44), 14, "rounded local basis y")
            expectClose(floatDWord(arena, 45), -0.82, "rounded clip origin x")
            expectClose(floatDWord(arena, 46), 0.62, "rounded clip origin y")
            expectClose(floatDWord(arena, 47), -1, "rounded local origin x")
            expectClose(floatDWord(arena, 48), -1, "rounded local origin y")

            expect(arena.dword(at: 53) == 0x000a_000c, "rounded FS constants")
            expect(arena.dword(at: 54) == 1, "fragment constant stage")
            expectClose(floatDWord(arena, 56), 10, "rounded half width")
            expectClose(floatDWord(arena, 57), 6, "rounded half height")
            expectClose(floatDWord(arena, 60), 1, "top-left radius")
            expectClose(floatDWord(arena, 61), 2, "top-right radius")
            expectClose(floatDWord(arena, 62), 3, "bottom-right radius")
            expectClose(floatDWord(arena, 63), 4, "bottom-left radius")
            expect(arena.dword(at: 64) == 0x000c_0008, "rounded draw")
        }

        withArena(capacity: 1024) { arena, _ in
            var compiler = makeCompiler()
            _ = compiler.initializePipeline(into: &arena)
            arena.reset()
            let solid = requireQuad()
            let rounded = requireRoundedQuad()
            let buffer = commandBuffer(
                id: 4,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawQuad(solid),
                    .drawQuad(rounded),
                    .drawQuad(rounded),
                    .drawQuad(solid),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    buffer,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .lowered(
                    startDWord: 0,
                    dwordCount: 196,
                    renderPassCount: 1,
                    drawCount: 4
                ),
                "solid/rounded shader switching"
            )
            var shaderHandles: [UInt32] = []
            for start in packetStarts(arena) where packetCommand(arena, start) == 31 {
                shaderHandles.append(requireDWord(arena, start + 1))
            }
            expect(
                shaderHandles == [1, 2, 8, 9, 1, 2],
                "redundant or missing shader-pair bind"
            )
        }
    }

    private static func validatesRoundedTransformsAndRollback() {
        withArena(capacity: 1024) { arena, _ in
            var compiler = makeCompiler()
            _ = compiler.initializePipeline(into: &arena)
            arena.reset()
            let rotation = transform(
                m11: 0,
                m12: 1,
                m21: -1,
                m22: 0,
                translationX: 100,
                translationY: 0
            )
            let buffer = commandBuffer(
                id: 5,
                commands: [
                    .beginRenderPass(pass(width: 200, height: 200)),
                    .setTransform(rotation),
                    .drawQuad(
                        requireRoundedQuad(
                            x: 10,
                            y: 20,
                            width: 20,
                            height: 12
                        )
                    ),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    buffer,
                    renderTarget: renderTarget(width: 200, height: 200),
                    into: &arena
                ) == .lowered(
                    startDWord: 0,
                    dwordCount: 77,
                    renderPassCount: 1,
                    drawCount: 1
                ),
                "rotated rounded quad"
            )
            expectClose(floatDWord(arena, 37), 0.14, "rotated clip basis x")
            expectClose(floatDWord(arena, 39), 0, "rotated local x basis x")
            expectClose(floatDWord(arena, 40), -14, "rotated local x basis y")
            expectClose(floatDWord(arena, 42), -0.22, "rotated clip basis y")
            expectClose(floatDWord(arena, 43), 22, "rotated local y basis x")
            expectClose(floatDWord(arena, 44), 0, "rotated local y basis y")
            expectClose(floatDWord(arena, 45), -0.33, "rotated clip origin x")
            expectClose(floatDWord(arena, 46), 0.91, "rotated clip origin y")
            expectClose(floatDWord(arena, 47), -1, "rotated local origin x")
            expectClose(floatDWord(arena, 48), 13, "rotated local origin y")
        }

        var compiler = makeCompiler()
        withArena(capacity: 1024) { arena, _ in
            _ = compiler.initializePipeline(into: &arena)
        }
        withArena(capacity: 256) { arena, _ in
            appendTestClear(to: &arena)
            let originalCount = arena.dwordCount
            let originalPrefix = (0..<originalCount).map {
                requireDWord(arena, $0)
            }

            let singular = commandBuffer(
                id: 6,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .setTransform(
                        transform(
                            m11: 1,
                            m12: 2,
                            m21: 0,
                            m22: 0
                        )
                    ),
                    .drawQuad(requireRoundedQuad()),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    singular,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(.roundedTransformSingular(commandIndex: 2)),
                "singular rounded transform"
            )

            let illConditioned = commandBuffer(
                id: 7,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .setTransform(
                        transform(
                            m11: 1,
                            m12: 0,
                            m21: 4096,
                            m22: 1
                        )
                    ),
                    .drawQuad(requireRoundedQuad()),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    illConditioned,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(
                    .roundedTransformIllConditioned(commandIndex: 2)
                ),
                "ill-conditioned rounded transform"
            )

            let copy = commandBuffer(
                id: 8,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawQuad(requireRoundedQuad(blend: .copy)),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    copy,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(.roundedCopyUnsupported(commandIndex: 1)),
                "rounded copy blend"
            )
            expect(arena.dwordCount == originalCount, "rounded rejection cursor")
            expect(
                (0..<originalCount).map { requireDWord(arena, $0) }
                    == originalPrefix,
                "rounded rejection changed prefix"
            )
        }

        withArena(capacity: 76) { arena, storage in
            let rounded = commandBuffer(
                id: 9,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawQuad(requireRoundedQuad()),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    rounded,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(
                    .capacityExhausted(
                        requiredDWords: 77,
                        availableDWords: 76
                    )
                ),
                "short rounded arena"
            )
            expect(arena.dwordCount == 0, "short rounded cursor")
            expect(storage[0] == 0xa5a5_a5a5, "short rounded touched storage")
        }

        withArena(capacity: 512) { arena, _ in
            var solidOnly = makeCompiler(roundedPipeline: false)
            _ = solidOnly.initializePipeline(into: &arena)
            arena.reset()
            let rounded = commandBuffer(
                id: 10,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawQuad(requireRoundedQuad()),
                    .endRenderPass,
                ]
            )
            expect(
                solidOnly.lower(
                    rounded,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(
                    .roundedPipelineUnavailable(commandIndex: 1)
                ),
                "solid-only rounded pipeline"
            )
            expect(arena.dwordCount == 0, "solid-only rounded cursor")
        }
    }

    private static func rejectsUnsupportedDrawsBeforeEncoding() {
        withArena(capacity: 256) { arena, _ in
            var compiler = makeCompiler(roundedPipeline: false)
            _ = compiler.initializePipeline(into: &arena)
            arena.reset()
            appendTestClear(to: &arena)
            let originalCount = arena.dwordCount
            let originalPrefix = (0..<originalCount).map {
                requireDWord(arena, $0)
            }

            let glyph = commandBuffer(
                id: 3,
                commands: [
                    .beginRenderPass(pass(width: 100, height: 100)),
                    .drawGlyph(requireGlyph()),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    glyph,
                    renderTarget: renderTarget(width: 100, height: 100),
                    into: &arena
                ) == .rejected(.glyphAtlasUnsupported(commandIndex: 1)),
                "glyph exact rejection"
            )
            expect(arena.dwordCount == originalCount, "glyph rejection cursor")
            expect(
                (0..<originalCount).map { requireDWord(arena, $0) }
                    == originalPrefix,
                "glyph rejection changed prefix"
            )
        }

        withArena(capacity: 128) { arena, _ in
            var compiler = makeCompiler()
            let solid = commandBuffer(
                id: 5,
                commands: [
                    .beginRenderPass(pass(width: 10, height: 10)),
                    .drawQuad(requireQuad()),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    solid,
                    renderTarget: renderTarget(width: 10, height: 10),
                    into: &arena
                ) == .rejected(.pipelineNotInitialized(commandIndex: 1)),
                "uninitialized quad exact rejection"
            )
            expect(arena.dwordCount == 0, "uninitialized quad advanced arena")
        }
    }

    private static func rejectsInvalidPassContracts() {
        withArena(capacity: 128) { arena, _ in
            var compiler = makeCompiler()
            let base = commandBuffer(
                id: 6,
                commands: [
                    .beginRenderPass(pass(width: 20, height: 10)),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(
                        id: 2,
                        width: 20,
                        height: 10
                    ),
                    into: &arena
                ) == .rejected(.renderTargetMismatch(commandIndex: 0)),
                "target identity mismatch"
            )
            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(width: 21, height: 10),
                    into: &arena
                ) == .rejected(.renderTargetExtentMismatch(commandIndex: 0)),
                "target extent mismatch"
            )
            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(
                        width: 20,
                        height: 10,
                        format: .rgba8UNormSRGB
                    ),
                    into: &arena
                ) == .rejected(.renderTargetFormatMismatch(commandIndex: 0)),
                "target format mismatch"
            )

            let unsupportedFormat = commandBuffer(
                id: 7,
                commands: [
                    .beginRenderPass(
                        pass(
                            width: 20,
                            height: 10,
                            format: .rgba8UNormSRGB
                        )
                    ),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    unsupportedFormat,
                    renderTarget: renderTarget(
                        width: 20,
                        height: 10,
                        format: .rgba8UNormSRGB
                    ),
                    into: &arena
                ) == .rejected(
                    .unsupportedRenderTargetFormat(commandIndex: 0)
                ),
                "unsupported render target format"
            )

            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(
                        width: 20,
                        height: 10,
                        virglSurfaceFormat: 2
                    ),
                    into: &arena
                ) == .rejected(
                    .virglSurfaceFormatMismatch(
                        commandIndex: 0,
                        expected: 100,
                        actual: 2
                    )
                ),
                "linear UNORM surface accepted for sRGB IR"
            )

            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(
                        width: 20,
                        height: 10,
                        surfaceHandle: 1
                    ),
                    into: &arena
                ) == .rejected(.surfaceHandleCollision(commandIndex: 0)),
                "surface/pipeline handle collision accepted"
            )
            expect(
                compiler.lower(
                    base,
                    renderTarget: renderTarget(
                        width: 20,
                        height: 10,
                        surfaceHandle: 8
                    ),
                    into: &arena
                ) == .rejected(.surfaceHandleCollision(commandIndex: 0)),
                "surface/rounded-shader handle collision accepted"
            )

            let discard = commandBuffer(
                id: 8,
                commands: [
                    .beginRenderPass(
                        pass(
                            width: 20,
                            height: 10,
                            store: .discard
                        )
                    ),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    discard,
                    renderTarget: renderTarget(width: 20, height: 10),
                    into: &arena
                ) == .rejected(.discardStoreUnsupported(commandIndex: 0)),
                "discard store rejection"
            )

            let oversized = commandBuffer(
                id: 9,
                commands: [
                    .beginRenderPass(pass(width: 65_536, height: 1)),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    oversized,
                    renderTarget: renderTarget(width: 65_536, height: 1),
                    into: &arena
                ) == .rejected(.renderTargetTooLarge(commandIndex: 0)),
                "16-bit scissor limit"
            )
            expect(arena.dwordCount == 0, "invalid pass advanced arena")
        }
    }

    private static func rejectsShortArenaWithoutPartialPublication() {
        withArena(capacity: 24) { arena, storage in
            var compiler = makeCompiler()
            let buffer = commandBuffer(
                id: 10,
                commands: [
                    .beginRenderPass(
                        pass(
                            width: 10,
                            height: 10,
                            load: .clear(.opaqueBlack)
                        )
                    ),
                    .endRenderPass,
                ]
            )
            expect(
                compiler.lower(
                    buffer,
                    renderTarget: renderTarget(width: 10, height: 10),
                    into: &arena
                ) == .rejected(
                    .capacityExhausted(
                        requiredDWords: 25,
                        availableDWords: 24
                    )
                ),
                "short frame arena rejection"
            )
            expect(arena.dwordCount == 0, "short frame advanced cursor")
            expect(storage[0] == 0xa5a5_a5a5, "short frame touched storage")
        }
    }

    private static func makeCompiler(
        explicitShaderBinding: Bool = true,
        supportsShaderLink: Bool = false,
        roundedPipeline: Bool = true
    ) -> VirGLIRCompiler {
        let caps = VirGLContextCapabilities(
            capsetID: explicitShaderBinding ? 2 : 1,
            capsetVersion: 1,
            capabilityBits: 0,
            capabilityBitsV2: supportsShaderLink
                ? VirGLContextCapabilities.separateShaderObjectsBit
                : 0
        )
        guard let handles = VirGLIRPipelineHandles(
            vertexShader: 1,
            fragmentShader: 2,
            roundedVertexShader: roundedPipeline ? 8 : nil,
            roundedFragmentShader: roundedPipeline ? 9 : nil,
            vertexElements: 3,
            rasterizer: 4,
            depthStencilAlpha: 5,
            copyBlend: 6,
            sourceOverBlend: 7,
            unitQuadVertexResource: 0x80
        ) else {
            fatalError("test pipeline handles")
        }
        return VirGLIRCompiler(
            configuration: VirGLIRPipelineConfiguration(
                capabilities: caps,
                handles: handles,
                unitQuadVertexLayout: .r32g32Float
            )
        )
    }

    private static func commandBuffer(
        id: UInt64,
        commands: [GPURenderCommand]
    ) -> GPURenderCommandBuffer {
        guard let commandID = GPUCommandBufferID(rawValue: id),
              var recorder = GPUCommandRecorder(
                  id: commandID,
                  capacity: commands.count
              )
        else {
            fatalError("test command recorder")
        }
        for (index, command) in commands.enumerated() {
            expect(
                recorder.record(command) == .recorded(index: index),
                "record test command \(index)"
            )
        }
        guard case .sealed(let buffer) = recorder.seal() else {
            fatalError("test command buffer did not seal")
        }
        return buffer
    }

    private static func pass(
        target: UInt32 = 1,
        width: UInt32,
        height: UInt32,
        format: GPUColorAttachmentFormat = .bgra8UNormSRGB,
        load: GPURenderPassLoadAction = .load,
        store: GPURenderPassStoreAction = .store
    ) -> GPURenderPassDescriptor {
        GPURenderPassDescriptor(
            target: targetID(target),
            extent: extent(width, height),
            format: format,
            loadAction: load,
            storeAction: store
        )
    }

    private static func renderTarget(
        id: UInt32 = 1,
        width: UInt32,
        height: UInt32,
        format: GPUColorAttachmentFormat = .bgra8UNormSRGB,
        virglSurfaceFormat: UInt32 = VirGLIRRenderTarget.b8g8r8a8SRGBFormat,
        surfaceHandle: UInt32 = 0x40
    ) -> VirGLIRRenderTarget {
        guard let result = VirGLIRRenderTarget(
            id: targetID(id),
            surfaceHandle: surfaceHandle,
            extent: extent(width, height),
            format: format,
            virglSurfaceFormat: virglSurfaceFormat
        ) else {
            fatalError("test render target")
        }
        return result
    }

    private static func extent(_ width: UInt32, _ height: UInt32) -> GPUPixelExtent {
        guard let result = GPUPixelExtent(width: width, height: height) else {
            fatalError("test extent")
        }
        return result
    }

    private static func targetID(_ raw: UInt32) -> GPURenderTargetID {
        guard let result = GPURenderTargetID(rawValue: raw) else {
            fatalError("test target ID")
        }
        return result
    }

    private static func fixed(_ whole: Int) -> GPUFixed16 {
        guard let result = GPUFixed16(whole: whole) else {
            fatalError("test fixed")
        }
        return result
    }

    private static func transform(
        m11: Int,
        m12: Int,
        m21: Int,
        m22: Int,
        translationX: Int = 0,
        translationY: Int = 0
    ) -> GPUTransform2D {
        GPUTransform2D(
            m11: fixed(m11),
            m12: fixed(m12),
            m21: fixed(m21),
            m22: fixed(m22),
            translationX: fixed(translationX),
            translationY: fixed(translationY)
        )
    }

    private static func fixedRectangle(
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> GPUFixedRectangle {
        guard let result = GPUFixedRectangle(
            x: fixed(x),
            y: fixed(y),
            width: fixed(width),
            height: fixed(height)
        ) else {
            fatalError("test rectangle")
        }
        return result
    }

    private static func requireColor(
        red: UInt16,
        green: UInt16,
        blue: UInt16,
        alpha: UInt16
    ) -> GPUPremultipliedColor {
        guard let result = GPUPremultipliedColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        ) else {
            fatalError("test color")
        }
        return result
    }

    private static func requireQuad(
        x: Int = 0,
        y: Int = 0,
        width: Int = 10,
        height: Int = 10,
        color: GPUPremultipliedColor = .opaqueWhite,
        blend: GPUBlendMode = .sourceOver
    ) -> GPUQuadInstance {
        guard let result = GPUQuadInstance(
            bounds: fixedRectangle(x: x, y: y, width: width, height: height),
            color: color,
            blendMode: blend
        ) else {
            fatalError("test quad")
        }
        return result
    }

    private static func requireRoundedQuad(
        x: Int = 0,
        y: Int = 0,
        width: Int = 10,
        height: Int = 10,
        topLeft: Int = 2,
        topRight: Int = 2,
        bottomRight: Int = 2,
        bottomLeft: Int = 2,
        color: GPUPremultipliedColor = .opaqueWhite,
        blend: GPUBlendMode = .sourceOver
    ) -> GPUQuadInstance {
        guard let radii = GPUCornerRadii(
                  topLeft: fixed(topLeft),
                  topRight: fixed(topRight),
                  bottomRight: fixed(bottomRight),
                  bottomLeft: fixed(bottomLeft)
              ),
              let result = GPUQuadInstance(
                  bounds: fixedRectangle(
                      x: x,
                      y: y,
                      width: width,
                      height: height
                  ),
                  color: color,
                  cornerRadii: radii,
                  blendMode: blend
              )
        else {
            fatalError("test rounded quad")
        }
        return result
    }

    private static func requireGlyph() -> GPUGlyphAtlasInstance {
        guard let texture = GPUTextureID(rawValue: 1) else {
            fatalError("test texture")
        }
        return GPUGlyphAtlasInstance(
            atlas: texture,
            bounds: fixedRectangle(x: 0, y: 0, width: 8, height: 12),
            textureRegion: .complete,
            color: .opaqueWhite
        )
    }

    private static func scissor(
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32
    ) -> GPUScissorRectangle {
        guard let result = GPUScissorRectangle(
            x: x,
            y: y,
            width: width,
            height: height
        ) else {
            fatalError("test scissor")
        }
        return result
    }

    private static func appendTestClear(to arena: inout VirGLDWordArena) {
        guard let clear = VirGLClearValue(
            bufferMask: 4,
            color0Bits: 0,
            color1Bits: 0,
            color2Bits: 0,
            color3Bits: 0,
            depthBits: 0,
            stencil: 0
        ), case .encoded = arena.encodeClear(clear) else {
            fatalError("test clear packet")
        }
    }

    private static func packetStarts(_ arena: VirGLDWordArena) -> [Int] {
        var result: [Int] = []
        var index = 0
        while index < arena.dwordCount {
            result.append(index)
            let header = requireDWord(arena, index)
            index += 1 + Int(header >> 16)
        }
        expect(index == arena.dwordCount, "packet walk ended at arena boundary")
        return result
    }

    private static func packetCommand(
        _ arena: VirGLDWordArena,
        _ start: Int
    ) -> UInt8 {
        UInt8(truncatingIfNeeded: requireDWord(arena, start))
    }

    private static func packetObjectType(
        _ arena: VirGLDWordArena,
        _ start: Int
    ) -> UInt8 {
        UInt8(truncatingIfNeeded: requireDWord(arena, start) >> 8)
    }

    private static func shaderTerminalByte(
        _ arena: VirGLDWordArena,
        start: Int
    ) -> UInt8 {
        let byteCount = Int(requireDWord(arena, start + 3))
        let byteIndex = byteCount - 1
        let word = requireDWord(arena, start + 6 + (byteIndex / 4))
        return UInt8(truncatingIfNeeded: word >> UInt32((byteIndex & 3) * 8))
    }

    private static func floatDWord(
        _ arena: VirGLDWordArena,
        _ index: Int
    ) -> Float {
        Float(bitPattern: requireDWord(arena, index))
    }

    private static func requireDWord(
        _ arena: VirGLDWordArena,
        _ index: Int
    ) -> UInt32 {
        guard let value = arena.dword(at: index) else {
            fatalError("missing dword \(index)")
        }
        return value
    }

    private static func withArena(
        capacity: Int,
        _ body: (
            inout VirGLDWordArena,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
        pointer.initialize(repeating: 0xa5a5_a5a5, count: capacity)
        let storage = UnsafeMutableBufferPointer(start: pointer, count: capacity)
        guard var arena = VirGLDWordArena(storage: storage) else {
            fatalError("test arena")
        }
        body(&arena, storage)
        pointer.deinitialize(count: capacity)
        pointer.deallocate()
    }

    private static func expectClose(
        _ actual: Float,
        _ expected: Float,
        _ message: String
    ) {
        let difference = actual > expected
            ? actual - expected
            : expected - actual
        expect(difference < 0.000_01, message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
