.PHONY: test test-elisp

test: test-elisp

test-elisp:
	emacs --batch -Q -l tests/beacon-preview-tests.el -f ert-run-tests-batch-and-exit
