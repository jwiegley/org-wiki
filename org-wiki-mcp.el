;;; org-wiki-mcp.el --- MCP tool registration for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 14 May 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org-wiki "0.1") (mcp-server-lib "0.1"))
;; Keywords: org wiki llm mcp

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

(defvar org-wiki-mcp--registered-tool-ids nil
  "List of tool ids currently registered by `org-wiki-mcp-enable'.")

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
     ;; Only the generic case becomes "internal_error"
     (error
      (org-wiki-mcp--throw
       `((error . "internal_error")
         (message . ,(error-message-string err)))))))

;;;; --- Tool handlers (MCP-shaped wrappers around org-wiki API) ----

(defun org-wiki-mcp--search-tool (query k)
  "Semantic search over wiki nodes.

MCP Parameters:
  query - search query string
  k - maximum number of results (an integer, encoded as a JSON number;
      mcp-server-lib delivers all schema parameters as strings, so the
      handler parses it)."
  (org-wiki-mcp--with-error-handling
    (json-encode
     (org-wiki-search query
                      (cond ((numberp k) k)
                            ((and (stringp k) (string-match-p "\\`[0-9]+\\'" k))
                             (string-to-number k))
                            (t org-wiki-default-search-limit))))))

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
  '(("wiki_search"        org-wiki-mcp--search-tool        t)
    ("wiki_read_node"     org-wiki-mcp--read-node-tool     t)
    ("wiki_node_metadata" org-wiki-mcp--node-metadata-tool t)
    ("wiki_backlinks"     org-wiki-mcp--backlinks-tool     t))
  "Tool registration spec: (TOOL-ID HANDLER-SYMBOL READ-ONLY-P).
All read-only spike tools have READ-ONLY-P = t.")

;;;###autoload
(defun org-wiki-mcp-enable ()
  "Register the read-only wiki tools against the running mcp-server-lib server."
  (interactive)
  (when org-wiki-mcp--registered-tool-ids
    (user-error "Wiki MCP tools already registered (%d tools); call org-wiki-mcp-disable first"
                (length org-wiki-mcp--registered-tool-ids)))
  (dolist (spec org-wiki-mcp--tools)
    (let ((id (nth 0 spec))
          (handler (nth 1 spec))
          (read-only (nth 2 spec)))
      (mcp-server-lib-register-tool
       handler
       :id id
       :server-id org-wiki-mcp-server-id
       :description (or (documentation handler)
                        (format "Org-wiki tool: %s" id))
       :read-only read-only)
      (push id org-wiki-mcp--registered-tool-ids)))
  (message "org-wiki: registered %d read-only tools on server-id %S"
           (length org-wiki-mcp--tools)
           org-wiki-mcp-server-id))

;;;###autoload
(defun org-wiki-mcp-disable ()
  "Unregister all wiki tools."
  (interactive)
  (dolist (id org-wiki-mcp--registered-tool-ids)
    (mcp-server-lib-unregister-tool id org-wiki-mcp-server-id))
  (setq org-wiki-mcp--registered-tool-ids nil)
  (message "org-wiki: unregistered tools"))

(provide 'org-wiki-mcp)
;;; org-wiki-mcp.el ends here
