;;; beacon-preview.el --- Pandoc-backed xwidget preview for Markdown and Org -*- lexical-binding: t; -*-

;; Author: matoi
;; Maintainer: matoi
;; URL: https://github.com/matoi/beacon-preview
;; Keywords: hypermedia, tools, convenience
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; beacon-preview builds local HTML preview artifacts for Markdown and Org via
;; Pandoc, injects beacon metadata, and drives the resulting document inside an
;; Emacs xwidget buffer.
;;
;; Expected workflow:
;;
;; 1. Build HTML and manifest artifacts with scripts/build_preview.py
;; 2. Open that HTML in an xwidget webkit buffer
;; 3. Jump or flash block-level anchors from the source buffer
;; 4. Optionally sync back from the preview viewport to the source buffer

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'json)
(require 'org-element)
(require 'url-util)

(defgroup beacon-preview nil
  "Preview local beaconable HTML in xwidget."
  :group 'tools
  :prefix "beacon-preview-")

(defgroup beacon-preview-build nil
  "Build and external tool settings for beacon preview."
  :group 'beacon-preview)

(defgroup beacon-preview-automation nil
  "Automatic preview lifecycle settings for beacon preview."
  :group 'beacon-preview)

(defgroup beacon-preview-navigation nil
  "Source-to-preview navigation settings for beacon preview."
  :group 'beacon-preview)

(defgroup beacon-preview-display nil
  "Preview window and display-follow settings for beacon preview."
  :group 'beacon-preview)

(defgroup beacon-preview-debugging nil
  "Debugging settings for beacon preview."
  :group 'beacon-preview)

(defun beacon-preview--library-directory ()
  "Return the directory containing beacon-preview.el, or nil."
  (let ((library-file (or load-file-name
                          (ignore-errors
                            (find-library-name "beacon-preview")))))
    (when library-file
      (file-name-directory (expand-file-name library-file)))))

(defun beacon-preview--default-builder-script ()
  "Return the default path to build_preview.py."
  (if-let ((library-dir (beacon-preview--library-directory)))
      (expand-file-name "../scripts/build_preview.py" library-dir)
    "build_preview.py"))

(defcustom beacon-preview-open-function #'xwidget-webkit-browse-url
  "Function used to open a generated preview URL in a new xwidget session."
  :type 'function
  :group 'beacon-preview-display)

(defcustom beacon-preview-display-location 'side-window
  "Where `beacon-preview-mode' should show preview buffers.

`side-window' reuses or opens a preview in the current frame using
`beacon-preview-display-buffer-action'. `dedicated-frame' gives each source
buffer its own dedicated preview frame. `shared-dedicated-frame' reuses one
dedicated preview frame for all source buffers."
  :type '(choice (const :tag "Right side window" side-window)
                 (const :tag "One frame per preview buffer" dedicated-frame)
                 (const :tag "One shared preview frame" shared-dedicated-frame))
  :group 'beacon-preview-display)

(defcustom beacon-preview-python-command "python3"
  "Python executable used to run the preview builder script."
  :type 'string
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-command "pandoc"
  "Pandoc executable used by the preview builder script."
  :type 'string
  :group 'beacon-preview-build)

(defcustom beacon-preview-builder-script
  (beacon-preview--default-builder-script)
  "Path to the build_preview.py script."
  :type 'file
  :group 'beacon-preview-build)

(defcustom beacon-preview-display-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . right)
    (slot . 0)
    (window-width . 0.5)
    (inhibit-same-window . t))
  "Display action used for xwidget preview buffers.

The default reuses an existing preview window when possible and otherwise
opens the preview in a right side window without replacing the editing buffer.

This setting is used when `beacon-preview-display-location' is `side-window'."
  :type 'sexp
  :group 'beacon-preview-display)

(defcustom beacon-preview-dedicated-frame-parameters
  '((name . "beacon-preview"))
  "Frame parameters used when opening a preview in a dedicated frame.

This setting is used when `beacon-preview-display-location' is
`dedicated-frame'."
  :type 'alist
  :group 'beacon-preview-display)

(defcustom beacon-preview-temporary-root
  (expand-file-name "beacon-preview/" temporary-file-directory)
  "Root directory for internally managed temporary preview artifacts."
  :type 'directory
  :group 'beacon-preview-build)

(defcustom beacon-preview-source-modes '(markdown-mode gfm-mode org-mode)
  "Major modes where source-side preview helpers should be offered."
  :type '(repeat symbol)
  :group 'beacon-preview-automation)

(defcustom beacon-preview-auto-refresh-on-save t
  "Whether `beacon-preview-mode' should refresh preview artifacts on save."
  :type 'boolean
  :group 'beacon-preview-automation)

(defcustom beacon-preview-auto-refresh-on-revert t
  "Whether `beacon-preview-mode' should refresh preview artifacts after revert.

This covers cases such as external file changes being pulled into the current
buffer via `revert-buffer' or `auto-revert-mode'."
  :type 'boolean
  :group 'beacon-preview-automation)

(defcustom beacon-preview-auto-start-on-enable nil
  "Whether enabling `beacon-preview-mode' should automatically open a preview.

When non-nil, turning on `beacon-preview-mode' in a supported file-backed
buffer builds preview artifacts and opens the preview unless one is already
live. The default is nil so preview startup remains opt-in.

This option is available from `M-x customize-group RET beacon-preview RET'."
  :type 'boolean
  :group 'beacon-preview-automation)

(defcustom beacon-preview-refresh-jump-behavior 'block
  "How live preview refresh should treat preview position.

When set to `block', refresh follows the current source block or heading as
usual. When set to `preserve', refresh rebuilds and reloads the preview while
keeping the current preview scroll position when possible."
  :type '(choice (const :tag "Follow current block" block)
                 (const :tag "Preserve preview position" preserve))
  :group 'beacon-preview-navigation)

(defcustom beacon-preview-follow-window-display-changes nil
  "Whether live preview should follow source window display-position changes.

When non-nil, changes in the source window's visible region trigger a debounced
preview sync for an existing live preview."
  :type 'boolean
  :group 'beacon-preview-display)

(defcustom beacon-preview-reveal-hidden-preview-window nil
  "Whether source-driven preview updates may foreground a hidden preview window.

When nil, actions such as refresh reuse a tracked preview buffer only when that
preview is already visible or can be updated without reclaiming a side window
that is currently showing another buffer. Explicit preview-display commands such
as `beacon-preview-build-and-open' still show the preview window normally."
  :type 'boolean
  :group 'beacon-preview-display)

(defconst beacon-preview--behavior-style-presets
  '((default
     :refresh-jump-behavior block
     :follow-window-display-changes nil
     :reveal-hidden-preview-window nil)
    (live
     :refresh-jump-behavior block
     :follow-window-display-changes t
     :reveal-hidden-preview-window nil)
    (visible
     :refresh-jump-behavior block
     :follow-window-display-changes nil
     :reveal-hidden-preview-window t)
    (live-visible
     :refresh-jump-behavior block
     :follow-window-display-changes t
     :reveal-hidden-preview-window t)
    (preserve
     :refresh-jump-behavior preserve
     :follow-window-display-changes nil
     :reveal-hidden-preview-window nil))
  "Named behavior style presets for beacon preview.")

(defvar beacon-preview--applying-behavior-style nil
  "Non-nil while a beacon preview behavior style is being applied.")

(defun beacon-preview--behavior-style-spec-p (style)
  "Return non-nil when STYLE is a valid beacon preview behavior style spec."
  (and (listp style)
       (plist-member style :refresh-jump-behavior)
       (plist-member style :follow-window-display-changes)
       (plist-member style :reveal-hidden-preview-window)
       (memq (plist-get style :refresh-jump-behavior) '(block preserve))
       (booleanp (plist-get style :follow-window-display-changes))
       (booleanp (plist-get style :reveal-hidden-preview-window))))

(defun beacon-preview--behavior-style-spec (style)
  "Return normalized behavior style plist for STYLE or signal an error."
  (cond
   ((symbolp style)
    (or (cdr (assq style beacon-preview--behavior-style-presets))
        (user-error "Unknown beacon preview behavior style: %S" style)))
   ((beacon-preview--behavior-style-spec-p style)
    style)
   (t
    (user-error "Invalid beacon preview behavior style: %S" style))))

(defun beacon-preview--current-behavior-style-spec ()
  "Return current behavior settings as a normalized style plist."
  (list :refresh-jump-behavior beacon-preview-refresh-jump-behavior
        :follow-window-display-changes beacon-preview-follow-window-display-changes
        :reveal-hidden-preview-window beacon-preview-reveal-hidden-preview-window))

(defun beacon-preview--behavior-style-value (style)
  "Return canonical style value for STYLE.

Known presets are returned as their symbol names; other valid styles are
returned as normalized plists."
  (let ((spec (beacon-preview--behavior-style-spec style)))
    (or (car
         (seq-find
          (lambda (entry)
            (equal spec (cdr entry)))
          beacon-preview--behavior-style-presets))
        spec)))

(defun beacon-preview--set-option-value (symbol value &optional local)
  "Set SYMBOL to VALUE, optionally only in the current buffer when LOCAL."
  (if local
      (set (make-local-variable symbol) value)
    (set-default symbol value)))

(defun beacon-preview--set-behavior-style (style &optional local)
  "Apply behavior STYLE to the coordinated preview behavior settings.

When LOCAL is non-nil, update only the current buffer's local behavior values."
  (let ((spec (beacon-preview--behavior-style-spec style)))
    (let ((beacon-preview--applying-behavior-style t))
      (beacon-preview--set-option-value
       'beacon-preview-refresh-jump-behavior
       (plist-get spec :refresh-jump-behavior)
       local)
      (beacon-preview--set-option-value
       'beacon-preview-follow-window-display-changes
       (plist-get spec :follow-window-display-changes)
       local)
      (beacon-preview--set-option-value
       'beacon-preview-reveal-hidden-preview-window
       (plist-get spec :reveal-hidden-preview-window)
       local))
    (beacon-preview--set-option-value
     'beacon-preview-behavior-style
     (beacon-preview--behavior-style-value spec)
     local)))

(defun beacon-preview--behavior-style-setter (symbol value)
  "Custom setter for SYMBOL using behavior style VALUE."
  (set-default symbol (beacon-preview--behavior-style-value value))
  (unless beacon-preview--applying-behavior-style
    (beacon-preview--set-behavior-style value)))

(defun beacon-preview--sync-behavior-style (&optional local)
  "Update `beacon-preview-behavior-style' to match current behavior settings.

When LOCAL is non-nil, update only the current buffer's local style value."
  (unless beacon-preview--applying-behavior-style
    (beacon-preview--set-option-value
     'beacon-preview-behavior-style
     (beacon-preview--behavior-style-value
      (beacon-preview--current-behavior-style-spec))
     local)))

;;;###autoload
(defun beacon-preview-apply-behavior-style (style &optional local)
  "Apply beacon preview behavior STYLE.

STYLE may be one of the named presets `default', `live', `visible',
`live-visible', or `preserve', or an explicit plist accepted by
`beacon-preview-behavior-style'.

When LOCAL is non-nil, apply STYLE only in the current buffer. Interactive use
applies the style locally to the current buffer."
  (interactive
   (list
    (intern
     (completing-read
      "Behavior style: "
      '("default" "live" "visible" "live-visible" "preserve")
      nil
      t))
    t))
  (beacon-preview--set-behavior-style
   style
   (or local (called-interactively-p 'interactive)))
  (message "[beacon-preview] behavior style: %S"
           beacon-preview-behavior-style))

(defcustom beacon-preview-behavior-style 'default
  "High-level style that sets coordinated preview behavior in one place.

This controls these variables together:

- `beacon-preview-refresh-jump-behavior'
- `beacon-preview-follow-window-display-changes'
- `beacon-preview-reveal-hidden-preview-window'

You can use a named preset such as `default', `live', `visible',
`live-visible', or `preserve'. You can also provide an explicit plist style:

  (:refresh-jump-behavior preserve
   :follow-window-display-changes t
   :reveal-hidden-preview-window nil)"
  :type '(choice
          (const :tag "Default" default)
          (const :tag "Live follow" live)
          (const :tag "Visible preview" visible)
          (const :tag "Live follow + visible preview" live-visible)
          (const :tag "Preserve preview position" preserve)
          (sexp :tag "Custom style plist"))
  :set #'beacon-preview--behavior-style-setter
  :group 'beacon-preview)

(defcustom beacon-preview-display-follow-delay 0.05
  "Idle delay in seconds before syncing preview after source display changes."
  :type 'number
  :group 'beacon-preview-display)

(defcustom beacon-preview-post-open-sync-delay 0.05
  "Delay in seconds before applying a post-open preview position sync."
  :type 'number
  :group 'beacon-preview-display)

(defcustom beacon-preview-jump-retry-count 20
  "How many times the browser-side jump script should retry before giving up."
  :type 'integer
  :group 'beacon-preview-navigation)

(defcustom beacon-preview-jump-retry-delay-ms 50
  "Delay in milliseconds between browser-side jump retries."
  :type 'integer
  :group 'beacon-preview-navigation)

(defcustom beacon-preview-slow-build-message-threshold 0.5
  "Minimum build time in seconds before showing a completion message.

When a preview build takes at least this long, a message showing the elapsed
time is displayed in the echo area.  Faster builds clear the transient
\"building\" message silently.  Set to 0 to always show timing."
  :type 'number
  :group 'beacon-preview-debugging)

(defcustom beacon-preview-debug nil
  "Whether beacon preview should emit debug messages to `*Messages*'."
  :type 'boolean
  :group 'beacon-preview-debugging)

(defcustom beacon-preview-external-link-browser #'browse-url
  "Function used to open external links clicked in the preview.

Called with a single URL string argument. When non-nil, clicks on links that
navigate away from the current preview page are redirected to this function
instead of loading inside the xwidget, so the preview keeps its current view.
Set to nil to disable interception and let the xwidget follow links normally."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'beacon-preview-navigation)

(defconst beacon-preview--external-link-sentinel-prefix
  "about:blank?__beacon_preview_external__="
  "Prefix of the sentinel URL used to signal an outbound link click.")

(defvar beacon-preview--last-url nil
  "Last URL opened by beacon preview.")

(defvar beacon-preview--last-html-path nil
  "Path to the last generated preview HTML file.")

(defvar beacon-preview--manifest nil
  "Cached beacon manifest loaded from JSON.")

(defvar beacon-preview--manifest-path nil
  "Path of the currently loaded beacon manifest.")

(defvar-local beacon-preview--xwidget-buffer nil
  "Buffer showing the beacon preview via xwidget for the current source buffer.")

(defvar-local beacon-preview--preview-frame nil
  "Dedicated frame associated with the current source buffer's preview.")

(defvar beacon-preview--shared-preview-frame nil
  "Dedicated frame shared across all source buffers when configured.")

(defvar-local beacon-preview--source-buffer nil
  "Source buffer associated with a preview buffer.")

(defvar-local beacon-preview--pending-sync-script nil
  "Pending JavaScript to run after the current preview load finishes.")

(defvar-local beacon-preview--pending-sync-generation 0
  "Monotonic generation number for queued preview sync requests.")

(defvar-local beacon-preview--pending-sync-timer nil
  "Timer scheduled to execute the latest queued preview sync.")

(defvar-local beacon-preview--display-follow-timer nil
  "Idle timer used to debounce preview sync for source display changes.")

(defvar-local beacon-preview--last-window-start nil
  "Last observed `window-start' used for display-change tracking.")

(defvar-local beacon-preview--last-point nil
  "Last observed point used for display-change tracking.")

(defvar-local beacon-preview--edited-positions nil
  "Recently edited source positions collected since the last save/revert.")

(defvar-local beacon-preview--build-process nil
  "Active async build process for this source buffer.")

(defvar-local beacon-preview--ephemeral-source-id nil
  "Stable per-buffer identifier used for unvisited preview artifacts.")

(defvar-local beacon-preview--markdown-treesit-cache nil
  "Cached Markdown block entries derived from tree-sitter for the current buffer.")

(defvar-local beacon-preview--markdown-treesit-cache-tick nil
  "Buffer modification tick used to validate `beacon-preview--markdown-treesit-cache'.")

(defvar-local beacon-preview--org-element-cache nil
  "Cached Org structural entries derived from `org-element' for the current buffer.")

(defvar-local beacon-preview--org-element-cache-tick nil
  "Buffer modification tick used to validate `beacon-preview--org-element-cache'.")

(defvar beacon-preview-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'beacon-preview-dwim)
    (define-key map (kbd "s") #'beacon-preview-apply-behavior-style)
    (define-key map (kbd "t") #'beacon-preview-toggle-preview-display)
    (define-key map (kbd "p") #'beacon-preview-sync-source-to-preview)
    (define-key map (kbd "a") #'beacon-preview-jump-to-anchor)
    (define-key map (kbd "h") #'beacon-preview-flash-current-target)
    (define-key map (kbd "f") #'beacon-preview-toggle-refresh-jump-behavior)
    (define-key map (kbd "w") #'beacon-preview-toggle-follow-window-display-changes)
    (define-key map (kbd "v") #'beacon-preview-toggle-reveal-hidden-preview-window)
    (define-key map (kbd "d") #'beacon-preview-toggle-debug)
    map)
  "Prefix keymap for `beacon-preview-mode' commands.")

(defvar beacon-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-b") beacon-preview-command-map)
    map)
  "Keymap for `beacon-preview-mode'.")

(defun beacon-preview--debug (format-string &rest args)
  "Emit a beacon preview debug message using FORMAT-STRING and ARGS."
  (when beacon-preview-debug
    (apply #'message (concat "[beacon-preview] " format-string) args)))

;;;###autoload
(defun beacon-preview-toggle-debug (&optional arg)
  "Toggle beacon preview debug logging.

With prefix ARG, enable debug logging when ARG is positive, otherwise disable
it."
  (interactive "P")
  (setq beacon-preview-debug
        (if arg
            (> (prefix-numeric-value arg) 0)
          (not beacon-preview-debug)))
  (message "[beacon-preview] debug %s"
           (if beacon-preview-debug "enabled" "disabled")))

;;;###autoload
(defun beacon-preview-toggle-refresh-jump-behavior ()
  "Toggle refresh jumping between block-following and position-preserving modes."
  (interactive)
  (beacon-preview--set-option-value
   'beacon-preview-refresh-jump-behavior
   (if (eq beacon-preview-refresh-jump-behavior 'block)
       'preserve
     'block)
   t)
  (beacon-preview--sync-behavior-style t)
  (message "[beacon-preview] refresh jump behavior: %s"
           beacon-preview-refresh-jump-behavior))

;;;###autoload
(defun beacon-preview-toggle-follow-window-display-changes (&optional arg)
  "Toggle preview following for source window display-position changes.

With prefix ARG, enable display following when ARG is positive, otherwise
 disable it."
  (interactive "P")
  (beacon-preview--set-option-value
   'beacon-preview-follow-window-display-changes
   (if arg
       (> (prefix-numeric-value arg) 0)
     (not beacon-preview-follow-window-display-changes))
   t)
  (beacon-preview--sync-behavior-style t)
  (message "[beacon-preview] follow window display changes %s"
           (if beacon-preview-follow-window-display-changes
               "enabled"
             "disabled")))

;;;###autoload
(defun beacon-preview-toggle-reveal-hidden-preview-window (&optional arg)
  "Toggle whether source-driven updates may foreground a hidden preview window.

With prefix ARG, enable foregrounding when ARG is positive, otherwise disable
it. Explicit preview-display commands still show the preview window regardless
of this setting."
  (interactive "P")
  (beacon-preview--set-option-value
   'beacon-preview-reveal-hidden-preview-window
   (if arg
       (> (prefix-numeric-value arg) 0)
     (not beacon-preview-reveal-hidden-preview-window))
   t)
  (beacon-preview--sync-behavior-style t)
  (message "[beacon-preview] reveal hidden preview window %s"
           (if beacon-preview-reveal-hidden-preview-window
               "enabled"
             "disabled")))

(defun beacon-preview--supported-source-mode-p ()
  "Return non-nil when the current buffer is supported for source-side features."
  (apply #'derived-mode-p beacon-preview-source-modes))

(defun beacon-preview--ensure-xwidget-loaded ()
  "Load xwidget support if available, returning non-nil on success."
  (or (featurep 'xwidget)
      (require 'xwidget nil t)))

(defun beacon-preview--xwidget-available-p ()
  "Return non-nil when xwidget webkit preview is available."
  (and (beacon-preview--ensure-xwidget-loaded)
       (display-graphic-p)
       (featurep 'xwidget-internal)
       (fboundp 'xwidget-webkit-browse-url)
       (fboundp 'xwidget-webkit-current-session)
       (fboundp 'xwidget-webkit-goto-url)))

(defun beacon-preview--xwidget-session-for-buffer (preview-buffer &optional window)
  "Return the xwidget webkit session associated with PREVIEW-BUFFER.

Some Emacs xwidget setups only expose the current session reliably when the
preview buffer is the selected buffer in its window. When direct buffer-local
lookup returns nil, retry from WINDOW or from an already visible preview
window before concluding that the preview session is gone."
  (when (buffer-live-p preview-buffer)
    (or (with-current-buffer preview-buffer
          (xwidget-webkit-current-session))
        (when-let ((preview-window (or window
                                       (get-buffer-window preview-buffer t))))
          (save-selected-window
            (with-selected-window preview-window
              (switch-to-buffer preview-buffer)
              (xwidget-webkit-current-session)))))))

(defun beacon-preview--xwidget-session ()
  "Return the xwidget session for the current source buffer's preview."
  (beacon-preview--xwidget-session-for-buffer beacon-preview--xwidget-buffer))

(defun beacon-preview--live-preview-p ()
  "Return non-nil when the current source buffer has a live preview session."
  (and (buffer-live-p beacon-preview--xwidget-buffer)
       (beacon-preview--xwidget-session)))

(defun beacon-preview--file-url (file)
  "Return a file:// URL for FILE."
  (concat "file://" (expand-file-name file)))

(defun beacon-preview--current-anchor-maybe ()
  "Return the current source-correlated anchor when source-side lookup is applicable.

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

(defun beacon-preview--handle-external-link-sentinel (xwidget uri phase)
  "If URI on XWIDGET carries the external-link sentinel, dispatch and return t.

WebKit emits a `load-changed' event once for each navigation phase
\(`load-started', `load-committed', `load-finished'\). We want to intercept
every phase so the sentinel never reaches the default handler, but only
dispatch the click action once. PHASE is the WebKit phase string from
`last-input-event'; actions run only on `load-started'."
  (when (and beacon-preview-external-link-browser
             (beacon-preview--external-link-from-uri uri))
    (when (equal phase "load-started")
      (let ((external-url (beacon-preview--external-link-from-uri uri)))
        (beacon-preview--debug "external link intercepted: %S" external-url)
        (unless (string-empty-p external-url)
          (ignore-errors
            (funcall beacon-preview-external-link-browser external-url)))
        (ignore-errors
          (xwidget-webkit-execute-script xwidget "history.go(-1);"))))
    t))

(defun beacon-preview--xwidget-callback (xwidget event-type)
  "Handle XWIDGET EVENT-TYPE and run pending preview sync after load finishes."
  (let* ((uri (and (fboundp 'xwidget-webkit-uri)
                   (ignore-errors (xwidget-webkit-uri xwidget))))
         (phase (nth 3 last-input-event))
         (intercepted (and (eq event-type 'load-changed)
                           (beacon-preview--handle-external-link-sentinel
                            xwidget uri phase))))
    (unless intercepted
      (beacon-preview--xwidget-callback-default xwidget event-type))))

(defun beacon-preview--xwidget-callback-default (xwidget event-type)
  "Default handling for XWIDGET EVENT-TYPE when no sentinel is active."
  (xwidget-webkit-callback xwidget event-type)
  (unless (eq event-type 'javascript-callback)
    (beacon-preview--debug "xwidget callback event=%S detail=%S"
                           event-type
                           (nth 3 last-input-event)))
  (when (and (eq event-type 'load-changed)
             (string-equal (nth 3 last-input-event) "load-finished"))
    (with-current-buffer (xwidget-buffer xwidget)
      (when (buffer-live-p beacon-preview--source-buffer)
        (beacon-preview--label-preview-buffer
         (current-buffer)
         beacon-preview--source-buffer))
      (when beacon-preview-external-link-browser
        (ignore-errors
          (xwidget-webkit-execute-script
           xwidget
           (beacon-preview--external-link-interceptor-script))))
      (when beacon-preview--pending-sync-script
        (let ((script beacon-preview--pending-sync-script)
              (generation beacon-preview--pending-sync-generation))
          (beacon-preview--debug "load finished; running pending sync")
          (setq beacon-preview--pending-sync-script nil)
          (when (timerp beacon-preview--pending-sync-timer)
            (cancel-timer beacon-preview--pending-sync-timer))
          (setq beacon-preview--pending-sync-timer
                (run-at-time
                 beacon-preview-post-open-sync-delay
                 nil
                 (lambda ()
                   (when (buffer-live-p (xwidget-buffer xwidget))
                     (with-current-buffer (xwidget-buffer xwidget)
                       (when (= generation beacon-preview--pending-sync-generation)
                         (setq beacon-preview--pending-sync-timer nil)
                         (beacon-preview--debug
                          "executing pending sync script generation=%d"
                          generation)
                         (xwidget-webkit-execute-script
                          xwidget
                          script))))))))))))

(defun beacon-preview--install-xwidget-callback-for-session (session)
  "Install the beacon preview xwidget callback into xwidget SESSION."
  (when (and session
             (fboundp 'xwidget-put))
    (xwidget-put session 'callback #'beacon-preview--xwidget-callback)))

(defun beacon-preview--install-xwidget-callback (preview-buffer)
  "Install the beacon preview xwidget callback into PREVIEW-BUFFER."
  (when (buffer-live-p preview-buffer)
    (beacon-preview--install-xwidget-callback-for-session
     (beacon-preview--xwidget-session-for-buffer preview-buffer))))

(defun beacon-preview--queue-position-sync (preview-buffer anchor ratio)
  "Queue a post-load sync for PREVIEW-BUFFER to ANCHOR with optional RATIO."
  (when (and (buffer-live-p preview-buffer)
             anchor)
    (with-current-buffer preview-buffer
      (setq beacon-preview--pending-sync-generation
            (1+ beacon-preview--pending-sync-generation))
      (beacon-preview--debug "queue sync anchor=%S ratio=%S buffer=%s"
                             anchor ratio (buffer-name preview-buffer))
      (setq beacon-preview--pending-sync-script
            (beacon-preview--jump-script anchor ratio)))))

(defun beacon-preview--link-preview-buffers (source-buffer preview-buffer)
  "Record bidirectional lifecycle links between SOURCE-BUFFER and PREVIEW-BUFFER."
  (when (buffer-live-p source-buffer)
    (with-current-buffer source-buffer
      (setq beacon-preview--xwidget-buffer preview-buffer)
      (add-hook 'kill-buffer-hook #'beacon-preview--cleanup-preview-on-source-kill nil t)))
  (when (buffer-live-p preview-buffer)
    (with-current-buffer preview-buffer
      (setq beacon-preview--source-buffer source-buffer)
      (add-hook 'kill-buffer-hook #'beacon-preview--cleanup-source-on-preview-kill nil t))))

(defun beacon-preview--initialize-preview-buffer (source-buffer session anchor ratio)
  "Track xwidget SESSION for SOURCE-BUFFER and queue initial sync.

ANCHOR and RATIO describe the initial post-load position sync to request for the
new preview buffer. The xwidget callback must already be installed for SESSION."
  (let ((preview-buffer (and session (xwidget-buffer session))))
    (when (buffer-live-p preview-buffer)
      (beacon-preview--link-preview-buffers source-buffer preview-buffer)
      (beacon-preview--label-preview-buffer preview-buffer source-buffer)
      (beacon-preview--queue-position-sync preview-buffer anchor ratio))
    preview-buffer))

(defun beacon-preview--navigate-preview-session (preview-buffer window url anchor ratio)
  "Reload PREVIEW-BUFFER in WINDOW to URL and queue sync to ANCHOR at RATIO."
  (beacon-preview--queue-position-sync preview-buffer anchor ratio)
  (save-selected-window
    (if (window-live-p window)
        (with-selected-window window
          (set-window-buffer window preview-buffer)
          (xwidget-webkit-goto-url url))
      (with-current-buffer preview-buffer
        (xwidget-webkit-goto-url url)))))

(defun beacon-preview--restore-origin-context (window buffer)
  "Restore selected WINDOW and current BUFFER after preview operations."
  (when (window-live-p window)
    (select-window window 'norecord))
  (when (buffer-live-p buffer)
    (set-buffer buffer)))

(defun beacon-preview--source-window (&optional buffer)
  "Return a live window displaying BUFFER, preferring the selected window."
  (let ((buffer (or buffer (current-buffer))))
    (cond
     ((eq (window-buffer (selected-window)) buffer)
      (selected-window))
     (t
      (get-buffer-window buffer t)))))

(defun beacon-preview--context-source-buffer ()
  "Return the source buffer for the current beacon preview context, or nil."
  (cond
   ((and (beacon-preview--supported-source-mode-p)
         (buffer-live-p beacon-preview--xwidget-buffer))
    (current-buffer))
   ((buffer-live-p beacon-preview--source-buffer)
    beacon-preview--source-buffer)
   (t nil)))

(defun beacon-preview--context-preview-buffer ()
  "Return the preview buffer for the current beacon preview context, or nil."
  (cond
   ((buffer-live-p beacon-preview--xwidget-buffer)
    beacon-preview--xwidget-buffer)
   ((and (buffer-live-p beacon-preview--source-buffer)
         (eq major-mode 'xwidget-webkit-mode))
    (current-buffer))
   (t nil)))

(defun beacon-preview--show-source-buffer (source-buffer)
  "Select a window showing SOURCE-BUFFER, displaying it if needed."
  (let ((window (or (beacon-preview--source-window source-buffer)
                    (display-buffer source-buffer))))
    (unless (window-live-p window)
      (user-error "Could not display source buffer %s" (buffer-name source-buffer)))
    (select-window window)
    (switch-to-buffer source-buffer)
    window))

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

(defun beacon-preview--align-window-to-top (window)
  "Show point near the top of WINDOW."
  (with-selected-window window
    (recenter 0)))

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

(defun beacon-preview--manifest-entry-at-index (kind index)
  "Return the manifest entry for KIND at 1-based INDEX, or nil."
  (seq-find (lambda (entry)
              (and (equal (alist-get 'kind entry) kind)
                   (= (alist-get 'index entry) index)))
            (beacon-preview--manifest-entries)))

(defun beacon-preview--markdown-treesit-available-p ()
  "Return non-nil when tree-sitter Markdown parsing is available in this buffer."
  (and (derived-mode-p 'markdown-mode 'gfm-mode)
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
  "Return manifest heading kind string for Markdown heading NODE, or nil."
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

(defun beacon-preview--markdown-treesit-entry-kind (node)
  "Return manifest kind string for Markdown tree-sitter NODE, or nil."
  (or (beacon-preview--markdown-treesit-heading-kind node)
      (pcase (treesit-node-type node)
        ("paragraph"
         (let ((parent (treesit-node-parent node)))
           (unless (member (and parent (treesit-node-type parent))
                           '("list_item" "block_quote"))
             "p")))
        ("list_item" "li")
        ("block_quote" "blockquote")
        ("fenced_code_block" "pre")
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
             (when-let ((kind (beacon-preview--markdown-treesit-entry-kind node)))
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
  "Return cached Markdown tree-sitter entries for manifest KIND, or nil."
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

(defun beacon-preview--org-element-paragraph-suppressed-p (element)
  "Return non-nil when Org paragraph ELEMENT should not produce a beacon."
  (let ((parent (org-element-property :parent element))
        (suppressed nil))
    (while (and parent (not suppressed))
      (when (memq (org-element-type parent)
                  '(item quote-block src-block example-block table table-row table-cell))
        (setq suppressed t))
      (setq parent (org-element-property :parent parent)))
    suppressed))

(defun beacon-preview--org-element-kind (element)
  "Return manifest kind string for Org ELEMENT, or nil."
  (pcase (org-element-type element)
    (`headline
     (format "h%d" (org-element-property :level element)))
    (`item "li")
    (`paragraph
     (unless (beacon-preview--org-element-paragraph-suppressed-p element)
       "p"))
    (`quote-block "blockquote")
    ((or `src-block `example-block) "pre")
    (`table "table")
    (_ nil)))

(defun beacon-preview--org-element-entry-metadata (element kind)
  "Return extra metadata alist for Org ELEMENT of manifest KIND."
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
          '(headline item paragraph quote-block src-block example-block table)
        (lambda (element)
          (when-let ((kind (beacon-preview--org-element-kind element)))
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
  "Return cached Org entries for manifest KIND, or nil."
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
                        (manifest-entry
                         (beacon-preview--manifest-entry-at-index
                          (alist-get 'kind entry)
                          (alist-get 'index entry)))
                        (anchor (alist-get 'anchor manifest-entry)))
              anchor)))
       (t
        (or (when-let* ((entry (beacon-preview--markdown-treesit-entry-at-pos
                                pos
                                '("pre" "blockquote" "table" "li" "p")))
                        (manifest-entry
                         (beacon-preview--manifest-entry-at-index
                          (alist-get 'kind entry)
                         (alist-get 'index entry)))
                        (anchor (alist-get 'anchor manifest-entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-blockquote-index))
                        (entry (beacon-preview--manifest-entry-at-index "blockquote" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-table-index))
                        (entry (beacon-preview--manifest-entry-at-index "table" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-list-item-index))
                        (entry (beacon-preview--manifest-entry-at-index "li" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)
            (when-let* ((index (beacon-preview--markdown-paragraph-index))
                        (entry (beacon-preview--manifest-entry-at-index "p" index))
                        (anchor (alist-get 'anchor entry)))
              anchor)))))))

(defun beacon-preview-current-block-anchor ()
  "Return the current block anchor for point, or nil when none is resolved."
  (beacon-preview--block-anchor-at-pos (point)))

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
  "Return a source position for manifest KIND at 1-based INDEX, or nil."
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
  "Return a source block range plist for manifest KIND at 1-based INDEX, or nil."
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

(defun beacon-preview--apply-preview-entry-to-source (entry source-buffer)
  "Move SOURCE-BUFFER to the position identified by preview manifest ENTRY.

When ENTRY includes `block_progress', place point within the resolved source
block approximately by logical line.  Otherwise prefer the source block start
near the top of the window."
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
        (set-window-point window target)
        (ignore ratio)
        (beacon-preview--align-window-to-top window)
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
  "Return the manifest kind for ANCHOR, or nil when unknown."
  (when-let ((entry (seq-find (lambda (candidate)
                                (equal (alist-get 'anchor candidate) anchor))
                              (beacon-preview--manifest-entries))))
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

(defun beacon-preview--jump-script (anchor &optional ratio)
  "Return JavaScript to jump to ANCHOR, offset by RATIO of the viewport height."
  (format
   (concat "(function () {"
           "  var anchor = %S;"
           "  var ratio = %s;"
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
           "    var targetY = rect.top + window.scrollY - (window.innerHeight * ratio);"
           "    window.scrollTo(0, Math.max(0, targetY));"
           "    if (window.BeaconPreview && typeof window.BeaconPreview.flashAnchor === 'function') {"
           "      window.BeaconPreview.flashAnchor(anchor);"
           "    }"
           "    return true;"
           "  }"
           "  return jump();"
           "})();")
   anchor
   (if ratio
       (format "%.10f" ratio)
     "0.0")
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

(defun beacon-preview--record-edit (beg _end _length)
  "Record a recent edit beginning at BEG for later preview highlighting."
  (when beacon-preview-mode
    (push beg beacon-preview--edited-positions)))

(defun beacon-preview--display-follow-state-changed-p (window)
  "Return non-nil when tracked display state changed for WINDOW."
  (let ((window-start (window-start window))
        (point (point)))
    (prog1
        (or (not (equal beacon-preview--last-window-start window-start))
            (not (equal beacon-preview--last-point point)))
      (setq beacon-preview--last-window-start window-start)
      (setq beacon-preview--last-point point))))

(defun beacon-preview--sync-preview-to-display ()
  "Synchronize preview to the current source display position when possible."
  (when (and beacon-preview-follow-window-display-changes
             (beacon-preview--supported-source-mode-p)
             (beacon-preview--live-preview-p))
    (when-let ((anchor (beacon-preview--current-anchor-maybe)))
      (beacon-preview-jump-to-anchor anchor))))

(defun beacon-preview--schedule-display-follow ()
  "Schedule a debounced preview sync for source display changes." 
  (when (timerp beacon-preview--display-follow-timer)
    (cancel-timer beacon-preview--display-follow-timer))
  (setq beacon-preview--display-follow-timer
        (run-with-idle-timer
         beacon-preview-display-follow-delay
         nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq beacon-preview--display-follow-timer nil)
               (beacon-preview--sync-preview-to-display))))
         (current-buffer))))

(defun beacon-preview--post-command ()
  "Track source window display changes and optionally sync the preview." 
  (when (and beacon-preview-follow-window-display-changes
             (beacon-preview--supported-source-mode-p)
             (beacon-preview--live-preview-p))
    (when-let ((window (beacon-preview--source-window (current-buffer))))
      (when (beacon-preview--display-follow-state-changed-p window)
        (beacon-preview--schedule-display-follow)))))

(defun beacon-preview--preview-buffer-name (&optional source-buffer)
  "Return the desired preview buffer name for SOURCE-BUFFER."
  (let* ((buffer (or source-buffer (current-buffer)))
         (label (buffer-name buffer)))
    (format "*beacon-preview: %s*" label)))

(defun beacon-preview--label-preview-buffer (preview-buffer source-buffer)
  "Associate PREVIEW-BUFFER with SOURCE-BUFFER and rename it for clarity."
  (when (buffer-live-p preview-buffer)
    (beacon-preview--link-preview-buffers source-buffer preview-buffer)
    (with-current-buffer preview-buffer
      (rename-buffer (beacon-preview--preview-buffer-name source-buffer) t))))

(defun beacon-preview--refresh-preview-buffer-label (&optional source-buffer)
  "Rename SOURCE-BUFFER's tracked preview buffer to match the source label."
  (when-let* ((buffer (or source-buffer (current-buffer)))
              ((buffer-live-p buffer))
              (preview-buffer
               (buffer-local-value 'beacon-preview--xwidget-buffer buffer))
              ((buffer-live-p preview-buffer)))
    (beacon-preview--label-preview-buffer preview-buffer buffer)))

(defun beacon-preview--after-set-visited-file-name ()
  "Refresh the tracked preview name after the current source buffer changes file."
  (beacon-preview--refresh-preview-buffer-label))

(defun beacon-preview--after-rename-buffer (&rest _args)
  "Refresh the tracked preview name after a source buffer is renamed."
  (beacon-preview--refresh-preview-buffer-label))

(unless (advice-member-p #'beacon-preview--after-rename-buffer 'rename-buffer)
  (advice-add 'rename-buffer :after #'beacon-preview--after-rename-buffer))

(defun beacon-preview--dedicated-frame-parameters ()
  "Return frame parameters for a dedicated beacon preview frame."
  (append beacon-preview-dedicated-frame-parameters
          '((beacon-preview-dedicated . t))))

(defun beacon-preview--live-preview-frame (&optional source-buffer)
  "Return the live dedicated preview frame configured for SOURCE-BUFFER, or nil."
  (pcase beacon-preview-display-location
    ('shared-dedicated-frame
     (when (frame-live-p beacon-preview--shared-preview-frame)
       beacon-preview--shared-preview-frame))
    (_
     (when-let ((buffer (or source-buffer (current-buffer))))
       (with-current-buffer buffer
         (when (frame-live-p beacon-preview--preview-frame)
           beacon-preview--preview-frame))))))

(defun beacon-preview--remember-preview-frame (source-buffer frame)
  "Record FRAME as SOURCE-BUFFER's dedicated preview frame."
  (when (frame-live-p frame)
    (if (eq beacon-preview-display-location 'shared-dedicated-frame)
        (setq beacon-preview--shared-preview-frame frame)
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (setq beacon-preview--preview-frame frame))))))

(defun beacon-preview--cleanup-preview-frame (source-buffer preview-buffer)
  "Hide or delete SOURCE-BUFFER's package-managed frame showing PREVIEW-BUFFER."
  (when (buffer-live-p source-buffer)
    (with-current-buffer source-buffer
      (let ((preview-frame (beacon-preview--live-preview-frame source-buffer)))
        (when (and (frame-live-p preview-frame)
                   (frame-parameter preview-frame 'beacon-preview-dedicated)
                   (eq (window-buffer (frame-root-window preview-frame)) preview-buffer))
          (pcase beacon-preview-display-location
            ('dedicated-frame
             (setq beacon-preview--preview-frame nil)
             (delete-frame preview-frame t))
            ('shared-dedicated-frame
             (make-frame-invisible preview-frame))))))))

(defun beacon-preview--show-preview-buffer-in-dedicated-frame (preview-buffer)
  "Display PREVIEW-BUFFER in the current source buffer's dedicated preview frame."
  (or (get-buffer-window preview-buffer t)
      (let* ((source-buffer (current-buffer))
             (frame (or (beacon-preview--live-preview-frame source-buffer)
                        (make-frame (beacon-preview--dedicated-frame-parameters))))
             (window (frame-root-window frame)))
        (beacon-preview--remember-preview-frame source-buffer frame)
        (set-window-buffer window preview-buffer)
        window)))

(defun beacon-preview--show-preview-buffer (preview-buffer)
  "Display PREVIEW-BUFFER in a user-visible window."
  (pcase beacon-preview-display-location
    ((or 'dedicated-frame 'shared-dedicated-frame)
     (beacon-preview--show-preview-buffer-in-dedicated-frame preview-buffer))
    (_
      (display-buffer preview-buffer beacon-preview-display-buffer-action))))

(defun beacon-preview--cleanup-preview-on-source-kill ()
  "Close the tracked preview when its source buffer is being killed."
  (when-let* ((preview-buffer beacon-preview--xwidget-buffer)
              ((buffer-live-p preview-buffer)))
    (beacon-preview--cleanup-preview-frame (current-buffer) preview-buffer)
    (with-current-buffer preview-buffer
      (setq beacon-preview--source-buffer nil))
    (setq beacon-preview--xwidget-buffer nil)
    (kill-buffer preview-buffer)))

(defun beacon-preview--cleanup-source-on-preview-kill ()
  "Clear source-side preview bookkeeping when a tracked preview buffer is killed."
  (let ((preview-buffer (current-buffer))
        (source-buffer beacon-preview--source-buffer))
    (setq beacon-preview--source-buffer nil)
    (when (buffer-live-p source-buffer)
      (beacon-preview--cleanup-preview-frame source-buffer preview-buffer)
      (with-current-buffer source-buffer
        (when (eq beacon-preview--xwidget-buffer preview-buffer)
          (setq beacon-preview--xwidget-buffer nil))))))

(defun beacon-preview--tracked-preview-window (&optional preview-buffer)
  "Return a live window already showing PREVIEW-BUFFER, or nil."
  (when-let ((buffer (or preview-buffer beacon-preview--xwidget-buffer)))
    (get-buffer-window buffer t)))

(defun beacon-preview--should-show-preview-window-p (&optional explicit preview-buffer)
  "Return non-nil when PREVIEW-BUFFER should be foregrounded for this action.

EXPLICIT is non-nil for commands that intentionally display the preview window.
Source-driven updates honor `beacon-preview-reveal-hidden-preview-window' and
avoid reclaiming a preview display that is currently showing another buffer."
  (or explicit
      beacon-preview-reveal-hidden-preview-window
      (not (buffer-live-p preview-buffer))
      (beacon-preview--tracked-preview-window preview-buffer)))

(defun beacon-preview--sanitized-buffer-base-name (&optional buffer)
  "Return a filesystem-friendly artifact base name for BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (raw-name (string-trim (buffer-name buffer)))
         (sanitized (replace-regexp-in-string "[^[:alnum:]._+-]+" "-" raw-name)))
    (or (and (not (string-empty-p sanitized))
             (string-trim sanitized "-+" "-+"))
        "buffer")))

(defun beacon-preview--source-artifact-base-name (&optional source)
  "Return the artifact base name for SOURCE.

SOURCE may be a buffer or a source file path string."
  (let* ((buffer (and (bufferp source) source))
         (source-file (cond
                       ((stringp source) source)
                       (buffer (buffer-file-name buffer))
                       (t (buffer-file-name (current-buffer))))))
    (if source-file
        (file-name-base (expand-file-name source-file))
      (beacon-preview--sanitized-buffer-base-name (or buffer (current-buffer))))))

(defun beacon-preview--source-identity (&optional source)
  "Return a stable identity string for SOURCE preview artifacts.

SOURCE may be a buffer or a source file path string."
  (let* ((buffer (and (bufferp source) source))
         (source-file (cond
                       ((stringp source) source)
                       (buffer (buffer-file-name buffer))
                       (t (buffer-file-name (current-buffer))))))
    (if source-file
        (expand-file-name source-file)
      (with-current-buffer (or buffer (current-buffer))
        (or beacon-preview--ephemeral-source-id
            (setq-local
             beacon-preview--ephemeral-source-id
             (format "buffer:%s:%s:%s"
                     (emacs-pid)
                     (buffer-name (current-buffer))
                     (substring
                      (secure-hash 'sha1
                                   (format "%s:%s:%s"
                                           (buffer-name (current-buffer))
                                           (float-time)
                                           (random)))
                      0
                      12))))))))

(defun beacon-preview--source-temp-directory (&optional source)
  "Return the internal temporary directory for SOURCE preview artifacts."
  (let* ((source-hash (secure-hash 'sha1 (beacon-preview--source-identity source)))
         (base-name (beacon-preview--source-artifact-base-name source))
         (root (file-name-as-directory
                 (expand-file-name beacon-preview-temporary-root))))
    (expand-file-name (format "%s-%s" base-name (substring source-hash 0 12))
                      root)))

(defun beacon-preview--artifact-paths (&optional source)
  "Return plist of output artifact paths for SOURCE."
  (let* ((base (beacon-preview--source-artifact-base-name source))
         (output-dir (beacon-preview--source-temp-directory source)))
    (list :html (expand-file-name (format "%s.html" base) output-dir)
          :manifest (expand-file-name (format "%s.json" base) output-dir))))

(defun beacon-preview--snapshot-extension (&optional buffer)
  "Return the temporary source snapshot extension appropriate for BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((buffer-file-name)
      (concat "." (or (file-name-extension (buffer-file-name)) "txt")))
     ((derived-mode-p 'org-mode)
      ".org")
     ((derived-mode-p 'markdown-mode 'gfm-mode)
      ".md")
     (t
      (user-error
       "Current buffer is not visiting a file and mode %s is not supported for preview snapshots"
       major-mode)))))

(defun beacon-preview--prepare-build-source (&optional buffer)
  "Return build metadata for BUFFER's current preview source.

The returned plist includes:

- `:input-file' for the file passed to the builder
- `:output-dir' for generated artifacts
- `:base-name' for output artifact naming
- `:default-directory' for running the builder
- `:ephemeral' when the input is a temporary buffer snapshot"
  (let* ((buffer (or buffer (current-buffer)))
         (source-file (buffer-file-name buffer))
         (output-dir (beacon-preview--source-temp-directory buffer))
         (base-name (beacon-preview--source-artifact-base-name buffer))
         (default-dir (or (and source-file (file-name-directory source-file))
                          default-directory)))
    (make-directory output-dir t)
    (if source-file
        (list :input-file (expand-file-name source-file)
              :output-dir output-dir
              :base-name base-name
              :default-directory default-dir
              :ephemeral nil)
      (let ((snapshot-file
             (expand-file-name
              (format "%s-source%s"
                      base-name
                      (beacon-preview--snapshot-extension buffer))
              output-dir)))
        (with-current-buffer buffer
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (point-min) (point-max) snapshot-file nil 'silent)))
        (list :input-file snapshot-file
              :output-dir output-dir
              :base-name base-name
              :default-directory default-dir
              :ephemeral t)))))

(defun beacon-preview--open-preview (file &optional anchor explicit)
  "Open FILE as a beacon preview in xwidget, optionally targeting ANCHOR.

When EXPLICIT is non-nil, the preview window may be shown or reclaimed even if
it is currently hidden behind another buffer."
  (unless (beacon-preview--xwidget-available-p)
    (user-error
     (concat
      "xwidget-webkit preview is unavailable; "
      "this Emacs must be built with xwidgets and running in a graphical session")))
  (let* ((source-buffer (current-buffer))
         (origin-buffer (current-buffer))
         (source-window (beacon-preview--source-window source-buffer))
         (origin-window (selected-window))
         (target-source-position (beacon-preview--target-source-position-maybe))
         (raw-ratio (and anchor
                          source-window
                          target-source-position
                          (beacon-preview--window-visible-ratio-for-pos
                           source-window
                           target-source-position)))
         (ratio (and raw-ratio
                     (beacon-preview--effective-window-ratio raw-ratio)))
         (url (if ratio
                  (beacon-preview--file-url file)
                (beacon-preview--preview-url file anchor)))
         (preview-buffer beacon-preview--xwidget-buffer)
         (opening-buffer (unless preview-buffer
                           (generate-new-buffer
                            (format " *beacon-preview-opening: %s*"
                                    (buffer-name source-buffer)))))
         (show-preview-window
          (beacon-preview--should-show-preview-window-p explicit preview-buffer))
         (visible-preview-window
          (and (buffer-live-p preview-buffer)
               (beacon-preview--tracked-preview-window preview-buffer)))
         (window (and show-preview-window
                      (beacon-preview--show-preview-buffer
                       (or preview-buffer opening-buffer))))
         (session (and (or show-preview-window visible-preview-window)
                       (beacon-preview--xwidget-session-for-buffer
                        preview-buffer
                        (or window visible-preview-window)))))
    (beacon-preview--debug
     "open-preview anchor=%S target-pos=%S raw-ratio=%S ratio=%S url=%s explicit=%S show-window=%S visible-window=%S"
     anchor target-source-position raw-ratio ratio url explicit show-preview-window visible-preview-window)
    (setq beacon-preview--last-url url)
    (setq beacon-preview--last-html-path (expand-file-name file))
    (unwind-protect
        (if session
            (progn
              (beacon-preview--install-xwidget-callback-for-session session)
              (beacon-preview--navigate-preview-session
               preview-buffer window url anchor ratio))
          (when show-preview-window
            (save-selected-window
              (with-selected-window window
                (funcall beacon-preview-open-function url t)
                (let ((created-session
                       (or (and (boundp 'xwidget-webkit-last-session)
                                xwidget-webkit-last-session)
                           (xwidget-webkit-current-session))))
                  (when created-session
                    (beacon-preview--install-xwidget-callback-for-session
                     created-session)
                    (setq preview-buffer
                          (beacon-preview--initialize-preview-buffer
                           source-buffer
                           created-session
                           anchor
                           ratio))))))))
      (when (and (buffer-live-p opening-buffer)
                 (not (eq opening-buffer preview-buffer)))
        (kill-buffer opening-buffer))
      (beacon-preview--restore-origin-context origin-window origin-buffer))))

;;;###autoload
(defun beacon-preview-load-manifest (file)
  "Load FILE as the active beacon manifest."
  (interactive "fBeacon manifest JSON: ")
  (setq beacon-preview--manifest-path (expand-file-name file))
  (setq beacon-preview--manifest
        (condition-case err
            (json-read-file beacon-preview--manifest-path)
          (error
           (user-error "Failed to load manifest %s: %s"
                       beacon-preview--manifest-path
                       (error-message-string err)))))
  beacon-preview--manifest)

;;;###autoload
(defun beacon-preview-clear-manifest ()
  "Clear the cached beacon manifest."
  (interactive)
  (setq beacon-preview--manifest nil)
  (setq beacon-preview--manifest-path nil))

(defun beacon-preview--command-available-p (command)
  "Return non-nil when COMMAND appears runnable in the current environment."
  (cond
   ((or (null command) (string-empty-p command)) nil)
   ((file-name-absolute-p command)
    (file-executable-p command))
   ((file-name-directory command)
    (file-executable-p (expand-file-name command default-directory)))
   (t
    (not (null (executable-find command))))))

(defun beacon-preview--build-error-message (output-buffer)
  "Return a concise build error message using OUTPUT-BUFFER contents."
  (with-current-buffer (get-buffer-create output-buffer)
    (goto-char (point-min))
    (let ((line (string-trim
                 (or (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position))
                     ""))))
      (if (string-empty-p line)
          (format "Preview build failed; see %s for details" output-buffer)
        (format "Preview build failed: %s" line)))))

(defun beacon-preview--validate-build-prerequisites ()
  "Signal a user error unless all build prerequisites are available."
  (unless (beacon-preview--command-available-p beacon-preview-python-command)
    (user-error "Python executable not found: %s" beacon-preview-python-command))
  (unless (file-exists-p (expand-file-name beacon-preview-builder-script))
    (user-error "Preview builder script not found: %s" beacon-preview-builder-script))
  (unless (beacon-preview--command-available-p beacon-preview-pandoc-command)
    (user-error "Pandoc executable not found: %s" beacon-preview-pandoc-command)))

(defun beacon-preview--build-args ()
  "Return the argument list for the builder process.

Also validates prerequisites and prepares the build source.  The returned
plist includes `:program', `:args', `:html', `:manifest', and
`:default-directory'."
  (beacon-preview--validate-build-prerequisites)
  (let* ((build-source (beacon-preview--prepare-build-source))
         (source-file (plist-get build-source :input-file))
         (artifacts (beacon-preview--artifact-paths))
         (html-path (plist-get artifacts :html))
         (manifest-path (plist-get artifacts :manifest))
         (base-name (plist-get build-source :base-name))
         (builder-script (expand-file-name beacon-preview-builder-script))
         (output-dir (plist-get build-source :output-dir)))
    (list :program beacon-preview-python-command
          :args (list builder-script
                     "--input" source-file
                     "--output-dir" output-dir
                     "--name" base-name
                     "--pandoc" beacon-preview-pandoc-command)
          :html html-path
          :manifest manifest-path
          :default-directory (plist-get build-source :default-directory))))

;;;###autoload
(defun beacon-preview-build-current-file ()
  "Build preview artifacts for the current source buffer synchronously.

Returns a plist with `:html' and `:manifest' paths."
  (interactive)
  (let* ((build (beacon-preview--build-args))
         (html-path (plist-get build :html))
         (manifest-path (plist-get build :manifest))
         (default-directory (plist-get build :default-directory))
         (output-buffer "*beacon-preview-build*")
         (exit-code
          (condition-case err
              (apply #'call-process
                     (plist-get build :program)
                     nil output-buffer nil
                     (plist-get build :args))
            (file-missing
             (user-error "Failed to start preview builder: %s"
                         (error-message-string err))))))
    (unless (and (integerp exit-code) (zerop exit-code))
      (pop-to-buffer output-buffer)
      (user-error "%s" (beacon-preview--build-error-message output-buffer)))
    (setq beacon-preview--last-html-path html-path)
    (beacon-preview-load-manifest manifest-path)
    (when (called-interactively-p 'interactive)
      (message "Built preview: %s" html-path))
    (list :html html-path :manifest manifest-path)))

(defun beacon-preview--build-current-file-async (callback)
  "Build preview artifacts asynchronously, then call CALLBACK.

CALLBACK receives one argument: a plist with `:html' and `:manifest' paths,
or nil on failure.  Any previously running async build for this source buffer
is killed first."
  (let* ((build (beacon-preview--build-args))
         (html-path (plist-get build :html))
         (manifest-path (plist-get build :manifest))
         (default-directory (plist-get build :default-directory))
         (source-buffer (current-buffer))
         (output-buffer (generate-new-buffer " *beacon-preview-build-async*"))
         (start-time (current-time)))
    ;; Kill any in-flight build for this source buffer.
    (when (and beacon-preview--build-process
               (process-live-p beacon-preview--build-process))
      (delete-process beacon-preview--build-process))
    (condition-case err
        (let ((process
               (apply #'start-process
                      "beacon-preview-build"
                      output-buffer
                      (plist-get build :program)
                      (plist-get build :args))))
          (setq beacon-preview--build-process process)
          (set-process-sentinel
           process
           (lambda (proc event)
             (when (buffer-live-p source-buffer)
               (with-current-buffer source-buffer
                 (when (eq beacon-preview--build-process proc)
                   (setq beacon-preview--build-process nil))))
             (unwind-protect
                 (cond
                  ((not (eq (process-status proc) 'exit))
                   (beacon-preview--debug "async build interrupted: %s"
                                          (string-trim event))
                   (funcall callback nil))
                  ((not (zerop (process-exit-status proc)))
                   (when (buffer-live-p source-buffer)
                     (with-current-buffer source-buffer
                       (message "[beacon-preview] build failed (exit %d)"
                                (process-exit-status proc))))
                   (funcall callback nil))
                  (t
                   (when (buffer-live-p source-buffer)
                     (with-current-buffer source-buffer
                       (setq beacon-preview--last-html-path html-path)
                       (beacon-preview-load-manifest manifest-path)
                       (beacon-preview--build-message-finish start-time)))
                   (funcall callback (list :html html-path
                                           :manifest manifest-path))))
               (when (buffer-live-p output-buffer)
                 (kill-buffer output-buffer))))))
      (file-missing
       (kill-buffer output-buffer)
       (user-error "Failed to start preview builder: %s"
                   (error-message-string err))))))

(defun beacon-preview--after-save ()
  "Refresh the current preview after saving the source buffer."
  (unwind-protect
      (when (and beacon-preview-auto-refresh-on-save
                 (beacon-preview--supported-source-mode-p)
                 (buffer-file-name))
        (beacon-preview-build-and-refresh))
    (setq beacon-preview--edited-positions nil)))

(defun beacon-preview--after-revert ()
  "Refresh the current preview after reverting the source buffer.

This is intended to catch externally modified files once their updated contents
have been loaded into the current buffer, but only when a live preview session
is already open for the current source buffer."
  (setq beacon-preview--edited-positions nil)
  (when (and beacon-preview-auto-refresh-on-revert
             (beacon-preview--supported-source-mode-p)
             (buffer-file-name)
             (beacon-preview--live-preview-p))
    (beacon-preview-build-and-refresh)))

(defun beacon-preview--maybe-auto-start ()
  "Automatically start preview for the current buffer when configured.

Auto-start is limited to supported source buffers and skips buffers that already
have a live preview session."
  (when (and beacon-preview-auto-start-on-enable
             (beacon-preview--supported-source-mode-p)
             (not (beacon-preview--live-preview-p)))
    (beacon-preview-build-and-open)))

(defun beacon-preview--build-message-start ()
  "Show a transient building message and return the current time."
  (message "[beacon-preview] building...")
  (current-time))

(defun beacon-preview--build-message-finish (start-time)
  "Show or clear the build message based on elapsed time since START-TIME."
  (let ((elapsed (float-time (time-subtract (current-time) start-time))))
    (if (>= elapsed beacon-preview-slow-build-message-threshold)
        (message "[beacon-preview] preview ready (%.1fs)" elapsed)
      (message nil))))

(defun beacon-preview-build-and-open ()
  "Build preview artifacts asynchronously and open the HTML preview."
  (beacon-preview--build-message-start)
  (let ((source-buffer (current-buffer)))
    (beacon-preview--build-current-file-async
     (lambda (artifacts)
       (when (and artifacts (buffer-live-p source-buffer))
         (with-current-buffer source-buffer
           (let* ((html-path (plist-get artifacts :html))
                  (anchor (beacon-preview--current-anchor-maybe)))
             (beacon-preview--open-preview html-path anchor t))))))))

(defun beacon-preview--refresh-with-artifacts (artifacts source-buffer
                                                         live edited-anchors)
  "Refresh the preview in SOURCE-BUFFER using ARTIFACTS.

LIVE, and EDITED-ANCHORS are the pre-build state captured by the caller."
  (when (and artifacts (buffer-live-p source-buffer))
    (with-current-buffer source-buffer
      (let* ((html-path (plist-get artifacts :html))
             (anchor (and live
                          (beacon-preview--live-preview-p)
                          (eq beacon-preview-refresh-jump-behavior 'block)
                          (beacon-preview--current-anchor-maybe)))
             (flash-script (and edited-anchors
                                (beacon-preview--flash-visible-anchors-script
                                 edited-anchors))))
        (when (beacon-preview--live-preview-p)
          (if (eq beacon-preview-refresh-jump-behavior 'preserve)
              (progn
                (setq beacon-preview--last-html-path html-path)
                (with-current-buffer beacon-preview--xwidget-buffer
                  (setq beacon-preview--pending-sync-generation
                        (1+ beacon-preview--pending-sync-generation))
                  (setq beacon-preview--pending-sync-script
                        (if flash-script
                            (concat
                             (beacon-preview--restore-scroll-script)
                             flash-script)
                          (beacon-preview--restore-scroll-script))))
                (beacon-preview--execute-script
                 (beacon-preview--preserve-scroll-script)))
            (beacon-preview--open-preview html-path anchor)
            (when (and flash-script
                       (null anchor)
                       (beacon-preview--live-preview-p))
              (with-current-buffer beacon-preview--xwidget-buffer
                (setq beacon-preview--pending-sync-generation
                      (1+ beacon-preview--pending-sync-generation))
                (setq beacon-preview--pending-sync-script flash-script)))))))))

(defun beacon-preview-build-and-refresh ()
  "Build preview artifacts asynchronously and refresh a live preview.

This only refreshes a preview that is already open; it never creates a new
preview window.  When `beacon-preview-refresh-jump-behavior' is `preserve',
refresh keeps the preview's current scroll position instead of jumping to the
current source block.  Save-triggered refreshes also flash recently edited
preview blocks when those targets remain visible after refresh."
  (let ((live (beacon-preview--live-preview-p))
        (source-buffer (current-buffer))
        (edited-anchors (and (beacon-preview--live-preview-p)
                             (beacon-preview--edited-anchors))))
    (beacon-preview--build-message-start)
    (beacon-preview--build-current-file-async
     (lambda (artifacts)
       (beacon-preview--refresh-with-artifacts
        artifacts source-buffer live edited-anchors)))))

;;;###autoload
(defun beacon-preview-dwim ()
  "Build, open, or jump the preview for the current source buffer.

When no live preview exists, build artifacts and open the preview.  When a
live preview is already available, jump it to the current source block."
  (interactive)
  (if (beacon-preview--live-preview-p)
      (beacon-preview-jump-to-current-block)
    (beacon-preview-build-and-open)))

;;;###autoload
(defun beacon-preview-switch-to-preview ()
  "Select the current source buffer's preview buffer.

If no preview is live yet for the current source buffer, start one first."
  (interactive)
  (if (buffer-live-p beacon-preview--xwidget-buffer)
      (beacon-preview--show-preview-buffer beacon-preview--xwidget-buffer)
    (beacon-preview-build-and-open)))

(defun beacon-preview--hide-preview-display ()
  "Hide the current source buffer's visible preview display."
  (unless (buffer-live-p beacon-preview--xwidget-buffer)
    (user-error "No live preview buffer is associated with this source buffer"))
  (let ((preview-window
         (beacon-preview--tracked-preview-window beacon-preview--xwidget-buffer)))
    (unless (window-live-p preview-window)
      (user-error "Preview is not currently visible"))
    (let* ((preview-frame (beacon-preview--live-preview-frame (current-buffer)))
           (window-frame (window-frame preview-window)))
      (if (and (frame-live-p preview-frame)
               (eq window-frame preview-frame))
          (make-frame-invisible window-frame)
        (delete-window preview-window)))))

;;;###autoload
(defun beacon-preview-toggle-preview-display ()
  "Toggle visibility of the current source buffer's preview display.

If no preview is live yet for the current source buffer, start one first."
  (interactive)
  (cond
   ((not (buffer-live-p beacon-preview--xwidget-buffer))
    (beacon-preview-build-and-open))
   ((beacon-preview--tracked-preview-window beacon-preview--xwidget-buffer)
    (beacon-preview--hide-preview-display))
   (t
    (beacon-preview-switch-to-preview))))

(defun beacon-preview--current-session ()
  "Return the current xwidget webkit session or signal a user error."
  (or (beacon-preview--xwidget-session)
      (user-error "No active xwidget webkit session found")))

(defun beacon-preview--execute-script (script)
  "Execute JavaScript SCRIPT in the current preview session."
  (xwidget-webkit-execute-script
   (beacon-preview--current-session)
   script))

(defun beacon-preview--visible-preview-entry-script ()
  "Return JavaScript that reports a visible preview beacon near viewport top.

The returned JSON includes a `ratio' field describing the selected beacon's
effective vertical position within the preview viewport, plus optional
`block_progress' when the viewport is inside a long block."
  (concat
   "(function () {"
   "  if (!window.BeaconPreview || !Array.isArray(window.BeaconPreview.manifest)) {"
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
   "  for (var i = 0; i < window.BeaconPreview.manifest.length; i += 1) {"
   "    var entry = window.BeaconPreview.manifest[i];"
   "    if (!entry || !supported[entry.kind]) { continue; }"
   "    var element = document.getElementById(entry.anchor);"
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
  "Decode VALUE returned from preview JavaScript into a manifest-like alist."
  (when (and (stringp value)
             (not (string-empty-p value)))
    (condition-case nil
        (json-parse-string value :object-type 'alist :array-type 'list)
      (error nil))))

;;;###autoload
(defun beacon-preview-sync-source-to-preview ()
  "Move the source buffer to a simple visible block currently shown in preview.

This is a first reverse-sync step: it asks the live preview for a visible
beacon entry using a simple viewport heuristic, then moves the corresponding
source buffer to that block or heading."
  (interactive)
  (let* ((source-buffer (beacon-preview--context-source-buffer))
         (preview-buffer (beacon-preview--context-preview-buffer)))
    (unless (buffer-live-p source-buffer)
      (user-error "No source buffer is associated with the current context"))
    (unless (buffer-live-p preview-buffer)
      (user-error "No live preview buffer is associated with the current context"))
    (let ((session (beacon-preview--xwidget-session-for-buffer preview-buffer)))
      (unless session
        (user-error "No active xwidget webkit session found"))
      (xwidget-webkit-execute-script
       session
       (beacon-preview--visible-preview-entry-script)
       (lambda (value)
         (let ((entry (beacon-preview--decode-visible-preview-entry value)))
           (if (not entry)
               (message "[beacon-preview] no visible preview beacon found")
             (condition-case err
                 (progn
                   (beacon-preview--apply-preview-entry-to-source entry source-buffer)
                   (message "[beacon-preview] synced source to preview %s #%s"
                            (alist-get 'kind entry)
                            (alist-get 'index entry)))
               (error
                (message "[beacon-preview] failed to sync source to preview: %s"
                         (error-message-string err)))))))))))

;;;###autoload
(defun beacon-preview-jump-to-anchor (anchor)
  "Jump the current preview to ANCHOR using the injected BeaconPreview API."
  (interactive "sAnchor: ")
  (let* ((source-window (beacon-preview--source-window (current-buffer)))
         (target-source-position (beacon-preview--target-source-position-maybe))
         (raw-ratio (and source-window
                         target-source-position
                         (beacon-preview--window-visible-ratio-for-pos
                          source-window
                          target-source-position)))
         (ratio (and raw-ratio
                     (beacon-preview--effective-window-ratio raw-ratio))))
    (beacon-preview--debug
     "jump-to-anchor anchor=%S target-pos=%S raw-ratio=%S ratio=%S"
     anchor target-source-position raw-ratio ratio)
    (beacon-preview--execute-script
     (beacon-preview--jump-script anchor ratio))))

;;;###autoload
(defun beacon-preview-flash-current-target ()
  "Flash the current source-correlated target in the live preview."
  (interactive)
  (unless (beacon-preview--live-preview-p)
    (user-error "No live preview is associated with the current buffer"))
  (let ((anchor (beacon-preview--current-anchor-maybe)))
    (unless anchor
      (user-error "No current block or heading anchor found at point"))
    (beacon-preview--execute-script
     (format
      (concat "(function () {"
              "  if (!window.BeaconPreview || typeof window.BeaconPreview.flashAnchor !== 'function') {"
              "    return false;"
              "  }"
              "  return window.BeaconPreview.flashAnchor(%S);"
              "})();")
      anchor))))

;;;###autoload
(defun beacon-preview-jump-to-index (kind index)
  "Jump the current preview to beacon KIND at INDEX."
  (interactive
   (list
    (completing-read
     "Kind: "
     '("h1" "h2" "h3" "h4" "h5" "h6" "p" "li" "blockquote" "pre" "table" "div")
     nil
     t)
    (read-number "Index: " 1)))
  (beacon-preview--execute-script
   (format
    (concat "(function () {"
            " if (!window.BeaconPreview) { return false; }"
            " return window.BeaconPreview.jumpToIndex(%S, %d);"
            "})();")
    kind
    index)))

;;;###autoload
(defun beacon-preview-reload ()
  "Reload the current beacon preview."
  (interactive)
  (beacon-preview--execute-script "window.location.reload();"))

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

(defun beacon-preview--manifest-entries ()
  "Return cached manifest entries as a plain list."
  (and beacon-preview--manifest
       (append beacon-preview--manifest nil)))

(defun beacon-preview--resolve-heading-anchor (heading)
  "Resolve HEADING through the loaded manifest if possible."
  (let* ((kind (format "h%d" (plist-get heading :level)))
         (text (plist-get heading :text))
         (occurrence (if (derived-mode-p 'org-mode)
                         (beacon-preview--org-heading-occurrence heading)
                       (beacon-preview--markdown-heading-occurrence heading)))
         (matches nil))
    (dolist (entry (beacon-preview--manifest-entries))
      (when (and (equal (alist-get 'kind entry) kind)
                 (equal (alist-get 'text entry) text))
        (push entry matches)))
    (setq matches (nreverse matches))
    (alist-get 'anchor (nth (1- occurrence) matches))))

(defun beacon-preview-jump-to-current-heading ()
  "Jump preview to the anchor derived from the current Markdown heading."
  (beacon-preview-jump-to-anchor
   (beacon-preview-current-heading-anchor)))

(defun beacon-preview-jump-to-current-block ()
  "Jump preview to the current source block anchor.

This prefers block-level anchors such as fenced code blocks, blockquotes,
tables, list items, and paragraphs. When no block anchor can be resolved, it
falls back to the current heading anchor."
  (unless (beacon-preview--supported-source-mode-p)
    (user-error "Current mode is not configured for source-side beacon lookup"))
  (let ((anchor (or (beacon-preview-current-block-anchor)
                    (ignore-errors (beacon-preview-current-heading-anchor)))))
    (unless anchor
      (user-error "No current block or heading anchor found at point"))
    (beacon-preview-jump-to-anchor anchor)))

;;;###autoload
(define-minor-mode beacon-preview-mode
  "Minor mode for beacon preview integration in source buffers."
  :lighter " Beacon"
  :keymap beacon-preview-mode-map
  (if beacon-preview-mode
      (progn
        (setq beacon-preview--last-window-start nil)
        (setq beacon-preview--last-point nil)
        (setq beacon-preview--edited-positions nil)
        (add-hook 'after-save-hook #'beacon-preview--after-save nil t)
        (add-hook 'after-revert-hook #'beacon-preview--after-revert nil t)
        (add-hook 'after-set-visited-file-name-hook
                  #'beacon-preview--after-set-visited-file-name nil t)
        (add-hook 'kill-buffer-hook #'beacon-preview--cleanup-preview-on-source-kill nil t)
        (add-hook 'after-change-functions #'beacon-preview--record-edit nil t)
        (add-hook 'post-command-hook #'beacon-preview--post-command nil t)
        (beacon-preview--maybe-auto-start))
    (remove-hook 'after-save-hook #'beacon-preview--after-save t)
    (remove-hook 'after-revert-hook #'beacon-preview--after-revert t)
    (remove-hook 'after-set-visited-file-name-hook
                 #'beacon-preview--after-set-visited-file-name t)
    (remove-hook 'after-change-functions #'beacon-preview--record-edit t)
    (remove-hook 'post-command-hook #'beacon-preview--post-command t)
    (when (timerp beacon-preview--display-follow-timer)
      (cancel-timer beacon-preview--display-follow-timer))
    (setq beacon-preview--display-follow-timer nil)
    (setq beacon-preview--edited-positions nil)))

(provide 'beacon-preview)

;;; beacon-preview.el ends here
