SHELL := /bin/sh

BUILD_DIR := .build
MODULE_CACHE := $(BUILD_DIR)/module-cache
KERNEL_ELF := $(BUILD_DIR)/swiftos.elf
KERNEL_BIN := $(BUILD_DIR)/swiftos.bin
SWIFT_OBJECT := $(BUILD_DIR)/kernel.o
BOOT_OBJECT := $(BUILD_DIR)/boot.o
USERLAND_INIT_RAW := $(BUILD_DIR)/userland-init.raw.o
USERLAND_SVC_RAW := $(BUILD_DIR)/userland-svc.raw.o
USERLAND_OBJECT := $(BUILD_DIR)/userland.o
USERLAND_TEST_ELF := $(BUILD_DIR)/userland-test.elf
RPI5_BUILD_DIR := $(BUILD_DIR)/raspberry-pi-5
RPI5_BOOT_OBJECT := $(RPI5_BUILD_DIR)/boot.o
RPI5_HEADER_OBJECT := $(RPI5_BUILD_DIR)/image-header.o
RPI5_KERNEL_ELF := $(RPI5_BUILD_DIR)/swiftos-rpi5.elf
RPI5_KERNEL_IMAGE := $(RPI5_BUILD_DIR)/kernel8.img

SWIFTC ?= swiftc
CLANG ?= clang
LD_LLD ?= ld.lld
LLVM_OBJCOPY ?= llvm-objcopy
LLVM_NM ?= $(shell xcrun --find llvm-nm)
LLVM_OBJDUMP ?= $(shell xcrun --find llvm-objdump)
QEMU ?= qemu-system-aarch64
PYTHON ?= python3
QEMU_CPUS ?= 4

TARGET := aarch64-none-none-elf
SWIFT_SOURCES := $(shell find Kernel -name '*.swift' -type f | sort)

SWIFT_FLAGS := \
	-target $(TARGET) \
	-enable-experimental-feature Embedded \
	-wmo \
	-parse-as-library \
	-Osize \
	-module-name SwiftOSKernel \
	-module-cache-path $(MODULE_CACHE) \
	-Xfrontend -function-sections \
	-Xfrontend -disable-stack-protector

QEMU_FLAGS := \
	-machine virt,gic-version=3 \
	-cpu cortex-a72 \
	-accel tcg \
	-smp $(QEMU_CPUS) \
	-m 512M \
	-device ramfb,id=ramfb0 \
	-monitor none \
	-serial stdio \
	-no-reboot

.PHONY: all build run inspect smoke monitor-smoke frame-smoke smp-el0-smoke test host-test userland-test qemu-fdt-test rpi5-build rpi5-inspect rpi5-package clean toolchain-check source-check

all: build

build: $(KERNEL_ELF) $(KERNEL_BIN)

toolchain-check: | $(BUILD_DIR)
	@$(SWIFTC) -print-target-info -target $(TARGET) >/dev/null
	@$(SWIFTC) -target $(TARGET) \
		-enable-experimental-feature Embedded \
		-wmo -parse-as-library -Osize \
		-module-cache-path $(MODULE_CACHE) \
		-Xfrontend -disable-stack-protector \
		-emit-object Tests/Toolchain/EmbeddedProbe.swift \
		-o $(BUILD_DIR)/embedded-toolchain-probe.o
	@$(CLANG) --target=$(TARGET) --version >/dev/null
	@$(LD_LLD) --version >/dev/null
	@$(LLVM_OBJCOPY) --version >/dev/null
	@$(QEMU) --version >/dev/null

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR) $(MODULE_CACHE)

$(SWIFT_OBJECT): $(SWIFT_SOURCES) | $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) -emit-object $(SWIFT_SOURCES) -o $@

$(BOOT_OBJECT): Kernel/Arch/AArch64/Boot.S | $(BUILD_DIR)
	$(CLANG) --target=$(TARGET) -ffreestanding -fno-stack-protector -c $< -o $@

$(USERLAND_INIT_RAW): Userland/Init.swift | $(BUILD_DIR)
	$(SWIFTC) $(filter-out -module-name SwiftOSKernel,$(SWIFT_FLAGS)) \
		-module-name SwiftOSUserland -emit-object $< -o $@

$(USERLAND_SVC_RAW): Userland/Syscall.S | $(BUILD_DIR)
	$(CLANG) --target=$(TARGET) -ffreestanding -fno-stack-protector -c $< -o $@

