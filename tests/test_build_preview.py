import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build_preview.py"


class BuildPreviewTests(unittest.TestCase):
    def test_build_preview_creates_html_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            input_path = tmpdir_path / "sample.md"
            output_dir = tmpdir_path / "out"
            input_path.write_text("# Title\n\n## Section\n\nBody\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(BUILD_SCRIPT),
                    "--input",
                    str(input_path),
                    "--output-dir",
                    str(output_dir),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            stdout_lines = [line for line in result.stdout.splitlines() if line.strip()]
            self.assertEqual(len(stdout_lines), 2)

            html_path = Path(stdout_lines[0])
            manifest_path = Path(stdout_lines[1])
            self.assertTrue(html_path.exists())
            self.assertTrue(manifest_path.exists())

            html = html_path.read_text(encoding="utf-8")
            manifest = manifest_path.read_text(encoding="utf-8")

            self.assertIn('window.BeaconPreview', html)
            self.assertIn('id="section"', html)
            self.assertIn('"anchor": "section"', manifest)
            self.assertIn('"text": "Section"', manifest)

    def test_build_preview_honors_custom_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            input_path = tmpdir_path / "notes.md"
            output_dir = tmpdir_path / "out"
            input_path.write_text("# Title\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(BUILD_SCRIPT),
                    "--input",
                    str(input_path),
                    "--output-dir",
                    str(output_dir),
                    "--name",
                    "custom-preview",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertTrue((output_dir / "custom-preview.html").exists())
            self.assertTrue((output_dir / "custom-preview.json").exists())

    def test_build_preview_reports_missing_pandoc_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            input_path = tmpdir_path / "sample.md"
            output_dir = tmpdir_path / "out"
            input_path.write_text("# Title\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(BUILD_SCRIPT),
                    "--input",
                    str(input_path),
                    "--output-dir",
                    str(output_dir),
                    "--pandoc",
                    "definitely-missing-pandoc-command",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "build_preview.py: pandoc executable not found: definitely-missing-pandoc-command",
                result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
