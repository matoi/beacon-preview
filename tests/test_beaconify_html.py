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
        self.assertIn("flashAnchor", with_api)
        self.assertIn("flashAnchorIfVisible", with_api)
        self.assertIn("isElementVisible", with_api)
        self.assertIn("flashElement", with_api)
        self.assertIn("beacon-preview-flash", with_api)
        self.assertIn("beacon-h1-1", with_api)

    def test_injects_navigation_api_with_unicode_manifest_text(self) -> None:
        html = '<html><body><h2>日本語 見出し</h2></body></html>'
        output, manifest = instrument_html(html, prefix="beacon")

        with_api = inject_navigation_api(output, manifest)

        self.assertIn("window.BeaconPreview", with_api)
        self.assertIn("\\u65e5\\u672c\\u8a9e", with_api)
        self.assertIn("</body>", with_api)

    def test_preserves_existing_beacon_data_attributes(self) -> None:
        html = (
            '<html><body><p id="existing" data-beacon-kind="p" '
            'data-beacon-index="7">Paragraph</p></body></html>'
        )

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('id="existing"', output)
        self.assertIn('data-beacon-kind="p"', output)
        self.assertIn('data-beacon-index="7"', output)
        self.assertNotIn('id="beacon-p-1"', output)
        self.assertEqual(manifest[0]["anchor"], "existing")
        self.assertEqual(manifest[0]["index"], 7)
        self.assertEqual(manifest[0]["text"], "Paragraph")

    def test_manifest_uses_existing_beacon_kind_and_index_consistently(self) -> None:
        html = (
            '<html><body><pre id="code" data-beacon-kind="code-block" '
            'data-beacon-index="9"><code>x</code></pre></body></html>'
        )

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('data-beacon-kind="code-block"', output)
        self.assertIn('data-beacon-index="9"', output)
        self.assertEqual(manifest[0]["anchor"], "code")
        self.assertEqual(manifest[0]["kind"], "code-block")
        self.assertEqual(manifest[0]["index"], 9)
        self.assertEqual(manifest[0]["text"], "x")

    def test_invalid_existing_beacon_index_is_replaced_with_generated_index(self) -> None:
        html = '<html><body><p data-beacon-index="bogus">Paragraph</p></body></html>'

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('data-beacon-index="1"', output)
        self.assertEqual(manifest[0]["index"], 1)
        self.assertEqual(manifest[0]["text"], "Paragraph")

    def test_partial_existing_beacon_kind_is_completed_with_generated_index(self) -> None:
        html = '<html><body><p data-beacon-kind="custom-paragraph">Paragraph</p></body></html>'

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('data-beacon-kind="custom-paragraph"', output)
        self.assertIn('data-beacon-index="1"', output)
        self.assertIn('id="beacon-p-1"', output)
        self.assertEqual(manifest[0]["kind"], "custom-paragraph")
        self.assertEqual(manifest[0]["index"], 1)
        self.assertEqual(manifest[0]["anchor"], "beacon-p-1")
        self.assertEqual(manifest[0]["text"], "Paragraph")

    def test_partial_existing_beacon_index_is_completed_with_generated_kind(self) -> None:
        html = '<html><body><li data-beacon-index="4">Item</li></body></html>'

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('data-beacon-kind="li"', output)
        self.assertIn('data-beacon-index="4"', output)
        self.assertIn('id="beacon-li-1"', output)
        self.assertEqual(manifest[0]["kind"], "li")
        self.assertEqual(manifest[0]["index"], 4)
        self.assertEqual(manifest[0]["anchor"], "beacon-li-1")
        self.assertEqual(manifest[0]["text"], "Item")

    def test_instruments_multiple_code_like_div_variants(self) -> None:
        html = (
            '<html><body>'
            '<div class="sourceCodeContainer"><pre><code>a</code></pre></div>'
            '<div class="listing extra"><pre><code>b</code></pre></div>'
            '</body></html>'
        )

        output, manifest = instrument_html(html, prefix="beacon")

        self.assertIn('id="beacon-div-1"', output)
        self.assertIn('id="beacon-div-2"', output)
        self.assertIn('id="beacon-pre-1"', output)
        self.assertIn('id="beacon-pre-2"', output)
        self.assertEqual(manifest[0]["kind"], "div")
        self.assertEqual(manifest[1]["kind"], "pre")
        self.assertEqual(manifest[2]["kind"], "div")
        self.assertEqual(manifest[3]["kind"], "pre")

    def test_injects_navigation_api_without_body_tag(self) -> None:
        html = '<div id="root"><h1>Title</h1></div>'
        output, manifest = instrument_html(html, prefix="beacon")

        with_api = inject_navigation_api(output, manifest)

        self.assertIn("window.BeaconPreview", with_api)
        self.assertTrue(with_api.rstrip().endswith("</script>"))
        self.assertIn('id="beacon-h1-1"', with_api)


if __name__ == "__main__":
    unittest.main()
