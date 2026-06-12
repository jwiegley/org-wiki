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
;;   - org-wiki--search        — semantic search (uses org-ql-semantic if
;;                              available, otherwise falls back to text
;;                              match) scoped to nodes with :WIKI_KIND:.
;;   - org-wiki-read-node     — return full body text of a node by :ID:.
;;   - org-wiki-node-metadata — return the property drawer (minus the
;;                              hash property) as a plist.
;;   - org-wiki--backlinks     — return backlinks from org-roam for a node.
;;
;; Identity predicates:
;;
;;   - org-wiki-node-p     — t iff the entry at point has :WIKI_KIND:
;;                           set.  Identity is property-only (§2.1);
;;                           location is a placement convention.
;;   - org-wiki-writable-p — additionally requires the file to live
;;                           under `org-wiki-root' (the write-allowlist
;;                           boundary for the future mutation slice).
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
(declare-function org-roam-node-file "org-roam-node" (node) t)
(declare-function org-ql-semantic-files "ext:org-ql-semantic")
(declare-function org-ql-semantic--sort-by-score "ext:org-ql-semantic")
(declare-function org-hash-property "ext:org-hash")
(declare-function org-roam-db-query "org-roam-db")
(defvar org-roam-db-location)

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
  "Default `k' (max results) for `org-wiki--search'."
  :type 'integer
  :group 'org-wiki)

(defcustom org-wiki-id-refresh-interval 300
  "Minimum seconds between cold-path `org-id-update-id-locations' calls.
The refresh rescans the whole known corpus (org-id unions the files
it is given with agenda files and previously known files), so an
agent retrying hallucinated IDs must not be able to trigger a full
rescan on every miss."
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

(defun org-wiki--roam-wiki-files ()
  "Return corpus files holding wiki nodes, per the org-roam DB.
Identity is property-only (architecture doc §2.1): wiki nodes that
have drifted outside `org-wiki-root' are still wiki nodes, and the
roam DB is how reads find them.  Returns nil when org-roam or its
database is unavailable.  The full-table scan is acceptable at
personal scale; revisit with a cached view if the corpus grows."
  (when (and (fboundp 'org-roam-db-query)
             (boundp 'org-roam-db-location)
             org-roam-db-location
             (file-exists-p org-roam-db-location))
    (ignore-errors
      (let (files)
        (pcase-dolist (`(,file ,properties)
                       (org-roam-db-query
                        [:select :distinct [file properties] :from nodes]))
          (when (assoc "WIKI_KIND" properties)
            (push file files)))
        (nreverse files)))))

