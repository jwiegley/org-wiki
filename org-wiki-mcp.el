;;; org-wiki-mcp.el --- MCP tool registration for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 14 May 2026
;; Keywords: outlines hypermedia
;; URL: https://github.com/jwiegley/dot-emacs

;; This file is distributed under the BSD 3-clause license; see the
;; LICENSE.md file in this repository for the full text.
;;
;; This file is part of the org-wiki package; the package metadata
;; (Version, Package-Requires) lives in org-wiki.el.  At runtime this
;; file additionally needs mcp-server-lib.

;;; Commentary:

;; Registers the read-only org-wiki tools against the running
;; `mcp-server-lib' instance.  Mirrors the pattern used by
;; `elisp-dev-mcp' (one defun per tool, `MCP Parameters:' docstring
;; block, single enable/disable pair).
;;
;; Open empirical question this spike answers:
;;
;;   1. Does `condition-case (error ...)' catch `mcp-server-lib-tool-error'?
;;      If yes, the wrapper would corrupt structured JSON errors.
;;      The answer determines whether we need an explicit
;;      `(mcp-server-lib-tool-error (signal ...))' clause before the
;;      generic catch.
;;
;;   2. What `:server-id' do wiki tools register under?  The doc's
;;      Option α recommends "default"; Option β uses "org-wiki".
;;      We default to "default" here and the test harness measures
;;      whether sharing the server-id collides with `elisp-dev-mcp''s
;;      own tools (which use server-id "elisp-dev-mcp", a separate
;;      endpoint).
;;
;;   3. Does `mcp-server-lib's auto-generated schema actually parse the
;;      `MCP Parameters:' docstring block correctly for multi-arg
;;      functions?

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mcp-server-lib)
(require 'org-wiki)

(defgroup org-wiki-mcp nil
  "MCP tool registration for org-wiki."
  :group 'org-wiki
  :prefix "org-wiki-mcp-")

(defcustom org-wiki-mcp-server-id "default"
  "Server-id under which wiki tools register.

The architecture doc discusses Option α (share `\"default\"' with
`wiki_'-prefixed tool ids) versus Option β (separate `\"org-wiki\"'
endpoint requiring the MCP client to connect to it explicitly).
Option α is the recommended default."
  :type 'string
  :group 'org-wiki-mcp)


;;;; --- Error signaling --------------------------------------------
;;
;; KEY EMPIRICAL FINDING (verified by test in org-wiki-test.el):
;;
;; `mcp-server-lib-tool-error' is defined as a child of `user-error',
;; which is itself a child of `error'.  Therefore a `condition-case'
;; clause like `(error ...)' catches it.  If the wiki tools use the
;; pattern recommended by v2.2 of the architecture doc:
;;
;;   (condition-case err
;;       (json-encode (org-wiki-search query k))
;;     (error (org-wiki-mcp--throw `((error . "internal_error") ...))))
;;
;; then our own `mcp-server-lib-tool-error' signals get caught and
;; rewrapped as "internal_error", losing the structured JSON we wanted
;; to surface.  Fix: add a `(mcp-server-lib-tool-error (signal (car err)
;; (cdr err)))' clause *first* so it's matched before the generic
;; `error' fallback.
;;
;; Verified directly in tests; see org-wiki-test.el
;; `org-wiki-test-tool-error-survives-rewrap-pattern'.

(define-error 'org-wiki-tool-error
              "Wiki MCP tool error"
              'mcp-server-lib-tool-error)

(defun org-wiki-mcp--throw (alist)
  "Signal a structured tool error with ALIST encoded as JSON.
Bypasses any naive `condition-case (error ...)' rewrap because the
caller is expected to pass through `mcp-server-lib-tool-error'
explicitly."
  (signal 'mcp-server-lib-tool-error
          (list (json-encode alist))))

(defun org-wiki-mcp--wiki-error-payload (data)
  "Convert `org-wiki-error' signal DATA to a JSON-ready alist.
DATA is (CODE-KEYWORD ARG...) as signaled by the org-wiki read API,
for example (:unknown_id \"abc\")."
  (let ((code (car data)))
    `((error . ,(if (keywordp code)
                    (substring (symbol-name code) 1)
                  "wiki_error"))
      ,@(when (cdr data)
          `((detail . ,(format "%s" (cadr data))))))))

