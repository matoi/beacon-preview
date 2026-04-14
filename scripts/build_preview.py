#!/usr/bin/env python3
"""Build beaconable preview artifacts from a supported source file."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Input Markdown file")
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory where preview artifacts should be written",
    )
    parser.add_argument(
        "--name",
        help="Base filename for output artifacts; defaults to the input stem",
    )
    parser.add_argument(
        "--pandoc",
        default="pandoc",
        help="Pandoc executable to use (default: pandoc)",
    )
    parser.add_argument(
        "--prefix",
        default="beacon",
        help="Prefix for generated beacon ids (default: beacon)",
    )
    return parser.parse_args()


def build_paths(input_path: Path, output_dir: Path, name: str | None) -> tuple[Path, Path]:
    base = name or input_path.stem
    html_path = output_dir / f"{base}.html"
    manifest_path = output_dir / f"{base}.json"
    return html_path, manifest_path


def pandoc_input_format_for_path(input_path: Path) -> str:
    suffix = input_path.suffix.lower()
    if suffix == ".org":
        return "org"
    return "gfm"


def run_pandoc(pandoc: str, input_path: Path, output_path: Path) -> None:
    input_format = pandoc_input_format_for_path(input_path)
    try:
        subprocess.run(
            [pandoc, "-f", input_format, str(input_path), "-s", "-o", str(output_path)],
            check=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"pandoc executable not found: {pandoc}") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"pandoc failed with exit status {exc.returncode}") from exc


def run_beaconify(input_path: Path, output_html: Path, output_manifest: Path, prefix: str) -> None:
    script_path = Path(__file__).with_name("beaconify_html.py")
    try:
        subprocess.run(
            [
                sys.executable,
                str(script_path),
                "--input",
                str(input_path),
                "--output",
                str(output_html),
                "--manifest-output",
                str(output_manifest),
                "--inject-navigation-api",
                "--prefix",
                prefix,
            ],
            check=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"python executable not found: {sys.executable}") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"beaconify step failed with exit status {exc.returncode}") from exc


def ensure_artifacts_exist(html_path: Path, manifest_path: Path) -> None:
    """Validate that the expected preview artifacts were created."""
    if not html_path.is_file():
        raise RuntimeError(f"expected HTML artifact was not created: {html_path}")
    if not manifest_path.is_file():
        raise RuntimeError(f"expected manifest artifact was not created: {manifest_path}")


def emit_artifact_paths(html_path: Path, manifest_path: Path) -> None:
    """Emit the builder stdout contract as absolute HTML and manifest paths."""
    print(html_path)
    print(manifest_path)


def main() -> int:
    try:
        args = parse_args()
        input_path = Path(args.input).expanduser().resolve()
        output_dir = Path(args.output_dir).expanduser().resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        html_path, manifest_path = build_paths(input_path, output_dir, args.name)

        with tempfile.TemporaryDirectory(prefix="beacon-preview-") as tmpdir:
            pandoc_html = Path(tmpdir) / "pandoc-output.html"
            run_pandoc(args.pandoc, input_path, pandoc_html)
            run_beaconify(pandoc_html, html_path, manifest_path, args.prefix)

        ensure_artifacts_exist(html_path, manifest_path)
        emit_artifact_paths(html_path, manifest_path)
        return 0
    except RuntimeError as exc:
        print(f"build_preview.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
