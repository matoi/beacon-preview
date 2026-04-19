.PHONY: test test-python test-elisp lint-python

test: lint-python test-python test-elisp

lint-python:
	python3 -m py_compile \
		scripts/beaconify_html.py \
		tests/test_beaconify_html.py

test-python:
	python3 -m unittest discover -s tests

test-elisp:
	emacs --batch -Q -l tests/beacon-preview-tests.el -f ert-run-tests-batch-and-exit
