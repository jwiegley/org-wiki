;;; org-wiki-commands.el --- Interactive commands for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Keywords: outlines hypermedia
;; URL: https://github.com/jwiegley/dot-emacs

;; This file is distributed under the BSD 3-clause license; see the
;; LICENSE.md file in this repository for the full text.

;;; Commentary:

;; Interactive front-ends for the org-wiki data core.  `consult',
;; `embark' and `marginalia' are optional: this file loads and works
;; without them (plain `completing-read', no preview, no embark menu),
;; so the headless MCP Emacs never pulls in UI packages.
;;
;; This file currently holds only the shared candidate layer
;; (enumerate, read, visit); the interactive commands themselves land
;; in later changes.

;;; Code:

(require 'org)
(require 'org-wiki)

(declare-function org-ql-select "org-ql")

;;;; --- Candidate layer --------------------------------------------

(defun org-wiki--node-at-point-plist ()
  "Return the summary plist of the node at point, plus `:point'."
  (append (org-wiki--node-at-point-summary) (list :point (point))))

(defun org-wiki--all-nodes ()
  "Return a list of plists, one per wiki node across the candidate files.
Each plist has keys :id :title :kind :file :point :summary.  This is
the embedding-free enumeration; it never contacts the semantic backend."
  (require 'org-ql)
  (org-ql-select (org-wiki--candidate-files)
                 '(property "WIKI_KIND")
                 :action #'org-wiki--node-at-point-plist))

(defun org-wiki--read (prompt nodes)
  "Use PROMPT to read one of NODES via `completing-read'.
Return the chosen node's plist, or nil when NODES is empty.
Candidate strings carry their node on the `org-wiki-node' text property
\(for embark) and are mapped back through an alist (robust to
property-stripping completion UIs).  Duplicate titles get a faded
suffix derived from the node id plus a counter, so every display
string is unique."
  (when nodes
    (let ((seen (make-hash-table :test #'equal))
          cands alist)
      (dolist (node nodes)
        (let* ((title (or (plist-get node :title) "?"))
               (id (plist-get node :id))
               (n 0)
               (disp title))
          (while (gethash disp seen)
            (setq n (1+ n))
            (setq disp
                  (concat title "  "
                          (propertize
                           (if (> (length id) 0)
                               (format "%s·%d"
                                       (substring id 0 (min 8 (length id))) n)
                             (number-to-string n))
                           'face 'shadow))))
          (puthash disp t seen)
          (setq disp (propertize disp 'org-wiki-node node))
          (push disp cands)
          (push (cons (substring-no-properties disp) node) alist)))
      (setq cands (nreverse cands))
      (let ((choice (completing-read prompt
                                     (org-wiki--completion-table cands)
                                     nil t)))
        (cdr (assoc choice alist))))))

(defun org-wiki--completion-table (candidates)
  "Return a completion table over CANDIDATES with node metadata."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (category . org-wiki-node)
                   (affixation-function . org-wiki--affixate))
      (complete-with-action action candidates string pred))))

(defun org-wiki--affixate (cands)
  "Affixation function: suffix each of CANDS with its kind and summary."
  (mapcar
   (lambda (c)
     (let* ((node (get-text-property 0 'org-wiki-node c))
            (kind (or (plist-get node :kind) ""))
            (summary (replace-regexp-in-string
                      "[ \t\n]+" " " (or (plist-get node :summary) ""))))
       (list c ""
             (concat "  "
                     (propertize (format "%-11s" kind) 'face 'font-lock-type-face)
                     " "
                     (propertize (truncate-string-to-width summary 64)
                                 'face 'completions-annotations)))))
   cands))

(defun org-wiki--visit (node &optional other-window)
  "Visit NODE's heading.  With OTHER-WINDOW non-nil, use another window."
  (let* ((id (plist-get node :id))
         (file (or (plist-get node :file)
                   (and id (org-wiki--locate-id id)))))
    (unless (and file (file-exists-p file))
      (user-error "org-wiki: Cannot locate node %s"
                  (or id (plist-get node :title) "?")))
    (let ((buf (find-file-noselect file)))
      (if other-window (pop-to-buffer buf) (pop-to-buffer-same-window buf))
      (with-current-buffer buf
        (widen)
        (goto-char (point-min))
        (let ((pos (and id (org-find-entry-with-id id))))
          (if pos
              (progn (goto-char pos) (org-back-to-heading t))
            (when (plist-get node :point)
              (goto-char (plist-get node :point)))))
        (org-fold-show-context 'org-goto)
        (recenter)))))

(provide 'org-wiki-commands)
;;; org-wiki-commands.el ends here
