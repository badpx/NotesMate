#!/usr/bin/env python3
"""Build the static product site using the app's 15 localization catalogs."""
import argparse
import hashlib
import html
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {
    "en": "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語",
    "ko": "한국어", "de": "Deutsch", "fr": "Français", "es": "Español",
    "pt": "Português", "it": "Italiano", "fil": "Filipino", "id": "Bahasa Indonesia",
    "ms": "Bahasa Melayu", "th": "ไทย", "vi": "Tiếng Việt",
}
TOKEN = re.compile(r"\{\{\s*([\w.]+)\s*\}\}")
ENTRY = re.compile(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;')


def catalog(language):
    source = ROOT / "NotesMate/Localization" / f"{language}.lproj/Localizable.strings"
    result = {}
    for match in ENTRY.finditer(source.read_text()):
        key, value = (json.loads(part) for part in match.groups())
        if key in result:
            raise ValueError(f"Duplicate localization: {language}: {key}")
        result[key] = value
    return result


def build(output, base, site_url, release_file):
    if base and (not base.startswith("/") or base.endswith("/") or ".." in base):
        raise ValueError("Base must be empty or an absolute path without a trailing slash")
    if urlparse(site_url).scheme != "https":
        raise ValueError("The canonical site URL must use HTTPS")
    release = json.loads(release_file.read_text())
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("The website must link to a public stable release")
    assets = [a for a in release["assets"] if a["name"].endswith("-macos.dmg")]
    if len(assets) != 1:
        raise ValueError("Expected exactly one macOS DMG in the latest release")
    download = assets[0]["browser_download_url"]
    if not download.startswith("https://github.com/badpx/NotesMate/releases/download/"):
        raise ValueError("Unexpected download URL")
    if not release["html_url"].startswith("https://github.com/badpx/NotesMate/releases/tag/"):
        raise ValueError("Unexpected release URL")
    template = (ROOT / "website/index.template.html").read_text()
    required = {key for key in TOKEN.findall(template) if key.startswith("Website.")}
    catalogs = {language: catalog(language) for language in LANGUAGES}
    expected = {key for key in catalogs["en"] if key.startswith("Website.")}
    if required != expected:
        raise ValueError(f"Template/catalog key mismatch: {required ^ expected}")
    supported = re.search(r"static let supported = \[(.*?)\]", (ROOT / "NotesMate/Editor/EditorLanguage.swift").read_text()).group(1)
    if set(re.findall(r'"([^"]+)"', supported)) != set(LANGUAGES):
        raise ValueError("Website languages must match EditorLanguage.supported")
    for language, values in catalogs.items():
        keys = {key for key in values if key.startswith("Website.")}
        if keys != expected or any(not values[key].strip() for key in expected):
            raise ValueError(f"Incomplete website translations: {language}")

    # Only the generated build directory is replaced; source files are never removed.
    if output.resolve() != (ROOT / "build/website").resolve():
        raise ValueError("Output must be build/website")
    if output.exists():
        shutil.rmtree(output)
    (output / "assets").mkdir(parents=True)
    asset_versions = {}
    for name in ("style.css", "site.js"):
        shutil.copyfile(ROOT / "website" / name, output / "assets" / name)
        asset_versions[name] = hashlib.sha256((output / "assets" / name).read_bytes()).hexdigest()[:12]
    for destination, source in {
        "note.svg": "NotesMate/Resources/AppIcon.icon/Assets/note.svg",
        "favicon.png": "NotesMate/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png",
        "preview-light-en.png": "docs/design/main-window-light-en-v2.png",
        "preview-dark-en.png": "docs/design/main-window-dark-en-v2.png",
        "preview-light-zh.png": "docs/design/main-window-v3.png",
        "preview-dark-zh.png": "docs/design/main-window-dark-v2.png",
    }.items():
        shutil.copyfile(ROOT / source, output / "assets" / destination)

    def suffix(language):
        return "/" if language == "en" else f"/{language}/"

    for language, values in catalogs.items():
        replacements = dict(values)
        replacements.update({
            "_lang": language, "_base": base, "_home": base + suffix(language),
            "_canonical": site_url + suffix(language), "_site_url": site_url,
            "_download": download, "_release": release["html_url"], "_version": release["tag_name"],
            "_preview_language": "zh" if language.startswith("zh") else "en",
            "_style_version": asset_versions["style.css"], "_script_version": asset_versions["site.js"],
        })
        raw = {
            "_alternates": "\n  ".join(
                f'<link rel="alternate" hreflang="{code}" href="{html.escape(site_url + suffix(code), quote=True)}">'
                for code in LANGUAGES
            ) + f'\n  <link rel="alternate" hreflang="x-default" href="{html.escape(site_url, quote=True)}/">',
            "_languages": "".join(
                f'<option value="{html.escape(base + suffix(code), quote=True)}"{" selected" if code == language else ""}>{label}</option>'
                for code, label in LANGUAGES.items()
            ),
        }
        def replace(match):
            key = match.group(1)
            return raw[key] if key in raw else html.escape(replacements[key], quote=True)
        page = TOKEN.sub(replace, template)
        destination = output if language == "en" else output / language
        destination.mkdir(exist_ok=True)
        (destination / "index.html").write_text(page)
    urls = "".join(f"<url><loc>{html.escape(site_url + suffix(code))}</loc></url>" for code in LANGUAGES)
    (output / "sitemap.xml").write_text(f'<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>')
    (output / ".nojekyll").touch()
    print(f"Built {len(LANGUAGES)} languages → {output.relative_to(ROOT)} ({release['tag_name']})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="/NotesMate")
    parser.add_argument("--site-url", default="https://badpx.github.io/NotesMate")
    parser.add_argument("--release-json", type=Path, default=ROOT / "website/release.json")
    arguments = parser.parse_args()
    build(ROOT / "build/website", arguments.base, arguments.site_url.rstrip("/"), arguments.release_json)
