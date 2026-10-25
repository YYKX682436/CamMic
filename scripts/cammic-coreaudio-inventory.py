#!/usr/bin/env python3
"""Parse and compare the CoreAudio inventory emitted by cammic-coreaudio-inspect."""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any


DEVICE_RE = re.compile(
    r"^device id=\d+ name=(?P<name>.*?) uid=(?P<uid>.*?) "
    r"manufacturer=(?P<manufacturer>.*?) input=(?P<input>\??\d+) "
    r"output=(?P<output>\??\d+) hidden=(?P<hidden>\??\d+) "
    r"running=(?P<running>\??\d+) canBeDefault=(?P<canBeDefault>\??\d+) "
    r"transport=(?P<transport>\??0x[0-9a-fA-F]+) owner=(?P<owner>\d+) "
    r"ownerClass=(?P<ownerClass>[0-9a-fA-F]+)$"
)
PLUGIN_RE = re.compile(r"^plugin id=\d+ class=(?P<class>[0-9a-fA-F]+) bundleID=(?P<bundleID>.*)$")
DEFAULT_RE = re.compile(
    r"^(?P<kind>defaultInput|defaultOutput|defaultSystemOutput) "
    r"id=\d+ name=(?P<name>.*?) uid=(?P<uid>.*)$"
)
DEFAULTS_REQUIRED = {"defaultInput", "defaultOutput", "defaultSystemOutput"}
CAMMIC_PLUGIN = "com.yykx682436.CamMicAudioDriver"


class InventoryError(ValueError):
    pass


def parse_inventory(text: str) -> dict[str, Any]:
    devices: list[dict[str, str]] = []
    plugins: list[dict[str, str]] = []
    defaults: dict[str, dict[str, str]] = {}
    device_rows = 0
    plugin_rows = 0

    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("device id="):
            device_rows += 1
            match = DEVICE_RE.fullmatch(line)
            if not match:
                raise InventoryError(f"unparsed device row at line {line_number}: {line}")
            device = match.groupdict()
            if not device["name"] or not device["uid"] or not device["manufacturer"]:
                raise InventoryError(f"device row has an empty identity at line {line_number}")
            if not device["uid"].startswith("CamMic"):
                devices.append(device)
            continue

        if line.startswith("plugin id="):
            plugin_rows += 1
            match = PLUGIN_RE.fullmatch(line)
            if not match:
                raise InventoryError(f"unparsed plug-in row at line {line_number}: {line}")
            plugin = match.groupdict()
            if plugin["bundleID"] != CAMMIC_PLUGIN:
                plugins.append(plugin)
            continue

        match = DEFAULT_RE.fullmatch(line)
        if match:
            values = match.groupdict()
            defaults[values.pop("kind")] = values

    if device_rows == 0 or not devices:
        raise InventoryError("CoreAudio inventory must contain at least one parsed unrelated device")
    if plugin_rows == 0 or not plugins:
        raise InventoryError("CoreAudio inventory must contain at least one parsed unrelated plug-in")
    missing_defaults = DEFAULTS_REQUIRED - defaults.keys()
    if missing_defaults:
        raise InventoryError(f"CoreAudio inventory is missing defaults: {', '.join(sorted(missing_defaults))}")
    if len({device["uid"] for device in devices}) != len(devices):
        raise InventoryError("CoreAudio inventory contains duplicate unrelated device UIDs")
    return {
        "devices": sorted(devices, key=lambda item: item["uid"]),
        # CoreAudio may expose multiple transient instances for the same HAL
        # plug-in bundle. Compare the stable registered identity, not instance count.
        "plugins": sorted(
            { (item["bundleID"], item["class"]): item for item in plugins }.values(),
            key=lambda item: (item["bundleID"], item["class"]),
        ),
        "defaults": defaults,
    }


def same_inventory(expected: dict[str, Any], actual: dict[str, Any]) -> bool:
    return expected == actual


