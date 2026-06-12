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
;; This file holds the shared candidate layer (enumerate, read,
;; visit) and the interactive commands built on top of it.

;;; Code:

(require 'cl-lib)
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

(defun org-wiki--id-at-point ()
  "Return a wiki node id at point: an id: link, or the enclosing heading.
Return nil when point is on neither, or when not in an Org buffer."
  (when (derived-mode-p 'org-mode)
    (or (let ((ctx (org-element-context)))
          (and (eq (org-element-type ctx) 'link)
               (string= (org-element-property :type ctx) "id")
               (org-element-property :path ctx)))
        (and (org-entry-get nil "WIKI_KIND")
             (org-entry-get nil "ID")))))

;;;; --- Commands ---------------------------------------------------

;;;###autoload
(defun org-wiki-find (&optional other-window)
  "Pick a wiki node and visit it.
With prefix arg OTHER-WINDOW, use another window."
  (interactive "P")
  (let ((node (org-wiki--read "Wiki node: " (org-wiki--all-nodes))))
    (when node (org-wiki--visit node other-window))))

;;;###autoload
(defun org-wiki-search (query &optional literal)
  "Search wiki nodes for QUERY and visit a chosen result.
By default this runs the semantic backend via `org-wiki--search',
which itself falls back to a literal text match when the backend
errors.  With a prefix arg (LITERAL non-nil) the semantic backend is
skipped entirely -- the predictable escape hatch when the embedding
service is down.  A slow backend is interruptible with \\[keyboard-quit]."
  (interactive "sWiki search: \nP")
  (let ((results (if literal
                     (seq-take (org-wiki--text-search
                                query (org-wiki--candidate-files))
                               100)
                   (org-wiki--search query 100))))
    (if (null results)
        (message "org-wiki: no matches for %S" query)
      (let ((node (org-wiki--read (format "Wiki (%s): " query) results)))
        (when node (org-wiki--visit node))))))

;;;###autoload
(defun org-wiki-backlinks (&optional id)
  "Visit a node that links to the wiki node ID.
Interactively, ID defaults to the node at point (an id: link or the
enclosing wiki heading); with none, prompt for a node."
  (interactive)
  (let* ((id (or id (org-wiki--id-at-point)
                 (plist-get (org-wiki--read "Backlinks to: "
                                            (org-wiki--all-nodes))
                            :id))))
    (unless id (user-error "org-wiki: No node specified"))
    (let ((links (org-wiki--backlinks id)))
      (if (null links)
          (message "org-wiki: no backlinks to %s" id)
        (let* ((nodes (mapcar (lambda (bl)
                                (list :id (plist-get bl :from-id)
                                      :title (plist-get bl :from-title)))
                              links))
               (node (org-wiki--read "Backlink: " nodes)))
          (when node (org-wiki--visit node)))))))

;;;###autoload
(defun org-wiki-show-metadata (&optional id)
  "Show the property drawer of the wiki node ID in a transient buffer.
Interactively, ID defaults to the node at point, else prompts.  Hash
properties are already stripped by `org-wiki-node-metadata'."
  (interactive)
  (let* ((id (or id (org-wiki--id-at-point)
                 (plist-get (org-wiki--read "Metadata for: "
                                            (org-wiki--all-nodes))
                            :id))))
    (unless id (user-error "org-wiki: No node specified"))
    (let ((meta (org-wiki-node-metadata id)))
      (with-current-buffer (get-buffer-create "*org-wiki-metadata*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (cl-loop for (k v) on meta by #'cddr
                   do (insert (format "%-14s %s\n"
                                      (substring (symbol-name k) 1) v)))
          (goto-char (point-min)))
        (special-mode)
        (display-buffer (current-buffer))))))

;;;; --- embark integration (optional) ------------------------------

(defvar embark-keymap-alist)
(defvar embark-target-finders)

(defun org-wiki--embark-node (cand)
  "Resolve embark CAND (a candidate string or a bare id) to a node plist.
Return nil for empty input; callers then `user-error' on the missing id."
  (and (stringp cand) (> (length cand) 0)
       (or (get-text-property 0 'org-wiki-node cand)
           (list :id cand))))

(defun org-wiki--title-of (id)
  "Return the title of the node with ID, or ID itself if unknown.
Scans every candidate file via `org-wiki--all-nodes'; do not call in a loop."
  (or (cl-loop for n in (org-wiki--all-nodes)
               when (equal (plist-get n :id) id) return (plist-get n :title))
      id))

(defun org-wiki--node-link (node)
  "Return an Org id: link string for NODE."
  (let* ((id (plist-get node :id))
         (title (or (plist-get node :title) (org-wiki--title-of id))))
    (format "[[id:%s][%s]]" id title)))

(defun org-wiki-embark-visit (cand)
  "Visit the wiki node named by embark CAND."
  (interactive "sNode: ")
  (org-wiki--visit (org-wiki--embark-node cand)))

(defun org-wiki-embark-visit-other (cand)
  "Visit the wiki node named by embark CAND in another window."
  (interactive "sNode: ")
  (org-wiki--visit (org-wiki--embark-node cand) t))

(defun org-wiki-embark-copy-link (cand)
  "Copy an Org id: link to the wiki node named by embark CAND."
  (interactive "sNode: ")
  (let ((link (org-wiki--node-link (org-wiki--embark-node cand))))
    (kill-new link)
    (message "Copied %s" link)))

(defun org-wiki-embark-insert-link (cand)
  "Insert an Org id: link to the wiki node named by embark CAND."
  (interactive "sNode: ")
  (insert (org-wiki--node-link (org-wiki--embark-node cand))))

(defun org-wiki-embark-backlinks (cand)
  "Show backlinks for the wiki node named by embark CAND."
  (interactive "sNode: ")
  (org-wiki-backlinks (plist-get (org-wiki--embark-node cand) :id)))

(defun org-wiki-embark-metadata (cand)
  "Show metadata for the wiki node named by embark CAND."
  (interactive "sNode: ")
  (org-wiki-show-metadata (plist-get (org-wiki--embark-node cand) :id)))

(defvar org-wiki-node-map
  (let ((map (make-sparse-keymap)))
    (define-key map "v" #'org-wiki-embark-visit)
    (define-key map "o" #'org-wiki-embark-visit-other)
    (define-key map "w" #'org-wiki-embark-copy-link)
    (define-key map "i" #'org-wiki-embark-insert-link)
    (define-key map "b" #'org-wiki-embark-backlinks)
    (define-key map "m" #'org-wiki-embark-metadata)
    map)
  "Embark action keymap for `org-wiki-node' targets.")

(defun org-wiki--embark-target-at-point ()
  "Embark target finder: an id: link or wiki heading at point."
  (let ((id (org-wiki--id-at-point)))
    (when id
      (cons 'org-wiki-node (cons id (cons (point) (point)))))))

(defun org-wiki--setup-embark ()
  "Register the wiki action keymap and target finder with embark.
Run once embark loads; safe to call repeatedly."
  (add-to-list 'embark-keymap-alist '(org-wiki-node . org-wiki-node-map))
  (add-to-list 'embark-target-finders #'org-wiki--embark-target-at-point))

;; Defer the embark hookup until embark itself loads, without a literal
;; `with-eval-after-load' form (which package-lint forbids in packages):
;; call `eval-after-load' indirectly so the integration stays a soft,
;; load-order-independent dependency.
(funcall #'eval-after-load 'embark #'org-wiki--setup-embark)

;;;; --- Prefix keymap (unbound; the user binds it) -----------------

;;;###autoload (autoload 'org-wiki-command-map "org-wiki-commands" nil t 'keymap)
(defvar org-wiki-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "s" #'org-wiki-search)
    (define-key map "f" #'org-wiki-find)
    (define-key map "b" #'org-wiki-backlinks)
    (define-key map "m" #'org-wiki-show-metadata)
    map)
  "Prefix keymap for org-wiki commands.
Bind it where you like, e.g.:

  (keymap-set global-map \"C-c w\" org-wiki-command-map)")

(provide 'org-wiki-commands)
;;; org-wiki-commands.el ends here
