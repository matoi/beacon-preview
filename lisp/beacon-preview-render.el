;;; beacon-preview-render.el --- Rendering and parsing helpers for beacon-preview -*- lexical-binding: t; -*-

;; Author: matoi
;; Maintainer: matoi
;; URL: https://github.com/matoi/beacon-preview
;; Keywords: hypermedia, tools, convenience
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; This file holds the pure-ish rendering, parsing, and position/anchor
;; helpers used by beacon-preview.  It is loaded by `beacon-preview.el' and
;; has no user-facing entry points of its own.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'url)
(require 'xml)
(require 'org-element)
(require 'url-util)

;; Forward declarations for customs/state defined in `beacon-preview.el'.
(defvar beacon-preview-flash-style)
(defvar beacon-preview-flash-enabled)
(defvar beacon-preview-flash-subtle-color)
(defvar beacon-preview-flash-subtle-peak-color)
(defvar beacon-preview-flash-subtle-duration-ms)
(defvar beacon-preview-flash-strong-color)
(defvar beacon-preview-flash-strong-peak-color)
(defvar beacon-preview-flash-strong-outline-color)
(defvar beacon-preview-flash-strong-outline-peak-color)
(defvar beacon-preview-flash-strong-outline-width-px)
(defvar beacon-preview-flash-strong-duration-ms)
(defvar beacon-preview-flash-border-radius)
(defvar beacon-preview-flash-easing)
(defvar beacon-preview-jump-retry-count)
(defvar beacon-preview-jump-retry-delay-ms)
(defvar beacon-preview-build-settings)
(defvar beacon-preview-build-settings-by-source-kind)
(defvar beacon-preview-build-settings-by-major-mode)
(defvar beacon-preview-pandoc-template-file)
(defvar beacon-preview-pandoc-css-files)
(defvar beacon-preview-mermaid-script-file)
(defvar beacon-preview-mathjax-script-file)
(defvar beacon-preview-body-wrapper-class)
(defvar beacon-preview-refresh-jump-behavior)
(defvar beacon-preview--preview-entries)
(defvar beacon-preview--markdown-treesit-cache)
(defvar beacon-preview--markdown-treesit-cache-tick)
(defvar beacon-preview--org-element-cache)
(defvar beacon-preview--org-element-cache-tick)
(defvar beacon-preview--external-link-sentinel-prefix)
(defvar beacon-preview--preview-html-cache)
(defvar beacon-preview--edited-positions)

(declare-function beacon-preview--debug "beacon-preview")
(declare-function beacon-preview--markdown-source-mode-p "beacon-preview")
(declare-function beacon-preview--supported-source-mode-p "beacon-preview")
(declare-function beacon-preview--source-kind "beacon-preview")
(declare-function beacon-preview--pandoc-input-format "beacon-preview")
(declare-function beacon-preview--build-settings-plist-p "beacon-preview")
(declare-function beacon-preview--flash-style-spec "beacon-preview")

(defun beacon-preview--file-url (file)
  "Return a file:// URL for FILE."
  (concat "file://" (expand-file-name file)))

(defun beacon-preview--current-anchor-maybe ()
  "Return the current source-correlated anchor
when source-side lookup is applicable.

This prefers a more specific block anchor near point, including boundary
positions that should resolve to the preceding block, and otherwise falls back
to heading-based navigation."
  (when (beacon-preview--supported-source-mode-p)
    (ignore-errors
      (or (beacon-preview--nearest-block-anchor-at-pos (point))
          (beacon-preview-current-heading-anchor)))))

(defun beacon-preview--external-link-interceptor-script ()
  "Return JS that redirects outbound link clicks through the sentinel data URL."
  (format
   (concat
    "(function () {"
    "  if (window.__beaconPreviewLinkInterceptorInstalled__) { return; }"
    "  window.__beaconPreviewLinkInterceptorInstalled__ = true;"
    "  var sentinel = %S;"
    "  document.addEventListener('click', function (event) {"
    "    if (event.defaultPrevented) { return; }"
    "    if (event.button !== 0) { return; }"
    "    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) { return; }"
    "    var node = event.target;"
    "    while (node && node.nodeType === 1 && node.tagName !== 'A') {"
    "      node = node.parentNode;"
    "    }"
    "    if (!node || node.tagName !== 'A') { return; }"
    "    if (!node.getAttribute('href')) { return; }"
    "    var resolved;"
    "    try { resolved = new URL(node.href, window.location.href); }"
    "    catch (_err) { return; }"
    "    var here = window.location;"
    "    var samePage = resolved.origin === here.origin"
    "      && resolved.pathname === here.pathname"
    "      && resolved.protocol === here.protocol;"
    "    if (samePage) { return; }"
    "    event.preventDefault();"
    "    event.stopPropagation();"
    "    window.location.href = sentinel + encodeURIComponent(resolved.href);"
    "  }, true);"
    "})();")
   beacon-preview--external-link-sentinel-prefix))

(defun beacon-preview--preview-url (file &optional anchor)
  "Return a preview URL for FILE, optionally targeting ANCHOR."
  (concat (beacon-preview--file-url file)
          (if (and anchor (not (string-empty-p anchor)))
              (concat "#" (url-hexify-string anchor))
            "")))

(defun beacon-preview--external-link-from-uri (uri)
  "Return the outbound URL encoded in URI's sentinel prefix, or nil."
  (when (and (stringp uri)
             (string-prefix-p beacon-preview--external-link-sentinel-prefix uri))
    (ignore-errors
      (url-unhex-string
       (substring uri (length beacon-preview--external-link-sentinel-prefix))))))
(defun beacon-preview--clamp-ratio (ratio)
  "Clamp RATIO to the inclusive [0.0, 1.0] range."
  (min 1.0
       (max 0.0 (float ratio))))

(defun beacon-preview--recenter-window-to-ratio (window ratio)
  "Recenter WINDOW so point appears at approximately RATIO of the window height."
  (let* ((body-lines (max 1 (window-body-height window)))
         (target-line (truncate (* (beacon-preview--clamp-ratio ratio)
                                   (1- body-lines)))))
    (with-selected-window window
      (recenter target-line))))

(defun beacon-preview--align-window-to-center (window)
  "Show point near the vertical center of WINDOW."
  (with-selected-window window
    (recenter)))

(defun beacon-preview--move-point-to-window-center (window)
  "Move point in WINDOW to the line at the window's vertical center.

Leaves `window-start' unchanged so the surrounding content stays in place."
  (with-selected-window window
    (let* ((start (window-start window))
           (body-lines (max 1 (window-body-height window)))
           (center-offset (/ body-lines 2))
           (target (save-excursion
                     (goto-char start)
                     (forward-line center-offset)
                     (line-beginning-position))))
      (goto-char target)
      (set-window-point window target))))

(defun beacon-preview--window-line-ratio (&optional window position)
  "Return POSITION's approximate vertical ratio within WINDOW.

The value is clamped to the `[0.0, 1.0]' range."
  (let* ((window (or window (selected-window)))
         (start (window-start window))
         (position (or position (point)))
         (window-lines (max 1 (window-body-height window t)))
         (visible-index
          (max 0
               (1- (count-screen-lines start position nil window)))))
    (min 1.0
         (max 0.0
              (/ (float visible-index)
                 (float window-lines))))))

(defun beacon-preview--window-pixel-y-for-pos (&optional window position)
  "Return POSITION's Y pixel coordinate within WINDOW, or nil."
  (let* ((window (or window (selected-window)))
         (position (or position (point)))
         (posn (posn-at-point position window))
         (xy (and posn (posn-x-y posn))))
    (when xy
      (cdr xy))))

(defun beacon-preview--window-visible-ratio-for-pos (&optional window position)
  "Return POSITION's vertical ratio within WINDOW if it is currently visible.

Return nil when POSITION is not visible in WINDOW."
  (let* ((window (or window (selected-window)))
         (position (or position (point)))
         (visible (pos-visible-in-window-p position window)))
    (beacon-preview--debug
     "visible-ratio pos=%S window-start=%S visible=%S"
     position
     (window-start window)
     visible)
    (when visible
      (let* ((y (beacon-preview--window-pixel-y-for-pos window position))
             (body-pixels (window-body-height window t))
             (ratio (if (and y (> body-pixels 0))
                        (/ (float y) (float body-pixels))
                      (beacon-preview--window-line-ratio window position))))
        (beacon-preview--debug "visible-ratio result=%.4f" ratio)
        ratio))))

(defun beacon-preview--effective-window-ratio (ratio)
  "Convert source window RATIO into a gentler preview offset ratio.

This keeps lower cursor positions from pushing the preview target too far down
the viewport."
  (/ ratio (+ 1.0 ratio)))

(defun beacon-preview--markdown-current-fenced-code-block-info ()
  "Return fenced code block plist at point, or nil when point is outside fences.

The plist currently contains `:begin' and `:end' positions for the fenced code
block, including the opening and closing fence lines."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos (point) '("pre"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defconst beacon-preview--html-target-tags
  '("h1" "h2" "h3" "h4" "h5" "h6" "p" "li" "blockquote" "pre" "table")
  "HTML tags instrumented for preview beacons.")

(defconst beacon-preview--source-block-kinds
  '("pre" "blockquote" "table" "li" "p")
  "Source-side block kinds that map to preview beacons.")

(defconst beacon-preview--html-container-tags
  '("li" "blockquote")
  "Preview HTML tags whose descendants should not be beaconed independently.")

(defconst beacon-preview--html-suppress-nested-tags
  '("blockquote")
  "Preview HTML tags that suppress nested beacons of the same kind.")

(defun beacon-preview--html-tag-name (node)
  "Return NODE tag name as a lowercase string."
  (when (listp node)
    (downcase (symbol-name (dom-tag node)))))

