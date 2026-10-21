"""Regression checks use synthetic catalogs and temporary reference files only."""
import contextlib
import copy
import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_script(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


redactor = load_script("reference_redactor", "scripts/redact-references")
localizations = load_script("localization_validator", "apple/scripts/validate-localizations.py")
try:
    from PIL import Image, PngImagePlugin
except ImportError:
    Image = None


class RedactorFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "input"
        self.source.mkdir()
        (self.source / "reference-01.png").write_bytes(b"synthetic preflight input")
        self.destination = self.root / "output"
        self.policy = {"cases": [{"input": "reference-01.png", "output": "redacted-01.png",
                                  "size": [8, 8], "rectangles": [[0.25, 0.25, 0.75, 0.75]]}]}

    def preflight(self):
        return redactor.preflight(self.source, self.destination, self.policy)

    def assert_rejected(self, message=None):
        with self.assertRaisesRegex(ValueError, message or "."):
            self.preflight()
        self.assertFalse(self.destination.exists())
        self.assertEqual((self.source / "reference-01.png").read_bytes(), b"synthetic preflight input")


class RedactorPreflightTests(RedactorFixture, unittest.TestCase):
    def test_valid_policy_creates_nothing(self):
        destination, entries = self.preflight()
        self.assertEqual(destination, self.destination)
        self.assertEqual(len(entries), 1)
        self.assertFalse(destination.exists())

    def test_input_and_output_require_safe_basenames(self):
        for field in ("input", "output"):
            for name in ("../escape.png", "/escape.png", "sub/image.png", "sub\\image.png",
                         "C:\\escape.png", "..", "", None, "manifest.json"):
                with self.subTest(field=field, name=name):
                    policy = copy.deepcopy(self.policy)
                    policy["cases"][0][field] = name
                    with self.assertRaisesRegex(ValueError, "basenames"):
                        redactor.preflight(self.source, self.destination, policy)
                    self.assertFalse(self.destination.exists())

    def test_input_symlink_cannot_escape(self):
        outside = self.root / "outside.png"
        outside.write_bytes(b"outside synthetic bytes")
        (self.source / "alias.png").symlink_to(outside)
        self.policy["cases"][0]["input"] = "alias.png"
        self.assert_rejected("escapes")
        self.assertEqual(outside.read_bytes(), b"outside synthetic bytes")

    def test_output_symlink_cannot_escape(self):
        self.destination.mkdir()
        outside = self.root / "outside.png"
        (self.destination / "redacted-01.png").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.preflight()
        self.assertFalse(outside.exists())

    def test_output_directory_symlink_obeys_repository_boundary(self):
        repository = self.root / "repository"
        public = repository / "docs"
        public.mkdir(parents=True)
        self.destination.symlink_to(public, target_is_directory=True)
        with patch.object(redactor, "ROOT", repository):
            with self.assertRaisesRegex(ValueError, "outside the repository"):
                self.preflight()
        self.assertEqual(list(public.iterdir()), [])

    def test_local_directory_symlink_does_not_exempt_public_output(self):
        repository = self.root / "repository"
        public = repository / "docs"
        public.mkdir(parents=True)
        (repository / ".local").symlink_to(public, target_is_directory=True)
        with patch.object(redactor, "ROOT", repository):
            with self.assertRaisesRegex(ValueError, "outside the repository"):
                redactor.preflight(self.source, repository / ".local" / "output", self.policy)
        self.assertEqual(list(public.iterdir()), [])

    def test_repository_output_rejected_but_local_output_allowed(self):
        with patch.object(redactor, "ROOT", self.root):
            self.assert_rejected("outside the repository")
            output, _ = redactor.preflight(self.source, self.root / ".local" / "output", self.policy)
        self.assertEqual(output, self.root / ".local" / "output")
        self.assertFalse(output.exists())

    def test_original_directory_rejected(self):
        with self.assertRaisesRegex(ValueError, "different directories"):
            redactor.preflight(self.source, self.source, self.policy)

    def test_later_invalid_case_has_no_outputs(self):
        self.policy["cases"].append({**self.policy["cases"][0], "output": "../escape.png"})
        self.assert_rejected("basenames")

    def test_duplicate_outputs_rejected_before_writing(self):
        self.policy["cases"].append(copy.deepcopy(self.policy["cases"][0]))
        self.assert_rejected("Duplicate output")
        self.policy["cases"][1]["output"] = "REDACTED-01.png"
        self.assert_rejected("Duplicate output")

    def test_later_existing_output_prevents_all_writes(self):
        self.destination.mkdir()
        existing = self.destination / "existing.png"
        existing.write_bytes(b"keep existing image")
        self.policy["cases"].append({**self.policy["cases"][0], "output": existing.name})
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.preflight()
        self.assertEqual(list(self.destination.iterdir()), [existing])
        self.assertEqual(existing.read_bytes(), b"keep existing image")

    def test_manifest_is_never_overwritten(self):
        self.destination.mkdir()
        manifest = self.destination / "manifest.json"
        manifest.write_text("keep existing manifest")
        with self.assertRaisesRegex(ValueError, "manifest.json"):
            self.preflight()
        self.assertEqual(list(self.destination.iterdir()), [manifest])
        self.assertEqual(manifest.read_text(), "keep existing manifest")

    def test_dangling_manifest_symlink_rejected(self):
        self.destination.mkdir()
        (self.destination / "manifest.json").symlink_to(self.root / "absent.json")
        with self.assertRaisesRegex(ValueError, "manifest.json"):
            self.preflight()
        self.assertFalse((self.root / "absent.json").exists())

    def test_invalid_masks_and_dimensions_rejected(self):
        for field, values in (("rectangles", ([], [[0, 0, 2, 1]], [[0.5, 0, 0.5, 1]], [[0, 0, float("nan"), 1]], [[False, 0, 1, 1]])),
                              ("size", ([0, 8], [True, 8], [8], "8x8"))):
            for value in values:
                with self.subTest(field=field, value=value):
                    policy = copy.deepcopy(self.policy)
                    policy["cases"][0][field] = value
                    with self.assertRaises(ValueError):
                        redactor.preflight(self.source, self.destination, policy)
                    self.assertFalse(self.destination.exists())


@unittest.skipIf(Image is None, "Pillow is unavailable; image rendering checks require Pillow")
class RedactorImageTests(RedactorFixture, unittest.TestCase):
    def write_png(self, name="reference-01.png", size=(8, 8)):
        metadata = PngImagePlugin.PngInfo()
        metadata.add_text("synthetic-private-note", "must disappear")
        Image.new("RGBA", size, (240, 80, 20, 255)).save(self.source / name, pnginfo=metadata)

    def test_opaque_mask_metadata_removal_and_original_retention(self):
        self.write_png()
        original = (self.source / "reference-01.png").read_bytes()
        self.assertEqual(redactor.redact(self.source, self.destination, self.policy), 1)
        target = self.destination / "redacted-01.png"
        with Image.open(target) as image:
            self.assertEqual(image.mode, "RGB")
            self.assertEqual(image.info, {})
            self.assertIsNone(image.crop((2, 2, 7, 7)).getbbox())
            self.assertEqual(image.getpixel((0, 0)), (240, 80, 20))
        self.assertEqual((self.source / "reference-01.png").read_bytes(), original)
        manifest = json.loads((self.destination / "manifest.json").read_text())
        self.assertEqual(manifest["files"][0]["sha256"], hashlib.sha256(target.read_bytes()).hexdigest())
        self.assertFalse(manifest["hardwareVerification"])

    def test_later_bad_dimensions_prevent_all_writes(self):
        self.write_png()
        self.write_png("reference-02.png", size=(9, 8))
        self.policy["cases"].append({**self.policy["cases"][0], "input": "reference-02.png", "output": "redacted-02.png"})
        with self.assertRaisesRegex(ValueError, "dimensions"):
            redactor.redact(self.source, self.destination, self.policy)
        self.assertFalse(self.destination.exists())

    def test_later_corrupt_png_prevents_all_writes(self):
        self.write_png()
        (self.source / "reference-02.png").write_bytes(b"corrupt synthetic PNG")
        self.policy["cases"].append({**self.policy["cases"][0], "input": "reference-02.png", "output": "redacted-02.png"})
        with self.assertRaises(OSError):
            redactor.redact(self.source, self.destination, self.policy)
        self.assertFalse(self.destination.exists())


def unit(value="synthetic", state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def catalog(es=None, en=None):
    return {"sourceLanguage": "es", "strings": {"synthetic.key": {"localizations": {
        "es": unit() if es is None else es, "en": unit() if en is None else en}}}}


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(localizations, "ROOT", self.root).start()
        for relative in localizations.CATALOG_PATHS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(catalog()))

    def run_validator(self, *arguments):
        output = io.StringIO()
        with patch("sys.argv", ["validate-localizations.py", *arguments]), contextlib.redirect_stdout(output):
            result = localizations.main()
        return result, json.loads(output.getvalue())

    def validate_catalog(self, data):
        path = self.root / localizations.CATALOG_PATHS[1]
        path.write_text(json.dumps(data))
        return localizations.validate(path)["errors"]

    def test_exact_five_catalogs_pass(self):
        status, report = self.run_validator()
        self.assertEqual(status, 0)
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["catalogs"]), 5)

    def test_each_required_catalog_missing_fails(self):
        for relative in localizations.CATALOG_PATHS:
            with self.subTest(catalog=relative):
                path = self.root / relative
                contents = path.read_bytes()
                path.unlink()
                status, report = self.run_validator()
                self.assertEqual(status, 1)
                self.assertFalse(report["passed"])
                self.assertTrue(any(r["catalog"] == relative and "missing" in " ".join(r["errors"]) for r in report["catalogs"]))
                path.write_bytes(contents)

    def test_additional_catalog_fails_inventory(self):
        extra = self.root / "Apps/Unexpected/Resources/Localizable.xcstrings"
        extra.parent.mkdir(parents=True)
        extra.write_text(json.dumps(catalog()))
        status, report = self.run_validator()
        self.assertEqual(status, 1)
        self.assertIn("Unexpected catalog", report["catalogs"][0]["errors"][0])

    def test_duplicate_json_keys_fail_with_report(self):
        path = self.root / localizations.CATALOG_PATHS[1]
        path.write_text('{"sourceLanguage":"es","strings":{},"strings":{}}')
        status, report = self.run_validator()
        self.assertEqual(status, 1)
        self.assertTrue(any("Duplicate JSON key" in " ".join(r["errors"]) for r in report["catalogs"]))

    def test_missing_language_and_incomplete_translation_fail(self):
        self.assertTrue(any("missing en" in error for error in self.validate_catalog(catalog(en={}))))
        self.assertTrue(any("incomplete en" in error for error in self.validate_catalog(catalog(en=unit(state="new")))))

    def test_plural_variations_must_match(self):
        es = {"variations": {"plural": {"one": unit("%lld synthetic"), "other": unit("%lld synthetic")}}}
        en = {"variations": {"plural": {"other": unit("%lld synthetic")}}}
        self.assertTrue(any("variation mismatch" in error for error in self.validate_catalog(catalog(es, en))))

    def test_argument_positions_and_types_must_match(self):
        for source, target in (("%lld", "%d"), ("%1$@ %2$d", "%1$d %2$@"), ("%@ %@", "%@")):
            with self.subTest(source=source, target=target):
                self.assertTrue(any("argument mismatch" in error for error in self.validate_catalog(catalog(unit(source), unit(target)))))

    def test_positional_reordering_and_escaped_percent_pass(self):
        errors = self.validate_catalog(catalog(unit("%1$@ %2$lld 100%%"), unit("%2$lld %1$@ 100%%")))
        self.assertEqual(errors, [])
        self.assertEqual(localizations.arguments("%%*d"), {})

    def test_star_width_and_precision_are_rejected_even_when_equal(self):
        for value in ("%*d", "%.*f", "%*.*f", "%2$*1$d", "%3$*1$.*2$f", "%1$.*2$f"):
            with self.subTest(format=value):
                errors = self.validate_catalog(catalog(unit(value), unit(value)))
                self.assertTrue(any("Unsupported star width/precision" in error for error in errors))

    def test_missing_helper_key_fails(self):
        source = self.root / "Apps/VaganciaFitnessWatch/Synthetic.swift"
        source.write_text('let value = WatchText.string("missing.synthetic.key")\n')
        status, report = self.run_validator()
        self.assertEqual(status, 1)
        self.assertEqual(report["helperReferences"][0]["missingCatalogKeys"], ["missing.synthetic.key"])

    def test_compiler_extraction_requires_keys_for_both_targets(self):
        extraction = self.root / "extraction"
        extraction.mkdir()
        status, report = self.run_validator("--stringsdata-root", str(extraction))
        self.assertEqual(status, 1)
        self.assertEqual([r["extractedKeys"] for r in report["compilerExtraction"]], [0, 0])
        for target in ("VaganciaFitness", "VaganciaFitnessWatch"):
            (extraction / f"{target}.stringsdata").write_text(json.dumps({
                "source": str(self.root / "Apps" / target / "Synthetic.swift"),
                "tables": {"Localizable": [{"key": "synthetic.key"}]}}))
        status, report = self.run_validator("--stringsdata-root", str(extraction))
        self.assertEqual(status, 0)
        self.assertEqual([r["extractedKeys"] for r in report["compilerExtraction"]], [1, 1])
        (extraction / "VaganciaFitness.stringsdata").write_text(json.dumps({
            "source": str(self.root / "Apps/VaganciaFitness/Synthetic.swift"),
            "tables": {"Localizable": [{"key": "missing.synthetic.key"}]}}))
        status, report = self.run_validator("--stringsdata-root", str(extraction))
        self.assertEqual(status, 1)
        self.assertEqual(report["compilerExtraction"][0]["missingCatalogKeys"], ["missing.synthetic.key"])


if __name__ == "__main__":
    unittest.main()
