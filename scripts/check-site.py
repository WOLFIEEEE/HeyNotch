#!/usr/bin/env python3
"""Check that the static artifact is complete under the GitHub Pages project path."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit
import re

ROOT = Path(__file__).resolve().parents[1] / "dist"
ORIGIN = "https://wolfieeee.github.io/HeyNotch/"


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.references = []
        self.metadata = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if attrs.get(key):
                self.references.append((tag, key, attrs[key]))
        if tag == "meta":
            self.metadata[attrs.get("property", attrs.get("name"))] = attrs.get("content")
        if tag == "link" and attrs.get("rel") == "canonical":
            self.metadata["canonical"] = attrs.get("href")


page = Page()
page.feed((ROOT / "index.html").read_text())
assert page.metadata["canonical"] == ORIGIN
assert page.metadata["og:url"] == ORIGIN
assert page.metadata["og:image"] == ORIGIN + "social.svg"
assert (ROOT / ".nojekyll").is_file()
for tag, attribute, value in page.references:
    if value.startswith("#"):
        assert not value[1:] or value[1:] in page.ids, f"Broken anchor: {value}"
        continue
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        assert parsed.scheme == "https", f"Unexpected URL scheme: {value}"
        assert tag in ("a", "link"), f"External runtime asset: {value}"
        assert value.startswith((ORIGIN, "https://github.com/WOLFIEEEE/HeyNotch")), value
        continue
    assert not value.startswith("/"), f"Root-relative asset breaks project path: {value}"
    target = urlsplit(urljoin(ORIGIN, value))
    assert target.path.startswith("/HeyNotch/"), f"Asset escapes project: {value}"
    file = ROOT / unquote(target.path.removeprefix("/HeyNotch/"))
    assert file.is_file(), f"Missing local asset: {value}"

files = list(ROOT.rglob("*"))
for file in files:
    assert not file.is_symlink(), f"Symlink in deployment: {file}"
    if file.is_file() and file.suffix in (".html", ".css", ".js", ".svg"):
        content = file.read_text()
        assert "remotemars.chatgpt.site" not in content, f"Retired host in {file}"
        assert not re.search(r"(?:sk-ant-|sk-proj-|gh[pousr]_)[A-Za-z0-9_-]{16,}", content), f"Possible credential in {file}"
        if file.suffix == ".css":
            assert not re.search(r"@import\b|url\(\s*['\"]?(?:https?:|//|/)", content), "External or root-relative CSS resource"

size = sum(f.stat().st_size for f in files if f.is_file())
print(f"PASS: GitHub Pages metadata, {len(page.references)} links/assets, {len(page.ids)} unique IDs; {size:,} byte artifact")
