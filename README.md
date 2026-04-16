# beacon-preview

`beacon-preview` is a Pandoc-based preview workflow for Markdown and Org that
makes generated HTML easy to navigate from Emacs.

It focuses on:

- generating local HTML artifacts with Pandoc
- adding beacon markers to headings and block-level elements
- opening the result in Emacs xwidget
- jumping or flashing the preview at useful locations from the source buffer

## Requirements

- Emacs with xwidgets support
- a graphical Emacs session
- Pandoc available in `PATH`, or configured explicitly from Emacs
- Python 3

## Installation

Until this package is published on MELPA, install it directly from the
repository with `package-vc`:

```elisp
(package-vc-install "https://github.com/matoi/beacon-preview")
```

For a local checkout, add the `lisp/` directory to `load-path` and require the
package:

```elisp
(add-to-list 'load-path "/path/to/beacon-preview/lisp")
(require 'beacon-preview)
```

## Main Files

- [lisp/beacon-preview.el](lisp/beacon-preview.el)
- [scripts/build_preview.py](scripts/build_preview.py)
- [scripts/beaconify_html.py](scripts/beaconify_html.py)

## Emacs Setup

Enable the mode for Markdown and Org buffers:

```elisp
(add-hook 'markdown-mode-hook #'beacon-preview-mode)
(add-hook 'gfm-mode-hook #'beacon-preview-mode)
(add-hook 'org-mode-hook #'beacon-preview-mode)
```

If you want a ready-to-paste `init.el` example, start with:

```elisp
(use-package beacon-preview
  :vc (:url "https://github.com/matoi/beacon-preview")
  :hook ((markdown-mode . beacon-preview-mode)
         (gfm-mode . beacon-preview-mode)
         (org-mode . beacon-preview-mode))
  :custom
  (beacon-preview-behavior-style 'default)
  (beacon-preview-python-command "python3")
  (beacon-preview-display-location 'side-window))
```

A slightly more opinionated example for daily use might look like:

```elisp
(use-package beacon-preview
  :vc (:url "https://github.com/matoi/beacon-preview")
  :hook ((markdown-mode . beacon-preview-mode)
         (gfm-mode . beacon-preview-mode)
         (org-mode . beacon-preview-mode))
  :bind
  (:map beacon-preview-mode-map
        ("C-c b o" . beacon-preview-dwim)
        ("C-c b t" . beacon-preview-toggle-preview-display)
        ("C-c b p" . beacon-preview-sync-source-to-preview))
  :custom
  (beacon-preview-behavior-style 'default)
  (beacon-preview-display-location 'side-window)
  (beacon-preview-auto-start-on-enable nil)
  (beacon-preview-python-command "python3")
  (beacon-preview-pandoc-command "pandoc"))
```

If Emacs cannot find the right Pandoc binary through `PATH`, set it explicitly:

```elisp
(setq beacon-preview-pandoc-command "/opt/homebrew/bin/pandoc")
```

Likewise, if you need a specific Python executable, set:

```elisp
(setq beacon-preview-python-command "/path/to/python3")
```

Most behavior knobs are available from:

```elisp
M-x customize-group RET beacon-preview RET
```

They are grouped under **Build**, **Automation**, **Navigation**, **Display**,
and **Debugging** subgroups.

## Basic Workflow

Open a Markdown or Org buffer and run:

```elisp
(beacon-preview-dwim)
```

This single command handles the entire preview lifecycle:

- when no preview exists, it builds artifacts and opens the preview
- when a preview is already live, it jumps to the current source block

The jump prefers the nearest block-level element (code block, blockquote,
table, list item, or paragraph) and falls back to the current heading. It also
tries to roughly preserve point's vertical position inside the source window.

If you only want to visually reacquire the current resolved target without
scrolling the preview, use:

```elisp
(beacon-preview-flash-current-target)
```

If you want to pull the source buffer toward the block currently visible in the
preview, use:

```elisp
(beacon-preview-sync-source-to-preview)
```

That source jump also pushes the previous location onto the mark stack, so you
can return with `C-u C-SPC`.

By default, that same block/heading-following behavior is used during
save-triggered refresh, so editing in the middle of a document generally
reopens the preview near the current source block rather than always at the top
of the file. If you prefer live updates without moving the current preview
position, switch refresh behavior to `preserve` as described below.

## Automatic Refresh

When `beacon-preview-mode` is enabled, saving the buffer rebuilds preview
artifacts and refreshes the tracked preview automatically.

By default, these source-driven refreshes do **not** reclaim a preview side
window that is currently showing some other buffer. This avoids unexpectedly
pulling the preview back to the foreground when you intentionally reused that
window for another task. If you want source-driven updates to reveal that
hidden preview window again, enable:

```elisp
(setq beacon-preview-reveal-hidden-preview-window t)
```

If you prefer the preview in its own frame instead of a side window, use:

```elisp
(setq beacon-preview-display-location 'dedicated-frame)
```

