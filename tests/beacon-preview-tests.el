;;; beacon-preview-tests.el --- Tests for beacon-preview -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load-file "/Users/matoi/Development/beacon-preview/lisp/beacon-preview.el")

(ert-deftest beacon-preview-source-temp-directory-is-stable ()
  (let* ((beacon-preview-temporary-root "/tmp/beacon-preview-tests/")
         (source-a "/tmp/project-a/sample.md")
         (source-b "/tmp/project-b/sample.md")
         (dir-a-1 (beacon-preview--source-temp-directory source-a))
         (dir-a-2 (beacon-preview--source-temp-directory source-a))
         (dir-b (beacon-preview--source-temp-directory source-b)))
    (should (string= dir-a-1 dir-a-2))
    (should-not (string= dir-a-1 dir-b))
    (should (string-match-p "sample-" dir-a-1))))

(ert-deftest beacon-preview-default-builder-script-follows-library-directory ()
  (cl-letf (((symbol-function 'beacon-preview--library-directory)
             (lambda ()
               "/tmp/beacon-preview/lisp/")))
    (should (string=
             (beacon-preview--default-builder-script)
             "/tmp/beacon-preview/scripts/build_preview.py"))))

(ert-deftest beacon-preview-current-heading-anchor-prefers-manifest ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Repeat") (anchor . "repeat"))
           ((kind . "h2") (text . "Repeat") (anchor . "repeat-1")))))
    (with-temp-buffer
      (insert "# Top\n\n## Repeat\nA\n\n## Repeat\nB\n")
      (goto-char (point-max))
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-heading-anchor) "repeat-1")))))

(ert-deftest beacon-preview-current-heading-anchor-falls-back-to-slug ()
  (let ((beacon-preview--manifest nil))
    (with-temp-buffer
      (insert "# Top\n\n## Code Section\nBody\n")
      (goto-char (point-max))
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-heading-anchor) "code-section")))))

(ert-deftest beacon-preview-current-heading-anchor-falls-back-with-duplicates ()
  (let ((beacon-preview--manifest nil))
    (with-temp-buffer
      (insert "# Top\n\n## Repeat\nA\n\n## Repeat\nB\n")
      (goto-char (point-max))
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-heading-anchor) "repeat-1")))))

