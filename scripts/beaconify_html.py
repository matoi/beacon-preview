#!/usr/bin/env python3
"""Inject simple beacon markers into block-level HTML elements.

NOTE: This script is a historical prototype and is NOT on the runtime path.
Since commit 6c0b998 ("Move preview builds into Emacs and add markdown-ts
support") the preview pipeline runs entirely inside Emacs using libxml and
dom.el (see `lisp/beacon-preview.el`).  This file is kept as a reference for
the original design and its behavior is covered by `tests/test_beaconify_html.py`,
but editing it has no effect on the package.

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

# Tags whose children should not be independently beaconed.  For example, a
# ``<p>`` inside ``<li>`` is part of the list item; counting it as a separate
# paragraph would desynchronize the kind/index mapping between the generated
# HTML and the source-side block counter.
CONTAINER_TAGS = {"li", "blockquote"}

# Tags that suppress beaconing of their own kind when nested.  A ``<blockquote>``
# inside another ``<blockquote>`` corresponds to a single source-side blockquote
# block (``> > text``), so only the outermost gets a beacon.
SUPPRESS_NESTED_TAGS = {"blockquote"}

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


def first_attr_value(attrs: str, name: str) -> str | None:
    pattern = re.compile(
        rf'\b{name}\s*=\s*(?P<quote>["\'])(?P<value>.*?)(?P=quote)',
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(attrs)
    return match.group("value") if match else None


def upsert_attr(attrs: str, name: str, value: str) -> str:
    pattern = re.compile(
        rf'(?P<prefix>\b{name}\s*=\s*)(?P<quote>["\']).*?(?P=quote)',
        re.IGNORECASE | re.DOTALL,
    )
    replacement = f'{name}="{value}"'
    if pattern.search(attrs):
        return pattern.sub(replacement, attrs, count=1)
    return attrs.rstrip() + f' {replacement}'


def parse_positive_int(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        parsed = int(value)
    except ValueError:
        return None
    return parsed if parsed > 0 else None


def resolve_beacon_kind(tag: str, attrs: str) -> str:
    existing_kind = first_attr_value(attrs, "data-beacon-kind")
    if existing_kind:
        return existing_kind
    return tag


def resolve_beacon_index(attrs: str, generated_index: int) -> int:
    existing_index = parse_positive_int(first_attr_value(attrs, "data-beacon-index"))
    return existing_index or generated_index


def inject_attrs(attrs: str, kind: str, index: int, prefix: str) -> str:
    effective_kind = resolve_beacon_kind(kind, attrs)
    effective_index = resolve_beacon_index(attrs, index)
    beacon_id = f'{prefix}-{kind}-{index}'
    updated = attrs.rstrip()

    if not ID_RE.search(attrs):
        updated += f' id="{beacon_id}"'
    updated = upsert_attr(updated, "data-beacon-kind", effective_kind)
    updated = upsert_attr(updated, "data-beacon-index", str(effective_index))
    return updated


def make_manifest_entry(tag: str, attrs: str, kind: str, index: int, prefix: str) -> dict[str, str | int]:
    effective_kind = resolve_beacon_kind(kind, attrs)
    effective_index = resolve_beacon_index(attrs, index)
    existing_id = first_attr_value(attrs, "id")
    anchor_id = existing_id or f"{prefix}-{kind}-{index}"
    return {
        "tag": tag,
        "kind": effective_kind,
        "index": effective_index,
        "anchor": anchor_id,
    }


def render_navigation_script(manifest: list[dict[str, str | int]]) -> str:
    manifest_json = json.dumps(manifest, ensure_ascii=True)
    return f"""
