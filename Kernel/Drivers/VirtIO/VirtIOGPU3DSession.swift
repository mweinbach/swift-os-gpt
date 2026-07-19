// The complete SwiftOS accelerated rendering crossing for VirtIO-GPU. The
// guest never allocates or uploads a scanout pixel backing store: VirGL
// renders the retained desktop into a host-private sRGB target and VirtIO-GPU
// scans that resource out. The only uploaded image is an immutable R8 glyph
// mask atlas; all visible placement, sampling, tinting, blending, and
// presentation remain GPU work. Every controlq operation is fenced and
// completed before dependent state is published.

struct VirtIOGPU3DSessionConfiguration: Equatable {
    let scanoutID: UInt32
    let width: UInt32
    let height: UInt32
    let contextID: UInt32
    let resourceID: UInt32
    let unitQuadResourceID: UInt32
    let glyphAtlasResourceID: UInt32
    let colorSurfaceHandle: UInt32
    let capabilities: VirGLRendererCapabilities
    let completionFenceID: UInt64
}

enum VirtIOGPU3DSessionError: Equatable {
    case alreadyConfigured
    case invalidNegotiatedFeatures
    case invalidMemoryLayout
    case deviceConfiguration(VirtIOGPUDeviceConfigurationReadResult)
    case fenceIDExhausted
    case protocolEncoding(commandType: UInt32)
    case commandEncoding(VirGLEncodeRejection)
    case pipelineInitialization(VirGLIRPipelineInitializationRejection)
    case desktopScene(GPUDesktopSceneRejection)
    case bootTextScene(GPUBootTextSceneRejection)
    case fontAtlasWrite(GPUMaskFontAtlasWriteResult)
    case renderLowering(VirGLIRLoweringRejection)
    case transport(VirtIOMMIORequestResult)
    case malformedResponse(commandType: UInt32)
    case noEnabledScanout
    case capsetCountOutOfRange
    case capsetObservation(VirGLCapsetSelectionRejection)
    case noCompatibleCapset
    case capsetPayloadTooLarge
    case capabilityPayload(VirGLCapabilityParseRejection)
    case displayModeExceedsTextureLimit
    case displayModeExceedsRendererCoordinates
    case commandStreamInvariant
}

enum VirtIOGPU3DSessionResult: Equatable {
    case configured(VirtIOGPU3DSessionConfiguration)
    case failed(VirtIOGPU3DSessionError)
}

enum VirtIOGPU3DFrameResult: Equatable {
    case presented(completionFenceID: UInt64)
    case failed(VirtIOGPU3DSessionError)
}

private enum VirtIOGPU3DTransactionResult {
    case completed(responseByteCount: UInt32)
    case failed(VirtIOGPU3DSessionError)
}

private enum VirtIOGPU3DDesktopSubmissionResult {
    case submitted(presentationDamage: GPUScissorRectangle)
    case failed(VirtIOGPU3DSessionError)
}

private struct VirtIOGPU3DScanoutMode {
    let id: UInt32
    let width: UInt32
    let height: UInt32
}

/// Owns one VirGL context, its GPU-only scanout target, immutable unit-quad
/// geometry and glyph atlas, and the reusable retained-renderer pipeline.
/// Copying this value would duplicate mutable transport and fence state, so
/// callers must keep one mutable owner after construction.
struct VirtIOGPU3DSession {
    static let readyMarker: StaticString = "SWIFTOS:VIRTIO_GPU_3D_OK\n"

    // Values are fixed by the public VirGL/Gallium wire protocol pinned by
    // VirGLCommandEncoder and VirGLCapabilityParser.
    private static let texture2DTarget: UInt32 = 2
    private static let pipeBufferTarget: UInt32 = 0
    private static let b8g8r8a8SRGB: UInt32 = 100
    private static let r8UNorm: UInt32 = 64
    private static let renderTargetBind: UInt32 = 1 << 1
    private static let samplerViewBind: UInt32 = 1 << 3
    private static let vertexBufferBind: UInt32 = 1 << 4
    private static let scanoutBind: UInt32 = 1 << 18
    private static let maximumRendererCoordinate: UInt32 = 32_767
    private static let unitQuadByteCount: UInt32 = 48
    private static let inlineWriteUsage: UInt32 = 0x82

    private static let contextID: UInt32 = 1
    private static let resourceID: UInt32 = 1
    private static let unitQuadResourceID: UInt32 = 2
    private static let glyphAtlasResourceID: UInt32 = 3
    private static let colorSurfaceHandle: UInt32 = 0x100
    private static let vertexShaderHandle: UInt32 = 0x101
    private static let fragmentShaderHandle: UInt32 = 0x102
    private static let vertexElementsHandle: UInt32 = 0x103
    private static let rasterizerHandle: UInt32 = 0x104
    private static let depthStencilAlphaHandle: UInt32 = 0x105
    private static let copyBlendHandle: UInt32 = 0x106
    private static let sourceOverBlendHandle: UInt32 = 0x107
    private static let roundedVertexShaderHandle: UInt32 = 0x108
    private static let roundedFragmentShaderHandle: UInt32 = 0x109
    private static let glyphVertexShaderHandle: UInt32 = 0x10a
    private static let glyphFragmentShaderHandle: UInt32 = 0x10b
    private static let glyphSamplerViewHandle: UInt32 = 0x10c
    private static let glyphNearestSamplerHandle: UInt32 = 0x10d
    private static let glyphLinearSamplerHandle: UInt32 = 0x10e

    private static let minimumCommandArenaByteCount: UInt64 = 4096
    private static let maximumSubmitRequestByteCount: UInt64 =
        minimumCommandArenaByteCount
    private static let maximumCapsetResponseByteCount: UInt64 =
        UInt64(VirtIOGPU3DWireLayout.controlHeaderByteCount)
            + UInt64(VirGLCapabilityWire.maximumVirGL2PayloadByteCount)
    private static let queuePageByteCount: UInt64 = 4096

    private var transport: VirtIOMMIOTransport
    private let commandArenaMapping: DMAMapping
    private let requestMapping: DMAMapping
    private let responseMapping: DMAMapping
    private let protectedQueueMapping: DMAMapping
    private var nextFenceID: UInt64 = 1
    private(set) var isConfigured = false
    private var activeConfiguration: VirtIOGPU3DSessionConfiguration?
    private var activeFeatures: VirtIOGPU3DFeatures?
    private var renderer: VirGLIRCompiler?

