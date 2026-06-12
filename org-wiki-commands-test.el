;;; org-wiki-commands-test.el --- ERT tests for org-wiki-commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:
;; Tests for the interactive command layer.  Reuses the fixture harness
;; and node constants from org-wiki-test.el.  All selection is injected
;; (completing-read stubbed) so nothing here needs a live minibuffer or
;; an embedding backend.  The consult and embark integration tests load
;; the real packages when they are installed and skip otherwise; the
;; headless load contract is asserted in a fresh subprocess, so it does
;; not depend on what earlier tests loaded into this session.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-wiki)
(require 'org-wiki-commands)
(require 'org-wiki-test)            ; fixtures + org-wiki-test-with-fixtures

;; Loaded only inside the skip-unless-guarded integration tests.
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar embark-transformer-alist)
(declare-function embark--targets "ext:embark")

(ert-deftest org-wiki-commands-test-all-nodes ()
  "`org-wiki--all-nodes' returns wiki nodes only, with kind+summary."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (org-wiki-test--write-fixture "entities/202605131012-ak.org"
                                 org-wiki-test--entity-node)
   (org-wiki-test--write-fixture "misc/202605131012-rnd.org"
                                 org-wiki-test--non-wiki-node)
   (let* ((nodes (org-wiki--all-nodes))
          (titles (mapcar (lambda (n) (plist-get n :title)) nodes)))
     (should (member "Content-Addressed Storage" titles))
     (should (member "Andrej Karpathy" titles))
     (should-not (member "A Random Note" titles))
     (let ((cas (cl-find "Content-Addressed Storage" nodes
                         :key (lambda (n) (plist-get n :title))
                         :test #'string=)))
       (should (string= (plist-get cas :kind) "Concept"))
       (should (string-match-p
                "content addressing"
                (downcase (or (plist-get cas :summary) ""))))))))

(ert-deftest org-wiki-commands-test-read-disambiguates-duplicate-titles ()
  "`org-wiki--read' returns the exact chosen node even when titles AND ids collide."
  (let* ((n1 (list :title "Dup"))
         (n2 (list :title "Dup"))
         (n3 (list :title "Dup"))
         (nodes (list n1 n2 n3))
         captured)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq captured (all-completions "" coll))
                 (nth 2 captured))))
      (let ((chosen (org-wiki--read "x: " nodes)))
        (should (= (length captured) 3))
        (should (= (length (seq-uniq captured)) 3))
        (should (eq chosen n3))))))

(ert-deftest org-wiki-commands-test-visit ()
  "`org-wiki--visit' lands point on the node's heading."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((node (cl-find "Content-Addressed Storage" (org-wiki--all-nodes)
                        :key (lambda (n) (plist-get n :title))
                        :test #'string=)))
     (org-wiki--visit node)
     (should (string-match-p "Content-Addressed Storage"
                             (org-get-heading t t t t))))))

(ert-deftest org-wiki-commands-test-find ()
  "`org-wiki-find' visits the node chosen at the prompt."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) "Content-Addressed Storage")))
     (org-wiki-find)
     (should (string-match-p "Content-Addressed Storage"
                             (org-get-heading t t t t))))))