(ert-deftest beacon-preview-markdown-current-heading-on-heading-line ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\nBody\n")
    (goto-char (point-min))
    (search-forward "Section")
    (beginning-of-line)
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Section")))))

(ert-deftest beacon-preview-markdown-current-heading-info-includes-position ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\nBody\n")
    (goto-char (point-min))
    (search-forward "Body")
    (setq-local major-mode 'markdown-mode)
    (let ((info (beacon-preview--markdown-current-heading-info)))
      (should (equal (plist-get info :level) 2))
      (should (equal (plist-get info :text) "Section"))
      (save-excursion
        (goto-char (plist-get info :pos))
        (should (looking-at-p "## Section"))))))

(ert-deftest beacon-preview-markdown-current-heading-on-blank-line-below-heading ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\n\nBody\n")
    (goto-char (point-min))
    (search-forward "Section")
    (forward-line 1)
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Section")))))

(ert-deftest beacon-preview-markdown-current-heading-supports-indented-atx-headings ()
  (with-temp-buffer
    (insert "# Top\n\n   ## Section\nBody\n")
    (goto-char (point-max))
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Section")))))

(ert-deftest beacon-preview-markdown-current-heading-supports-setext-headings ()
  (with-temp-buffer
    (insert "Top\n===\n\nSection\n---\n\nBody\n")
    (goto-char (point-max))
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Section")))))

(ert-deftest beacon-preview-markdown-current-heading-inside-fenced-code-block ()
  (with-temp-buffer
    (insert
     "## 状態モデル: per-position tracker 配列\n\n"
     "singleton state machine + 2 スロットバッファ (`buffered_kana` / `buffered_kana_2`) "
     "を廃止し、per-position の `key_tracker[]` 配列に置き換える。\n\n"
     "```c\n"
     "#define NICOLA_MAX_TRACKERS 6   /* Kconfig で変更可能 */\n"
     "```\n")
    (goto-char (point-min))
    (search-forward "#define")
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "状態モデル: per-position tracker 配列")))))

(ert-deftest beacon-preview-current-heading-anchor-inside-fenced-code-block ()
  (let ((beacon-preview--manifest
         '(((kind . "h2")
            (text . "状態モデル: per-position tracker 配列")
            (anchor . "状態モデル-per-position-tracker-配列")))))
    (with-temp-buffer
      (insert
       "## 状態モデル: per-position tracker 配列\n\n"
       "singleton state machine + 2 スロットバッファ (`buffered_kana` / `buffered_kana_2`) "
       "を廃止し、per-position の `key_tracker[]` 配列に置き換える。\n\n"
       "```c\n"
       "#define NICOLA_MAX_TRACKERS 6   /* Kconfig で変更可能 */\n"
       "```\n")
      (goto-char (point-min))
      (search-forward "#define")
      (setq-local major-mode 'markdown-mode)
      (should (string=
               (beacon-preview-current-heading-anchor)
               "状態モデル-per-position-tracker-配列")))))

(ert-deftest beacon-preview-pandoc-like-slug-preserves-non-ascii ()
  (should (string= (beacon-preview--pandoc-like-slug "日本語 見出し")
                   "日本語-見出し"))
  (should (string= (beacon-preview--pandoc-like-slug "Héllo, World!")
                   "héllo-world"))
  (should (string= (beacon-preview--pandoc-like-slug "C++ / Rust")
                   "c-rust"))
  (should (string= (beacon-preview--pandoc-like-slug "foo_bar baz")
                   "foo_bar-baz"))
  (should (string= (beacon-preview--pandoc-like-slug
                    "状態モデル: per-position tracker 配列")
                   "状態モデル-per-position-tracker-配列")))

(ert-deftest beacon-preview-window-line-ratio-stays-in-range ()
  (with-temp-buffer
    (dotimes (_ 40)
      (insert "line\n"))
    (goto-char (point-min))
    (forward-line 5)
    (set-window-buffer (selected-window) (current-buffer))
    (should (<= 0.0 (beacon-preview--window-line-ratio)))
    (should (<= (beacon-preview--window-line-ratio) 1.0))))

(ert-deftest beacon-preview-window-line-ratio-uses-explicit-position ()
  (with-temp-buffer
    (dotimes (i 40)
      (insert (format "line-%02d\n" i)))
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (let ((target-pos (save-excursion
                        (forward-line 10)
                        (point))))
      (should (> (beacon-preview--window-line-ratio (selected-window) target-pos)
                 0.0)))))

(ert-deftest beacon-preview-window-line-ratio-can-reflect-visual-line-offset ()
  (with-temp-buffer
    (let ((fill-column 20))
      (insert "This is a long wrapped line that should occupy several visual lines in the window.\n")
      (insert "## Section\n")
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (let ((target-pos (save-excursion
                          (search-forward "## Section")
                          (line-beginning-position))))
        (should (> (beacon-preview--window-line-ratio (selected-window) target-pos)
                   0.0))))))

(ert-deftest beacon-preview-window-visible-ratio-for-pos-returns-nil-when-hidden ()
  (with-temp-buffer
    (dotimes (_ 40)
      (insert "line\n"))
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (let ((target-pos (save-excursion
                        (goto-char (point-max))
                        (point))))
      (cl-letf (((symbol-function 'pos-visible-in-window-p)
                 (lambda (_pos _window) nil)))
        (should-not
         (beacon-preview--window-visible-ratio-for-pos
          (selected-window)
          target-pos))))))

(ert-deftest beacon-preview-window-visible-ratio-for-pos-returns-ratio-when-visible ()
  (with-temp-buffer
    (dotimes (_ 40)
      (insert "line\n"))
    (set-window-buffer (selected-window) (current-buffer))
    (let ((target-pos (save-excursion
                        (goto-char (point-min))
                        (forward-line 5)
                        (point))))
      (cl-letf (((symbol-function 'pos-visible-in-window-p)
                 (lambda (_pos _window) t))
                ((symbol-function 'beacon-preview--window-pixel-y-for-pos)
                 (lambda (&optional _window _position) 120))
                ((symbol-function 'window-body-height)
                 (lambda (&optional _window _pixelwise) 240)))
        (should (numberp
                 (beacon-preview--window-visible-ratio-for-pos
                  (selected-window)
                  target-pos)))))))

(ert-deftest beacon-preview-window-visible-ratio-for-pos-prefers-pixel-position ()
  (with-temp-buffer
    (let ((target-pos (point-min)))
      (cl-letf (((symbol-function 'pos-visible-in-window-p)
                 (lambda (_pos _window) t))
                ((symbol-function 'beacon-preview--window-pixel-y-for-pos)
                 (lambda (&optional _window _position) 50))
                ((symbol-function 'window-body-height)
                 (lambda (&optional _window _pixelwise) 200))
                ((symbol-function 'beacon-preview--window-line-ratio)
                 (lambda (&rest _args) (ert-fail "line fallback should not be used"))))
        (should (= 0.25
                   (beacon-preview--window-visible-ratio-for-pos
                    (selected-window)
                    target-pos)))))))

(ert-deftest beacon-preview-source-window-prefers-selected-window-for-current-buffer ()
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (should (eq (beacon-preview--source-window (current-buffer))
                (selected-window)))))

(ert-deftest beacon-preview-xwidget-available-p-requires-loadable-xwidget ()
  (cl-letf (((symbol-function 'beacon-preview--ensure-xwidget-loaded)
             (lambda () nil)))
    (should-not (beacon-preview--xwidget-available-p))))

(ert-deftest beacon-preview-open-preview-errors-cleanly-when-xwidget-is-unavailable ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
               (lambda () nil)))
      (should-error
       (beacon-preview--open-preview "/tmp/sample.html")
       :type 'user-error))))

(ert-deftest beacon-preview-effective-window-ratio-compresses-lower-positions ()
  (should (= 0.0 (beacon-preview--effective-window-ratio 0.0)))
  (should (< (beacon-preview--effective-window-ratio 0.8) 0.8))
  (should (< (beacon-preview--effective-window-ratio 1.0) 0.6))
  (should (> (beacon-preview--effective-window-ratio 0.5) 0.0)))

(ert-deftest beacon-preview-jump-script-includes-anchor-and-ratio ()
  (let ((script (beacon-preview--jump-script "section" 0.25)))
    (should (string-match-p "section" script))
    (should (string-match-p "0\\.2500000000" script))
    (should (string-match-p "window\\.scrollTo" script))
    (should (string-match-p "setTimeout" script))))

(ert-deftest beacon-preview-build-current-file-creates-temp-artifacts ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root)))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n\n## Section\n\nBody\n"))
          (find-file source-file)
          (let ((artifacts (beacon-preview-build-current-file)))
            (should (file-exists-p (plist-get artifacts :html)))
            (should (file-exists-p (plist-get artifacts :manifest)))
            (should (string-prefix-p
                     (file-name-as-directory (expand-file-name beacon-preview-temporary-root))
                     (plist-get artifacts :html)))
            (should beacon-preview--manifest)
            (kill-buffer (current-buffer))))
      (ignore-errors
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-at-current-heading ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (opened-file nil)
         (opened-anchor nil)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*")))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n\n## Section\n"))
          (find-file source-file)
          (goto-char (point-max))
          (setq-local major-mode 'markdown-mode)
          (let* ((artifacts (beacon-preview-build-current-file))
                 (html-path (plist-get artifacts :html)))
            (setq beacon-preview--last-url "file:///dummy")
            (setq beacon-preview--last-html-path html-path)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--open-preview)
                       (lambda (file &optional anchor)
                         (setq opened-file file)
                         (setq opened-anchor anchor)))
                      ((symbol-function 'xwidget-webkit-current-session)
                       (lambda () 'live-session)))
              (beacon-preview-build-and-refresh))
            (should (string= opened-file html-path))
            (should (string= opened-anchor "section")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-from-fenced-code-position ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (opened-file nil)
         (opened-anchor nil)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*")))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert
             "## 状態モデル: per-position tracker 配列\n\n"
             "singleton state machine + 2 スロットバッファ (`buffered_kana` / `buffered_kana_2`) "
             "を廃止し、per-position の `key_tracker[]` 配列に置き換える。\n\n"
             "```c\n"
             "#define NICOLA_MAX_TRACKERS 6   /* Kconfig で変更可能 */\n"
             "```\n"))
          (find-file source-file)
          (search-forward "#define")
          (setq-local major-mode 'markdown-mode)
          (let* ((artifacts (beacon-preview-build-current-file))
                 (html-path (plist-get artifacts :html)))
            (setq beacon-preview--last-url "file:///dummy")
            (setq beacon-preview--last-html-path html-path)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--open-preview)
                       (lambda (file &optional anchor)
                         (setq opened-file file)
                         (setq opened-anchor anchor)))
                      ((symbol-function 'xwidget-webkit-current-session)
                       (lambda () 'live-session)))
              (beacon-preview-build-and-refresh))
            (should (string= opened-file html-path))
            (should (string= opened-anchor
                             "状態モデル-per-position-tracker-配列")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-current-file-passes-pandoc-command ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-pandoc-command "/custom/bin/pandoc")
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (captured-args nil))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n"))
          (find-file source-file)
          (cl-letf (((symbol-function 'call-process)
                     (lambda (_program _infile destination _display &rest args)
                       (setq captured-args args)
                       (with-current-buffer (get-buffer-create destination)
                         (erase-buffer))
                       0))
                    ((symbol-function 'beacon-preview--command-available-p)
                     (lambda (_command) t))
                    ((symbol-function 'beacon-preview-load-manifest)
                     (lambda (_file)
                       (setq beacon-preview--manifest '((dummy . t))))))
            (beacon-preview-build-current-file)
            (should (member "--pandoc" captured-args))
            (should (member "/custom/bin/pandoc" captured-args)))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-current-file-errors-when-pandoc-is-missing ()
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-pandoc-command "missing-pandoc"))
      (cl-letf (((symbol-function 'beacon-preview--command-available-p)
                 (lambda (command)
                   (not (string= command "missing-pandoc")))))
        (should-error
         (beacon-preview-build-current-file)
         :type 'user-error)))))

(ert-deftest beacon-preview-build-current-file-surfaces-builder-output ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root)))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n"))
          (find-file source-file)
          (cl-letf (((symbol-function 'beacon-preview--command-available-p)
                     (lambda (_command) t))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'call-process)
                     (lambda (_program _infile destination _display &rest _args)
                       (with-current-buffer (get-buffer-create destination)
                         (erase-buffer)
                         (insert "build_preview.py: pandoc executable not found: pandoc\n"))
                       1)))
            (should-error
             (beacon-preview-build-current-file)
             :type 'user-error)))
      (ignore-errors
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-load-manifest-errors-cleanly-on-invalid-json ()
  (let ((manifest-file (make-temp-file "beacon-preview-manifest-" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file manifest-file
            (insert "{not valid json"))
          (should-error
           (beacon-preview-load-manifest manifest-file)
           :type 'user-error))
      (delete-file manifest-file))))

(ert-deftest beacon-preview-preview-url-adds-anchor-fragment ()
  (should (string-match-p "#section$"
                          (beacon-preview--preview-url "/tmp/sample.html" "section")))
  (should (string-match-p "#%E6%97%A5%E6%9C%AC%E8%AA%9E-%E8%A6%8B%E5%87%BA%E3%81%97$"
                          (beacon-preview--preview-url
                           "/tmp/sample.html"
                           "日本語-見出し")))
  (should (string-match-p "sample\\.html$"
                          (beacon-preview--preview-url "/tmp/sample.html" nil))))

(ert-deftest beacon-preview-open-preview-queues-position-sync-when-needed ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\n")
    (goto-char (point-max))
    (setq-local major-mode 'markdown-mode)
    (set-window-buffer (selected-window) (current-buffer))
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*"))
          (callback nil))
      (unwind-protect
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                     ((symbol-function 'featurep)
                      (lambda (feature)
                        (eq feature 'xwidget-internal)))
                     ((symbol-function 'beacon-preview--window-visible-ratio-for-pos)
                      (lambda (&optional _window _position)
                        0.5))
                     ((symbol-function 'beacon-preview--show-preview-buffer)
                      (lambda (_buffer) (selected-window)))
                     ((symbol-function 'xwidget-webkit-browse-url)
                      (lambda (_url &optional _new-session)
                        (set-buffer created-buffer)))
                     ((symbol-function 'xwidget-webkit-current-session)
                       (lambda () 'created-session))
                     ((symbol-function 'xwidget-buffer)
                       (lambda (_session) created-buffer))
                     ((symbol-function 'xwidget-put)
                      (lambda (_xwidget property value)
                        (when (eq property 'callback)
                          (setq callback value)))))
            (beacon-preview--open-preview "/tmp/sample.html" "section")
            (with-current-buffer created-buffer
              (should beacon-preview--pending-sync-script))
            (should (eq callback #'beacon-preview--xwidget-callback)))
        (kill-buffer created-buffer)))))

(ert-deftest beacon-preview-open-preview-uses-source-window-for-ratio ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\n")
    (goto-char (point-max))
    (setq-local major-mode 'markdown-mode)
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*"))
          (captured-window nil))
      (unwind-protect
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                     ((symbol-function 'featurep)
                      (lambda (feature)
                        (eq feature 'xwidget-internal)))
                     ((symbol-function 'beacon-preview--source-window)
                      (lambda (&optional _buffer)
                        'source-window))
                     ((symbol-function 'beacon-preview--target-source-position-maybe)
                      (lambda ()
                        'target-pos))
                     ((symbol-function 'beacon-preview--window-visible-ratio-for-pos)
                      (lambda (window position)
                        (setq captured-window window)
                        (should (eq position 'target-pos))
                        0.5))
                     ((symbol-function 'beacon-preview--show-preview-buffer)
                      (lambda (_buffer) (selected-window)))
                     ((symbol-function 'xwidget-webkit-browse-url)
                      (lambda (_url &optional _new-session)
                        (set-buffer created-buffer)))
	                       ((symbol-function 'xwidget-webkit-current-session)
	                        (lambda () 'created-session))
	                       ((symbol-function 'xwidget-put)
	                        (lambda (&rest _args) nil))
	                       ((symbol-function 'xwidget-buffer)
	                        (lambda (_session) created-buffer)))
            (beacon-preview--open-preview "/tmp/sample.html" "section")
            (should (eq captured-window 'source-window)))
        (kill-buffer created-buffer)))))

(ert-deftest beacon-preview-xwidget-callback-runs-pending-sync-after-load-finished ()
  (let ((preview-buffer (generate-new-buffer " *beacon-preview-xwidget*"))
        (executed nil)
        (scheduled nil)
        (last-input-event '(xwidget-event nil nil "load-finished")))
    (unwind-protect
        (with-current-buffer preview-buffer
          (setq beacon-preview--pending-sync-script "window.scrollTo(0, 10);")
          (cl-letf (((symbol-function 'xwidget-buffer)
                     (lambda (_xwidget) preview-buffer))
                    ((symbol-function 'xwidget-webkit-callback)
                     (lambda (_xwidget _event-type) nil))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn)
                       (setq scheduled fn)
                       'timer))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_xwidget script)
                       (setq executed script))))
            (beacon-preview--xwidget-callback 'dummy 'load-changed)
            (should scheduled)
            (funcall scheduled)
            (should (string= executed "window.scrollTo(0, 10);"))
            (should-not beacon-preview--pending-sync-script)))
      (kill-buffer preview-buffer))))

(ert-deftest beacon-preview-xwidget-callback-ignores-stale-sync-timer ()
  (let ((preview-buffer (generate-new-buffer " *beacon-preview-xwidget*"))
        (scheduled nil)
        (executed nil)
        (last-input-event '(xwidget-event nil nil "load-finished")))
    (unwind-protect
        (with-current-buffer preview-buffer
          (setq beacon-preview--pending-sync-script "window.scrollTo(0, 10);")
          (setq beacon-preview--pending-sync-generation 1)
          (cl-letf (((symbol-function 'xwidget-buffer)
                     (lambda (_xwidget) preview-buffer))
                    ((symbol-function 'xwidget-webkit-callback)
                     (lambda (_xwidget _event-type) nil))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn)
                       (setq scheduled fn)
                       'timer))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_xwidget script)
                       (setq executed script))))
            (beacon-preview--xwidget-callback 'dummy 'load-changed)
            (setq beacon-preview--pending-sync-generation 2)
            (funcall scheduled)
            (should-not executed)))
      (kill-buffer preview-buffer))))

(ert-deftest beacon-preview-jump-to-anchor-uses-source-window-for-ratio ()
  (with-temp-buffer
    (let ((captured-window nil)
          (executed nil))
      (cl-letf (((symbol-function 'beacon-preview--source-window)
                 (lambda (&optional _buffer)
                   'source-window))
                ((symbol-function 'beacon-preview--target-source-position-maybe)
                 (lambda ()
                   'target-pos))
                ((symbol-function 'beacon-preview--window-visible-ratio-for-pos)
                 (lambda (window position)
                   (setq captured-window window)
                   (should (eq position 'target-pos))
                   0.25))
                ((symbol-function 'beacon-preview--execute-script)
                 (lambda (script)
                   (setq executed script))))
        (beacon-preview-jump-to-anchor "section")
        (should (eq captured-window 'source-window))
        (should (string-match-p "section" executed))))))

(ert-deftest beacon-preview-current-session-uses-tracked-preview-buffer ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-xwidget*")))
      (unwind-protect
          (progn
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                       (lambda () 'tracked-session)))
              (should (eq (beacon-preview--current-session) 'tracked-session))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-label-preview-buffer-renames-and-links-source ()
  (with-temp-buffer
    (rename-buffer "source-buffer" t)
    (setq-local buffer-file-name "/tmp/example.md")
    (let ((source-buffer (current-buffer))
          (preview-buffer (generate-new-buffer " *preview*")))
      (unwind-protect
          (progn
            (beacon-preview--label-preview-buffer preview-buffer source-buffer)
            (should (string= (buffer-name preview-buffer)
                             "*beacon-preview: example.md*"))
            (with-current-buffer preview-buffer
              (should (eq beacon-preview--source-buffer source-buffer))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-build-and-refresh-reopens-when-preview-buffer-is-dead ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (reload-called nil)
         (opened-file nil))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n"))
          (find-file source-file)
          (let* ((artifacts (beacon-preview-build-current-file))
                 (html-path (plist-get artifacts :html))
                 (dead-buffer (generate-new-buffer " *dead-preview*")))
            (setq beacon-preview--last-url "file:///dummy")
            (setq beacon-preview--last-html-path html-path)
            (setq beacon-preview--xwidget-buffer dead-buffer)
            (kill-buffer dead-buffer)
            (cl-letf (((symbol-function 'beacon-preview--open-preview)
                       (lambda (file &optional _anchor) (setq opened-file file))))
              (beacon-preview-build-and-refresh))
            (should-not reload-called)
            (should (string= opened-file html-path)))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview--open-preview-records-created-preview-buffer ()
  (with-temp-buffer
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                       ((symbol-function 'featurep)
                        (lambda (feature)
                          (eq feature 'xwidget-internal)))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) (selected-window)))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (_url &optional _new-session)
                          (set-buffer created-buffer)))
	                     ((symbol-function 'xwidget-webkit-current-session)
	                      (lambda () 'created-session))
	                     ((symbol-function 'xwidget-put)
	                      (lambda (&rest _args) nil))
	                     ((symbol-function 'xwidget-buffer)
	                      (lambda (_session) created-buffer)))
              (beacon-preview--open-preview "/tmp/sample.html")
              (should (eq beacon-preview--xwidget-buffer created-buffer))
              (should (string-prefix-p "*beacon-preview:" (buffer-name created-buffer)))))
        (kill-buffer created-buffer)))))

(ert-deftest beacon-preview--open-preview-reuses-live-preview-buffer ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (goto-url nil)
          (browse-called nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                       ((symbol-function 'featurep)
                        (lambda (feature)
                          (eq feature 'xwidget-internal)))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) (selected-window)))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda () 'live-session))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (url) (setq goto-url url)))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (&rest _args) (setq browse-called t))))
              (beacon-preview--open-preview "/tmp/sample.html")
              (should (string-match-p "sample\\.html$" goto-url))
              (should-not browse-called)))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-switch-to-preview-displays-tracked-buffer ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-switch*"))
          (displayed nil))
      (unwind-protect
          (progn
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'display-buffer)
                       (lambda (buffer &optional _action)
                         (setq displayed buffer)
                         (selected-window))))
              (beacon-preview-switch-to-preview)
              (should (eq displayed preview-buffer))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-mode-runs-refresh-on-save ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-refresh-on-save t)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t))))
        (beacon-preview-mode 1)
        (run-hooks 'after-save-hook)
        (should refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-skips-unsupported-buffers ()
  (with-temp-buffer
    (setq-local major-mode 'text-mode)
    (setq-local buffer-file-name "/tmp/sample.txt")
    (let ((beacon-preview-auto-refresh-on-save t)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t))))
        (beacon-preview-mode 1)
        (run-hooks 'after-save-hook)
        (should-not refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-installs-keybindings ()
  (should (eq (lookup-key beacon-preview-command-map (kbd "o"))
              #'beacon-preview-build-and-open))
  (should (eq (lookup-key beacon-preview-command-map (kbd "r"))
              #'beacon-preview-build-and-refresh))
  (should (eq (lookup-key beacon-preview-command-map (kbd "d"))
              #'beacon-preview-toggle-debug))
  (should (eq (lookup-key beacon-preview-command-map (kbd "j"))
              #'beacon-preview-jump-to-current-heading)))

(ert-deftest beacon-preview-toggle-debug-flips-state ()
  (let ((beacon-preview-debug nil))
    (beacon-preview-toggle-debug)
    (should beacon-preview-debug)
    (beacon-preview-toggle-debug)
    (should-not beacon-preview-debug)))

(provide 'beacon-preview-tests)

;;; beacon-preview-tests.el ends here
