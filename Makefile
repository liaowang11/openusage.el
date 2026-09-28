EMACS ?= emacs

# load-prefer-newer: `make compile' leaves .elc files behind, and without it a
# later `make test' silently runs the stale compiled copy.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

SRC = openusage.el
TESTS = $(wildcard tests/*-tests.el)

# package-lint lives in the project-local .deps/elpa (gitignored), filled by
# `make deps'.  Without it `make lint' runs checkdoc only.
DEPS_DIR = $(CURDIR)/.deps/elpa
BATCH += --eval '(when (file-directory-p "$(DEPS_DIR)") (require (quote package)) (setq package-user-dir "$(DEPS_DIR)") (package-initialize))'

.PHONY: compile test lint deps check clean

compile:
	$(BATCH) -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC)

test:
	$(BATCH) -L . -L tests -l ert $(foreach t,$(TESTS),-l $(t)) -f ert-run-tests-batch-and-exit

# checkdoc only `warn's in batch and exits 0, so fail on any `checkdoc-error'.
lint:
	$(BATCH) -L . -l checkdoc --eval '(setq checkdoc-verb-check-experimental-flag nil)' \
		--eval '(let (hit) (advice-add (quote checkdoc-error) :before (lambda (&rest _) (setq hit t))) (checkdoc-file "$(SRC)") (when hit (kill-emacs 1)))'
	$(BATCH) -L . \
		--eval '(unless (require (quote package-lint) nil t) (message "package-lint not installed (make deps); skipping") (kill-emacs 0))' \
		-f package-lint-batch-and-exit $(SRC)

deps:
	mkdir -p $(DEPS_DIR)
	$(BATCH) \
		--eval '(add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t)' \
		--eval '(package-refresh-contents)' \
		--eval '(package-install (quote package-lint))'

check: compile lint test

clean:
	rm -f *.elc tests/*.elc
