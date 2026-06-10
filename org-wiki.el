;;; org-wiki.el --- Org-native LLM Wiki (read-only spike) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 14 May 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (org-roam "2.2") (org-ql "0.7") (mcp-server-lib "0.1"))
;; Keywords: outlines hypermedia
;; URL: https://github.com/jwiegley/dot-emacs

;; This file is distributed under the BSD 3-clause license; see the
;; LICENSE.md file in this repository for the full text.

;;; Commentary:

;; This package is the *read-only spike* for the Org-native LLM Wiki design
;; specified in `~/src/dot-emacs/lisp/docs/org-llm-wiki.md'.  Its purpose is
;; not to be the final implementation but to empirically validate the
;; load-bearing assumptions of the design *before* the mutation tools are
;; built.  Specifically it answers:
;;
;;   - Does (property "WIKI_KIND") as an org-ql predicate work as the doc
;;     claims (matches any node with the property set)?
;;   - Does mcp-server-lib's handler-positional + keyword-properties
;;     registration signature work for multi-positional-arg defuns?
;;   - Does the `MCP Parameters:' docstring block actually get parsed into
;;     a JSON schema?
;;   - Does a `condition-case (error ...)' clause catch a
;;     `mcp-server-lib-tool-error' signal (the bug v2.2 was supposed to
;;     fix)?
;;   - What server-id should wiki tools use, given that `elisp-dev-mcp'
;;     registers under its own?
;;
;; Tools implemented (all read-only):
;;
;;   - org-wiki-search        — semantic search (uses org-ql-semantic if
;;                              available, otherwise falls back to text
;;                              match) scoped to nodes with :WIKI_KIND:.
;;   - org-wiki-read-node     — return full body text of a node by :ID:.
;;   - org-wiki-node-metadata — return the property drawer (minus the
;;                              hash property) as a plist.
;;   - org-wiki-backlinks     — return backlinks from org-roam for a node.
;;
;; Identity predicate:
;;
;;   - org-wiki-node-p — t iff the entry at point has :WIKI_KIND: set
;;                       AND lives under `org-wiki-root'.
;;
;; The read-only surface needs none of: file locking, write-ahead log,
;; recovery, hash discipline, sandboxing.  Those will be added in the
;; mutation slice once the read-only assumptions are verified.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'seq)
(require 'subr-x)

;; org-ql is required at runtime for the search predicate
(declare-function org-ql-select "org-ql")
(declare-function org-roam-backlinks-get "org-roam-mode")
(declare-function org-roam-node-from-id "org-roam-node")
;; cl-defstruct accessors: check-declare cannot resolve them, so only
;; verify the defining file exists (FILEONLY = t).
(declare-function org-roam-backlink-source-node "org-roam-mode" (backlink) t)
(declare-function org-roam-node-id "org-roam-node" (node) t)
(declare-function org-roam-node-title "org-roam-node" (node) t)
(declare-function org-ql-semantic-files "ext:org-ql-semantic")
(declare-function org-hash-property "ext:org-hash")

(defgroup org-wiki nil
  "Org-native LLM Wiki — read-only spike."
  :group 'org-roam
  :prefix "org-wiki-")

(defcustom org-wiki-root (expand-file-name "wiki/" (or (bound-and-true-p org-roam-directory)
                                                       "~/org/"))
  "Root directory of the wiki subtree.
A node is a wiki node only if it lives under this directory AND has a
`:WIKI_KIND:' property."
  :type 'directory
  :group 'org-wiki)

(defcustom org-wiki-kinds
  '("Concept" "Entity" "Topic" "Comparison" "Question"
    "Source-Record" "Frozen" "Index")
  "Permitted values for the `:WIKI_KIND:' property."
  :type '(repeat string)
  :group 'org-wiki)

(defcustom org-wiki-default-search-limit 10
  "Default `k' (max results) for `org-wiki-search'."
  :type 'integer
  :group 'org-wiki)

;;;; --- Identity predicate -----------------------------------------

(defun org-wiki--under-root-p (file)
  "Return t if FILE is under `org-wiki-root'."
  (and file
       (string-prefix-p (expand-file-name (file-name-as-directory org-wiki-root))
                        (expand-file-name file))))

;;;###autoload
(defun org-wiki-node-p (&optional pom)
  "Return t if the entry at POM is a wiki node.
POM is a point or marker, defaulting to point.

Identity is property-only per the architecture doc §2.1: a wiki node is
any Org entry that has a `:WIKI_KIND:' property.  The canonical
location `org-wiki-root' and the `:wiki:' filetag are placement
*conventions*, not part of identity — wiki nodes can drift outside the
canonical directory and remain valid for reads.  Write tools
additionally require `org-wiki-writable-p' to be non-nil before they
will mutate."
  (save-excursion
    (when pom (goto-char pom))
    (and (derived-mode-p 'org-mode)
         (org-entry-get nil "WIKI_KIND"))))

;;;###autoload
(defun org-wiki-writable-p (&optional pom)
  "Return t if the entry at POM is a wiki node and lives in a writable location.

A node is writable iff it satisfies `org-wiki-node-p' AND its buffer file
is under `org-wiki-root'.  Write-side tools (in the future mutation
spike) gate on this; the read-only spike doesn't need it but exposes it
for callers."
  (and (org-wiki-node-p pom)
       (org-wiki--under-root-p (buffer-file-name))))

;;;; --- Internal helpers -------------------------------------------

(defun org-wiki--all-files ()
  "Return a list of absolute paths of all .org files under `org-wiki-root'."
  (when (file-directory-p org-wiki-root)
    (directory-files-recursively org-wiki-root "\\.org\\'")))

(defun org-wiki--hash-property-name ()
  "Return the name of the hash property `org-hash' writes, if available.
Returns nil when `org-hash' isn't loaded — in which case the read-only
spike just won't strip a hash from `node-metadata' output."
  (when (fboundp 'org-hash-property)
    (org-hash-property)))

(defun org-wiki--node-at-point-summary ()
  "Return a plist summarizing the wiki node at point.
Properties returned: :id :title :kind :file :summary."
  (let* ((id    (org-entry-get nil "ID"))
         (kind  (org-entry-get nil "WIKI_KIND"))
         (title (or (org-entry-get nil "ITEM")
                    (nth 4 (org-heading-components))))
         (file  (buffer-file-name)))
    (list :id id :title title :kind kind :file file
          :summary (org-wiki--extract-summary))))

(defun org-wiki--extract-summary ()
  "Return the body of the `** Summary' subheading of the wiki node at point.
Empty string if no such subheading exists."
  (save-restriction
    (org-narrow-to-subtree)
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward "^\\*\\* Summary[ \t]*$" nil t)
          (let ((start (progn (forward-line) (point)))
                (end   (or (and (re-search-forward "^\\*\\* " nil t)
                                (match-beginning 0))
                           (point-max))))
            (string-trim (buffer-substring-no-properties start end)))
        ""))))

;;;; --- Discovery tools --------------------------------------------

;;;###autoload
(defun org-wiki-search (query &optional k)
  "Search wiki nodes for QUERY, returning up to K (default 10) plists.
Each result has keys :id :title :kind :file :summary (plus :score when a
semantic backend was available).

When `org-ql-semantic-files' is bound the search is semantic-first;
otherwise it falls back to a string match against `org-ql''s
`heading' / `description' predicates."
  (require 'org-ql)
  (let* ((k (or k org-wiki-default-search-limit))
         (all-files (org-wiki--all-files))
         (semantic-available (fboundp 'org-ql-semantic-files))
         (candidate-files
          (if semantic-available
              ;; org-ql-semantic--files returns files in semantic-similarity
              ;; order; intersect with wiki tree
              (cl-intersection (org-ql-semantic-files query) all-files
                               :test #'string=)
            all-files))
         (results
          (org-ql-select candidate-files
            (if semantic-available
                `(and (property "WIKI_KIND") (semantic ,query))
              `(and (property "WIKI_KIND")
                    (or (heading ,query)
                        (regexp ,(regexp-quote query)))))
            :action #'org-wiki--node-at-point-summary)))
    (seq-take results k)))

;;;###autoload
(defun org-wiki-read-node (id)
  "Return the full body of the wiki node with ID as a plain-text string.
Signals `org-wiki-error' if no node with that ID exists, or if it isn't
a wiki node."
  (let ((file (gethash id org-id-locations)))
    (unless file
      ;; Cold-path: refresh org-id-locations once and retry.
      (org-id-update-id-locations (org-wiki--all-files))
      (setq file (gethash id org-id-locations)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (unless (re-search-forward
                 (format "^[ \t]*:ID:[ \t]+%s\\b" (regexp-quote id))
                 nil t)
          (signal 'org-wiki-error (list :id_not_in_file id file)))
        (org-back-to-heading t)
        (unless (org-wiki-node-p)
          (signal 'org-wiki-error (list :not_a_wiki_node id)))
        (save-restriction
          (org-narrow-to-subtree)
          (buffer-substring-no-properties (point-min) (point-max)))))))

;;;###autoload
(defun org-wiki-node-metadata (id)
  "Return a plist of the property drawer of the wiki node with ID.
The hash property (as returned by `org-hash-property') is stripped from
the result if present."
  (let ((file (gethash id org-id-locations))
        (hash-prop (org-wiki--hash-property-name)))
    (unless file
      (org-id-update-id-locations (org-wiki--all-files))
      (setq file (gethash id org-id-locations)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (unless (re-search-forward
                 (format "^[ \t]*:ID:[ \t]+%s\\b" (regexp-quote id))
                 nil t)
          (signal 'org-wiki-error (list :id_not_in_file id file)))
        (org-back-to-heading t)
        (let ((props (org-entry-properties nil 'standard)))
          (when hash-prop
            (setq props (assoc-delete-all hash-prop props)))
          ;; Convert to a JSON-friendly plist
          (apply #'append
                 (mapcar (lambda (kv)
                           (list (intern (concat ":" (downcase (car kv))))
                                 (cdr kv)))
                         props)))))))

;;;###autoload
(defun org-wiki-backlinks (id)
  "Return a list of plists describing backlinks to the wiki node with ID.
Each plist has keys :from-id :from-title :from-file :anchor-text.

Uses `org-roam-backlinks-get' when `org-roam' is loaded; otherwise
returns nil and logs a message."
  (cond
   ((not (fboundp 'org-roam-node-from-id))
    (message "org-wiki-backlinks: org-roam not loaded; returning nil")
    nil)
   (t
    (let* ((node (org-roam-node-from-id id))
           (backlinks (and node (org-roam-backlinks-get node))))
      (mapcar (lambda (bl)
                (let ((src (org-roam-backlink-source-node bl)))
                  (list :from-id    (org-roam-node-id src)
                        :from-title (org-roam-node-title src))))
              backlinks)))))

;;;; --- Error type -------------------------------------------------

(define-error 'org-wiki-error "Wiki tool error")

(provide 'org-wiki)
;;; org-wiki.el ends here
