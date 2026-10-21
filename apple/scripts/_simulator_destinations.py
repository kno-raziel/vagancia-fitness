#!/usr/bin/env python3
"""Intersect CoreSimulator availability with destinations accepted by the scheme."""

import argparse
import json
import re
import subprocess
import sys


def run_tool(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(
            f"{' '.join(arguments)} failed ({result.returncode}):\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def usable_devices(simulators, destinations):
    # Ineligible records may contain real UUIDs as well as placeholder IDs.
    available = destinations.split("Ineligible destinations", 1)[0]
    accepted_architectures = {}
    for record in re.findall(r"\{([^{}]+)\}", available):
        fields = dict(re.findall(r"(?:^|,)\s*([^:,]+):\s*([^,}]+)", record))
        if fields.get("platform", "").strip() == "iOS Simulator" and "error" not in fields:
            accepted_architectures.setdefault(fields.get("id", "").strip(), set()).add(
                fields.get("arch", "").strip())
    devices = []
    for runtime, entries in simulators.get("devices", {}).items():
        version = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)((?:-\d+)*)", runtime)
        if not version or int(version[1]) < 26:
            continue
        os_version = runtime.split("iOS-", 1)[1].replace("-", ".")
        for device in entries:
            if (device.get("isAvailable") and device.get("name", "").startswith("iPhone")
                    and device.get("udid") in accepted_architectures):
                devices.append({**device, "OS": os_version,
                                "architectures": accepted_architectures[device["udid"]]})
    return sorted(devices, key=lambda device: (
        device.get("state") != "Booted", device.get("name", ""), device["OS"], device["udid"]
    ))


def select_destination(devices, requested):
    fields = {}
    if requested:
        for part in requested.split(","):
            key, separator, value = part.strip().partition("=")
            if not separator or key in fields or key not in {"platform", "id", "name", "OS", "arch"}:
                raise ValueError(f"Unsupported simulator DESTINATION field: {part}")
            fields[key] = value
        if fields.get("platform") != "iOS Simulator":
            raise ValueError("Tests require DESTINATION platform=iOS Simulator.")
    matches = [device for device in devices if all(
        key not in fields or fields[key] == device[value]
        for key, value in (("id", "udid"), ("name", "name"), ("OS", "OS"))
        if not (key == "OS" and fields.get("OS") == "latest")
    ) and ("arch" not in fields or fields["arch"] in device.get("architectures", set()))]
    if fields.get("OS") == "latest" and matches:
        latest = max(tuple(map(int, device["OS"].split("."))) for device in matches)
        matches = [device for device in matches if tuple(map(int, device["OS"].split("."))) == latest]
    if not matches:
        raise ValueError(f"No usable iOS 26+ iPhone simulator matches {requested or 'automatic selection'}.")
    destination = "platform=iOS Simulator,id=" + matches[0]["udid"]
    if "arch" in fields:
        destination += ",arch=" + fields["arch"]
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--scheme", default="VaganciaFitness")
    parser.add_argument("--configuration", default="Debug", choices=("Debug", "Release"))
    parser.add_argument("--destination", default="")
    parser.add_argument("--count", action="store_true")
    args = parser.parse_args()
    try:
        simulators = json.loads(run_tool(["xcrun", "simctl", "list", "devices", "available", "--json"]))
        destinations = run_tool(["xcodebuild", "-project", args.project, "-scheme", args.scheme,
                                 "-configuration", args.configuration, "-showdestinations"])
        devices = usable_devices(simulators, destinations)
        if args.count:
            print(len(devices))
        else:
            print(select_destination(devices, args.destination))
    except (ValueError, OSError, TypeError, KeyError, AttributeError) as error:
        print(f"Simulator preflight failed: {error}", file=sys.stderr)
        print("Select a full Xcode with DEVELOPER_DIR or xcode-select; inspect xcrun simctl list runtimes "
              "and xcodebuild -project apple/VaganciaFitness.xcodeproj -scheme " + args.scheme +
              " -showdestinations. Choose an installed compatible runtime and DESTINATION; "
              "this command never downloads runtimes.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
