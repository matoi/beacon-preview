import unittest

from scripts.beaconify_html import inject_navigation_api, instrument_html


class BeaconifyHtmlTests(unittest.TestCase):
    def test_instruments_block_level_elements(self) -> None:
        html = """
        <html><body>
        <h1>Title</h1>
        <p>Paragraph</p>
        <ul><li>Item</li></ul>
        <blockquote><p>Quote</p></blockquote>
        <pre><code>example</code></pre>
        <table><tr><td>A</td></tr></table>
        </body></html>
        """

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('id="beacon-h1-1"', output)
        self.assertIn('id="beacon-p-1"', output)
        self.assertIn('id="beacon-li-1"', output)
        self.assertIn('id="beacon-blockquote-1"', output)
        self.assertIn('id="beacon-pre-1"', output)
        self.assertIn('id="beacon-table-1"', output)
        self.assertEqual(manifest[0]["anchor"], "beacon-h1-1")
        self.assertEqual(manifest[0]["text"], "Title")

    def test_preserves_existing_id_while_adding_beacon_metadata(self) -> None:
        html = '<html><body><h2 id="existing">Section</h2></body></html>'

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('id="existing"', output)
        self.assertIn('data-beacon-kind="h2"', output)
        self.assertIn('data-beacon-index="1"', output)
        self.assertNotIn('id="beacon-h2-1"', output)
        self.assertEqual(manifest[0]["anchor"], "existing")
        self.assertEqual(manifest[0]["text"], "Section")

    def test_instruments_code_like_divs(self) -> None:
        html = '<html><body><div class="sourceCode"><pre><code>x</code></pre></div></body></html>'

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('data-beacon-kind="div"', output)
        self.assertIn('id="beacon-div-1"', output)
        self.assertIn('id="beacon-pre-1"', output)
        self.assertEqual(manifest[0]["kind"], "div")
        self.assertEqual(manifest[1]["text"], "x")

    def test_injects_navigation_api(self) -> None:
        html = '<html><body><h1>Title</h1></body></html>'
        output, manifest = instrument_html(html, prefix="beacon")

        with_api = inject_navigation_api(output, manifest)

        self.assertIn("window.BeaconPreview", with_api)
        self.assertIn("jumpToAnchor", with_api)
        self.assertIn("jumpToIndex", with_api)
        self.assertIn("beacon-h1-1", with_api)

    def test_injects_navigation_api_with_unicode_manifest_text(self) -> None:
        html = '<html><body><h2>日本語 見出し</h2></body></html>'
        output, manifest = instrument_html(html, prefix="beacon")

        with_api = inject_navigation_api(output, manifest)

        self.assertIn("window.BeaconPreview", with_api)
        self.assertIn("\\u65e5\\u672c\\u8a9e", with_api)
        self.assertIn("</body>", with_api)


if __name__ == "__main__":
    unittest.main()
