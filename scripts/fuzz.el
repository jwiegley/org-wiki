;;; fuzz.el --- Randomized robustness harness for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Emacs Lisp has no coverage-guided fuzzer, so this is the practical
;; equivalent: a seeded random-input harness that drives the public
;; org-wiki API and the MCP tool handlers with hostile inputs (regexp
;; metacharacters, control characters, unicode, malformed org files)
;; and fails if anything signals outside its documented error
;; contract:
;;
;;   - `org-wiki-search' and `org-wiki-node-p' must never signal.
;;   - `org-wiki-read-node' / `org-wiki-node-metadata' may signal only
;;     `org-wiki-error'.
;;   - The MCP handlers may signal only `mcp-server-lib-tool-error'.
;;
;; The PRNG seed is fixed (override with FUZZ_SEED) so runs are
;; reproducible; FUZZ_ITERATIONS overrides the iteration count.
;;
;; Usage:
;;
;;   emacs -Q --batch -L . -l scripts/fuzz.el -f org-wiki-fuzz-run

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-wiki)
(require 'org-wiki-mcp)

(defvar org-wiki-fuzz-iterations
  (string-to-number (or (getenv "FUZZ_ITERATIONS") "250"))
  "Number of fuzzing iterations to run.")

(defvar org-wiki-fuzz-seed (or (getenv "FUZZ_SEED") "org-wiki-fuzz-0")
  "Seed string for the pseudo-random generator.")

(defvar org-wiki-fuzz--failures nil
  "List of failure descriptions accumulated during the run.")

(defconst org-wiki-fuzz--chars
  (append "abcdefghij KLMNOP0123456789"
          "[](){}.*+?^$\\|\"'`#;:~@-_"
          "äéλ☃日本語"
          (list ?\n ?\t)
          nil)
  "Character pool for random strings.")

(defun org-wiki-fuzz--string (max-len)
  "Return a random string of up to MAX-LEN characters."
  (let ((n (random (1+ max-len))))
    (apply #'string
           (cl-loop repeat n
                    collect (nth (random (length org-wiki-fuzz--chars))
                                 org-wiki-fuzz--chars)))))

(defun org-wiki-fuzz--id ()
  "Return a random ID-ish string: sometimes valid, mostly garbage."
  (pcase (random 4)
    (0 "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91") ; the known wiki node
    (1 "bbbbbbbb-1111-2222-3333-444444444444") ; known non-wiki node
    (_ (org-wiki-fuzz--string 40))))

(defconst org-wiki-fuzz--wiki-node "\
#+title: Fuzz Target

* Fuzz Target
  :PROPERTIES:
  :ID:           4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91
  :WIKI_KIND:    Concept
  :END:

** Summary

A stable fixture node for the fuzzer to read.
")

(defconst org-wiki-fuzz--plain-node "\
#+title: Plain Note

* Plain Note
  :PROPERTIES:
  :ID:       bbbbbbbb-1111-2222-3333-444444444444
  :END:

Not a wiki node.
")

(defun org-wiki-fuzz--setup ()
  "Create the fixture tree, including malformed files.  Return its root."
  (let ((root (make-temp-file "org-wiki-fuzz-" t)))
    (cl-flet ((emit (name content)
                (with-temp-file (expand-file-name name root)
                  (insert content))))
      (emit "wiki.org" org-wiki-fuzz--wiki-node)
      (emit "plain.org" org-wiki-fuzz--plain-node)
      (emit "empty.org" "")
      (emit "garbage.org"
            (concat "* [[*+? broken \\ heading\n"
                    ":PROPERTIES:\n:ID: not-closed\n"
                    (org-wiki-fuzz--string 400)))
      (puthash "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"
               (expand-file-name "wiki.org" root) org-id-locations)
      (puthash "bbbbbbbb-1111-2222-3333-444444444444"
               (expand-file-name "plain.org" root) org-id-locations))
    root))

(defun org-wiki-fuzz--allowed-p (err allowed)
  "Return non-nil if signal ERR matches one of the ALLOWED conditions."
  (let ((conditions (get (car err) 'error-conditions)))
    (cl-some (lambda (sym) (memq sym conditions)) allowed)))

(defun org-wiki-fuzz--check (iteration op input allowed thunk)
  "Run THUNK; record a failure unless it signals only ALLOWED conditions.
ITERATION, OP and INPUT annotate any failure report."
  (condition-case err
      (progn (funcall thunk) t)
    (error
     (unless (org-wiki-fuzz--allowed-p err allowed)
       (push (format "iteration %d: %s %S signaled %S"
                     iteration op input err)
             org-wiki-fuzz--failures)
       nil))))

(defun org-wiki-fuzz-run ()
  "Run the fuzzing harness; exit non-zero on contract violations."
  (random org-wiki-fuzz-seed)
  (let* ((org-id-locations (make-hash-table :test 'equal))
         (org-wiki--id-last-refresh 0)
         (root (org-wiki-fuzz--setup))
         (org-wiki-root (file-name-as-directory root))
         (org-id-locations-file (expand-file-name ".org-id-locations" root))
         (inhibit-message t))
    (unwind-protect
        (dotimes (i org-wiki-fuzz-iterations)
          (pcase (random 5)
            (0 (let ((query (org-wiki-fuzz--string 30))
                     (k (- (random 30) 5)))
                 (org-wiki-fuzz--check i "org-wiki-search" (list query k) nil
                                       (lambda () (org-wiki-search query k)))))
            (1 (let ((id (org-wiki-fuzz--id)))
                 (org-wiki-fuzz--check i "org-wiki-read-node" id
                                       '(org-wiki-error)
                                       (lambda () (org-wiki-read-node id)))))
            (2 (let ((id (org-wiki-fuzz--id)))
                 (org-wiki-fuzz--check i "org-wiki-node-metadata" id
                                       '(org-wiki-error)
                                       (lambda () (org-wiki-node-metadata id)))))
            (3 (let ((query (org-wiki-fuzz--string 30))
                     (k (org-wiki-fuzz--string 25)))
                 (org-wiki-fuzz--check i "wiki_search tool" (list query k)
                                       '(mcp-server-lib-tool-error)
                                       (lambda ()
                                         (org-wiki-mcp--search-tool query k)))))
            (4 (let ((id (org-wiki-fuzz--id)))
                 (org-wiki-fuzz--check i "wiki_read_node tool" id
                                       '(mcp-server-lib-tool-error)
                                       (lambda ()
                                         (org-wiki-mcp--read-node-tool id)))))))
      (delete-directory root t)))
  (let ((inhibit-message nil))
    (if (null org-wiki-fuzz--failures)
        (progn
          (message "fuzz: %d iterations, no contract violations (seed %S)"
                   org-wiki-fuzz-iterations org-wiki-fuzz-seed)
          (kill-emacs 0))
      (dolist (failure (nreverse org-wiki-fuzz--failures))
        (message "FAIL %s" failure))
      (message "fuzz: %d violation(s) in %d iterations (seed %S)"
               (length org-wiki-fuzz--failures)
               org-wiki-fuzz-iterations
               org-wiki-fuzz-seed)
      (kill-emacs 1))))

;;; fuzz.el ends here
