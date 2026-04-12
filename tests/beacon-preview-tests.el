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

(ert-deftest beacon-preview-current-heading-anchor-falls-back-when-manifest-entry-is-missing ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Repeat") (anchor . "repeat")))))
    (with-temp-buffer
      (insert "# Top\n\n## Repeat\nA\n\n## Repeat\nB\n")
      (goto-char (point-max))
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-heading-anchor) "repeat-1")))))

(ert-deftest beacon-preview-current-heading-anchor-falls-back-when-manifest-text-disagrees ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Other Section") (anchor . "other-section"))
           ((kind . "h2") (text . "Still Other") (anchor . "still-other")))))
    (with-temp-buffer
      (insert "# Top\n\n## Real Section\nBody\n")
      (goto-char (point-max))
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-heading-anchor) "real-section")))))

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

(ert-deftest beacon-preview-current-block-anchor-resolves-fenced-code-block-to-pre ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section"))
           ((kind . "pre") (index . 1) (anchor . "beacon-pre-1"))
           ((kind . "pre") (index . 2) (anchor . "beacon-pre-2")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "```elisp\n(message \"one\")\n```\n\n"
       "```elisp\n(message \"two\")\n```\n")
      (goto-char (point-min))
      (search-forward "two")
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-pre-2")))))

(ert-deftest beacon-preview-current-anchor-falls-back-to-heading-when-block-anchor-is-missing ()
  (let ((beacon-preview--manifest
         '(((kind . "h2")
            (text . "状態モデル: per-position tracker 配列")
            (anchor . "状態モデル-per-position-tracker-配列")))))
    (with-temp-buffer
      (insert
       "## 状態モデル: per-position tracker 配列\n\n"
       "```c\n"
       "#define NICOLA_MAX_TRACKERS 6\n"
       "```\n")
      (goto-char (point-min))
      (search-forward "#define")
      (setq-local major-mode 'markdown-mode)
      (should (string=
               (beacon-preview--current-anchor-maybe)
               "状態モデル-per-position-tracker-配列")))))

(ert-deftest beacon-preview-current-block-anchor-resolves-blockquote ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section"))
           ((kind . "blockquote") (index . 1) (anchor . "beacon-blockquote-1"))
           ((kind . "blockquote") (index . 2) (anchor . "beacon-blockquote-2")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "> first quote\n\n"
       "> second quote\n")
      (goto-char (point-min))
      (search-forward "second quote")
      (beginning-of-line)
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-blockquote-2")))))

(ert-deftest beacon-preview-current-block-anchor-resolves-table ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section"))
           ((kind . "table") (index . 1) (anchor . "beacon-table-1"))
           ((kind . "table") (index . 2) (anchor . "beacon-table-2")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "| A | B |\n"
       "| --- | --- |\n"
       "| 1 | 2 |\n\n"
       "| C | D |\n"
       "| --- | --- |\n"
       "| 3 | 4 |\n")
      (goto-char (point-min))
      (search-forward "| C | D |")
      (beginning-of-line)
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-table-2")))))

(ert-deftest beacon-preview-current-block-anchor-resolves-list-item ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section"))
           ((kind . "li") (index . 1) (anchor . "beacon-li-1"))
           ((kind . "li") (index . 2) (anchor . "beacon-li-2")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "- first item\n"
       "- second item\n")
      (goto-char (point-min))
      (search-forward "second item")
      (beginning-of-line)
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-li-2")))))

(ert-deftest beacon-preview-current-block-anchor-resolves-paragraph ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section"))
           ((kind . "p") (index . 1) (anchor . "beacon-p-1"))
           ((kind . "p") (index . 2) (anchor . "beacon-p-2")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "First paragraph line 1.\n"
       "Second line same paragraph.\n\n"
       "Another paragraph.\n")
      (goto-char (point-min))
      (search-forward "Another paragraph")
      (beginning-of-line)
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-p-2")))))

(ert-deftest beacon-preview-current-anchor-falls-back-to-heading-when-paragraph-anchor-is-missing ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "Section") (anchor . "section")))))
    (with-temp-buffer
      (insert
       "## Section\n\n"
       "Only paragraph text here.\n")
      (goto-char (point-min))
      (search-forward "Only paragraph")
      (setq-local major-mode 'markdown-mode)
      (should (string= (beacon-preview--current-anchor-maybe)
                       "section")))))