(defun org-wiki--candidate-files ()
  "Return all files that may contain wiki nodes.
The wiki tree is always included; when the org-roam DB is available,
files elsewhere in the corpus whose nodes carry `:WIKI_KIND:' are
included too, so that search honors property-only identity."
  (delete-dups (nconc (org-wiki--all-files) (org-wiki--roam-wiki-files))))

(defvar org-wiki--id-last-refresh 0
  "`float-time' of the last cold-path org-id locations refresh.")

(defun org-wiki--locate-id (id)
  "Return the file containing ID per `org-id-locations', or nil.
On a miss, refresh the locations table at most once per
`org-wiki-id-refresh-interval' seconds and retry."
  (or (and (hash-table-p org-id-locations)
           (gethash id org-id-locations))
      (when (> (- (float-time) org-wiki--id-last-refresh)
               org-wiki-id-refresh-interval)
        (setq org-wiki--id-last-refresh (float-time))
        (org-id-update-id-locations (org-wiki--all-files))
        (and (hash-table-p org-id-locations)
             (gethash id org-id-locations)))))

(defun org-wiki--node-buffer (file)
  "Return a buffer visiting FILE, reusing any live buffer.
Fresh buffers are fully initialized by `find-file-noselect' and left
live, so later visits (and `org-wiki--visit') can reuse them safely."
  (or (find-buffer-visiting file)
      (find-file-noselect file)))

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

(defun org-wiki--search (query &optional k)
  "Search wiki nodes for QUERY, returning up to K (default 10) plists.
Each result has keys :id :title :kind :file :summary.

When `org-ql-semantic-files' is available the search is
semantic-first and results are ordered by similarity.  If the
semantic backend errors — org-ql-semantic signals rather than
degrading when its CLI or embedding server is down — or is absent,
the search falls back to a literal string match against `org-ql''s
`heading' / `regexp' predicates, in corpus-traversal order with no
relevance ranking."
  (require 'org-ql)
  (let* ((k (or k org-wiki-default-search-limit))
         (files (org-wiki--candidate-files))
         (semantic
          (when (fboundp 'org-ql-semantic-files)
            (condition-case nil
                (cons t (org-wiki--semantic-search query files))
              ;; Degraded mode: backend down or misconfigured.
              (error nil)))))
    (seq-take (if semantic
                  (cdr semantic)
                (org-wiki--text-search query files))
              k)))

(defun org-wiki--semantic-search (query files)
  "Return wiki-node summaries for QUERY from FILES, best match first."
  (let ((wiki-set (make-hash-table :test #'equal)))
    (dolist (file files)
      (puthash file t wiki-set))
    ;; Filter the similarity-ordered list against the wiki set rather
    ;; than intersecting the other way around: `cl-intersection' does
    ;; not preserve order, and the ranking is the point.
    (let ((candidates (seq-filter (lambda (file) (gethash file wiki-set))
                                  (org-ql-semantic-files query))))
      (when candidates
        (org-ql-select candidates
                       `(and (property "WIKI_KIND") (semantic ,query))
                       :action #'org-wiki--node-at-point-summary
                       :sort #'org-ql-semantic--sort-by-score)))))

(defun org-wiki--text-search (query files)
  "Return wiki-node summaries matching QUERY literally in FILES."
  (org-ql-select files
                 `(and (property "WIKI_KIND")
                       (or (heading ,query)
                           (regexp ,(regexp-quote query))))
                 :action #'org-wiki--node-at-point-summary))

;;;###autoload
(defun org-wiki-read-node (id)
  "Return the full body of the wiki node with ID as a plain-text string.
The returned text is the node's whole subtree, including its property
drawer.  Signals `org-wiki-error' if no node with that ID exists, or
if it isn't a wiki node."
  (let ((file (org-wiki--locate-id id)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (org-wiki--node-buffer file)
      (save-excursion
        (goto-char (point-min))
        (unless (re-search-forward
                 (format "^[ \t]*:ID:[ \t]+%s\\b" (regexp-quote id))
                 nil t)
          ;; Deliberately no file path in the payload: error payloads
          ;; travel to whatever MCP client is connected.
          (signal 'org-wiki-error (list :id_not_in_file id)))
        (org-back-to-heading t)
        (unless (org-wiki-node-p)
          (signal 'org-wiki-error (list :not_a_wiki_node id)))
        (save-restriction
          (org-narrow-to-subtree)
          (buffer-substring-no-properties (point-min) (point-max)))))))

;;;###autoload
(defun org-wiki-node-metadata (id)
  "Return a plist of the property drawer of the wiki node with ID.
Hash properties (any property whose name starts with \"HASH_\") are
stripped unconditionally: the integrity hash is tool-maintained and is
never surfaced through the metadata view, whether or not org-hash is
loaded in this session."
  (let ((file (org-wiki--locate-id id)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (org-wiki--node-buffer file)
      (save-excursion
        (goto-char (point-min))
        (unless (re-search-forward
                 (format "^[ \t]*:ID:[ \t]+%s\\b" (regexp-quote id))
                 nil t)
          (signal 'org-wiki-error (list :id_not_in_file id)))
        (org-back-to-heading t)
        (let ((props (cl-remove-if
                      (lambda (kv)
                        (string-prefix-p "HASH_" (car kv) t))
                      (org-entry-properties nil 'standard))))
          ;; Convert to a JSON-friendly plist
          (apply #'append
                 (mapcar (lambda (kv)
                           (list (intern (concat ":" (downcase (car kv))))
                                 (cdr kv)))
                         props)))))))

(defun org-wiki--backlinks (id)
  "Return a list of plists describing backlinks to the wiki node with ID.
Each plist has keys :from-id, :from-title and :from-file, so callers
can visit the linking node without consulting the org-id locations
table (linkers may live outside the wiki tree).

Uses `org-roam-backlinks-get' when `org-roam' is loaded; otherwise
returns nil and logs a message."
  (cond
   ((not (fboundp 'org-roam-node-from-id))
    (message "org-wiki--backlinks: org-roam not loaded; returning nil")
    nil)
   (t
    (let* ((node (org-roam-node-from-id id))
           (backlinks (and node (org-roam-backlinks-get node))))
      (mapcar (lambda (bl)
                (let ((src (org-roam-backlink-source-node bl)))
                  (list :from-id    (org-roam-node-id src)
                        :from-title (org-roam-node-title src)
                        :from-file  (org-roam-node-file src))))
              backlinks)))))

;;;; --- Error type -------------------------------------------------

(define-error 'org-wiki-error "Wiki tool error")

(provide 'org-wiki)
;;; org-wiki.el ends here
