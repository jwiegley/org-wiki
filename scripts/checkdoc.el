;;; checkdoc.el --- Batch checkdoc runner for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Run `checkdoc' over the given files and exit non-zero if any
;; diagnostic is produced.
;;
;; Usage:
;;
;;   emacs -Q --batch -l scripts/checkdoc.el FILE...

;;; Code:

(require 'cl-lib)
(require 'checkdoc)

(defvar org-wiki-checkdoc--count 0
  "Number of checkdoc diagnostics seen so far.")

(setq checkdoc-create-error-function
      (lambda (text start _end &optional _unfixable)
        (setq org-wiki-checkdoc--count (1+ org-wiki-checkdoc--count))
        (message "%s:%d: %s"
                 (buffer-file-name)
                 (if start (line-number-at-pos start) 0)
                 text)
        nil))

(let ((files (cl-remove-if (lambda (arg) (string-prefix-p "-" arg))
                           command-line-args-left)))
  (dolist (file files)
    (checkdoc-file file))
  (if (zerop org-wiki-checkdoc--count)
      (kill-emacs 0)
    (message "checkdoc: %d diagnostic(s)" org-wiki-checkdoc--count)
    (kill-emacs 1)))

;;; checkdoc.el ends here
