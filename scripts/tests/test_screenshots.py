"""Validate screenshot metadata cleaning with synthetic PNGs and export manifests."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPT = Path(__file__).resolve().parents[2] / "apple/scripts/export-documentation-screenshots.py"
spec = importlib.util.spec_from_file_location("documentation_screenshots", SCRIPT)
screenshots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshots)


def chunk(kind, payload=b""):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def synthetic_chunks():
    compressed = zlib.compress(b"\x00\x12\x34\x56")
    return [chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)),
            chunk(b"gAMA", struct.pack(">I", 45455)), chunk(b"sRGB", b"\x00"),
            chunk(b"eXIf", b"synthetic EXIF metadata"),
            chunk(b"iTXt", b"XML:com.adobe.xmp\0\0\0\0\0synthetic XMP"),
            chunk(b"tEXt", b"Comment\0synthetic private note"),
            chunk(b"zTXt", b"Comment\0\0" + zlib.compress(b"synthetic compressed note")),
            chunk(b"tIME", b"\x07\xea\x01\x01\x00\x00\x00"),
            chunk(b"IDAT", compressed[:4]), chunk(b"IDAT", compressed[4:]), chunk(b"IEND")]


def synthetic_png():
    return screenshots.PNG_SIGNATURE + b"".join(synthetic_chunks())


class PNGMetadataTests(unittest.TestCase):
    def test_strips_metadata_preserving_image_chunks_verbatim(self):
        original = synthetic_png()
        expected = screenshots.PNG_SIGNATURE + b"".join(
            value for value in synthetic_chunks() if value[4:8] in screenshots.RETAINED_CHUNKS)
        cleaned = screenshots.strip_png_metadata(original)
        self.assertEqual(cleaned, expected)
        self.assertEqual(screenshots.strip_png_metadata(cleaned), cleaned)
        for metadata in (b"eXIf", b"iTXt", b"tEXt", b"zTXt", b"tIME", b"synthetic"):
            self.assertNotIn(metadata, cleaned)

    def test_retains_palette_transparency_and_color_profile(self):
        profile = b"synthetic-profile\0\0" + zlib.compress(b"synthetic color profile")
        values = [chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 3, 0, 0, 0)),
                  chunk(b"cHRM", bytes(32)), chunk(b"iCCP", profile),
                  chunk(b"PLTE", b"\x12\x34\x56"), chunk(b"tRNS", b"\x80"),
                  chunk(b"IDAT", zlib.compress(b"\x00\x00")), chunk(b"IEND")]
        original = screenshots.PNG_SIGNATURE + b"".join(values)
        self.assertEqual(screenshots.strip_png_metadata(original), original)

    def test_rejects_crc_damage_even_in_discarded_metadata(self):
        for index in (0, 3, 8):
            values = synthetic_chunks()
            corrupted = bytearray(values[index])
            corrupted[-1] ^= 1
            values[index] = bytes(corrupted)
            with self.subTest(chunk=index), self.assertRaisesRegex(ValueError, "CRC"):
                screenshots.strip_png_metadata(screenshots.PNG_SIGNATURE + b"".join(values))

    def test_rejects_truncated_missing_and_invalid_chunk_structure(self):
        values = synthetic_chunks()
        header, ending = values[0], values[-1]
        invalid = [b"", b"not a PNG", synthetic_png()[:-1], synthetic_png() + b"trailing bytes",
                   screenshots.PNG_SIGNATURE + b"".join(values[:-1]),
                   screenshots.PNG_SIGNATURE + ending,
                   screenshots.PNG_SIGNATURE + header + header + b"".join(values[1:]),
                   screenshots.PNG_SIGNATURE + header + chunk(b"ABCD") + b"".join(values[1:]),
                   screenshots.PNG_SIGNATURE + header + chunk(b"abcD") + b"".join(values[1:]),
                   screenshots.PNG_SIGNATURE + header + chunk(b"IDAT", b"x") + chunk(b"tEXt", b"x") + chunk(b"IDAT", b"y") + ending,
                   screenshots.PNG_SIGNATURE + header + chunk(b"IEND"),
                   screenshots.PNG_SIGNATURE + header + b"\x7f\xff\xff\xffIDAT"]
        for index, value in enumerate(invalid):
            with self.subTest(case=index), self.assertRaises(ValueError):
                screenshots.strip_png_metadata(value)

    def test_rejects_bad_header_palette_and_animated_png(self):
        for replacement in (chunk(b"IHDR", b"short"),
                            chunk(b"IHDR", struct.pack(">IIBBBBB", 0, 1, 8, 2, 0, 0, 0)),
                            chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 4, 2, 0, 0, 0))):
            with self.subTest(header=replacement), self.assertRaises(ValueError):
                screenshots.strip_png_metadata(screenshots.PNG_SIGNATURE + replacement + b"".join(synthetic_chunks()[1:]))
        for extra in (chunk(b"PLTE", b"x"), chunk(b"acTL", bytes(8))):
            with self.subTest(chunk=extra), self.assertRaises(ValueError):
                screenshots.strip_png_metadata(screenshots.PNG_SIGNATURE + synthetic_chunks()[0] + extra + b"".join(synthetic_chunks()[1:]))


class ScreenshotExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "attachments"
        self.source.mkdir()
        self.output = self.root / "documentation"
        self.records = []
        for kind, (identifier, names) in screenshots.CAPTURES.items():
            attachments = []
            for number, name in enumerate(names):
                filename = f"{kind}-{number}.png"
                (self.source / filename).write_bytes(synthetic_png())
                attachments.append({"exportedFileName": filename,
                                    "suggestedHumanReadableName": f"{name}_0_SYNTHETIC.png"})
            self.records.append({"testIdentifier": identifier, "attachments": attachments})
        self.write_manifest()

    def write_manifest(self):
        (self.source / "manifest.json").write_text(json.dumps(self.records))

    def test_capture_sets_map_to_fixed_outputs_and_preserve_originals(self):
        original = {path.name: path.read_bytes() for path in self.source.iterdir()}
        self.output.mkdir()
        (self.output / "keep.txt").write_text("unrelated documentation")
        for kind, (_, names) in screenshots.CAPTURES.items():
            self.assertEqual(set(screenshots.export_screenshots(self.source, kind, self.output)), set(names.values()))
            for name in names.values():
                self.assertEqual((self.output / name).read_bytes(), screenshots.strip_png_metadata(synthetic_png()))
        self.assertEqual({path.name: path.read_bytes() for path in self.source.iterdir()}, original)
        self.assertEqual((self.output / "keep.txt").read_text(), "unrelated documentation")

    def test_cli_exports_without_optional_packages(self):
        result = subprocess.run([sys.executable, "-B", "-S", str(SCRIPT), str(self.source),
                                 "--kind", "debug", "--output-directory", str(self.output)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in self.output.iterdir()], ["app-debug.png"])
        self.assertIn("pixel data unchanged", result.stdout)

    def test_refresh_replaces_only_known_documentation_files(self):
        self.output.mkdir()
        for name in screenshots.CAPTURES["product"][1].values():
            (self.output / name).write_bytes(b"previous documentation image")
        screenshots.export_screenshots(self.source, "product", self.output)
        self.assertEqual(set(path.name for path in self.output.iterdir()), set(screenshots.CAPTURES["product"][1].values()))
        self.assertTrue(all(path.read_bytes() == screenshots.strip_png_metadata(synthetic_png()) for path in self.output.iterdir()))

    def test_wrong_identifier_missing_or_duplicate_capture_creates_nothing(self):
        for mutation in ("identifier", "missing", "duplicate"):
            with self.subTest(mutation=mutation):
                records = json.loads((self.source / "manifest.json").read_text())
                if mutation == "identifier":
                    records[0]["testIdentifier"] = "UnknownTests/unreviewedCapture()"
                elif mutation == "missing":
                    records[0]["attachments"].pop()
                else:
                    records[0]["attachments"].append(records[0]["attachments"][0])
                (self.source / "manifest.json").write_text(json.dumps(records))
                with self.assertRaises(ValueError):
                    screenshots.export_screenshots(self.source, "product", self.output)
                self.assertFalse(self.output.exists())
                self.write_manifest()

    def test_later_bad_png_prevents_refresh_of_existing_outputs(self):
        self.output.mkdir()
        existing = self.output / "app-home.png"
        existing.write_bytes(b"keep previous screenshot")
        (self.source / "product-2.png").write_bytes(b"malformed synthetic PNG")
        with self.assertRaises(ValueError):
            screenshots.export_screenshots(self.source, "product", self.output)
        self.assertEqual(existing.read_bytes(), b"keep previous screenshot")
        self.assertEqual(list(self.output.iterdir()), [existing])

    def test_input_names_and_symlink_containment(self):
        for name in ("../outside.png", "/outside.png", "sub/image.png", "sub\\image.png", None):
            with self.subTest(name=name):
                self.records[0]["attachments"][-1]["exportedFileName"] = name
                self.write_manifest()
                with self.assertRaises(ValueError):
                    screenshots.export_screenshots(self.source, "product", self.output)
                self.assertFalse(self.output.exists())
        outside = self.root / "outside.png"
        outside.write_bytes(synthetic_png())
        (self.source / "alias.png").symlink_to(outside)
        self.records[0]["attachments"][-1]["exportedFileName"] = "alias.png"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "escapes"):
            screenshots.export_screenshots(self.source, "product", self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(outside.read_bytes(), synthetic_png())

    def test_output_symlink_prevents_all_writes(self):
        self.output.mkdir()
        outside = self.root / "outside.png"
        outside.write_bytes(b"keep original")
        (self.output / "app-history.png").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Unsafe output"):
            screenshots.export_screenshots(self.source, "product", self.output)
        self.assertEqual(outside.read_bytes(), b"keep original")
        self.assertEqual([path.name for path in self.output.iterdir()], ["app-history.png"])

    def test_manifest_symlink_and_source_destination_alias_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "directories must differ"):
            screenshots.export_screenshots(self.source, "product", self.source)
        manifest = self.source / "manifest.json"
        outside = self.root / "outside.json"
        outside.write_bytes(manifest.read_bytes())
        manifest.unlink()
        manifest.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "manifest escapes"):
            screenshots.export_screenshots(self.source, "product", self.output)
        self.assertFalse(self.output.exists())

    def test_native_share_card_cli_strips_metadata_and_preserves_source(self):
        source = self.root / "native-card.png"
        source.write_bytes(synthetic_png())
        result = subprocess.run([sys.executable, "-B", "-S", str(SCRIPT), str(source),
                                 "--kind", "share-card", "--output-directory", str(self.output)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in self.output.iterdir()], ["app-share-card.png"])
        self.assertEqual((self.output / "app-share-card.png").read_bytes(),
                         screenshots.strip_png_metadata(synthetic_png()))
        self.assertEqual(source.read_bytes(), synthetic_png())

    def test_native_share_card_rejects_source_output_alias_and_symlink(self):
        self.output.mkdir()
        source = self.output / "app-share-card.png"
        source.write_bytes(synthetic_png())
        with self.assertRaisesRegex(ValueError, "must differ"):
            screenshots.export_screenshots(source, "share-card", self.output)
        alias = self.root / "alias"
        alias.symlink_to(self.output, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must differ"):
            screenshots.export_screenshots(source, "share-card", alias)
        outside = self.root / "native-card.png"
        outside.write_bytes(synthetic_png())
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Unsafe output"):
            screenshots.export_screenshots(outside, "share-card", self.output)
        self.assertEqual(outside.read_bytes(), synthetic_png())

    def test_native_share_card_invalid_input_preserves_previous_output(self):
        self.output.mkdir()
        existing = self.output / "app-share-card.png"
        existing.write_bytes(b"previous reviewed card")
        source = self.root / "native-card.png"
        source.write_bytes(synthetic_png()[:-1])
        for candidate in (source, self.root / "missing.png", self.source):
            with self.subTest(source=candidate), self.assertRaises(ValueError):
                screenshots.export_screenshots(candidate, "share-card", self.output)
            self.assertEqual(existing.read_bytes(), b"previous reviewed card")


if __name__ == "__main__":
    unittest.main()
