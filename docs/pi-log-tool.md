# Raspberry Pi log workflow

`tools/swiftos_pi_logs.py` gives the development environment one entry point
for returned-card persistent logs and the live USB CDC console. It is a host
tool only; none of its Python or macOS dependencies are linked into SwiftOS.

## Returned microSD card

Power the Pi down before removing the card. Insert it in the Mac, independently
check the current external-disk list, and unmount the whole card yourself:

```sh
diskutil list external physical
diskutil unmountDisk /dev/diskN
mkdir -p .build/hardware-captures
make rpi5-card-logs \
  RPI5_LOG_ARGS='--output .build/hardware-captures/pi5-returned-card.json'
```

The tool always takes another fresh `diskutil list -plist external physical`
snapshot. It selects only one removable, external, physical whole disk with a
`SWIFTOS` FAT32 boot partition and type-`0xda` data partition. `--device
/dev/diskN` is only a selector: it is checked against that fresh snapshot and
does not bypass discovery. Ambiguous candidates, partition paths, fixed disks,
geometry changes, symlinks, missing SwiftOS sentinels, and any mounted child
partition are refused.

Reading `/dev/rdiskN` can require administrator access on macOS. The tool never
invokes `sudo`. If macOS denies the read, repeat the complete command through
the privilege mechanism you trust so discovery and geometry verification run
again. Keep the shell unprivileged so it creates a user-owned evidence file,
and enable `noclobber` so redirection cannot replace an earlier capture:

```sh
(
  umask 077
  set -C
  sudo env PYTHONDONTWRITEBYTECODE=1 \
    python3 tools/swiftos_pi_logs.py card --json \
    > .build/hardware-captures/pi5-returned-card.json
)
```

Do not add a cached disk number merely to the privileged rerun. Recheck the
physical list after any reconnect. The tool opens the raw whole disk
read-only, bounds the inspector to the independently reported exact byte size,
and reads only the MBR, redundant SwiftOS data superblocks, and declared log
arena. It does not mount, unmount, eject, format, repartition, or write media.

The default terminal view starts with capture health and sequence gaps/resets.
When a retained console crosses kernel sequence resets, it labels the aggregate
stream incomplete because it spans boots, then reconstructs and reports the
newest kernel epoch separately. Failure triage is scoped to that newest epoch,
so a stale failure from an older boot cannot obscure the current result. The
promoted markers include `PANIC`, `FAILED`, `TIMEOUT`, `MISSING`, `UNSUPPORTED`,
`DEFERRED`, `MISMATCH`, `INVALID`, `UNAVAILABLE`, `LOST`, and suspicious
`_STATE` markers. An `RP1_NET_BOARD_FAILED` or `_TIMEOUT` result also carries
its immediately preceding SYS/PLL snapshot, clock-attempt telemetry,
`BOARD_STAGE`, `BOARD_REGISTER`, `BOARD_EXPECTED`, and `BOARD_OBSERVED` values
into the summary as one adjacent diagnostic group. `USB_DEBUG_FAULT` likewise
promotes its reason, gadget/controller states, interrupt snapshot, bus speed,
and receive status. A capture ending partway through that bounded USB snapshot
still reports the available fields rather than hiding them.

The full reconstructed canonical console remains an aggregate in persistent
record order so older boot evidence is not discarded. `--summary-only` hides
that full console; `--json` prints the complete machine-readable report.
`--output` creates a mode-`0600` JSON evidence file and refuses to overwrite an
existing capture. The privileged redirection example instead relies on the
unprivileged shell's `noclobber` guard, which also prevents replacement while
keeping the file owned by the developer rather than root.

View a saved capture later without reopening or rereading the microSD card:

```sh
python3 tools/swiftos_pi_logs.py show \
  .build/hardware-captures/pi5-returned-card.json
```

`show --summary-only` prints just health and promoted diagnostic markers;
`show --json` re-emits the bounded, recognized-format report. Saved captures
must be regular, non-symlink files with the supported format and bounded size.

A regular packaged image can be examined without `diskutil` or privilege:

```sh
python3 tools/swiftos_pi_logs.py card \
  --image .build/raspberry-pi-5/swiftos-rpi5-media.img \
  --summary-only
```

## Connected Pi over USB-C

Build the control client, power the Pi separately through a supported path,
and reserve its USB-C OTG connector for the data cable. Then follow retained
canonical console bytes:

```sh
make rpi5-live-logs \
  RPI5_LOG_ARGS='--output .build/hardware-captures/pi5-live-console.log'
```

The wrapper delegates USB identity matching (`1209:5a17`), exact CDC tty
association, raw tty configuration, DTR, SDBG framing, CRC checks, and `CONS`
record reconstruction to `swiftosctl console`. It polls by structured-log
sequence, so non-console entries also advance the cursor and console bytes are
not replayed. The exact reconstructed bytes are teed to the terminal and the
optional capture. An existing output file is never replaced. Press Control-C
to stop the follow cleanly.

Automatic live discovery requires exactly one associated SwiftOS CDC callout
device. To resolve an intentional multi-device setup, pass a validated callout
path:

```sh
make rpi5-live-logs \
  RPI5_LOG_ARGS='--device /dev/cu.usbmodemSWIFTOS1 --once'
```

`--once` pulls the retained console and exits. `--start SEQUENCE`, `--count N`,
`--timeout SECONDS`, and `--poll-interval SECONDS` bound live collection. The
live path is read-only at the SDBG service level; it does not issue a `SUPD`
update and it never writes the microSD card.

Run the wrapper contract tests without touching physical media:

```sh
make rpi5-log-tool-host-test
```
