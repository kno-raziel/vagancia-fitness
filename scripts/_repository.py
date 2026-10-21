"""Public source inventory; deliberately independent of Git and local evidence."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = {"apple", "android", "shared", "docs", "design", "scripts", ".github"}
FILES = {"README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md",
         "CODE_OF_CONDUCT.md", "SECURITY.md", "PRIVACY.md",
         "AGENTS.md", "PRODUCT.md", ".gitignore", ".editorconfig", ".gitattributes"}
EXCLUDED_PARTS = {".git", ".local", ".build", "build", "DerivedData", "artifacts",
                  "xcuserdata", "__pycache__", "FitShowReferences"}
PRIVATE_REFERENCE_DIRECTORY = Path("docs/references/fitshow")

EXCLUDED_SUFFIXES = {".pyc", ".xcuserstate", ".mobileprovision", ".p12", ".pfx",
                     ".pem", ".key", ".ipa", ".xcresult", ".xcarchive"}


def public_files():
    candidates = [ROOT / name for name in FILES if (ROOT / name).is_file()]
    for name in sorted(DIRECTORIES):
        directory = ROOT / name
        if directory.exists():
            candidates.extend(directory.rglob("*"))
    metadata = ROOT / ".impeccable/design.json"
    if metadata.exists():
        candidates.append(metadata)
    for path in sorted(set(candidates)):
        relative = path.relative_to(ROOT)
        # Directory exclusions must not discard commands named "build".
        if any(part in EXCLUDED_PARTS for part in relative.parts[:-1]):
            continue
        if any(Path(part).suffix in {".xcresult", ".xcarchive"} for part in relative.parts[:-1]):
            continue
        if PRIVATE_REFERENCE_DIRECTORY in relative.parents and relative != PRIVATE_REFERENCE_DIRECTORY / "README.md":
            continue
        if path.name in {".DS_Store", "Local.xcconfig"} or any(path.name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES):
            continue
        if path.name.startswith(".env") and not path.name.endswith(".example"):
            continue
        if path.is_symlink():
            raise ValueError(f"Public source must not contain symlinks: {relative}")
        if path.is_file():
            yield path


def gitignore_content():
    """Generate Git's boundary from the same classifications as public_files()."""
    lines = [
        "# Generated from scripts/_repository.py; do not edit independently.",
        "# Refresh: python3 scripts/_repository.py --write-gitignore",
        "# Only classified public roots can enter the future repository.",
        "/*",
    ]
    lines.extend("!/" + name for name in sorted(FILES))
    lines.extend("!/" + name + "/" for name in sorted(DIRECTORIES))
    lines.extend([
        "!/.impeccable/",
        "/.impeccable/*",
        "!/.impeccable/design.json",
        "# Recreated locally: build outputs, evidence, signing and user state.",
    ])
    lines.extend(name + "/" for name in sorted(EXCLUDED_PARTS))
    lines.extend("*" + suffix for suffix in sorted(EXCLUDED_SUFFIXES))
    lines.extend([
        ".DS_Store",
        "Local.xcconfig",
        ".env*",
        "!.env*.example",
        "# Only the reference policy is public; screenshots/manifests stay private.",
        "/" + PRIVATE_REFERENCE_DIRECTORY.as_posix() + "/*",
        "!/" + (PRIVATE_REFERENCE_DIRECTORY / "README.md").as_posix(),
    ])
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-gitignore", action="store_true", required=True)
    parser.parse_args()
    (ROOT / ".gitignore").write_text(gitignore_content())
    print("Updated .gitignore from the public distribution policy; Git was not initialized.")