    init(
        transport: VirtIOMMIOTransport,
        commandArenaMapping: DMAMapping,
        requestMapping: DMAMapping,
        responseMapping: DMAMapping,
        protectedQueueMapping: DMAMapping
    ) {
        self.transport = transport
        self.commandArenaMapping = commandArenaMapping
        self.requestMapping = requestMapping
        self.responseMapping = responseMapping
        self.protectedQueueMapping = protectedQueueMapping
    }

    mutating func configureAndRenderDesktop() -> VirtIOGPU3DSessionResult {
        guard !isConfigured else { return .failed(.alreadyConfigured) }
        guard memoryLayoutIsValid() else {
            return .failed(.invalidMemoryLayout)
        }

        let deviceFeatureBits = transport.negotiatedFeatures
            & VirtIOGPU3DFeatures.knownMask
        guard let features = VirtIOGPU3DFeatures(
                  rawValue: deviceFeatureBits
              ),
              features.supports3D
        else {
            return .failed(.invalidNegotiatedFeatures)
        }

        let configuration: VirtIOGPUDeviceConfiguration
        let configurationResult = transport.readGPUDeviceConfiguration()
        switch configurationResult {
        case .ready(let readyConfiguration):
            configuration = readyConfiguration
        case .invalidAttemptLimit, .wrongDevice, .invalidConfiguration,
             .unstable:
            return .failed(.deviceConfiguration(configurationResult))
        }

        let scanout: VirtIOGPU3DScanoutMode
        switch queryDisplay(configuration: configuration) {
        case .ready(let discovered):
            scanout = discovered
        case .failed(let error):
            return abort(error)
        }

        let capabilities: VirGLRendererCapabilities
        switch discoverCapabilities(
            capsetCount: configuration.capsetCount,
            features: features
        ) {
        case .ready(let discovered):
            capabilities = discovered
        case .failed(let error):
            return abort(error)
        }

        // Production compositing preserves attachment alpha and performs the
        // linear-to-sRGB transfer in the GPU render target. Opaque format 101
        // and linear format 2 cannot substitute for format 100.
        guard capabilities.supportsB8G8R8A8SRGBRenderTarget else {
            return abort(.capabilityPayload(.unsupportedRenderTargetFormat))
        }
        guard capabilities.supportsB8G8R8A8SRGBScanout else {
            return abort(.capabilityPayload(.unsupportedScanoutFormat))
        }
        guard capabilities.supportsR8UNormSampler else {
            return abort(.capabilityPayload(.unsupportedSamplerFormat))
        }
        if capabilities.hasExplicitTexture2DLimit,
           !capabilities.supportsTexture2D(
               width: scanout.width,
               height: scanout.height
           ) {
            return abort(.displayModeExceedsTextureLimit)
        }
        guard scanout.width <= Self.maximumRendererCoordinate,
              scanout.height <= Self.maximumRendererCoordinate
        else {
            return abort(.displayModeExceedsRendererCoordinates)
        }

        guard let colorResource = VirtIOGPU3DResourceDescriptor(
                  resourceID: Self.resourceID,
                  target: Self.texture2DTarget,
                  format: Self.b8g8r8a8SRGB,
                  bind: Self.renderTargetBind | Self.scanoutBind,
                  width: scanout.width,
                  height: scanout.height,
                  depth: 1,
                  arraySize: 1,
                  lastLevel: 0,
                  sampleCount: 0,
                  flags: VirtIOGPU3DResourceFlag.yOriginTop
              ),
              let unitQuadResource = VirtIOGPU3DResourceDescriptor(
                  resourceID: Self.unitQuadResourceID,
                  target: Self.pipeBufferTarget,
                  format: Self.r8UNorm,
                  bind: Self.vertexBufferBind,
                  width: Self.unitQuadByteCount,
                  height: 1,
                  depth: 1,
                  arraySize: 1,
                  lastLevel: 0,
                  sampleCount: 0,
                  flags: 0
              ),
              let glyphAtlasResource = VirtIOGPU3DResourceDescriptor(
                  resourceID: Self.glyphAtlasResourceID,
                  target: Self.texture2DTarget,
                  format: Self.r8UNorm,
                  bind: Self.samplerViewBind,
                  width: GPUMaskFontAtlasLayout.atlasWidth,
                  height: GPUMaskFontAtlasLayout.atlasHeight,
                  depth: 1,
                  arraySize: 1,
                  lastLevel: 0,
                  sampleCount: 0,
                  // VirGL flips inline uploads for Y_0_TOP textures. The
                  // atlas writer and normalized UVs already agree on row 0,
                  // so the mask resource must retain native texture rows.
                  flags: 0
              )
        else {
            return abort(.commandStreamInvariant)
        }

        guard createContext(
                  capset: capabilities.capset,
                  features: features
              ),
              createResource(
                  colorResource,
                  features: features
              ),
              attachResource(
                  resourceID: Self.resourceID,
                  features: features
              ),
              createResource(
                  unitQuadResource,
                  features: features
              ),
              attachResource(
                  resourceID: Self.unitQuadResourceID,
                  features: features
              ),
              createResource(
                  glyphAtlasResource,
                  features: features
              ),
              attachResource(
                  resourceID: Self.glyphAtlasResourceID,
                  features: features
              )
        else {
            // Each helper already preserved its exact error in lastError.
            return abort(lastError ?? .protocolEncoding(
                commandType: VirtIOGPU3DControlType.contextCreate
            ))
        }

        switch encodeAndSubmitUnitQuad(features: features) {
        case .success:
            break
        case .failure(let error):
            return abort(error)
        }

        switch encodeAndSubmitGlyphAtlas(features: features) {
        case .success:
            break
        case .failure(let error):
            return abort(error)
        }

        let presentationDamage: VirtIOGPURectangle
        switch encodeAndSubmitDesktopFrame(
            scanout: scanout,
            capabilities: capabilities,
            features: features
        ) {
        case .submitted(let damage):
            presentationDamage = VirtIOGPURectangle(
                x: damage.x,
                y: damage.y,
                width: damage.width,
                height: damage.height
            )
        case .failed(let error):
            return abort(error)
        }

        let rectangle = VirtIOGPURectangle(
            x: 0,
            y: 0,
            width: scanout.width,
            height: scanout.height
        )
        switch setScanout(
            scanoutID: scanout.id,
            rectangle: rectangle
        ) {
        case .success:
            break
        case .failure(let error):
            return abort(error)
        }
        switch flush(rectangle: presentationDamage) {
        case .success:
            break
        case .failure(let error):
            return abort(error)
        }

        let completionFenceID = nextFenceID - 1
        let sessionConfiguration = VirtIOGPU3DSessionConfiguration(
            scanoutID: scanout.id,
            width: scanout.width,
            height: scanout.height,
            contextID: Self.contextID,
            resourceID: Self.resourceID,
            unitQuadResourceID: Self.unitQuadResourceID,
            glyphAtlasResourceID: Self.glyphAtlasResourceID,
            colorSurfaceHandle: Self.colorSurfaceHandle,
            capabilities: capabilities,
            completionFenceID: completionFenceID
        )
        activeConfiguration = sessionConfiguration
        activeFeatures = features
        isConfigured = true
        return .configured(sessionConfiguration)
    }

