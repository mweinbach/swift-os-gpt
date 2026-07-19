# SwiftOS control tool

`swiftosctl` is the macOS-side discovery and readiness foundation for a
physically connected SwiftOS machine. It matches the project USB identity
exactly (`1209:5a17`) and associates CDC callout devices through their I/O
Registry ancestry. Apple's built-in CDC driver is sufficient; this tool does
not install a driver or kernel extension.

Build and run it with:

```sh
make swiftosctl
.build/swiftosctl doctor
.build/swiftosctl wait-ready --timeout 30
```

`doctor` and `wait-ready` exit with status 2 until exactly one associated
SwiftOS CDC tty is usable. Add `--json` for automation.

On Raspberry Pi 5, reserve the USB-C connector for OTG data and power the
board separately through a supported path. The Pi USB-A ports are host-only.
