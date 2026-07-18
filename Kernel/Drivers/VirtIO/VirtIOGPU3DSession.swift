// The first complete SwiftOS accelerated rendering crossing for VirtIO-GPU.
// The guest never allocates or uploads a pixel backing store: VirGL creates and
// clears a host-private render target, and VirtIO-GPU scans that resource out.
// Every controlq operation is fenced and completed before dependent state is
// published.

struct VirtIOGPU3DClearColor: Equatable {
    let redBits: UInt32
    let greenBits: UInt32
    let blueBits: UInt32
    let alphaBits: UInt32
}

struct VirtIOGPU3DSessionConfiguration: Equatable {
    let scanoutID: UInt32
    let width: UInt32
    let height: UInt32
    let contextID: UInt32
    let resourceID: UInt32
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
    case transport(VirtIOMMIORequestResult)
    case malformedResponse(commandType: UInt32)
    case noEnabledScanout
    case capsetCountOutOfRange
    case capsetObservation(VirGLCapsetSelectionRejection)
    case noCompatibleCapset
    case capsetPayloadTooLarge
    case capabilityPayload(VirGLCapabilityParseRejection)
    case displayModeExceedsTextureLimit
    case commandStreamInvariant
}

enum VirtIOGPU3DSessionResult: Equatable {
    case configured(VirtIOGPU3DSessionConfiguration)
    case failed(VirtIOGPU3DSessionError)
}

private enum VirtIOGPU3DTransactionResult {
    case completed(responseByteCount: UInt32)
    case failed(VirtIOGPU3DSessionError)
}

private struct VirtIOGPU3DScanoutMode {
    let id: UInt32
    let width: UInt32
    let height: UInt32
}

/// Owns the strictly ordered bootstrap lifecycle for one VirGL context and one
/// scanout resource. Copying this value would duplicate mutable transport and
/// fence state, so callers must keep one mutable owner after construction.
struct VirtIOGPU3DSession {
    static let readyMarker: StaticString = "SWIFTOS:VIRTIO_GPU_3D_OK\n"

    // Values are fixed by the public VirGL/Gallium wire protocol pinned by
    // VirGLCommandEncoder and VirGLCapabilityParser.
    private static let texture2DTarget: UInt32 = 2
    private static let b8g8r8x8UNorm: UInt32 = 2
    private static let renderTargetBind: UInt32 = 1 << 1
    private static let scanoutBind: UInt32 = 1 << 18
    private static let colorAttachmentZeroMask: UInt32 = 1 << 2

    private static let contextID: UInt32 = 1
    private static let resourceID: UInt32 = 1
    private static let colorSurfaceHandle: UInt32 = 1

    private static let commandDWordCount: UInt64 = 19
    private static let commandByteCount: UInt64 = commandDWordCount * 4
    private static let maximumSubmitRequestByteCount: UInt64 =
        UInt64(VirtIOGPU3DWireLayout.submit3DHeaderByteCount)
            + commandByteCount
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

