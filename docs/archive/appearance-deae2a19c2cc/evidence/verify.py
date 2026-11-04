"""Verify this self-contained archive using only the Python standard library."""

import argparse
import hashlib
import itertools
import json
import re
import struct
import zipfile
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
COMMIT = "deae2a19c2cc8218183f08b777347215b7fa31e6"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_source():
    manifest = json.loads((ROOT / "evidence" / "source-manifest.json").read_text())
    archive = ROOT / manifest["zip"]
    require(manifest["commit"] == COMMIT, "Unexpected source revision")
    require(archive.stat().st_size == manifest["zipBytes"], "ZIP size mismatch")
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["zipSha256"], "ZIP checksum mismatch")
    with zipfile.ZipFile(archive) as source:
        require(source.comment.decode("ascii") == COMMIT, "git archive revision comment mismatch")
        files = [entry for entry in source.infolist() if not entry.is_dir()]
        require(len(files) == len(manifest["files"]), "Tracked file count mismatch")
        require({entry.filename for entry in files} == set(manifest["files"]), "Tracked paths mismatch")
        for entry in files:
            parts = Path(entry.filename).parts
            require(not (set(parts) & {".git", "bin", "obj", "node_modules", ".vs"}), f"Forbidden source path: {entry.filename}")
            require(not entry.filename.endswith((".user", ".suo", ".env")), f"Local settings: {entry.filename}")
            data = source.read(entry)
            blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
            require(blob == manifest["files"][entry.filename], f"Tracked blob mismatch: {entry.filename}")
    print(f"Source verified: {len(files)} tracked files, {archive.stat().st_size:,} ZIP bytes, {COMMIT}")
    return manifest


def verify_gallery(source):
    evidence = ROOT / "evidence" / "capture-manifest.json"
    manifest = json.loads(evidence.read_text(encoding="utf-8-sig"))
    require(manifest["sourceCommit"] == COMMIT, "Capture revision mismatch")
    require(manifest["sourceZipSha256"] == source["zipSha256"], "Capture ZIP mismatch")
    require(manifest["fixture"] in source["files"], "Fixture is not from the source ZIP")
    with zipfile.ZipFile(ROOT / source["zip"]) as archive:
        require(hashlib.sha256(archive.read(manifest["fixture"])).hexdigest() == manifest["fixtureSha256"], "Fixture checksum mismatch")
    captures = manifest["captures"]
    require(len(captures) == 25, "Expected 25 captures")
    expected = set(itertools.product(
        ("Glass", "Clay", "Neumorphic"), ("Light", "Dark"), ("Standard", "Colored"), ("Overview", "Devices")
    ))
    actual = {(item["style"], item["mode"], item["theme"], item["page"]) for item in captures if item["page"] != "Settings"}
    require(actual == expected, "Appearance matrix mismatch")
    settings = [item for item in captures if item["page"] == "Settings"]
    require(len(settings) == 1, "Expected one Settings image")
    names = {item["file"] for item in captures}
    require(names == {path.name for path in (ROOT / "screenshots").glob("*.png")}, "Unexpected or missing image files")
    hashes = set()
    total = 0
    for item in captures:
        path = ROOT / "screenshots" / item["file"]
        data = path.read_bytes()
        checksum = hashlib.sha256(data).hexdigest()
        hashes.add(checksum)
        total += len(data)
        require(checksum == item["sha256"], f"Image checksum mismatch: {path.name}")
        require(data[:8] == b"\x89PNG\r\n\x1a\n", f"Not a PNG: {path.name}")
        require(struct.unpack(">II", data[16:24]) == (1600, 960), f"Viewport mismatch: {path.name}")
        require(item["backdrop"] == ("Mica Alt" if item["style"] == "Glass" else "Solid"), "Backdrop mismatch")
        require(bool(item["materialStatus"]) and bool(item["materialEvidence"]), "Missing material evidence")
    require(len(hashes) == 25, "Expected 25 unique images")
    for doc in (ROOT / "README.md", ROOT / "IMPLEMENTATION.md", ROOT / "gallery" / "README.md"):
        text = doc.read_text(encoding="utf-8")
        for target in re.findall(r"\]\(([^)]+)\)", text):
            if "://" not in target and not target.startswith("#"):
                require((doc.parent / unquote(target.split("#")[0])).is_file(), f"Broken local link in {doc}: {target}")
    previews = re.findall(r"!\[[^\]]*\]\(([^)]+)\)", (ROOT / "README.md").read_text())
    require(len(previews) == 3, "Short README must have exactly three previews")
    require(set(previews) == {f"screenshots/{style}-dark-standard-devices.png" for style in ("glass", "clay", "neumorphic")}, "Preview choices mismatch")
    gallery = (ROOT / "gallery" / "README.md").read_text()
    require(len(re.findall(r"!\[", gallery)) == 25, "Gallery must embed all 25 images exactly once")
    for name in names:
        require(gallery.count(f"(../screenshots/{name})") == 2, f"Gallery thumbnail must link to its local original: {name}")
    total_archive = sum(path.stat().st_size for path in ROOT.rglob("*") if path.is_file())
    print(f"Gallery verified: 24 matrix images + Settings, {total:,} PNG bytes; archive total {total_archive:,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    source = verify_source()
    if not args.source_only:
        verify_gallery(source)