    /// Lowers one immutable device-neutral command buffer into the already
    /// initialized VirGL pipeline, submits it to the GPU, and presents only
    /// the declared damage. No pixel backing store or CPU raster path exists
    /// in this API.
    mutating func render(
        _ commandBuffer: GPURenderCommandBuffer,
        damage requestedDamage: VirtIOGPURectangle? = nil
    ) -> VirtIOGPU3DFrameResult {
        renderCommands(
            first: commandBuffer,
            second: nil,
            damage: requestedDamage
        )
    }

    /// Lowers two ordered command buffers into one VirGL submission and then
    /// performs one resource flush. This is the bounded crossing used by
    /// retained chrome followed by a `.load` text pass: no chrome-only frame
    /// becomes visible between the two buffers.
    mutating func renderBatch(
        _ firstCommandBuffer: GPURenderCommandBuffer,
        then secondCommandBuffer: GPURenderCommandBuffer,
        damage requestedDamage: VirtIOGPURectangle? = nil
    ) -> VirtIOGPU3DFrameResult {
        renderCommands(
            first: firstCommandBuffer,
            second: secondCommandBuffer,
            damage: requestedDamage
        )
    }

    private mutating func renderCommands(
        first firstCommandBuffer: GPURenderCommandBuffer,
        second secondCommandBuffer: GPURenderCommandBuffer?,
        damage requestedDamage: VirtIOGPURectangle?
    ) -> VirtIOGPU3DFrameResult {
        guard isConfigured,
              let configuration = activeConfiguration,
              let features = activeFeatures,
              var activeRenderer = renderer,
              var arena = makeCommandArena(),
              let target = makeRenderTarget(
                  width: configuration.width,
                  height: configuration.height
              )
        else {
            return failFrame(.invalidMemoryLayout)
        }
        let damage = requestedDamage ?? VirtIOGPURectangle(
            x: 0,
            y: 0,
            width: configuration.width,
            height: configuration.height
        )
        guard damageFits(
                  damage,
                  width: configuration.width,
                  height: configuration.height
              )
        else {
            return failFrame(.commandStreamInvariant)
        }
        switch activeRenderer.lower(
            firstCommandBuffer,
            renderTarget: target,
            into: &arena
        ) {
        case .lowered:
            break
        case .rejected(let rejection):
            return failFrame(.renderLowering(rejection))
        }
        if let secondCommandBuffer {
            switch activeRenderer.lower(
                secondCommandBuffer,
                renderTarget: target,
                into: &arena
            ) {
            case .lowered:
                break
            case .rejected(let rejection):
                return failFrame(.renderLowering(rejection))
            }
        }
        switch submit(arena: arena, features: features) {
        case .success:
            break
        case .failure(let error):
            return failFrame(error)
        }
        switch flush(rectangle: damage) {
        case .success:
            renderer = activeRenderer
            return .presented(completionFenceID: nextFenceID - 1)
        case .failure(let error):
            return failFrame(error)
        }
    }

    private var lastError: VirtIOGPU3DSessionError?

    private enum ScanoutResult {
        case ready(VirtIOGPU3DScanoutMode)
        case failed(VirtIOGPU3DSessionError)
    }

    private enum CapabilityResult {
        case ready(VirGLRendererCapabilities)
        case failed(VirtIOGPU3DSessionError)
    }

    private enum OperationResult {
        case success
        case failure(VirtIOGPU3DSessionError)
    }

    private mutating func queryDisplay(
        configuration: VirtIOGPUDeviceConfiguration
    ) -> ScanoutResult {
        guard let fence = takeFence() else {
            return .failed(.fenceIDExhausted)
        }
        let requestByteCount = VirtIOGPUProtocol.controlHeaderByteCount
        let responseCapacity = VirtIOGPUProtocol.displayInfoResponseByteCount
        guard prepareTransaction(
                  requestByteCount: requestByteCount,
                  responseCapacity: responseCapacity
              )
        else {
            return .failed(.invalidMemoryLayout)
        }
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.getDisplayInfo,
            fenceID: fence,
            at: requestMapping.cpuPhysicalAddress
        )
        switch submitPrepared(
            requestByteCount: requestByteCount,
            responseCapacity: responseCapacity
        ) {
        case .failed(let error):
            return .failed(error)
        case .completed(let byteCount):
            guard byteCount == responseCapacity,
                  VirtIOGPUProtocol.responseIsValid(
                      at: responseMapping.cpuPhysicalAddress,
                      byteCount: byteCount,
                      expectedType: VirtIOGPUControlType.responseOKDisplayInfo,
                      fenceID: fence
                  )
            else {
                return .failed(.malformedResponse(
                    commandType: VirtIOGPUControlType.getDisplayInfo
                ))
            }
        }

