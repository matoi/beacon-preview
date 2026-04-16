;;; beacon-preview-tests.el --- Tests for beacon-preview -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load-file
 (expand-file-name "../lisp/beacon-preview.el"
                   (file-name-directory
                    (or load-file-name buffer-file-name))))

(defun beacon-preview-test--sync-async-build (callback)
  "Synchronous stand-in for `beacon-preview--build-current-file-async' in tests."
  (let ((artifacts (beacon-preview-build-current-file)))
    (funcall callback artifacts)))

;; Force async builds to run synchronously during tests so that
;; process sentinels are not needed in batch mode.
(advice-add 'beacon-preview--build-current-file-async :override
            #'beacon-preview-test--sync-async-build)

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

(ert-deftest beacon-preview-org-current-heading-anchor-prefers-manifest ()
  (let ((beacon-preview--manifest
         '(((kind . "h1") (text . "Title") (anchor . "title"))
           ((kind . "h2") (text . "Section") (anchor . "section-1")))))
    (with-temp-buffer
      (insert "* Title\n\n** Section\nBody\n")
      (goto-char (point-max))
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-heading-anchor) "section-1")))))

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

(ert-deftest beacon-preview-org-current-block-anchor-resolves-list-item ()
  (let ((beacon-preview--manifest
         '(((kind . "li") (index . 1) (anchor . "beacon-li-1"))
           ((kind . "li") (index . 2) (anchor . "beacon-li-2")))))
    (with-temp-buffer
      (insert "- first item\n- second item\n")
      (goto-char (point-min))
      (search-forward "second item")
      (beginning-of-line)
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-li-2")))))

(ert-deftest beacon-preview-org-current-block-anchor-resolves-paragraph ()
  (let ((beacon-preview--manifest
         '(((kind . "p") (index . 1) (anchor . "beacon-p-1"))
           ((kind . "p") (index . 2) (anchor . "beacon-p-2")))))
    (with-temp-buffer
      (insert
       "First paragraph line 1.\n"
       "Second line same paragraph.\n\n"
       "Another paragraph.\n")
      (goto-char (point-min))
      (search-forward "Another paragraph")
      (beginning-of-line)
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-p-2")))))

(ert-deftest beacon-preview-org-current-block-anchor-resolves-quote-block ()
  (let ((beacon-preview--manifest
         '(((kind . "blockquote") (index . 1) (anchor . "beacon-blockquote-1")))))
    (with-temp-buffer
      (insert
       "#+begin_quote\n"
       "quoted text\n"
       "#+end_quote\n")
      (goto-char (point-min))
      (search-forward "quoted text")
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-blockquote-1")))))

(ert-deftest beacon-preview-org-current-block-anchor-resolves-source-block ()
  (let ((beacon-preview--manifest
         '(((kind . "pre") (index . 1) (anchor . "beacon-pre-1")))))
    (with-temp-buffer
      (insert
       "#+begin_src emacs-lisp\n"
       "(message \"hi\")\n"
       "#+end_src\n")
      (goto-char (point-min))
      (search-forward "message")
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-pre-1")))))

(ert-deftest beacon-preview-org-current-block-anchor-resolves-table ()
  (let ((beacon-preview--manifest
         '(((kind . "table") (index . 1) (anchor . "beacon-table-1")))))
    (with-temp-buffer
      (insert
       "| A | B |\n"
       "|---+---|\n"
       "| 1 | 2 |\n")
      (goto-char (point-min))
      (search-forward "| 1 | 2 |")
      (beginning-of-line)
      (setq-local major-mode 'org-mode)
      (should (string= (beacon-preview-current-block-anchor)
                       "beacon-table-1")))))

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

(ert-deftest beacon-preview-current-anchor-prefers-previous-block-on-blank-line ()
  (let ((beacon-preview--manifest
         '(((kind . "h2") (text . "HTML Pipeline") (anchor . "html-pipeline"))
           ((kind . "p") (index . 1) (anchor . "beacon-p-1"))
           ((kind . "li") (index . 1) (anchor . "beacon-li-1"))
           ((kind . "li") (index . 2) (anchor . "beacon-li-2"))
           ((kind . "li") (index . 3) (anchor . "beacon-li-3"))
           ((kind . "li") (index . 4) (anchor . "beacon-li-4"))
           ((kind . "li") (index . 5) (anchor . "beacon-li-5"))
           ((kind . "p") (index . 2) (anchor . "beacon-p-2")))))
    (with-temp-buffer
      (insert
       "## HTML Pipeline\n\n"
       "The generated preview HTML contains:\n\n"
       "- `id` attributes usable as anchor targets\n"
       "- `data-beacon-kind`\n"
       "- `data-beacon-index`\n"
       "- manifest metadata for editor-side lookup\n"
       "- a browser-side `window.BeaconPreview` API\n\n"
       "That browser-side API exposes:\n")
      (setq-local major-mode 'markdown-mode)
      (goto-char (point-min))
      (search-forward "window.BeaconPreview")
      (end-of-line)
      (forward-line 1)
      (beginning-of-line)
      (should (string= (beacon-preview--current-anchor-maybe)
                       "beacon-li-5")))))

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

(ert-deftest beacon-preview-build-and-refresh-does-not-create-preview-when-none-exists ()
  (with-temp-buffer
    (setq beacon-preview--xwidget-buffer nil)
    (let ((opened nil))
      (cl-letf (((symbol-function 'beacon-preview-build-current-file)
                 (lambda () '(:html "/tmp/sample.html" :manifest "/tmp/sample.json")))
                ((symbol-function 'beacon-preview--open-preview)
                 (lambda (&rest _args) (setq opened t))))
        (beacon-preview-build-and-refresh)
        (should-not opened)))))

(ert-deftest beacon-preview-dwim-builds-and-opens-when-no-live-preview ()
  (with-temp-buffer
    (setq beacon-preview--xwidget-buffer nil)
    (let ((opened nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda () (setq opened t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () nil)))
        (beacon-preview-dwim)
        (should opened)))))

(ert-deftest beacon-preview-dwim-jumps-to-block-when-preview-is-live ()
  (with-temp-buffer
    (setq beacon-preview--xwidget-buffer (current-buffer))
    (let ((jumped nil))
      (cl-letf (((symbol-function 'beacon-preview-jump-to-current-block)
                 (lambda () (setq jumped t)))
                ((symbol-function 'beacon-preview--live-preview-p)
                 (lambda () t)))
        (beacon-preview-dwim)
        (should jumped)))))

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

(ert-deftest beacon-preview-edited-anchors-resolve-near-blank-boundaries ()
  (let ((beacon-preview--manifest
         '(((kind . "p") (index . 1) (anchor . "beacon-p-1"))
           ((kind . "p") (index . 2) (anchor . "beacon-p-2")))))
    (with-temp-buffer
      (insert
       "First paragraph.\n\n"
       "Second paragraph.\n")
      (setq-local major-mode 'markdown-mode)
      (goto-char (point-min))
      (search-forward "First paragraph.")
      (forward-line 1)
      (beginning-of-line)
      (setq-local beacon-preview--edited-positions (list (point)))
      (should (equal (beacon-preview--edited-anchors)
                     '("beacon-p-1"))))))

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

(ert-deftest beacon-preview-build-current-file-creates-temp-artifacts-for-unvisited-buffer ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root)))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "draft-notes" t)
          (setq-local major-mode 'markdown-mode)
          (setq default-directory tmp-root)
          (insert "# Title\n\n## Section\n\nBody\n")
          (let ((artifacts (beacon-preview-build-current-file)))
            (should (file-exists-p (plist-get artifacts :html)))
            (should (file-exists-p (plist-get artifacts :manifest)))
            (should (string-prefix-p
                     (file-name-as-directory (expand-file-name beacon-preview-temporary-root))
                     (plist-get artifacts :html)))
            (should (string-match-p "draft-notes\\.html\\'" (plist-get artifacts :html)))
            (should beacon-preview--manifest)))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-current-file-errors-for-unvisited-unsupported-buffer ()
  (with-temp-buffer
    (setq-local major-mode 'text-mode)
    (should-error
     (beacon-preview-build-current-file)
     :type 'user-error)))

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

(ert-deftest beacon-preview-dwim-url-adds-anchor-fragment ()
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
          (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                      (lambda () t))
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

(ert-deftest beacon-preview-open-preview-queues-position-sync-without-ratio ()
  (with-temp-buffer
    (insert "# Top\n\n## Section\n")
    (goto-char (point-max))
    (setq-local major-mode 'markdown-mode)
    (set-window-buffer (selected-window) (current-buffer))
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*"))
          (callback nil))
      (unwind-protect
          (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                      (lambda () t))
                     ((symbol-function 'beacon-preview--window-visible-ratio-for-pos)
                      (lambda (&optional _window _position)
                        nil))
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
              (should beacon-preview--pending-sync-script)
              (should (string-match-p "BeaconPreview\\.flashAnchor"
                                      beacon-preview--pending-sync-script))
              (should (string-match-p "section"
                                      beacon-preview--pending-sync-script)))
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
          (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                      (lambda () t))
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
        (source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (executed nil)
        (scheduled nil)
        (last-input-event '(xwidget-event nil nil "load-finished")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (rename-buffer "example.md" t)
            (setq-local buffer-file-name "/tmp/example.md"))
          (with-current-buffer preview-buffer
            (setq beacon-preview--source-buffer source-buffer)
            (setq beacon-preview--pending-sync-script "window.scrollTo(0, 10);"))
          (cl-letf (((symbol-function 'xwidget-buffer)
                     (lambda (_xwidget) preview-buffer))
                    ((symbol-function 'xwidget-webkit-callback)
                     (lambda (_xwidget _event-type)
                       (with-current-buffer preview-buffer
                         (rename-buffer "*xwidget-webkit: README*" t))))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn)
                       (setq scheduled fn)
                       'timer))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_xwidget script)
                       (setq executed script))))
            (beacon-preview--xwidget-callback 'dummy 'load-changed)
            (should (string= (buffer-name preview-buffer)
                             "*beacon-preview: example.md*"))
            (should scheduled)
            (funcall scheduled)
            (should (string= executed "window.scrollTo(0, 10);"))
            (with-current-buffer preview-buffer
              (should-not beacon-preview--pending-sync-script))))
      (kill-buffer preview-buffer)
      (kill-buffer source-buffer))))

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

(ert-deftest beacon-preview-sync-source-to-preview-moves-to-visible-markdown-block ()
  (let ((source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (preview-buffer (generate-new-buffer " *beacon-preview-dwim*"))
        (original-point nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert
             "# Heading\n\n"
             "First paragraph.\n\n"
             "Second paragraph.\n")
            (setq-local major-mode 'markdown-mode)
            (setq-local beacon-preview--xwidget-buffer preview-buffer)
            (setq original-point (point)))
          (with-current-buffer preview-buffer
            (setq-local major-mode 'xwidget-webkit-mode)
            (setq-local beacon-preview--source-buffer source-buffer))
          (switch-to-buffer preview-buffer)
          (let ((recenter-arg nil))
            (cl-letf (((symbol-function 'beacon-preview--xwidget-session-for-buffer)
                       (lambda (_buffer &optional _window)
                         'session))
                      ((symbol-function 'xwidget-webkit-execute-script)
                       (lambda (_session _script callback)
                         (funcall callback "{\"anchor\":\"beacon-p-2\",\"kind\":\"p\",\"index\":2,\"ratio\":0.75}")))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &optional _action)
                         (set-window-buffer (selected-window) buffer)
                         (selected-window)))
                      ((symbol-function 'recenter)
                       (lambda (&optional arg)
                         (setq recenter-arg arg))))
              (beacon-preview-sync-source-to-preview)
              (with-current-buffer source-buffer
                (should (equal (line-number-at-pos (point)) 5))
                (should (= (mark t) original-point))
                (pop-to-mark-command)
                (should (= (point) original-point)))
              (should (eq (window-buffer (selected-window)) source-buffer))
              (should (integerp recenter-arg))
              (should (> recenter-arg 0)))))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer))))

(ert-deftest beacon-preview-target-source-position-prefers-previous-block-on-blank-line ()
  (with-temp-buffer
    (insert
     "## HTML Pipeline\n\n"
     "The generated preview HTML contains:\n\n"
     "- item one\n"
     "- item two\n\n"
     "That browser-side API exposes:\n")
    (setq-local major-mode 'markdown-mode)
    (goto-char (point-min))
    (search-forward "item two")
    (beginning-of-line)
    (let ((expected (point)))
      (end-of-line)
      (forward-line 1)
      (beginning-of-line)
      (should (= (beacon-preview--target-source-position-at-pos (point))
                 expected)))))

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

(ert-deftest beacon-preview-xwidget-session-for-buffer-falls-back-to-visible-window ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-xwidget*"))
          (session-calls 0))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (buffer &optional _all-frames)
                         (when (eq buffer preview-buffer)
                           (selected-window))))
                      ((symbol-function 'xwidget-webkit-current-session)
                       (lambda ()
                         (setq session-calls (1+ session-calls))
                         (if (eq (window-buffer (selected-window)) preview-buffer)
                             'tracked-session
                           nil))))
              (should (eq (beacon-preview--xwidget-session-for-buffer preview-buffer)
                          'tracked-session))
              (should (> session-calls 1))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-initialize-preview-buffer-tracks-buffer-and-queues-sync ()
  (with-temp-buffer
    (let ((source-buffer (current-buffer))
          (preview-buffer (generate-new-buffer " *beacon-preview-created*")))
      (unwind-protect
          (cl-letf (((symbol-function 'xwidget-buffer)
                     (lambda (_session) preview-buffer)))
            (should (eq (beacon-preview--initialize-preview-buffer
                         source-buffer
                         'created-session
                         "section"
                         nil)
                        preview-buffer))
            (with-current-buffer source-buffer
              (should (eq beacon-preview--xwidget-buffer preview-buffer)))
            (with-current-buffer preview-buffer
              (should beacon-preview--pending-sync-script)
              (should (eq beacon-preview--source-buffer source-buffer))))
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
                              "*beacon-preview: source-buffer*"))
             (with-current-buffer preview-buffer
               (should (eq beacon-preview--source-buffer source-buffer))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-dwim-buffer-name-uses-source-buffer-name ()
  (with-temp-buffer
    (rename-buffer "notes.md<docs>" t)
    (setq-local buffer-file-name "/tmp/worktrees/demo/docs/notes.md")
    (should (string=
             (beacon-preview--preview-buffer-name (current-buffer))
             "*beacon-preview: notes.md<docs>*"))))

(ert-deftest beacon-preview-rename-buffer-updates-tracked-preview-name ()
  (with-temp-buffer
    (rename-buffer "notes.md" t)
    (let ((source-buffer (current-buffer))
          (preview-buffer (generate-new-buffer " *preview*")))
      (unwind-protect
          (progn
            (setq-local beacon-preview--xwidget-buffer preview-buffer)
            (beacon-preview--label-preview-buffer preview-buffer source-buffer)
            (rename-buffer "notes.md<project>" t)
            (should (string= (buffer-name preview-buffer)
                             "*beacon-preview: notes.md<project>*")))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-after-set-visited-file-name-updates-tracked-preview-name ()
  (with-temp-buffer
    (rename-buffer "notes.md" t)
    (let ((source-buffer (current-buffer))
          (preview-buffer (generate-new-buffer " *preview*")))
      (unwind-protect
          (progn
            (setq-local beacon-preview--xwidget-buffer preview-buffer)
            (beacon-preview--label-preview-buffer preview-buffer source-buffer)
            (rename-buffer "notes.org" t)
            (beacon-preview--after-set-visited-file-name)
            (should (string= (buffer-name preview-buffer)
                             "*beacon-preview: notes.org*")))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-build-and-refresh-skips-open-when-preview-buffer-is-dead ()
  (let* ((tmp-root (make-temp-file "beacon-preview-ert-" t))
         (source-file (expand-file-name "sample.md" tmp-root))
         (beacon-preview-temporary-root (expand-file-name "preview-root" tmp-root))
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
                       (lambda (file &optional _anchor _explicit)
                         (setq opened-file file))))
              (beacon-preview-build-and-refresh))
            (should-not opened-file))
          (kill-buffer (current-buffer)))
      (ignore-errors
        (when (get-file-buffer source-file)
          (kill-buffer (get-file-buffer source-file))))
      (delete-directory tmp-root t))))

(ert-deftest beacon-preview-build-and-refresh-does-not-reclaim-hidden-preview-window-by-default ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (other-buffer (generate-new-buffer " *beacon-preview-other*"))
          (preview-window (split-window-right))
          (browse-called nil)
          (goto-url nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (set-window-buffer preview-window other-buffer)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (let ((beacon-preview-reveal-hidden-preview-window nil))
              (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                         (lambda () t))
                        ((symbol-function 'get-buffer-window)
                         (lambda (_buffer &optional _all-frames) nil))
                        ((symbol-function 'xwidget-webkit-current-session)
                         (lambda () nil))
                        ((symbol-function 'beacon-preview--show-preview-buffer)
                         (lambda (_buffer)
                           (setq browse-called 'reclaimed)
                           preview-window))
                        ((symbol-function 'xwidget-webkit-goto-url)
                         (lambda (url) (setq goto-url url)))
                        ((symbol-function 'xwidget-webkit-browse-url)
                         (lambda (&rest _args)
                           (setq browse-called t))))
                (beacon-preview--open-preview "/tmp/sample.html" nil nil)
                (should-not browse-called)
                (should-not goto-url)
                (should (eq (window-buffer preview-window) other-buffer)))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
        (kill-buffer preview-buffer)
        (kill-buffer other-buffer)))))

(ert-deftest beacon-preview-build-and-open-may-reclaim-hidden-preview-window-explicitly ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (other-buffer (generate-new-buffer " *beacon-preview-other*"))
          (preview-window (split-window-right))
          (goto-url nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (set-window-buffer preview-window other-buffer)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                       (lambda () t))
                      ((symbol-function 'get-buffer-window)
                       (lambda (buffer &optional _all-frames)
                         (when (eq buffer preview-buffer)
                           preview-window)))
                      ((symbol-function 'beacon-preview--show-preview-buffer)
                       (lambda (_buffer) preview-window))
                      ((symbol-function 'xwidget-webkit-current-session)
                       (lambda () 'live-session))
                      ((symbol-function 'xwidget-webkit-goto-url)
                       (lambda (url) (setq goto-url url))))
              (beacon-preview--open-preview "/tmp/sample.html" nil t)
              (should (string-match-p "sample\\.html$" goto-url))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
        (kill-buffer preview-buffer)
        (kill-buffer other-buffer)))))

(ert-deftest beacon-preview-build-and-refresh-does-not-reuse-hidden-live-session-by-default ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (goto-url nil)
          (browse-called nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (let ((beacon-preview-reveal-hidden-preview-window nil))
              (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                         (lambda () t))
                        ((symbol-function 'get-buffer-window)
                         (lambda (_buffer &optional _all-frames) nil))
                        ((symbol-function 'xwidget-webkit-current-session)
                         (lambda () 'live-session))
                        ((symbol-function 'beacon-preview--show-preview-buffer)
                         (lambda (_buffer)
                           (ert-fail "Hidden preview should not be shown by default")))
                        ((symbol-function 'xwidget-webkit-goto-url)
                         (lambda (url) (setq goto-url url)))
                        ((symbol-function 'xwidget-webkit-browse-url)
                         (lambda (&rest _args)
                           (setq browse-called t))))
                (beacon-preview--open-preview "/tmp/sample.html" nil nil)
                (should-not goto-url)
                (should-not browse-called)))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--open-preview-records-created-preview-buffer ()
  (with-temp-buffer
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
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
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) (selected-window)))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda () 'live-session))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (url) (setq goto-url url)))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (&rest _args) (setq browse-called t))))
              (beacon-preview--open-preview "/tmp/sample.html" nil t)
              (should (string-match-p "sample\\.html$" goto-url))
              (should-not browse-called)))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--open-preview-reuses-visible-preview-buffer-with-session-fallback ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (goto-url nil)
          (browse-called nil)
          (session-calls 0))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) (selected-window)))
                       ((symbol-function 'get-buffer-window)
                        (lambda (buffer &optional _all-frames)
                          (when (eq buffer preview-buffer)
                            (selected-window))))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda ()
                          (setq session-calls (1+ session-calls))
                          (if (eq (window-buffer (selected-window)) preview-buffer)
                              'live-session
                            nil)))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (url) (setq goto-url url)))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (&rest _args) (setq browse-called t))))
              (beacon-preview--open-preview "/tmp/sample.html")
              (should (string-match-p "sample\\.html$" goto-url))
               (should-not browse-called)
               (should (> session-calls 1))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--show-preview-buffer-creates-dedicated-frame ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (created-frame 'preview-frame)
          (created-window 'preview-window)
          (used-params nil)
          (assigned nil)
          (display-called nil)
          (beacon-preview-display-location 'dedicated-frame)
          (beacon-preview-dedicated-frame-parameters '((name . "Beacon Preview"))))
      (unwind-protect
          (cl-letf (((symbol-function 'get-buffer-window)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'frame-live-p)
                     (lambda (frame) (eq frame created-frame)))
                    ((symbol-function 'make-frame)
                     (lambda (params)
                       (setq used-params params)
                       created-frame))
                    ((symbol-function 'frame-root-window)
                     (lambda (_frame) created-window))
                    ((symbol-function 'set-window-buffer)
                     (lambda (window buffer)
                       (setq assigned (list window buffer))))
                    ((symbol-function 'display-buffer)
                     (lambda (&rest _args)
                       (setq display-called t))))
            (should (eq (beacon-preview--show-preview-buffer preview-buffer)
                        created-window))
            (should (equal used-params
                           '((name . "Beacon Preview")
                             (beacon-preview-dedicated . t))))
            (should (equal assigned (list created-window preview-buffer)))
            (should (eq beacon-preview--preview-frame created-frame))
            (should-not display-called))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--show-preview-buffer-reuses-dedicated-frame ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (remembered-frame 'preview-frame)
          (remembered-window 'preview-window)
          (assigned nil)
          (make-frame-called nil)
          (beacon-preview-display-location 'dedicated-frame))
      (unwind-protect
          (progn
            (setq beacon-preview--preview-frame remembered-frame)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _args) nil))
                      ((symbol-function 'frame-live-p)
                       (lambda (frame) (eq frame remembered-frame)))
                      ((symbol-function 'frame-root-window)
                       (lambda (_frame) remembered-window))
                      ((symbol-function 'make-frame)
                       (lambda (&rest _args)
                         (setq make-frame-called t)
                         'new-frame))
                      ((symbol-function 'set-window-buffer)
                       (lambda (window buffer)
                         (setq assigned (list window buffer)))))
              (should (eq (beacon-preview--show-preview-buffer preview-buffer)
                          remembered-window))
              (should-not make-frame-called)
              (should (equal assigned (list remembered-window preview-buffer)))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--show-preview-buffer-reuses-shared-dedicated-frame ()
  (let ((source-a (generate-new-buffer " *beacon-preview-source-a*"))
        (source-b (generate-new-buffer " *beacon-preview-source-b*"))
        (preview-a (generate-new-buffer " *beacon-preview-live-a*"))
        (preview-b (generate-new-buffer " *beacon-preview-live-b*"))
        (shared-frame 'shared-preview-frame)
        (shared-window 'shared-preview-window)
        (make-frame-called 0)
        (assignments nil)
        (beacon-preview-display-location 'shared-dedicated-frame))
    (unwind-protect
        (let ((beacon-preview--shared-preview-frame nil))
          (cl-letf (((symbol-function 'get-buffer-window)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'frame-live-p)
                     (lambda (frame) (eq frame shared-frame)))
                    ((symbol-function 'make-frame)
                     (lambda (&rest _args)
                       (setq make-frame-called (1+ make-frame-called))
                       shared-frame))
                    ((symbol-function 'frame-root-window)
                     (lambda (_frame) shared-window))
                    ((symbol-function 'set-window-buffer)
                     (lambda (window buffer)
                       (push (list window buffer) assignments))))
            (with-current-buffer source-a
              (beacon-preview--show-preview-buffer preview-a))
            (with-current-buffer source-b
              (beacon-preview--show-preview-buffer preview-b))
            (should (= make-frame-called 1))
            (should (eq beacon-preview--shared-preview-frame shared-frame))
            (should (equal (nreverse assignments)
                           (list (list shared-window preview-a)
                                 (list shared-window preview-b))))))
      (kill-buffer source-a)
      (kill-buffer source-b)
      (kill-buffer preview-a)
      (kill-buffer preview-b))))

(ert-deftest beacon-preview--open-preview-restores-selected-window-after-creating-preview ()
  (with-temp-buffer
    (let ((created-buffer (generate-new-buffer " *beacon-preview-created*"))
          (origin-window (selected-window))
          (origin-buffer (current-buffer))
          (preview-window (split-window-right)))
      (unwind-protect
          (progn
            (set-window-buffer origin-window (current-buffer))
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) preview-window))
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
              (should (eq (selected-window) origin-window))
              (should (eq (window-buffer origin-window) origin-buffer))
              (should (eq (current-buffer) origin-buffer))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
        (kill-buffer created-buffer)))))

(ert-deftest beacon-preview--open-preview-restores-selected-window-when-reusing-preview ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (origin-window (selected-window))
          (origin-buffer (current-buffer))
          (preview-window (split-window-right))
          (goto-url nil))
      (unwind-protect
          (progn
            (set-window-buffer origin-window (current-buffer))
            (set-window-buffer preview-window preview-buffer)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) preview-window))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda () 'live-session))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (url) (setq goto-url url)))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (&rest _args)
                          (ert-fail "Should reuse live preview session"))))
              (beacon-preview--open-preview "/tmp/sample.html")
              (should (string-match-p "sample\\.html$" goto-url))
              (should (eq (selected-window) origin-window))
              (should (eq (window-buffer preview-window) preview-buffer))
              (should (eq (window-buffer origin-window) origin-buffer))
              (should (eq (current-buffer) origin-buffer))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--open-preview-reinstalls-xwidget-callback-when-reusing-preview ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (preview-window (split-window-right))
          (callback nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (set-window-buffer preview-window preview-buffer)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) preview-window))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda () 'live-session))
                       ((symbol-function 'xwidget-put)
                        (lambda (_xwidget property value)
                          (when (eq property 'callback)
                            (setq callback value))))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (&rest _args) nil)))
              (beacon-preview--open-preview "/tmp/sample.html" "section")
              (should (eq callback #'beacon-preview--xwidget-callback))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview--open-preview-selects-preview-window-during-reuse-navigation ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-live*"))
          (origin-window (selected-window))
          (preview-window (split-window-right))
          (goto-called-in-preview-window nil))
      (unwind-protect
          (progn
            (set-window-buffer origin-window (current-buffer))
            (set-window-buffer preview-window preview-buffer)
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'beacon-preview--xwidget-available-p)
                        (lambda () t))
                       ((symbol-function 'beacon-preview--show-preview-buffer)
                        (lambda (_buffer) preview-window))
                       ((symbol-function 'xwidget-webkit-current-session)
                        (lambda () 'live-session))
                       ((symbol-function 'xwidget-webkit-goto-url)
                        (lambda (_url)
                          (setq goto-called-in-preview-window
                                (eq (selected-window) preview-window))))
                       ((symbol-function 'xwidget-webkit-browse-url)
                        (lambda (&rest _args)
                          (ert-fail "Should reuse live preview session"))))
              (beacon-preview--open-preview "/tmp/sample.html")
              (should goto-called-in-preview-window)
              (should (eq (selected-window) origin-window))))
        (when (window-live-p preview-window)
          (delete-window preview-window))
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

(ert-deftest beacon-preview-switch-to-preview-starts-preview-when-needed ()
  (with-temp-buffer
    (let ((started nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda ()
                   (setq started t))))
        (beacon-preview-switch-to-preview)
        (should started)))))

(ert-deftest beacon-preview-toggle-preview-display-shows-hidden-preview ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-switch*"))
          (displayed nil))
      (unwind-protect
          (progn
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _args) nil))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &optional _action)
                         (setq displayed buffer)
                         (selected-window))))
              (beacon-preview-toggle-preview-display)
              (should (eq displayed preview-buffer))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-toggle-preview-display-starts-preview-when-needed ()
  (with-temp-buffer
    (let ((started nil))
      (cl-letf (((symbol-function 'beacon-preview-build-and-open)
                 (lambda ()
                   (setq started t))))
        (beacon-preview-toggle-preview-display)
        (should started)))))

(ert-deftest beacon-preview-toggle-preview-display-hides-visible-window ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-switch*"))
          (preview-window 'preview-window)
          (deleted nil))
      (unwind-protect
          (progn
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _args) preview-window))
                      ((symbol-function 'window-live-p)
                       (lambda (window) (eq window preview-window)))
                      ((symbol-function 'window-frame)
                       (lambda (_window) 'source-frame))
                      ((symbol-function 'beacon-preview--live-preview-frame)
                       (lambda (&optional _source-buffer) nil))
                      ((symbol-function 'delete-window)
                       (lambda (window) (setq deleted window)))
                      ((symbol-function 'make-frame-invisible)
                       (lambda (&rest _args)
                         (ert-fail "Side-window preview should not hide a frame"))))
              (beacon-preview-toggle-preview-display)
              (should (eq deleted preview-window))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-toggle-preview-display-hides-dedicated-frame ()
  (with-temp-buffer
    (let ((preview-buffer (generate-new-buffer " *beacon-preview-switch*"))
          (preview-window 'preview-window)
          (preview-frame 'preview-frame)
          (hidden nil))
      (unwind-protect
          (progn
            (setq beacon-preview--xwidget-buffer preview-buffer)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _args) preview-window))
                      ((symbol-function 'window-live-p)
                       (lambda (window) (eq window preview-window)))
                      ((symbol-function 'window-frame)
                       (lambda (_window) preview-frame))
                      ((symbol-function 'beacon-preview--live-preview-frame)
                       (lambda (&optional _source-buffer) preview-frame))
                      ((symbol-function 'frame-live-p)
                       (lambda (frame) (eq frame preview-frame)))
                      ((symbol-function 'make-frame-invisible)
                       (lambda (frame) (setq hidden frame)))
                      ((symbol-function 'delete-window)
                       (lambda (&rest _args)
                         (ert-fail "Dedicated preview should hide its frame"))))
              (beacon-preview-toggle-preview-display)
              (should (eq hidden preview-frame))))
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-tracks-preview-buffers-per-source-buffer ()
  (let ((source-a (generate-new-buffer " *beacon-preview-source-a*"))
        (source-b (generate-new-buffer " *beacon-preview-source-b*"))
        (preview-a (generate-new-buffer " *beacon-preview-dwim-a*"))
        (preview-b (generate-new-buffer " *beacon-preview-dwim-b*"))
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

(ert-deftest beacon-preview-killing-source-buffer-kills-tracked-preview ()
  (let ((source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (preview-buffer (generate-new-buffer " *beacon-preview-dwim*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (setq-local major-mode 'markdown-mode)
            (setq-local beacon-preview--xwidget-buffer preview-buffer)
            (beacon-preview-mode 1)
            (kill-buffer source-buffer))
          (should-not (buffer-live-p source-buffer))
          (should-not (buffer-live-p preview-buffer)))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-killing-source-buffer-deletes-dedicated-preview-frame ()
  (let ((source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (preview-buffer (generate-new-buffer " *beacon-preview-dwim*"))
        (preview-frame 'preview-frame)
        (deleted-frame nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (setq-local major-mode 'markdown-mode)
            (setq-local beacon-preview-display-location 'dedicated-frame)
            (setq-local beacon-preview--xwidget-buffer preview-buffer)
            (setq-local beacon-preview--preview-frame preview-frame)
            (beacon-preview-mode 1))
          (cl-letf (((symbol-function 'beacon-preview--live-preview-frame)
                     (lambda (&optional _source-buffer) preview-frame))
                    ((symbol-function 'frame-live-p)
                     (lambda (frame) (eq frame preview-frame)))
                    ((symbol-function 'frame-parameter)
                     (lambda (frame parameter)
                       (when (and (eq frame preview-frame)
                                  (eq parameter 'beacon-preview-dedicated))
                         t)))
                    ((symbol-function 'frame-root-window)
                     (lambda (_frame) 'preview-window))
                    ((symbol-function 'window-buffer)
                     (lambda (_window) preview-buffer))
                    ((symbol-function 'delete-frame)
                     (lambda (frame &optional _force)
                       (setq deleted-frame frame))))
            (kill-buffer source-buffer))
          (should (eq deleted-frame preview-frame))
          (should-not (buffer-live-p preview-buffer)))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-killing-source-buffer-still-kills-preview-after-mode-disabled ()
  (let ((source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (preview-buffer (generate-new-buffer " *beacon-preview-dwim*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (setq-local major-mode 'markdown-mode)
            (beacon-preview--label-preview-buffer preview-buffer source-buffer)
            (beacon-preview-mode 1)
            (beacon-preview-mode 0)
            (kill-buffer source-buffer))
          (should-not (buffer-live-p source-buffer))
          (should-not (buffer-live-p preview-buffer)))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer)))))

(ert-deftest beacon-preview-killing-preview-buffer-clears-source-tracking-and-frame ()
  (let ((source-buffer (generate-new-buffer " *beacon-preview-source*"))
        (preview-buffer (generate-new-buffer " *beacon-preview-dwim*"))
        (preview-frame 'preview-frame)
        (deleted-frame nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (setq-local major-mode 'markdown-mode)
            (setq-local beacon-preview-display-location 'dedicated-frame)
            (setq-local beacon-preview--preview-frame preview-frame)
            (beacon-preview--label-preview-buffer preview-buffer source-buffer))
          (cl-letf (((symbol-function 'beacon-preview--live-preview-frame)
                     (lambda (&optional _source-buffer) preview-frame))
                    ((symbol-function 'frame-live-p)
                     (lambda (frame) (eq frame preview-frame)))
                    ((symbol-function 'frame-parameter)
                     (lambda (frame parameter)
                       (when (and (eq frame preview-frame)
                                  (eq parameter 'beacon-preview-dedicated))
                         t)))
                    ((symbol-function 'frame-root-window)
                     (lambda (_frame) 'preview-window))
                    ((symbol-function 'window-buffer)
                     (lambda (_window) preview-buffer))
                    ((symbol-function 'delete-frame)
                     (lambda (frame &optional _force)
                       (setq deleted-frame frame))))
            (kill-buffer preview-buffer))
          (should (eq deleted-frame preview-frame))
          (with-current-buffer source-buffer
            (should-not (buffer-live-p beacon-preview--xwidget-buffer))
            (should-not beacon-preview--preview-frame)))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer)))))

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
  (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
        (default-follow (default-value 'beacon-preview-follow-window-display-changes))
        (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
        (default-style (default-value 'beacon-preview-behavior-style)))
    (unwind-protect
        (with-temp-buffer
          (set-default 'beacon-preview-refresh-jump-behavior 'block)
          (set-default 'beacon-preview-follow-window-display-changes nil)
          (set-default 'beacon-preview-reveal-hidden-preview-window nil)
          (set-default 'beacon-preview-behavior-style 'default)
          (beacon-preview-toggle-refresh-jump-behavior)
          (should (local-variable-p 'beacon-preview-refresh-jump-behavior))
          (should (local-variable-p 'beacon-preview-behavior-style))
          (should (eq beacon-preview-refresh-jump-behavior 'preserve))
          (should (eq beacon-preview-behavior-style 'preserve))
          (should (eq (default-value 'beacon-preview-refresh-jump-behavior) 'block))
          (should (eq (default-value 'beacon-preview-behavior-style) 'default))
          (beacon-preview-toggle-refresh-jump-behavior)
          (should (eq beacon-preview-refresh-jump-behavior 'block))
          (should (eq beacon-preview-behavior-style 'default)))
      (set-default 'beacon-preview-follow-window-display-changes default-follow)
      (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
      (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
      (set-default 'beacon-preview-behavior-style default-style))))

(ert-deftest beacon-preview-toggle-follow-window-display-changes-flips-state ()
  (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
        (default-follow (default-value 'beacon-preview-follow-window-display-changes))
        (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
        (default-style (default-value 'beacon-preview-behavior-style)))
    (unwind-protect
        (with-temp-buffer
          (set-default 'beacon-preview-refresh-jump-behavior 'block)
          (set-default 'beacon-preview-follow-window-display-changes nil)
          (set-default 'beacon-preview-reveal-hidden-preview-window nil)
          (set-default 'beacon-preview-behavior-style 'default)
          (beacon-preview-toggle-follow-window-display-changes)
          (should (local-variable-p 'beacon-preview-follow-window-display-changes))
          (should (local-variable-p 'beacon-preview-behavior-style))
          (should beacon-preview-follow-window-display-changes)
          (should (eq beacon-preview-behavior-style 'live))
          (should-not (default-value 'beacon-preview-follow-window-display-changes))
          (should (eq (default-value 'beacon-preview-behavior-style) 'default))
          (beacon-preview-toggle-follow-window-display-changes)
          (should-not beacon-preview-follow-window-display-changes)
          (should (eq beacon-preview-behavior-style 'default)))
      (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
      (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
      (set-default 'beacon-preview-follow-window-display-changes default-follow)
      (set-default 'beacon-preview-behavior-style default-style))))

(ert-deftest beacon-preview-toggle-reveal-hidden-preview-window-flips-state ()
  (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
        (default-follow (default-value 'beacon-preview-follow-window-display-changes))
        (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
        (default-style (default-value 'beacon-preview-behavior-style)))
    (unwind-protect
        (with-temp-buffer
          (set-default 'beacon-preview-refresh-jump-behavior 'block)
          (set-default 'beacon-preview-follow-window-display-changes nil)
          (set-default 'beacon-preview-reveal-hidden-preview-window nil)
          (set-default 'beacon-preview-behavior-style 'default)
          (beacon-preview-toggle-reveal-hidden-preview-window)
          (should (local-variable-p 'beacon-preview-reveal-hidden-preview-window))
          (should (local-variable-p 'beacon-preview-behavior-style))
          (should beacon-preview-reveal-hidden-preview-window)
          (should (eq beacon-preview-behavior-style 'visible))
          (should-not (default-value 'beacon-preview-reveal-hidden-preview-window))
          (should (eq (default-value 'beacon-preview-behavior-style) 'default))
          (beacon-preview-toggle-reveal-hidden-preview-window)
          (should-not beacon-preview-reveal-hidden-preview-window)
          (should (eq beacon-preview-behavior-style 'default)))
      (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
      (set-default 'beacon-preview-follow-window-display-changes default-follow)
      (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
      (set-default 'beacon-preview-behavior-style default-style))))

(ert-deftest beacon-preview-apply-behavior-style-applies-preset ()
  (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
        (default-follow (default-value 'beacon-preview-follow-window-display-changes))
        (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
        (default-style (default-value 'beacon-preview-behavior-style)))
    (unwind-protect
        (with-temp-buffer
          (set-default 'beacon-preview-refresh-jump-behavior 'block)
          (set-default 'beacon-preview-follow-window-display-changes nil)
          (set-default 'beacon-preview-reveal-hidden-preview-window nil)
          (set-default 'beacon-preview-behavior-style 'default)
          (beacon-preview-apply-behavior-style 'live-visible t)
          (should (local-variable-p 'beacon-preview-refresh-jump-behavior))
          (should (local-variable-p 'beacon-preview-follow-window-display-changes))
          (should (local-variable-p 'beacon-preview-reveal-hidden-preview-window))
          (should (local-variable-p 'beacon-preview-behavior-style))
          (should (eq beacon-preview-refresh-jump-behavior 'block))
          (should beacon-preview-follow-window-display-changes)
          (should beacon-preview-reveal-hidden-preview-window)
          (should (eq beacon-preview-behavior-style 'live-visible))
          (should (eq (default-value 'beacon-preview-behavior-style) 'default)))
      (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
      (set-default 'beacon-preview-follow-window-display-changes default-follow)
      (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
      (set-default 'beacon-preview-behavior-style default-style))))

(ert-deftest beacon-preview-apply-behavior-style-applies-custom-plist ()
  (let ((style '(:refresh-jump-behavior preserve
                 :follow-window-display-changes t
                 :reveal-hidden-preview-window t)))
    (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
          (default-follow (default-value 'beacon-preview-follow-window-display-changes))
          (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
          (default-style (default-value 'beacon-preview-behavior-style)))
      (unwind-protect
          (with-temp-buffer
            (set-default 'beacon-preview-refresh-jump-behavior 'block)
            (set-default 'beacon-preview-follow-window-display-changes nil)
            (set-default 'beacon-preview-reveal-hidden-preview-window nil)
            (set-default 'beacon-preview-behavior-style 'default)
            (beacon-preview-apply-behavior-style style t)
            (should (eq beacon-preview-refresh-jump-behavior 'preserve))
            (should beacon-preview-follow-window-display-changes)
            (should beacon-preview-reveal-hidden-preview-window)
            (should (equal beacon-preview-behavior-style style)))
        (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
        (set-default 'beacon-preview-follow-window-display-changes default-follow)
        (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
        (set-default 'beacon-preview-behavior-style default-style)))))

(ert-deftest beacon-preview-apply-behavior-style-sets-defaults-when-not-local ()
  (let ((default-refresh (default-value 'beacon-preview-refresh-jump-behavior))
        (default-follow (default-value 'beacon-preview-follow-window-display-changes))
        (default-reveal (default-value 'beacon-preview-reveal-hidden-preview-window))
        (default-style (default-value 'beacon-preview-behavior-style)))
    (unwind-protect
        (progn
          (set-default 'beacon-preview-refresh-jump-behavior 'block)
          (set-default 'beacon-preview-follow-window-display-changes nil)
          (set-default 'beacon-preview-reveal-hidden-preview-window nil)
          (set-default 'beacon-preview-behavior-style 'default)
          (beacon-preview-apply-behavior-style 'live-visible)
          (should (eq (default-value 'beacon-preview-refresh-jump-behavior) 'block))
          (should (default-value 'beacon-preview-follow-window-display-changes))
          (should (default-value 'beacon-preview-reveal-hidden-preview-window))
          (should (eq (default-value 'beacon-preview-behavior-style) 'live-visible)))
      (set-default 'beacon-preview-refresh-jump-behavior default-refresh)
      (set-default 'beacon-preview-follow-window-display-changes default-follow)
      (set-default 'beacon-preview-reveal-hidden-preview-window default-reveal)
      (set-default 'beacon-preview-behavior-style default-style))))

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

(ert-deftest beacon-preview-supported-source-mode-includes-org-mode ()
  (with-temp-buffer
    (setq-local major-mode 'org-mode)
    (should (beacon-preview--supported-source-mode-p))))

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

(ert-deftest beacon-preview-mode-can-auto-start-preview-for-unvisited-buffer ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
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
              #'beacon-preview-dwim))
  (should (eq (lookup-key beacon-preview-command-map (kbd "s"))
              #'beacon-preview-apply-behavior-style))
  (should (eq (lookup-key beacon-preview-command-map (kbd "t"))
              #'beacon-preview-toggle-preview-display))
  (should (eq (lookup-key beacon-preview-command-map (kbd "p"))
              #'beacon-preview-sync-source-to-preview))
  (should (eq (lookup-key beacon-preview-command-map (kbd "d"))
              #'beacon-preview-toggle-debug))
  (should (eq (lookup-key beacon-preview-command-map (kbd "h"))
              #'beacon-preview-flash-current-target))
  (should (eq (lookup-key beacon-preview-command-map (kbd "f"))
              #'beacon-preview-toggle-refresh-jump-behavior))
  (should (eq (lookup-key beacon-preview-command-map (kbd "w"))
              #'beacon-preview-toggle-follow-window-display-changes)))

(ert-deftest beacon-preview-flash-current-target-runs-preview-flash-api ()
  (with-temp-buffer
    (setq-local major-mode 'markdown-mode)
    (let ((beacon-preview--xwidget-buffer (generate-new-buffer " *beacon-preview-live*"))
          (executed nil))
      (unwind-protect
          (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                     (lambda () 'live-session))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_session script)
                       (setq executed script)))
                    ((symbol-function 'beacon-preview--current-anchor-maybe)
                     (lambda () "beacon-p-1")))
            (beacon-preview-flash-current-target)
            (should (string-match-p "BeaconPreview\\.flashAnchor" executed))
            (should (string-match-p "beacon-p-1" executed)))
        (kill-buffer beacon-preview--xwidget-buffer)))))

(ert-deftest beacon-preview-toggle-debug-flips-state ()
  (let ((beacon-preview-debug nil))
    (beacon-preview-toggle-debug)
    (should beacon-preview-debug)
    (beacon-preview-toggle-debug)
    (should-not beacon-preview-debug)))

(provide 'beacon-preview-tests)

;;; beacon-preview-tests.el ends here