(defun beacon-preview--html-code-like-class-p (class-value)
  "Return non-nil when CLASS-VALUE marks a Pandoc code wrapper."
  (when (stringp class-value)
    (let ((classes (split-string class-value "[ \t\r\n]+" t)))
      (seq-some
       (lambda (class)
         (member class '("sourceCode" "sourceCodeContainer" "listing")))
       classes))))

(defun beacon-preview--html-instrumentable-tag-p (tag node)
  "Return non-nil when HTML TAG on NODE should receive beacon metadata."
  (or (member tag beacon-preview--html-target-tags)
      (and (string= tag "div")
           (beacon-preview--html-code-like-class-p (dom-attr node 'class)))))

(defun beacon-preview--html-positive-int (value)
  "Return VALUE as a positive integer, or nil when invalid."
  (when (and (stringp value)
             (string-match-p "\\`[0-9]+\\'" value))
    (let ((parsed (string-to-number value)))
      (and (> parsed 0) parsed))))

(defun beacon-preview--html-normalize-text (text)
  "Normalize HTML TEXT for preview cache entries."
  (string-trim
   (replace-regexp-in-string "[ \t\r\n]+" " " (or text ""))))

(defun beacon-preview--html-entry-text (node)
  "Return normalized text content for HTML NODE, or nil."
  (let* ((raw-text (dom-texts node))
         (joined-text (cond
                       ((stringp raw-text) raw-text)
                       ((listp raw-text) (mapconcat #'identity raw-text " "))
                       (t "")))
         (text (beacon-preview--html-normalize-text joined-text)))
    (unless (string-empty-p text)
      text)))

(defun beacon-preview--html-heading-tag-p (tag)
  "Return non-nil when TAG is an HTML heading tag."
  (and (stringp tag)
       (string-match-p "\\`h[1-6]\\'" tag)))

(defun beacon-preview--html-entry (node tag generated-index prefix)
  "Return a preview cache entry for HTML NODE.

TAG is the lowercase node tag name, GENERATED-INDEX is the raw tag counter, and
PREFIX is the anchor prefix."
  (let* ((existing-kind (dom-attr node 'data-beacon-kind))
         (existing-index (beacon-preview--html-positive-int
                          (dom-attr node 'data-beacon-index)))
         (existing-id (dom-attr node 'id))
         (effective-kind (or existing-kind tag))
         (effective-index (or existing-index generated-index))
         (anchor (or existing-id
                     (format "%s-%s-%d" prefix tag generated-index)))
         (entry `((tag . ,tag)
                  (kind . ,effective-kind)
                  (index . ,effective-index)
                  (anchor . ,anchor))))
    (unless existing-id
      (dom-set-attribute node 'id anchor))
    (dom-set-attribute node 'data-beacon-kind effective-kind)
    (dom-set-attribute node 'data-beacon-index (number-to-string effective-index))
    (when-let ((text (and (beacon-preview--html-heading-tag-p effective-kind)
                          (beacon-preview--html-entry-text node))))
      (setcdr (last entry) `((text . ,text))))
    entry))

(defun beacon-preview--html-cache-by-kind (entries)
  "Return a hash table grouping preview ENTRIES by kind."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (let* ((kind (alist-get 'kind entry))
             (bucket (gethash kind table nil)))
        (puthash kind (cons entry bucket) table)))
    (maphash
     (lambda (kind bucket)
       (puthash kind (nreverse bucket) table))
     table)
    table))

(defun beacon-preview--effective-flash-spec ()
  "Return the effective flash style plist used for rendering.

Resolves `beacon-preview-flash-style' so that plain `setq' on the
aggregate variable takes effect even when the `:set'-driven sync to the
per-property defcustoms has not run."
  (beacon-preview--flash-style-spec beacon-preview-flash-style))

(defun beacon-preview--flash-css ()
  "Return CSS text for the current flash style settings."
  (let* ((spec (beacon-preview--effective-flash-spec))
         (radius (plist-get spec :border-radius))
         (easing (plist-get spec :easing))
         (subtle-color (plist-get spec :subtle-color))
         (subtle-peak (plist-get spec :subtle-peak-color))
         (subtle-dur (plist-get spec :subtle-duration-ms))
         (strong-color (plist-get spec :strong-color))
         (strong-peak (plist-get spec :strong-peak-color))
         (strong-dur (plist-get spec :strong-duration-ms))
         (outline-color (plist-get spec :strong-outline-color))
         (outline-peak (plist-get spec :strong-outline-peak-color))
         (outline-width (plist-get spec :strong-outline-width-px)))
    (format
     (concat
      ".beacon-preview-flash-subtle {"
      " animation: beacon-preview-flash-subtle %.3fs %s;"
      " background-color: %s;"
      " border-radius: %s;"
      " }\n"
      ".beacon-preview-flash-strong {"
      " animation: beacon-preview-flash-strong %.3fs %s;"
      " background-color: %s;"
      " box-shadow: inset 0 0 0 %dpx %s;"
      " border-radius: %s;"
      " }\n"
      "table.beacon-preview-flash-subtle {"
      " outline: %dpx solid %s;"
      " outline-offset: 2px;"
      " }\n"
      "table.beacon-preview-flash-strong {"
      " outline: %dpx solid %s;"
      " outline-offset: 2px;"
      " }\n"
      "@keyframes beacon-preview-flash-subtle {"
      " 0%% { background-color: %s; }"
      " 50%% { background-color: %s; }"
      " 100%% { background-color: transparent; }"
      " }\n"
      "@keyframes beacon-preview-flash-strong {"
      " 0%% { background-color: %s; box-shadow: inset 0 0 0 %dpx %s; }"
      " 50%% { background-color: %s; box-shadow: inset 0 0 0 %dpx %s; }"
      " 100%% { background-color: transparent; box-shadow: inset 0 0 0 0 transparent; }"
      " }")
     (/ subtle-dur 1000.0) easing subtle-color radius
     (/ strong-dur 1000.0) easing strong-color outline-width outline-color radius
     outline-width outline-color
     outline-width outline-color
     subtle-peak subtle-color
     strong-peak outline-width outline-peak
     strong-color outline-width outline-color)))

(defun beacon-preview--js-string-literal (str)
  "Return JavaScript double-quoted string literal for STR.

Escapes every character that could terminate or re-interpret the literal
in either a bare JavaScript context or when the literal is later embedded
inside an HTML `<script>` element: backslash, double quote, CR, LF, the
JavaScript LineTerminators U+2028 / U+2029, and `</` (neutralized to
`<\\/` so a payload cannot close a surrounding script tag)."
  (let ((s (or str "")))
    (setq s (replace-regexp-in-string "\\\\" "\\\\" s t t))
    (setq s (replace-regexp-in-string "\"" "\\\"" s t t))
    (setq s (replace-regexp-in-string "\r" "\\r" s t t))
    (setq s (replace-regexp-in-string "\n" "\\n" s t t))
    (setq s (replace-regexp-in-string "\u2028" "\\u2028" s t t))
    (setq s (replace-regexp-in-string "\u2029" "\\u2029" s t t))
    (setq s (replace-regexp-in-string "</" "<\\/" s t t))
    (concat "\"" s "\"")))

(defun beacon-preview--render-navigation-script ()
  "Return browser-side preview helper JavaScript."
  (let* ((spec (beacon-preview--effective-flash-spec))
         (enabled (plist-get spec :enabled))
         (subtle-timeout (+ (plist-get spec :subtle-duration-ms) 50))
         (strong-timeout (+ (plist-get spec :strong-duration-ms) 50))
         (css-literal (if enabled
                          (beacon-preview--js-string-literal
                           (beacon-preview--flash-css))
                        "\"\"")))
    (concat
     "<script>\n"
     "(function () {\n"
     "  const FLASH_STYLE_ID = \"beacon-preview-flash-style\";\n"
     "  const FLASH_SUBTLE_CLASS = \"beacon-preview-flash-subtle\";\n"
     "  const FLASH_STRONG_CLASS = \"beacon-preview-flash-strong\";\n"
     (format "  const FLASH_ENABLED = %s;\n" (if enabled "true" "false"))
     (format "  const FLASH_CSS = %s;\n" css-literal)
     (format "  const FLASH_SUBTLE_TIMEOUT_MS = %d;\n" subtle-timeout)
     (format "  const FLASH_STRONG_TIMEOUT_MS = %d;\n" strong-timeout)
     "  let flashTimer = null;\n"
     "  let flashedElement = null;\n"
     "  function collectEntries() {\n"
     "    const nodes = document.querySelectorAll('[data-beacon-kind][data-beacon-index]');\n"
     "    const entries = [];\n"
     "    for (let i = 0; i < nodes.length; i += 1) {\n"
     "      const node = nodes[i];\n"
     "      const kind = node.getAttribute('data-beacon-kind');\n"
     "      const index = parseInt(node.getAttribute('data-beacon-index') || '', 10);\n"
     "      const anchor = node.id || '';\n"
     "      if (!kind || !anchor || !Number.isFinite(index) || index <= 0) { continue; }\n"
     "      entries.push({ anchor: anchor, kind: kind, index: index, element: node });\n"
     "    }\n"
     "    return entries;\n"
     "  }\n"
     "  function ensureFlashStyle() {\n"
     "    if (!FLASH_ENABLED) { return; }\n"
     "    if (document.getElementById(FLASH_STYLE_ID)) { return; }\n"
     "    const style = document.createElement('style');\n"
     "    style.id = FLASH_STYLE_ID;\n"
     "    style.textContent = FLASH_CSS;\n"
     "    (document.head || document.body || document.documentElement).appendChild(style);\n"
     "  }\n"
     "  function clearFlash() {\n"
     "    if (flashTimer !== null) { window.clearTimeout(flashTimer); flashTimer = null; }\n"
     "    if (flashedElement) {\n"
     "      flashedElement.classList.remove(FLASH_SUBTLE_CLASS);\n"
     "      flashedElement.classList.remove(FLASH_STRONG_CLASS);\n"
     "      flashedElement = null;\n"
     "    }\n"
     "  }\n"
     "  function flashElement(element, variant) {\n"
     "    if (!element) { return false; }\n"
     "    if (!FLASH_ENABLED) { return true; }\n"
     "    const flashClass = variant === 'strong' ? FLASH_STRONG_CLASS : FLASH_SUBTLE_CLASS;\n"
     "    ensureFlashStyle();\n"
     "    clearFlash();\n"
     "    flashedElement = element;\n"
     "    element.classList.add(flashClass);\n"
     "    flashTimer = window.setTimeout(function () {\n"
     "      if (flashedElement === element) {\n"
     "        element.classList.remove(flashClass);\n"
     "        flashedElement = null;\n"
     "      }\n"
     "      flashTimer = null;\n"
     "    }, variant === 'strong' ? FLASH_STRONG_TIMEOUT_MS : FLASH_SUBTLE_TIMEOUT_MS);\n"
     "    return true;\n"
     "  }\n"
   "  function findByAnchor(anchor) {\n"
   "    const entries = collectEntries();\n"
   "    for (let i = 0; i < entries.length; i += 1) {\n"
   "      if (entries[i].anchor === anchor) { return entries[i]; }\n"
   "    }\n"
   "    return null;\n"
   "  }\n"
   "  function findByIndex(kind, index) {\n"
   "    const entries = collectEntries();\n"
   "    for (let i = 0; i < entries.length; i += 1) {\n"
   "      if (entries[i].kind === kind && entries[i].index === index) { return entries[i]; }\n"
   "    }\n"
   "    return null;\n"
   "  }\n"
   "  function scrollToElement(element) {\n"
   "    if (!element) { return false; }\n"
   "    element.scrollIntoView({ behavior: 'auto', block: 'center', inline: 'nearest' });\n"
   "    return true;\n"
   "  }\n"
   "  function jumpToElement(element) {\n"
   "    if (!scrollToElement(element)) { return false; }\n"
   "    flashElement(element, 'subtle');\n"
   "    return true;\n"
   "  }\n"
   "  function jumpToAnchor(anchor) {\n"
   "    const entry = findByAnchor(anchor);\n"
   "    return jumpToElement(entry ? entry.element : document.getElementById(anchor));\n"
   "  }\n"
   "  function isElementVisible(element) {\n"
   "    if (!element) { return false; }\n"
   "    const rect = element.getBoundingClientRect();\n"
   "    return rect.bottom > 0 && rect.top < window.innerHeight;\n"
   "  }\n"
   "  function flashAnchor(anchor) {\n"
   "    const entry = findByAnchor(anchor);\n"
   "    return flashElement(entry ? entry.element : document.getElementById(anchor), 'subtle');\n"
   "  }\n"
   "  function flashAnchorIfVisible(anchor) {\n"
   "    const element = document.getElementById(anchor);\n"
   "    if (!isElementVisible(element)) { return false; }\n"
   "    return flashElement(element, 'strong');\n"
   "  }\n"
   "  function jumpToIndex(kind, index) {\n"
   "    const entry = findByIndex(kind, index);\n"
   "    return entry ? jumpToElement(entry.element) : false;\n"
   "  }\n"
   "  window.BeaconPreview = {\n"
   "    collectEntries: collectEntries,\n"
   "    findByAnchor: findByAnchor,\n"
   "    findByIndex: findByIndex,\n"
   "    jumpToAnchor: jumpToAnchor,\n"
   "    jumpToIndex: jumpToIndex,\n"
   "    flashAnchor: flashAnchor,\n"
   "    flashAnchorIfVisible: flashAnchorIfVisible,\n"
   "    flashElement: flashElement,\n"
   "    isElementVisible: isElementVisible\n"
   "  };\n"
   "})();\n"
   "</script>")))

(defun beacon-preview--inject-navigation-api (html)
  "Return HTML with the browser-side preview helper script injected."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (if (re-search-forward "</body\\s-*>" nil t)
        (replace-match (concat (beacon-preview--render-navigation-script)
                               "\n</body>")
                       t
                       t)
      (goto-char (point-max))
      (insert "\n" (beacon-preview--render-navigation-script) "\n"))
    (buffer-string)))

(defconst beacon-preview--protected-token-prefix
  "__BEACON_PROTECTED_SCRIPT_STYLE_"
  "Opaque marker used to shield <script>/<style> bodies from libxml.

The printer in `xml-print' re-escapes `<', `>', `&', `\"', and `''
inside any text node it serializes.  For ordinary content that is
correct, but for <script> and <style> bodies it corrupts legitimate
CSS selectors (`pre > code') and JavaScript operators (`a < b').

Rather than unescape entities back after the fact (which would also
decode user-authored content that happened to land in those blocks),
we replace each body with a token *before* parsing, and substitute
the original content back *after* serialization.  Tokens are plain
ASCII so they survive libxml round-tripping unchanged and cannot be
produced accidentally by Pandoc output.")

(defun beacon-preview--protect-script-style-bodies (html)
  "Replace <script>/<style> bodies in HTML with opaque placeholder tokens.

Return (PROTECTED-HTML . ALIST) where ALIST maps each placeholder token
to the original body string.  See
`beacon-preview--protected-token-prefix' for rationale."
  (with-temp-buffer
    (insert html)
    (let ((counter 0)
          (alist nil))
      (dolist (tag '("script" "style"))
        (goto-char (point-min))
        (let ((re (format "\\(<%s\\(?:[^>]*\\)>\\)\\(\\(?:.\\|\n\\)*?\\)\\(</%s\\s-*>\\)"
                          tag tag)))
          (while (re-search-forward re nil t)
            (let* ((open (match-string 1))
                   (body (match-string 2))
                   (close (match-string 3))
                   (token (format "%s%d__"
                                  beacon-preview--protected-token-prefix
                                  counter)))
              (setq counter (1+ counter))
              (push (cons token body) alist)
              (replace-match (concat open token close) t t)))))
      (cons (buffer-string) (nreverse alist)))))

(defun beacon-preview--restore-script-style-bodies (html alist)
  "Substitute placeholder tokens in HTML with their original bodies.

ALIST is the mapping returned by
`beacon-preview--protect-script-style-bodies'."
  (let ((result html))
    (dolist (entry alist)
      (setq result (replace-regexp-in-string
                    (regexp-quote (car entry))
                    (cdr entry)
                    result t t)))
    result))

(defun beacon-preview--current-build-config ()
  "Return the current preview build settings as a plist.

This snapshots user-facing build options so HTML postprocess work can preserve
buffer-local values even while it uses temporary buffers internally."
  (let* ((source-kind (beacon-preview--source-kind))
         (major-mode-defaults (cdr (assq major-mode beacon-preview-build-settings-by-major-mode)))
         (source-kind-defaults (cdr (assq source-kind beacon-preview-build-settings-by-source-kind)))
         (config nil))
    (unless (or (null major-mode-defaults)
                (beacon-preview--build-settings-plist-p major-mode-defaults))
      (user-error "Invalid beacon preview build settings for major mode %S: %S"
                  major-mode
                  major-mode-defaults))
    (unless (or (null source-kind-defaults)
                (beacon-preview--build-settings-plist-p source-kind-defaults))
      (user-error "Invalid beacon preview build settings for source kind %S: %S"
                  source-kind
                  source-kind-defaults))
    (setq config (append source-kind-defaults nil))
    (setq config (append major-mode-defaults config))
    (when beacon-preview-build-settings
      (unless (beacon-preview--build-settings-plist-p beacon-preview-build-settings)
        (user-error "Invalid beacon preview build settings: %S"
                    beacon-preview-build-settings))
      (setq config (append beacon-preview-build-settings config)))
    (dolist (entry '((:pandoc-template-file . beacon-preview-pandoc-template-file)
                     (:pandoc-css-files . beacon-preview-pandoc-css-files)
                     (:mermaid-script-file . beacon-preview-mermaid-script-file)
                     (:mathjax-script-file . beacon-preview-mathjax-script-file)
                     (:body-wrapper-class . beacon-preview-body-wrapper-class)))
      (when (local-variable-p (cdr entry))
        (setq config (plist-put config (car entry) (symbol-value (cdr entry))))))
    (dolist (entry '((:pandoc-template-file . beacon-preview-pandoc-template-file)
                     (:pandoc-css-files . beacon-preview-pandoc-css-files)
                     (:mermaid-script-file . beacon-preview-mermaid-script-file)
                     (:mathjax-script-file . beacon-preview-mathjax-script-file)
                     (:body-wrapper-class . beacon-preview-body-wrapper-class)))
      (unless (plist-member config (car entry))
        (setq config (plist-put config (car entry) (symbol-value (cdr entry))))))
    config))

(defconst beacon-preview--html-void-elements
  '(area base br col embed hr img input link meta param source track wbr)
  "HTML void elements that have no closing tag in HTML5.

Used by the HTML serializer to emit `<br>' / `<img ...>' rather than the
XML self-closing form. Non-void elements always get an explicit closing
tag, because the HTML5 parser treats `<a/>' as an unclosed `<a>' and
swallows subsequent content until the next `</a>' — Pandoc's empty
per-line source anchors (`<a id=\"cb4-1\"></a>') would otherwise trigger
that misparse.")

(defun beacon-preview--escape-html-text (text)
  "Return TEXT escaped for placement in HTML element content."
  (let ((s (or text "")))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    s))

(defun beacon-preview--escape-html-attr (text)
  "Return TEXT escaped for placement inside a double-quoted HTML attribute."
  (let ((s (or text "")))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "\"" "&quot;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    s))

(defun beacon-preview--serialize-html-attribute (attr)
  "Return ATTR (a (NAME . VALUE) cons) as a leading-space HTML attribute."
  (format " %s=\"%s\""
          (symbol-name (car attr))
          (beacon-preview--escape-html-attr (cdr attr))))

(defun beacon-preview--serialize-html-node (node)
  "Return the HTML serialization of NODE.

Emits no extra whitespace, uses explicit close tags for non-void
elements, and self-closes only HTML void elements. This avoids both the
`<a/>'-misparsed-as-open-tag bug and the indentation that `xml-print'
would otherwise inject between inline elements or inside `<pre>'."
  (cond
   ((null node) "")
   ((stringp node) (beacon-preview--escape-html-text node))
   ((listp node)
    (let ((tag (dom-tag node)))
      (cond
       ((not (symbolp tag)) "")
       ((eq tag 'comment)
        (format "<!--%s-->" (or (car (dom-children node)) "")))
       (t
        (let* ((tag-name (symbol-name tag))
               (attrs (dom-attributes node))
               (children (dom-children node))
               (open (concat "<" tag-name
                             (mapconcat #'beacon-preview--serialize-html-attribute
                                        attrs ""))))
          (if (memq tag beacon-preview--html-void-elements)
              (concat open ">")
            (concat open ">"
                    (mapconcat #'beacon-preview--serialize-html-node
                               children "")
                    "</" tag-name ">")))))))
   (t "")))

(defun beacon-preview--serialize-html-dom (dom)
  "Return an HTML5 serialization of DOM, prefixed with `<!DOCTYPE html>'.

Uses an HTML-aware serializer rather than `xml-print' to avoid XML
self-closing of non-void elements, indentation injection (which would
shift `<pre>' content and add stray whitespace between inline elements),
and the loss of the HTML5 doctype that would otherwise drop the page
into quirks mode."
  (concat "<!DOCTYPE html>\n"
          (beacon-preview--serialize-html-node dom)))

(defun beacon-preview--html-find-first-tag (node tag)
  "Return the first descendant of NODE whose tag is TAG."
  (when (listp node)
    (if (eq (dom-tag node) tag)
        node
      (seq-some
       (lambda (child)
         (beacon-preview--html-find-first-tag child tag))
       (dom-children node)))))

(defun beacon-preview--html-set-children (node children)
  "Replace NODE children with CHILDREN."
  (setcdr (cdr node) children)
  node)

(defun beacon-preview--wrap-body-content (dom config)
  "Wrap DOM body children in one article when configured."
  (when-let* ((wrapper-class (plist-get config :body-wrapper-class))
              ((not (string-empty-p wrapper-class)))
              (body (beacon-preview--html-find-first-tag dom 'body)))
    (let ((children (dom-children body)))
      (beacon-preview--html-set-children
       body
       (list `(article ((class . ,wrapper-class)) ,@children)))))
  dom)

(defun beacon-preview--html-class-list (node)
  "Return NODE classes as a list of strings."
  (when-let ((class-value (dom-attr node 'class)))
    (split-string class-value "[ \t\r\n]+" t)))

(defun beacon-preview--html-class-member-p (node class-name)
  "Return non-nil when NODE has CLASS-NAME."
  (member class-name (beacon-preview--html-class-list node)))

(defun beacon-preview--normalize-mermaid-blocks (dom)
  "Normalize Pandoc Mermaid blocks in DOM for browser-side rendering."
  (cl-labels
      ((walk (node)
         (when (listp node)
           (when (and (eq (dom-tag node) 'pre)
                      (beacon-preview--html-class-member-p node "mermaid"))
             (let* ((texts (dom-texts node))
                    (text (if (stringp texts)
                              texts
                            (mapconcat #'identity texts ""))))
               ;; Keep pre-like preview-entry semantics after the node becomes a div.
               (setcar node 'div)
               (dom-set-attribute node 'data-beacon-kind "pre")
               (beacon-preview--html-set-children node (list text))))
           (dolist (child (dom-children node))
             (walk child)))))
    (walk dom))
  dom)

(defun beacon-preview--inject-into-head (html fragment)
  "Insert FRAGMENT before the closing head tag in HTML."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (if (re-search-forward "</head\\s-*>" nil t)
        (replace-match (concat fragment "\n</head>") t t)
      (goto-char (point-min))
      (if (re-search-forward "<body\\(?:[^>]*\\)>" nil t)
          (replace-match (concat "<head>\n" fragment "\n</head>\n" (match-string 0))
                         t t)
        (goto-char (point-min))
        (insert "<head>\n" fragment "\n</head>\n")))
    (buffer-string)))

(defun beacon-preview--render-mermaid-script-tags (config)
  "Return optional Mermaid runtime script tags, or nil when unavailable."
  (let ((script-file (plist-get config :mermaid-script-file)))
    (when script-file
      (if (file-exists-p script-file)
        (let ((script-url (beacon-preview--file-url
                           script-file)))
          (format
           (concat
            "<script src=\"%s\"></script>\n"
            "<script>\n"
            "(function () {\n"
            "  function runMermaid() {\n"
            "    if (!window.mermaid) { return; }\n"
            "    if (typeof mermaid.initialize === 'function') {\n"
            "      mermaid.initialize({ startOnLoad: false });\n"
            "    }\n"
            "    if (typeof mermaid.run === 'function') {\n"
            "      mermaid.run({ querySelector: '.mermaid' });\n"
            "      return;\n"
            "    }\n"
            "    if (typeof mermaid.init === 'function') {\n"
            "      mermaid.init(undefined, document.querySelectorAll('.mermaid'));\n"
            "    }\n"
            "  }\n"
            "  if (document.readyState === 'loading') {\n"
            "    document.addEventListener('DOMContentLoaded', runMermaid, { once: true });\n"
            "  } else {\n"
            "    runMermaid();\n"
            "  }\n"
            "})();\n"
            "</script>")
           script-url))
        (message "[beacon-preview] Mermaid runtime not found: %s"
                 script-file)
        nil))))

(defun beacon-preview--strip-pandoc-mathjax-script-tags (html)
  "Remove Pandoc's default remote MathJax script tags from HTML."
  (replace-regexp-in-string
   "<script\\(?:.\\|\n\\)*?src=\"https://cdn\\.jsdelivr\\.net/npm/mathjax@[^\"<>]+\"\\(?:.\\|\n\\)*?</script>[ \t\r\n]*"
   ""
   html t t))

(defun beacon-preview--render-mathjax-script-tags (config)
  "Return optional MathJax runtime script tags, or nil when unavailable."
  (let ((script-file (plist-get config :mathjax-script-file)))
    (when script-file
      (if (file-exists-p script-file)
          (format "<script defer src=\"%s\"></script>"
                  (beacon-preview--file-url
                   (expand-file-name script-file)))
        (message "[beacon-preview] MathJax runtime not found: %s"
                 script-file)
        nil))))

(defun beacon-preview--render-css-link-tags (config)
  "Return optional CSS link tags for CONFIG, or nil when none are available."
  (let ((links nil))
    (dolist (path (plist-get config :pandoc-css-files))
      (if (file-exists-p path)
          (push (format "<link rel=\"stylesheet\" href=\"%s\" />"
                        (beacon-preview--file-url
                         (expand-file-name path)))
                links)
        (message "[beacon-preview] CSS file not found: %s" path)))
    (when links
      (mapconcat #'identity (nreverse links) "\n"))))

(defun beacon-preview--instrument-html-dom (dom prefix config)
  "Instrument HTML DOM with preview beacons using PREFIX.

Return a plist containing `:html' and `:entries'."
  (let ((counters (make-hash-table :test #'equal))
        (entries nil))
    (beacon-preview--wrap-body-content dom config)
    (cl-labels
        ((walk (node container-depth)
           (when (listp node)
             (let* ((tag (beacon-preview--html-tag-name node))
                    (instrumentable (and tag
                                         (beacon-preview--html-instrumentable-tag-p
                                          tag node)))
                    (is-container (member tag beacon-preview--html-container-tags))
                    (suppressed nil)
                    (child-depth container-depth))
               (when (and instrumentable (> container-depth 0))
                 (let ((is-nested-container is-container))
                   (when (or (not is-nested-container)
                             (member tag beacon-preview--html-suppress-nested-tags))
                     (setq suppressed t)
                     (when is-nested-container
                       (setq child-depth (1+ child-depth))))))
               (when (and instrumentable (not suppressed))
                 (let* ((generated-index (1+ (gethash tag counters 0)))
                        (entry (beacon-preview--html-entry
                                node tag generated-index prefix)))
                   (puthash tag generated-index counters)
                   (push entry entries)
                   (when is-container
                     (setq child-depth (1+ container-depth)))))
               (dolist (child (dom-children node))
                 (walk child child-depth))))))
      (walk dom 0))
    (beacon-preview--normalize-mermaid-blocks dom)
    (list :html (beacon-preview--serialize-html-dom dom)
          :entries (nreverse entries))))

(defun beacon-preview--postprocess-preview-html-file (html-path &optional prefix)
  "Rewrite HTML-PATH with preview beacons and return cache metadata.

PREFIX defaults to `beacon'."
  (let* ((prefix (or prefix "beacon"))
         (config (beacon-preview--current-build-config))
         (protected
          (with-temp-buffer
            (insert-file-contents html-path)
            (beacon-preview--protect-script-style-bodies (buffer-string))))
         (protected-html (car protected))
         (restore-alist (cdr protected))
         (result
          (with-temp-buffer
            (insert protected-html)
            (let ((dom (libxml-parse-html-region (point-min) (point-max))))
              (beacon-preview--instrument-html-dom dom prefix config))))
         (html (beacon-preview--restore-script-style-bodies
                (plist-get result :html) restore-alist))
         (html (if (plist-get config :mathjax-script-file)
                   (beacon-preview--strip-pandoc-mathjax-script-tags html)
                 html))
         (html (if-let ((css-fragment
                         (beacon-preview--render-css-link-tags config)))
                   (beacon-preview--inject-into-head html css-fragment)
                 html))
         (html (if-let ((mermaid-fragment
                         (beacon-preview--render-mermaid-script-tags config)))
                   (beacon-preview--inject-into-head html mermaid-fragment)
                 html))
         (html (if-let ((mathjax-fragment
                         (beacon-preview--render-mathjax-script-tags config)))
                   (beacon-preview--inject-into-head html mathjax-fragment)
                 html))
         (html (beacon-preview--inject-navigation-api html))
         (entries (plist-get result :entries)))
    (with-temp-file html-path
      (insert html))
    (let ((cache (list :ordered entries
                       :by-kind (beacon-preview--html-cache-by-kind entries)
                       :html-path (expand-file-name html-path))))
      (setq beacon-preview--preview-html-cache cache)
      (setq beacon-preview--preview-entries entries)
      cache)))

(defun beacon-preview--preview-entry-at-index (kind index)
  "Return the preview entry for KIND at 1-based INDEX, or nil."
  (or (when-let* ((cache beacon-preview--preview-html-cache)
                  (entries (gethash kind (plist-get cache :by-kind) nil)))
        (nth (1- index) entries))
      (seq-find (lambda (entry)
                  (and (equal (alist-get 'kind entry) kind)
                       (= (alist-get 'index entry) index)))
                (beacon-preview--preview-entries-list))))

(defun beacon-preview--markdown-treesit-available-p ()
  "Return non-nil when tree-sitter Markdown parsing is available in this buffer."
  (and (beacon-preview--markdown-source-mode-p)
       (fboundp 'treesit-parser-create)
       (fboundp 'treesit-parser-root-node)
       (fboundp 'treesit-node-type)
       (fboundp 'treesit-node-child-count)
       (fboundp 'treesit-node-child)
       (fboundp 'treesit-node-start)
       (fboundp 'treesit-node-end)
       (fboundp 'treesit-node-parent)
       (fboundp 'treesit-parser-list)
       (fboundp 'treesit-parser-language)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'markdown)))

(defun beacon-preview--markdown-treesit-parser ()
  "Return the Markdown tree-sitter parser for the current buffer, or nil."
  (when (beacon-preview--markdown-treesit-available-p)
    (or (seq-find
         (lambda (parser)
           (eq (treesit-parser-language parser) 'markdown))
         (treesit-parser-list))
        (ignore-errors
          (treesit-parser-create 'markdown)))))

(defun beacon-preview--markdown-treesit-heading-kind (node)
  "Return preview heading kind string for Markdown heading NODE, or nil."
  (pcase (treesit-node-type node)
    ("atx_heading"
     (when-let ((marker (treesit-node-child node 0)))
       (when (string-match "\\`atx_h\\([1-6]\\)_marker\\'"
                           (treesit-node-type marker))
         (format "h%s" (match-string 1 (treesit-node-type marker))))))
    ("setext_heading"
     (let ((kind nil)
           (count (treesit-node-child-count node))
           (i 0))
       (while (and (< i count) (not kind))
         (let ((child-type (treesit-node-type (treesit-node-child node i))))
           (when (string-match "\\`setext_h\\([12]\\)_underline\\'" child-type)
             (setq kind (format "h%s" (match-string 1 child-type)))))
         (setq i (1+ i)))
       kind))
    (_ nil)))

(defun beacon-preview--markdown-treesit-fenced-math-block-p (node)
  "Return non-nil when NODE is a Markdown fenced math block.

Pandoc's GFM reader renders ```math fences as display math paragraphs, not
`pre' blocks, so source-side indexing needs to classify them as `p' as well."
  (when (and (string= (beacon-preview--pandoc-input-format) "gfm")
             (string= (treesit-node-type node) "fenced_code_block"))
    (let* ((begin (treesit-node-start node))
           (line-end (save-excursion
                       (goto-char begin)
                       (line-end-position)))
           (line (buffer-substring-no-properties begin line-end)))
      (when (string-match "\\`[ \t]*\\(?:```+\\|~~~+\\)[ \t]*\\(.*?\\)[ \t]*\\'" line)
        (let* ((info (string-trim (match-string 1 line)))
               (token (car (split-string info "[ \t]+" t))))
          (or (string= token "math")
              (string-match-p "\\(?:\\`\\|[ \t{]\\)\\.math\\(?:\\'\\|[ \t}]\\)"
                              info)))))))

(defun beacon-preview--markdown-treesit-preview-kind (node)
  "Return preview HTML kind for Markdown tree-sitter NODE, or nil.

The returned kind is intentionally normalized to the block kind Pandoc emits in
preview HTML, not just the parser node type.  For example, GFM fenced math is a
`fenced_code_block' in tree-sitter but a display math paragraph in Pandoc HTML."
  (or (beacon-preview--markdown-treesit-heading-kind node)
      (pcase (treesit-node-type node)
        ("paragraph"
         (let ((parent (treesit-node-parent node)))
           (unless (member (and parent (treesit-node-type parent))
                           '("list_item" "block_quote"))
             "p")))
        ("list_item" "li")
        ("block_quote" "blockquote")
        ("fenced_code_block"
         (if (beacon-preview--markdown-treesit-fenced-math-block-p node)
             "p"
           "pre"))
        ("pipe_table" "table")
        (_ nil))))

(defun beacon-preview--markdown-treesit-heading-text (node begin end)
  "Return heading text for Markdown heading NODE spanning BEGIN..END."
  (let* ((raw (buffer-substring-no-properties begin end))
         (lines (split-string raw "\n"))
         (first-line (string-trim (or (car lines) ""))))
    (pcase (treesit-node-type node)
      ("atx_heading"
       (when (string-match
              "^[ \t]\\{0,3\\}\\(#+\\)[ \t]+\\(.+?\\)[ \t]*#*[ \t]*$"
              first-line)
         (string-trim (match-string 2 first-line))))
      ("setext_heading"
       first-line)
      (_ nil))))

(defun beacon-preview--markdown-treesit-entry-metadata (node kind begin end)
  "Return extra metadata alist for Markdown tree-sitter entry.

NODE, KIND, BEGIN, and END describe the entry being recorded."
  (let ((metadata nil))
    (when (string-match "\\`h\\([1-6]\\)\\'" kind)
      (setq metadata
            (append metadata
                    (list (cons 'level (string-to-number (match-string 1 kind)))))))
    (when (string-match "\\`h[1-6]\\'" kind)
      (when-let ((text (beacon-preview--markdown-treesit-heading-text node begin end)))
        (setq metadata
              (append metadata
                      (list (cons 'text text))))))
    (append metadata
            (list (cons 'kind kind)
                  (cons 'begin begin)
                  (cons 'end (max begin (1- end)))))))

(defun beacon-preview--markdown-treesit-build-cache ()
  "Build and return Markdown block entries derived from tree-sitter."
  (when-let* ((parser (beacon-preview--markdown-treesit-parser))
              (root (treesit-parser-root-node parser)))
    (let ((ordered nil)
          (kind-tables (make-hash-table :test #'equal)))
      (cl-labels
          ((walk (node)
             (when-let ((kind (beacon-preview--markdown-treesit-preview-kind node)))
               (let* ((begin (treesit-node-start node))
                      (end (treesit-node-end node))
                      (index (1+ (length (gethash kind kind-tables nil))))
                      (entry (append
                              (list (cons 'index index))
                              (beacon-preview--markdown-treesit-entry-metadata
                               node kind begin end))))
                 (puthash kind
                          (append (gethash kind kind-tables nil)
                                  (list entry))
                          kind-tables)
                 (setq ordered (append ordered (list entry)))))
             (dotimes (i (treesit-node-child-count node))
               (walk (treesit-node-child node i)))))
        (walk root))
      (list :ordered ordered :by-kind kind-tables))))

(defun beacon-preview--markdown-treesit-cache ()
  "Return cached Markdown tree-sitter entries for the current buffer, or nil."
  (when (beacon-preview--markdown-treesit-available-p)
    (let ((tick (buffer-chars-modified-tick)))
      (unless (and beacon-preview--markdown-treesit-cache
                   (equal beacon-preview--markdown-treesit-cache-tick tick))
        (setq beacon-preview--markdown-treesit-cache
              (beacon-preview--markdown-treesit-build-cache))
        (setq beacon-preview--markdown-treesit-cache-tick tick))
      beacon-preview--markdown-treesit-cache)))

(defun beacon-preview--markdown-treesit-entries-for-kind (kind)
  "Return cached Markdown tree-sitter entries for preview KIND, or nil."
  (when-let ((cache (beacon-preview--markdown-treesit-cache)))
    (gethash kind (plist-get cache :by-kind))))

(defun beacon-preview--markdown-treesit-entry-at-pos (pos &optional kinds)
  "Return Markdown tree-sitter entry containing POS.

When KINDS is non-nil, only entries whose `kind' is in that list are
considered."
  (when-let ((cache (beacon-preview--markdown-treesit-cache)))
    (seq-find
     (lambda (entry)
       (and (or (null kinds)
                (member (alist-get 'kind entry) kinds))
            (<= (alist-get 'begin entry) pos)
            (< pos (alist-get 'end entry))))
     (plist-get cache :ordered))))

(defun beacon-preview--markdown-treesit-entry-at-or-before-pos (pos &optional kinds)
  "Return Markdown tree-sitter entry containing POS or ending just before it.

When KINDS is non-nil, only entries whose `kind' is in that list are
considered."
  (or (beacon-preview--markdown-treesit-entry-at-pos pos kinds)
      (when-let ((cache (beacon-preview--markdown-treesit-cache)))
        (let ((result nil))
          (dolist (entry (plist-get cache :ordered))
            (when (and (or (null kinds)
                           (member (alist-get 'kind entry) kinds))
                       (< (alist-get 'end entry) pos))
              (setq result entry)))
          result))))

(defun beacon-preview--markdown-treesit-index-at-pos (kind pos)
  "Return 1-based Markdown tree-sitter index for KIND containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos pos (list kind))))
    (alist-get 'index entry)))

(defun beacon-preview--markdown-treesit-position-at-index (kind index)
  "Return Markdown tree-sitter position for KIND at 1-based INDEX, or nil."
  (when-let ((entry (nth (1- index)
                         (beacon-preview--markdown-treesit-entries-for-kind kind))))
    (alist-get 'begin entry)))

(defun beacon-preview--markdown-treesit-heading-entries ()
  "Return cached Markdown tree-sitter heading entries in source order."
  (when-let ((cache (beacon-preview--markdown-treesit-cache)))
    (seq-filter
     (lambda (entry)
       (string-match-p "\\`h[1-6]\\'" (alist-get 'kind entry)))
     (plist-get cache :ordered))))

(defun beacon-preview--markdown-treesit-current-heading-entry (&optional pos)
  "Return the nearest Markdown heading tree-sitter entry at or before POS."
  (let ((target (or pos (point)))
        (result nil))
    (dolist (entry (beacon-preview--markdown-treesit-heading-entries))
      (when (<= (alist-get 'begin entry) target)
        (setq result entry)))
    result))

(defun beacon-preview--markdown-treesit-current-heading-info (&optional pos)
  "Return nearest Markdown heading info at or before POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-current-heading-entry pos)))
    (list :level (alist-get 'level entry)
          :text (alist-get 'text entry)
          :pos (alist-get 'begin entry))))

(defun beacon-preview--markdown-treesit-heading-occurrence (heading)
  "Return 1-based occurrence count for Markdown HEADING using tree-sitter."
  (let* ((target-level (plist-get heading :level))
         (target-text (plist-get heading :text))
         (current-entry (beacon-preview--markdown-treesit-current-heading-entry (point)))
         (target-pos (or (plist-get heading :pos)
                         (and current-entry
                              (= (alist-get 'level current-entry) target-level)
                              (string= (or (alist-get 'text current-entry) "")
                                       (or target-text ""))
                              (alist-get 'begin current-entry))))
         (count 0))
    (dolist (entry (beacon-preview--markdown-treesit-heading-entries))
      (when (<= (alist-get 'begin entry) target-pos)
        (when (and (= (alist-get 'level entry) target-level)
                   (string= (or (alist-get 'text entry) "")
                            (or target-text "")))
          (setq count (1+ count)))))
    (and (> count 0) count)))

(defun beacon-preview--org-element-available-p ()
  "Return non-nil when Org structural parsing is available in this buffer."
  (and (derived-mode-p 'org-mode)
       (fboundp 'org-element-parse-buffer)
       (fboundp 'org-element-map)
       (fboundp 'org-element-type)
       (fboundp 'org-element-property)))

(defun beacon-preview--org-element-preview-ignored-p (element)
  "Return non-nil when Org ELEMENT should not produce a preview entry.

This filters parser nodes that Pandoc does not emit as independent preview
blocks, such as the wrapper-only `\\[' and `\\]' paragraphs around a LaTeX
display math environment."
  (let ((parent (org-element-property :parent element))
        (ignored nil))
    (when-let* ((begin (org-element-property :begin element))
                (end (org-element-property :end element))
                (text (string-trim
                       (buffer-substring-no-properties begin end))))
      (when (member text '("\\[" "\\]"))
        (setq ignored t)))
    (while (and parent (not ignored))
      (when (memq (org-element-type parent)
                  '(item quote-block src-block example-block table table-row table-cell))
        (setq ignored t))
      (setq parent (org-element-property :parent parent)))
    ignored))

(defun beacon-preview--org-element-preview-kind (element)
  "Return preview HTML kind for Org ELEMENT, or nil.

The returned kind is normalized to the block kind Pandoc emits in preview HTML.
For example, an Org `latex-environment' inside display math is rendered as a
display math paragraph, so it contributes a `p' entry."
  (unless (beacon-preview--org-element-preview-ignored-p element)
    (pcase (org-element-type element)
      (`headline
       (format "h%d" (org-element-property :level element)))
      (`item "li")
      (`paragraph "p")
      (`latex-environment "p")
      (`quote-block "blockquote")
      ((or `src-block `example-block) "pre")
      (`table "table")
      (_ nil))))

(defun beacon-preview--org-element-entry-metadata (element kind)
  "Return extra metadata alist for Org ELEMENT of preview KIND."
  (let ((metadata nil))
    (when (string-match "\\`h\\([0-9]+\\)\\'" kind)
      (setq metadata
            (append metadata
                    (list (cons 'level (string-to-number (match-string 1 kind)))))))
    (when (string-match "\\`h[0-9]+\\'" kind)
      (setq metadata
            (append metadata
                    (list (cons 'text (org-element-property :raw-value element))))))
    (append metadata
            (list (cons 'kind kind)
                  (cons 'begin (org-element-property :begin element))
                  (cons 'end (max (org-element-property :begin element)
                                  (1- (org-element-property :end element))))))))

(defun beacon-preview--org-element-build-cache ()
  "Build and return Org structural entries derived from `org-element'."
  (when (beacon-preview--org-element-available-p)
    (let ((ast (org-element-parse-buffer))
          (ordered nil)
          (kind-tables (make-hash-table :test #'equal)))
      (org-element-map ast
          '(headline item paragraph latex-environment quote-block src-block example-block table)
        (lambda (element)
          (when-let ((kind (beacon-preview--org-element-preview-kind element)))
            (let* ((index (1+ (length (gethash kind kind-tables nil))))
                   (entry (append
                           (list (cons 'index index))
                           (beacon-preview--org-element-entry-metadata element kind))))
              (puthash kind
                       (append (gethash kind kind-tables nil)
                               (list entry))
                       kind-tables)
              (setq ordered (append ordered (list entry))))))
        nil nil nil t)
      (list :ordered ordered :by-kind kind-tables))))

(defun beacon-preview--org-element-cache ()
  "Return cached Org structural entries for the current buffer, or nil."
  (when (beacon-preview--org-element-available-p)
    (let ((tick (buffer-chars-modified-tick)))
      (unless (and beacon-preview--org-element-cache
                   (equal beacon-preview--org-element-cache-tick tick))
        (setq beacon-preview--org-element-cache
              (beacon-preview--org-element-build-cache))
        (setq beacon-preview--org-element-cache-tick tick))
      beacon-preview--org-element-cache)))

(defun beacon-preview--org-element-entries-for-kind (kind)
  "Return cached Org entries for preview KIND, or nil."
  (when-let ((cache (beacon-preview--org-element-cache)))
    (gethash kind (plist-get cache :by-kind))))

(defun beacon-preview--org-element-entry-at-pos (pos &optional kinds)
  "Return Org entry containing POS.

When KINDS is non-nil, only entries whose `kind' is in that list are
considered."
  (when-let ((cache (beacon-preview--org-element-cache)))
    (seq-find
     (lambda (entry)
       (and (or (null kinds)
                (member (alist-get 'kind entry) kinds))
            (<= (alist-get 'begin entry) pos)
            (< pos (alist-get 'end entry))))
     (plist-get cache :ordered))))

(defun beacon-preview--org-element-entry-at-or-before-pos (pos &optional kinds)
  "Return Org entry containing POS or ending just before it."
  (or (beacon-preview--org-element-entry-at-pos pos kinds)
      (when-let ((cache (beacon-preview--org-element-cache)))
        (let ((result nil))
          (dolist (entry (plist-get cache :ordered))
            (when (and (or (null kinds)
                           (member (alist-get 'kind entry) kinds))
                       (< (alist-get 'end entry) pos))
              (setq result entry)))
          result))))

(defun beacon-preview--org-element-index-at-pos (kind pos)
  "Return 1-based Org index for KIND containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos pos (list kind))))
    (alist-get 'index entry)))

(defun beacon-preview--org-element-position-at-index (kind index)
  "Return Org position for KIND at 1-based INDEX, or nil."
  (when-let ((entry (nth (1- index)
                         (beacon-preview--org-element-entries-for-kind kind))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-element-heading-entries ()
  "Return cached Org heading entries in source order."
  (when-let ((cache (beacon-preview--org-element-cache)))
    (seq-filter
     (lambda (entry)
       (string-match-p "\\`h[0-9]+\\'" (alist-get 'kind entry)))
     (plist-get cache :ordered))))

(defun beacon-preview--org-element-current-heading-entry (&optional pos)
  "Return the nearest Org heading entry at or before POS."
  (let ((target (or pos (point)))
        (result nil))
    (dolist (entry (beacon-preview--org-element-heading-entries))
      (when (<= (alist-get 'begin entry) target)
        (setq result entry)))
    result))

(defun beacon-preview--org-element-current-heading-info (&optional pos)
  "Return nearest Org heading info at or before POS, or nil."
  (when-let ((entry (beacon-preview--org-element-current-heading-entry pos)))
    (list :level (alist-get 'level entry)
          :text (alist-get 'text entry)
          :pos (alist-get 'begin entry))))

(defun beacon-preview--org-element-heading-occurrence (heading)
  "Return 1-based occurrence count for Org HEADING using `org-element'."
  (let* ((target-level (plist-get heading :level))
         (target-text (plist-get heading :text))
         (current-entry (beacon-preview--org-element-current-heading-entry (point)))
         (target-pos (or (plist-get heading :pos)
                         (and current-entry
                              (= (alist-get 'level current-entry) target-level)
                              (string= (or (alist-get 'text current-entry) "")
                                       (or target-text ""))
                              (alist-get 'begin current-entry))))
         (count 0))
    (dolist (entry (beacon-preview--org-element-heading-entries))
      (when (<= (alist-get 'begin entry) target-pos)
        (when (and (= (alist-get 'level entry) target-level)
                   (string= (or (alist-get 'text entry) "")
                            (or target-text "")))
          (setq count (1+ count)))))
    (and (> count 0) count)))

(defun beacon-preview--org-heading-info-at-point ()
  "Return an Org heading plist at point, including level, text, and position."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos (point))))
    (when (string-match "\\`h[0-9]+\\'" (alist-get 'kind entry))
      (list :level (alist-get 'level entry)
            :text (alist-get 'text entry)
            :pos (alist-get 'begin entry)))))

(defun beacon-preview--org-current-heading-info ()
  "Return the nearest Org heading at or before point, including `:pos'."
  (beacon-preview--org-element-current-heading-info))

(defun beacon-preview--org-heading-occurrence (heading)
  "Return 1-based occurrence count for Org HEADING up to point."
  (beacon-preview--org-element-heading-occurrence heading))
(defun beacon-preview--org-list-item-beginning-position ()
  "Return the beginning position of the current Org list item, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos (point) '("li"))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-list-item-index ()
  "Return the 1-based Org list item index at point, or nil."
  (beacon-preview--org-element-index-at-pos "li" (point)))

(defun beacon-preview--org-paragraph-beginning-position ()
  "Return the beginning position of the current Org paragraph block, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos (point) '("p"))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-paragraph-index ()
  "Return the 1-based Org paragraph index at point, or nil."
  (beacon-preview--org-element-index-at-pos "p" (point)))

(defun beacon-preview--org-blockquote-beginning-position ()
  "Return the beginning position of the current Org quote block, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos
                     (point)
                     '("blockquote"))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-blockquote-index ()
  "Return the 1-based Org quote block index at point, or nil."
  (beacon-preview--org-element-index-at-pos "blockquote" (point)))

(defun beacon-preview--org-source-block-beginning-position ()
  "Return the beginning position of the current Org source/example block, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos (point) '("pre"))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-source-block-index ()
  "Return the 1-based Org source/example block index at point, or nil."
  (beacon-preview--org-element-index-at-pos "pre" (point)))

(defun beacon-preview--org-table-beginning-position ()
  "Return the beginning position of the current Org table, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos (point) '("table"))))
    (alist-get 'begin entry)))

(defun beacon-preview--org-table-index ()
  "Return the 1-based Org table index at point, or nil."
  (beacon-preview--org-element-index-at-pos "table" (point)))

(defun beacon-preview--markdown-blockquote-beginning-position ()
  "Return the beginning position of the current Markdown blockquote, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                     (point)
                     '("blockquote"))))
    (alist-get 'begin entry)))

(defun beacon-preview--markdown-blockquote-index ()
  "Return the 1-based blockquote index at point, or nil."
  (beacon-preview--markdown-treesit-index-at-pos "blockquote" (point)))

(defun beacon-preview--markdown-table-beginning-position ()
  "Return the beginning position of the current pipe table, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                     (point)
                     '("table"))))
    (alist-get 'begin entry)))

(defun beacon-preview--markdown-table-index ()
  "Return the 1-based pipe table index at point, or nil."
  (beacon-preview--markdown-treesit-index-at-pos "table" (point)))

(defun beacon-preview--markdown-list-item-beginning-position ()
  "Return the beginning position of the current Markdown list item, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                     (point)
                     '("li"))))
    (alist-get 'begin entry)))

(defun beacon-preview--markdown-list-item-index ()
  "Return the 1-based list item index at point, or nil."
  (beacon-preview--markdown-treesit-index-at-pos "li" (point)))

(defun beacon-preview--markdown-paragraph-line-p ()
  "Return non-nil when the current line should be treated as paragraph content." 
  (and (not (looking-at "^[ \t]*$"))
       (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                          (line-beginning-position)
                          '("p"))))
         (let ((begin (alist-get 'begin entry))
               (end (alist-get 'end entry)))
           (and (<= begin (line-beginning-position))
                (<= (line-end-position) (1+ end)))))))

(defun beacon-preview--markdown-paragraph-beginning-position ()
  "Return the beginning position of the current paragraph block, or nil.

Only plain paragraph text is considered here; headings, list items, and fenced
code blocks are excluded." 
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                     (point)
                     '("p"))))
    (alist-get 'begin entry)))

(defun beacon-preview--markdown-skip-paragraph-forward ()
  "Move point to the first line after the current paragraph block." 
  (while (and (beacon-preview--markdown-paragraph-line-p)
              (zerop (forward-line 1)))
    nil))

(defun beacon-preview--markdown-paragraph-index ()
  "Return the 1-based paragraph index at point, or nil."
  (beacon-preview--markdown-treesit-index-at-pos "p" (point)))

(defun beacon-preview--markdown-fenced-code-block-index ()
  "Return the 1-based fenced code block index at point, or nil.

This counts fenced code blocks in the source buffer using simple Markdown fence
rules so it can align with Pandoc/beaconified `pre' entries." 
  (beacon-preview--markdown-treesit-index-at-pos "pre" (point)))

(defun beacon-preview--block-anchor-at-pos (pos)
  "Return the block anchor for POS, or nil when none is resolved."
  (when (beacon-preview--supported-source-mode-p)
    (save-excursion
      (goto-char pos)
      (cond
       ((derived-mode-p 'org-mode)
        (or (when-let* ((entry (beacon-preview--org-element-entry-at-pos
                                pos
                                '("pre" "blockquote" "table" "li" "p")))
                        (preview-entry
                         (beacon-preview--preview-entry-at-index
                          (alist-get 'kind entry)
                          (alist-get 'index entry)))
                        (anchor (alist-get 'anchor preview-entry)))
              anchor)))
       (t
        (or (when-let* ((entry (beacon-preview--markdown-treesit-entry-at-pos
                                pos
                                '("pre" "blockquote" "table" "li" "p")))
                        (preview-entry
                         (beacon-preview--preview-entry-at-index
                          (alist-get 'kind entry)
                         (alist-get 'index entry)))
                        (anchor (alist-get 'anchor preview-entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-blockquote-index))
                        (entry (beacon-preview--preview-entry-at-index "blockquote" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-table-index))
                        (entry (beacon-preview--preview-entry-at-index "table" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-list-item-index))
                        (entry (beacon-preview--preview-entry-at-index "li" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-paragraph-index))
                        (entry (beacon-preview--preview-entry-at-index "p" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)))))))

(defun beacon-preview-current-block-anchor ()
  "Return the current block anchor for point, or nil when none is resolved."
  (beacon-preview--block-anchor-at-pos (point)))

(defun beacon-preview--source-block-entry-at-pos (pos)
  "Return the source block entry at or immediately before POS, or nil."
  (when (beacon-preview--supported-source-mode-p)
    (save-excursion
      (goto-char pos)
      (cond
       ((derived-mode-p 'org-mode)
        (or (beacon-preview--org-element-entry-at-pos
             pos beacon-preview--source-block-kinds)
            (progn
              (skip-chars-backward " \t\n")
              (or (beacon-preview--org-element-entry-at-pos
                   (point) beacon-preview--source-block-kinds)
                  (beacon-preview--org-element-entry-at-or-before-pos
                   (point) beacon-preview--source-block-kinds)))))
       (t
        (or (beacon-preview--markdown-treesit-entry-at-pos
             pos beacon-preview--source-block-kinds)
            (progn
              (skip-chars-backward " \t\n")
              (or (beacon-preview--markdown-treesit-entry-at-pos
                   (point) beacon-preview--source-block-kinds)
                  (beacon-preview--markdown-treesit-entry-at-or-before-pos
                   (point) beacon-preview--source-block-kinds)))))))))

(defun beacon-preview--org-heading-position-at-index (level index)
  "Return the position of the Org heading at LEVEL and 1-based INDEX, or nil."
  (let ((count 0)
        (found nil))
    (dolist (entry (beacon-preview--org-element-heading-entries))
      (when (and (not found)
                 (= (alist-get 'level entry) level))
        (setq count (1+ count))
        (when (= count index)
          (setq found (alist-get 'begin entry)))))
    found))

(defun beacon-preview--org-list-item-position-at-index (index)
  "Return the position of the Org list item at 1-based INDEX, or nil."
  (beacon-preview--org-element-position-at-index "li" index))

(defun beacon-preview--org-paragraph-position-at-index (index)
  "Return the position of the Org paragraph at 1-based INDEX, or nil."
  (beacon-preview--org-element-position-at-index "p" index))

(defun beacon-preview--org-blockquote-position-at-index (index)
  "Return the position of the Org quote block at 1-based INDEX, or nil."
  (beacon-preview--org-element-position-at-index "blockquote" index))

(defun beacon-preview--org-source-block-position-at-index (index)
  "Return the position of the Org source/example block at 1-based INDEX, or nil."
  (beacon-preview--org-element-position-at-index "pre" index))

(defun beacon-preview--org-table-position-at-index (index)
  "Return the position of the Org table at 1-based INDEX, or nil."
  (beacon-preview--org-element-position-at-index "table" index))

(defun beacon-preview--markdown-heading-position-at-index (level index)
  "Return the position of the Markdown heading at LEVEL and 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index
   (format "h%d" level)
   index))

(defun beacon-preview--markdown-blockquote-position-at-index (index)
  "Return the position of the Markdown blockquote at 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index "blockquote" index))

(defun beacon-preview--markdown-table-position-at-index (index)
  "Return the position of the Markdown pipe table at 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index "table" index))

(defun beacon-preview--markdown-list-item-position-at-index (index)
  "Return the position of the Markdown list item at 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index "li" index))

(defun beacon-preview--markdown-paragraph-position-at-index (index)
  "Return the position of the Markdown paragraph at 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index "p" index))

(defun beacon-preview--markdown-fenced-code-block-position-at-index (index)
  "Return the position of the Markdown fenced code block at 1-based INDEX, or nil."
  (beacon-preview--markdown-treesit-position-at-index "pre" index))

(defun beacon-preview--source-position-for-kind-index (kind index)
  "Return a source position for preview KIND at 1-based INDEX, or nil."
  (when (and kind (integerp index) (> index 0))
    (cond
     ((derived-mode-p 'org-mode)
      (cond
       ((string-match "\\`h\\([1-6]\\)\\'" kind)
        (beacon-preview--org-heading-position-at-index
         (string-to-number (match-string 1 kind))
         index))
       ((equal kind "pre")
        (beacon-preview--org-source-block-position-at-index index))
       ((equal kind "blockquote")
        (beacon-preview--org-blockquote-position-at-index index))
       ((equal kind "table")
        (beacon-preview--org-table-position-at-index index))
       ((equal kind "li")
        (beacon-preview--org-list-item-position-at-index index))
       ((equal kind "p")
        (beacon-preview--org-paragraph-position-at-index index))))
     (t
      (cond
       ((string-match "\\`h\\([1-6]\\)\\'" kind)
        (beacon-preview--markdown-heading-position-at-index
         (string-to-number (match-string 1 kind))
         index))
       ((equal kind "pre")
        (beacon-preview--markdown-fenced-code-block-position-at-index index))
       ((equal kind "blockquote")
        (beacon-preview--markdown-blockquote-position-at-index index))
       ((equal kind "table")
        (beacon-preview--markdown-table-position-at-index index))
       ((equal kind "li")
        (beacon-preview--markdown-list-item-position-at-index index))
       ((equal kind "p")
        (beacon-preview--markdown-paragraph-position-at-index index)))))))

(defun beacon-preview--markdown-heading-range-at-pos (pos)
  "Return a Markdown heading range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-current-heading-entry pos)))
    (let ((level (alist-get 'level entry))
          (begin (alist-get 'begin entry))
          (end (point-max)))
      (catch 'done
        (dolist (candidate (beacon-preview--markdown-treesit-heading-entries))
          (when (and (> (alist-get 'begin candidate) begin)
                     (<= (alist-get 'level candidate) level))
            (setq end (max begin (1- (alist-get 'begin candidate))))
            (throw 'done nil))))
      (list :begin begin :end end))))

(defun beacon-preview--org-heading-range-at-pos (pos)
  "Return an Org heading range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-current-heading-entry pos)))
    (let ((level (alist-get 'level entry))
          (begin (alist-get 'begin entry))
          (end (point-max)))
      (catch 'done
        (dolist (candidate (beacon-preview--org-element-heading-entries))
          (when (and (> (alist-get 'begin candidate) begin)
                     (<= (alist-get 'level candidate) level))
            (setq end (max begin (1- (alist-get 'begin candidate))))
            (throw 'done nil))))
      (list :begin begin :end end))))

(defun beacon-preview--org-paragraph-range-at-pos (pos)
  "Return an Org paragraph range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos pos '("p"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--org-blockquote-range-at-pos (pos)
  "Return an Org quote block range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos pos '("blockquote"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--org-source-block-range-at-pos (pos)
  "Return an Org source/example block range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos pos '("pre"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--org-table-range-at-pos (pos)
  "Return an Org table range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--org-element-entry-at-pos pos '("table"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--markdown-paragraph-range-at-pos (pos)
  "Return a Markdown paragraph range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos pos '("p"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--markdown-blockquote-range-at-pos (pos)
  "Return a Markdown blockquote range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos pos '("blockquote"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--markdown-table-range-at-pos (pos)
  "Return a Markdown pipe table range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos pos '("table"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--markdown-fenced-code-block-range-at-pos (pos)
  "Return a Markdown fenced code block range plist containing POS, or nil."
  (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos pos '("pre"))))
    (list :begin (alist-get 'begin entry)
          :end (alist-get 'end entry))))

(defun beacon-preview--source-block-range-for-kind-index (kind index)
  "Return a source block range plist for preview KIND at 1-based INDEX, or nil."
  (when-let ((position (beacon-preview--source-position-for-kind-index kind index)))
    (save-excursion
      (goto-char position)
      (cond
       ((derived-mode-p 'org-mode)
        (cond
         ((string-match "\\`h\\([1-6]\\)\\'" kind)
          (beacon-preview--org-heading-range-at-pos position))
         ((equal kind "pre")
          (beacon-preview--org-source-block-range-at-pos position))
         ((equal kind "blockquote")
          (beacon-preview--org-blockquote-range-at-pos position))
         ((equal kind "table")
          (beacon-preview--org-table-range-at-pos position))
         ((equal kind "p")
          (beacon-preview--org-paragraph-range-at-pos position))
         (t nil)))
       (t
        (cond
         ((string-match "\\`h\\([1-6]\\)\\'" kind)
          (beacon-preview--markdown-heading-range-at-pos position))
         ((equal kind "pre")
          (beacon-preview--markdown-fenced-code-block-range-at-pos position))
         ((equal kind "blockquote")
          (beacon-preview--markdown-blockquote-range-at-pos position))
         ((equal kind "table")
          (beacon-preview--markdown-table-range-at-pos position))
         ((equal kind "p")
          (beacon-preview--markdown-paragraph-range-at-pos position))
         (t nil)))))))

(defun beacon-preview--position-in-range-by-progress (range progress)
  "Return a position within RANGE according to PROGRESS, or nil.

RANGE is a plist containing `:begin' and `:end'.  PROGRESS should be a number
in the inclusive `[0.0, 1.0]' range."
  (when (and (numberp progress)
             range)
    (let* ((begin (plist-get range :begin))
           (end (plist-get range :end)))
      (when (and (integer-or-marker-p begin)
                 (integer-or-marker-p end)
                 (<= begin end))
        (save-excursion
          (goto-char begin)
          (let* ((begin-line (line-number-at-pos begin))
                 (end-line (line-number-at-pos end))
                 (line-span (max 0 (- end-line begin-line)))
                (offset (truncate (* (beacon-preview--clamp-ratio progress)
                                      line-span))))
            (forward-line offset)
            (line-beginning-position)))))))

(defun beacon-preview--source-block-progress-at-pos (range position)
  "Return POSITION's approximate progress through source block RANGE."
  (when-let* ((begin (plist-get range :begin))
              (end (plist-get range :end)))
    (when (and (integer-or-marker-p begin)
               (integer-or-marker-p end)
               (integer-or-marker-p position)
               (<= begin end))
      (let* ((begin-line (line-number-at-pos begin))
             (end-line (line-number-at-pos end))
             (position-line (line-number-at-pos
                             (min (max position begin) end)))
             (line-span (- end-line begin-line)))
        (if (> line-span 0)
            (beacon-preview--clamp-ratio
             (/ (float (- position-line begin-line))
                (float line-span)))
          (beacon-preview--clamp-ratio
           (/ (float (- (min (max position begin) end) begin))
              (float (max 1 (- end begin))))))))))

(defun beacon-preview--current-source-preview-context (&optional window position)
  "Return source-to-preview sync context for the current nearby block.

The context is a plist with `:anchor', `:ratio', and `:block-progress'.  It is
based on POSITION, defaulting to point, inside WINDOW, defaulting to the
selected window."
  (let* ((position (or position (point)))
         (entry (beacon-preview--source-block-entry-at-pos position))
         (kind (alist-get 'kind entry))
         (index (alist-get 'index entry)))
    (when-let* ((preview-entry (and kind index
                                    (beacon-preview--preview-entry-at-index
                                     kind index)))
                (anchor (alist-get 'anchor preview-entry)))
      (let* ((range (list :begin (alist-get 'begin entry)
                          :end (alist-get 'end entry)))
             (ratio (beacon-preview--window-visible-ratio-for-pos
                     (or window (selected-window))
                     position))
             (block-progress
              (beacon-preview--source-block-progress-at-pos range position)))
        (list :anchor anchor
              :kind kind
              :index index
              :ratio ratio
              :block-progress block-progress)))))

(defun beacon-preview--apply-preview-entry-to-source (entry source-buffer)
  "Move SOURCE-BUFFER to the position identified by preview ENTRY.

The matched source block is first aligned to ENTRY's `ratio' so the source
window mirrors the preview's scroll position, then point is moved to the
source window's vertical center without disturbing that alignment."
  (with-current-buffer source-buffer
    (let* ((kind (alist-get 'kind entry))
           (index (alist-get 'index entry))
           (block-progress (alist-get 'block_progress entry))
           (ratio (alist-get 'ratio entry))
           (position (beacon-preview--source-position-for-kind-index kind index))
           (range (beacon-preview--source-block-range-for-kind-index kind index))
           (target (or (beacon-preview--position-in-range-by-progress
                        range
                        block-progress)
                       position)))
      (unless position
        (user-error "No source position found for preview %s #%s" kind index))
      (let ((window (beacon-preview--show-source-buffer source-buffer)))
        (unless (= target (point))
          (push-mark (point) t))
        (goto-char target)
        (if (numberp ratio)
            (beacon-preview--recenter-window-to-ratio window ratio)
          (beacon-preview--align-window-to-center window))
        (beacon-preview--move-point-to-window-center window)
        target))))

(defun beacon-preview--nearest-block-source-position-at-pos (pos)
  "Return a nearby source block start for POS, preferring the preceding block."
  (save-excursion
    (goto-char pos)
    (cond
     ((derived-mode-p 'org-mode)
      (or (when-let ((entry (beacon-preview--org-element-entry-at-pos
                             (point)
                             '("pre" "blockquote" "table" "li" "p"))))
            (alist-get 'begin entry))
          (progn
            (skip-chars-backward " \t\n")
            (or (when-let ((entry (beacon-preview--org-element-entry-at-or-before-pos
                                   (point)
                                   '("pre" "blockquote" "table" "li" "p"))))
                  (alist-get 'begin entry))
                (when (> (point) (point-min))
                  (when-let ((entry (beacon-preview--org-element-entry-at-pos
                                     (1- (point))
                                     '("pre" "blockquote" "table" "li" "p"))))
                    (alist-get 'begin entry)))))))
     (t
      (or (when-let ((entry (beacon-preview--markdown-treesit-entry-at-pos
                             (point)
                             '("pre" "blockquote" "table" "li" "p"))))
            (alist-get 'begin entry))
          (when-let ((block (beacon-preview--markdown-current-fenced-code-block-info)))
            (plist-get block :begin))
          (beacon-preview--markdown-blockquote-beginning-position)
          (beacon-preview--markdown-table-beginning-position)
          (beacon-preview--markdown-list-item-beginning-position)
          (beacon-preview--markdown-paragraph-beginning-position)
          (progn
            (skip-chars-backward " \t\n")
            (or (when-let ((entry (beacon-preview--markdown-treesit-entry-at-or-before-pos
                                   (point)
                                   '("pre" "blockquote" "table" "li" "p"))))
                  (alist-get 'begin entry))
                (when-let ((block (beacon-preview--markdown-current-fenced-code-block-info)))
                  (plist-get block :begin))
                (beacon-preview--markdown-blockquote-beginning-position)
                (beacon-preview--markdown-table-beginning-position)
                (beacon-preview--markdown-list-item-beginning-position)
                (beacon-preview--markdown-paragraph-beginning-position))))))))

(defun beacon-preview--target-source-position-at-pos (pos)
  "Return the source position for the jump target that contains POS, or nil.

This prefers a more specific source block position when available and otherwise
falls back to the current heading position."
  (save-excursion
    (goto-char pos)
    (or (beacon-preview--nearest-block-source-position-at-pos pos)
        (if-let ((heading (if (derived-mode-p 'org-mode)
                              (beacon-preview--org-current-heading-info)
                            (beacon-preview--markdown-current-heading-info))))
            (plist-get heading :pos)
          nil))))

(defun beacon-preview--target-source-position-maybe ()
  "Return the source position for the current jump target, or nil."
  (beacon-preview--target-source-position-at-pos (point)))

(defun beacon-preview--anchor-kind (anchor)
  "Return the preview kind for ANCHOR, or nil when unknown."
  (when-let ((entry (seq-find (lambda (candidate)
                                (equal (alist-get 'anchor candidate) anchor))
                              (beacon-preview--preview-entries-list))))
    (alist-get 'kind entry)))

(defun beacon-preview--nearest-block-anchor-at-pos (pos)
  "Return a nearby block anchor for POS, preferring the preceding block.

Boundary positions such as trailing whitespace or blank separator lines should
resolve to the block immediately before point rather than jumping ahead into the
next block." 
  (save-excursion
    (goto-char pos)
    (or (beacon-preview--block-anchor-at-pos (point))
        (progn
          (skip-chars-backward " \t\n")
          (or (beacon-preview--block-anchor-at-pos (point))
              (when (> (point) (point-min))
                (beacon-preview--block-anchor-at-pos (1- (point)))))))))

(defun beacon-preview--edited-anchors ()
  "Return de-duplicated block anchors for recently edited positions."
  (when (beacon-preview--supported-source-mode-p)
    (let ((anchors nil))
      (dolist (pos beacon-preview--edited-positions (nreverse anchors))
        (when (and (integer-or-marker-p pos)
                   (<= (point-min) pos)
                   (<= pos (point-max)))
          (when-let ((anchor (beacon-preview--nearest-block-anchor-at-pos pos)))
            (unless (member anchor anchors)
              (push anchor anchors))))))))

(defun beacon-preview--jump-script (anchor &optional ratio block-progress flash-anchor)
  "Return JavaScript to jump to ANCHOR.

RATIO offsets the target by a fraction of the viewport height.  BLOCK-PROGRESS,
when non-nil, targets the corresponding fraction within ANCHOR's element.
FLASH-ANCHOR defaults to ANCHOR and controls which element is flashed."
  (format
   (concat "(function () {"
           "  var anchor = %s;"
           "  var ratio = %s;"
           "  var blockProgress = %s;"
           "  var flashAnchor = %s;"
           "  var retries = %d;"
           "  var retryDelay = %d;"
           "  function jump() {"
           "    var element = document.getElementById(anchor);"
           "    if (!element) {"
           "      if (retries > 0) {"
           "        retries -= 1;"
           "        window.setTimeout(jump, retryDelay);"
           "      }"
           "      return false;"
           "    }"
           "    var rect = element.getBoundingClientRect();"
           "    blockProgress = Math.max(0, Math.min(1, blockProgress));"
           "    var targetY = rect.top + window.scrollY + (rect.height * blockProgress) - (window.innerHeight * ratio);"
           "    window.scrollTo(0, Math.max(0, targetY));"
           "    if (window.BeaconPreview && typeof window.BeaconPreview.flashAnchor === 'function') {"
           "      window.BeaconPreview.flashAnchor(flashAnchor);"
           "    }"
           "    return true;"
           "  }"
           "  return jump();"
           "})();")
   (beacon-preview--js-string-literal anchor)
   (if ratio
       (format "%.10f" ratio)
     "0.0")
   (if block-progress
       (format "%.10f" block-progress)
     "0.0")
   (beacon-preview--js-string-literal (or flash-anchor anchor))
   beacon-preview-jump-retry-count
   beacon-preview-jump-retry-delay-ms))

(defun beacon-preview--preserve-scroll-script ()
  "Return JavaScript that reloads the preview while restoring its scroll position." 
  (concat
   "(function () {"
   "  try { sessionStorage.setItem('beacon-preview-scroll-y', String(window.scrollY || 0)); }"
   "  catch (_err) {}"
   "  window.location.reload();"
   "})();"))

(defun beacon-preview--restore-scroll-script ()
  "Return JavaScript that restores a preserved preview scroll position if any." 
  (concat
   "(function () {"
   "  var raw = null;"
   "  try { raw = sessionStorage.getItem('beacon-preview-scroll-y'); } catch (_err) {}"
   "  if (raw === null) { return false; }"
   "  var value = parseFloat(raw);"
   "  if (!Number.isFinite(value)) { return false; }"
   "  window.scrollTo(0, Math.max(0, value));"
   "  try { sessionStorage.removeItem('beacon-preview-scroll-y'); } catch (_err) {}"
   "  return true;"
   "})();"))

(defun beacon-preview--flash-visible-anchors-script (anchors)
  "Return JavaScript that flashes visible preview elements for ANCHORS."
  (format
   (concat
    "(function () {"
    "  var anchors = %s;"
    "  if (!window.BeaconPreview || typeof window.BeaconPreview.flashAnchorIfVisible !== 'function') {"
    "    return false;"
    "  }"
    "  anchors.forEach(function (anchor) {"
    "    window.BeaconPreview.flashAnchorIfVisible(anchor);"
    "  });"
    "  return true;"
    "})();")
   (json-encode anchors)))

(defun beacon-preview--visible-preview-entry-script ()
  "Return JavaScript that reports a visible preview beacon near viewport top.

The returned JSON includes a `ratio' field describing the selected beacon's
effective vertical position within the preview viewport, plus optional
`block_progress' when the viewport is inside a long block."
  (concat
   "(function () {"
   "  if (!window.BeaconPreview || typeof window.BeaconPreview.collectEntries !== 'function') {"
   "    return '';"
   "  }"
   "  var supported = {h1:true,h2:true,h3:true,h4:true,h5:true,h6:true,p:true,li:true,blockquote:true,pre:true,table:true};"
   "  var viewportHeight = Math.max(window.innerHeight || 0, 1);"
   "  function elementMetrics(element) {"
   "    if (!element) { return null; }"
   "    var rect = element.getBoundingClientRect();"
   "    var visibleTop = Math.max(rect.top, 0);"
   "    var visibleBottom = Math.min(rect.bottom, viewportHeight);"
   "    if (visibleBottom <= visibleTop) { return null; }"
   "    var visibleSpan = visibleBottom - visibleTop;"
   "    var startVisible = rect.top >= 0 && rect.top < viewportHeight;"
   "    var spansViewportTop = rect.top < 0 && rect.bottom > 0;"
   "    var blockProgress = spansViewportTop ? Math.min(Math.max((-rect.top) / Math.max(rect.height, 1), 0), 1) : 0;"
   "    var focusY = startVisible ? rect.top : visibleTop;"
   "    return {"
   "      rectTop: rect.top,"
   "      rectBottom: rect.bottom,"
    "      visibleTop: visibleTop,"
    "      visibleBottom: visibleBottom,"
    "      visibleSpan: visibleSpan,"
    "      focusY: focusY,"
    "      ratio: focusY / viewportHeight,"
   "      startVisible: startVisible,"
   "      spansViewportTop: spansViewportTop,"
   "      blockProgress: blockProgress"
    "    };"
   "  }"
   "  var starts = [];"
   "  var spanning = [];"
   "  var entries = window.BeaconPreview.collectEntries();"
   "  for (var i = 0; i < entries.length; i += 1) {"
   "    var entry = entries[i];"
   "    if (!entry || !supported[entry.kind]) { continue; }"
   "    var element = entry.element || document.getElementById(entry.anchor);"
   "    var metrics = elementMetrics(element);"
   "    if (!metrics) { continue; }"
   "    if (metrics.startVisible) {"
   "      starts.push({anchor: entry.anchor, kind: entry.kind, index: entry.index, ratio: metrics.ratio, block_progress: 0, rectTop: metrics.rectTop});"
   "    } else if (metrics.spansViewportTop) {"
   "      spanning.push({anchor: entry.anchor, kind: entry.kind, index: entry.index, ratio: metrics.ratio, block_progress: metrics.blockProgress, rectTop: metrics.rectTop});"
   "    }"
   "  }"
   "  starts.sort(function (a, b) { return a.rectTop - b.rectTop; });"
   "  spanning.sort(function (a, b) { return b.rectTop - a.rectTop; });"
   "  var best = starts[0] || spanning[0] || null;"
   "  return best ? JSON.stringify({anchor: best.anchor, kind: best.kind, index: best.index, ratio: best.ratio, block_progress: best.block_progress}) : '';"
   "})()"))

(defun beacon-preview--decode-visible-preview-entry (value)
  "Decode VALUE returned from preview JavaScript into a preview-entry-like alist."
  (when (and (stringp value)
             (not (string-empty-p value)))
    (condition-case nil
        (json-parse-string value :object-type 'alist :array-type 'list)
      (error nil))))

(defun beacon-preview--markdown-heading-entry-at-point ()
  "Return the Markdown heading tree-sitter entry at point, or nil."
  (beacon-preview--markdown-treesit-entry-at-pos
   (point)
   '("h1" "h2" "h3" "h4" "h5" "h6")))

(defun beacon-preview--markdown-current-heading-info ()
  "Return the nearest Markdown heading at or before point, including `:pos'."
  (beacon-preview--markdown-treesit-current-heading-info))

(defun beacon-preview--markdown-current-heading ()
  "Return the nearest Markdown heading text at or before point.

The search is intentionally small and predictable for the prototype."
  (when-let ((heading (beacon-preview--markdown-current-heading-info)))
    (list :level (plist-get heading :level)
          :text (plist-get heading :text))))

(defun beacon-preview--markdown-heading-occurrence (heading)
  "Return 1-based occurrence count for HEADING up to point.

HEADING is a plist with :level and :text."
  (beacon-preview--markdown-treesit-heading-occurrence heading))

(defun beacon-preview--pandoc-like-slug (text)
  "Convert TEXT into a simple Pandoc-like heading anchor.

This aims to be closer to Pandoc's generated heading identifiers."
  (let ((result nil)
        (pending-hyphen nil))
    (dolist (char (string-to-list (downcase (string-trim text))))
      (cond
       ((eq char ?-)
        (when result
          (push ?- result))
        (setq pending-hyphen nil))
       ((memq (char-syntax char) '(?\  ))
        (setq pending-hyphen (not (null result))))
       ((or (eq char ?_)
            (memq (get-char-code-property char 'general-category)
                  '(Ll Lm Lo Lt Lu Nd Nl No Mc Me Mn Pc)))
        (when pending-hyphen
          (push ?- result)
          (setq pending-hyphen nil))
        (push char result))
       (t nil)))
    (setq result (nreverse result))
    (string-trim (concat result) "-+" "-+")))

(defun beacon-preview-current-heading-anchor ()
  "Return the preview anchor for the current source heading context."
  (interactive)
  (unless (beacon-preview--supported-source-mode-p)
    (user-error "Current mode is not configured for source-side beacon lookup"))
  (let* ((org-mode-p (derived-mode-p 'org-mode))
         (heading (if org-mode-p
                      (beacon-preview--org-current-heading-info)
                    (beacon-preview--markdown-current-heading))))
    (unless heading
      (user-error "No heading found at or before point"))
    (let* ((resolved (beacon-preview--resolve-heading-anchor heading))
           (occurrence (if org-mode-p
                           (beacon-preview--org-heading-occurrence heading)
                         (beacon-preview--markdown-heading-occurrence heading)))
           (base-anchor (beacon-preview--pandoc-like-slug
                         (plist-get heading :text)))
           (anchor (or resolved
                       (if (> occurrence 1)
                           (format "%s-%d" base-anchor (1- occurrence))
                         base-anchor))))
      (when (called-interactively-p 'interactive)
        (message "%s" anchor))
      anchor)))

(defun beacon-preview--preview-entries-list ()
  "Return cached preview entries as a plain list."
  (and beacon-preview--preview-entries
       (append beacon-preview--preview-entries nil)))

(defun beacon-preview--resolve-heading-anchor (heading)
  "Resolve HEADING through the preview entries if possible."
  (let* ((kind (format "h%d" (plist-get heading :level)))
         (text (plist-get heading :text))
         (occurrence (if (derived-mode-p 'org-mode)
                         (beacon-preview--org-heading-occurrence heading)
                       (beacon-preview--markdown-heading-occurrence heading)))
         (matches nil))
    (dolist (entry (beacon-preview--preview-entries-list))
      (when (and (equal (alist-get 'kind entry) kind)
                 (equal (alist-get 'text entry) text))
        (push entry matches)))
    (setq matches (nreverse matches))
    (alist-get 'anchor (nth (1- occurrence) matches))))


(provide 'beacon-preview-render)

;;; beacon-preview-render.el ends here
