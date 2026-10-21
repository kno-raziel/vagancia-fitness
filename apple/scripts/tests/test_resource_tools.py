#!/usr/bin/env python3
"""Offline regression checks for font conversion and privacy resource validation."""
import importlib.machinery
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zlib

SCRIPTS = Path(__file__).resolve().parents[1]


def load_script(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(SCRIPTS / filename))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


fonts = load_script("font_resources", "regenerate-fonts.py")
privacy = load_script("privacy_resources", "check-privacy")


def synthetic_woff():
    # This fixture contains synthetic bytes, not redistributed font input.
    head = bytes(54)
    glyph = b"synthetic outline bytes" * 24
    blocks = []
    entries = []
    offset = 44 + 2 * 20
    for tag, original in [(b"glyf", glyph), (b"head", head)]:
        compressed = zlib.compress(original)
        entries.append(struct.pack(">4sIIII", tag, offset, len(compressed), len(original), fonts.checksum(original)))
        block = compressed + b"\0" * (-len(compressed) % 4)
        blocks.append(block)
        offset += len(block)
    sfnt_size = 12 + 2 * 16 + ((len(glyph) + 3) & ~3) + ((len(head) + 3) & ~3)
    header = struct.pack(">4sIIHHIHHIIIII", b"wOFF", 0x00010000, offset, 2, 0, sfnt_size, 1, 0, 0, 0, 0, 0, 0)
    return header + b"".join(entries) + b"".join(blocks), glyph


class FontConversionTests(unittest.TestCase):
    def test_reconstructs_tables_and_valid_whole_font_checksum(self):
        woff, glyph = synthetic_woff()
        ttf = fonts.woff1_to_ttf(woff)
        self.assertEqual(fonts.checksum(ttf), 0xB1B0AFBA)
        self.assertEqual(ttf, fonts.woff1_to_ttf(woff))
        tables = {}
        for index in range(2):
            tag, digest, offset, size = struct.unpack_from(">4sIII", ttf, 12 + index * 16)
            tables[tag] = ttf[offset:offset + size]
        self.assertEqual(tables[b"glyf"], glyph)
        self.assertEqual(tables[b"head"][:8] + bytes(4) + tables[b"head"][12:], bytes(54))

    def test_rejects_truncation_bad_format_checksum_and_overlap(self):
        woff, _ = synthetic_woff()
        broken_checksum = bytearray(woff)
        broken_checksum[60] ^= 1
        overlap = bytearray(woff)
        overlap[68:72] = overlap[48:52]
        for invalid in [b"", woff[:-1], b"wOF2" + woff[4:], broken_checksum, overlap]:
            with self.subTest(invalid=bytes(invalid)[:8]), self.assertRaises(ValueError):
                fonts.woff1_to_ttf(invalid)


class PrivacyResourceTests(unittest.TestCase):
    def test_checked_in_sources_and_resource_declarations(self):
        privacy.check_source(privacy.ROOT)

    def test_new_disk_or_keyboard_api_requires_review(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "NewAPI.swift"
            source.write_text("// systemUptime\nlet capacity = URLResourceKey.volumeAvailableCapacityKey\nlet inputs = UITextInputMode.activeInputModes")
            self.assertEqual(privacy.source_categories(Path(directory)), {"DiskSpace", "ActiveKeyboards"})

    def test_manifest_rejects_missing_reason_duplicates_and_tracking(self):
        source = privacy.ROOT / "apple/Apps/VaganciaFitnessWatch/Resources/PrivacyInfo.xcprivacy"
        data = plistlib.loads(source.read_bytes())
        categories = {"UserDefaults", "SystemBootTime"}
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "PrivacyInfo.xcprivacy"
            for mode in ["missing", "duplicate", "tracking"]:
                modified = plistlib.loads(plistlib.dumps(data))
                if mode == "missing":
                    modified["NSPrivacyAccessedAPITypes"].pop()
                elif mode == "duplicate":
                    modified["NSPrivacyAccessedAPITypes"].append(modified["NSPrivacyAccessedAPITypes"][0])
                else:
                    modified["NSPrivacyTracking"] = True
                manifest.write_bytes(plistlib.dumps(modified))
                with self.subTest(mode=mode), self.assertRaises(ValueError):
                    privacy.validate_manifest(manifest, categories)

    def test_aggregate_built_products_require_app_and_package_manifests(self):
        modules, apps = privacy.check_source(privacy.ROOT)
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            for configuration in ["Debug", "Release"]:
                for app, dependencies in privacy.APPS.items():
                    platform = "watchsimulator" if app.endswith("Watch") else "iphonesimulator"
                    bundle = products / f"{configuration}-{platform}" / f"{app}.app"
                    bundle.mkdir(parents=True)
                    manifest = privacy.ROOT / "apple/Apps" / app / "Resources/PrivacyInfo.xcprivacy"
                    (bundle / "PrivacyInfo.xcprivacy").write_bytes(manifest.read_bytes())
                    for module in dependencies:
                        resource = bundle / f"FitnessKit_{module}.bundle"
                        resource.mkdir()
                        manifest = privacy.ROOT / privacy.PACKAGE / module / "Resources/PrivacyInfo.xcprivacy"
                        (resource / "PrivacyInfo.xcprivacy").write_bytes(manifest.read_bytes())
            counts = privacy.check_built_products(products, modules, apps)
            self.assertEqual(set(counts.values()), {2})
            missing = products / "Release-iphonesimulator/VaganciaFitness.app/FitnessKit_FitnessRuntime.bundle/PrivacyInfo.xcprivacy"
            missing.unlink()
            with self.assertRaises(FileNotFoundError):
                privacy.check_built_products(products, modules, apps)


if __name__ == "__main__":
    unittest.main()
