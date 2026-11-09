import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "tools" / "Check-Documentation.py"


class DocumentationTests(unittest.TestCase):
    def check(self, content, *, search=True, documents=None):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "index.html").write_text(content, encoding="utf-8")
            if search:
                (site / "search").mkdir()
                docs = documents if documents is not None else [
                    {"location": "", "title": "Home", "text": "Useful instructions."}
                ]
                (site / "search" / "search_index.json").write_text(
                    json.dumps({"docs": docs}), encoding="utf-8"
                )
            return subprocess.run(
                [sys.executable, str(CHECKER), str(site)],
                capture_output=True, text=True, check=False,
            )

    def test_project_url_and_hidden_icon_pass(self):
        result = self.check(
            '<h1 id="home">Home</h1>'
            '<a href="https://iricigor.github.io/fingvibe/#home">Home</a>'
            '<span aria-hidden="true"><span class="twemoji"><svg></svg></span></span>'
            '<a href="https://github.com/iricigor/fingvibe">Source</a>'
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_link_and_anchor_fail(self):
        result = self.check('<a href="missing/">Missing</a><a href="#absent">Bad</a>')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing target", result.stderr)
        self.assertIn("missing anchor", result.stderr)

    def test_missing_alt_and_external_assets_fail(self):
        result = self.check(
            '<img src="https://example.com/private.png">'
            '<script src="https://example.com/analytics.js"></script>'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no alternative text", result.stderr)
        self.assertIn("external asset request", result.stderr)

    def test_unhidden_icon_fails(self):
        result = self.check('<span class="twemoji"><svg></svg></span>')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not aria-hidden", result.stderr)

    def test_missing_and_empty_search_fail(self):
        result = self.check("<h1>Home</h1>", search=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no local search index", result.stderr)
        result = self.check("<h1>Home</h1>", documents=[])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no documents", result.stderr)

    def test_invalid_search_target_fails(self):
        result = self.check(
            "<h1>Home</h1>",
            documents=[{"location": "missing/", "title": "Missing", "text": "Text"}],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing target", result.stderr)
        self.assertIn("missing from search", result.stderr)


if __name__ == "__main__":
    unittest.main()
