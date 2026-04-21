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
;; 1. Build HTML artifacts with Pandoc
;; 2. Open that HTML in an xwidget webkit buffer
;; 3. Jump or flash block-level anchors from the source buffer
;; 4. Optionally sync back from the preview viewport to the source buffer

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

(declare-function xwidget-webkit-browse-url "xwidget")
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-webkit-goto-url "xwidget")
(declare-function xwidget-webkit-execute-script "xwidget")
(declare-function xwidget-webkit-callback "xwidget")
(declare-function xwidget-webkit-uri "xwidget")
(declare-function url-retrieve "url")
(declare-function url-retrieve-synchronously "url")

(defvar xwidget-webkit-last-session)
(defvar url-http-end-of-headers)
(defvar beacon-preview-mode)
(defvar beacon-preview-behavior-style)
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

(defgroup beacon-preview-flash nil
  "Flash highlight appearance for beacon preview."
  :group 'beacon-preview)

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

(defcustom beacon-preview-pandoc-command "pandoc"
  "Pandoc executable used to render preview HTML."
  :type 'string
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-server-host "127.0.0.1"
  "Host used for `pandoc server' requests."
  :type 'string
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-server-port 3030
  "Port used for `pandoc server' requests."
  :type 'integer
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-server-timeout 2
  "Timeout in seconds used when starting `pandoc server'."
  :type 'integer
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-server-auto-start t
  "Whether beacon preview should start `pandoc server' on demand."
  :type 'boolean
  :group 'beacon-preview-build)
(defcustom beacon-preview-pandoc-server-startup-deadline 10.0
  "Maximum seconds to wait for a managed `pandoc server' to become reachable."
  :type 'number
  :group 'beacon-preview-build)


(defun beacon-preview--string-list-p (value)
  "Return non-nil when VALUE is nil or a list of strings."
  (or (null value)
      (and (listp value)
           (seq-every-p #'stringp value))))

(defun beacon-preview--optional-string-p (value)
  "Return non-nil when VALUE is nil or a string."
  (or (null value)
      (stringp value)))

(defconst beacon-preview--build-setting-keys
  '(:pandoc-template-file
    :pandoc-css-files
    :mermaid-script-file
    :body-wrapper-class)
  "Build setting keys accepted by beacon preview build config plists.")

(defun beacon-preview--build-settings-plist-p (value)
  "Return non-nil when VALUE is a valid build settings plist."
  (when (listp value)
    (let ((tail value)
          (valid t))
      (while (and valid tail)
        (let ((key (car tail))
              (setting (cadr tail)))
          (setq valid
                (and (keywordp key)
                     (memq key beacon-preview--build-setting-keys)
                     (pcase key
                       (:pandoc-css-files (beacon-preview--string-list-p setting))
                       (:pandoc-template-file (beacon-preview--optional-string-p setting))
                       (:mermaid-script-file (beacon-preview--optional-string-p setting))
                       (:body-wrapper-class (beacon-preview--optional-string-p setting))
                       (_ nil))))
          (setq tail (cddr tail))))
      valid)))

(defcustom beacon-preview-build-settings nil
  "Optional structured build settings for preview HTML.

Supported keys are `:pandoc-template-file', `:pandoc-css-files',
`:mermaid-script-file', and `:body-wrapper-class'.  This can be set globally or
locally, and more specific local values override broader defaults."
  :type '(choice (const :tag "No structured overrides" nil)
                 (sexp :tag "Build settings plist"))
  :group 'beacon-preview-build)
(put 'beacon-preview-build-settings 'safe-local-variable
     #'beacon-preview--build-settings-plist-p)

(defcustom beacon-preview-build-settings-by-source-kind nil
  "Alist of default build settings plists keyed by source kind.

Recognized source kinds are `markdown' and `org'.  Each value is a plist
accepted by `beacon-preview-build-settings'."
  :type '(alist :key-type (choice (const markdown) (const org))
                :value-type sexp)
  :group 'beacon-preview-build)

(defcustom beacon-preview-build-settings-by-major-mode nil
  "Alist of default build settings plists keyed by major mode symbols.

Each key should be a major mode symbol such as `markdown-mode', `gfm-mode',
`markdown-ts-mode', or `org-mode'.  Each value is a plist accepted by
`beacon-preview-build-settings'.  When both source-kind and major-mode
defaults apply, the major-mode entry wins."
  :type '(alist :key-type symbol
                :value-type sexp)
  :group 'beacon-preview-build)

(defcustom beacon-preview-pandoc-template-file nil
  "Optional Pandoc template file used for preview HTML builds.

When nil, beacon preview uses Pandoc's built-in HTML template.  When set to an
existing file, the build passes `--template' to Pandoc."
  :type '(choice (const :tag "Use Pandoc default template" nil)
                 file)
  :group 'beacon-preview-build)
(put 'beacon-preview-pandoc-template-file 'safe-local-variable
     #'beacon-preview--optional-string-p)

(defcustom beacon-preview-pandoc-css-files nil
  "Optional CSS files to include in preview HTML builds.

Each existing file is injected as a stylesheet link in the generated preview
HTML.  Missing files are ignored so CSS enhancements remain optional."
  :type '(repeat file)
  :group 'beacon-preview-build)
(put 'beacon-preview-pandoc-css-files 'safe-local-variable
     #'beacon-preview--string-list-p)

(defcustom beacon-preview-mermaid-script-file nil
  "Optional Mermaid runtime JavaScript file for preview HTML.

When set to an existing file, beacon preview injects script tags into the
generated HTML so Mermaid blocks can render in the preview browser.  Missing
files are ignored."
  :type '(choice (const :tag "Disabled" nil)
                 file)
  :group 'beacon-preview-build)
(put 'beacon-preview-mermaid-script-file 'safe-local-variable
     #'beacon-preview--optional-string-p)

(defcustom beacon-preview-body-wrapper-class nil
  "Optional CSS class applied to a single wrapper around preview body content.

When non-nil, the HTML postprocess step wraps the body contents in one
`article' element carrying this class.  This is useful for wrapper-scoped CSS
such as `github-markdown-css'."
  :type '(choice (const :tag "No wrapper" nil)
                 string)
  :group 'beacon-preview-build)
(put 'beacon-preview-body-wrapper-class 'safe-local-variable
     #'beacon-preview--optional-string-p)

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

(defcustom beacon-preview-source-modes '(markdown-mode gfm-mode markdown-ts-mode org-mode)
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

(defconst beacon-preview--flash-style-keys
  '(:enabled
    :subtle-color :subtle-peak-color :subtle-duration-ms
    :strong-color :strong-peak-color
    :strong-outline-color :strong-outline-peak-color :strong-outline-width-px
    :strong-duration-ms
    :border-radius :easing)
  "All keys understood by `beacon-preview-flash-style' plists.")

(defconst beacon-preview--flash-style-presets
  '((default
     :enabled t
     :subtle-color "rgba(255, 235, 120, 0.12)"
     :subtle-peak-color "rgba(255, 235, 120, 0.24)"
     :subtle-duration-ms 1050
     :strong-color "rgba(255, 235, 120, 0.22)"
     :strong-peak-color "rgba(255, 235, 120, 0.42)"
     :strong-outline-color "rgba(255, 196, 0, 0.18)"
     :strong-outline-peak-color "rgba(255, 196, 0, 0.3)"
     :strong-outline-width-px 2
     :strong-duration-ms 1250
     :border-radius "0.2rem"
     :easing "ease-out")
    (light
     :enabled t
     :subtle-color "rgba(245, 158, 11, 0.10)"
     :subtle-peak-color "rgba(245, 158, 11, 0.22)"
     :subtle-duration-ms 1050
     :strong-color "rgba(245, 158, 11, 0.18)"
     :strong-peak-color "rgba(245, 158, 11, 0.34)"
     :strong-outline-color "rgba(217, 119, 6, 0.22)"
     :strong-outline-peak-color "rgba(217, 119, 6, 0.36)"
     :strong-outline-width-px 2
     :strong-duration-ms 1250
     :border-radius "0.2rem"
     :easing "ease-out")
    (dark
     :enabled t
     :subtle-color "rgba(125, 211, 252, 0.14)"
     :subtle-peak-color "rgba(125, 211, 252, 0.28)"
     :subtle-duration-ms 1050
     :strong-color "rgba(125, 211, 252, 0.24)"
     :strong-peak-color "rgba(125, 211, 252, 0.44)"
     :strong-outline-color "rgba(56, 189, 248, 0.28)"
     :strong-outline-peak-color "rgba(56, 189, 248, 0.5)"
     :strong-outline-width-px 2
     :strong-duration-ms 1250
     :border-radius "0.2rem"
     :easing "ease-out")
    (none
     :enabled nil
     :subtle-color "transparent"
     :subtle-peak-color "transparent"
     :subtle-duration-ms 0
     :strong-color "transparent"
     :strong-peak-color "transparent"
     :strong-outline-color "transparent"
     :strong-outline-peak-color "transparent"
     :strong-outline-width-px 0
     :strong-duration-ms 0
     :border-radius "0"
     :easing "linear"))
  "Built-in flash style presets for beacon preview.")

(defcustom beacon-preview-flash-style-user-presets nil
  "Alist of user-defined flash style presets.

Each entry is `(NAME . PLIST)' where NAME is a symbol and PLIST may
contain any subset of the keys listed in
`beacon-preview--flash-style-keys'. Missing keys fall back to the
`default' built-in preset. User presets shadow built-ins of the same
name."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'beacon-preview-flash)

(defvar beacon-preview--applying-flash-style nil
  "Non-nil while a beacon preview flash style is being applied.")

(defun beacon-preview--flash-style-default-spec ()
  "Return the resolved `default' flash style preset plist."
  (cdr (assq 'default beacon-preview--flash-style-presets)))

(defun beacon-preview--flash-style-merge (overrides)
  "Return the `default' preset overlaid with OVERRIDES plist."
  (let ((spec (copy-sequence (beacon-preview--flash-style-default-spec))))
    (let ((tail overrides))
      (while tail
        (setq spec (plist-put spec (car tail) (cadr tail)))
        (setq tail (cddr tail))))
    spec))

(defun beacon-preview--flash-style-plist-p (value)
  "Return non-nil when VALUE is a plist of flash style keys."
  (and (listp value)
       (cl-evenp (length value))
       (let ((tail value)
             (ok t))
         (while (and ok tail)
           (unless (memq (car tail) beacon-preview--flash-style-keys)
             (setq ok nil))
           (setq tail (cddr tail)))
         ok)))

(defun beacon-preview--flash-style-spec (style)
  "Return normalized flash style plist for STYLE or signal an error."
  (cond
   ((symbolp style)
    (let ((entry (or (assq style beacon-preview-flash-style-user-presets)
                     (assq style beacon-preview--flash-style-presets))))
      (unless entry
        (user-error "Unknown beacon preview flash style: %S" style))
      (beacon-preview--flash-style-merge (cdr entry))))
   ((beacon-preview--flash-style-plist-p style)
    (beacon-preview--flash-style-merge style))
   (t
    (user-error "Invalid beacon preview flash style: %S" style))))

(defun beacon-preview--flash-style-known-names ()
  "Return list of known flash style preset names (user + built-in)."
  (delete-dups
   (append (mapcar #'car beacon-preview-flash-style-user-presets)
           (mapcar #'car beacon-preview--flash-style-presets))))

(defun beacon-preview--current-flash-style-spec ()
  "Return the current flash style as a normalized plist."
  (list :enabled beacon-preview-flash-enabled
        :subtle-color beacon-preview-flash-subtle-color
        :subtle-peak-color beacon-preview-flash-subtle-peak-color
        :subtle-duration-ms beacon-preview-flash-subtle-duration-ms
        :strong-color beacon-preview-flash-strong-color
        :strong-peak-color beacon-preview-flash-strong-peak-color
        :strong-outline-color beacon-preview-flash-strong-outline-color
        :strong-outline-peak-color beacon-preview-flash-strong-outline-peak-color
        :strong-outline-width-px beacon-preview-flash-strong-outline-width-px
        :strong-duration-ms beacon-preview-flash-strong-duration-ms
        :border-radius beacon-preview-flash-border-radius
        :easing beacon-preview-flash-easing))

(defun beacon-preview--flash-style-value (style)
  "Return canonical value (preset symbol or normalized plist) for STYLE."
  (let ((spec (beacon-preview--flash-style-spec style)))
    (or (car
         (seq-find
          (lambda (entry)
            (equal spec (beacon-preview--flash-style-merge (cdr entry))))
          (append beacon-preview-flash-style-user-presets
                  beacon-preview--flash-style-presets)))
        spec)))

(defun beacon-preview--set-flash-style (style &optional local)
  "Apply flash STYLE to the individual flash defcustoms.

When LOCAL is non-nil, update only the current buffer's local values."
  (let ((spec (beacon-preview--flash-style-spec style))
        (beacon-preview--applying-flash-style t))
    (dolist (pair '((:enabled . beacon-preview-flash-enabled)
                    (:subtle-color . beacon-preview-flash-subtle-color)
                    (:subtle-peak-color . beacon-preview-flash-subtle-peak-color)
                    (:subtle-duration-ms . beacon-preview-flash-subtle-duration-ms)
                    (:strong-color . beacon-preview-flash-strong-color)
                    (:strong-peak-color . beacon-preview-flash-strong-peak-color)
                    (:strong-outline-color . beacon-preview-flash-strong-outline-color)
                    (:strong-outline-peak-color . beacon-preview-flash-strong-outline-peak-color)
                    (:strong-outline-width-px . beacon-preview-flash-strong-outline-width-px)
                    (:strong-duration-ms . beacon-preview-flash-strong-duration-ms)
                    (:border-radius . beacon-preview-flash-border-radius)
                    (:easing . beacon-preview-flash-easing)))
      (beacon-preview--set-option-value
       (cdr pair) (plist-get spec (car pair)) local))
    (beacon-preview--set-option-value
     'beacon-preview-flash-style
     (beacon-preview--flash-style-value spec)
     local)))

(defun beacon-preview--flash-style-setter (symbol value)
  "Custom setter for SYMBOL using flash style VALUE."
  (set-default symbol (beacon-preview--flash-style-value value))
  (unless beacon-preview--applying-flash-style
    (beacon-preview--set-flash-style value)))

(defun beacon-preview--flash-customs-fully-bound-p ()
  "Return non-nil once every flash per-property defcustom has a binding."
  (and (boundp 'beacon-preview-flash-enabled)
       (boundp 'beacon-preview-flash-subtle-color)
       (boundp 'beacon-preview-flash-subtle-peak-color)
       (boundp 'beacon-preview-flash-subtle-duration-ms)
       (boundp 'beacon-preview-flash-strong-color)
       (boundp 'beacon-preview-flash-strong-peak-color)
       (boundp 'beacon-preview-flash-strong-outline-color)
       (boundp 'beacon-preview-flash-strong-outline-peak-color)
       (boundp 'beacon-preview-flash-strong-outline-width-px)
       (boundp 'beacon-preview-flash-strong-duration-ms)
       (boundp 'beacon-preview-flash-border-radius)
       (boundp 'beacon-preview-flash-easing)))

(defun beacon-preview--sync-flash-style ()
  "Update `beacon-preview-flash-style' to match current per-property values."
  (when (and (not beacon-preview--applying-flash-style)
             (beacon-preview--flash-customs-fully-bound-p))
    (set-default
     'beacon-preview-flash-style
     (beacon-preview--flash-style-value
      (beacon-preview--current-flash-style-spec)))))

(defun beacon-preview--flash-property-setter (symbol value)
  "Set SYMBOL to VALUE and resync `beacon-preview-flash-style'."
  (set-default symbol value)
  (beacon-preview--sync-flash-style))

(defun beacon-preview--flash-style-default (key)
  "Return the value of KEY in the `default' flash style preset."
  (plist-get (beacon-preview--flash-style-default-spec) key))

(defcustom beacon-preview-flash-enabled
  (beacon-preview--flash-style-default :enabled)
  "Whether preview jump/sync should flash the target element."
  :type 'boolean
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-subtle-color
  (beacon-preview--flash-style-default :subtle-color)
  "Steady CSS background color for the subtle flash variant."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-subtle-peak-color
  (beacon-preview--flash-style-default :subtle-peak-color)
  "Peak (0%% keyframe) CSS background color for the subtle flash variant."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-subtle-duration-ms
  (beacon-preview--flash-style-default :subtle-duration-ms)
  "Duration in milliseconds of the subtle flash animation."
  :type 'integer
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-color
  (beacon-preview--flash-style-default :strong-color)
  "Steady CSS background color for the strong flash variant."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-peak-color
  (beacon-preview--flash-style-default :strong-peak-color)
  "Peak CSS background color for the strong flash variant."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-outline-color
  (beacon-preview--flash-style-default :strong-outline-color)
  "Steady CSS color for the strong flash inset outline."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-outline-peak-color
  (beacon-preview--flash-style-default :strong-outline-peak-color)
  "Peak CSS color for the strong flash inset outline."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-outline-width-px
  (beacon-preview--flash-style-default :strong-outline-width-px)
  "Width in pixels of the strong flash inset outline."
  :type 'integer
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-strong-duration-ms
  (beacon-preview--flash-style-default :strong-duration-ms)
  "Duration in milliseconds of the strong flash animation."
  :type 'integer
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-border-radius
  (beacon-preview--flash-style-default :border-radius)
  "CSS border-radius applied to flashed elements."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

(defcustom beacon-preview-flash-easing
  (beacon-preview--flash-style-default :easing)
  "CSS animation timing function used for both flash variants."
  :type 'string
  :set #'beacon-preview--flash-property-setter
  :group 'beacon-preview-flash)

;;;###autoload
(defun beacon-preview-apply-flash-style (style &optional local)
  "Apply beacon preview flash STYLE.

STYLE may be a built-in preset (`default', `light', `dark', `none'), a
user-registered preset from `beacon-preview-flash-style-user-presets',
or an explicit plist accepted by `beacon-preview-flash-style'.

When LOCAL is non-nil, apply STYLE only in the current buffer.
Interactive use applies the style locally to the current buffer.

Note: the flash style is baked into the injected preview script when the
preview is built, so existing previews must be rebuilt for changes to
take effect."
  (interactive
   (list
    (intern
     (completing-read
      "Flash style: "
      (mapcar #'symbol-name (beacon-preview--flash-style-known-names))
      nil t))
    t))
  (beacon-preview--set-flash-style
   style
   (or local (called-interactively-p 'interactive)))
  (message "[beacon-preview] flash style: %S" beacon-preview-flash-style))

(defcustom beacon-preview-flash-style 'default
  "High-level style controlling the preview flash highlight appearance.

Acceptable values:

- A built-in preset symbol: `default', `light', `dark', or `none'.
- A symbol registered in `beacon-preview-flash-style-user-presets'.
- An explicit plist with any subset of the keys in
  `beacon-preview--flash-style-keys'; missing keys inherit from the
  `default' preset.

Setting this option keeps all `beacon-preview-flash-*' per-property
defcustoms in sync. Conversely, editing any individual property will
flip this option to a matching preset symbol or to a normalized plist.

The flash style is baked into the injected preview script at render
time, so previews must be rebuilt for changes to take effect."
  :type '(choice
          (const :tag "Default (yellow)" default)
          (const :tag "Light (amber)" light)
          (const :tag "Dark (cyan)" dark)
          (const :tag "None (disabled)" none)
          (symbol :tag "User preset name")
          (sexp :tag "Custom style plist"))
  :set #'beacon-preview--flash-style-setter
  :group 'beacon-preview-flash)

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

(defvar-local beacon-preview--preview-html-cache nil
  "Cached preview HTML entries for the current source buffer.")

(defvar-local beacon-preview--xwidget-buffer nil
  "Buffer showing the beacon preview via xwidget for the current source buffer.")

(defvar-local beacon-preview--last-build-tick nil
  "Buffer modification tick recorded for the most recent preview build.")

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

(defvar-local beacon-preview--build-request-buffer nil
  "Active async HTTP retrieval buffer for this source buffer.")

(defvar-local beacon-preview--ephemeral-source-id nil
  "Stable per-buffer identifier used for unvisited preview artifacts.")

(defvar-local beacon-preview--markdown-treesit-cache nil
  "Cached Markdown block entries derived from tree-sitter for the current buffer.")

(defvar-local beacon-preview--markdown-treesit-cache-tick nil
  "Buffer modification tick used to validate
`beacon-preview--markdown-treesit-cache'.")

(defvar-local beacon-preview--org-element-cache nil
  "Cached Org structural entries derived from `org-element' for the current buffer.")

(defvar-local beacon-preview--org-element-cache-tick nil
  "Buffer modification tick used to validate `beacon-preview--org-element-cache'.")

(defvar beacon-preview--pandoc-server-process nil
  "Process object for the internally managed `pandoc server', if any.")

(defvar beacon-preview--pandoc-server-process-config nil
  "Connection settings plist for the managed `pandoc server' process.

This tracks the `:host' and `:port' used when the current managed process was
started so Beacon Preview can restart it after configuration changes.")

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

(defun beacon-preview--markdown-source-mode-p (&optional buffer)
  "Return non-nil when BUFFER should be treated as Markdown source."
  (with-current-buffer (or buffer (current-buffer))
    (derived-mode-p 'markdown-mode 'gfm-mode 'markdown-ts-mode)))

(defun beacon-preview--supported-source-mode-p ()
  "Return non-nil when the current buffer is supported for source-side features."
  (apply #'derived-mode-p beacon-preview-source-modes))

(defun beacon-preview--source-kind (&optional buffer)
  "Return the high-level source kind for BUFFER, or nil when unsupported."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'org-mode) 'org)
     ((beacon-preview--markdown-source-mode-p) 'markdown)
     (t nil))))

(defun beacon-preview--pandoc-input-format (&optional buffer)
  "Return the Pandoc input format string for BUFFER, or signal a user error."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'org-mode)
      "org")
     ((beacon-preview--markdown-source-mode-p)
      "gfm")
     (t
      (user-error
       "Current mode %s is not supported for beacon preview builds"
       major-mode)))))


(require 'beacon-preview-render)
(require 'beacon-preview-runtime)

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
