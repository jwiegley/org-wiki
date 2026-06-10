;;; format.el --- Batch canonical formatter for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Canonicalize Emacs Lisp formatting: native `indent-region'
;; indentation, no tabs, no trailing whitespace, exactly one trailing
;; newline.  This is the community-standard "canonical indentation"
;; discipline rather than a full reformatter, so intentional line
;; structure is preserved.
;;
;; Usage:
;;
;;   emacs -Q --batch -L . -l scripts/format.el FILE...           # fix
;;   emacs -Q --batch -L . -l scripts/format.el --check FILE...   # check
;;
;; In --check mode nothing is written; the exit status is non-zero if
;; any file would change.

;;; Code:

(require 'cl-lib)

;; Load the package sources so the `declare' indent specs of our own
;; macros (e.g. `org-wiki-mcp--with-error-handling') are in effect when
;; indenting.  Fail loudly if they don't load: indenting without the
;; specs would report false positives.
(dolist (file '("org-wiki.el" "org-wiki-mcp.el"))
  (load (expand-file-name file) nil t))

(defun org-wiki-format--file (file fix)
  "Canonically format FILE in a temporary buffer.
When FIX is non-nil, write the result back.  Return non-nil if FILE
was already clean."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((original (buffer-string)))
      (delay-mode-hooks (emacs-lisp-mode))
      (setq indent-tabs-mode nil)
      (untabify (point-min) (point-max))
      (indent-region (point-min) (point-max))
      (delete-trailing-whitespace)
      (goto-char (point-max))
      (unless (or (= (point-min) (point-max))
                  (eq (char-before) ?\n))
        (insert "\n"))
      (let ((clean (string= original (buffer-string))))
        (cond (clean)
              (fix
               (write-region (point-min) (point-max) file nil 'silent)
               (message "Reformatted %s" file))
              (t
               (message "Needs formatting: %s" file)))
        clean))))

(let* ((args command-line-args-left)
       (check (member "--check" args))
       (files (cl-remove-if (lambda (arg) (string-prefix-p "-" arg)) args))
       (status 0))
  (dolist (file files)
    (unless (org-wiki-format--file file (not check))
      (when check (setq status 1))))
  (kill-emacs status))

;;; format.el ends here