(defmacro org-wiki-mcp--with-error-handling (&rest body)
  "Run BODY, converting unexpected errors to JSON-encoded tool errors.

Crucially, `mcp-server-lib-tool-error' (and its descendants like
`org-wiki-tool-error') is re-raised explicitly *before* the generic
`error' catch.  This is the fix for the bug v2.2 of the architecture
doc introduced — see commentary above."
  (declare (indent 0))
  `(condition-case err
       (progn ,@body)
     ;; Re-raise tool errors so the dispatcher gets them intact
     (mcp-server-lib-tool-error
      (signal (car err) (cdr err)))
     ;; Wiki errors carry a structured (CODE ARG...) payload; surface
     ;; it as structured JSON rather than letting the generic clause
     ;; flatten it into an opaque "internal_error" message string.
     (org-wiki-error
      (org-wiki-mcp--throw (org-wiki-mcp--wiki-error-payload (cdr err))))
     ;; Only the generic case becomes "internal_error"
     (error
      (org-wiki-mcp--throw
       `((error . "internal_error")
         (message . ,(error-message-string err)))))))

;;;; --- Tool handlers (MCP-shaped wrappers around org-wiki API) ----

(defun org-wiki-mcp--search-tool (query k)
  "Search wiki nodes for QUERY, returning up to K results.

MCP Parameters:
  query - search query string
  k - maximum number of results (a positive integer up to 100;
      mcp-server-lib delivers all schema parameters as strings, so the
      handler parses it; anything unparsable falls back to the
      default limit)."
  (org-wiki-mcp--with-error-handling
    (json-encode
     (org-wiki-search query (org-wiki-mcp--parse-k k)))))

(defun org-wiki-mcp--parse-k (k)
  "Return a sane result limit from the wire-level K value.
Overflowing literals parse to floats and negative or junk values
must not reach `seq-take', so anything outside 1..100 falls back to
`org-wiki-default-search-limit'."
  (cond ((and (integerp k) (> k 0)) (min k 100))
        ((and (stringp k) (string-match-p "\\`[0-9]+\\'" k))
         (let ((n (string-to-number k)))
           (if (and (integerp n) (> n 0))
               (min n 100)
             org-wiki-default-search-limit)))
        (t org-wiki-default-search-limit)))

(defun org-wiki-mcp--read-node-tool (id)
  "Return the full body of the wiki node with ID.

MCP Parameters:
  id - the :ID: property value (a UUID or src-<uuid> string)."
  (org-wiki-mcp--with-error-handling
    (json-encode (list :id id :body (org-wiki-read-node id)))))

(defun org-wiki-mcp--node-metadata-tool (id)
  "Return the property drawer of the wiki node with ID (hash omitted).

MCP Parameters:
  id - the :ID: property value."
  (org-wiki-mcp--with-error-handling
    (json-encode (org-wiki-node-metadata id))))

(defun org-wiki-mcp--backlinks-tool (id)
  "Return backlinks to the wiki node with ID.

MCP Parameters:
  id - the :ID: property value of the target node."
  (org-wiki-mcp--with-error-handling
    (json-encode (org-wiki-backlinks id))))

;;;; --- Registration -----------------------------------------------

(defconst org-wiki-mcp--tools
  '(("wiki_search" org-wiki-mcp--search-tool
     "Search wiki nodes (entries with a :WIKI_KIND: property).  Returns \
up to k results as JSON objects with id, title, kind, file, and \
summary, ordered by semantic similarity when the backend is available.")
    ("wiki_read_node" org-wiki-mcp--read-node-tool
     "Return the full body of the wiki node with the given :ID: — its \
whole subtree with Org syntax preserved.")
    ("wiki_node_metadata" org-wiki-mcp--node-metadata-tool
     "Return the property drawer of the wiki node with the given :ID: \
as JSON, with tool-maintained hash properties stripped.")
    ("wiki_backlinks" org-wiki-mcp--backlinks-tool
     "Return the nodes that link to the wiki node with the given :ID:, \
via org-roam's backlink index."))
  "Tool registration spec: (TOOL-ID HANDLER-SYMBOL DESCRIPTION).
The descriptions are hand-written summaries: per-parameter text lives
in each handler's `MCP Parameters:' docstring block, which
mcp-server-lib extracts into the inputSchema — passing the whole
docstring as :description would duplicate it.  All spike tools are
read-only.")

(defvar org-wiki-mcp--registered nil
  "Non-nil while the wiki server registration is live.")

;;;###autoload
(defun org-wiki-mcp-enable ()
  "Register the read-only wiki tools against the running mcp-server-lib server.
Uses `mcp-server-lib-register-server' (the current API; the older
per-tool `mcp-server-lib-register-tool' is obsolete as of 0.3.0).
No :instructions are set because the default server-id is a shared
endpoint and that field is last-writer-wins."
  (interactive)
  (when org-wiki-mcp--registered
    (user-error "Wiki MCP tools already registered; call org-wiki-mcp-disable first"))
  (mcp-server-lib-register-server
   :id org-wiki-mcp-server-id
   :tools (mapcar (pcase-lambda (`(,id ,handler ,description))
                    (list handler :id id :description description
                          :read-only t))
                  org-wiki-mcp--tools))
  (setq org-wiki-mcp--registered t)
  (message "org-wiki: registered %d read-only tools on server-id %S"
           (length org-wiki-mcp--tools)
           org-wiki-mcp-server-id))

;;;###autoload
(defun org-wiki-mcp-disable ()
  "Unregister all wiki tools."
  (interactive)
  (when org-wiki-mcp--registered
    (mcp-server-lib-unregister-server org-wiki-mcp-server-id)
    (setq org-wiki-mcp--registered nil))
  (message "org-wiki: unregistered tools"))

(provide 'org-wiki-mcp)
;;; org-wiki-mcp.el ends here
