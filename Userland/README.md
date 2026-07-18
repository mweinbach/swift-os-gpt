# SwiftOS init workload

`Init.swift` is a freestanding Embedded Swift userspace payload. It is compiled
separately from the kernel and exports one C-ABI entry point:

```text
swiftos_user_init(x0: thread ID) -> does not return
```

Each invocation creates its only mutable state as an automatic value. The
kernel can start two threads at the same entry address with different EL0 stack
pointers and identifiers. The threads stay CPU-bound, making timer preemption
observable, and periodically issue report syscall `1` with:

```text
x8 = 1                 report syscall number
x0 = thread ID
x1 = per-thread report sequence
x2 = per-thread checksum
```

`Syscall.S` is the only assembly in the payload because Swift cannot express
`svc`. It is a leaf veneer with no policy and no mutable storage.

## Object and image contract

Build the sources into objects distinct from the kernel module:

```sh
swiftc -target aarch64-none-none-elf \
  -enable-experimental-feature Embedded \
  -wmo -parse-as-library -Osize \
  -module-name SwiftOSUserland \
  -module-cache-path .build/module-cache \
  -Xfrontend -function-sections \
  -Xfrontend -disable-stack-protector \
  -emit-object Userland/Init.swift -o .build/userland-init.raw.o

clang --target=aarch64-none-none-elf -ffreestanding -fno-stack-protector \
  -c Userland/Syscall.S -o .build/userland-svc.raw.o

ld.lld -flavor gnu -m aarch64elf -r --gc-sections \
  -u swiftos_user_init -o .build/userland.o \
  .build/userland-init.raw.o .build/userland-svc.raw.o
```

The relocatable link is part of the isolation contract. The Embedded Swift
compiler emits generic support sections in each standalone module. None are
reachable from init, so this step removes them before `userland.o` meets the
kernel object; that avoids duplicate runtime definitions and turns an accidental
userspace allocation into a link-time dependency instead of silently sharing a
kernel allocator.

The final linker invocation must name both objects explicitly. Route their
input sections before the kernel's broad `.text` and `.rodata` collectors:

```ld
.user_text : ALIGN(4K)
{
    __user_text_start = .;
    KEEP(.build/userland.o(.text.swiftos_user_init))
    .build/userland.o(.text .text.*)
    __user_text_end = .;
}

.user_rodata : ALIGN(4K)
{
    __user_rodata_start = .;
    .build/userland.o(.rodata .rodata.* .swift5* swift5*)
    .build/userland.o(.swift_modhash)
    __user_rodata_end = .;
}
```

Exact object-path matching is intentional: it prevents kernel code from being
granted EL0 access and prevents the user payload from disappearing into kernel
text. The final link must retain `swiftos_user_init` while using
`--gc-sections`; this discards unused support routines emitted by the Embedded
Swift toolchain. Define `__user_entry = swiftos_user_init` and assert that it
lies in the user-text interval.

The owned page-table builder must map only `.user_text` as EL0 readable and
executable, `.user_rodata` as EL0 read-only and non-executable, and each user
stack as EL0 read/write and non-executable. Give each stack at least one
unmapped guard page. Kernel mappings must remain privileged-only. Start each
context at `__user_entry` with `x0` set to its identifier, `SP_EL0` set to its
own aligned stack top, and `SPSR_EL1` configured for EL0t with interrupts
unmasked.

An AArch64 `SVC` exception reports exception class `0x15`; `ELR_EL1` already
points at the instruction following `svc`. Dispatch syscall `1` from saved
`x8`, consume arguments from saved `x0...x2`, place a result in saved `x0`, and
return without advancing `ELR_EL1` again.