        var index: UInt32 = 0
        while index < configuration.scanoutCount {
            let modeAddress = responseMapping.cpuPhysicalAddress
                + UInt64(VirtIOGPUProtocol.controlHeaderByteCount)
                + UInt64(index) * 24
            let width = PhysicalBytes.readLE32(at: modeAddress + 8)
            let height = PhysicalBytes.readLE32(at: modeAddress + 12)
            let enabled = PhysicalBytes.readLE32(at: modeAddress + 16)
            if enabled != 0, width != 0, height != 0 {
                return .ready(
                    VirtIOGPU3DScanoutMode(
                        id: index,
                        width: width,
                        height: height
                    )
                )
            }
            index += 1
        }
        return .failed(.noEnabledScanout)
    }

    private mutating func discoverCapabilities(
        capsetCount: UInt32,
        features: VirtIOGPU3DFeatures
    ) -> CapabilityResult {
        guard var selector = VirGLCapsetSelector(
                  advertisedCapsetCount: capsetCount
              )
        else {
            return .failed(.capsetCountOutOfRange)
        }

        var index: UInt32 = 0
        while index < capsetCount {
            guard let fence = takeFence() else {
                return .failed(.fenceIDExhausted)
            }
            guard let header = VirtIOGPU3DFencedHeader(
                      type: VirtIOGPU3DControlType.getCapsetInfo,
                      fenceID: fence,
                      features: features
                  )
            else {
                return .failed(.protocolEncoding(
                    commandType: VirtIOGPU3DControlType.getCapsetInfo
                ))
            }
            let requestByteCount = VirtIOGPU3DWireLayout.getCapsetInfoByteCount
            let responseCapacity =
                VirtIOGPU3DWireLayout.capsetInfoResponseByteCount
            guard prepareTransaction(
                      requestByteCount: requestByteCount,
                      responseCapacity: responseCapacity
                  )
            else {
                return .failed(.invalidMemoryLayout)
            }
            guard VirtIOGPU3DProtocol.writeGetCapsetInfo(
                      header: header,
                      capsetIndex: index,
                      availableCapsetCount: capsetCount,
                      at: requestMapping.cpuPhysicalAddress,
                      capacity: requestByteCount
                  ) == requestByteCount
            else {
                return .failed(.protocolEncoding(
                    commandType: VirtIOGPU3DControlType.getCapsetInfo
                ))
            }
            let responseByteCount: UInt32
            switch submitPrepared(
                requestByteCount: requestByteCount,
                responseCapacity: responseCapacity
            ) {
            case .failed(let error):
                return .failed(error)
            case .completed(let completedByteCount):
                responseByteCount = completedByteCount
            }
            guard let information = VirtIOGPU3DProtocol
                      .readCapsetInfoResponse(
                          at: responseMapping.cpuPhysicalAddress,
                          byteCount: responseByteCount,
                          fenceID: fence
                      )
            else {
                return .failed(.malformedResponse(
                    commandType: VirtIOGPU3DControlType.getCapsetInfo
                ))
            }
            switch selector.observe(information) {
            case .accepted, .ignored:
                break
            case .rejected(let rejection):
                return .failed(.capsetObservation(rejection))
            }
            index += 1
        }

        let selection: VirGLCapsetSelection
        switch selector.finish() {
        case .selected(let selected):
            selection = selected
        case .unavailable:
            return .failed(.noCompatibleCapset)
        case .rejected(let rejection):
            return .failed(.capsetObservation(rejection))
        }

        guard selection.payloadByteCount
                <= UInt32.max - VirtIOGPU3DWireLayout.controlHeaderByteCount
        else {
            return .failed(.capsetPayloadTooLarge)
        }
        let responseCapacity = selection.payloadByteCount
            + VirtIOGPU3DWireLayout.controlHeaderByteCount
        guard UInt64(responseCapacity) <= responseMapping.byteCount else {
            return .failed(.capsetPayloadTooLarge)
        }
        guard let fence = takeFence() else {
            return .failed(.fenceIDExhausted)
        }
        guard let header = VirtIOGPU3DFencedHeader(
                  type: VirtIOGPU3DControlType.getCapset,
                  fenceID: fence,
                  features: features
              )
        else {
            return .failed(.protocolEncoding(
                commandType: VirtIOGPU3DControlType.getCapset
            ))
        }
        let requestByteCount = VirtIOGPU3DWireLayout.getCapsetByteCount
        guard prepareTransaction(
                  requestByteCount: requestByteCount,
                  responseCapacity: responseCapacity
              )
        else {
            return .failed(.invalidMemoryLayout)
        }
        guard VirtIOGPU3DProtocol.writeGetCapset(
                  header: header,
                  capsetID: selection.kind.rawValue,
                  version: selection.version,
                  maximumVersion: selection.advertisedMaximumVersion,
                  at: requestMapping.cpuPhysicalAddress,
                  capacity: requestByteCount
              ) == requestByteCount
        else {
            return .failed(.protocolEncoding(
                commandType: VirtIOGPU3DControlType.getCapset
            ))
        }
        let responseByteCount: UInt32
        switch submitPrepared(
            requestByteCount: requestByteCount,
            responseCapacity: responseCapacity
        ) {
        case .failed(let error):
            return .failed(error)
        case .completed(let completedByteCount):
            responseByteCount = completedByteCount
        }
        guard let payload = VirtIOGPU3DProtocol.readCapsetResponse(
                  at: responseMapping.cpuPhysicalAddress,
                  byteCount: responseByteCount,
                  expectedPayloadByteCount: selection.payloadByteCount,
                  fenceID: fence
              ),
              let pointer = UnsafeRawPointer(
                  bitPattern: UInt(payload.address)
              )
        else {
            return .failed(.malformedResponse(
                commandType: VirtIOGPU3DControlType.getCapset
            ))
        }
        let rawPayload = UnsafeRawBufferPointer(
            start: pointer,
            count: Int(payload.byteCount)
        )
        switch VirGLCapabilityParser.parse(
            capset: selection,
            payload: rawPayload
        ) {
        case .capabilities(let capabilities):
            return .ready(capabilities)
        case .rejected(let rejection):
            return .failed(.capabilityPayload(rejection))
        }
    }

    private mutating func createContext(
        capset: VirGLCapsetSelection,
        features: VirtIOGPU3DFeatures
    ) -> Bool {
        let commandType = VirtIOGPU3DControlType.contextCreate
        guard let fence = takeFence() else {
            lastError = .fenceIDExhausted
            return false
        }
        guard let header = VirtIOGPU3DFencedHeader(
                  type: commandType,
                  fenceID: fence,
                  contextID: Self.contextID,
                  features: features
              )
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        let byteCount = VirtIOGPU3DWireLayout.contextCreateByteCount
        guard prepareTransaction(
                  requestByteCount: byteCount,
                  responseCapacity:
                    VirtIOGPU3DWireLayout.controlHeaderByteCount
              )
        else {
            lastError = .invalidMemoryLayout
            return false
        }
        guard VirtIOGPU3DProtocol.writeContextCreate(
                  header: header,
                  contextInitialization: features.supportsContextInitialization
                    ? capset.kind.rawValue : 0,
                  features: features,
                  debugNameAddress: 0,
                  debugNameByteCount: 0,
                  at: requestMapping.cpuPhysicalAddress,
                  capacity: byteCount
              ) == byteCount
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        return completeNoData(
            commandType: commandType,
            requestByteCount: byteCount,
            fenceID: fence
        )
    }

    private mutating func createResource(
        _ resource: VirtIOGPU3DResourceDescriptor,
        features: VirtIOGPU3DFeatures
    ) -> Bool {
        let commandType = VirtIOGPU3DControlType.resourceCreate3D
        guard let fence = takeFence() else {
            lastError = .fenceIDExhausted
            return false
        }
        guard let header = VirtIOGPU3DFencedHeader(
                  type: commandType,
                  fenceID: fence,
                  features: features
              )
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        let byteCount = VirtIOGPU3DWireLayout.resourceCreate3DByteCount
        guard prepareTransaction(
                  requestByteCount: byteCount,
                  responseCapacity:
                    VirtIOGPU3DWireLayout.controlHeaderByteCount
              )
        else {
            lastError = .invalidMemoryLayout
            return false
        }
        guard VirtIOGPU3DProtocol.writeResourceCreate3D(
                  header: header,
                  resource: resource,
                  at: requestMapping.cpuPhysicalAddress,
                  capacity: byteCount
              ) == byteCount
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        return completeNoData(
            commandType: commandType,
            requestByteCount: byteCount,
            fenceID: fence
        )
    }

    private mutating func attachResource(
        resourceID: UInt32,
        features: VirtIOGPU3DFeatures
    ) -> Bool {
        let commandType = VirtIOGPU3DControlType.contextAttachResource
        guard let fence = takeFence() else {
            lastError = .fenceIDExhausted
            return false
        }
        guard let header = VirtIOGPU3DFencedHeader(
                  type: commandType,
                  fenceID: fence,
                  contextID: Self.contextID,
                  features: features
              )
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        let byteCount = VirtIOGPU3DWireLayout.contextResourceByteCount
        guard prepareTransaction(
                  requestByteCount: byteCount,
                  responseCapacity:
                    VirtIOGPU3DWireLayout.controlHeaderByteCount
              )
        else {
            lastError = .invalidMemoryLayout
            return false
        }
        guard VirtIOGPU3DProtocol.writeContextAttachResource(
                  header: header,
                  resourceID: resourceID,
                  at: requestMapping.cpuPhysicalAddress,
                  capacity: byteCount
              ) == byteCount
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
        return completeNoData(
            commandType: commandType,
            requestByteCount: byteCount,
            fenceID: fence
        )
    }

    private mutating func encodeAndSubmitUnitQuad(
        features: VirtIOGPU3DFeatures
    ) -> OperationResult {
        guard var arena = makeCommandArena(),
              let box = VirGLTextureBox(
                  x: 0,
                  y: 0,
                  z: 0,
                  width: Self.unitQuadByteCount,
                  height: 1,
                  depth: 1
              ),
              let blockLayout = VirGLTransferBlockLayout(
                  blockWidth: 1,
                  blockHeight: 1,
                  blockDepth: 1,
                  bytesPerBlock: 1
              )
        else {
            return .failure(.invalidMemoryLayout)
        }

        let zero = Float(0).bitPattern
        let one = Float(1).bitPattern
        var vertices = (
            zero, zero,
            one, zero,
            zero, one,
            zero, one,
            one, zero,
            one, one
        )
        let encodeResult = withUnsafeBytes(of: &vertices) { bytes in
            arena.encodeResourceInlineWrite(
                resourceHandle: Self.unitQuadResourceID,
                level: 0,
                usage: Self.inlineWriteUsage,
                stride: 0,
                layerStride: 0,
                box: box,
                blockLayout: blockLayout,
                bytes: bytes
            )
        }
        switch encodeResult {
        case .encoded(let start, let count):
            guard start == 0, count == 24, arena.dwordCount == 24 else {
                return .failure(.commandStreamInvariant)
            }
        case .rejected(let rejection):
            return .failure(.commandEncoding(rejection))
        }
        return submit(arena: arena, features: features)
    }

    /// Builds and uploads the immutable mask atlas one bounded strip at a
    /// time. These bytes are font coverage data, never scanout pixels; the
    /// renderer turns the masks into visible glyphs entirely in VirGL.
    private mutating func encodeAndSubmitGlyphAtlas(
        features: VirtIOGPU3DFeatures
    ) -> OperationResult {
        guard let staging = UnsafeMutableRawPointer(
                  bitPattern: UInt(responseMapping.cpuPhysicalAddress)
              ),
              responseMapping.byteCount
                >= UInt64(GPUMaskFontAtlasUploadPlan.maximumUploadByteCount),
              let blockLayout = VirGLTransferBlockLayout(
                  blockWidth: 1,
                  blockHeight: 1,
                  blockDepth: 1,
                  bytesPerBlock: 1
              )
        else {
            return .failure(.invalidMemoryLayout)
        }

        var uploadIndex = 0
        while uploadIndex < GPUMaskFontAtlasUploadPlan.uploadCount {
            guard let upload = GPUMaskFontAtlasLayout.uploadPlan.upload(
                      at: uploadIndex
                  ),
                  let box = VirGLTextureBox(
                      x: upload.destination.x,
                      y: upload.destination.y,
                      z: 0,
                      width: upload.destination.width,
                      height: upload.destination.height,
                      depth: 1
                  ),
                  var arena = makeCommandArena()
            else {
                return .failure(.commandStreamInvariant)
            }
            let bytes = UnsafeMutableRawBufferPointer(
                start: staging,
                count: upload.byteCount
            )
            switch GPUMaskFontAtlasWriter.writeUpload(
                at: uploadIndex,
                into: bytes
            ) {
            case .written(let byteCount):
                guard byteCount == upload.byteCount else {
                    return .failure(.commandStreamInvariant)
                }
            case .invalidUploadIndex:
                return .failure(.fontAtlasWrite(.invalidUploadIndex))
            case .insufficientCapacity(
                let requiredByteCount,
                let availableByteCount
            ):
                return .failure(.fontAtlasWrite(.insufficientCapacity(
                    requiredByteCount: requiredByteCount,
                    availableByteCount: availableByteCount
                )))
            }

            let encodeResult = arena.encodeResourceInlineWrite(
                resourceHandle: Self.glyphAtlasResourceID,
                level: 0,
                usage: Self.inlineWriteUsage,
                stride: UInt32(upload.sourceBytesPerRow),
                layerStride: UInt32(upload.byteCount),
                box: box,
                blockLayout: blockLayout,
                bytes: UnsafeRawBufferPointer(bytes)
            )
            switch encodeResult {
            case .encoded(let start, let count):
                guard start == 0,
                      count == 768,
                      arena.dwordCount == 768
                else {
                    return .failure(.commandStreamInvariant)
                }
            case .rejected(let rejection):
                return .failure(.commandEncoding(rejection))
            }
            switch submit(arena: arena, features: features) {
            case .success:
                break
            case .failure(let error):
                return .failure(error)
            }
            uploadIndex += 1
        }
        return .success
    }

    private mutating func encodeAndSubmitDesktopFrame(
        scanout: VirtIOGPU3DScanoutMode,
        capabilities: VirGLRendererCapabilities,
        features: VirtIOGPU3DFeatures
    ) -> VirtIOGPU3DDesktopSubmissionResult {
        guard var initializationArena = makeCommandArena() else {
            return .failed(.invalidMemoryLayout)
        }
        switch initializationArena.encodeCreateSurface(
            handle: Self.colorSurfaceHandle,
            resourceHandle: Self.resourceID,
            format: Self.b8g8r8a8SRGB,
            view: .texture(level: 0, firstLayer: 0, lastLayer: 0)
        ) {
        case .encoded:
            break
        case .rejected(let rejection):
            return .failed(.commandEncoding(rejection))
        }

        guard let glyphTextureID = GPUTextureID(
                  rawValue: Self.glyphAtlasResourceID
              ),
              let glyphPipeline = VirGLIRGlyphPipeline(
                  textureID: glyphTextureID,
                  textureResource: Self.glyphAtlasResourceID,
                  vertexShader: Self.glyphVertexShaderHandle,
                  fragmentShader: Self.glyphFragmentShaderHandle,
                  samplerView: Self.glyphSamplerViewHandle,
                  nearestSampler: Self.glyphNearestSamplerHandle,
                  linearSampler: Self.glyphLinearSamplerHandle
              ),
              let handles = VirGLIRPipelineHandles(
                  vertexShader: Self.vertexShaderHandle,
                  fragmentShader: Self.fragmentShaderHandle,
                  roundedVertexShader: Self.roundedVertexShaderHandle,
                  roundedFragmentShader: Self.roundedFragmentShaderHandle,
                  glyph: glyphPipeline,
                  vertexElements: Self.vertexElementsHandle,
                  rasterizer: Self.rasterizerHandle,
                  depthStencilAlpha: Self.depthStencilAlphaHandle,
                  copyBlend: Self.copyBlendHandle,
                  sourceOverBlend: Self.sourceOverBlendHandle,
                  unitQuadVertexResource: Self.unitQuadResourceID
              )
        else {
            return .failed(.commandStreamInvariant)
        }
        let contextCapabilities = VirGLContextCapabilities(
            capsetID: capabilities.capset.kind.rawValue,
            capsetVersion: capabilities.capset.version,
            capabilityBits: capabilities.capabilityBits,
            capabilityBitsV2: capabilities.capabilityBitsV2
        )
        var compiler = VirGLIRCompiler(
            configuration: VirGLIRPipelineConfiguration(
                capabilities: contextCapabilities,
                handles: handles,
                unitQuadVertexLayout: .r32g32Float
            )
        )
        switch compiler.initializePipeline(into: &initializationArena) {
        case .initialized:
            break
        case .rejected(let rejection):
            return .failed(.pipelineInitialization(rejection))
        }
        switch submit(arena: initializationArena, features: features) {
        case .success:
            break
        case .failure(let error):
            return .failed(error)
        }

        guard let renderTarget = makeRenderTarget(
                  width: scanout.width,
                  height: scanout.height
              ),
              let desktopCommandID = GPUCommandBufferID(rawValue: 1),
              let textCommandID = GPUCommandBufferID(rawValue: 2),
              var renderArena = makeCommandArena()
        else {
            return .failed(.commandStreamInvariant)
        }
        let commandBuffer: GPURenderCommandBuffer
        let presentationDamage: GPUScissorRectangle
        switch GPUDesktopScene.makeInitialFrame(
            physicalWidth: scanout.width,
            physicalHeight: scanout.height,
            target: renderTarget.id,
            commandBufferID: desktopCommandID
        ) {
        case .frame(let frame):
            commandBuffer = frame.commandBuffer
            presentationDamage = frame.presentationDamage
        case .rejected(let rejection):
            return .failed(.desktopScene(rejection))
        }
        switch compiler.lower(
            commandBuffer,
            renderTarget: renderTarget,
            into: &renderArena
        ) {
        case .lowered:
            break
        case .rejected(let rejection):
            return .failed(.renderLowering(rejection))
        }

        switch GPUBootTextScene.makeFrame(
            physicalWidth: scanout.width,
            physicalHeight: scanout.height,
            atlas: glyphTextureID,
            target: renderTarget.id,
            commandBufferID: textCommandID
        ) {
        case .frame(let frame):
            switch compiler.lower(
                frame.commandBuffer,
                renderTarget: renderTarget,
                into: &renderArena
            ) {
            case .lowered:
                break
            case .rejected(let rejection):
                return .failed(.renderLowering(rejection))
            }
        case .nothingVisible:
            break
        case .rejected(let rejection):
            return .failed(.bootTextScene(rejection))
        }

        switch submit(arena: renderArena, features: features) {
        case .success:
            renderer = compiler
            return .submitted(presentationDamage: presentationDamage)
        case .failure(let error):
            return .failed(error)
        }
    }

    private mutating func submit(
        arena: VirGLDWordArena,
        features: VirtIOGPU3DFeatures
    ) -> OperationResult {
        guard arena.dwordCount > 0,
              arena.dwordCount <= Int(UInt32.max / 4)
        else {
            return .failure(.commandStreamInvariant)
        }
        guard let fence = takeFence() else {
            return .failure(.fenceIDExhausted)
        }
        guard let header = VirtIOGPU3DFencedHeader(
                  type: VirtIOGPU3DControlType.submit3D,
                  fenceID: fence,
                  contextID: Self.contextID,
                  features: features
              )
        else {
            return .failure(.protocolEncoding(
                commandType: VirtIOGPU3DControlType.submit3D
            ))
        }
        let commandByteCount = UInt32(arena.dwordCount * 4)
        let requestByteCountResult =
            VirtIOGPU3DWireLayout.submit3DHeaderByteCount
                .addingReportingOverflow(commandByteCount)
        guard !requestByteCountResult.overflow else {
            return .failure(.commandStreamInvariant)
        }
        let requestByteCount = requestByteCountResult.partialValue
        guard prepareTransaction(
                  requestByteCount: requestByteCount,
                  responseCapacity:
                    VirtIOGPU3DWireLayout.controlHeaderByteCount
              )
        else {
            return .failure(.invalidMemoryLayout)
        }
        guard VirtIOGPU3DProtocol.writeSubmit3D(
                  header: header,
                  commandStreamAddress:
                    commandArenaMapping.cpuPhysicalAddress,
                  commandStreamByteCount: commandByteCount,
                  at: requestMapping.cpuPhysicalAddress,
                  capacity: requestByteCount
              ) == requestByteCount
        else {
            return .failure(.protocolEncoding(
                commandType: VirtIOGPU3DControlType.submit3D
            ))
        }
        if completeNoData(
            commandType: VirtIOGPU3DControlType.submit3D,
            requestByteCount: requestByteCount,
            fenceID: fence
        ) {
            return .success
        }
        return .failure(lastError ?? .malformedResponse(
            commandType: VirtIOGPU3DControlType.submit3D
        ))
    }

    private func makeCommandArena() -> VirGLDWordArena? {
        guard let storage = UnsafeMutablePointer<UInt32>(
                  bitPattern: UInt(commandArenaMapping.cpuPhysicalAddress)
              ),
              requestMapping.byteCount
                > UInt64(VirtIOGPU3DWireLayout.submit3DHeaderByteCount)
        else {
            return nil
        }
        let requestCommandCapacity = requestMapping.byteCount
            - UInt64(VirtIOGPU3DWireLayout.submit3DHeaderByteCount)
        let usableByteCount = commandArenaMapping.byteCount
                < requestCommandCapacity
            ? commandArenaMapping.byteCount
            : requestCommandCapacity
        return VirGLDWordArena(
            storage: UnsafeMutableBufferPointer(
                start: storage,
                count: Int(usableByteCount / 4)
            )
        )
    }

    private func makeRenderTarget(
        width: UInt32,
        height: UInt32
    ) -> VirGLIRRenderTarget? {
        guard let targetID = GPURenderTargetID(rawValue: Self.resourceID),
              let extent = GPUPixelExtent(width: width, height: height)
        else {
            return nil
        }
        return VirGLIRRenderTarget(
            id: targetID,
            surfaceHandle: Self.colorSurfaceHandle,
            extent: extent,
            format: .bgra8UNormSRGB,
            virglSurfaceFormat: Self.b8g8r8a8SRGB
        )
    }

    private func damageFits(
        _ damage: VirtIOGPURectangle,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        guard damage.width != 0, damage.height != 0 else { return false }
        let endX = damage.x.addingReportingOverflow(damage.width)
        let endY = damage.y.addingReportingOverflow(damage.height)
        return !endX.overflow
            && !endY.overflow
            && endX.partialValue <= width
            && endY.partialValue <= height
    }

    private mutating func failFrame(
        _ error: VirtIOGPU3DSessionError
    ) -> VirtIOGPU3DFrameResult {
        switch error {
        case .transport, .malformedResponse, .fenceIDExhausted,
             .protocolEncoding, .invalidMemoryLayout:
            transport.failDevice()
            isConfigured = false
        default:
            break
        }
        return .failed(error)
    }

    private mutating func setScanout(
        scanoutID: UInt32,
        rectangle: VirtIOGPURectangle
    ) -> OperationResult {
        let commandType = VirtIOGPUControlType.setScanout
        guard let fence = takeFence() else {
            return .failure(.fenceIDExhausted)
        }
        let byteCount: UInt32 = 48
        guard prepareTransaction(
                  requestByteCount: byteCount,
                  responseCapacity: VirtIOGPUProtocol.controlHeaderByteCount
              )
        else {
            return .failure(.invalidMemoryLayout)
        }
        let request = requestMapping.cpuPhysicalAddress
        VirtIOGPUProtocol.writeHeader(
            type: commandType,
            fenceID: fence,
            at: request
        )
        VirtIOGPUProtocol.writeRectangle(rectangle, at: request + 24)
        PhysicalBytes.writeLE32(scanoutID, at: request + 40)
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 44)
        if completeNoData(
            commandType: commandType,
            requestByteCount: byteCount,
            fenceID: fence
        ) {
            return .success
        }
        return .failure(lastError ?? .malformedResponse(
            commandType: commandType
        ))
    }

    private mutating func flush(
        rectangle: VirtIOGPURectangle
    ) -> OperationResult {
        let commandType = VirtIOGPUControlType.resourceFlush
        guard let fence = takeFence() else {
            return .failure(.fenceIDExhausted)
        }
        let byteCount: UInt32 = 48
        guard prepareTransaction(
                  requestByteCount: byteCount,
                  responseCapacity: VirtIOGPUProtocol.controlHeaderByteCount
              )
        else {
            return .failure(.invalidMemoryLayout)
        }
        let request = requestMapping.cpuPhysicalAddress
        VirtIOGPUProtocol.writeHeader(
            type: commandType,
            fenceID: fence,
            at: request
        )
        VirtIOGPUProtocol.writeRectangle(rectangle, at: request + 24)
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 40)
        if completeNoData(
            commandType: commandType,
            requestByteCount: byteCount,
            fenceID: fence
        ) {
            return .success
        }
        return .failure(lastError ?? .malformedResponse(
            commandType: commandType
        ))
    }

    private mutating func completeNoData(
        commandType: UInt32,
        requestByteCount: UInt32,
        fenceID: UInt64
    ) -> Bool {
        switch submitPrepared(
            requestByteCount: requestByteCount,
            responseCapacity: VirtIOGPU3DWireLayout.controlHeaderByteCount
        ) {
        case .failed(let error):
            lastError = error
            return false
        case .completed(let responseByteCount):
            let valid: Bool
            if VirtIOGPU3DControlType.isRequest(commandType) {
                valid = VirtIOGPU3DProtocol.noDataResponseIsValid(
                    at: responseMapping.cpuPhysicalAddress,
                    byteCount: responseByteCount,
                    fenceID: fenceID
                )
            } else {
                valid = responseByteCount
                        == VirtIOGPUProtocol.controlHeaderByteCount
                    && VirtIOGPUProtocol.responseIsValid(
                        at: responseMapping.cpuPhysicalAddress,
                        byteCount: responseByteCount,
                        expectedType:
                            VirtIOGPUControlType.responseOKNoData,
                        fenceID: fenceID
                    )
            }
            guard valid else {
                lastError = .malformedResponse(commandType: commandType)
                return false
            }
            lastError = nil
            return true
        }
    }

    private func prepareTransaction(
        requestByteCount: UInt32,
        responseCapacity: UInt32
    ) -> Bool {
        requestByteCount > 0
            && responseCapacity >= VirtIOGPUProtocol.controlHeaderByteCount
            && UInt64(requestByteCount) <= requestMapping.byteCount
            && UInt64(responseCapacity) <= responseMapping.byteCount
            && PhysicalBytes.zero(
                address: requestMapping.cpuPhysicalAddress,
                byteCount: UInt64(requestByteCount)
            )
            && PhysicalBytes.zero(
                address: responseMapping.cpuPhysicalAddress,
                byteCount: UInt64(responseCapacity)
            )
    }

    private mutating func submitPrepared(
        requestByteCount: UInt32,
        responseCapacity: UInt32
    ) -> VirtIOGPU3DTransactionResult {
        guard let buffers = VirtIOQueueBufferPair(
                  request: requestMapping,
                  requestByteCount: requestByteCount,
                  response: responseMapping,
                  responseCapacity: responseCapacity,
                  protectedQueueMapping: protectedQueueMapping
              )
        else {
            return .failed(.invalidMemoryLayout)
        }
        switch transport.submit(buffers: buffers) {
        case .completed(let responseByteCount):
            return .completed(responseByteCount: responseByteCount)
        case .invalidRequest:
            return .failed(.transport(.invalidRequest))
        case .timedOut:
            return .failed(.transport(.timedOut))
        case .malformedCompletion:
            return .failed(.transport(.malformedCompletion))
        case .deviceNeedsReset:
            return .failed(.transport(.deviceNeedsReset))
        }
    }

    private mutating func takeFence() -> UInt64? {
        guard nextFenceID != 0 else { return nil }
        let fence = nextFenceID
        let increment = nextFenceID.addingReportingOverflow(1)
        nextFenceID = increment.overflow ? 0 : increment.partialValue
        return fence
    }

    private mutating func abort(
        _ error: VirtIOGPU3DSessionError
    ) -> VirtIOGPU3DSessionResult {
        transport.failDevice()
        return .failed(error)
    }

    private func memoryLayoutIsValid() -> Bool {
        guard commandArenaMapping.coherency == .hardwareCoherent,
              requestMapping.coherency == .hardwareCoherent,
              responseMapping.coherency == .hardwareCoherent,
              protectedQueueMapping.coherency == .hardwareCoherent,
              commandArenaMapping.cpuPhysicalAddress & 3 == 0,
              commandArenaMapping.byteCount
                >= Self.minimumCommandArenaByteCount,
              commandArenaMapping.byteCount / 4 <= UInt64(Int.max),
              requestMapping.byteCount
                >= Self.maximumSubmitRequestByteCount,
              responseMapping.byteCount
                >= Self.maximumCapsetResponseByteCount,
              protectedQueueMapping.byteCount >= Self.queuePageByteCount,
              protectedQueueMapping.cpuPhysicalAddress
                & (Self.queuePageByteCount - 1) == 0,
              protectedQueueMapping.deviceAddress
                & (Self.queuePageByteCount - 1) == 0,
              cpuPointerIsRepresentable(commandArenaMapping),
              cpuPointerIsRepresentable(requestMapping),
              cpuPointerIsRepresentable(responseMapping),
              cpuPointerIsRepresentable(protectedQueueMapping),
              mappingsAreDisjoint(commandArenaMapping, requestMapping),
              mappingsAreDisjoint(commandArenaMapping, responseMapping),
              mappingsAreDisjoint(
                  commandArenaMapping,
                  protectedQueueMapping
              ),
              mappingsAreDisjoint(requestMapping, responseMapping),
              mappingsAreDisjoint(requestMapping, protectedQueueMapping),
              mappingsAreDisjoint(responseMapping, protectedQueueMapping)
        else {
            return false
        }
        return true
    }

    private func cpuPointerIsRepresentable(_ mapping: DMAMapping) -> Bool {
        mapping.cpuPhysicalAddress <= UInt64(UInt.max)
            && mapping.byteCount <= UInt64(Int.max)
            && UnsafeRawPointer(
                bitPattern: UInt(mapping.cpuPhysicalAddress)
            ) != nil
    }

    private func mappingsAreDisjoint(
        _ first: DMAMapping,
        _ second: DMAMapping
    ) -> Bool {
        !rangesOverlap(
            firstAddress: first.cpuPhysicalAddress,
            firstByteCount: first.byteCount,
            secondAddress: second.cpuPhysicalAddress,
            secondByteCount: second.byteCount
        ) && !rangesOverlap(
            firstAddress: first.deviceAddress,
            firstByteCount: first.byteCount,
            secondAddress: second.deviceAddress,
            secondByteCount: second.byteCount
        )
    }

    private func rangesOverlap(
        firstAddress: UInt64,
        firstByteCount: UInt64,
        secondAddress: UInt64,
        secondByteCount: UInt64
    ) -> Bool {
        let firstLast = firstAddress + (firstByteCount - 1)
        let secondLast = secondAddress + (secondByteCount - 1)
        return firstAddress <= secondLast && secondAddress <= firstLast
    }
}
