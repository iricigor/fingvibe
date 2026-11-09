import json
from pathlib import Path
import runpy
import tempfile
import unittest


PUBLISHER = Path(__file__).resolve().parents[1] / "tools" / "Publish-Documentation.py"
overlay_site = runpy.run_path(str(PUBLISHER))["overlay_site"]


class DocumentationPublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.site = root / "site"
        self.published = root / "published"
        self.site.mkdir()
        self.published.mkdir()
        (self.site / "index.html").write_text("New manual", encoding="utf-8")
        (self.published / "index.html").write_text("Old manual", encoding="utf-8")
        self.review = self.published / "ui-review" / "pr-1" / "run-2"
        self.review.mkdir(parents=True)
        (self.review / "image.png").write_bytes(b"existing screenshot")

    def test_preserves_ui_review_and_updates_docs(self):
        overlay_site(self.site, self.published)
        self.assertEqual((self.published / "index.html").read_text(), "New manual")
        self.assertEqual((self.review / "image.png").read_bytes(), b"existing screenshot")
        self.assertTrue((self.published / ".nojekyll").is_file())

    def test_removes_only_previously_owned_stale_files(self):
        (self.published / "manual").mkdir()
        stale = self.published / "manual" / "old.html"
        stale.write_text("Old instructions", encoding="utf-8")
        (self.published / "unrelated.txt").write_text("Keep", encoding="utf-8")
        (self.published / ".documentation-files.json").write_text(
            json.dumps(["manual/old.html"]), encoding="utf-8"
        )
        overlay_site(self.site, self.published)
        self.assertFalse(stale.exists())
        self.assertEqual((self.published / "unrelated.txt").read_text(), "Keep")
        self.assertTrue((self.review / "image.png").exists())

    def test_rejects_archive_files_before_changes(self):
        (self.site / "ui-review").mkdir()
        (self.site / "ui-review" / "image.png").write_bytes(b"replacement")
        with self.assertRaisesRegex(ValueError, "not owned"):
            overlay_site(self.site, self.published)
        self.assertEqual((self.published / "index.html").read_text(), "Old manual")
        self.assertEqual((self.review / "image.png").read_bytes(), b"existing screenshot")

    def test_rejects_unsafe_manifest_before_changes(self):
        for value in ["../outside", "/outside", r"manual\old.html", "ui-review/pr-1/run-2/image.png"]:
            with self.subTest(value=value):
                (self.published / ".documentation-files.json").write_text(
                    json.dumps([value]), encoding="utf-8"
                )
                with self.assertRaises(ValueError):
                    overlay_site(self.site, self.published)
                self.assertEqual((self.published / "index.html").read_text(), "Old manual")

    def test_rejects_wrong_manifest_shape(self):
        (self.published / ".documentation-files.json").write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "must be a list"):
            overlay_site(self.site, self.published)

    def test_rejects_missing_homepage(self):
        (self.site / "index.html").unlink()
        with self.assertRaisesRegex(ValueError, "no index.html"):
            overlay_site(self.site, self.published)

    def test_repeat_publish_is_identical(self):
        overlay_site(self.site, self.published)
        first = (self.published / ".documentation-files.json").read_bytes()
        overlay_site(self.site, self.published)
        self.assertEqual((self.published / ".documentation-files.json").read_bytes(), first)


if __name__ == "__main__":
    unittest.main()