    mutating func configureAndClear(
        color: VirtIOGPU3DClearColor
    ) -> VirtIOGPU3DSessionResult {
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

        // Direct scanout requires the explicit VIRGL2 format mask. The legacy
        // capset exposes neither that contract nor a 2D texture limit, so this
        // production path rejects it instead of inferring either property.
        guard capabilities.supportsB8G8R8X8Scanout else {
            return abort(.capabilityPayload(.unsupportedScanoutFormat))
        }
        if capabilities.hasExplicitTexture2DLimit,
           !capabilities.supportsTexture2D(
               width: scanout.width,
               height: scanout.height
           ) {
            return abort(.displayModeExceedsTextureLimit)
        }

        guard createContext(
                  capset: capabilities.capset,
                  features: features
              ),
              createResource(
                  width: scanout.width,
                  height: scanout.height,
                  features: features
              ),
              attachResource(features: features)
        else {
            // Each helper already preserved its exact error in lastError.
            return abort(lastError ?? .protocolEncoding(
                commandType: VirtIOGPU3DControlType.contextCreate
            ))
        }

        switch encodeAndSubmitClear(color: color, features: features) {
        case .success:
            break
        case .failure(let error):
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
        switch flush(rectangle: rectangle) {
        case .success:
            break
        case .failure(let error):
            return abort(error)
        }

        let completionFenceID = nextFenceID - 1
        isConfigured = true
        return .configured(
            VirtIOGPU3DSessionConfiguration(
                scanoutID: scanout.id,
                width: scanout.width,
                height: scanout.height,
                contextID: Self.contextID,
                resourceID: Self.resourceID,
                capabilities: capabilities,
                completionFenceID: completionFenceID
            )
        )
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
        width: UInt32,
        height: UInt32,
        features: VirtIOGPU3DFeatures
    ) -> Bool {
        let commandType = VirtIOGPU3DControlType.resourceCreate3D
        guard let resource = VirtIOGPU3DResourceDescriptor(
                  resourceID: Self.resourceID,
                  target: Self.texture2DTarget,
                  format: Self.b8g8r8x8UNorm,
                  bind: Self.renderTargetBind | Self.scanoutBind,
                  width: width,
                  height: height,
                  depth: 1,
                  arraySize: 1,
                  lastLevel: 0,
                  sampleCount: 0,
                  flags: VirtIOGPU3DResourceFlag.yOriginTop
              )
        else {
            lastError = .protocolEncoding(commandType: commandType)
            return false
        }
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
                  resourceID: Self.resourceID,
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

    private mutating func encodeAndSubmitClear(
        color: VirtIOGPU3DClearColor,
        features: VirtIOGPU3DFeatures
    ) -> OperationResult {
        guard let storage = UnsafeMutablePointer<UInt32>(
                  bitPattern: UInt(commandArenaMapping.cpuPhysicalAddress)
              ),
              var arena = VirGLDWordArena(
                  storage: UnsafeMutableBufferPointer(
                      start: storage,
                      count: Int(commandArenaMapping.byteCount / 4)
                  )
              )
        else {
            return .failure(.invalidMemoryLayout)
        }

        switch arena.encodeCreateSurface(
            handle: Self.colorSurfaceHandle,
            resourceHandle: Self.resourceID,
            format: Self.b8g8r8x8UNorm,
            view: .texture(level: 0, firstLayer: 0, lastLayer: 0)
        ) {
        case .encoded:
            break
        case .rejected(let rejection):
            return .failure(.commandEncoding(rejection))
        }

        var surfaceHandle = Self.colorSurfaceHandle
        let framebufferResult = withUnsafePointer(to: &surfaceHandle) {
            pointer in
            arena.encodeSetFramebuffer(
                colorSurfaceHandles: UnsafeBufferPointer(
                    start: pointer,
                    count: 1
                ),
                depthStencilSurfaceHandle: nil
            )
        }
        switch framebufferResult {
        case .encoded:
            break
        case .rejected(let rejection):
            return .failure(.commandEncoding(rejection))
        }

        guard let clear = VirGLClearValue(
                  bufferMask: Self.colorAttachmentZeroMask,
                  color0Bits: color.redBits,
                  color1Bits: color.greenBits,
                  color2Bits: color.blueBits,
                  color3Bits: color.alphaBits,
                  depthBits: 0,
                  stencil: 0
              )
        else {
            return .failure(.commandEncoding(.invalidState))
        }
        switch arena.encodeClear(clear) {
        case .encoded:
            break
        case .rejected(let rejection):
            return .failure(.commandEncoding(rejection))
        }

        guard arena.dwordCount == Int(Self.commandDWordCount),
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
        let requestByteCount =
            VirtIOGPU3DWireLayout.submit3DHeaderByteCount + commandByteCount
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
              commandArenaMapping.byteCount >= Self.commandByteCount,
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
