#!/usr/bin/env python3
"""Check the static artifact, approved brand images, and GitHub Pages project paths."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit
import re
import struct
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / "dist"
ORIGIN = "https://wolfieeee.github.io/HeyNotch/"
RELEASE_TAG = "v2.8.2-preview.3"
REPOSITORY = "https://github.com/WOLFIEEEE/HeyNotch"


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.references = []
        self.aria_references = []
        self.images = []
        self.icons = []
        self.metadata = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if attrs.get(key):
                self.references.append((tag, key, attrs[key]))
        for key in ("aria-controls", "aria-labelledby", "aria-describedby"):
            self.aria_references.extend(attrs.get(key, "").split())
        if tag == "img":
            assert "alt" in attrs, f"Missing image alternative: {attrs.get('src')}"
            assert attrs.get("width", "").isdigit() and attrs.get("height", "").isdigit(), "Images need stable dimensions"
            assert int(attrs["width"]) > 0 and int(attrs["height"]) > 0
            self.images.append(attrs)
        if tag == "meta":
            self.metadata[attrs.get("property", attrs.get("name"))] = attrs.get("content")
        if tag == "link" and attrs.get("rel") == "canonical":
            self.metadata["canonical"] = attrs.get("href")
        if tag == "link" and attrs.get("rel") in ("icon", "apple-touch-icon"):
            self.icons.append(attrs)


def artifact_path(value):
    """Resolve versioned image/CSS/script URLs without dropping the project prefix."""
    parsed = urlsplit(value)
    assert not value.startswith("/"), f"Root-relative asset breaks project path: {value}"
    target = urlsplit(urljoin(ORIGIN, value))
    assert target.scheme == "https" and target.netloc == urlsplit(ORIGIN).netloc, value
    assert target.path.startswith("/HeyNotch/"), f"Asset escapes project: {value}"
    relative = unquote(target.path.removeprefix("/HeyNotch/"))
    assert ".." not in Path(relative).parts, f"Asset traversal: {value}"
    file = ROOT / relative
    assert file.is_file(), f"Missing local asset: {value}"
    return file


def png_size(file):
    data = file.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", f"Invalid PNG: {file}"
    return struct.unpack(">II", data[16:24])


page = Page()
html = (ROOT / "index.html").read_text()
page.feed(html)
assert page.metadata["canonical"] == ORIGIN
assert page.metadata["og:url"] == ORIGIN
social_url = page.metadata["og:image"]
assert social_url.startswith(ORIGIN + "social.png?") and urlsplit(social_url).query, "Social artwork must be versioned"
assert page.metadata["twitter:image"] == social_url
assert page.metadata["og:image:type"] == "image/png"
assert (page.metadata["og:image:width"], page.metadata["og:image:height"]) == ("1200", "630")
assert page.metadata["og:image:alt"] and page.metadata["twitter:image:alt"]
assert png_size(artifact_path(social_url)) == (1200, 630)
assert (ROOT / ".nojekyll").is_file()
for target in page.aria_references:
    assert target in page.ids, f"Missing ARIA target: {target}"
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
    artifact_path(value)

# These are local consistency checks. The release owner must separately verify
# the public notarized asset and matching tag before publishing this website.
release_links = {value for tag, attribute, value in page.references if value.startswith(REPOSITORY)}
assert release_links == {
    f"{REPOSITORY}/tree/{RELEASE_TAG}",
    f"{REPOSITORY}/blob/{RELEASE_TAG}/docs/INSTALL.md",
    f"{REPOSITORY}/releases/tag/{RELEASE_TAG}",
    f"{REPOSITORY}/releases/download/{RELEASE_TAG}/HeyNotch-2.8.2-274-notarized.zip",
}, "Download, guide, notes, and source must identify the same preview release"
assert "Download for Mac" in html and "build 274" in html and "PREVIEW 3" in html
assert "Updates installed manually" in html and "macOS 14 or later" in html
assert "public installer is not available" not in html and "public source may not include" not in html

for attrs in page.images:
    file = artifact_path(attrs["src"])
    if file.suffix == ".svg":
        assert attrs.get("class") == "provider-logo", f"Unexpected SVG image: {file}"
        assert attrs["alt"] == "", "Provider names already label their decorative logos"
        assert (attrs["width"], attrs["height"]) == ("24", "24"), "Provider marks need stable display boxes"
        svg = ET.fromstring(file.read_bytes())
        assert svg.tag == "{http://www.w3.org/2000/svg}svg"
        view_box = [float(value) for value in svg.attrib["viewBox"].split()]
        assert len(view_box) == 4 and view_box[2] > 0 and view_box[3] > 0
    else:
        assert png_size(file) == (int(attrs["width"]), int(attrs["height"])), f"Image dimensions mismatch: {file}"
    assert urlsplit(attrs["src"]).query, f"Brand image needs a version: {file}"
for attrs in page.icons:
    file = artifact_path(attrs["href"])
    width, height = png_size(file)
    assert attrs["sizes"] == f"{width}x{height}", f"Icon size mismatch: {file}"
    assert urlsplit(attrs["href"]).query, f"Icon needs a version: {file}"
assert {(a["rel"], a["sizes"]) for a in page.icons} == {
    ("icon", "32x32"), ("icon", "192x192"), ("apple-touch-icon", "180x180")
}
assert sum(a.get("class") == "brand-wordmark" and a["alt"] == "HeyNotch" for a in page.images) == 2
provider_images = [a for a in page.images if a.get("class") == "provider-logo"]
provider_manifest = json.loads((ROOT / "assets/providers/provenance.json").read_text())
assert len(provider_images) == len(provider_manifest["assets"]) == 3
assert {artifact_path(a["src"]).name for a in provider_images} == {a["file"] for a in provider_manifest["assets"]}
for entry in provider_manifest["assets"]:
    file = ROOT / "assets/providers" / entry["file"]
    assert hashlib.sha256(file.read_bytes()).hexdigest() == entry["sha256"], f"Official artwork changed: {file}"
assert "<b aria-hidden=\"true\">◎</b>" not in html and "<b aria-hidden=\"true\">⇄</b>" not in html

files = list(ROOT.rglob("*"))
for file in files:
    assert not file.is_symlink(), f"Symlink in deployment: {file}"
    if file.is_file() and file.suffix in (".html", ".css", ".js", ".svg"):
        content = file.read_text()
        assert "remotemars.chatgpt.site" not in content, f"Retired host in {file}"
        assert not re.search(r"(?:sk-ant-|sk-proj-|gh[pousr]_)[A-Za-z0-9_-]{16,}", content), f"Possible credential in {file}"
        assert not re.search(r"\b(?:brand-mark|brand-period|little-notch|notch-mini-mark|closing-mark)\b", content), f"Retired logo in {file}"
        if file.suffix == ".css":
            assert not re.search(r"@import\b|url\(\s*['\"]?(?:https?:|//|/)", content), "External or root-relative CSS resource"
assert not (ROOT / "favicon.svg").exists() and not (ROOT / "social.svg").exists(), "Remove retired logo assets"

size = sum(f.stat().st_size for f in files if f.is_file())
assert size <= 2_000_000, f"Static artifact exceeds the 2 MB image budget: {size:,} bytes"
print(f"PASS: GitHub Pages metadata, {len(page.references)} links/assets, {len(page.ids)} unique IDs, {len(page.images)} brand images; {size:,} byte artifact")