If you want all previews to share one dedicated frame instead:

```elisp
(setq beacon-preview-display-location 'shared-dedicated-frame)
```

Use `dedicated-frame` when each source buffer should keep its own preview frame,
or `shared-dedicated-frame` when all previews should rotate through one
dedicated frame.

If you want to coordinate the main preview-follow settings together, use a
behavior style instead of setting the individual variables one by one:

```elisp
(beacon-preview-apply-behavior-style 'default)
```

Available named styles are:

- `default` - refresh follows the current block, without live display-follow or hidden-preview reveal
- `live` - `default` plus live following for source window scrolling/recentering
- `visible` - `default` plus automatic re-reveal of a hidden preview display during source-driven updates
- `live-visible` - combines both live display-follow and hidden-preview reveal
- `preserve` - refresh rebuilds while preserving the current preview scroll position

You can also use a custom style plist when you want one explicit bundle:

```elisp
(beacon-preview-apply-behavior-style
 '(:refresh-jump-behavior preserve
   :follow-window-display-changes t
   :reveal-hidden-preview-window nil))
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

For the settings most likely to be adjusted while working:

Runtime commands below update the **current source buffer** only. Use Customize
or your init file for persistent global defaults.

| Concern | Persistent variable | Runtime command |
| --- | --- | --- |
| Preview opens in side window, per-preview frame, or shared frame | `beacon-preview-display-location` | — |
| Coordinated behavior preset | `beacon-preview-behavior-style` | `M-x beacon-preview-apply-behavior-style` |
| Refresh follows current source block vs preserves preview scroll | `beacon-preview-refresh-jump-behavior` | `M-x beacon-preview-toggle-refresh-jump-behavior` |
| Live preview follows source window scrolling/recentering | `beacon-preview-follow-window-display-changes` | `M-x beacon-preview-toggle-follow-window-display-changes` |
| Source-driven refresh may reveal a hidden preview window | `beacon-preview-reveal-hidden-preview-window` | `M-x beacon-preview-toggle-reveal-hidden-preview-window` |

If you want `beacon-preview-mode` to open the preview automatically when enabled
in a supported source buffer:

```elisp
(setq beacon-preview-auto-start-on-enable t)
```

By default this is disabled, so opening a `.md` or `.org` file does not
automatically start preview unless you opt in.

## Preview Buffers

Preview buffers are renamed to follow the current source buffer name, so any
buffer naming you already use for disambiguation is carried over to the
preview too. For example:

```text
*beacon-preview: notes.md<docs>*
```

If the source buffer is later renamed, the tracked preview buffer name follows
that rename as well.

Use:

```elisp
(beacon-preview-switch-to-preview)
```
to jump back to the tracked preview for the current source buffer. If the
current source buffer does not have a live preview yet, this command starts one
first.

Use:

```elisp
(beacon-preview-toggle-preview-display)
```
to toggle that preview display between shown and hidden. If the current source
buffer does not have a live preview yet, this command starts one first.

## Useful Commands

- `M-x beacon-preview-mode` - enable or disable the minor mode in the current source buffer
- `M-x beacon-preview-dwim` - open or jump the preview for the current source buffer
- `M-x beacon-preview-switch-to-preview` - jump to the tracked preview, starting one if needed
- `M-x beacon-preview-toggle-preview-display` - show or hide the tracked preview, starting one if needed
- `M-x beacon-preview-jump-to-anchor` - jump the preview to a specific anchor name
- `M-x beacon-preview-flash-current-target` - highlight the current source-correlated preview target without scrolling
- `M-x beacon-preview-sync-source-to-preview` - move the source buffer to the block currently visible in the preview
- `M-x beacon-preview-reload` - reload the current preview page in xwidget
- `M-x beacon-preview-toggle-refresh-jump-behavior` - switch between block-following and preserving preview position
- `M-x beacon-preview-toggle-follow-window-display-changes` - toggle live preview following for source scrolling/recentering
- `M-x beacon-preview-toggle-reveal-hidden-preview-window` - toggle whether source-driven refresh may re-show a hidden preview
- `M-x beacon-preview-apply-behavior-style` - apply a named bundle of preview-follow settings

## Key Bindings

`beacon-preview-mode` installs these buffer-local bindings:

- `C-c C-b o` for `beacon-preview-dwim`
- `C-c C-b s` for `beacon-preview-apply-behavior-style`
- `C-c C-b t` for `beacon-preview-toggle-preview-display`
- `C-c C-b p` for `beacon-preview-sync-source-to-preview`
- `C-c C-b a` for `beacon-preview-jump-to-anchor`
- `C-c C-b h` for `beacon-preview-flash-current-target`
- `C-c C-b f` for `beacon-preview-toggle-refresh-jump-behavior`
- `C-c C-b w` for `beacon-preview-toggle-follow-window-display-changes`
- `C-c C-b v` for `beacon-preview-toggle-reveal-hidden-preview-window`
