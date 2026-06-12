;;; org-wiki-test.el --- ERT tests for org-wiki read-only spike  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Self-contained tests that use a temporary fixture directory rather than
;; reading anything under ~/org/.  The tests double as empirical
;; verification of load-bearing assumptions in
;; ~/src/dot-emacs/lisp/docs/org-llm-wiki.md.
;;
;; Run with:
;;
;;   emacs --batch -L . \
;;     -L ../mcp-server-lib \
;;     --eval '(setq org-roam-directory (make-temp-file "fake-roam-" t))' \
;;     -l org-wiki.el \
;;     -l org-wiki-mcp.el \
;;     -l org-wiki-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org)
(require 'org-id)

;; Bound via `let' in the fixture macro; org-roam itself is loaded only
;; in the backlinks test.
(defvar org-roam-directory)
(declare-function org-ql-select "org-ql")

;; Avoid org-roam-db actually trying to open a database file during tests.
;; We require org-roam *only* in the backlinks test and skip it cleanly
;; when it isn't usable.

(require 'mcp-server-lib)
(require 'org-wiki)
(require 'org-wiki-mcp)

;;;; --- Test fixtures ----------------------------------------------

(defvar org-wiki-test--fixture-dir nil
  "Temporary wiki-root used for fixtures during a test run.")

(defun org-wiki-test--write-fixture (relpath content)
  "Write CONTENT to RELPATH under the fixture wiki-root.  Return abs path."
  (let* ((full (expand-file-name relpath org-wiki-test--fixture-dir)))
    (make-directory (file-name-directory full) t)
    (with-temp-file full
      (insert content))
    full))

(defun org-wiki-test--with-fixtures (body)
  "Set up fixture directory, run BODY thunk, clean up.
Cleanup kills any buffer left visiting a fixture file — the read
paths open buffers, and leaking buffers that visit deleted files
would let one test see another's stale state."
  (let* ((root (make-temp-file "org-wiki-fixture-" t))
         (org-wiki-root (file-name-as-directory root))
         (org-roam-directory (file-name-as-directory root))
         (org-id-locations (make-hash-table :test 'equal))
         (org-id-locations-file (expand-file-name ".org-id-locations" root))
         (org-wiki--id-last-refresh 0)
         (org-wiki-test--fixture-dir root))
    (unwind-protect
        (funcall body)
      ;; Compare truenames: tests may reach fixture files through
      ;; symlinks (or macOS's /var -> /private/var indirection), and a
      ;; buffer visiting a resolved path must still be cleaned up.
      (let ((root-true (file-name-as-directory (file-truename root))))
        (dolist (buf (buffer-list))
          (let ((file (buffer-file-name buf)))
            (when (and file
                       (string-prefix-p root-true (file-truename file)))
              (with-current-buffer buf
                (set-buffer-modified-p nil))
              (kill-buffer buf)))))
      (delete-directory root t))))

(defmacro org-wiki-test-with-fixtures (&rest body)
  "Run BODY in a fresh fixture wiki-root."
  (declare (indent 0))
  `(org-wiki-test--with-fixtures (lambda () ,@body)))

(defconst org-wiki-test--concept-node "\
#+title:    Content-Addressed Storage
#+filetags: :wiki:concept:storage:
#+category: Wiki/Storage

* Content-Addressed Storage
  :PROPERTIES:
  :ID:           4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91
  :WIKI_KIND:    Concept
  :CONFIDENCE:   high
  :HASH_sha512_256: deadbeef000000000000000000000000000000000000000000000000cafebabe
  :CREATED:      [2026-05-13 Wed 10:12]
  :MODIFIED:     [2026-05-13 Wed 10:23]
  :END:

** Summary

Content addressing identifies data by a hash of its bytes, not by a
name or path.  Renames don't break references.

** Definition

A content address is a hash of bytes, not a path.
")

(defconst org-wiki-test--entity-node "\
#+title:    Andrej Karpathy
#+filetags: :wiki:entity:person:
#+category: Wiki/People

* Andrej Karpathy
  :PROPERTIES:
  :ID:           a23b4c5d-6e7f-8901-2345-67890abcdef0
  :WIKI_KIND:    Entity
  :CONFIDENCE:   high
  :END:

** Summary

Computer scientist; co-founder of OpenAI; popularized the LLM Wiki
pattern in late 2025.
")

(defconst org-wiki-test--non-wiki-node "\
#+title:    A Random Note
#+filetags: :journal:

* A Random Note
  :PROPERTIES:
  :ID:       bbbbbbbb-1111-2222-3333-444444444444
  :CREATED:  [2026-05-01 Fri]
  :END:

This file lives in the wiki tree but lacks :WIKI_KIND:, so it must
not be classified as a wiki node.
")

;;;; --- Identity predicate -----------------------------------------

(ert-deftest org-wiki-test-node-p-true-on-wiki-node ()
  "A heading with :WIKI_KIND: under wiki root is a wiki node."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     (with-current-buffer (find-file-noselect file)
       (goto-char (point-min))
       (re-search-forward "^\\* Content")
       (should (org-wiki-node-p))))))

(ert-deftest org-wiki-test-node-p-false-without-wiki-kind ()
  "A heading without :WIKI_KIND: is not a wiki node, even under wiki root."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-random.org"
                org-wiki-test--non-wiki-node)))
     (with-current-buffer (find-file-noselect file)
       (goto-char (point-min))
       (re-search-forward "^\\* A Random")
       (should-not (org-wiki-node-p))))))

