SHELL := /bin/sh

BUILD_DIR := .build
MODULE_CACHE := $(BUILD_DIR)/module-cache
KERNEL_ELF := $(BUILD_DIR)/swiftos.elf
KERNEL_BIN := $(BUILD_DIR)/swiftos.bin
SWIFT_OBJECT := $(BUILD_DIR)/kernel.o
BOOT_OBJECT := $(BUILD_DIR)/boot.o

SWIFTC ?= swiftc
CLANG ?= clang
LD_LLD ?= ld.lld
LLVM_OBJCOPY ?= llvm-objcopy
LLVM_NM ?= $(shell xcrun --find llvm-nm)
LLVM_OBJDUMP ?= $(shell xcrun --find llvm-objdump)
QEMU ?= qemu-system-aarch64
PYTHON ?= python3

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
	-smp 1 \
	-m 512M \
	-device ramfb,id=ramfb0 \
	-monitor none \
	-serial stdio \
	-no-reboot

.PHONY: all build run inspect smoke gui-smoke test host-test qemu-fdt-test clean toolchain-check source-check

all: build

build: $(KERNEL_ELF) $(KERNEL_BIN)

toolchain-check:
	@$(SWIFTC) -print-target-info -target $(TARGET) >/dev/null
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

$(KERNEL_ELF): $(BOOT_OBJECT) $(SWIFT_OBJECT) Kernel/linker.ld
	$(LD_LLD) -flavor gnu -m aarch64elf -nostdlib -static \
		--gc-sections --build-id=none -T Kernel/linker.ld \
		-o $@ $(BOOT_OBJECT) $(SWIFT_OBJECT)

$(KERNEL_BIN): $(KERNEL_ELF)
	$(LLVM_OBJCOPY) -O binary $< $@

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
		Tests/Host/FlattenedDeviceTreeTests.swift \
		-o $(BUILD_DIR)/fdt-host-tests
	$(BUILD_DIR)/fdt-host-tests

qemu-fdt-test: | $(BUILD_DIR)
	$(QEMU) -machine virt,dumpdtb=$(BUILD_DIR)/qemu-virt.dtb \
		-cpu cortex-a72 -m 512M -display none -monitor none -serial none
	$(SWIFTC) -parse-as-library \
		-module-cache-path $(BUILD_DIR)/host-module-cache \
		-emit-library \
		Kernel/Platform/FlattenedDeviceTree.swift \
		Tests/Host/QEMUDeviceTreeProbe.swift \
		-o $(BUILD_DIR)/libQEMUDeviceTreeProbe.dylib
	$(PYTHON) Tests/Host/qemu_fdt_probe.py \
		$(BUILD_DIR)/libQEMUDeviceTreeProbe.dylib $(BUILD_DIR)/qemu-virt.dtb

inspect: build
	LLVM_NM=$(LLVM_NM) LLVM_OBJDUMP=$(LLVM_OBJDUMP) \
		$(PYTHON) tools/validate_elf.py $(KERNEL_ELF)

smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/boot_smoke.py $(KERNEL_BIN) --boots 3

gui-smoke: build
	QEMU=$(QEMU) $(PYTHON) Tests/Smoke/gui_smoke.py \
		$(KERNEL_BIN) --output $(BUILD_DIR)/swiftos-gui.ppm

test: toolchain-check source-check host-test qemu-fdt-test inspect smoke gui-smoke

clean:
	rm -rf $(BUILD_DIR)