$(USERLAND_OBJECT): $(USERLAND_INIT_RAW) $(USERLAND_SVC_RAW)
	$(LD_LLD) -flavor gnu -m aarch64elf -r --gc-sections \
		-u swiftos_user_init -o $@ $^

$(USERLAND_TEST_ELF): $(USERLAND_OBJECT) Tests/Toolchain/Userland.ld
	$(LD_LLD) -flavor gnu -m aarch64elf -nostdlib -static \
		--gc-sections --build-id=none -T Tests/Toolchain/Userland.ld \
		-o $@ $(USERLAND_OBJECT)

$(KERNEL_ELF): $(BOOT_OBJECT) $(SWIFT_OBJECT) $(USERLAND_OBJECT) Kernel/linker.ld
	$(LD_LLD) -flavor gnu -m aarch64elf -nostdlib -static \
		--gc-sections --build-id=none -T Kernel/linker.ld \
		-o $@ $(BOOT_OBJECT) $(SWIFT_OBJECT) $(USERLAND_OBJECT)

$(KERNEL_BIN): $(KERNEL_ELF)
	$(LLVM_OBJCOPY) -O binary $< $@

$(RPI5_BUILD_DIR):
	mkdir -p $@

$(RPI5_BOOT_OBJECT): Kernel/Arch/AArch64/Boot.S | $(RPI5_BUILD_DIR)
	$(CLANG) --target=$(TARGET) -DSWIFTOS_RPI5=1 \
		-ffreestanding -fno-stack-protector -c $< -o $@

$(RPI5_HEADER_OBJECT): Boards/RaspberryPi5/ImageHeader.S | $(RPI5_BUILD_DIR)
	$(CLANG) --target=$(TARGET) -ffreestanding -fno-stack-protector -c $< -o $@

$(RPI5_KERNEL_ELF): $(RPI5_HEADER_OBJECT) $(RPI5_BOOT_OBJECT) \
		$(SWIFT_OBJECT) $(USERLAND_OBJECT) Boards/RaspberryPi5/linker.ld
	$(LD_LLD) -flavor gnu -m aarch64elf -nostdlib -static \
		--gc-sections --build-id=none -T Boards/RaspberryPi5/linker.ld \
		-o $@ $(RPI5_HEADER_OBJECT) $(RPI5_BOOT_OBJECT) \
		$(SWIFT_OBJECT) $(USERLAND_OBJECT)

$(RPI5_KERNEL_IMAGE): $(RPI5_KERNEL_ELF)
	$(LLVM_OBJCOPY) -O binary $< $@

rpi5-build: $(RPI5_KERNEL_ELF) $(RPI5_KERNEL_IMAGE)

rpi5-inspect: rpi5-build
	LLVM_NM=$(LLVM_NM) LLVM_OBJDUMP=$(LLVM_OBJDUMP) \
		$(PYTHON) tools/validate_rpi5_image.py \
		$(RPI5_KERNEL_ELF) $(RPI5_KERNEL_IMAGE)

rpi5-package: rpi5-inspect
	@test -n "$(RPI5_FIRMWARE)" || \
		(echo "RPI5_FIRMWARE must name a pinned raspberrypi/firmware checkout" >&2; exit 2)
	Boards/RaspberryPi5/package-boot.sh $(RPI5_KERNEL_IMAGE) \
		$(RPI5_FIRMWARE) $(RPI5_BUILD_DIR)/boot

run: build
	$(QEMU) $(QEMU_FLAGS) -display cocoa -kernel $(KERNEL_BIN)

source-check:
	$(PYTHON) tools/validate_source_boundary.py

