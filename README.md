# beacon-preview

`beacon-preview` is a Pandoc-based preview workflow for Markdown and Org that
makes generated HTML easy to navigate from Emacs.

It focuses on:

- generating local HTML artifacts with Pandoc
- adding beacon markers to headings and block-level elements
- resolving source-side blocks structurally instead of by line-by-line fallback scans
- opening the result in Emacs xwidget
- jumping or flashing the preview at useful locations from the source buffer

## Requirements

`beacon-preview` works best when these pieces are already available:

- Emacs with xwidgets support
- Emacs built with libxml support
- a graphical Emacs session
- Pandoc installed and available in `PATH`, or configured explicitly from Emacs
- for Markdown source-side sync: Emacs `treesit` support with the `markdown` grammar available
- for Org source-side sync: `org-element` support

Markdown source-side block detection assumes a working tree-sitter Markdown
grammar.

For Markdown source-side sync, use tree-sitter Markdown library builds that
include the fix from
[emacs-tree-sitter/tree-sitter-langs#1449](https://github.com/emacs-tree-sitter/tree-sitter-langs/issues/1449).

## Installation

Until this package is published on MELPA, install it directly from the
repository with `package-vc`:

```elisp
(package-vc-install "https://github.com/matoi/beacon-preview")
```

If you use `use-package`, a minimal repository-based setup looks like:

```elisp
(use-package beacon-preview
  :vc (:url "https://github.com/matoi/beacon-preview")
  :hook ((markdown-mode . beacon-preview-mode)
         (gfm-mode . beacon-preview-mode)
         (markdown-ts-mode . beacon-preview-mode)
         (org-mode . beacon-preview-mode)))
```

For a local checkout, add the `lisp/` directory to `load-path` and require the
package:

```elisp
(add-to-list 'load-path "/path/to/beacon-preview/lisp")
(require 'beacon-preview)
```

## Main Files

- [lisp/beacon-preview.el](lisp/beacon-preview.el) — the package; the entire
  runtime (Pandoc invocation, libxml DOM instrumentation, xwidget control)
  lives here.

## Quick Start

After installing the package:

1. Enable `beacon-preview-mode` in Markdown and/or Org buffers.
2. Open a `.md` or `.org` file.
3. Run `M-x beacon-preview-dwim`.

That first `beacon-preview-dwim` call builds the HTML preview and opens it in
an xwidget buffer. Later calls jump the live preview to the current source
block or heading.

## Emacs Setup

Enable the mode for Markdown and Org buffers:

```elisp
(add-hook 'markdown-mode-hook #'beacon-preview-mode)
(add-hook 'gfm-mode-hook #'beacon-preview-mode)
(add-hook 'markdown-ts-mode-hook #'beacon-preview-mode)
(add-hook 'org-mode-hook #'beacon-preview-mode)
```

If you want a ready-to-paste `init.el` example, start with:

```elisp
(use-package beacon-preview
  :vc (:url "https://github.com/matoi/beacon-preview")
  :hook ((markdown-mode . beacon-preview-mode)
         (gfm-mode . beacon-preview-mode)
         (markdown-ts-mode . beacon-preview-mode)
         (org-mode . beacon-preview-mode))
  :custom
  (beacon-preview-behavior-style 'default)
  (beacon-preview-display-location 'side-window))
```

A slightly more opinionated example for daily use might look like:

```elisp
(use-package beacon-preview
  :vc (:url "https://github.com/matoi/beacon-preview")
  :hook ((markdown-mode . beacon-preview-mode)
         (gfm-mode . beacon-preview-mode)
         (markdown-ts-mode . beacon-preview-mode)
         (org-mode . beacon-preview-mode))
  :bind
  (:map beacon-preview-mode-map
        ("C-c C-b o" . beacon-preview-dwim)
        ("C-c C-b t" . beacon-preview-toggle-preview-display)
        ("C-c C-b p" . beacon-preview-sync-source-to-preview))
  :custom
  (beacon-preview-behavior-style 'default)
  (beacon-preview-display-location 'side-window)
  (beacon-preview-auto-start-on-enable nil)
  (beacon-preview-pandoc-command "pandoc"))
```

If Emacs cannot find the right Pandoc binary through `PATH`, set it explicitly:

```elisp
(setq beacon-preview-pandoc-command "/opt/homebrew/bin/pandoc")
```

Optional styling/runtime enhancements can be layered on without changing the
basic preview pipeline:

```elisp
(setq beacon-preview-pandoc-css-files
      '("/path/to/github-markdown.css"))
(setq beacon-preview-body-wrapper-class "markdown-body")
(setq beacon-preview-mermaid-script-file
      "/path/to/mermaid.js")
```

These settings are all optional:

- `beacon-preview-pandoc-css-files` appends `--css` arguments for existing CSS files
- `beacon-preview-body-wrapper-class` wraps preview body content in one
  `article` element so wrapper-scoped CSS can apply cleanly
- `beacon-preview-mermaid-script-file` injects a local Mermaid runtime when present
- no custom Pandoc template is required for this CSS + wrapper path

If any of those files are absent, preview builds still succeed and fall back to
plain Pandoc HTML or untranslated Mermaid source blocks.

If you want simple defaults for all Markdown buffers versus all Org buffers,
use `beacon-preview-build-settings-by-source-kind`:

```elisp
(setq beacon-preview-build-settings-by-source-kind
      '((markdown
         :pandoc-css-files ("/path/to/github-markdown.css")
         :body-wrapper-class "markdown-body"
         :mermaid-script-file "/path/to/node_modules/mermaid/dist/mermaid.js")
        (org
         :pandoc-css-files ("/path/to/org-preview.css"))))
```

If you also want true mode-specific overrides, layer
`beacon-preview-build-settings-by-major-mode` on top:

```elisp
(setq beacon-preview-build-settings-by-major-mode
      '((gfm-mode
         :mermaid-script-file "/path/to/mermaid.js")
        (markdown-ts-mode
         :pandoc-template-file "/path/to/custom.html5")))
```

The precedence is:

1. buffer-local individual variables
2. buffer-local `beacon-preview-build-settings`
3. `beacon-preview-build-settings-by-major-mode`
4. `beacon-preview-build-settings-by-source-kind`
5. global individual variables and global `beacon-preview-build-settings`

That lets you keep one shared Markdown baseline while still overriding specific
major modes when needed.

One concrete setup might look like:

```elisp
(setq beacon-preview-pandoc-css-files
      '("/path/to/github-markdown-css/github-markdown.css"))
(setq beacon-preview-body-wrapper-class "markdown-body")
(setq beacon-preview-mermaid-script-file
      "/path/to/node_modules/mermaid/dist/mermaid.js")
```

For a quick manual check after enabling those options, open either:

```text
examples/mermaid-preview-sample.md
examples/mermaid-preview-sample.org
```

and run `M-x beacon-preview-dwim`.

These build settings also work well as buffer-local, file-local, or
directory-local values, so Markdown and Org files can use different preview
assets without changing your global defaults.  More specific scopes override
broader defaults: local overrides beat major-mode defaults, which beat
source-kind defaults, which beat global defaults. For example:

```elisp
;; In a hook or with `setq-local'
(setq-local beacon-preview-pandoc-css-files
            '("/path/to/project-preview.css"))
(setq-local beacon-preview-body-wrapper-class "markdown-body")
```

or in file-local variables:

```text
<!-- Local Variables:
beacon-preview-pandoc-css-files: ("/path/to/project-preview.css")
beacon-preview-body-wrapper-class: "markdown-body"
End: -->
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

- when no preview exists, it builds artifacts asynchronously and opens the preview
- when a preview is already live and visible, it jumps to the current source block
- when a preview is already live but hidden, it foregrounds that preview without changing its current position
- when a live preview is stale, it rebuilds first and then continues with the same source-driven behavior

The jump prefers the nearest block-level element (code block, blockquote,
table, list item, or paragraph) and falls back to the current heading. It also
tries to roughly preserve point's vertical position inside the source window.

For source-side block matching, Markdown uses cached tree-sitter entries and
Org uses cached `org-element` entries. This keeps kind/index lookup aligned
with the processed preview HTML block cache without rescanning the buffer from
the top on every sync step.

If you only want to show the tracked preview without syncing it to the current
source location, use:

```elisp
(beacon-preview-switch-to-preview)
```

This refreshes a stale live preview before showing it, but does not move the
preview to the current source block.

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

This command shows the tracked preview and then moves the source buffer to the
preview session's current position. If the preview is stale, it is rebuilt
first while preserving the preview's current scroll position so reverse sync
still reflects the preview location you were using. That source jump also
pushes the previous location onto the mark stack, so you can return with
`C-u C-SPC`.

Reverse sync is driven from the top of the preview viewport rather than the
viewport center. When a block start is visible, that topmost visible block
becomes the sync target. When the viewport is already inside a long block,
preview-side `block_progress` is sent back so the source buffer can move to an
approximate position within the same block instead of jumping to a nearby but
wrong block.

By default, that same block/heading-following behavior is used during
save-triggered refresh, so editing in the middle of a document generally
reopens the preview near the current source block rather than always at the top
of the file. If you prefer live updates without moving the current preview
position, switch refresh behavior to `preserve` as described below.

## Automatic Refresh

When `beacon-preview-mode` is enabled, saving the buffer rebuilds preview
artifacts and refreshes the tracked preview automatically. Builds run
asynchronously, so Emacs stays responsive during Pandoc invocation. If a
new save arrives while a build is still running, the in-flight build is
superseded.

When a build takes longer than `beacon-preview-slow-build-message-threshold`
(default 0.5 seconds), the elapsed time is shown in the echo area.

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

### Customizing the flash highlight

The yellow flash shown when jumping or syncing to a preview target can be
restyled with `beacon-preview-flash-style`:

```elisp
(beacon-preview-apply-flash-style 'dark)
```

Built-in presets are `default` (yellow), `light` (amber for light backgrounds),
`dark` (cyan for dark themes), and `none` (disables flashing).

For finer control, set any of the per-property variables in the
`beacon-preview-flash` customize group (`beacon-preview-flash-subtle-color`,
`beacon-preview-flash-strong-duration-ms`, etc.); changing one updates
`beacon-preview-flash-style` to a matching preset symbol or normalized plist.

You can also register your own named presets:

```elisp
(setq beacon-preview-flash-style-user-presets
      '((solarized
         :subtle-color "rgba(181, 137, 0, 0.18)"
         :strong-color "rgba(181, 137, 0, 0.32)"
         :strong-outline-color "rgba(181, 137, 0, 0.4)")))
(beacon-preview-apply-flash-style 'solarized)
```

Missing keys in a user preset (or in an inline plist value of
`beacon-preview-flash-style`) inherit from the built-in `default` preset. The
flash style is baked into the injected preview script at render time, so
existing previews need to be rebuilt for changes to take effect.

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
| Coordinated flash highlight preset | `beacon-preview-flash-style` | `M-x beacon-preview-apply-flash-style` |
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
- `M-x beacon-preview-flash-current-target` - highlight the current source-correlated preview target without scrolling
- `M-x beacon-preview-sync-source-to-preview` - move the source buffer to the block currently visible in the preview
- `M-x beacon-preview-toggle-preview-display` - show or hide the tracked preview, starting one if needed
- `M-x beacon-preview-switch-to-preview` - jump to the tracked preview, starting one if needed
- `M-x beacon-preview-jump-to-anchor` - jump the preview to a specific anchor name
- `M-x beacon-preview-reload` - reload the current preview page in xwidget
- `M-x beacon-preview-apply-behavior-style` - apply a named bundle of preview-follow settings
- `M-x beacon-preview-toggle-refresh-jump-behavior` - switch between block-following and preserving preview position
- `M-x beacon-preview-toggle-follow-window-display-changes` - toggle live preview following for source scrolling/recentering
- `M-x beacon-preview-toggle-reveal-hidden-preview-window` - toggle whether source-driven refresh may re-show a hidden preview

## Key Bindings

`beacon-preview-mode` installs these buffer-local bindings:

- `C-c C-b o` for `beacon-preview-dwim`
- `C-c C-b h` for `beacon-preview-flash-current-target`
- `C-c C-b p` for `beacon-preview-sync-source-to-preview`
- `C-c C-b t` for `beacon-preview-toggle-preview-display`
- `C-c C-b a` for `beacon-preview-jump-to-anchor`
- `C-c C-b s` for `beacon-preview-apply-behavior-style`
- `C-c C-b f` for `beacon-preview-toggle-refresh-jump-behavior`
- `C-c C-b w` for `beacon-preview-toggle-follow-window-display-changes`
- `C-c C-b v` for `beacon-preview-toggle-reveal-hidden-preview-window`
