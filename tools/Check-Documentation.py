"""Check a built MkDocs site without contacting external websites."""

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urljoin, urlsplit


SITE_URL = "https://iricigor.github.io/fingvibe/"
VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.ids = set()
        self.links = []
        self.errors = []
        self.hidden = []
        self.feed(content)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        hidden = attrs.get("aria-hidden") == "true" or (
            bool(self.hidden) and self.hidden[-1][1]
        )
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if "twemoji" in attrs.get("class", "").split() and not hidden:
            self.errors.append("Decorative manual icon is not aria-hidden.")
        if tag == "img" and not attrs.get("alt", "").strip():
            self.errors.append(f"Image has no alternative text: {attrs.get('src')}")
        for attribute in ("href", "src"):
            if attrs.get(attribute):
                resource = attribute == "src" or (
                    tag == "link" and "stylesheet" in attrs.get("rel", "").split()
                )
                self.links.append((attrs[attribute], resource))
        if tag not in VOID_TAGS:
            self.hidden.append((tag, hidden))

    def handle_endtag(self, tag):
        for index in range(len(self.hidden) - 1, -1, -1):
            if self.hidden[index][0] == tag:
                del self.hidden[index:]
                break


def check_site(site):
    site = site.resolve()
    pages = {
        path: Page(path.read_text(encoding="utf-8"))
        for path in site.rglob("*.html")
    }
    errors = []
    if site / "index.html" not in pages:
        errors.append("Site has no index.html.")

    def check_link(source, value, resource=False):
        relative = source.relative_to(site).as_posix()
        page_url = urljoin(SITE_URL, relative)
        url = urlsplit(urljoin(page_url, value))
        prefix = urlsplit(SITE_URL)
        if url.scheme not in ("http", "https"):
            return
        if url.netloc != prefix.netloc or not url.path.startswith(prefix.path):
            if resource:
                errors.append(f"{relative}: external asset request: {value}")
            return
        local = unquote(url.path[len(prefix.path):])
        target = (site / local).resolve()
        if not target.is_relative_to(site):
            errors.append(f"{relative}: link escapes site: {value}")
            return
        if target.is_dir():
            target /= "index.html"
        if not target.is_file():
            errors.append(f"{relative}: missing target: {value}")
        elif url.fragment and target in pages:
            if unquote(url.fragment) not in pages[target].ids:
                errors.append(f"{relative}: missing anchor: {value}")

    for path, page in pages.items():
        errors.extend(f"{path.relative_to(site)}: {error}" for error in page.errors)
        for value, resource in page.links:
            check_link(path, value, resource)

    search_path = site / "search" / "search_index.json"
    if not search_path.is_file():
        errors.append("Site has no local search index.")
    else:
        search = json.loads(search_path.read_text(encoding="utf-8"))
        documents = search.get("docs", [])
        if not documents:
            errors.append("Search index contains no documents.")
        for document in documents:
            if not document.get("title") or not document.get("text", "").strip():
                errors.append(f"Empty search document: {document.get('location')}")
            check_link(site / "index.html", document["location"])
        indexed_paths = {
            urlsplit(document["location"]).path for document in documents
        }
        for page in pages:
            relative = page.relative_to(site).as_posix()
            if relative == "404.html":
                continue
            location = relative.removesuffix("index.html")
            if location not in indexed_paths:
                errors.append(f"Page missing from search index: {relative}")

    return errors, len(pages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=Path)
    args = parser.parse_args()
    errors, count = check_site(args.site)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f"Checked {count} HTML pages: links, anchors, assets, icons, and search.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
