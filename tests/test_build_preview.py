import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build_preview.py"

spec = __import__("importlib.util").util.spec_from_file_location(
    "build_preview", BUILD_SCRIPT
)
build_preview = __import__("importlib.util").util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(build_preview)


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

    def test_run_pandoc_uses_gfm_input_format(self) -> None:
        input_path = Path("/tmp/sample.md")
        output_path = Path("/tmp/sample.html")

        with mock.patch.object(build_preview.subprocess, "run") as run_mock:
            build_preview.run_pandoc("pandoc", input_path, output_path)

        run_mock.assert_called_once_with(
            ["pandoc", "-f", "gfm", str(input_path), "-s", "-o", str(output_path)],
            check=True,
        )

    def test_run_pandoc_uses_org_input_format_for_org_files(self) -> None:
        input_path = Path("/tmp/sample.org")
        output_path = Path("/tmp/sample.html")

        with mock.patch.object(build_preview.subprocess, "run") as run_mock:
            build_preview.run_pandoc("pandoc", input_path, output_path)

        run_mock.assert_called_once_with(
            ["pandoc", "-f", "org", str(input_path), "-s", "-o", str(output_path)],
            check=True,
        )

    def test_emit_artifact_paths_writes_exact_stdout_contract(self) -> None:
        html_path = Path("/tmp/out/sample.html")
        manifest_path = Path("/tmp/out/sample.json")

        with mock.patch.object(build_preview, "print") as print_mock:
            build_preview.emit_artifact_paths(html_path, manifest_path)

        self.assertEqual(
            print_mock.call_args_list,
            [mock.call(html_path), mock.call(manifest_path)],
        )

    def test_ensure_artifacts_exist_reports_missing_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            html_path = tmpdir_path / "sample.html"
            manifest_path = tmpdir_path / "sample.json"
            html_path.write_text("<html></html>", encoding="utf-8")

            with self.assertRaisesRegex(
                RuntimeError,
                "expected manifest artifact was not created",
            ):
                build_preview.ensure_artifacts_exist(html_path, manifest_path)

    def test_build_preview_supports_gfm_tables_task_lists_strikethrough_and_fences(self) -> None:
        markdown = (
            "# Title\n\n"
            "| A | B |\n"
            "| --- | --- |\n"
            "| 1 | 2 |\n\n"
            "- [x] done\n"
            "- [ ] todo\n\n"
            "This has ~~strike~~ text.\n\n"
            "```python\n"
            "print(1)\n"
            "```\n"
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            input_path = tmpdir_path / "gfm-sample.md"
            output_dir = tmpdir_path / "out"
            input_path.write_text(markdown, encoding="utf-8")

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

            html = Path(stdout_lines[0]).read_text(encoding="utf-8")
            manifest = Path(stdout_lines[1]).read_text(encoding="utf-8")

            self.assertIn('<table id="beacon-table-1"', html)
            self.assertIn('<ul class="task-list">', html)
            self.assertIn('type="checkbox" checked=""', html)
            self.assertIn('type="checkbox" />todo', html)
            self.assertIn('<del>strike</del>', html)
            self.assertIn('class="sourceCode python"', html)
            self.assertIn('id="beacon-pre-1"', html)

            self.assertIn('"kind": "table"', manifest)
            self.assertIn('"anchor": "beacon-table-1"', manifest)
            self.assertIn('"kind": "li"', manifest)
            self.assertIn('"anchor": "beacon-li-1"', manifest)
            self.assertIn('"anchor": "beacon-li-2"', manifest)
            self.assertIn('"kind": "p"', manifest)
            self.assertIn('"text": "This has strike"', manifest)
            self.assertIn('"kind": "div"', manifest)
            self.assertIn('"anchor": "beacon-pre-1"', manifest)


if __name__ == "__main__":
    unittest.main()
