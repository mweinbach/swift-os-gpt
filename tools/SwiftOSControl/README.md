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
.build/swiftosctl console
```

`doctor` and `wait-ready` exit with status 2 until exactly one associated
SwiftOS CDC tty is usable. Add `--json` for automation.

`console` takes a coherent one-shot SDBG snapshot of the retained canonical
kernel console. It reconstructs the original UART bytes from `CONS` records;
`--json` includes a base64 copy and a structured-log `nextSequence` cursor for
polling, while `--raw` writes only the exact bytes for evidence capture. Use
`--start N` to resume from a cursor and `--count N` to bound each pull. An idle
request at the advertised next sequence succeeds with an empty byte stream.

On Raspberry Pi 5, reserve the USB-C connector for OTG data and power the
board separately through a supported path. The Pi USB-A ports are host-only.
