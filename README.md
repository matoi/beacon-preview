# beacon-preview

`beacon-preview` is a Pandoc-based preview workflow for Markdown that makes the
generated HTML easy to navigate from Emacs.

This file is the primary **user-facing** reference for setup, commands,
configuration, and the current stable contract expected by the repository.
If you need the actively evolving implementation status or next-session notes,
see `docs/markdown-preview-handoff.md`.

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

For day-to-day use, treat the setup and command descriptions in this README as
authoritative. Development-session priorities and open implementation questions
live in `docs/markdown-preview-handoff.md`.

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

Most behavior knobs are available from:

```elisp
M-x customize-group RET beacon-preview RET
```

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
target heading does not always land at the very top of the preview. When a
preview jump succeeds, the destination block is also lightly highlighted so it
is easier to visually reacquire after the scroll.

For a more block-oriented jump, use:

```elisp
(beacon-preview-jump-to-current-block)
```

This prefers the current fenced code block, blockquote, pipe table, list item,
or paragraph when one can be resolved through the manifest, and otherwise falls
back to the current heading.

By default, that same block/heading-following behavior is used during
save-triggered refresh, so editing in the middle of a document generally
reopens the preview near the current source block rather than always at the top
of the file. If you prefer live updates without moving the current preview
position, switch refresh behavior to `preserve` as described below.

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

If you want refresh to rebuild preview artifacts without moving the current
preview position, use:

```elisp
(setq beacon-preview-refresh-jump-behavior 'preserve)
```

In both refresh modes, save-triggered refresh may also lightly highlight
recently edited blocks that are still visible in the preview after reload. This
is intended as a visual cue only: off-screen edited blocks are ignored, and the
current scroll behavior still follows the selected refresh mode.

If you want live preview to follow source window display-position changes such
as paging, recentering, or other scroll-induced visible-region updates:

```elisp
(setq beacon-preview-follow-window-display-changes t)
```

This follow mode watches source window display changes rather than specific
commands, so it can react to a broader range of scrolling/recentering actions
when a live preview is already open.

For runtime toggles while working, these commands are available:

- `M-x beacon-preview-toggle-refresh-jump-behavior`
- `M-x beacon-preview-toggle-follow-window-display-changes`
- `M-x beacon-preview-toggle-debug`

If you want `beacon-preview-mode` to open the preview automatically when enabled
in a Markdown buffer:

```elisp
(setq beacon-preview-auto-start-on-enable t)
```

By default this is disabled, so opening a `.md` file does not automatically
start preview unless you opt in.

## Useful Commands

- `M-x beacon-preview-mode`
- `M-x beacon-preview-build-and-open`
- `M-x beacon-preview-build-and-refresh`
- `M-x beacon-preview-switch-to-preview`
- `M-x beacon-preview-jump-to-current-heading`
- `M-x beacon-preview-jump-to-current-block`
- `M-x beacon-preview-jump-to-anchor`
- `M-x beacon-preview-reload`
- `M-x beacon-preview-toggle-refresh-jump-behavior`
- `M-x beacon-preview-toggle-follow-window-display-changes`
- `M-x beacon-preview-toggle-debug`

## Key Bindings

`beacon-preview-mode` installs these buffer-local bindings:

- `C-c C-b o` for `beacon-preview-build-and-open`
- `C-c C-b r` for `beacon-preview-build-and-refresh`
- `C-c C-b j` for `beacon-preview-jump-to-current-heading`
- `C-c C-b b` for `beacon-preview-jump-to-current-block`
- `C-c C-b a` for `beacon-preview-jump-to-anchor`
- `C-c C-b f` for `beacon-preview-toggle-refresh-jump-behavior`
- `C-c C-b w` for `beacon-preview-toggle-follow-window-display-changes`
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
- `flashAnchor(anchor)`
- `flashAnchorIfVisible(anchor)`
- `isElementVisible(element)`

## Manifest Contract

The current backend-facing contract is intentionally simple: a builder produces
preview HTML plus a manifest JSON file that describes useful preview jump
targets.

Each manifest entry currently uses these fields:

- `kind`: block/heading kind such as `h1`, `p`, `li`, `blockquote`, `pre`, `table`, or `div`
- `index`: 1-based occurrence count within that `kind`
- `anchor`: the HTML `id` used for preview jumps
- `text`: optional human-readable text extracted from the instrumented HTML

Additional fields may appear, but Emacs currently relies mainly on `kind`,
`index`, `anchor`, and, for heading matching, `text`.

Important contract details:

- `anchor` must refer to a real HTML element id in the generated preview
- `index` is scoped within a `kind`, not globally across the manifest
- existing HTML ids may be preserved instead of generating `beacon-*` ids
- if input HTML already contains `data-beacon-kind` and/or `data-beacon-index`,
  the instrumented HTML and emitted manifest stay aligned with those values when
  they are usable; missing pieces may be filled in with generated defaults
- `text` is optional, but when extractable from the instrumented HTML it is
  included so editor-side matching can prefer manifest-backed resolution
- builders may choose how they generate the HTML, as long as they emit HTML and
  a manifest that follow this contract

When manifest entries are missing or disagree with the current source buffer,
Emacs falls back rather than failing hard:

- heading lookup falls back to a Pandoc-like slug derived from source text
- current block jumps fall back to the current heading anchor when no matching
  block entry is available

## Current Block Resolution

`beacon-preview-jump-to-current-block` and refresh reopen logic currently prefer
these source-side targets in this order:

1. fenced code block → `pre`
2. blockquote → `blockquote`
3. pipe table → `table`
4. list item → `li`
5. paragraph → `p`
6. fallback to current heading

This is intentionally source-side heuristic matching rather than exact source
maps. The current implementation aims for useful block-level preview jumps while
keeping setup light and save-based.

## Command-Line Usage

Build preview artifacts from Markdown in one step:

```bash
python3 scripts/build_preview.py \
  --input examples/sample.md \
  --output-dir /tmp/beacon-preview
```

On success, `build_preview.py` writes exactly two lines to stdout: the absolute
HTML artifact path first, then the absolute manifest path. It also verifies
that both artifacts were created before reporting success.

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
