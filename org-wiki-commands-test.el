;;; org-wiki-commands-test.el --- ERT tests for org-wiki-commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:
;; Tests for the interactive command layer.  Reuses the fixture harness
;; and node constants from org-wiki-test.el.  All selection is injected
;; (completing-read stubbed) so nothing here needs a live minibuffer,
;; embedding backend, consult, or embark.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-wiki)
(require 'org-wiki-commands)
(require 'org-wiki-test)            ; fixtures + org-wiki-test-with-fixtures

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
  "`org-wiki-backlinks' visits a linking node from the backlink list."
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
  "The four autoloaded commands work with consult/embark/marginalia absent.
The embark actions are intentionally not autoloaded, so they are not checked."
  (should-not (featurep 'consult))
  (should-not (featurep 'embark))
  (should-not (featurep 'marginalia))
  (should (commandp 'org-wiki-find))
  (should (commandp 'org-wiki-search))
  (should (commandp 'org-wiki-backlinks))
  (should (commandp 'org-wiki-show-metadata)))

(provide 'org-wiki-commands-test)
;;; org-wiki-commands-test.el ends here
