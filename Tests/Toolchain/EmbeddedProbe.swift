import _Volatile

@_cdecl("swiftos_embedded_toolchain_probe")
func embeddedToolchainProbe(_ value: UInt64) -> UInt64 {
    value &+ 1
}
