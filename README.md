# beacon-preview

`beacon-preview` is a Pandoc-based preview workflow for Markdown that makes the
generated HTML easy to navigate from Emacs.

It focuses on:

- generating local HTML artifacts with Pandoc
- adding beacon markers to headings and block-level elements
- opening the result in Emacs xwidget
- jumping the preview to useful locations from the source buffer

## Requirements

- Emacs with xwidgets support
- a graphical Emacs session
- Pandoc available in `PATH`, or configured explicitly from Emacs
- Python 3

## Main Files

- [lisp/beacon-preview.el](/Users/matoi/Development/beacon-preview/lisp/beacon-preview.el)
- [scripts/build_preview.py](/Users/matoi/Development/beacon-preview/scripts/build_preview.py)
- [scripts/beaconify_html.py](/Users/matoi/Development/beacon-preview/scripts/beaconify_html.py)

## Emacs Setup

Load the mode and enable it for Markdown buffers:

```elisp
(load-file "/Users/matoi/Development/beacon-preview/lisp/beacon-preview.el")
(add-hook 'markdown-mode-hook #'beacon-preview-mode)
(add-hook 'gfm-mode-hook #'beacon-preview-mode)
```

`beacon-preview` is intentionally xwidget-only. If Emacs was built without
xwidgets, or if you run it outside a graphical session, preview commands fail
with an explanatory error instead of a low-level `void-function` style error.

If Emacs cannot find the right Pandoc binary through `PATH`, set it explicitly:

```elisp
(setq beacon-preview-pandoc-command "/opt/homebrew/bin/pandoc")
```

The preview builder script is discovered relative to `beacon-preview.el` by
default, so a checkout-specific absolute path is no longer required.

## Basic Workflow

Open a Markdown buffer and run:

```elisp
(beacon-preview-build-and-open)
```

This will:

- generate preview HTML from the current file
- write preview artifacts into an internal temporary directory
- open the generated HTML in xwidget
- track the preview buffer for the current source buffer

If no preview exists yet, this command creates one. If a tracked preview already
exists for the source buffer, later refreshes reuse it.

After that, use:

```elisp
(beacon-preview-jump-to-current-heading)
```

to move the preview to the current Markdown heading. The jump also tries to
roughly preserve point's vertical position inside the source window, so the
target heading does not always land at the very top of the preview.

That same heading-following behavior is used during save-triggered refresh, so
editing in the middle of a document generally reopens the preview near the
current heading rather than at the top of the file.

## Automatic Refresh

When `beacon-preview-mode` is enabled, saving the buffer rebuilds preview
artifacts and refreshes the tracked preview automatically.

If you want to refresh manually, use:

```elisp
(beacon-preview-build-and-refresh)
```

If you prefer jumps without that window-position offset, disable it with:

```elisp
(setq beacon-preview-follow-window-position nil)
```

If you prefer manual refresh only:

```elisp
(setq beacon-preview-auto-refresh-on-save nil)
```

## Useful Commands

- `M-x beacon-preview-mode`
- `M-x beacon-preview-build-and-open`
- `M-x beacon-preview-build-and-refresh`
- `M-x beacon-preview-switch-to-preview`
- `M-x beacon-preview-jump-to-current-heading`
- `M-x beacon-preview-jump-to-anchor`
- `M-x beacon-preview-reload`
- `M-x beacon-preview-toggle-debug`

## Key Bindings

`beacon-preview-mode` installs these buffer-local bindings:

- `C-c C-b o` for `beacon-preview-build-and-open`
- `C-c C-b r` for `beacon-preview-build-and-refresh`
- `C-c C-b j` for `beacon-preview-jump-to-current-heading`
- `C-c C-b a` for `beacon-preview-jump-to-anchor`
- `C-c C-b d` for `beacon-preview-toggle-debug`

## Preview Buffers

Preview buffers are renamed to include the source filename, for example:

```text
*beacon-preview: notes.md*
```

Use:

```elisp
(beacon-preview-switch-to-preview)
```

to jump back to the tracked preview for the current source buffer.

## HTML Pipeline

The generated preview HTML contains:

- `id` attributes usable as anchor targets
- `data-beacon-kind`
- `data-beacon-index`
- manifest metadata for editor-side lookup
- a browser-side `window.BeaconPreview` API

That browser-side API exposes:

- `manifest`
- `findByAnchor(anchor)`
- `findByIndex(kind, index)`
- `jumpToAnchor(anchor)`
- `jumpToIndex(kind, index)`

## Command-Line Usage

Build preview artifacts from Markdown in one step:

```bash
python3 scripts/build_preview.py \
  --input examples/sample.md \
  --output-dir /tmp/beacon-preview
```

Transform an existing HTML file directly:

```bash
python3 scripts/beaconify_html.py \
  --input examples/sample-pandoc.html \
  --output /tmp/sample-beacon.html \
  --manifest-output /tmp/sample-beacon.json \
  --inject-navigation-api
```

## Notes

- Preview artifacts live under an internal temporary directory during Emacs use.
- The temporary artifact directory is derived from the source file path, so the
  user does not have to manage output locations manually.
- Manifest-backed heading resolution is stronger than manifest-free fallback.
- Fallback heading matching is designed to be close to Pandoc heading ids.
- Build failures try to explain whether `python`, `pandoc`, or the generated
  manifest was the immediate problem.