<script>
(function () {{
  const manifest = {manifest_json};
  const FLASH_STYLE_ID = "beacon-preview-flash-style";
  const FLASH_SUBTLE_CLASS = "beacon-preview-flash-subtle";
  const FLASH_STRONG_CLASS = "beacon-preview-flash-strong";
  let flashTimer = null;
  let flashedElement = null;

  function ensureFlashStyle() {{
    if (document.getElementById(FLASH_STYLE_ID)) {{
      return;
    }}

    const style = document.createElement("style");
    style.id = FLASH_STYLE_ID;
    style.textContent = [
      "." + FLASH_SUBTLE_CLASS + " {{",
      "  animation: beacon-preview-flash-subtle 1.05s ease-out;",
      "  background-color: rgba(255, 235, 120, 0.12);",
      "  border-radius: 0.2rem;",
      "}}",
      "." + FLASH_STRONG_CLASS + " {{",
      "  animation: beacon-preview-flash-strong 1.25s ease-out;",
      "  background-color: rgba(255, 235, 120, 0.22);",
      "  box-shadow: inset 0 0 0 2px rgba(255, 196, 0, 0.18);",
      "  border-radius: 0.2rem;",
      "}}",
      "@keyframes beacon-preview-flash-subtle {{",
      "  0% {{ background-color: rgba(255, 235, 120, 0.24); }}",
      "  38% {{ background-color: rgba(255, 235, 120, 0.12); }}",
      "  58% {{ background-color: rgba(255, 235, 120, 0.18); }}",
      "  100% {{ background-color: rgba(255, 235, 120, 0); }}",
      "}}",
      "@keyframes beacon-preview-flash-strong {{",
      "  0% {{ background-color: rgba(255, 235, 120, 0.42); box-shadow: inset 0 0 0 2px rgba(255, 196, 0, 0.3); }}",
      "  35% {{ background-color: rgba(255, 235, 120, 0.2); box-shadow: inset 0 0 0 2px rgba(255, 196, 0, 0.14); }}",
      "  55% {{ background-color: rgba(255, 235, 120, 0.3); box-shadow: inset 0 0 0 2px rgba(255, 196, 0, 0.22); }}",
      "  100% {{ background-color: rgba(255, 235, 120, 0); box-shadow: inset 0 0 0 0 rgba(255, 196, 0, 0); }}",
      "}}"
    ].join("\\n");
    (document.head || document.body || document.documentElement).appendChild(style);
  }}

  function clearFlash() {{
    if (flashTimer !== null) {{
      window.clearTimeout(flashTimer);
      flashTimer = null;
    }}
    if (flashedElement) {{
      flashedElement.classList.remove(FLASH_SUBTLE_CLASS);
      flashedElement.classList.remove(FLASH_STRONG_CLASS);
      flashedElement = null;
    }}
  }}

  function flashElement(element, variant) {{
    if (!element) {{
      return false;
    }}

    const flashClass = variant === "strong" ? FLASH_STRONG_CLASS : FLASH_SUBTLE_CLASS;
    ensureFlashStyle();
    clearFlash();
    flashedElement = element;
    element.classList.add(flashClass);
    flashTimer = window.setTimeout(function () {{
      if (flashedElement === element) {{
        element.classList.remove(flashClass);
        flashedElement = null;
      }}
      flashTimer = null;
    }}, variant === "strong" ? 1300 : 1100);
    return true;
  }}

  function findByAnchor(anchor) {{
    return manifest.find(function (entry) {{
      return entry.anchor === anchor;
    }}) || null;
  }}

  function flashEntry(entry, variant) {{
    if (!entry) {{
      return false;
    }}

    const element = document.getElementById(entry.anchor);
    return flashElement(element, variant);
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

  function jumpToElement(element) {{
    if (!scrollToElement(element)) {{
      return false;
    }}

    flashElement(element, "subtle");
    return true;
  }}

  function jumpToAnchor(anchor) {{
    const element = document.getElementById(anchor);
    return jumpToElement(element);
  }}

  function isElementVisible(element) {{
    if (!element) {{
      return false;
    }}

    const rect = element.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < window.innerHeight;
  }}

  function flashAnchor(anchor) {{
    const entry = findByAnchor(anchor);
    return flashEntry(entry, "subtle");
  }}

  function flashAnchorIfVisible(anchor) {{
    const element = document.getElementById(anchor);
    if (!isElementVisible(element)) {{
      return false;
    }}
    const entry = findByAnchor(anchor);
    return flashEntry(entry, "strong");
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
    jumpToIndex: jumpToIndex,
    flashAnchor: flashAnchor,
    flashAnchorIfVisible: flashAnchorIfVisible,
    flashElement: flashElement,
    isElementVisible: isElementVisible
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
    container_depth = 0
    container_stack: list[str] = []

    def replace(match: re.Match[str]) -> str:
        nonlocal container_depth

        closing = match.group("closing")
        tag = normalize_tag(match.group("tag"))
        attrs = match.group("attrs") or ""
        selfclose = match.group("selfclose") or ""

        if tag in VOID_OR_SELF_CLOSING:
            return match.group(0)

        if closing:
            if tag in CONTAINER_TAGS and container_stack and container_stack[-1] == tag:
                container_stack.pop()
                container_depth -= 1
            return match.group(0)

        if not should_instrument(tag, attrs):
            return match.group(0)

        # Skip child elements inside a beaconed container; they are
        # represented through the parent's beacon in the manifest.
        if container_depth > 0:
            is_nested_container = tag in CONTAINER_TAGS
            # Suppress nested containers of the same kind (e.g. nested
            # blockquotes map to one source block).
            if not is_nested_container or tag in SUPPRESS_NESTED_TAGS:
                if is_nested_container:
                    container_stack.append(tag)
                    container_depth += 1
                return match.group(0)

        if tag in CONTAINER_TAGS:
            container_stack.append(tag)
            container_depth += 1

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