(ert-deftest org-wiki-test-node-p-true-outside-wiki-root ()
  "A heading with :WIKI_KIND: outside wiki root IS a wiki node.

Identity is property-only (§2.1).  The directory is a placement
convention, not part of identity.  Such a node is still searchable
and readable; it just isn't writable — see
`org-wiki-test-writable-p-false-outside-wiki-root'."
  (org-wiki-test-with-fixtures
   (let* ((other-root (make-temp-file "org-wiki-other-" t))
          (file (expand-file-name "outside.org" other-root)))
     (unwind-protect
         (progn
           (with-temp-file file (insert org-wiki-test--concept-node))
           (with-current-buffer (find-file-noselect file)
             (goto-char (point-min))
             (re-search-forward "^\\* Content")
             (should (org-wiki-node-p))))
       (delete-directory other-root t)))))

(ert-deftest org-wiki-test-writable-p-false-outside-wiki-root ()
  "A heading with :WIKI_KIND: outside wiki root is NOT writable.

The write-allowlist (§3.5) is path-bounded even when identity is not."
  (org-wiki-test-with-fixtures
   (let* ((other-root (make-temp-file "org-wiki-other-" t))
          (file (expand-file-name "outside.org" other-root)))
     (unwind-protect
         (progn
           (with-temp-file file (insert org-wiki-test--concept-node))
           (with-current-buffer (find-file-noselect file)
             (goto-char (point-min))
             (re-search-forward "^\\* Content")
             (should (org-wiki-node-p))         ; reads OK
             (should-not (org-wiki-writable-p)))) ; writes NOT OK
       (delete-directory other-root t)))))

;;;; --- Search -----------------------------------------------------

(ert-deftest org-wiki-test-search-finds-wiki-nodes-only ()
  "Search returns wiki nodes only — non-wiki files in the tree are filtered."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture
    "concepts/202605131012-content-addressed-storage.org"
    org-wiki-test--concept-node)
   (org-wiki-test--write-fixture
    "entities/202605131013-andrej-karpathy.org"
    org-wiki-test--entity-node)
   (org-wiki-test--write-fixture
    "concepts/202605131014-random.org"
    org-wiki-test--non-wiki-node)
   (let ((results (org-wiki--search "Content" 10)))
     ;; Must actually find the matching wiki node — without this the
     ;; test passes vacuously on an empty result list.
     (should results)
     (should (cl-some (lambda (r)
                        (string= (plist-get r :id)
                                 "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
                      results))
     (should (cl-every (lambda (r) (plist-get r :kind)) results))
     ;; The non-wiki node must be filtered out
     (should-not
      (cl-some (lambda (r)
                 (string= (plist-get r :id)
                          "bbbbbbbb-1111-2222-3333-444444444444"))
               results)))))

(ert-deftest org-wiki-test-search-respects-k ()
  "Search returns at most k results."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture
    "concepts/202605131012-content-addressed-storage.org"
    org-wiki-test--concept-node)
   (org-wiki-test--write-fixture
    "entities/202605131013-andrej-karpathy.org"
    org-wiki-test--entity-node)
   (let ((results (org-wiki--search "" 1)))
     (should (<= (length results) 1)))))

;;;; --- Semantic search ---------------------------------------------

;; org-ql-semantic is not installable in the gate environment, so the
;; semantic path is exercised against stubs: `org-ql-semantic-files'
;; and `org-ql-semantic--match-score' are bound per-test with
;; `cl-letf' (making the `fboundp' availability probe pass), and the
;; `semantic' org-ql predicate is provided by the helper below.

(declare-function org-ql-semantic--match-score "ext:org-ql-semantic")

(defun org-wiki-test--ensure-semantic-predicate ()
  "Define a stub `semantic' org-ql predicate if the real one is absent.
