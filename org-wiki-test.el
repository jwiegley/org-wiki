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
      (dolist (buf (buffer-list))
        (let ((file (buffer-file-name buf)))
          (when (and file
                     (string-prefix-p (file-name-as-directory root) file))
            (with-current-buffer buf
              (set-buffer-modified-p nil))
            (kill-buffer buf))))
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