def fixture() -> str:
    return "\n".join(
        [
            "CoreAudio deviceCount=3",
            "device id=10 name=Mac mini扬声器 uid=BuiltInSpeakerDevice manufacturer=Apple Inc. input=0 output=2 hidden=0 running=0 canBeDefault=1 transport=0x626c746e owner=1 ownerClass=61737973",
            "device id=11 name=CamMic uid=CamMic2ch_UID manufacturer=CamMic input=2 output=0 hidden=0 running=1 canBeDefault=1 transport=0x76697274 owner=1 ownerClass=61737973",
            "plugin id=20 class=61706c67 bundleID=com.apple.audio.CoreAudio",
            "plugin id=21 class=61706c67 bundleID=com.yykx682436.CamMicAudioDriver",
            "defaultInput id=11 name=CamMic uid=CamMic2ch_UID",
            "defaultOutput id=10 name=Mac mini扬声器 uid=BuiltInSpeakerDevice",
            "defaultSystemOutput id=10 name=Mac mini扬声器 uid=BuiltInSpeakerDevice",
        ]
    ) + "\n"


def self_test() -> None:
    source = fixture()
    baseline = parse_inventory(source)
    mutations = {
        "device name": ("name=Mac mini扬声器", "name=Changed Speaker"),
        "device UID": ("uid=BuiltInSpeakerDevice", "uid=ChangedSpeakerUID"),
        "manufacturer": ("manufacturer=Apple Inc.", "manufacturer=Changed Vendor"),
        "channel count": ("output=2", "output=1"),
        "hidden state": ("hidden=0", "hidden=1"),
        "running state": ("running=0", "running=1"),
        "default eligibility": ("canBeDefault=1", "canBeDefault=0"),
        "transport": ("transport=0x626c746e", "transport=0x76697274"),
        "owning object": ("owner=1 ownerClass=61737973", "owner=2 ownerClass=61737973"),
        "owner class": ("ownerClass=61737973", "ownerClass=61706c67"),
    }
    for label, (old, new) in mutations.items():
        changed = source.replace(old, new, 1)
        if changed == source or same_inventory(baseline, parse_inventory(changed)):
            raise InventoryError(f"reverse test failed to detect changed {label}")
        print(f"reverse test passed: changed {label} makes inventory differ")

    for invalid in ("", "device id=1 name=CamMic uid=CamMic2ch_UID manufacturer=CamMic input=2 output=0 hidden=0 running=0 canBeDefault=1 transport=0x76697274 owner=1 ownerClass=61737973\n"):
        try:
            parse_inventory(invalid)
        except InventoryError:
            continue
        raise InventoryError("reverse test failed to reject an empty unrelated-device inventory")
    print("reverse test passed: empty unrelated-device inventory is rejected")


def main(argv: list[str]) -> int:
    if argv == ["self-test"]:
        self_test()
        return 0
    if len(argv) == 3 and argv[0] == "snapshot":
        source = pathlib.Path(argv[1]).read_text(encoding="utf-8")
        summary = parse_inventory(source)
        pathlib.Path(argv[2]).write_text(
            json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"snapshot passed: {len(summary['devices'])} unrelated devices, {len(summary['plugins'])} unrelated plug-ins")
        return 0
    if len(argv) == 3 and argv[0] == "compare":
        expected = json.loads(pathlib.Path(argv[1]).read_text(encoding="utf-8"))
        actual = json.loads(pathlib.Path(argv[2]).read_text(encoding="utf-8"))
        if same_inventory(expected, actual):
            print("unrelated CoreAudio inventory unchanged")
            return 0
        print("unrelated CoreAudio inventory changed", file=sys.stderr)
        print(json.dumps({"expected": expected, "actual": actual}, ensure_ascii=False, indent=2, sort_keys=True), file=sys.stderr)
        return 1
    print("usage: cammic-coreaudio-inventory.py self-test | snapshot RAW SUMMARY | compare EXPECTED SUMMARY", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (InventoryError, OSError, json.JSONDecodeError) as error:
        print(f"CoreAudio inventory validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
