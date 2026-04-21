;;; beacon-preview-runtime.el --- Process, xwidget, and command layer for beacon-preview -*- lexical-binding: t; -*-

;; Author: matoi
;; Maintainer: matoi
;; URL: https://github.com/matoi/beacon-preview
;; Keywords: hypermedia, tools, convenience
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; This file holds process management, xwidget session handling, and the
;; interactive commands for beacon-preview.  It is loaded by
;; `beacon-preview.el' after `beacon-preview-render'.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'url)
(require 'xml)
(require 'url-util)

(require 'beacon-preview-render)

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

;; Forward declarations for customs/state defined in `beacon-preview.el'.
(defvar beacon-preview-mode)
(defvar beacon-preview-open-function)
(defvar beacon-preview-display-location)
(defvar beacon-preview-pandoc-command)
(defvar beacon-preview-pandoc-server-host)
(defvar beacon-preview-pandoc-server-port)
(defvar beacon-preview-pandoc-server-timeout)
(defvar beacon-preview-pandoc-server-auto-start)
(defvar beacon-preview-pandoc-server-startup-deadline)
(defvar beacon-preview-build-settings)
(defvar beacon-preview-build-settings-by-source-kind)
(defvar beacon-preview-build-settings-by-major-mode)
(defvar beacon-preview-pandoc-template-file)
(defvar beacon-preview-pandoc-css-files)
(defvar beacon-preview-mermaid-script-file)
(defvar beacon-preview-body-wrapper-class)
(defvar beacon-preview-display-buffer-action)
(defvar beacon-preview-dedicated-frame-parameters)
(defvar beacon-preview-temporary-root)
(defvar beacon-preview-source-modes)
(defvar beacon-preview-auto-refresh-on-save)
(defvar beacon-preview-auto-refresh-on-revert)
(defvar beacon-preview-auto-start-on-enable)
(defvar beacon-preview-refresh-jump-behavior)
(defvar beacon-preview-follow-window-display-changes)
(defvar beacon-preview-reveal-hidden-preview-window)
(defvar beacon-preview-display-follow-delay)
(defvar beacon-preview-post-open-sync-delay)
(defvar beacon-preview-slow-build-message-threshold)
(defvar beacon-preview-debug)
(defvar beacon-preview-external-link-browser)
(defvar beacon-preview--external-link-sentinel-prefix)
(defvar beacon-preview--last-url)
(defvar beacon-preview--last-html-path)
(defvar beacon-preview--manifest)
(defvar beacon-preview--manifest-path)
(defvar beacon-preview--preview-html-cache)
(defvar beacon-preview--xwidget-buffer)
(defvar beacon-preview--last-build-tick)
(defvar beacon-preview--preview-frame)
(defvar beacon-preview--shared-preview-frame)
(defvar beacon-preview--source-buffer)
(defvar beacon-preview--pending-sync-script)
(defvar beacon-preview--pending-sync-generation)
(defvar beacon-preview--pending-sync-timer)
(defvar beacon-preview--display-follow-timer)
(defvar beacon-preview--last-window-start)
(defvar beacon-preview--last-point)
(defvar beacon-preview--edited-positions)
(defvar beacon-preview--build-request-buffer)
(defvar beacon-preview--ephemeral-source-id)
(defvar beacon-preview--pandoc-server-process)

(declare-function beacon-preview--debug "beacon-preview")
(declare-function beacon-preview--markdown-source-mode-p "beacon-preview")
(declare-function beacon-preview--supported-source-mode-p "beacon-preview")
(declare-function beacon-preview--source-kind "beacon-preview")
(declare-function beacon-preview--pandoc-input-format "beacon-preview")

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
  (when-let ((preview-buffer (beacon-preview--tracked-preview-buffer)))
    (beacon-preview--xwidget-session-for-buffer preview-buffer)))

(defun beacon-preview--tracked-preview-buffer ()
  "Return the current source buffer's tracked preview buffer, or nil.

This rejects stale preview associations whose reverse link no longer points
back to the current source buffer."
  (when (buffer-live-p beacon-preview--xwidget-buffer)
    (let ((source-buffer (buffer-local-value 'beacon-preview--source-buffer
                                             beacon-preview--xwidget-buffer)))
      (if (or (null source-buffer)
              (eq source-buffer (current-buffer)))
        beacon-preview--xwidget-buffer
        nil))))

(defun beacon-preview--live-preview-p ()
  "Return non-nil when the current source buffer has a live preview session."
  (and (beacon-preview--tracked-preview-buffer)
       (beacon-preview--xwidget-session)))


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
         (beacon-preview--tracked-preview-buffer))
    (current-buffer))
   ((buffer-live-p beacon-preview--source-buffer)
    beacon-preview--source-buffer)
   (t nil)))

(defun beacon-preview--context-preview-buffer ()
  "Return the preview buffer for the current beacon preview context, or nil."
  (cond
   ((beacon-preview--tracked-preview-buffer)
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
    (list :html (expand-file-name (format "%s.html" base) output-dir))))

(defun beacon-preview--snapshot-extension (&optional buffer)
  "Return the temporary source snapshot extension appropriate for BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((buffer-file-name)
      (concat "." (or (file-name-extension (buffer-file-name)) "txt")))
     ((derived-mode-p 'org-mode)
      ".org")
     ((beacon-preview--markdown-source-mode-p)
      ".md")
     (t
      (user-error
       "Current buffer is not visiting a file and mode %s is not supported for preview snapshots"
       major-mode)))))

(defun beacon-preview--file-writable-for-save-p (file)
  "Return non-nil when FILE can be written for an auto-save-before-preview.
A missing FILE is considered writable when its parent directory is writable."
  (if (file-exists-p file)
      (file-writable-p file)
    (file-writable-p (file-name-directory (expand-file-name file)))))

(defun beacon-preview--write-buffer-snapshot (buffer output-dir base-name default-dir)
  "Write BUFFER contents to a temp snapshot under OUTPUT-DIR and return metadata.
BASE-NAME is used to name the snapshot file.  DEFAULT-DIR becomes the
`:default-directory' of the returned plist."
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
          :ephemeral t)))

