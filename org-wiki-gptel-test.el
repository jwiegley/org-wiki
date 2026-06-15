;;; org-wiki-gptel-test.el --- ERT tests for org-wiki-gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Tests for the gptel integration layer.  Reuses the fixture harness
;; and node constants from org-wiki-test.el.  The tool functions are
;; plain elisp and are tested without gptel; everything that touches
;; gptel's registry, presets or request plumbing is guarded with
;; `skip-unless' and runs only when gptel is installed (it is present
;; in the Nix dev shell and flake checks via devDeps, so the gates
;; exercise the real integration rather than skipping).  The headless
;; load contract is asserted in a fresh subprocess.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-wiki)
(require 'org-wiki-gptel)
(require 'org-wiki-test)            ; fixtures + org-wiki-test-with-fixtures

;; Loaded only inside the skip-unless-guarded integration tests.
(defvar gptel--known-tools)
(defvar gptel--known-presets)
(defvar gptel--preset)
(defvar gptel-backend)
(defvar gptel-directives)
(defvar gptel-model)
(defvar gptel-tools)
(defvar gptel-use-tools)
(defvar gptel-confirm-tool-calls)
(defvar gptel-system-prompt)
(declare-function gptel--apply-preset "ext:gptel" (preset &optional setter))
(declare-function gptel-get-tool "ext:gptel-request")
(declare-function gptel-get-preset "ext:gptel")
(declare-function gptel-make-tool "ext:gptel-request")
;; cl-defstruct constructor and accessors (FILEONLY = t).
(declare-function gptel--make-backend "ext:gptel-request" (&rest slots) t)
(declare-function gptel-tool-name "ext:gptel-request" (tool) t)
(declare-function gptel-tool-category "ext:gptel-request" (tool) t)
(declare-function gptel-tool-async "ext:gptel-request" (tool) t)
(declare-function gptel-tool-confirm "ext:gptel-request" (tool) t)
(declare-function gptel-tool-include "ext:gptel-request" (tool) t)
(declare-function gptel-tool-args "ext:gptel-request" (tool) t)
(declare-function gptel-tool-function "ext:gptel-request" (tool) t)

;;;; --- Headless load contract ---------------------------------------

(ert-deftest org-wiki-gptel-test-loads-headless ()
  "The file loads and defines its commands without gptel ever loading.
Runs in a fresh batch subprocess so the check holds no matter what
earlier tests pulled into this session.  gptel may well be present
on the load path; the contract is that loading org-wiki-gptel does
not load it."
  (let* ((dir (file-name-directory (locate-library "org-wiki-gptel")))
         (roam (make-temp-file "org-wiki-gptel-headless-" t))
         (form '(kill-emacs
                 (if (and (not (featurep 'gptel))
                          (commandp 'org-wiki-ask)
                          (commandp 'org-wiki-chat)
                          (commandp 'org-wiki-gptel-register)
                          (fboundp 'org-wiki-gptel--search)
                          (fboundp 'org-wiki-gptel--read-node)
                          (fboundp 'org-wiki-gptel--node-metadata)
                          (fboundp 'org-wiki-gptel--backlinks))
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
                        "-l" (expand-file-name "org-wiki-gptel.el" dir)
                        "--eval" (format "%S" form))))
      (delete-directory roam t))))

(ert-deftest org-wiki-gptel-test-commands-exist ()
  "The contract commands are interactive commands."
  (should (commandp 'org-wiki-ask))
  (should (commandp 'org-wiki-chat))
  (should (commandp 'org-wiki-gptel-register)))

(ert-deftest org-wiki-gptel-test-commands-user-error-without-gptel ()
  "Entry points signal `user-error' when gptel cannot be loaded."
  (let ((real-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'gptel)
                     nil
                   (funcall real-require feature filename noerror)))))
      (should-error (org-wiki-ask "q") :type 'user-error)
      (should-error (org-wiki-chat) :type 'user-error)
      (should-error (org-wiki-gptel-register) :type 'user-error))))

;;;; --- System prompt -------------------------------------------------

(ert-deftest org-wiki-gptel-test-system-prompt-directive-wins ()
  "The gptel-prompts directive overrides the built-in default."
  (let ((gptel-directives '((org-wiki-ask . "FILE WINS"))))
    (should (equal (org-wiki-gptel--system) "FILE WINS"))))

(ert-deftest org-wiki-gptel-test-system-prompt-defaults ()
  "Without a directive, the built-in default system prompt is used."
  (let ((gptel-directives nil))
    (should (eq (org-wiki-gptel--system) org-wiki-gptel--default-system))))

(ert-deftest org-wiki-gptel-test-default-system-content ()
  "The default system prompt carries its load-bearing instructions."
  (should (string-match-p "wiki_search" org-wiki-gptel--default-system))
  (should (string-match-p (regexp-quote "[[id:")
                          org-wiki-gptel--default-system))
  (should (string-match-p "COVERAGE GAP" org-wiki-gptel--default-system)))

;;;; --- Tool functions (no gptel needed) -------------------------------

(ert-deftest org-wiki-gptel-test-clamp-k ()
  "K clamping: positive integers pass through, junk falls back."
  (should (= (org-wiki-gptel--clamp-k 7) 7))
  (should (= (org-wiki-gptel--clamp-k 1000) 100))
  (should (= (org-wiki-gptel--clamp-k 2.0) 2))
  (should (= (org-wiki-gptel--clamp-k 2.7) 2))
  (should (= (org-wiki-gptel--clamp-k 0.9)
             org-wiki-default-search-limit))
  (should (= (org-wiki-gptel--clamp-k nil) org-wiki-default-search-limit))
  (should (= (org-wiki-gptel--clamp-k 0) org-wiki-default-search-limit))
  (should (= (org-wiki-gptel--clamp-k -1) org-wiki-default-search-limit))
  (should (= (org-wiki-gptel--clamp-k "5") org-wiki-default-search-limit)))

(ert-deftest org-wiki-gptel-test-search-tool-passes-clamped-k ()
  "The search tool clamps K before handing it to `org-wiki--search'."
  (let (seen)
    (cl-letf (((symbol-function 'org-wiki--search)
               (lambda (_query k) (push k seen) nil)))
      (org-wiki-gptel--search "q" nil)
      (org-wiki-gptel--search "q" 0)
      (org-wiki-gptel--search "q" 7)
      (org-wiki-gptel--search "q" 1000)
      (org-wiki-gptel--search "q" 2.0)
      (org-wiki-gptel--search "q" 0.9))
    (should (equal (nreverse seen)
                   (list org-wiki-default-search-limit
                         org-wiki-default-search-limit
                         7 100 2
                         org-wiki-default-search-limit)))))

(ert-deftest org-wiki-gptel-test-search-tool-returns-json-array ()
  "The search tool returns a JSON array of node summary objects."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((json (org-wiki-gptel--search "Content-Addressed" 10))
          (results (json-parse-string json :object-type 'alist
                                      :array-type 'list)))
     (should (consp results))
     (let ((hit (car results)))
       (should (equal (alist-get 'id hit)
                      "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
       (should (equal (alist-get 'title hit) "Content-Addressed Storage"))
       (should (equal (alist-get 'kind hit) "Concept"))
       (should (stringp (alist-get 'file hit)))
       (should (string-match-p "content addressing"
                               (downcase (alist-get 'summary hit))))))))

(ert-deftest org-wiki-gptel-test-search-tool-empty-is-array ()
  "No hits encode as an empty JSON array, never JSON null."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (should (equal (org-wiki-gptel--search "zzz-no-such-thing" nil) "[]"))))

(ert-deftest org-wiki-gptel-test-read-node-tool ()
  "The read tool returns {id, body} with the full Org subtree."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((json (org-wiki-gptel--read-node
                 "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
          (obj (json-parse-string json :object-type 'alist)))
     (should (equal (alist-get 'id obj)
                    "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
     (should (string-match-p "\\* Content-Addressed Storage"
                             (alist-get 'body obj)))
     (should (string-match-p ":WIKI_KIND:" (alist-get 'body obj))))))

(ert-deftest org-wiki-gptel-test-read-node-tool-returns-error-json ()
  "Unknown ids RETURN a structured JSON error; nothing signals."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((json (org-wiki-gptel--read-node "no-such-id"))
          (obj (json-parse-string json :object-type 'alist)))
     (should (equal (alist-get 'error obj) "unknown_id"))
     (should (equal (alist-get 'detail obj) "no-such-id")))))

(ert-deftest org-wiki-gptel-test-metadata-tool ()
  "The metadata tool returns downcased keys with hash properties gone."
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((json (org-wiki-gptel--node-metadata
                 "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
          (obj (json-parse-string json :object-type 'alist)))
     (should (equal (alist-get 'wiki_kind obj) "Concept"))
     (should (equal (alist-get 'confidence obj) "high"))
     (should (equal (alist-get 'id obj)
                    "4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91"))
     (should-not (cl-some (lambda (kv)
                            (string-prefix-p "hash_"
                                             (symbol-name (car kv))))
                          obj)))))

(ert-deftest org-wiki-gptel-test-backlinks-tool-normalizes-nil ()
  "Backlinks encode as a JSON array; nil normalizes to [] not null."
  (cl-letf (((symbol-function 'org-wiki--backlinks) (lambda (_id) nil)))
    (should (equal (org-wiki-gptel--backlinks "any-id") "[]")))
  (cl-letf (((symbol-function 'org-wiki--backlinks)
             (lambda (_id)
               (list (list :from-id "a" :from-title "T"
                           :from-file "/f.org")))))
    (let* ((json (org-wiki-gptel--backlinks "any-id"))
           (results (json-parse-string json :object-type 'alist
                                       :array-type 'list)))
      (should (= (length results) 1))
      (should (equal (alist-get 'from-id (car results)) "a"))
      (should (equal (alist-get 'from-title (car results)) "T"))
      (should (equal (alist-get 'from-file (car results)) "/f.org")))))

(ert-deftest org-wiki-gptel-test-internal-error-returns-json ()
  "Unexpected errors come back as {error: internal_error, message}."
  (cl-letf (((symbol-function 'org-wiki--search)
             (lambda (&rest _) (error "Boom"))))
    (let* ((json (org-wiki-gptel--search "q" nil))
           (obj (json-parse-string json :object-type 'alist)))
      (should (equal (alist-get 'error obj) "internal_error"))
      (should (string-match-p "Boom" (alist-get 'message obj))))))

;;;; --- Registration (real gptel) --------------------------------------

(ert-deftest org-wiki-gptel-test-register-tools-and-schema ()
  "Registration produces four tools with the exact contract schema."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (dolist (name org-wiki-gptel--tool-names)
    (let ((tool (gptel-get-tool (list "org-wiki" name))))
      (should tool)
      (should (equal (gptel-tool-name tool) name))
      (should (equal (gptel-tool-category tool) "org-wiki"))
      (should-not (gptel-tool-async tool))
      (should-not (gptel-tool-confirm tool))
      (should-not (gptel-tool-include tool))
      (should (functionp (gptel-tool-function tool)))))
  ;; wiki_search: query (required string) + k (optional integer);
  ;; gptel preprocesses :type symbols into schema strings.
  (let* ((args (gptel-tool-args (gptel-get-tool '("org-wiki" "wiki_search"))))
         (q (nth 0 args))
         (k (nth 1 args)))
    (should (= (length args) 2))
    (should (equal (plist-get q :name) "query"))
    (should (equal (plist-get q :type) "string"))
    (should-not (plist-get q :optional))
    (should (equal (plist-get k :name) "k"))
    (should (equal (plist-get k :type) "integer"))
    (should (plist-get k :optional)))
  ;; The other three take a single required string id.
  (dolist (name '("wiki_read_node" "wiki_node_metadata" "wiki_backlinks"))
    (let ((args (gptel-tool-args (gptel-get-tool (list "org-wiki" name)))))
      (should (= (length args) 1))
      (should (equal (plist-get (car args) :name) "id"))
      (should (equal (plist-get (car args) :type) "string"))
      (should-not (plist-get (car args) :optional)))))

(ert-deftest org-wiki-gptel-test-register-idempotent ()
  "Re-registering leaves exactly one registry entry per tool name."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (org-wiki-gptel-register)
  (let ((cat (cdr (assoc "org-wiki" gptel--known-tools))))
    (should (= (length cat) 4))
    (dolist (name org-wiki-gptel--tool-names)
      (should (= (cl-count name cat :key #'car :test #'equal) 1)))))

(ert-deftest org-wiki-gptel-test-register-preset ()
  "The org-wiki preset bundles the tools and inherits the backend."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (let ((spec (gptel-get-preset 'org-wiki)))
    (should spec)
    (should (equal (mapcar #'gptel-tool-name (plist-get spec :tools))
                   org-wiki-gptel--tool-names))
    (should (cl-every (lambda (tool)
                        (equal (gptel-tool-category tool) "org-wiki"))
                      (plist-get spec :tools)))
    (should (eq (plist-get spec :system) #'org-wiki-gptel--system))
    (should (plist-get spec :use-tools))
    (should (plist-member spec :confirm-tool-calls))
    (should-not (plist-get spec :confirm-tool-calls))
    ;; No backend/model: the preset must inherit whatever is in effect.
    (should-not (plist-member spec :backend))
    (should-not (plist-member spec :model))))

(ert-deftest org-wiki-gptel-test-preset-ignores-duplicate-tool-names ()
  "Applying the preset keeps org-wiki tools when names are duplicated."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (let ((known-tools (copy-tree gptel--known-tools))
        (known-presets (copy-tree gptel--known-presets)))
    (unwind-protect
        (progn
          (org-wiki-gptel-register)
          (dolist (name org-wiki-gptel--tool-names)
            (gptel-make-tool
             :name name
             :function #'ignore
             :description "Same-named non-org-wiki test tool."
             :args nil
             :category "mcp" :confirm nil :include nil))
          (setq gptel--known-tools
                (append (cl-remove-if-not
                         (lambda (cat) (equal (car cat) "mcp"))
                         gptel--known-tools)
                        (cl-remove-if
                         (lambda (cat) (equal (car cat) "mcp"))
                         gptel--known-tools)))
          (let ((gptel--preset nil)
                (gptel-tools nil)
                (gptel-use-tools nil)
                (gptel-confirm-tool-calls t)
                (gptel-system-prompt nil))
            (gptel--apply-preset 'org-wiki)
            (should (equal (mapcar #'gptel-tool-name gptel-tools)
                           org-wiki-gptel--tool-names))
            (should (cl-every
                     (lambda (tool)
                       (equal (gptel-tool-category tool) "org-wiki"))
                     gptel-tools))))
      (setq gptel--known-tools known-tools)
      (setq gptel--known-presets known-presets))))

(ert-deftest org-wiki-gptel-test-registered-functions-callable ()
  "The registered tool functions run positionally as gptel calls them."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (org-wiki-test-with-fixtures
   (org-wiki-test--write-fixture "concepts/202605131012-cas.org"
                                 org-wiki-test--concept-node)
   (let* ((tool (gptel-get-tool '("org-wiki" "wiki_search")))
          ;; gptel passes nil for omitted :optional args.
          (json (funcall (gptel-tool-function tool) "Content-Addressed" nil))
          (results (json-parse-string json :object-type 'alist
                                      :array-type 'list)))
     (should (equal (alist-get 'title (car results))
                    "Content-Addressed Storage")))))

;;;; --- Model resolution ------------------------------------------------

(ert-deftest org-wiki-gptel-test-resolve-model-defcustom-wins ()
  "An explicit `org-wiki-gptel-model' beats every inherited source."
  (let ((org-wiki-gptel-model 'wiki-model)
        (gptel-model 'global-model))
    (should (eq (org-wiki-gptel--resolve-model) 'wiki-model))))

(ert-deftest org-wiki-gptel-test-resolve-model-inherits-gptel-model ()
  "With a nil defcustom, the buffer's (or global) `gptel-model' wins."
  (let ((org-wiki-gptel-model nil)
        (gptel-model 'global-model))
    (should (eq (org-wiki-gptel--resolve-model) 'global-model))))

(ert-deftest org-wiki-gptel-test-resolve-model-backend-fallback ()
  "With no model anywhere, the backend's first model is chosen."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (let ((org-wiki-gptel-model nil)
        (gptel-model nil)
        (gptel-backend (gptel--make-backend
                        :name "test-backend"
                        :models '(model-a model-b))))
    (should (eq (org-wiki-gptel--resolve-model) 'model-a)))
  ;; A backend advertising no models cannot rescue a nil model.
  (let ((org-wiki-gptel-model nil)
        (gptel-model nil)
        (gptel-backend (gptel--make-backend :name "empty" :models nil)))
    (should-error (org-wiki-gptel--resolve-model) :type 'user-error)))

(ert-deftest org-wiki-gptel-test-resolve-model-all-nil-user-errors ()
  "No defcustom, no `gptel-model', no backend: a naming `user-error'.
A nil model must never reach the wire — gptel sends it as-is and the
provider answers with an opaque HTTP 404."
  (let ((org-wiki-gptel-model nil)
        (gptel-model nil)
        (gptel-backend nil))
    (let ((err (should-error (org-wiki-gptel--resolve-model)
                             :type 'user-error)))
      (should (string-match-p "[Nn]o gptel model configured"
                              (cadr err))))))

(ert-deftest org-wiki-gptel-test-prepare-buffer-pins-model ()
  "`org-wiki-gptel--prepare-buffer' pins the resolved model locally.
A fresh ask buffer otherwise inherits a global nil `gptel-model',
which goes out on the wire and 404s at the provider."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (let ((org-wiki-gptel-model nil)
        (gptel-model nil)
        (gptel-backend (gptel--make-backend
                        :name "test-backend"
                        :models '(model-a model-b))))
    (with-temp-buffer
      (org-wiki-gptel--prepare-buffer)
      (should (local-variable-p 'gptel-model))
      (should (eq gptel-model 'model-a)))))

;;;; --- org-wiki-ask -----------------------------------------------------

(ert-deftest org-wiki-gptel-test-ask-prepares-buffer-and-request ()
  "`org-wiki-ask' arms the buffer locals and issues the request."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (when (get-buffer "*org-wiki-ask*")
    (kill-buffer "*org-wiki-ask*"))
  (unwind-protect
      (let ((gptel-model 'global-model)
            captured)
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (&optional prompt &rest keys)
                     (setq captured (cons prompt keys))))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (org-wiki-ask "What is content addressing?"))
        (let ((buf (get-buffer "*org-wiki-ask*")))
          (should buf)
          (with-current-buffer buf
            (should (derived-mode-p 'org-mode))
            (should (string-match-p "^\\* What is content addressing\\?"
                                    (buffer-string)))
            (should (= (length gptel-tools) 4))
            (should gptel-use-tools)
            (should (local-variable-p 'gptel-model))
            (should (eq gptel-model 'global-model))
            (should (local-variable-p (org-wiki-gptel--system-var))))
          (pcase-let ((`(,prompt . ,keys) captured))
            (should (equal prompt "What is content addressing?"))
            (should (plist-get keys :stream))
            (should (functionp (plist-get keys :callback)))
            (let ((system (plist-get keys :system)))
              (should (stringp system))
              (should (> (length system) 0)))
            (let ((pos (plist-get keys :position)))
              (should (markerp pos))
              (should (eq (marker-buffer pos) buf))))))
    (when (get-buffer "*org-wiki-ask*")
      (kill-buffer "*org-wiki-ask*"))))

(ert-deftest org-wiki-gptel-test-ask-callback-stream-and-errors ()
  "The ask callback streams chunks at the marker and reports errors."
  (with-temp-buffer
    (let ((marker (point-marker)))
      (set-marker-insertion-type marker t)
      (let ((cb (org-wiki-gptel--ask-callback marker)))
        (funcall cb "Hello, " nil)
        (funcall cb "wiki." nil)
        (should (string= (buffer-string) "Hello, wiki."))
        ;; End-of-stream, reasoning chunks and aborts insert nothing.
        (funcall cb t nil)
        (funcall cb '(reasoning . "hmm") nil)
        (funcall cb 'abort nil)
        (should (string= (buffer-string) "Hello, wiki."))
        ;; A request error surfaces its status in the buffer.
        (funcall cb nil '(:status "401 unauthorized"))
        (should (string-match-p "gptel error: 401 unauthorized"
                                (buffer-string)))))))

(ert-deftest org-wiki-gptel-test-ask-callback-dead-buffer ()
  "Once the answer buffer is killed, the callback drops everything.
Inserting at a marker whose buffer is dead errors inside gptel's
callback machinery; the guard swallows every branch and mentions
the kill in the echo area exactly once."
  (let* ((buf (generate-new-buffer " *org-wiki-ask-dead*"))
         (marker (with-current-buffer buf (point-marker)))
         (messages nil))
    (set-marker-insertion-type marker t)
    (let ((cb (org-wiki-gptel--ask-callback marker)))
      (kill-buffer buf)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when fmt (push (apply #'format fmt args) messages))
                   nil)))
        (funcall cb "a streamed chunk" nil)       ; would insert
        (funcall cb t nil)                        ; end-of-stream
        (funcall cb nil '(:status "500 oops"))    ; would insert
        (funcall cb 'abort nil))
      (should (equal messages
                     '("org-wiki-ask: answer buffer was killed"))))))

(ert-deftest org-wiki-gptel-test-ask-callback-tool-result ()
  "Tool results only message the echo area; nothing is inserted."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (org-wiki-gptel-register)
  (with-temp-buffer
    (let ((marker (point-marker)))
      (set-marker-insertion-type marker t)
      (let ((cb (org-wiki-gptel--ask-callback marker))
            (tool (gptel-get-tool '("org-wiki" "wiki_search"))))
        (funcall cb (cons 'tool-result (list (list tool nil "[]"))) nil)
        (should (string= (buffer-string) ""))))))

;;;; --- org-wiki-chat -----------------------------------------------------

(ert-deftest org-wiki-gptel-test-chat-applies-preset ()
  "`org-wiki-chat' layers the org-wiki preset onto the gptel buffer."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (let ((chat-buf (generate-new-buffer " *org-wiki-chat-test*")))
    (unwind-protect
        (progn
          (with-current-buffer chat-buf
            (delay-mode-hooks (org-mode)))
          (cl-letf (((symbol-function 'gptel)
                     (lambda (_name &rest _) chat-buf))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buf &rest _) buf)))
            (let ((gptel-model 'global-model))
              (org-wiki-chat)))
          (with-current-buffer chat-buf
            ;; The preset sets no :model; the command pins one anyway.
            (should (local-variable-p 'gptel-model))
            (should (eq gptel-model 'global-model))
            (should (= (length gptel-tools) 4))
            (should (cl-every (lambda (tool)
                                (member (gptel-tool-name tool)
                                        org-wiki-gptel--tool-names))
                              gptel-tools))
            (should (local-variable-p 'gptel-use-tools))
            (should gptel-use-tools)
            ;; `gptel--apply-preset' resolves the rename itself; assert
            ;; against whichever variable the loaded gptel uses.
            (should (local-variable-p (org-wiki-gptel--system-var)))))
      (kill-buffer chat-buf))))

(ert-deftest org-wiki-gptel-test-chat-missing-model-creates-no-buffer ()
  "`org-wiki-chat' signals before creating a buffer when no model resolves.
Regression for the half-configured-buffer note: the model is resolved
before `gptel' spins up *org-wiki-chat*, so a missing-model
`user-error' leaves nothing behind for the next call to reuse."
  (skip-unless (locate-library "gptel"))
  (require 'gptel)
  (let ((gptel-called nil))
    (cl-letf (((symbol-function 'gptel)
               (lambda (&rest _)
                 (setq gptel-called t)
                 (generate-new-buffer " *org-wiki-chat-should-not-exist*")))
              ((symbol-function 'pop-to-buffer) (lambda (buf &rest _) buf)))
      (let ((org-wiki-gptel-model nil)
            (gptel-model nil)
            (gptel-backend nil))
        (should-error (org-wiki-chat) :type 'user-error)
        (should-not gptel-called)))))

(provide 'org-wiki-gptel-test)
;;; org-wiki-gptel-test.el ends here