host-test:
	$(SWIFTC) --version
	mkdir -p $(BUILD_DIR)/host-module-cache
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Platform/FlattenedDeviceTree.swift \
		Kernel/Platform/Platform.swift \
		Tests/Host/FlattenedDeviceTreeTests.swift \
		-o $(BUILD_DIR)/fdt-host-tests
	$(BUILD_DIR)/fdt-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Monitor/MonitorCommand.swift \
		Tests/Host/MonitorCommandTests.swift \
		-o $(BUILD_DIR)/monitor-command-host-tests
	$(BUILD_DIR)/monitor-command-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Scheduler/RunQueue.swift \
		Tests/Host/RunQueueTests.swift \
		-o $(BUILD_DIR)/run-queue-host-tests
	$(BUILD_DIR)/run-queue-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Interrupts/ExceptionFrame.swift \
		Tests/Host/ExceptionFrameTests.swift \
		-o $(BUILD_DIR)/exception-frame-host-tests
	$(BUILD_DIR)/exception-frame-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Memory/PhysicalMemory.swift \
		Kernel/Memory/PageAllocator.swift \
		Kernel/Memory/PageTables.swift \
		Kernel/Memory/AddressSpace.swift \
		Tests/Host/MemoryFoundationTests.swift \
		-o $(BUILD_DIR)/memory-foundation-host-tests
	$(BUILD_DIR)/memory-foundation-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Platform/FlattenedDeviceTree.swift \
		Kernel/Platform/Platform.swift \
		Kernel/Memory/PhysicalMemory.swift \
		Kernel/Memory/PageAllocator.swift \
		Kernel/Memory/PageTables.swift \
		Kernel/Memory/AddressSpace.swift \
		Kernel/Memory/RuntimePhysicalMemory.swift \
		Kernel/Memory/FinalTranslationTables.swift \
		Tests/Host/RuntimeMemoryIntegrationTests.swift \
		-o $(BUILD_DIR)/runtime-memory-integration-host-tests
	$(BUILD_DIR)/runtime-memory-integration-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/Interrupts/ExceptionFrame.swift \
		Kernel/Scheduler/RunQueue.swift \
		Kernel/Scheduler/PreemptiveEL0Scheduler.swift \
		Tests/Host/PreemptiveEL0SchedulerTests.swift \
		-o $(BUILD_DIR)/preemptive-el0-scheduler-host-tests
	$(BUILD_DIR)/preemptive-el0-scheduler-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/SMP/ProcessorTopology.swift \
		Kernel/SMP/PSCITypes.swift \
		Tests/Host/SMPFoundationTests.swift \
		-o $(BUILD_DIR)/smp-foundation-host-tests
	$(BUILD_DIR)/smp-foundation-host-tests
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		Kernel/SMP/ProcessorTopology.swift \
		Kernel/SMP/PSCITypes.swift \
		Kernel/SMP/SMPRuntime.swift \
		Tests/Host/SMPRuntimeTests.swift \
		-o $(BUILD_DIR)/smp-runtime-host-tests
	$(BUILD_DIR)/smp-runtime-host-tests

userland-test: $(USERLAND_TEST_ELF)
	$(PYTHON) Tests/Toolchain/validate_userland_objects.py \
		--nm $(LLVM_NM) --objdump $(LLVM_OBJDUMP) \
		$(USERLAND_INIT_RAW) $(USERLAND_SVC_RAW) \
		$(USERLAND_OBJECT) $(USERLAND_TEST_ELF)

qemu-fdt-test: | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/host-module-cache
	$(QEMU) -machine virt,gic-version=3,dumpdtb=$(BUILD_DIR)/qemu-virt.dtb \
		-cpu cortex-a72 -m 512M -display none -monitor none -serial none
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		-emit-library \
		Kernel/Platform/FlattenedDeviceTree.swift \
		Kernel/Platform/Platform.swift \
		Tests/Host/QEMUDeviceTreeProbe.swift \
		-o $(BUILD_DIR)/libQEMUDeviceTreeProbe.dylib
	$(PYTHON) Tests/Host/qemu_fdt_probe.py \
		$(BUILD_DIR)/libQEMUDeviceTreeProbe.dylib $(BUILD_DIR)/qemu-virt.dtb

inspect: build
	LLVM_NM=$(LLVM_NM) LLVM_OBJDUMP=$(LLVM_OBJDUMP) \
		$(PYTHON) tools/validate_elf.py $(KERNEL_ELF)

smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/boot_smoke.py $(KERNEL_BIN) --boots 3
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/boot_smoke.py $(KERNEL_BIN) \
		--boots 1 --virtualization

monitor-smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/monitor_smoke.py $(KERNEL_BIN)

frame-smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/frame_smoke.py \
		$(KERNEL_BIN) --output $(BUILD_DIR)/swiftos-frame.ppm

smp-el0-smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/smp_el0_smoke.py $(KERNEL_BIN)
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/smp_el0_smoke.py \
		$(KERNEL_BIN) --virtualization

test: toolchain-check source-check host-test userland-test qemu-fdt-test inspect smoke monitor-smoke frame-smoke smp-el0-smoke rpi5-inspect

clean:
	rm -rf $(BUILD_DIR)
