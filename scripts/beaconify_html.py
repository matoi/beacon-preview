#!/usr/bin/env python3
"""Inject simple beacon markers into block-level HTML elements.

This is a prototype aimed at Pandoc-generated HTML. It intentionally starts with
block-level anchors rather than precise source-line mapping.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from collections import defaultdict
from html.parser import HTMLParser
from pathlib import Path


TARGET_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote", "pre", "table"}
VOID_OR_SELF_CLOSING = {"br", "hr", "img", "input", "meta", "link"}

TAG_RE = re.compile(r"<(?P<closing>/)?(?P<tag>[A-Za-z][A-Za-z0-9:-]*)(?P<attrs>[^<>]*?)(?P<selfclose>/)?>")
CLASS_RE = re.compile(r'\bclass\s*=\s*(?P<quote>["\'])(?P<value>.*?)(?P=quote)', re.IGNORECASE | re.DOTALL)
ID_RE = re.compile(r"\bid\s*=", re.IGNORECASE)
DATA_KIND_RE = re.compile(r"\bdata-beacon-kind\s*=", re.IGNORECASE)
DATA_INDEX_RE = re.compile(r"\bdata-beacon-index\s*=", re.IGNORECASE)
BODY_CLOSE_RE = re.compile(r"</body\s*>", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Input HTML file")
    parser.add_argument("--output", help="Output HTML file; defaults to stdout")
    parser.add_argument(
        "--manifest-output",
        help="Optional JSON file for extracted beacon target metadata",
    )
    parser.add_argument(
        "--prefix",
        default="beacon",
        help="Prefix for generated anchor ids (default: beacon)",
    )
    parser.add_argument(
        "--inject-navigation-api",
        action="store_true",
        help="Inject a small browser-side BeaconPreview API into the HTML",
    )
    return parser.parse_args()


def normalize_tag(tag: str) -> str:
    return tag.lower()


def has_code_like_class(attrs: str) -> bool:
    match = CLASS_RE.search(attrs)
    if not match:
        return False

    classes = {item.strip() for item in match.group("value").split() if item.strip()}
    return bool({"sourceCode", "sourceCodeContainer", "listing"} & classes)


def should_instrument(tag: str, attrs: str) -> bool:
    if tag in TARGET_TAGS:
        return True

    if tag == "div" and has_code_like_class(attrs):
        return True

    return False


def inject_attrs(attrs: str, kind: str, index: int, prefix: str) -> str:
    beacon_id = f'{prefix}-{kind}-{index}'
    pieces = [attrs.rstrip()]

    if not ID_RE.search(attrs):
        pieces.append(f' id="{beacon_id}"')
    if not DATA_KIND_RE.search(attrs):
        pieces.append(f' data-beacon-kind="{kind}"')
    if not DATA_INDEX_RE.search(attrs):
        pieces.append(f' data-beacon-index="{index}"')

    return "".join(pieces)


def first_attr_value(attrs: str, name: str) -> str | None:
    pattern = re.compile(
        rf'\b{name}\s*=\s*(?P<quote>["\'])(?P<value>.*?)(?P=quote)',
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(attrs)
    return match.group("value") if match else None


def make_manifest_entry(tag: str, attrs: str, kind: str, index: int, prefix: str) -> dict[str, str | int]:
    existing_id = first_attr_value(attrs, "id")
    anchor_id = existing_id or f"{prefix}-{kind}-{index}"
    return {
        "tag": tag,
        "kind": kind,
        "index": index,
        "anchor": anchor_id,
    }


def render_navigation_script(manifest: list[dict[str, str | int]]) -> str:
    manifest_json = json.dumps(manifest, ensure_ascii=True)
    return f"""