(ert-deftest org-wiki-commands-test-search-default-uses-search ()
  "`org-wiki-search' (no prefix) presents `org-wiki--search' results."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (cl-letf (((symbol-function 'org-wiki--search)
              (lambda (q &optional _k)
                (org-wiki--text-search q (org-wiki--candidate-files))))
             ((symbol-function 'completing-read)
              (lambda (&rest _) "Content-Addressed Storage")))
     (org-wiki-search "content")
     (should (string-match-p "Content-Addressed Storage"
                             (org-get-heading t t t t))))))

(ert-deftest org-wiki-commands-test-search-literal-skips-semantic ()
  "With a prefix arg, `org-wiki-search' never calls `org-wiki--search'."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((semantic-called nil))
     (cl-letf (((symbol-function 'org-wiki--search)
                (lambda (&rest _) (setq semantic-called t) nil))
               ((symbol-function 'completing-read)
                (lambda (&rest _) "Content-Addressed Storage")))
       (org-wiki-search "content" t)
       (should-not semantic-called)
       (should (string-match-p "Content-Addressed Storage"
                               (org-get-heading t t t t)))))))

(ert-deftest org-wiki-commands-test-backlinks ()
  "`org-wiki-backlinks' visits a linking node through its :from-file.
The backlink's file is plumbed into the node plist as :file, so the
visit must not need the org-id locations table — linkers can live
outside the wiki tree, where `org-wiki--locate-id' cannot help."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((ak-file (org-wiki-test--write-fixture
                   "entities/202605131012-ak.org"
                   org-wiki-test--entity-node)))
     (cl-letf (((symbol-function 'org-wiki--backlinks)
                (lambda (_id)
                  (list (list :from-id "a23b4c5d-6e7f-8901-2345-67890abcdef0"
                              :from-title "Andrej Karpathy"
                              :from-file ak-file))))
               ((symbol-function 'org-wiki--locate-id)
                (lambda (_id) (error "Visit must not need org-id lookup")))
               ((symbol-function 'completing-read)
                (lambda (&rest _) "Andrej Karpathy")))
       (org-wiki-backlinks "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
       (should (string-match-p "Andrej Karpathy"
                               (org-get-heading t t t t)))))))

(ert-deftest org-wiki-commands-test-backlinks-without-file-falls-back ()
  "Backlink plists lacking :from-file still visit via org-id lookup."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (org-wiki-test--write-fixture "entities/202605131012-ak.org"
                                 org-wiki-test--entity-node)
   (cl-letf (((symbol-function 'org-wiki--backlinks)
              (lambda (_id)
                (list (list :from-id "a23b4c5d-6e7f-8901-2345-67890abcdef0"
                            :from-title "Andrej Karpathy"))))
             ((symbol-function 'completing-read)
              (lambda (&rest _) "Andrej Karpathy")))
     (org-wiki-backlinks "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
     (should (string-match-p "Andrej Karpathy"
                             (org-get-heading t t t t))))))

(ert-deftest org-wiki-commands-test-show-metadata ()
  "`org-wiki-show-metadata' renders the node's drawer into a buffer."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (when (get-buffer "*org-wiki-metadata*")
     (kill-buffer "*org-wiki-metadata*"))
   (org-wiki-show-metadata "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
   (with-current-buffer "*org-wiki-metadata*"
     (let ((text (buffer-string)))
       (should (string-match-p "wiki_kind" (downcase text)))
       (should (string-match-p "Concept" text))
       (should-not (string-match-p "hash_" (downcase text)))))))

