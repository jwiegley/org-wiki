;;; org-wiki-health.el --- Structural diagnostics for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Keywords: outlines hypermedia
;; URL: https://github.com/jwiegley/dot-emacs

;; This file is distributed under the BSD 3-clause license; see the
;; LICENSE.md file in this repository for the full text.

;;; Commentary:

;; Deterministic, read-only structural diagnostics for org-wiki.  Kept
;; separate from the read core so health scanning and Org parsing add no
;; cost to search and node-read hot paths.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'org-wiki)

(declare-function org-ql-select "org-ql")

(defun org-wiki--id-links-in-subtree ()
  "Return id-link targets in the current Org subtree."
  (save-restriction
    (org-narrow-to-subtree)
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (link)
        (when (string= (org-element-property :type link) "id")
          (org-element-property :path link))))))

(defun org-wiki--health-node-at-point ()
  "Return the health-check data for the wiki node at point."
  (append (org-wiki--node-at-point-summary)
          (list :links (org-wiki--id-links-in-subtree)
                :source-ids (split-string
                             (or (org-entry-get nil "SOURCE_IDS") "")
                             "[ \t]*,[ \t]*" t)
                :roam-refs (org-entry-get nil "ROAM_REFS")
                :retrieved (org-entry-get nil "RETRIEVED"))))

(defun org-wiki--normalized-ids (ids)
  "Return IDS lowercased, deduplicated and sorted."
  (sort (delete-dups (mapcar #'downcase (delq nil (copy-sequence ids))))
        #'string<))

(defun org-wiki--health-issue (code node detail)
  "Return a health issue named CODE for NODE with DETAIL."
  (list :code code :severity "warning"
        :id (plist-get node :id)
        :title (plist-get node :title)
        :kind (plist-get node :kind)
        :file (plist-get node :file)
        :detail detail))

(defun org-wiki--health ()
  "Return a deterministic structural health report for all wiki nodes.

The report checks identity, kind, summaries, canonical id links, source
provenance, citation metadata and type-aware connectivity.  It makes no
LLM calls and never modifies the corpus."
  (require 'org-ql)
  (let* ((nodes (org-ql-select (org-wiki--candidate-files)
                               '(property "WIKI_KIND")
                               :action #'org-wiki--health-node-at-point))
         (by-id (make-hash-table :test #'equal))
         (inbound (make-hash-table :test #'equal))
         issues)
    (dolist (node nodes)
      (when-let* ((id (plist-get node :id))
                  (normalized (downcase id)))
        (puthash normalized (cons node (gethash normalized by-id)) by-id)))
    (dolist (node nodes)
      (dolist (link (plist-get node :links))
        (let ((target (downcase link)))
          (if (gethash target by-id)
              (puthash target (1+ (gethash target inbound 0)) inbound)
            (push (org-wiki--health-issue
                   "broken_id_link" node
                   (format "Unknown or non-canonical wiki id: %s" link))
                  issues)))))
    (maphash
     (lambda (id matches)
       (when (cdr matches)
         (push (org-wiki--health-issue
                "duplicate_id" (car matches)
                (format "ID %s occurs in: %s" id
                        (string-join
                         (mapcar (lambda (node) (plist-get node :file)) matches)
                         ", ")))
               issues)))
     by-id)
    (dolist (node nodes)
      (let* ((id (plist-get node :id))
             (normalized-id (and id (downcase id)))
             (kind (plist-get node :kind))
             (links (plist-get node :links)))
        (unless id
          (push (org-wiki--health-issue
                 "missing_id" node "Wiki heading has no ID property")
                issues))
        (unless (member kind org-wiki-kinds)
          (push (org-wiki--health-issue
                 "invalid_kind" node (format "Unknown WIKI_KIND: %s" kind))
                issues))
        (when (string-empty-p (or (plist-get node :summary) ""))
          (push (org-wiki--health-issue
                 "missing_summary" node "Summary section is empty or absent")
                issues))
        (if (equal kind "Source-Record")
            (progn
              (unless (plist-get node :roam-refs)
                (push (org-wiki--health-issue
                       "missing_roam_refs" node
                       "Source-Record has no ROAM_REFS property")
                      issues))
              (unless (plist-get node :retrieved)
                (push (org-wiki--health-issue
                       "missing_retrieved" node
                       "Source-Record has no RETRIEVED property")
                      issues))
              (when (and normalized-id
                         (zerop (gethash normalized-id inbound 0)))
                (push (org-wiki--health-issue
                       "unreferenced_source" node
                       "No wiki node cites this Source-Record")
                      issues))
              (unless links
                (push (org-wiki--health-issue
                       "source_without_links" node
                       "Source-Record links to no derived or related node")
                      issues)))
          (when (and normalized-id
                     (zerop (gethash normalized-id inbound 0)))
            (push (org-wiki--health-issue
                   "orphan_node" node "No wiki node links to this node")
                  issues))
          (let* ((declared (org-wiki--normalized-ids
                            (plist-get node :source-ids)))
                 (cited
                  (org-wiki--normalized-ids
                   (cl-loop for link in links
                            for target = (downcase link)
                            for matches = (gethash target by-id)
                            when (or (string-prefix-p "src-" target)
                                     (cl-some
                                      (lambda (match)
                                        (equal (plist-get match :kind)
                                               "Source-Record"))
                                      matches))
                            collect target))))
            (unless (equal declared cited)
              (push (org-wiki--health-issue
                     "source_ids_mismatch" node
                     (format "SOURCE_IDS=%S; cited Source-Records=%S"
                             declared cited))
                    issues))))))
    (setq issues
          (sort issues
                (lambda (a b)
                  (let ((ac (plist-get a :code))
                        (bc (plist-get b :code)))
                    (if (equal ac bc)
                        (string< (or (plist-get a :title) "")
                                 (or (plist-get b :title) ""))
                      (string< ac bc))))))
    (list :status (if issues "issues" "ok")
          :node-count (length nodes)
          :issue-count (length issues)
          :issues (vconcat issues))))

(provide 'org-wiki-health)
;;; org-wiki-health.el ends here
