# SwiftOS USB kernel updater

`swiftos-usb-update` validates and pushes a Raspberry Pi 5 `kernel8.img` over
the same CDC ACM connection used by the USB diagnostic display. It never
reports staging success until the guest acknowledges an SHA-256-verified
commit. That acknowledgement precedes guest activation policy; confirm the Pi
disconnects, re-enumerates, and boots the expected image.
Only one host process can own the tty, so close the display viewer first.

Build and inspect devices:

```sh
make usb-update
.build/swiftos-usb-update --list
```

Validate the exact image without opening a device:

```sh
.build/swiftos-usb-update \
  --image .build/raspberry-pi-5/kernel8.img \
  --dry-run
```

Push it after the SwiftOS USB gadget enumerates:

```sh
.build/swiftos-usb-update \
  --device /dev/cu.usbmodemSWIFTOS1 \
  --image .build/raspberry-pi-5/kernel8.img
```

Automatic selection is allowed only when exactly one `cu.usbmodem` device is
present. Timeouts close the connection, reopen it, issue the idempotent BEGIN,
and resume from the guest's acknowledged offset. The default DATA chunk is 456
bytes, making its complete wire frame 496 bytes so it fits in one high-speed
512-byte USB bulk packet. The guest may negotiate a smaller 64...456-byte
chunk in its first STATUS.

## SUPD version 1 wire contract

Every integer is little endian. A frame starts with this 24-byte header:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `SUPD` |
| 4 | 1 | version, `1` |
| 5 | 1 | message kind |
| 6 | 2 | flags, zero in version 1 |
| 8 | 4 | transfer ID |
| 12 | 4 | sequence |
| 16 | 4 | payload byte count, at most 4112 |
| 20 | 4 | frame CRC32 |

The frame CRC is standard CRC-32/ISO-HDLC (reflected polynomial
`0xedb88320`, check value `cbf43926` for `123456789`) over header bytes 0...19
followed by the payload. The CRC field itself is excluded.

Message kinds and payloads:

- `1 BEGIN`, sequence 0, 56 bytes: artifact kind `u16` (`1` kernel boot
  image), target machine `u16` (`1` Raspberry Pi 5), total length `u64`,
  requested chunk bytes `u32`, requested total chunks `u32`, SHA-256 `[32]`,
  and whole-image CRC32 `u32`.
- `2 DATA`, sequence `offset / negotiatedChunk + 1`: exact offset `u64`, byte
  count `u32`, reserved-zero `u32`, then that many bytes. Gaps, overlaps, and
  bytes beyond the declared image are invalid. Replaying the last fully
  accepted chunk must be idempotent.
- `3 COMMIT`, sequence `negotiatedTotalChunks + 1`, 40 bytes: total length
  `u64` and SHA-256 `[32]`.
- `4 ABORT`, out-of-band sequence 0, 4-byte reason code.
- `5 STATUS`, out-of-band sequence 0, 20 bytes: status code `u16`, phase `u8`,
  flags `u8`, next exact offset `u64`, accepted chunk bytes `u32`, and detail
  `u32`.

The transfer ID is the little-endian first word of SHA-256 XOR the low 32 bits
of image length, with the reserved result zero mapped to one. It is stable
across host restarts. BEGIN for the same transfer and manifest must return the
staged `nextOffset`; a conflicting BEGIN must be rejected. The host uses only
one request at a time, so STATUS is deliberately out of band rather than
echoing a request sequence.

STATUS codes are `0` ready, `1` accepted, `2` progress, `3` verified, and `4`
committed. Failure codes begin at `0x0100`: malformed frame, unsupported
version, unsupported target, invalid offset, checksum mismatch, storage
failure, busy, and aborted occupy `0x0100...0x0107`. Phases are idle `0`,
receiving `1`, verifying `2`, committed `3`, and rejected `4`.

COMMIT is the verified staging boundary: the guest calculates SHA-256 across
the complete staged artifact, validates the Pi Image header, seals activation
metadata, sends COMMITTED, and only then may its kernel policy perform a
bounded soft restart. A reconnect after a lost COMMIT response can issue BEGIN
again; a guest that already completed the same transfer returns committed with
`nextOffset == totalLength`.

The CLI therefore reports sealed staging and a requested chainload, not an
end-to-end boot result. Confirm that the CDC device disconnects, re-enumerates,
and exposes the expected new boot identity; UART remains the policy-failure
diagnostic path until that identity exchange exists on SUPD itself.

This first updater is intentionally volatile. A successful soft restart runs
the staged RAM image, while a power cycle returns to `kernel8.img` on the
microSD card. SHA-256 and CRC32 provide corruption detection, not signer or host
authentication; use this only on a physically trusted development connection.

Run the host protocol tests with:

```sh
make usb-update-host-test
```
