#!/usr/bin/env python3
"""Validate the unsigned device IPA without requiring a local Xcode install."""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def inspect_macho(data):
    require(len(data) >= 32, "Truncated Mach-O")
    magic, cpu, _, _, count, command_size, _, _ = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected thin arm64 Mach-O")
    end = 32 + command_size
    require(end <= len(data), "Truncated load commands")
    offset = 32
    platform = minimum = None
    signed = False
    for _ in range(count):
        require(offset + 8 <= end, "Truncated load command")
        command, size = struct.unpack_from("<2I", data, offset)
        require(size >= 8 and offset + size <= end, "Invalid load command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Invalid build version")
            platform, minimum = struct.unpack_from("<2I", data, offset + 8)
        if command == 0x1D:  # LC_CODE_SIGNATURE, including ad-hoc signatures
            signed = True
        offset += size
    require(offset == end, "Invalid load command count")
    require(platform == 2, f"Expected iPhoneOS platform (2), got {platform}")
    require(not signed, "Unexpected Mach-O code signature")
    require(minimum == 0x110000, f"Expected iOS 17.0, got {minimum}")
    return {"architecture": "arm64", "platform": "iPhoneOS", "minimum_ios": version(minimum), "signed": signed}


def verify(path):
    bundles = [
        ("Payload/HotspotProxy.app", "HotspotProxy", "com.indoyoon.hotspotproxy"),
        ("Payload/HotspotProxy.app/PlugIns/HotspotProxyWidget.appex", "HotspotProxyWidget", "com.indoyoon.hotspotproxy.widget"),
    ]
    report = {"file": path.name, "size_bytes": path.stat().st_size,
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bundles": []}
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "ZIP CRC check failed")
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP entries")
        require(all(n == "Payload/" or n.startswith("Payload/HotspotProxy.app/") for n in names), "Unexpected top-level structure")
        require(not any("_CodeSignature" in n or n.endswith("embedded.mobileprovision") for n in names), "Unexpected signature/profile")
        for bundle, executable, identifier in bundles:
            info = plistlib.loads(archive.read(f"{bundle}/Info.plist"))
            require(info["CFBundleExecutable"] == executable, "Unexpected executable name")
            require(info["CFBundleIdentifier"] == identifier, "Unexpected bundle ID")
            require(info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "Unexpected plist platform")
            require(info["MinimumOSVersion"] in ("17.0", "17.0.0"), "Unexpected minimum OS")
            require(info["UIDeviceFamily"] == [1], "Expected iPhone device family")
            member = archive.getinfo(f"{bundle}/{executable}")
            require((member.external_attr >> 16) & 0o111, "Executable permission missing")
            result = inspect_macho(archive.read(member))
            report["bundles"].append({"path": bundle, "bundle_id": identifier, "executable": executable, **result})
    report["zip_integrity"] = "passed"
    report["signature"] = "unsigned"
    report["device_installation"] = "not tested"
    return report


if __name__ == "__main__":
    print(json.dumps(verify(Path(sys.argv[1])), indent=2))