<script>
(function () {{
  const manifest = {manifest_json};

  function findByAnchor(anchor) {{
    return manifest.find(function (entry) {{
      return entry.anchor === anchor;
    }}) || null;
  }}

  function findByIndex(kind, index) {{
    return manifest.find(function (entry) {{
      return entry.kind === kind && entry.index === index;
    }}) || null;
  }}

  function scrollToElement(element) {{
    if (!element) {{
      return false;
    }}

    element.scrollIntoView({{ behavior: "auto", block: "center", inline: "nearest" }});
    return true;
  }}

  function jumpToAnchor(anchor) {{
    const element = document.getElementById(anchor);
    return scrollToElement(element);
  }}

  function jumpToIndex(kind, index) {{
    const entry = findByIndex(kind, index);
    return entry ? jumpToAnchor(entry.anchor) : false;
  }}

  window.BeaconPreview = {{
    manifest: manifest,
    findByAnchor: findByAnchor,
    findByIndex: findByIndex,
    jumpToAnchor: jumpToAnchor,
    jumpToIndex: jumpToIndex
  }};
}})();
</script>
""".strip()


def inject_navigation_api(html: str, manifest: list[dict[str, str | int]]) -> str:
    script = render_navigation_script(manifest)

    if BODY_CLOSE_RE.search(html):
        return BODY_CLOSE_RE.sub(lambda _match: script + "\n</body>", html, count=1)

    return html + "\n" + script + "\n"


class BeaconManifestTextParser(HTMLParser):
    """Extract text content for instrumented beacon elements."""

    def __init__(self) -> None:
        super().__init__()
        self.stack: list[tuple[str, int, list[str]]] = []
        self.text_by_key: dict[tuple[str, int], str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_dict = dict(attrs)
        kind = attrs_dict.get("data-beacon-kind")
        index = attrs_dict.get("data-beacon-index")
        if kind is not None and index is not None:
            try:
                self.stack.append((kind, int(index), []))
            except ValueError:
                return

    def handle_endtag(self, tag: str) -> None:
        if not self.stack:
            return
        kind, index, chunks = self.stack.pop()
        text = normalize_text_content("".join(chunks))
        if text and (kind, index) not in self.text_by_key:
            self.text_by_key[(kind, index)] = text
        if self.stack and text:
            self.stack[-1][2].append(text + " ")

    def handle_data(self, data: str) -> None:
        if self.stack:
            self.stack[-1][2].append(data)

    def handle_entityref(self, name: str) -> None:
        self.handle_data(html.unescape(f"&{name};"))

    def handle_charref(self, name: str) -> None:
        self.handle_data(html.unescape(f"&#{name};"))


def normalize_text_content(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def enrich_manifest_with_text(html_text: str, manifest: list[dict[str, str | int]]) -> list[dict[str, str | int]]:
    parser = BeaconManifestTextParser()
    parser.feed(html_text)
    parser.close()

    enriched: list[dict[str, str | int]] = []
    for entry in manifest:
        updated = dict(entry)
        key = (str(entry["kind"]), int(entry["index"]))
        text = parser.text_by_key.get(key)
        if text:
            updated["text"] = text
        enriched.append(updated)
    return enriched


def instrument_html(text: str, prefix: str) -> tuple[str, list[dict[str, str | int]]]:
    counters: defaultdict[str, int] = defaultdict(int)
    manifest: list[dict[str, str | int]] = []

    def replace(match: re.Match[str]) -> str:
        closing = match.group("closing")
        tag = normalize_tag(match.group("tag"))
        attrs = match.group("attrs") or ""
        selfclose = match.group("selfclose") or ""

        if closing or tag in VOID_OR_SELF_CLOSING:
            return match.group(0)

        if not should_instrument(tag, attrs):
            return match.group(0)

        counters[tag] += 1
        manifest.append(make_manifest_entry(tag, attrs, tag, counters[tag], prefix))
        new_attrs = inject_attrs(attrs, tag, counters[tag], prefix)
        return f"<{tag}{new_attrs}{selfclose}>"

    instrumented = TAG_RE.sub(replace, text)
    return instrumented, enrich_manifest_with_text(instrumented, manifest)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else None

    html = input_path.read_text(encoding="utf-8")
    instrumented, manifest = instrument_html(html, prefix=args.prefix)

    if args.inject_navigation_api:
        instrumented = inject_navigation_api(instrumented, manifest)

    if output_path is None:
        sys.stdout.write(instrumented)
    else:
        output_path.write_text(instrumented, encoding="utf-8")

    if args.manifest_output:
        manifest_path = Path(args.manifest_output)
        manifest_path.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