(defun beacon-preview--prepare-build-source (&optional buffer)
  "Return build metadata for BUFFER's current preview source.

When BUFFER visits a file and has unsaved modifications, the buffer is
silently saved so the preview always reflects the live edits.  If the
on-disk file has been modified externally since Emacs last read or wrote
it, `user-error' is signaled to avoid clobbering the external changes.
When the file is read-only, the buffer contents are rendered via a
temporary snapshot instead.

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
    (cond
     ((not source-file)
      (beacon-preview--write-buffer-snapshot buffer output-dir base-name default-dir))
     (t
      (with-current-buffer buffer
        (when (buffer-modified-p)
          (unless (verify-visited-file-modtime (current-buffer))
            (user-error
             "beacon-preview: %s has changed on disk; resolve the conflict (revert or save) before previewing"
             source-file))
          (when (beacon-preview--file-writable-for-save-p source-file)
            (let ((inhibit-message t))
              (save-buffer)))))
      (if (with-current-buffer buffer (buffer-modified-p))
          ;; Save was skipped (file is read-only); fall back to snapshot.
          (beacon-preview--write-buffer-snapshot buffer output-dir base-name default-dir)
        (list :input-file (expand-file-name source-file)
              :output-dir output-dir
              :base-name base-name
              :default-directory default-dir
              :ephemeral nil))))))

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
         (preview-buffer (beacon-preview--tracked-preview-buffer))
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
  (setq beacon-preview--preview-html-cache nil)
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
  (setq beacon-preview--manifest-path nil)
  (setq beacon-preview--preview-html-cache nil))

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
  (unless (beacon-preview--command-available-p beacon-preview-pandoc-command)
    (user-error "Pandoc executable not found: %s" beacon-preview-pandoc-command)))

(defun beacon-preview--existing-paths (paths)
  "Return PATHS filtered to existing filesystem entries."
  (seq-filter #'file-exists-p paths))

(defun beacon-preview--pandoc-server-url (&optional endpoint)
  "Return the URL for the pandoc server ENDPOINT."
  (format "http://%s:%d%s"
          beacon-preview-pandoc-server-host
          beacon-preview-pandoc-server-port
          (or endpoint "/")))

(defun beacon-preview--pandoc-server-live-p ()
  "Return non-nil when the configured pandoc server responds to `/version'."
  (condition-case nil
      (let ((url-request-method "GET")
            (buffer (url-retrieve-synchronously
                     (beacon-preview--pandoc-server-url "/version")
                     t t 0.2)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (goto-char (point-min))
            (prog1
                (re-search-forward "^HTTP/[0-9.]+ 200 " nil t)
              (kill-buffer buffer)))))
    (error nil)))

