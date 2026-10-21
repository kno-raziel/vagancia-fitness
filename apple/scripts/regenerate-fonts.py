#!/usr/bin/env python3
"""Reproduce bundled TTFs offline from explicitly supplied Fontsource packages.

--source-root contains @fontsource/<family>/{package.json,LICENSE,files/...}.
Nothing is downloaded or installed. All input, license and resulting TTF hashes
must match the checked-in manifest before any output is written. Supply
--output-dir to verify in a disposable directory; omit it to restore bundled TTFs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "apple/Apps/VaganciaFitness/Resources/Brand/font-manifest.json"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def checksum(data):
    padded = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(padded) // 4}I", padded)) & 0xFFFFFFFF


def woff1_to_ttf(data):
    """Restore a sorted sfnt directory, preserve tables, recompute head checksum.

    No OpenType outlines, names or timestamps are changed. Only WOFF1 TrueType
    inputs are accepted; WOFF2 and CFF fonts require a separate reviewed path.
    """
    if len(data) < 44:
        raise ValueError("Truncated WOFF header")
    signature, flavor, length, count, reserved, sfnt_size = struct.unpack_from(">4sIIHHI", data)
    if signature != b"wOFF" or flavor != 0x00010000 or reserved or length != len(data) or not 0 < count <= 4095:
        raise ValueError("Expected a valid WOFF1 TrueType header")
    if len(data) < 44 + 20 * count or not 12 + 16 * count <= sfnt_size <= 16 * 1024 * 1024:
        raise ValueError("Invalid WOFF table directory or sfnt size")
    tables = {}
    intervals = []
    for index in range(count):
        tag, offset, compressed_size, original_size, original_checksum = struct.unpack_from(">4sIIII", data, 44 + 20 * index)
        if tag in tables or offset % 4 or offset < 44 + 20 * count or compressed_size > original_size or offset + compressed_size > len(data) or original_size > sfnt_size:
            raise ValueError("Invalid WOFF table entry")
        if any(offset < end and offset + compressed_size > start for start, end in intervals):
            raise ValueError("Overlapping WOFF tables")
        intervals.append((offset, offset + compressed_size))
        block = data[offset:offset + compressed_size]
        if compressed_size < original_size:
            inflater = zlib.decompressobj()
            block = inflater.decompress(block, original_size + 1)
            if not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
                raise ValueError("Invalid compressed WOFF table")
        if len(block) != original_size:
            raise ValueError("WOFF table length mismatch")
        if tag == b"head":
            if len(block) < 54:
                raise ValueError("Invalid head table")
            block = block[:8] + b"\0" * 4 + block[12:]
        if checksum(block) != original_checksum:
            raise ValueError(f"WOFF table checksum mismatch: {tag!r}")
        tables[tag] = (block, original_checksum)
    if b"head" not in tables:
        raise ValueError("WOFF has no head table")
    power = 1 << (count.bit_length() - 1)
    header = struct.pack(">IHHHH", flavor, count, power * 16, power.bit_length() - 1, count * 16 - power * 16)
    directory = bytearray()
    blocks = bytearray()
    offset = 12 + count * 16
    head_offset = None
    for tag, (block, original_checksum) in sorted(tables.items()):
        directory.extend(struct.pack(">4sIII", tag, original_checksum, offset, len(block)))
        if tag == b"head":
            head_offset = offset
        blocks.extend(block)
        blocks.extend(b"\0" * (-len(block) % 4))
        offset += (len(block) + 3) & ~3
    output = bytearray(header + directory + blocks)
    if len(output) != sfnt_size:
        raise ValueError("Reconstructed sfnt size mismatch")
    struct.pack_into(">I", output, head_offset + 8, (0xB1B0AFBA - checksum(output)) & 0xFFFFFFFF)
    if checksum(output) != 0xB1B0AFBA:
        raise ValueError("Reconstructed sfnt checksum mismatch")
    return bytes(output)


def regenerate(source_root, output_dir=None):
    outputs = []
    licenses = {}
    for font in json.loads(MANIFEST.read_text()):
        source = source_root / font["source"]
        package_dir = source.parent.parent
        package = json.loads((package_dir / "package.json").read_text())
        if package["name"] != font["sourcePackage"] or package["version"] != font["sourcePackageVersion"]:
            raise ValueError(f"Unexpected package name/version for {font['sourcePackage']}")
        license_bytes = (package_dir / "LICENSE").read_bytes()
        if sha256(license_bytes) != font["licenseSHA256"]:
            raise ValueError(f"OFL checksum mismatch for {font['family']}")
        bundled_license = ROOT / font["ttf"]
        bundled_license = bundled_license.parent / f"{font['family']}-LICENSE.txt"
        if bundled_license.read_bytes() != license_bytes:
            raise ValueError(f"Bundled OFL differs for {font['family']}")
        original = source.read_bytes()
        if sha256(original) != font["sourceSHA256"]:
            raise ValueError(f"Input WOFF checksum mismatch for {font['source']}")
        output = woff1_to_ttf(original)
        if sha256(output) != font["ttfSHA256"]:
            raise ValueError(f"Reconstructed TTF checksum mismatch for {font['ttf']}")
        destination = output_dir / Path(font["ttf"]).name if output_dir else ROOT / font["ttf"]
        outputs.append((destination, output))
        if output_dir:
            licenses[output_dir / bundled_license.name] = license_bytes
    # Validate the complete batch before writing, so a mismatch cannot partially
    # replace bundled fonts. Public input locations stay caller supplied.
    for destination, output in outputs + list(licenses.items()):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(output)
    return len(outputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    try:
        count = regenerate(args.source_root, args.output_dir)
        print(f"Fonts: {count} TTFs reproduced byte for byte; input/output hashes and OFL verified.")
    except (OSError, ValueError, KeyError, struct.error, zlib.error) as error:
        print(f"Font regeneration failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
