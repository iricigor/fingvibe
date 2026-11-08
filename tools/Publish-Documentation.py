"""Overlay checked documentation without modifying the gh-pages UI-review archive."""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil


MANIFEST = ".documentation-files.json"
DIRECTORIES = {"assets", "branding", "manual", "screenshots", "search"}
ROOT_FILES = {
    "index.html", "404.html", "sitemap.xml", "sitemap.xml.gz",
    ".nojekyll", "documentation-revision.txt",
}


def validate_path(value, root):
    if not isinstance(value, str) or "\\" in value:
        raise ValueError(f"Invalid documentation path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"Unsafe documentation path: {value!r}")
    if path.parts[0] not in DIRECTORIES and value not in ROOT_FILES:
        raise ValueError(f"Path is not owned by documentation: {value!r}")
    target = root
    for part in path.parts:
        target /= part
        if target.is_symlink():
            raise ValueError(f"Documentation target is a symbolic link: {value!r}")
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Documentation target escapes its checkout: {value!r}")
    if target.exists() and not target.is_file():
        raise ValueError(f"Documentation file target is not a file: {value!r}")
    return target


def overlay_site(site, published):
    site = site.resolve()
    published = published.resolve()
    if not site.is_dir() or not published.is_dir() or site == published:
        raise ValueError("Use separate existing site and gh-pages checkout directories.")
    paths = {}
    for source in site.rglob("*"):
        if source.is_symlink():
            raise ValueError(f"Site contains a symbolic link: {source}")
        if source.is_file():
            relative = source.relative_to(site).as_posix()
            paths[relative] = validate_path(relative, published)
    if "index.html" not in paths:
        raise ValueError("Checked site has no index.html.")

    manifest = published / MANIFEST
    if manifest.is_symlink():
        raise ValueError("Documentation manifest cannot be a symbolic link.")
    previous = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else []
    if not isinstance(previous, list):
        raise ValueError("Documentation manifest must be a list of owned file paths.")
    previous_targets = [(name, validate_path(name, published)) for name in previous]
    validate_path(".nojekyll", published)

    for name, target in previous_targets:
        if name not in paths and name != ".nojekyll" and target.exists():
            target.unlink()
    for name, target in paths.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(site / name, target)
    (published / ".nojekyll").write_text("", encoding="utf-8")
    manifest.write_text(
        json.dumps(sorted(set(paths) | {".nojekyll"}), indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Updated {len(paths)} documentation files; UI-review archive is untouched.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=Path)
    parser.add_argument("published", type=Path)
    args = parser.parse_args()
    overlay_site(args.site, args.published)


if __name__ == "__main__":
    main()
