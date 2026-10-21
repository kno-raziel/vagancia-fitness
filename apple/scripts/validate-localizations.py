#!/usr/bin/env python3
"""Check ES/EN String Catalog completeness and format argument contracts."""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATHS = (
    "Apps/VaganciaFitness/Resources/InfoPlist.xcstrings",
    "Apps/VaganciaFitness/Resources/Localizable.xcstrings",
    "Apps/VaganciaFitnessWatch/Resources/InfoPlist.xcstrings",
    "Apps/VaganciaFitnessWatch/Resources/Localizable.xcstrings",
    "Packages/FitnessKit/Sources/FitnessCore/Resources/Localizable.xcstrings",
)
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+#0 ']*(\d+|\*(?:\d+\$)?)?(?:\.(\d*|\*(?:\d+\$)?))?(hh|ll|h|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp])")
HELPER_CALL = re.compile(r'\b(WatchText|FitnessText)\.(?:string|format)\(\s*"((?:\\.|[^"\\])*)"')


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"Duplicate JSON key: {key!r}")
        obj[key] = value
    return obj


def units(node, path=()):
    if not isinstance(node, dict):
        return {}
    result = {}
    if "stringUnit" in node:
        result[path] = node["stringUnit"]
    for key, value in node.items():
        if key != "stringUnit" and isinstance(value, dict):
            result.update(units(value, path + (key,)))
    return result


def arguments(text):
    text = text.replace("%%", "")
    result = Counter()
    next_position = 1
    for match in FORMAT.finditer(text):
        position, width, precision, length, kind = match.groups()
        if "*" in (width or "") or "*" in (precision or ""):
            raise ValueError("Unsupported star width/precision in format argument")
        position = int(position) if position else next_position
        next_position += 1
        result[(position, (length or "") + kind)] += 1
    return result


def validate(path):
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    errors = []
    if data.get("sourceLanguage") != "es":
        errors.append("sourceLanguage must be es")
    entries = data.get("strings", {})
    if not entries:
        errors.append("catalog is empty")
    translated = 0
    for key, entry in entries.items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        variants = {}
        for language in ("es", "en"):
            leaves = units(localizations.get(language, {}))
            variants[language] = leaves
            if not leaves:
                errors.append(f"{key!r}: missing {language} translation")
            for variation, unit in leaves.items():
                if unit.get("state") != "translated" or not isinstance(unit.get("value"), str) or (key and not unit["value"]):
                    errors.append(f"{key!r}: incomplete {language}/{'.'.join(variation)}")
        for variation in variants["es"].keys() | variants["en"].keys():
            source = variants["es"].get(variation)
            target = variants["en"].get(variation)
            if source is None or target is None:
                errors.append(f"{key!r}: ES/EN variation mismatch at {'.'.join(variation)}")
            elif isinstance(source.get("value"), str) and isinstance(target.get("value"), str):
                try:
                    if arguments(source["value"]) != arguments(target["value"]):
                        errors.append(f"{key!r}: format argument mismatch at {'.'.join(variation)}")
                except ValueError as error:
                    errors.append(f"{key!r}: {error} at {'.'.join(variation)}")
        translated += 1
    return {"catalog": str(path.relative_to(ROOT)), "entries": len(entries), "translatedEntries": translated, "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stringsdata-root", type=Path,
                        help="Also check extracted Swift compiler keys for both product apps")
    args = parser.parse_args()
    catalogs = [ROOT / relative for relative in CATALOG_PATHS]
    discovered = set(ROOT.glob("Apps/**/Resources/*.xcstrings")) | set(ROOT.glob("Packages/FitnessKit/Sources/**/Resources/*.xcstrings"))
    reports = [{"catalog": str(path.relative_to(ROOT)), "errors": ["Unexpected catalog outside the five required paths"]}
               for path in sorted(discovered - set(catalogs))]
    for path in catalogs:
        try:
            reports.append(validate(path))
        except FileNotFoundError:
            reports.append({"catalog": str(path.relative_to(ROOT)), "errors": ["Required catalog is missing"]})
        except (ValueError, KeyError, TypeError) as error:
            reports.append({"catalog": str(path.relative_to(ROOT)), "errors": [str(error)]})
    helper_references = []
    helper_catalogs = {
        "WatchText": ROOT / "Apps/VaganciaFitnessWatch/Resources/Localizable.xcstrings",
        "FitnessText": ROOT / "Packages/FitnessKit/Sources/FitnessCore/Resources/Localizable.xcstrings",
    }
    for helper, catalog in helper_catalogs.items():
        if any(report["errors"] for report in reports if report["catalog"] == str(catalog.relative_to(ROOT))):
            continue
        keys = set(json.loads(catalog.read_text())["strings"])
        references = set()
        for folder in (ROOT / "Apps/VaganciaFitness", ROOT / "Apps/VaganciaFitnessWatch", ROOT / "Packages/FitnessKit/Sources"):
            for source in folder.rglob("*.swift"):
                for name, literal in HELPER_CALL.findall(source.read_text()):
                    if name != helper or "\\(" in literal:
                        continue
                    references.add(json.loads('"' + literal + '"'))
        helper_references.append({"helper": helper, "literalKeys": len(references),
                                  "missingCatalogKeys": sorted(references - keys)})
    extraction = []
    if args.stringsdata_root:
        for target in ("VaganciaFitness", "VaganciaFitnessWatch"):
            catalog = ROOT / "Apps" / target / "Resources/Localizable.xcstrings"
            if any(report["errors"] for report in reports if report["catalog"] == str(catalog.relative_to(ROOT))):
                continue
            keys = set(json.loads(catalog.read_text())["strings"])
            extracted = set()
            for path in args.stringsdata_root.rglob("*.stringsdata"):
                data = json.loads(path.read_text())
                # Xcode may record /tmp while Python resolves /private/tmp,
                # or use another checkout symlink. Compare physical paths.
                source = Path(data.get("source", "")).resolve()
                if not source.is_relative_to((ROOT / "Apps" / target).resolve()):
                    continue
                extracted.update(row["key"] for row in data.get("tables", {}).get("Localizable", []))
            extraction.append({"target": target, "extractedKeys": len(extracted),
                               "missingCatalogKeys": sorted(extracted - keys)})
    result = {"catalogs": reports, "helperReferences": helper_references,
              "compilerExtraction": extraction,
              "passed": bool(catalogs) and not any(r["errors"] for r in reports)
              and not any(r["missingCatalogKeys"] for r in helper_references)
              and not any(not r["extractedKeys"] or r["missingCatalogKeys"] for r in extraction)}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
