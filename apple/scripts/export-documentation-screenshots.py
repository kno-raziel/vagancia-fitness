#!/usr/bin/env python3
"""Refresh reviewed documentation screenshots from synthetic XCTest attachments.

Only the fixed product/debug capture names and test identifiers are accepted.
Existing documentation images at these fixed names are replaced for a refresh.
Original attachments and their manifest remain unchanged. PNG pixel data is not
reencoded: validated image/color chunks are copied verbatim; ancillary metadata
such as EXIF, XMP, text and timestamps is removed. This does not inspect pixels
for private content; review the synthetic captures before invoking this command.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
RETAINED_CHUNKS = {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"sRGB", b"gAMA", b"cHRM", b"iCCP"}
PNG_BASENAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.png\Z")
CAPTURES = {
    "product": (
        "VaganciaFitnessUITests/testCaptureProductScreensAcrossThePrimaryFlows()",
        {"product-home": "app-home.png", "product-active-workout": "app-workout.png",
         "product-activity": "app-history.png"},
    ),
    "debug": (
        "SessionFlowTests/testNativeLiquidGlassTabsKeepHistoricalMetricsAndMotorGates()",
        {"liquid-glass-session": "app-debug.png"},
    ),
}


def strip_png_metadata(data):
    """Validate PNG chunk framing/CRCs and preserve retained chunks byte for byte."""
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Invalid PNG signature")
    output = bytearray(PNG_SIGNATURE)
    offset = len(PNG_SIGNATURE)
    seen = set()
    data_ended = False
    color_type = None
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError("Truncated PNG chunk")
        length, kind = struct.unpack_from(">I4s", data, offset)
        end = offset + 12 + length
        if length > 0x7FFFFFFF or end > len(data):
            raise ValueError("Invalid or truncated PNG chunk length")
        if not re.fullmatch(b"[A-Za-z]{4}", kind) or kind[2] & 32:
            raise ValueError("Invalid PNG chunk type")
        payload = data[offset + 8:end - 4]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise ValueError(f"PNG CRC mismatch in {kind.decode('ascii')}")
        if not seen and kind != b"IHDR":
            raise ValueError("PNG must start with IHDR")
        if kind not in RETAINED_CHUNKS and not kind[0] & 32:
            raise ValueError(f"Unsupported critical PNG chunk: {kind.decode('ascii')}")
        if kind in {b"acTL", b"fcTL", b"fdAT"}:
            raise ValueError("Animated PNG attachments are unsupported")
        if kind in RETAINED_CHUNKS - {b"IDAT"} and kind in seen:
            raise ValueError(f"Duplicate PNG chunk: {kind.decode('ascii')}")
        if kind == b"IHDR":
            if length != 13:
                raise ValueError("Invalid IHDR length")
            width, height, depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
            if (not 0 < width <= 0x7FFFFFFF or not 0 < height <= 0x7FFFFFFF
                    or depth not in depths.get(color_type, set()) or compression or filtering or interlace not in (0, 1)):
                raise ValueError("Invalid PNG image header")
        elif kind == b"PLTE":
            if b"IDAT" in seen or not length or length % 3 or length > 768 or color_type in (0, 4):
                raise ValueError("Invalid PNG palette")
        elif kind == b"IDAT":
            if data_ended or (color_type == 3 and b"PLTE" not in seen):
                raise ValueError("Invalid PNG image data order")
        elif kind == b"IEND":
            if length or b"IDAT" not in seen or end != len(data):
                raise ValueError("Invalid PNG ending or trailing data")
        elif kind in {b"sRGB", b"gAMA", b"cHRM", b"iCCP", b"tRNS"}:
            if b"IDAT" in seen:
                raise ValueError("PNG color/transparency chunks must precede image data")
            lengths = {b"sRGB": 1, b"gAMA": 4, b"cHRM": 32}
            if kind in lengths and length != lengths[kind]:
                raise ValueError("Invalid PNG color chunk length")
            if kind == b"tRNS" and (color_type in (4, 6) or (color_type == 0 and length != 2)
                                    or (color_type == 2 and length != 6)
                                    or (color_type == 3 and (b"PLTE" not in seen or not length))):
                raise ValueError("Invalid PNG transparency chunk")
        if b"IDAT" in seen and kind != b"IDAT":
            data_ended = True
        seen.add(kind)
        if kind in RETAINED_CHUNKS:
            output.extend(data[offset:end])
        offset = end
    if b"IEND" not in seen:
        raise ValueError("PNG is missing IEND")
    return bytes(output)


def safe_attachment(directory, name):
    if not isinstance(name, str) or not PNG_BASENAME.fullmatch(name):
        raise ValueError("Exported attachment filename must be a safe PNG basename")
    path = directory / name
    if not path.resolve().is_relative_to(directory):
        raise ValueError("Exported attachment escapes its directory")
    if not path.is_file():
        raise ValueError(f"Missing attachment: {name}")
    return path


def prepare_exports(directory, kind, destination):
    """Read and validate every selected input/output before any files are written."""
    directory = directory.resolve()
    destination = destination.resolve()
    if directory == destination:
        raise ValueError("Attachment and output directories must differ")
    if destination.exists() and not destination.is_dir():
        raise ValueError("Output directory must be a directory")
    manifest = directory / "manifest.json"
    if not manifest.resolve().is_relative_to(directory):
        raise ValueError("Attachment manifest escapes its directory")
    records = json.loads(manifest.read_text())
    if not isinstance(records, list):
        raise ValueError("Attachment manifest must contain a list of test records")
    test_identifier, names = CAPTURES[kind]
    selected = {}
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("Attachment manifest test records must be objects")
        if record.get("testIdentifier") != test_identifier:
            continue
        attachments = record.get("attachments")
        if not isinstance(attachments, list):
            raise ValueError("Selected test must contain an attachments list")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise ValueError("Attachment records must be objects")
            label = attachment.get("suggestedHumanReadableName", "")
            if not isinstance(label, str):
                raise ValueError("Attachment labels must be strings")
            for name, output_name in names.items():
                if not label.startswith(name + "_"):
                    continue
                if not PNG_BASENAME.fullmatch(label):
                    raise ValueError("Selected attachment label must be a safe PNG basename")
                if output_name in selected:
                    raise ValueError(f"Ambiguous duplicate capture: {name}")
                source = safe_attachment(directory, attachment.get("exportedFileName"))
                target = destination / output_name
                if target.is_symlink() or not target.resolve().is_relative_to(destination):
                    raise ValueError(f"Unsafe output path: {output_name}")
                if target.exists() and not target.is_file():
                    raise ValueError(f"Output must be a regular file: {output_name}")
                selected[output_name] = (target, strip_png_metadata(source.read_bytes()))
    missing = set(names.values()) - selected.keys()
    if missing:
        raise ValueError(f"Missing captures for {test_identifier}: {', '.join(sorted(missing))}")
    return destination, list(selected.values())


def export_screenshots(directory, kind, destination):
    destination, prepared = prepare_exports(directory, kind, destination)
    destination.mkdir(parents=True, exist_ok=True)
    for target, data in prepared:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination, prefix=".screenshot-", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(data)
            os.replace(temporary, target)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return [target.name for target, _ in prepared]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachment_directory", type=Path, help="Directory exported by xcresulttool, including manifest.json")
    parser.add_argument("--kind", choices=tuple(CAPTURES), required=True)
    parser.add_argument("--output-directory", type=Path, default=ROOT / "docs/images")
    args = parser.parse_args()
    try:
        names = export_screenshots(args.attachment_directory, args.kind, args.output_directory)
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        print(f"Screenshot export failed: {error}", file=sys.stderr)
        return 1
    print("Refreshed reviewed synthetic screenshots (pixel data unchanged): " + ", ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