(ert-deftest beacon-preview-markdown-current-heading-ignores-atx-like-lines-inside-fenced-code-block ()
  (with-temp-buffer
    (insert
     "# Top\n\n"
     "## Real Section\n\n"
     "```markdown\n"
     "### Fake Heading\n"
     "still code\n"
     "```\n")
    (goto-char (point-min))
    (search-forward "still code")
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Real Section")))))

(ert-deftest beacon-preview-markdown-current-heading-ignores-setext-like-lines-inside-fenced-code-block ()
  (with-temp-buffer
    (insert
     "# Top\n\n"
     "## Real Section\n\n"
     "```text\n"
     "Fake Heading\n"
     "---\n"
     "still code\n"
     "```\n")
    (goto-char (point-min))
    (search-forward "still code")
    (setq-local major-mode 'markdown-mode)
    (should (equal (beacon-preview--markdown-current-heading)
                   '(:level 2 :text "Real Section")))))

(ert-deftest beacon-preview-markdown-current-heading-returns-nil-for-fence-only-pseudo-headings ()
  (with-temp-buffer
    (insert
     "```markdown\n"
     "# Fake Heading\n"
     "Pseudo Heading\n"
     "---\n"
     "```\n")
    (goto-char (point-min))
    (search-forward "Pseudo Heading")
    (setq-local major-mode 'markdown-mode)
    (should-not (beacon-preview--markdown-current-heading))))

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
    (should (string-match-p "setTimeout" script))
    (should (string-match-p "BeaconPreview\\.flashAnchor" script))))

(ert-deftest beacon-preview-edited-anchors-deduplicates-multiple-edits ()
  (let ((beacon-preview--manifest
         '(((kind . "p") (index . 1) (anchor . "beacon-p-1"))
           ((kind . "p") (index . 2) (anchor . "beacon-p-2")))))
    (with-temp-buffer
      (insert
       "First paragraph line 1.\n"
       "Second line same paragraph.\n\n"
       "Another paragraph.\n")
      (setq-local major-mode 'markdown-mode)
      (let ((first-pos 5)
            (duplicate-pos 12)
            (second-pos (save-excursion
                          (goto-char (point-min))
                          (search-forward "Another")
                          (match-beginning 0))))
        (setq-local beacon-preview--edited-positions
                    (list first-pos duplicate-pos second-pos))
        (should (equal (beacon-preview--edited-anchors)
                       '("beacon-p-1" "beacon-p-2")))))))

(ert-deftest beacon-preview-flash-visible-anchors-script-uses-visibility-gated-api ()
  (let ((script (beacon-preview--flash-visible-anchors-script
                 '("beacon-p-1" "beacon-p-2"))))
    (should (string-match-p "flashAnchorIfVisible" script))
    (should (string-match-p "beacon-p-1" script))
    (should (string-match-p "beacon-p-2" script))))

(ert-deftest beacon-preview-build-and-refresh-preserve-queues-visible-edited-flash ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (beacon-preview-refresh-jump-behavior 'preserve)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*"))
         (executed nil))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n"))
          (find-file source-file)
          (goto-char (point-min))
          (search-forward "First")
          (setq-local major-mode 'markdown-mode)
          (beacon-preview-build-current-file)
          (setq-local beacon-preview--edited-positions (list (point)))
          (setq beacon-preview--xwidget-buffer preview-buffer)
          (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                     (lambda () 'live-session))
                    ((symbol-function 'beacon-preview--open-preview)
                     (lambda (&rest _args)
                       (ert-fail "preserve mode should not reopen preview")))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_session script)
                       (setq executed script))))
            (beacon-preview-build-and-refresh))
          (should (string-match-p "sessionStorage\\.setItem" executed))
          (with-current-buffer preview-buffer
            (should (string-match-p "sessionStorage\\.getItem"
                                    beacon-preview--pending-sync-script))
            (should (string-match-p "flashAnchorIfVisible"
                                    beacon-preview--pending-sync-script))
            (should (string-match-p "beacon-p-1"
                                    beacon-preview--pending-sync-script)))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

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

(ert-deftest beacon-preview-build-and-refresh-preserves-preview-position-when-configured ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (beacon-preview-refresh-jump-behavior 'preserve)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*"))
         (executed nil)
         (opened nil))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "# Title\n\n## Section\nBody\n"))
          (find-file source-file)
          (goto-char (point-max))
          (setq-local major-mode 'markdown-mode)
          (beacon-preview-build-current-file)
          (setq beacon-preview--xwidget-buffer preview-buffer)
          (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                     (lambda () 'live-session))
                    ((symbol-function 'beacon-preview--open-preview)
                     (lambda (&rest _args)
                       (setq opened t)))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_session script)
                       (setq executed script))))
            (beacon-preview-build-and-refresh))
          (should-not opened)
          (should (string-match-p "sessionStorage\\.setItem" executed))
          (with-current-buffer preview-buffer
            (should (string-match-p "sessionStorage\\.getItem"
                                    beacon-preview--pending-sync-script)))
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
            (should (string= opened-anchor "beacon-pre-1")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-from-blockquote-position ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (opened-file nil)
         (opened-anchor nil)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*")))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "## Section\n\n> first quote\n\n> second quote\n"))
          (find-file source-file)
          (search-forward "second quote")
          (beginning-of-line)
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
            (should (string= opened-anchor "beacon-blockquote-2")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-from-table-position ()
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
             "## Section\n\n"
             "| A | B |\n"
             "| --- | --- |\n"
             "| 1 | 2 |\n\n"
             "| C | D |\n"
             "| --- | --- |\n"
             "| 3 | 4 |\n"))
          (find-file source-file)
          (search-forward "| C | D |")
          (beginning-of-line)
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
            (should (string= opened-anchor "beacon-table-2")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-from-list-item-position ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
         (opened-file nil)
         (opened-anchor nil)
         (preview-buffer (generate-new-buffer " *beacon-preview-live*")))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "## Section\n\n- first item\n- second item\n"))
          (find-file source-file)
          (search-forward "second item")
          (beginning-of-line)
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
            (should (string= opened-anchor "beacon-li-2")))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (buffer-live-p preview-buffer)
          (kill-buffer preview-buffer))
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-reopens-live-preview-from-paragraph-position ()
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
             "## Section\n\n"
             "First paragraph line 1.\n"
             "Second line same paragraph.\n\n"
             "Another paragraph.\n"))
          (find-file source-file)
          (search-forward "Another paragraph")
          (beginning-of-line)
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
            (should (string= opened-anchor "beacon-p-2")))
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

(ert-deftest beacon-preview-jump-to-current-block-prefers-block-anchor ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (let ((jumped-anchor nil))
      (cl-letf (((symbol-function 'beacon-preview-current-block-anchor)
                 (lambda () "beacon-pre-1"))
                ((symbol-function 'beacon-preview-current-heading-anchor)
                 (lambda () "section"))
                ((symbol-function 'beacon-preview-jump-to-anchor)
                 (lambda (anchor)
                   (setq jumped-anchor anchor))))
        (beacon-preview-jump-to-current-block)
        (should (string= jumped-anchor "beacon-pre-1"))))))

(ert-deftest beacon-preview-jump-to-current-block-falls-back-to-heading-anchor ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (let ((jumped-anchor nil))
      (cl-letf (((symbol-function 'beacon-preview-current-block-anchor)
                 (lambda () nil))
                ((symbol-function 'beacon-preview-current-heading-anchor)
                 (lambda () "section"))
                ((symbol-function 'beacon-preview-jump-to-anchor)
                 (lambda (anchor)
                   (setq jumped-anchor anchor))))
        (beacon-preview-jump-to-current-block)
        (should (string= jumped-anchor "section"))))))

(ert-deftest beacon-preview-jump-to-current-block-errors-when-no-anchor-exists ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (cl-letf (((symbol-function 'beacon-preview-current-block-anchor)
               (lambda () nil))
              ((symbol-function 'beacon-preview-current-heading-anchor)
               (lambda () (user-error "No heading"))))
      (should-error (beacon-preview-jump-to-current-block)
                    :type 'user-error))))

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

(ert-deftest beacon-preview-tracks-preview-buffers-per-source-buffer ()
  (let ((source-a (generate-new-buffer " *beacon-preview-source-a*"))
        (source-b (generate-new-buffer " *beacon-preview-source-b*"))
        (preview-a (generate-new-buffer " *beacon-preview-preview-a*"))
        (preview-b (generate-new-buffer " *beacon-preview-preview-b*"))
        (displayed nil))
    (unwind-protect
        (progn
          (with-current-buffer source-a
            (setq-local major-mode 'markdown-mode)
            (setq-local buffer-file-name "/tmp/a.md")
            (setq-local beacon-preview--xwidget-buffer preview-a))
          (with-current-buffer source-b
            (setq-local major-mode 'markdown-mode)
            (setq-local buffer-file-name "/tmp/b.md")
            (setq-local beacon-preview--xwidget-buffer preview-b))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buffer &optional _action)
                       (setq displayed buffer)
                       (selected-window))))
            (with-current-buffer source-a
              (beacon-preview-switch-to-preview)
              (should (eq displayed preview-a)))
            (with-current-buffer source-b
              (beacon-preview-switch-to-preview)
              (should (eq displayed preview-b)))))
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))
            (list source-a source-b preview-a preview-b)))))

(ert-deftest beacon-preview-current-session-stays-buffer-local-across-sources ()
  (let ((source-a (generate-new-buffer " *beacon-preview-session-source-a*"))
        (source-b (generate-new-buffer " *beacon-preview-session-source-b*"))
        (preview-a (generate-new-buffer " *beacon-preview-session-preview-a*"))
        (preview-b (generate-new-buffer " *beacon-preview-session-preview-b*")))
    (unwind-protect
        (progn
          (with-current-buffer source-a
            (setq-local beacon-preview--xwidget-buffer preview-a))
          (with-current-buffer source-b
            (setq-local beacon-preview--xwidget-buffer preview-b))
          (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                     (lambda ()
                       (cond
                        ((eq (current-buffer) preview-a) 'session-a)
                        ((eq (current-buffer) preview-b) 'session-b)
                        (t nil)))))
            (with-current-buffer source-a
              (should (eq (beacon-preview--current-session) 'session-a)))
            (with-current-buffer source-b
              (should (eq (beacon-preview--current-session) 'session-b)))))
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))
            (list source-a source-b preview-a preview-b)))))

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

(ert-deftest beacon-preview-after-save-clears-edited-positions ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (setq-local beacon-preview--edited-positions '(10 20))
    (let ((beacon-preview-auto-refresh-on-save t))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () nil)))
        (beacon-preview--after-save)
        (should-not beacon-preview--edited-positions)))))

(ert-deftest beacon-preview-post-command-schedules-display-follow-on-window-change ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (let ((beacon-preview-follow-window-display-changes t)
          (beacon-preview--xwidget-buffer (generate-new-buffer " *beacon-preview-live*"))
          (scheduled nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'beacon-preview--live-preview-p)
                       (lambda () t))
                      ((symbol-function 'beacon-preview--source-window)
                       (lambda (&optional _buffer) 'source-window))
                      ((symbol-function 'window-start)
                       (lambda (_window) 100))
                      ((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat fn buffer)
                         (setq scheduled (list fn buffer))
                         'timer)))
              (setq beacon-preview--last-window-start 10)
              (setq beacon-preview--last-point (point-min))
              (beacon-preview--post-command)
              (should scheduled)))
        (when (buffer-live-p beacon-preview--xwidget-buffer)
          (kill-buffer beacon-preview--xwidget-buffer))))))

(ert-deftest beacon-preview-post-command-ignores-unchanged-display-state ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (let ((beacon-preview-follow-window-display-changes t)
          (beacon-preview--xwidget-buffer (generate-new-buffer " *beacon-preview-live*"))
          (scheduled nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'beacon-preview--live-preview-p)
                       (lambda () t))
                      ((symbol-function 'beacon-preview--source-window)
                       (lambda (&optional _buffer) 'source-window))
                      ((symbol-function 'window-start)
                       (lambda (_window) 10))
                      ((symbol-function 'run-with-idle-timer)
                       (lambda (&rest _args)
                         (setq scheduled t)
                         'timer)))
              (setq beacon-preview--last-window-start 10)
              (setq beacon-preview--last-point (point))
              (beacon-preview--post-command)
              (should-not scheduled)))
        (when (buffer-live-p beacon-preview--xwidget-buffer)
          (kill-buffer beacon-preview--xwidget-buffer))))))

(ert-deftest beacon-preview-toggle-refresh-jump-behavior-flips-state ()
  (let ((beacon-preview-refresh-jump-behavior 'block))
    (beacon-preview-toggle-refresh-jump-behavior)
    (should (eq beacon-preview-refresh-jump-behavior 'preserve))
    (beacon-preview-toggle-refresh-jump-behavior)
    (should (eq beacon-preview-refresh-jump-behavior 'block))))

(ert-deftest beacon-preview-toggle-follow-window-display-changes-flips-state ()
  (let ((beacon-preview-follow-window-display-changes nil))
    (beacon-preview-toggle-follow-window-display-changes)
    (should beacon-preview-follow-window-display-changes)
    (beacon-preview-toggle-follow-window-display-changes)
    (should-not beacon-preview-follow-window-display-changes)))

(ert-deftest beacon-preview-mode-runs-refresh-on-revert-with-live-preview ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-refresh-on-revert t)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () t)))
        (beacon-preview-mode 1)
        (run-hooks 'after-revert-hook)
        (should refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-skips-refresh-on-revert-without-live-preview ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-refresh-on-revert t)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () nil)))
        (beacon-preview-mode 1)
        (run-hooks 'after-revert-hook)
        (should-not refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-skips-refresh-on-revert-when-disabled ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-refresh-on-revert nil)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () t)))
        (beacon-preview-mode 1)
        (run-hooks 'after-revert-hook)
        (should-not refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-skips-unsupported-buffers ()
  (with-temp-buffer
    (setq-local major-mode 'text-mode)
    (setq-local buffer-file-name "/tmp/sample.txt")
    (let ((beacon-preview-auto-refresh-on-save t)
          (beacon-preview-auto-refresh-on-revert t)
          (refresh-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-refresh)
                 (lambda () (setq refresh-called t))))
        (beacon-preview-mode 1)
        (run-hooks 'after-save-hook)
        (run-hooks 'after-revert-hook)
        (should-not refresh-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-does-not-auto-start-preview-by-default ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-start-on-enable nil)
          (open-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda () (setq open-called t))))
        (beacon-preview-mode 1)
        (should-not open-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-can-auto-start-preview-on-enable ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-start-on-enable t)
          (open-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda () (setq open-called t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () nil)))
        (beacon-preview-mode 1)
        (should open-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-skips-auto-start-when-preview-is-already-live ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (setq-local buffer-file-name "/tmp/sample.md")
    (let ((beacon-preview-auto-start-on-enable t)
          (open-called nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda () (setq open-called t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () t)))
        (beacon-preview-mode 1)
        (should-not open-called)
        (beacon-preview-mode 0)))))

(ert-deftest beacon-preview-mode-installs-keybindings ()
  (should (eq (lookup-key beacon-preview-command-map (kbd "o"))
              #'beacon-preview-build-and-open))
  (should (eq (lookup-key beacon-preview-command-map (kbd "r"))
              #'beacon-preview-build-and-refresh))
  (should (eq (lookup-key beacon-preview-command-map (kbd "d"))
              #'beacon-preview-toggle-debug))
  (should (eq (lookup-key beacon-preview-command-map (kbd "j"))
              #'beacon-preview-jump-to-current-heading))
  (should (eq (lookup-key beacon-preview-command-map (kbd "b"))
              #'beacon-preview-jump-to-current-block))
  (should (eq (lookup-key beacon-preview-command-map (kbd "f"))
              #'beacon-preview-toggle-refresh-jump-behavior))
  (should (eq (lookup-key beacon-preview-command-map (kbd "w"))
              #'beacon-preview-toggle-follow-window-display-changes)))

(ert-deftest beacon-preview-toggle-debug-flips-state ()
  (let ((beacon-preview-debug nil))
    (beacon-preview-toggle-debug)
    (should beacon-preview-debug)
    (beacon-preview-toggle-debug)
    (should-not beacon-preview-debug)))

(provide 'beacon-preview-tests)

;;; beacon-preview-tests.el ends here
