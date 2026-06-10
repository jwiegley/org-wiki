;;; coverage.el --- Coverage instrumentation for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Configure `undercover' to instrument the package sources and emit an
;; lcov report, then make sure the (instrumented) sources are loaded.
;; Load this BEFORE the test file:
;;
;;   UNDERCOVER_FORCE=true emacs -Q --batch -L . \
;;     -l scripts/coverage.el -l org-wiki-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; undercover only instruments source files, never byte-compiled ones,
;; and it evaluates the matched files itself, so this must run before
;; anything else loads org-wiki.  The report is written from
;; `kill-emacs-hook' when the test runner exits.

;;; Code:

(require 'undercover)

(undercover "org-wiki.el" "org-wiki-mcp.el"
            (:report-format 'lcov)
            (:report-file "coverage/lcov.info")
            (:send-report nil))

;; undercover has already evaluated the instrumented sources; these are
;; assertions that the features really are present.
(require 'org-wiki)
(require 'org-wiki-mcp)

;;; coverage.el ends here