Like the real predicate, its body defers to
`org-ql-semantic--match-score', so a single `cl-letf' binding drives
both the match and the score the action records.  The `eval'
indirection keeps org-ql a runtime-only dependency of this file:
loading org-ql at compile time would route this file's
`org-ql-select' calls through org-ql's compiler macros, which warn
fatally under the build gate."
  (require 'org-ql)
  (unless (fboundp 'org-ql--predicate-semantic)
    (eval '(org-ql-defpred semantic (query)
                           "Test stub for the org-ql-semantic predicate."
                           :body (org-ql-semantic--match-score query))
          t)))

(ert-deftest org-wiki-test-semantic-search-survives-symlinked-root ()
  "Semantic results survive a symlinked `org-wiki-root'.
Candidate files are discovered through `org-wiki-root', which may
reach the corpus through symlinks, while the semantic backend returns
fully resolved paths.  The intersection must be truename-keyed on
both sides or it comes back empty for every query."
  (org-wiki-test-with-fixtures
   (let ((real-file (org-wiki-test--write-fixture
                     "concepts/202605131012-content-addressed-storage.org"
                     org-wiki-test--concept-node))
         (link (concat (directory-file-name org-wiki-test--fixture-dir)
                       "-link")))
     (make-symbolic-link (directory-file-name org-wiki-test--fixture-dir)
                         link)
     (unwind-protect
         (let ((org-wiki-root (file-name-as-directory link)))
           (org-wiki-test--ensure-semantic-predicate)
           (cl-letf (((symbol-function 'org-ql-semantic-files)
                      (lambda (_query &optional _limit)
                        (list (file-truename real-file))))
                     ((symbol-function 'org-ql-semantic--match-score)
                      (lambda (_query) 0.9)))
             (let ((results (org-wiki--search "content addressing" 5)))
               (should results)
               (should (string= (plist-get (car results) :id)
                                "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")))))
       (delete-file link)))))

(ert-deftest org-wiki-test-semantic-search-child-hit-surfaces-node ()
  "A semantic hit on a child heading surfaces the enclosing wiki node.
The strongest matches are routinely on Summary/Definition
subheadings, which carry no :WIKI_KIND: of their own; the search must
climb to the nearest ancestor that does."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     (org-wiki-test--ensure-semantic-predicate)
     (cl-letf (((symbol-function 'org-ql-semantic-files)
                (lambda (_query &optional _limit) (list file)))
               ((symbol-function 'org-ql-semantic--match-score)
                ;; Only the Summary subheading matches.
                (lambda (_query)
                  (when (equal (org-get-heading t t t t) "Summary")
                    0.8))))
       (let ((results (org-wiki--search "hash of bytes, not a path" 5)))
         (should (= 1 (length results)))
         (should (string= (plist-get (car results) :id)
                          "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
         (should (string= (plist-get (car results) :kind) "Concept")))))))

(ert-deftest org-wiki-test-semantic-search-ranks-by-score ()
  "Semantic results are ordered by score, not corpus-traversal order."
  (org-wiki-test-with-fixtures
   (let ((concept (org-wiki-test--write-fixture
                   "concepts/202605131012-content-addressed-storage.org"
                   org-wiki-test--concept-node))
         (entity (org-wiki-test--write-fixture
                  "entities/202605131013-andrej-karpathy.org"
                  org-wiki-test--entity-node)))
     (org-wiki-test--ensure-semantic-predicate)
     (cl-letf (((symbol-function 'org-ql-semantic-files)
                ;; Traversal order deliberately puts the weaker match
                ;; first; the ranking must reorder.
                (lambda (_query &optional _limit) (list concept entity)))
               ((symbol-function 'org-ql-semantic--match-score)
                (lambda (_query)
                  (if (equal (buffer-file-name) entity) 0.9 0.4))))
       (let ((results (org-wiki--search "famous computer scientists" 5)))
         (should (equal (mapcar (lambda (r) (plist-get r :id)) results)
                        '("a23b4c5d-6e7f-8901-2345-67890abcdef0"
                          "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))))))))

(ert-deftest org-wiki-test-semantic-search-empty-falls-back-to-text ()
  "An empty (non-error) semantic result falls back to literal search.
A paraphrase the embedding misses must never beat a query literal
matching would have answered — zero semantic hits means degrade, not
return nothing."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture
    "concepts/202605131012-content-addressed-storage.org"
    org-wiki-test--concept-node)
   (cl-letf (((symbol-function 'org-ql-semantic-files)
              (lambda (_query &optional _limit) nil)))
     (let ((results (org-wiki--search "Content" 5)))
       (should (cl-some (lambda (r)
                          (string= (plist-get r :id)
                                   "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
                        results))))))

(ert-deftest org-wiki-test-semantic-search-error-falls-back-to-text ()
  "A signaling semantic backend degrades to the literal text search.
org-ql-semantic signals rather than degrading when its CLI or
embedding server is down; the search must swallow that and still
return literal matches."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture
    "concepts/202605131012-content-addressed-storage.org"
    org-wiki-test--concept-node)
   (cl-letf (((symbol-function 'org-ql-semantic-files)
              (lambda (_query &optional _limit)
                (error "Semantic backend is down"))))
     (let ((results (org-wiki--search "Content" 5)))
       (should (cl-some (lambda (r)
                          (string= (plist-get r :id)
                                   "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
                        results))))))

;;;; --- Reading ----------------------------------------------------

(ert-deftest org-wiki-test-read-node-returns-body ()
  "Reading a known node returns its body text."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     ;; Register the ID in org-id-locations
     (puthash "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91" file org-id-locations)
     (let ((body (org-wiki-read-node "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")))
       (should (stringp body))
       (should (string-match-p "Content addressing" body))))))

(ert-deftest org-wiki-test-read-node-rejects-unknown-id ()
  "Reading an unknown ID signals org-wiki-error."
  (org-wiki-test-with-fixtures
   (should-error
    (org-wiki-read-node "00000000-0000-0000-0000-000000000000")
    :type 'org-wiki-error)))

(ert-deftest org-wiki-test-read-node-rejects-non-wiki-node ()
  "Reading a node that exists but lacks :WIKI_KIND: signals org-wiki-error."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131014-random.org"
                org-wiki-test--non-wiki-node)))
     (puthash "bbbbbbbb-1111-2222-3333-444444444444" file org-id-locations)
     (should-error
      (org-wiki-read-node "bbbbbbbb-1111-2222-3333-444444444444")
      :type 'org-wiki-error))))

;;;; --- Node metadata ----------------------------------------------

(ert-deftest org-wiki-test-node-metadata-returns-properties ()
  "Metadata returns the property drawer as a plist."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     (puthash "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91" file org-id-locations)
     (let ((meta (org-wiki-node-metadata "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")))
       (should (plist-get meta :id))
       (should (string= (plist-get meta :wiki_kind) "Concept"))))))

(ert-deftest org-wiki-test-node-metadata-strips-hash ()
  "Metadata must never surface a HASH_* property, with or without org-hash.

The fixture node carries :HASH_sha512_256:, and the strip must not
depend on org-hash being loaded — it is optional at runtime."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     (puthash "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91" file org-id-locations)
     (let ((meta (org-wiki-node-metadata "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")))
       (should meta)
       (cl-loop for (key _value) on meta by #'cddr
                do (should-not (string-prefix-p ":hash_"
                                                (symbol-name key))))))))

;;;; --- Backlinks ---------------------------------------------------

(ert-deftest org-wiki-test-backlinks-plist-shape ()
  "`org-wiki--backlinks' returns :from-id/:from-title/:from-file plists.
org-roam itself is stubbed: this pins the plist shape that both the
MCP backlinks tool and `org-wiki-backlinks' consume, including the
:from-file key the interactive command uses to visit linkers without
an org-id locations lookup."
  (cl-letf (((symbol-function 'org-roam-node-from-id)
             (lambda (_id) 'fake-node))
            ((symbol-function 'org-roam-backlinks-get)
             (lambda (_node) '(fake-backlink)))
            ((symbol-function 'org-roam-backlink-source-node)
             (lambda (_bl) 'fake-src))
            ((symbol-function 'org-roam-node-id)
             (lambda (_src) "a23b4c5d-6e7f-8901-2345-67890abcdef0"))
            ((symbol-function 'org-roam-node-title)
             (lambda (_src) "Andrej Karpathy"))
            ((symbol-function 'org-roam-node-file)
             (lambda (_src) "/tmp/ak.org")))
    (should (equal (org-wiki--backlinks "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91")
                   '((:from-id "a23b4c5d-6e7f-8901-2345-67890abcdef0"
                               :from-title "Andrej Karpathy"
                               :from-file "/tmp/ak.org"))))))

;;;; --- Two-id normalization (file-level alias) ---------------------

;; Wiki node files on disk carry TWO ids: the file-level lint
;; conventions mandate a top-of-file :PROPERTIES: drawer with its own
;; :ID: and :CREATED:, while the node's canonical identity is the
;; heading :ID: that carries :WIKI_KIND: (exactly one such heading
;; per file, per the architecture doc).  The read tools must treat
;; the file-level id as an alias for the node — not crash in
;; `org-back-to-heading' — and must teach callers the canonical
;; heading id.

(defconst org-wiki-test--file-level-id
  "AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0000"
  "File-level (top-of-file drawer) id of the double-id fixture.")

(defconst org-wiki-test--heading-id
  "3cfdef55-0a72-4bb2-b44e-e6b73f6b3f52"
  "Canonical heading id of the double-id fixture.")

(defconst org-wiki-test--double-id-node
  (concat ":PROPERTIES:
:ID:       " org-wiki-test--file-level-id "
:CREATED:  [2026-06-10 Wed 23:36]
:END:
#+category: wiki
#+filetags: :wiki:concept:
#+title:    ZX-calculus

* ZX-calculus
:PROPERTIES:
:ID:         " org-wiki-test--heading-id "
:WIKI_KIND:  Concept
:CONFIDENCE: high
:CREATED:    [2026-06-10 Wed 23:36]
:END:

** Summary

A graphical calculus for reasoning about linear maps between qubits.
")
  "Node file matching the live lint-canonical anatomy.
File-level drawer with an uppercase UUID, keyword lines with #+title
last, flush-left heading drawer with a lowercase UUID carrying
:WIKI_KIND:.")

(defconst org-wiki-test--file-id-only-node "\
:PROPERTIES:
:ID:       11111111-2222-4333-8444-555566667777
:CREATED:  [2026-06-11 Thu 00:10]
:END:
#+filetags: :wiki:
#+title:    Mind Map

Prose before any heading.

* Not a wiki heading
:PROPERTIES:
:CREATED: [2026-06-11 Thu 00:11]
:END:

This heading has no :WIKI_KIND:, so the alias redirect must fail
rather than land here.
"
  "A file carrying only the lint-mandated file-level id.
Mirrors index files like MIND_MAP.org/README.org, which have no
:WIKI_KIND: heading.")

(defun org-wiki-test--write-double-id-fixture ()
  "Write the double-id fixture and register both ids.
Return the file's absolute path."
  (let ((file (org-wiki-test--write-fixture
               "concepts/202606102336-zx-calculus.org"
               org-wiki-test--double-id-node)))
    (puthash org-wiki-test--file-level-id file org-id-locations)
    (puthash org-wiki-test--heading-id file org-id-locations)
    file))

(ert-deftest org-wiki-test-read-node-accepts-file-level-id ()
  "Reading via the file-level id returns the wiki heading's subtree.
The result must be byte-identical to reading via the heading id —
the historical failure was a leaked `org-back-to-heading' user-error
\(\"Before first headline at position 14 in buffer ...\")."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-double-id-fixture)
   (let ((via-file (org-wiki-read-node org-wiki-test--file-level-id))
         (via-heading (org-wiki-read-node org-wiki-test--heading-id)))
     (should (string-prefix-p "* ZX-calculus" via-file))
     (should (string-match-p "graphical calculus" via-file))
     (should (equal via-file via-heading)))))

(ert-deftest org-wiki-test-canonical-id-normalizes-file-level-id ()
  "`org-wiki-canonical-id' maps the file-level alias to the heading id.
Heading ids are already canonical and unknown ids signal."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-double-id-fixture)
   (should (equal (org-wiki-canonical-id org-wiki-test--file-level-id)
                  org-wiki-test--heading-id))
   (should (equal (org-wiki-canonical-id org-wiki-test--heading-id)
                  org-wiki-test--heading-id))
   (should-error
    (org-wiki-canonical-id "00000000-0000-0000-0000-000000000000")
    :type 'org-wiki-error)
   ;; The lenient resolver used by backlinks never signals: unknown
   ;; ids pass through unchanged.
   (should (equal (org-wiki--resolve-id "no-such-id") "no-such-id"))))

(ert-deftest org-wiki-test-node-metadata-accepts-file-level-id ()
  "Metadata via the file-level id is the heading's drawer.
Its :id entry must carry the canonical heading id, and the plist must
equal the one returned for the heading id."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-double-id-fixture)
   (let ((via-file (org-wiki-node-metadata org-wiki-test--file-level-id)))
     (should (equal (plist-get via-file :id) org-wiki-test--heading-id))
     (should (string= (plist-get via-file :wiki_kind) "Concept"))
     (should (equal via-file
                    (org-wiki-node-metadata org-wiki-test--heading-id))))))

(ert-deftest org-wiki-test-read-node-tool-reports-canonical-id ()
  "The wiki_read_node payload carries the canonical heading id.
An agent that found the file-level alias (from the raw file or
org-roam) must learn the heading id from the response; heading-id
calls stay byte-identical."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-double-id-fixture)
   (let ((json (org-wiki-mcp--read-node-tool org-wiki-test--file-level-id)))
     (should (string-match-p
              (regexp-quote
               (concat "\"id\":\"" org-wiki-test--heading-id "\""))
              json))
     (should-not (string-match-p org-wiki-test--file-level-id json))
     (should (string-match-p "ZX-calculus" json))
     (should (equal json
                    (org-wiki-mcp--read-node-tool
                     org-wiki-test--heading-id))))))

(ert-deftest org-wiki-test-backlinks-normalize-file-level-id ()
  "Backlinks via the file-level id are the heading's backlinks.
Nothing links to the file-level alias, so an un-normalized query
would return a misleading empty list; the roam query must receive
the canonical heading id."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-double-id-fixture)
   (let (queried)
     (cl-letf (((symbol-function 'org-roam-node-from-id)
                (lambda (id) (push id queried) 'fake-node))
               ((symbol-function 'org-roam-backlinks-get)
                (lambda (_node) '(fake-backlink)))
               ((symbol-function 'org-roam-backlink-source-node)
                (lambda (_bl) 'fake-src))
               ((symbol-function 'org-roam-node-id)
                (lambda (_src) "a23b4c5d-6e7f-8901-2345-67890abcdef0"))
               ((symbol-function 'org-roam-node-title)
                (lambda (_src) "Andrej Karpathy"))
               ((symbol-function 'org-roam-node-file)
                (lambda (_src) "/tmp/ak.org")))
       (let ((via-file (org-wiki--backlinks org-wiki-test--file-level-id))
             (via-heading (org-wiki--backlinks org-wiki-test--heading-id)))
         (should via-file)
         (should (equal via-file via-heading))
         ;; Both roam queries used the canonical heading id.
         (should (equal queried (list org-wiki-test--heading-id
                                      org-wiki-test--heading-id))))))))

(ert-deftest org-wiki-test-file-level-id-without-wiki-heading-errors ()
  "A file-level id in a file with no :WIKI_KIND: heading is structured.
It must signal `org-wiki-error', and the MCP rendering must be a
typed payload that leaks neither the historical \"Before first
headline\" user-error nor any buffer/file name."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "202606110010-mind-map.org"
                org-wiki-test--file-id-only-node)))
     (puthash "11111111-2222-4333-8444-555566667777" file org-id-locations)
     (should-error
      (org-wiki-read-node "11111111-2222-4333-8444-555566667777")
      :type 'org-wiki-error)
     (should-error
      (org-wiki-node-metadata "11111111-2222-4333-8444-555566667777")
      :type 'org-wiki-error)
     (let* ((err (should-error
                  (org-wiki-mcp--read-node-tool
                   "11111111-2222-4333-8444-555566667777")
                  :type 'mcp-server-lib-tool-error))
            (payload (cadr err)))
       (should (stringp payload))
       (should (string-match-p "\"error\":\"not_a_wiki_node\"" payload))
       (should-not (string-match-p "internal_error" payload))
       (should-not (string-match-p "Before first headline" payload))
       (should-not (string-match-p "mind-map" payload))))))

(ert-deftest org-wiki-test-read-node-rejects-id-missing-from-file ()
  "An id whose recorded file no longer contains it signals org-wiki-error.
Covers the `:id_not_in_file' branch of `org-wiki--goto-id' (a stale
`org-id-locations' entry)."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node)))
     (puthash "dddddddd-1111-2222-3333-444444444444" file org-id-locations)
     (should-error
      (org-wiki-read-node "dddddddd-1111-2222-3333-444444444444")
      :type 'org-wiki-error))))

;;;; --- The org-ql property predicate ------------------------------

(ert-deftest org-wiki-test-property-predicate-matches-existence ()
  "Verify that org-ql's (property \"WIKI_KIND\") matches by existence,
not by value.  This is the load-bearing claim from §2.1 of the doc."
  (org-wiki-test-with-fixtures
   (let ((file (org-wiki-test--write-fixture
                "concepts/202605131012-content-addressed-storage.org"
                org-wiki-test--concept-node))
         (random-file (org-wiki-test--write-fixture
                       "concepts/202605131014-random.org"
                       org-wiki-test--non-wiki-node)))
     (require 'org-ql)
     (let ((matches (org-ql-select (list file random-file)
                                   '(property "WIKI_KIND")
                                   :action (lambda () (org-entry-get nil "ID")))))
       (should (member "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91" matches))
       (should-not (member "bbbbbbbb-1111-2222-3333-444444444444" matches))))))

;;;; --- KEY EMPIRICAL FINDING: error-class catch-up ----------------

(ert-deftest org-wiki-test-tool-error-survives-rewrap-pattern ()
  "EMPIRICAL: does `condition-case (error ...)' catch
`mcp-server-lib-tool-error'?

If yes, the recommended v2.2 error-handling pattern (catch all `error',
rewrap as `internal_error') would corrupt structured tool errors.  Our
fix is to add a `mcp-server-lib-tool-error' clause FIRST so it's
re-signaled before the generic catch."
  (let* ((tool-throw-caught-by-generic
          ;; Pattern v2.2 originally recommended (BUG)
          (condition-case _err
              (signal 'mcp-server-lib-tool-error '("structured"))
            (error 'caught-by-generic-error)
            (mcp-server-lib-tool-error 'caught-by-specific)))
         (tool-throw-caught-by-specific
          ;; Pattern this spike uses (FIX)
          (condition-case _err
              (signal 'mcp-server-lib-tool-error '("structured"))
            (mcp-server-lib-tool-error 'caught-by-specific)
            (error 'caught-by-generic-error))))
    (should (eq tool-throw-caught-by-generic 'caught-by-generic-error))
    (should (eq tool-throw-caught-by-specific 'caught-by-specific))))

(ert-deftest org-wiki-test-with-error-handling-preserves-tool-error ()
  "The macro `org-wiki-mcp--with-error-handling' must re-signal tool errors."
  (should-error
   (org-wiki-mcp--with-error-handling
     (signal 'mcp-server-lib-tool-error '("preserved-payload")))
   :type 'mcp-server-lib-tool-error))

(ert-deftest org-wiki-test-with-error-handling-converts-generic-error ()
  "The macro converts ordinary `error' signals to JSON tool errors."
  (let ((result
         (condition-case err
             (org-wiki-mcp--with-error-handling
               (error "boom"))
           (mcp-server-lib-tool-error (cdr err)))))
    (should (consp result))
    (let ((payload (car result)))
      (should (stringp payload))
      (should (string-match-p "internal_error" payload))
      (should (string-match-p "boom" payload)))))

(ert-deftest org-wiki-test-with-error-handling-structures-wiki-error ()
  "Wiki errors surface as structured JSON, not flattened internal_error.

An unknown-id failure must reach the MCP client as
{\"error\": \"unknown_id\", \"detail\": ...} rather than as an opaque
internal_error whose message is `error-message-string' noise."
  (org-wiki-test-with-fixtures
   (let ((err (should-error
               (org-wiki-mcp--read-node-tool "no-such-id-anywhere")
               :type 'mcp-server-lib-tool-error)))
     (let ((payload (cadr err)))
       (should (stringp payload))
       (should (string-match-p "\"error\":\"unknown_id\"" payload))
       (should (string-match-p "no-such-id-anywhere" payload))
       (should-not (string-match-p "internal_error" payload))))))

;;;; --- MCP API verification ---------------------------------------

(ert-deftest org-wiki-test-mcp-register-tool-accepts-multi-arg ()
  "Verify the server registration accepts a multi-positional-arg handler.

Uses `mcp-server-lib-register-server' (the current API; per-tool
`mcp-server-lib-register-tool' is obsolete as of 0.3.0).  The schema
is generated from the arglist with all parameters typed as string."
  (let ((server-id "org-wiki-test")
        (tool-id "test_two_arg"))
    (unwind-protect
        (progn
          (mcp-server-lib-register-server
           :id server-id
           :tools (list
                   (list (lambda (a b)
                           "Test two-arg handler.

MCP Parameters:
  a - first param
  b - second param"
                           (format "%s+%s" a b))
                         :id tool-id
                         :description "Sum two strings"
                         :read-only t)))
          ;; Verify it's registered by checking the per-server tools table
          (let ((tools-table (gethash server-id mcp-server-lib--tools)))
            (should tools-table)
            (should (gethash tool-id tools-table))))
      (mcp-server-lib-unregister-server server-id))))

(ert-deftest org-wiki-test-mcp-schema-from-docstring ()
  "Verify mcp-server-lib extracts parameter docs from the docstring block.

If this fails, our `MCP Parameters:' blocks in handlers don't
generate the JSON-schema we expect."
  (let* ((handler (lambda (foo bar)
                    "Handler.

MCP Parameters:
  foo - the first thing
  bar - the second thing"
                    (format "%s/%s" foo bar)))
         (schema (mcp-server-lib--generate-schema-from-function handler)))
    (should schema)
    ;; The schema is an alist or plist representing JSON Schema
    ;; Verify both params are described
    (let ((schema-str (format "%S" schema)))
      (should (string-match-p "foo" schema-str))
      (should (string-match-p "bar" schema-str))
      (should (string-match-p "first thing" schema-str))
      (should (string-match-p "second thing" schema-str)))))

(ert-deftest org-wiki-test-enable-disable-roundtrip ()
  "Enable then disable should leave the registry clean.

Uses a unique server-id to avoid colliding with any existing tools."
  (let ((org-wiki-mcp-server-id "org-wiki-test-roundtrip")
        (org-wiki-mcp--registered nil))
    (unwind-protect
        (progn
          (org-wiki-mcp-enable)
          (should org-wiki-mcp--registered)
          (let ((tools-table (gethash org-wiki-mcp-server-id
                                      mcp-server-lib--tools)))
            (should tools-table)
            (should (= 4 (hash-table-count tools-table))))
          (org-wiki-mcp-disable)
          (should-not org-wiki-mcp--registered)
          (let ((tools-table (gethash org-wiki-mcp-server-id
                                      mcp-server-lib--tools)))
            (should (or (null tools-table)
                        (zerop (hash-table-count tools-table))))))
      ;; cleanup in case of early failure
      (ignore-errors (org-wiki-mcp-disable)))))

(ert-deftest org-wiki-test-enable-twice-errors ()
  "Calling enable twice without disabling should signal a clear error."
  (let ((org-wiki-mcp-server-id "org-wiki-test-double-enable")
        (org-wiki-mcp--registered nil))
    (unwind-protect
        (progn
          (org-wiki-mcp-enable)
          (should-error (org-wiki-mcp-enable) :type 'user-error))
      (ignore-errors (org-wiki-mcp-disable)))))

;;;; --- Hash property accessor -------------------------------------

(ert-deftest org-wiki-test-hash-property-name-when-loaded ()
  "If org-hash is loaded, `org-hash-property' returns a HASH_<algo> string."
  (skip-unless (require 'org-hash nil 'noerror))
  (let ((prop (org-wiki--hash-property-name)))
    (should (stringp prop))
    (should (string-prefix-p "HASH_" prop))))

(provide 'org-wiki-test)
;;; org-wiki-test.el ends here
