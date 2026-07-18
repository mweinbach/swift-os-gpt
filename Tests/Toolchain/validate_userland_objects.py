#!/usr/bin/env python3

import argparse
import re
import subprocess
import sys


def run(*arguments: str) -> str:
    completed = subprocess.run(
        arguments,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nm", required=True)
    parser.add_argument("--objdump", required=True)
    parser.add_argument("init_object")
    parser.add_argument("svc_object")
    parser.add_argument("combined_object")
    parser.add_argument("linked_image")
    arguments = parser.parse_args()

    init_symbols = run(arguments.nm, "-g", arguments.init_object)
    svc_symbols = run(arguments.nm, "-g", arguments.svc_object)
    svc_disassembly = run(arguments.objdump, "-d", arguments.svc_object)
    section_headers = run(
        arguments.objdump,
        "--section-headers",
        arguments.svc_object,
    )
    image_symbols = run(arguments.nm, "-a", arguments.linked_image)
    image_undefined = run(arguments.nm, "-u", arguments.linked_image)
    image_sections = run(
        arguments.objdump,
        "--section-headers",
        arguments.linked_image,
    )
    combined_symbols = run(arguments.nm, "-a", arguments.combined_object)
    combined_undefined = run(arguments.nm, "-u", arguments.combined_object)

    if not re.search(r"\bT\s+swiftos_user_init$", init_symbols, re.MULTILINE):
        raise RuntimeError("user init object does not export swiftos_user_init")
    if not re.search(r"\bU\s+swiftos_user_svc$", init_symbols, re.MULTILINE):
        raise RuntimeError("user init object does not import only the SVC veneer")

    if not re.search(r"\bT\s+swiftos_user_svc$", svc_symbols, re.MULTILINE):
        raise RuntimeError("SVC object does not export swiftos_user_svc")
    if ".text.swiftos.user.svc" not in section_headers:
        raise RuntimeError("SVC veneer is not in its dedicated text section")
    if len(re.findall(r"\s+svc\s+#", svc_disassembly)) != 1:
        raise RuntimeError("SVC veneer must contain exactly one svc instruction")
    if image_undefined.strip():
        raise RuntimeError(f"linked user payload has dependencies: {image_undefined}")
    if combined_undefined.strip():
        raise RuntimeError(
            f"combined user object has dependencies: {combined_undefined}"
        )
    if ".swift_modhash" in image_sections:
        raise RuntimeError("Swift module hash escaped the isolated rodata section")

    for required_symbol in ("swiftos_user_init", "swiftos_user_svc", "__user_entry"):
        if not re.search(rf"\b{required_symbol}$", image_symbols, re.MULTILINE):
            raise RuntimeError(f"linked user payload is missing {required_symbol}")

    for forbidden_symbol in ("free", "memset", "posix_memalign", "swift_slowAlloc"):
        if re.search(rf"\b{forbidden_symbol}$", combined_symbols, re.MULTILINE):
            raise RuntimeError(
                f"combined user object unexpectedly retains {forbidden_symbol}"
            )
        if re.search(rf"\b{forbidden_symbol}$", image_symbols, re.MULTILINE):
            raise RuntimeError(
                f"live user payload unexpectedly retains {forbidden_symbol}"
            )

    print("userland object contract: passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"userland object contract: {error}", file=sys.stderr)
        sys.exit(1)
