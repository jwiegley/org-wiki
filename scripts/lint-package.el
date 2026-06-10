;;; lint-package.el --- Batch package-lint runner for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Run `package-lint' over the given files.  Dependencies are resolved
;; against the packages installed in the running Emacs (no network),
;; which is what both the Nix dev shell and the flake checks provide.
;;
;; Usage:
;;
;;   emacs -Q --batch -L . -l scripts/lint-package.el FILE...

;;; Code:

(require 'package)
(package-initialize)
(require 'package-lint)

(setq package-lint-main-file "org-wiki.el")

(package-lint-batch-and-exit)

;;; lint-package.el ends here