(ert-deftest org-wiki-commands-test-copy-link ()
  "The copy action puts a well-formed id: link on the kill-ring."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((node (cl-find "Content-Addressed Storage" (org-wiki--all-nodes)
                         :key (lambda (n) (plist-get n :title))
                         :test #'string=))
          (cand (propertize (plist-get node :title) 'org-wiki-node node))
          (kill-ring nil)
          (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil)
          (interprogram-paste-function nil))
     (org-wiki-embark-copy-link cand)
     (should (string= (current-kill 0)
                      (format "[[id:%s][Content-Addressed Storage]]"
                              (plist-get node :id)))))))

(ert-deftest org-wiki-commands-test-insert-link ()
  "The insert action inserts a well-formed id: link at point."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((node (cl-find "Content-Addressed Storage" (org-wiki--all-nodes)
                         :key (lambda (n) (plist-get n :title))
                         :test #'string=))
          (cand (propertize (plist-get node :title) 'org-wiki-node node)))
     (with-temp-buffer
       (org-wiki-embark-insert-link cand)
       (should (string= (buffer-string)
                        (format "[[id:%s][Content-Addressed Storage]]"
                                (plist-get node :id))))))))

(ert-deftest org-wiki-commands-test-loads-headless ()
  "The package loads with consult/embark/marginalia absent; commands work.
Runs in a fresh batch subprocess so the check holds no matter which
UI packages other tests have pulled into this session.  The embark
actions are intentionally not autoloaded, so they are not checked."
  (let* ((dir (file-name-directory (locate-library "org-wiki-commands")))
         (roam (make-temp-file "org-wiki-headless-" t))
         (form '(kill-emacs
                 (if (and (not (featurep 'consult))
                          (not (featurep 'embark))
                          (not (featurep 'marginalia))
                          (commandp 'org-wiki-find)
                          (commandp 'org-wiki-search)
                          (commandp 'org-wiki-backlinks)
                          (commandp 'org-wiki-show-metadata))
                     0 1))))
    (unwind-protect
        (should (zerop (call-process
                        (expand-file-name invocation-name invocation-directory)
                        nil nil nil
                        "-Q" "--batch"
                        "-L" dir
                        "-L" (expand-file-name "../mcp-server-lib" dir)
                        "--eval" (format "(setq org-roam-directory %S)" roam)
                        "-l" (expand-file-name "org-wiki.el" dir)
                        "-l" (expand-file-name "org-wiki-commands.el" dir)
                        "--eval" (format "%S" form))))
      (delete-directory roam t))))

;;;; --- Keymaps -----------------------------------------------------

(ert-deftest org-wiki-commands-test-command-map-function-cell ()
  "`org-wiki-command-map' is fbound to its keymap, as the autoload promises.
Binding the quoted symbol must work after load, not only through the
deferred `(autoload ... \\='keymap)' path."
  (should (fboundp 'org-wiki-command-map))
  (should (keymapp (symbol-function 'org-wiki-command-map)))
  (should (eq (symbol-function 'org-wiki-command-map) org-wiki-command-map)))

(ert-deftest org-wiki-commands-test-node-map-ret-visits ()
  "RET in the embark node keymap defaults to the visit action."
  (should (eq (lookup-key org-wiki-node-map (kbd "RET"))
              #'org-wiki-embark-visit)))

;;;; --- embark seam -------------------------------------------------

(ert-deftest org-wiki-commands-test-embark-transform ()
  "The embark transformer rewrites picker candidates to bare node ids.
The candidates are captured from a real `org-wiki--read' call, so the
test exercises the same propertized strings embark computes targets
from — including the duplicate-title disambiguation suffix, which
must map to the *second* node's id, not its display title."
  (let* ((n1 (list :id "11111111-aaaa" :title "Dup"))
         (n2 (list :id "22222222-bbbb" :title "Dup"))
         captured)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq captured (all-completions "" coll))
                 (car captured))))
      (org-wiki--read "x: " (list n1 n2)))
    (should (= (length captured) 2))
    (should (equal (org-wiki--embark-transform 'org-wiki-node (nth 0 captured))
                   '(org-wiki-node . "11111111-aaaa")))
    (should (equal (org-wiki--embark-transform 'org-wiki-node (nth 1 captured))
                   '(org-wiki-node . "22222222-bbbb")))
    ;; Bare ids (at-point targets) and empty strings pass through.
    (should (equal (org-wiki--embark-transform 'org-wiki-node "raw-id")
                   '(org-wiki-node . "raw-id")))
    (should (equal (org-wiki--embark-transform 'org-wiki-node "")
                   '(org-wiki-node . "")))))

(ert-deftest org-wiki-commands-test-copy-link-bare-id ()
  "The copy action resolves a bare id to a full [[id:ID][Title]] link.
A property-stripped bare id is what embark actually injects into
actions, so this fallback is the runtime contract of every action."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((kill-ring nil)
         (kill-ring-yank-pointer nil)
         (interprogram-cut-function nil)
         (interprogram-paste-function nil))
     (org-wiki-embark-copy-link "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
     (should (string= (current-kill 0)
                      (concat "[[id:4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91]"
                              "[Content-Addressed Storage]]"))))))

(ert-deftest org-wiki-commands-test-insert-link-bare-id ()
  "The insert action resolves a bare id to a full [[id:ID][Title]] link."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (with-temp-buffer
     (org-wiki-embark-insert-link "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
     (should (string= (buffer-string)
                      (concat "[[id:4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91]"
                              "[Content-Addressed Storage]]"))))))

(ert-deftest org-wiki-commands-test-copy-link-empty-input-errors ()
  "Empty embark input signals `user-error' instead of a [[id:nil]] link."
  (should-error (org-wiki-embark-copy-link "") :type 'user-error))

(ert-deftest org-wiki-commands-test-embark-target-link-bounds ()
  "The target finder reports an id: link's id and its real extent."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "before [[id:abc-123][Alpha]] after\n")
    (goto-char (point-min))
    (search-forward "Alpha")
    (pcase-let ((`(org-wiki-node ,id ,beg . ,end)
                 (org-wiki--embark-target-at-point)))
      (should (equal id "abc-123"))
      (should (equal (buffer-substring-no-properties beg end)
                     "[[id:abc-123][Alpha]]")))))

(ert-deftest org-wiki-commands-test-embark-target-heading-bounds ()
  "On a wiki heading, the target finder reports heading-line bounds."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-cas.org"
                org-wiki-test--concept-node)))
     (with-current-buffer (find-file-noselect file)
       (goto-char (point-min))
       (re-search-forward "^\\* Content")
       (pcase-let ((`(org-wiki-node ,id ,beg . ,end)
                    (org-wiki--embark-target-at-point)))
         (should (equal id "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
         (should (equal (buffer-substring-no-properties beg end)
                        "* Content-Addressed Storage")))))))

(ert-deftest org-wiki-commands-test-embark-integration ()
  "Registration and the candidate-to-action seam work with real embark.
Verifies `org-wiki--setup-embark' ran via `eval-after-load', collects
an at-point target through `embark--targets' itself, then pushes a
picker candidate through the registered transformer and embark's
property-stripping injection (embark.el `substring-no-properties')
into the copy action.  Loading embark here is safe: the headless
check runs in its own subprocess."
  (skip-unless (locate-library "embark"))
  (require 'embark)
  (should (eq (cdr (assq 'org-wiki-node embark-keymap-alist))
              'org-wiki-node-map))
  (should (memq #'org-wiki--embark-target-at-point embark-target-finders))
  (should (eq (cdr (assq 'org-wiki-node embark-transformer-alist))
              #'org-wiki--embark-transform))
  ;; At-point target through embark's own machinery.
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "see [[id:abc-123][Alpha]] here\n")
    (goto-char (point-min))
    (search-forward "Alpha")
    (let ((target (seq-find (lambda (tgt)
                              (eq (plist-get tgt :type) 'org-wiki-node))
                            (embark--targets))))
      (should target)
      (should (equal (plist-get target :target) "abc-123"))
      (should (equal (buffer-substring-no-properties
                      (car (plist-get target :bounds))
                      (cdr (plist-get target :bounds)))
                     "[[id:abc-123][Alpha]]"))))
  ;; Picker candidate -> transformer -> stripped injection -> action.
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let (captured)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt coll &rest _)
                  (setq captured (all-completions "" coll))
                  (car captured))))
       (org-wiki--read "x: " (org-wiki--all-nodes)))
     (pcase-let* ((`(,_type . ,target)
                   (funcall (alist-get 'org-wiki-node embark-transformer-alist)
                            'org-wiki-node (car captured)))
                  (injected (substring-no-properties target))
                  (kill-ring nil)
                  (kill-ring-yank-pointer nil)
                  (interprogram-cut-function nil)
                  (interprogram-paste-function nil))
       (org-wiki-embark-copy-link injected)
       (should (string= (current-kill 0)
                        (concat "[[id:4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91]"
                                "[Content-Addressed Storage]]")))))))

;;;; --- consult seam ------------------------------------------------

(ert-deftest org-wiki-commands-test-read-dispatches-to-consult ()
  "`org-wiki--read' routes through `consult--read' when consult is loaded.
Consult is simulated here (feature flag plus stubbed functions), so
the dispatch is verified even on an Emacs without consult installed;
the real consult code path is exercised by
`org-wiki-commands-test-consult-read-integration'."
  (let* ((n1 (list :id "id-1" :title "Alpha"))
         (n2 (list :id "id-2" :title "Beta"))
         (called nil)
         (state-fn nil))
    ;; `features' is not a special variable, so a plain `let' cannot
    ;; bind it; `cl-letf' the symbol's value instead.  The binding
    ;; unwinds with the form, so the simulated feature cannot leak.
    (cl-letf (((symbol-value 'features)
               (cons 'consult (symbol-value 'features)))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (_action _cand) nil)))
              ((symbol-function 'consult--read)
               (lambda (table &rest options)
                 (setq called t)
                 (setq state-fn (plist-get options :state))
                 (funcall (plist-get options :lookup)
                          (cadr (all-completions "" table)) nil "" nil))))
      (let ((chosen (org-wiki--read "x: " (list n1 n2))))
        (should called)
        (should (functionp state-fn))
        (should (eq chosen n2))))))

(ert-deftest org-wiki-commands-test-consult-read-integration ()
  "With real consult loaded, `org-wiki--read' resolves via `consult--read'.
The spy around `consult--read' proves the consult branch ran;
`completing-read' is stubbed underneath it, which is the layer
consult itself drives in batch."
  (skip-unless (locate-library "consult"))
  (require 'consult)
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((nodes (org-wiki--all-nodes))
         (real-read (symbol-function 'consult--read))
         (consult-path nil))
     (cl-letf (((symbol-function 'consult--read)
                (lambda (&rest args)
                  (setq consult-path t)
                  (apply real-read args)))
               ((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (car (all-completions "Content" table)))))
       (let ((chosen (org-wiki--read "Node: " nodes)))
         (should consult-path)
         (should (equal (plist-get chosen :title)
                        "Content-Addressed Storage"))
         (should (equal (plist-get chosen :id)
                        "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")))))))

(ert-deftest org-wiki-commands-test-consult-preview-state ()
  "The consult preview lands on the node's heading and degrades safely."
  (skip-unless (locate-library "consult"))
  (require 'consult)
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let ((node (cl-find "Content-Addressed Storage" (org-wiki--all-nodes)
                        :key (lambda (n) (plist-get n :title))
                        :test #'string=))
         (state (org-wiki--preview-state)))
     (save-window-excursion
       (funcall state 'preview node)
       (should (equal (buffer-file-name) (plist-get node :file)))
       (should (looking-at-p "\\* Content-Addressed Storage"))
       ;; Resetting the preview must not error.
       (funcall state 'preview nil)
       ;; An unlocatable node previews nothing rather than erroring.
       (funcall state 'preview
                (list :id "00000000-0000-0000-0000-000000000000"))
       (funcall state 'exit nil)))))

(provide 'org-wiki-commands-test)
;;; org-wiki-commands-test.el ends here
