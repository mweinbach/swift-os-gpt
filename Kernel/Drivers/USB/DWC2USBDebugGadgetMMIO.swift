typealias RaspberryPiUSBDebugGadget =
    DWC2USBDebugGadget<DWC2MMIORegisterAccess>

extension DWC2USBDebugGadget where Registers == DWC2MMIORegisterAccess {
    init?(
        resource: DeviceResource,
        scratchBaseAddress: UInt64,
        scratchByteCount: UInt64,
        scanout: ScanoutBuffer,
        viewportScale: UInt16,
        sessionID: UInt64
    ) {
        guard let registers = DWC2MMIORegisterAccess(
                  baseAddress: resource.baseAddress,
                  length: resource.length
              )
        else { return nil }
        self.init(
            registers: registers,
            scratchBaseAddress: scratchBaseAddress,
            scratchByteCount: scratchByteCount,
            scanout: scanout,
            viewportScale: viewportScale,
            sessionID: sessionID
        )
    }
}