(defun beacon-preview--pandoc-server-sentinel (process _event)
  "Forget PROCESS when the managed pandoc server exits."
  (unless (process-live-p process)
    (when (eq beacon-preview--pandoc-server-process process)
      (setq beacon-preview--pandoc-server-process nil))))

(defun beacon-preview--start-pandoc-server ()
  "Start a managed `pandoc server' process."
  (let ((buffer (get-buffer-create " *beacon-preview-pandoc-server*")))
    (setq beacon-preview--pandoc-server-process
          (make-process
           :name "beacon-preview-pandoc-server"
           :buffer buffer
           :command (list beacon-preview-pandoc-command
                          "server"
                          (format "--port=%d" beacon-preview-pandoc-server-port)
                          (format "--timeout=%d" beacon-preview-pandoc-server-timeout))
           :noquery t
           :connection-type 'pipe
           :sentinel #'beacon-preview--pandoc-server-sentinel))
    beacon-preview--pandoc-server-process))

(defun beacon-preview--pandoc-server-startup-log ()
  "Return recent output from the managed pandoc server's buffer, or nil."
  (let ((buffer (get-buffer " *beacon-preview-pandoc-server*")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (unless (string-empty-p (string-trim text))
            text))))))

(defun beacon-preview--ensure-pandoc-server ()
  "Ensure a reachable pandoc server is available or signal a user error."
  (unless (beacon-preview--pandoc-server-live-p)
    (unless beacon-preview-pandoc-server-auto-start
      (user-error "Pandoc server is not reachable at %s"
                  (beacon-preview--pandoc-server-url "/")))
    (unless (and beacon-preview--pandoc-server-process
                 (process-live-p beacon-preview--pandoc-server-process))
      (beacon-preview--start-pandoc-server))
    (let ((deadline (+ (float-time)
                       beacon-preview-pandoc-server-startup-deadline)))
      (while (and (< (float-time) deadline)
                  (process-live-p beacon-preview--pandoc-server-process)
                  (not (beacon-preview--pandoc-server-live-p)))
        (accept-process-output beacon-preview--pandoc-server-process 0.1)))
    (unless (beacon-preview--pandoc-server-live-p)
      (let ((log (beacon-preview--pandoc-server-startup-log)))
        (user-error "Failed to start pandoc server at %s%s"
                    (beacon-preview--pandoc-server-url "/")
                    (if log (format ": %s" (string-trim log)) ""))))))

(defun beacon-preview--buffer-file-string (file)
  "Return FILE contents as a UTF-8 string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun beacon-preview--pandoc-server-template (config)
  "Return template string for CONFIG, or nil if no usable template exists."
  (when-let ((template-file (plist-get config :pandoc-template-file)))
    (if (file-exists-p template-file)
        (beacon-preview--buffer-file-string template-file)
      (message "[beacon-preview] Pandoc template not found: %s" template-file)
      nil)))

(defun beacon-preview--pandoc-server-css-variables (config)
  "Return a vector of CSS file URLs for CONFIG, or nil when none are usable."
  (let ((urls nil))
    (dolist (path (plist-get config :pandoc-css-files))
      (if (file-exists-p path)
          (setq urls
                (append urls
                        (list (beacon-preview--file-url
                               (expand-file-name path)))))
        (message "[beacon-preview] CSS file not found: %s" path)))
    (when urls
      (vconcat urls))))

(defun beacon-preview--pandoc-server-request ()
  "Return request metadata for a pandoc-server preview build."
  (beacon-preview--validate-build-prerequisites)
  (beacon-preview--ensure-pandoc-server)
  (let* ((build-source (beacon-preview--prepare-build-source))
         (input-format (beacon-preview--pandoc-input-format))
         (config (beacon-preview--current-build-config))
         (source-file (plist-get build-source :input-file))
         (artifacts (beacon-preview--artifact-paths))
         (html-path (plist-get artifacts :html))
         (template (beacon-preview--pandoc-server-template config))
         (css-variables (beacon-preview--pandoc-server-css-variables config))
         (payload `(("text" . ,(beacon-preview--buffer-file-string source-file))
                    ("from" . ,input-format)
                    ("to" . "html")
                    ("standalone" . t)
                    ,@(when template
                        `(("template" . ,template)))
                    ,@(when css-variables
                        `(("variables" . (("css" . ,css-variables))))))))
    (make-directory (plist-get build-source :output-dir) t)
    (list :url (beacon-preview--pandoc-server-url "/")
          :payload payload
          :html html-path
          :default-directory (plist-get build-source :default-directory))))

(defun beacon-preview--http-response-body ()
  "Return the current buffer's HTTP response body, decoded as UTF-8.

`url-retrieve' response buffers are unibyte and keep the body as raw bytes.
Decoding to a multibyte string ensures JSON parsing and later file writes
handle non-ASCII output correctly."
  (goto-char (point-min))
  (let ((body-bytes
         (if (re-search-forward "\r?\n\r?\n" nil t)
             (buffer-substring-no-properties (point) (point-max))
           (buffer-string))))
    (decode-coding-string body-bytes 'utf-8)))

(defun beacon-preview--encode-request-data (payload)
  "Return PAYLOAD JSON-encoded as a unibyte UTF-8 byte string.

`url-request-data' must not contain multibyte characters; encoding to UTF-8
bytes is required whenever the payload (e.g. source text) includes non-ASCII
content."
  (encode-coding-string (json-encode payload) 'utf-8))

(defun beacon-preview--write-build-output (output-buffer lines)
  "Replace OUTPUT-BUFFER contents with LINES joined by newlines."
  (with-current-buffer (get-buffer-create output-buffer)
    (erase-buffer)
    (insert (string-join (seq-remove #'string-empty-p lines) "\n"))))

(defun beacon-preview--pandoc-server-handle-response (response-buffer html-path output-buffer)
  "Decode RESPONSE-BUFFER and write HTML-PATH, or signal a `user-error'."
  (unwind-protect
      (with-current-buffer response-buffer
        (let* ((status-line (progn
                              (goto-char (point-min))
                              (buffer-substring-no-properties
                               (line-beginning-position)
                               (line-end-position))))
               (body (beacon-preview--http-response-body))
               (payload (condition-case nil
                            (json-parse-string
                             body
                             :object-type 'alist
                             :array-type 'list)
                          (json-parse-error
                           nil)))
               (messages (alist-get 'messages payload))
               (output (or (alist-get 'output payload)
                           (when (string-match-p "^HTTP/[0-9.]+ 200 " status-line)
                             body)))
               (error-message (alist-get 'error payload))
               (base64 (eq t (alist-get 'base64 payload)))
               (log-lines
                (append
                 (when (and status-line
                            (not (string-empty-p status-line)))
                   (list status-line))
                 (mapcar
                  (lambda (entry)
                    (format "%s: %s"
                            (alist-get 'verbosity entry)
                            (alist-get 'message entry)))
                  messages)
                 (when error-message
                   (list error-message)))))
          (beacon-preview--write-build-output output-buffer log-lines)
          (unless (and (stringp output)
                       (not error-message)
                       (string-match-p "^HTTP/[0-9.]+ 200 " status-line))
            (user-error "%s" (beacon-preview--build-error-message output-buffer)))
          (make-directory (file-name-directory html-path) t)
          (with-temp-file html-path
            (insert (if base64
                        (decode-coding-string
                         (base64-decode-string output)
                         'utf-8)
                      output)))))
    (when (buffer-live-p response-buffer)
      (kill-buffer response-buffer))))

;;;###autoload
(defun beacon-preview-build-current-file ()
  "Build preview artifacts for the current source buffer synchronously.

Returns a plist with the final `:html' path."
  (interactive)
  (let* ((output-buffer "*beacon-preview-build*")
         (build (beacon-preview--pandoc-server-request))
         (html-path (plist-get build :html))
         (default-directory (plist-get build :default-directory))
         (url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")
            ("Accept" . "application/json")))
         (url-request-data
          (beacon-preview--encode-request-data (plist-get build :payload)))
         (response-buffer
          (url-retrieve-synchronously (plist-get build :url) t t)))
    (unless (buffer-live-p response-buffer)
      (user-error "Failed to contact pandoc server at %s"
                  (plist-get build :url)))
    (beacon-preview--pandoc-server-handle-response
     response-buffer html-path output-buffer)
    (setq beacon-preview--last-html-path html-path)
    (beacon-preview--postprocess-preview-html-file html-path)
    (setq beacon-preview--last-build-tick (buffer-chars-modified-tick))
    (when (called-interactively-p 'interactive)
      (message "Built preview: %s" html-path))
    (list :html html-path)))

(defun beacon-preview--build-current-file-async (callback)
  "Build preview artifacts asynchronously, then call CALLBACK.

CALLBACK receives one argument: a plist with final `:html' path, or nil on
failure.  Any previously running async build for this source buffer is killed
first."
  (let* ((source-buffer (current-buffer))
         (output-buffer (generate-new-buffer " *beacon-preview-build-async*"))
         (start-time (current-time)))
    (when (buffer-live-p beacon-preview--build-request-buffer)
      (let ((request-process (get-buffer-process beacon-preview--build-request-buffer)))
        (when (process-live-p request-process)
          (delete-process request-process)))
      (kill-buffer beacon-preview--build-request-buffer)
      (setq beacon-preview--build-request-buffer nil))
    (let* ((build (beacon-preview--pandoc-server-request))
           (html-path (plist-get build :html))
           (default-directory (plist-get build :default-directory))
           (url-request-method "POST")
           (url-request-extra-headers
            '(("Content-Type" . "application/json")
              ("Accept" . "application/json")))
           (url-request-data
          (beacon-preview--encode-request-data (plist-get build :payload)))
           (request-buffer
            (url-retrieve
             (plist-get build :url)
             (lambda (status)
               (let ((response-buffer (current-buffer)))
                 (when (buffer-live-p source-buffer)
                   (with-current-buffer source-buffer
                     (when (eq beacon-preview--build-request-buffer response-buffer)
                       (setq beacon-preview--build-request-buffer nil))))
                 (unwind-protect
                     (cond
                      ((plist-get status :error)
                       (beacon-preview--write-build-output
                        output-buffer
                        (list (format "%s" (plist-get status :error))))
                       (funcall callback nil))
                      (t
                       (condition-case err
                           (progn
                             (beacon-preview--pandoc-server-handle-response
                              response-buffer html-path output-buffer)
                             (when (buffer-live-p source-buffer)
                               (with-current-buffer source-buffer
                                 (setq beacon-preview--last-html-path html-path)
                                 (beacon-preview--postprocess-preview-html-file html-path)
                                 (setq beacon-preview--last-build-tick
                                       (buffer-chars-modified-tick))
                                 (beacon-preview--build-message-finish start-time)))
                             (funcall callback (list :html html-path)))
                         (error
                          (beacon-preview--write-build-output
                           output-buffer
                           (list (error-message-string err)))
                          (funcall callback nil)))))
                   (when (buffer-live-p output-buffer)
                     (kill-buffer output-buffer)))))
             nil t)))
      (setq beacon-preview--build-request-buffer request-buffer))))

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
                                                         live edited-anchors
                                                         &optional refresh-jump-behavior)
  "Refresh the preview in SOURCE-BUFFER using ARTIFACTS.

LIVE, and EDITED-ANCHORS are the pre-build state captured by the caller.
REFRESH-JUMP-BEHAVIOR, when non-nil, overrides
`beacon-preview-refresh-jump-behavior' for this refresh."
  (when (and artifacts (buffer-live-p source-buffer))
    (with-current-buffer source-buffer
      (let* ((effective-refresh-jump-behavior
              (or refresh-jump-behavior beacon-preview-refresh-jump-behavior))
             (html-path (plist-get artifacts :html))
             (anchor (and live
                          (beacon-preview--live-preview-p)
                          (eq effective-refresh-jump-behavior 'block)
                          (beacon-preview--current-anchor-maybe)))
             (flash-script (and edited-anchors
                                (beacon-preview--flash-visible-anchors-script
                                 edited-anchors))))
        (when (beacon-preview--live-preview-p)
          (if (eq effective-refresh-jump-behavior 'preserve)
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

(defun beacon-preview--preview-needs-build-p ()
  "Return non-nil when the current source buffer needs a fresh preview build."
  (not (equal beacon-preview--last-build-tick
              (buffer-chars-modified-tick))))

(defun beacon-preview--ensure-live-and-fresh-preview ()
  "Ensure the current source buffer has a live, fresh preview.

Return non-nil when this started an async build/open cycle and the caller
should stop further synchronous preview actions for now."
  (if (and (beacon-preview--live-preview-p)
           (not (beacon-preview--preview-needs-build-p)))
      nil
    (beacon-preview-build-and-open)
    t))

(defun beacon-preview--show-tracked-preview ()
  "Show the current source buffer's tracked preview buffer."
  (if-let ((preview-buffer (beacon-preview--tracked-preview-buffer)))
      (beacon-preview--show-preview-buffer preview-buffer)
    (user-error "No live preview buffer is associated with this source buffer")))

;;;###autoload
(defun beacon-preview-dwim ()
  "Build, foreground, or jump the preview for the current source buffer.

When no live preview exists, build artifacts and open the preview.  When a
live preview exists but is stale, rebuild and foreground it.  When a live
preview is already up to date, foreground it if hidden or jump to the current
source block if it is already visible."
  (interactive)
  (cond
   ((beacon-preview--ensure-live-and-fresh-preview))
   ((beacon-preview--tracked-preview-window
     (beacon-preview--tracked-preview-buffer))
    (beacon-preview-jump-to-current-block))
   (t
    (beacon-preview--show-tracked-preview))))

;;;###autoload
(defun beacon-preview-show-preview ()
  "Show the current source buffer's tracked preview.

If no preview is live yet for the current source buffer, start one first."
  (interactive)
  (if (beacon-preview--live-preview-p)
      (beacon-preview--run-after-ensuring-fresh-preview
       #'beacon-preview--show-tracked-preview
       t)
    (beacon-preview-build-and-open)))

(defun beacon-preview--hide-preview-display ()
  "Hide the current source buffer's visible preview display."
  (unless (beacon-preview--tracked-preview-buffer)
    (user-error "No live preview buffer is associated with this source buffer"))
  (let ((preview-window
         (beacon-preview--tracked-preview-window
          (beacon-preview--tracked-preview-buffer))))
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
   ((beacon-preview--tracked-preview-window
     (beacon-preview--tracked-preview-buffer))
    (beacon-preview--hide-preview-display))
   (t
    (unless (beacon-preview--ensure-live-and-fresh-preview)
      (beacon-preview--show-tracked-preview)))))

(defun beacon-preview--current-session ()
  "Return the current xwidget webkit session or signal a user error."
  (or (beacon-preview--xwidget-session)
      (user-error "No active xwidget webkit session found")))

(defun beacon-preview--execute-script (script)
  "Execute JavaScript SCRIPT in the current preview session."
  (xwidget-webkit-execute-script
   (beacon-preview--current-session)
   script))

;;;###autoload
(defun beacon-preview--run-after-ensuring-fresh-preview
    (thunk &optional preserve-preview-position)
  "Run THUNK in the current source buffer, rebuilding the preview first when stale.
When the preview is stale relative to the source buffer (per
`beacon-preview--preview-needs-build-p'), an async rebuild is started and
THUNK is invoked in the build completion callback after a short delay so
the xwidget has time to load the refreshed HTML.  The rebuild path also
auto-saves the buffer via `beacon-preview--prepare-build-source' and
signals `user-error' on an external-file conflict.

When PRESERVE-PREVIEW-POSITION is non-nil, the stale-preview refresh keeps
the preview near its pre-refresh scroll position before THUNK runs."
  (if (not (beacon-preview--preview-needs-build-p))
      (funcall thunk)
    (let ((source-buffer (current-buffer))
          (live (beacon-preview--live-preview-p))
          (edited-anchors (and (beacon-preview--live-preview-p)
                               (beacon-preview--edited-anchors)))
          (refresh-jump-behavior
           (and preserve-preview-position 'preserve)))
      (beacon-preview--build-message-start)
      (beacon-preview--build-current-file-async
       (lambda (artifacts)
         (beacon-preview--refresh-with-artifacts
          artifacts source-buffer live edited-anchors
          refresh-jump-behavior)
         (run-at-time
          beacon-preview-post-open-sync-delay nil
          (lambda ()
            (when (buffer-live-p source-buffer)
              (with-current-buffer source-buffer
                (funcall thunk))))))))))

(defun beacon-preview--sync-source-to-preview-now (source-buffer preview-buffer)
  "Query PREVIEW-BUFFER for a visible beacon and move SOURCE-BUFFER point to it."
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
                       (error-message-string err))))))))))

(defun beacon-preview-sync-source-to-preview ()
  "Move the source buffer to a simple visible block currently shown in preview.

This is a first reverse-sync step: it asks the live preview for a visible
beacon entry using a simple viewport heuristic, then moves the corresponding
source buffer to that block or heading.

When the preview is stale relative to the source buffer, the preview is
rebuilt first (auto-saving the source buffer if it has unsaved edits) so
that reverse-sync operates on content aligned with the buffer."
  (interactive)
  (let* ((source-buffer (beacon-preview--context-source-buffer))
         (preview-buffer (beacon-preview--context-preview-buffer)))
    (unless (buffer-live-p source-buffer)
      (user-error "No source buffer is associated with the current context"))
    (unless (buffer-live-p preview-buffer)
      (user-error "No live preview buffer is associated with the current context"))
    (with-current-buffer source-buffer
      (beacon-preview--run-after-ensuring-fresh-preview
       (lambda ()
         (when (buffer-live-p preview-buffer)
           (beacon-preview--show-tracked-preview)
           (setq preview-buffer (beacon-preview--tracked-preview-buffer))
           (beacon-preview--sync-source-to-preview-now
            source-buffer preview-buffer)))
       t))))

;;;###autoload
(defun beacon-preview-jump-to-anchor (anchor)
  "Jump the current preview to ANCHOR using the injected BeaconPreview API.
When the preview is stale relative to the source buffer, it is rebuilt
first so the jump lands on aligned content."
  (interactive "sAnchor: ")
  (beacon-preview--run-after-ensuring-fresh-preview
   (lambda ()
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
        (beacon-preview--jump-script anchor ratio))))))

;;;###autoload
(defun beacon-preview-flash-current-target ()
  "Flash the current source-correlated target in the live preview.
When the preview is stale relative to the source buffer, it is rebuilt
first so the flashed element matches the current source block."
  (interactive)
  (unless (beacon-preview--live-preview-p)
    (user-error "No live preview is associated with the current buffer"))
  (beacon-preview--run-after-ensuring-fresh-preview
   (lambda ()
     (let ((anchor (beacon-preview--current-anchor-maybe)))
       (unless anchor
         (user-error "No current block or heading anchor found at point"))
       (beacon-preview--execute-script
        (format
         (concat "(function () {"
                 "  if (!window.BeaconPreview || typeof window.BeaconPreview.flashAnchor !== 'function') {"
                 "    return false;"
                 "  }"
                 "  return window.BeaconPreview.flashAnchor(%s);"
                 "})();")
         (beacon-preview--js-string-literal anchor)))))))

;;;###autoload
(defun beacon-preview-jump-to-index (kind index)
  "Jump the current preview to beacon KIND at INDEX.
When the preview is stale relative to the source buffer, it is rebuilt
first so the index refers to the same blocks the buffer currently has."
  (interactive
   (list
    (completing-read
     "Kind: "
     '("h1" "h2" "h3" "h4" "h5" "h6" "p" "li" "blockquote" "pre" "table" "div")
     nil
     t)
    (read-number "Index: " 1)))
  (beacon-preview--run-after-ensuring-fresh-preview
   (lambda ()
     (beacon-preview--execute-script
      (format
       (concat "(function () {"
               " if (!window.BeaconPreview) { return false; }"
               " return window.BeaconPreview.jumpToIndex(%s, %d);"
               "})();")
       (beacon-preview--js-string-literal kind)
       index)))))

;;;###autoload
(defun beacon-preview-reload ()
  "Reload the current beacon preview."
  (interactive)
  (beacon-preview--execute-script "window.location.reload();"))

(defun beacon-preview-jump-to-current-heading ()
  "Jump preview to the anchor derived from the current Markdown heading."
  (beacon-preview--run-after-ensuring-fresh-preview
   (lambda ()
     (beacon-preview-jump-to-anchor
      (beacon-preview-current-heading-anchor)))))

(defun beacon-preview-jump-to-current-block ()
  "Jump preview to the current source block anchor.

This prefers block-level anchors such as fenced code blocks, blockquotes,
tables, list items, and paragraphs. When no block anchor can be resolved, it
falls back to the current heading anchor."
  (unless (beacon-preview--supported-source-mode-p)
    (user-error "Current mode is not configured for source-side beacon lookup"))
  (beacon-preview--run-after-ensuring-fresh-preview
   (lambda ()
     (let ((anchor (or (beacon-preview-current-block-anchor)
                       (ignore-errors (beacon-preview-current-heading-anchor)))))
       (unless anchor
         (user-error "No current block or heading anchor found at point"))
       (beacon-preview-jump-to-anchor anchor)))))

(provide 'beacon-preview-runtime)

;;; beacon-preview-runtime.el ends here
