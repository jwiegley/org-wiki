;; -*- mode: eask; lexical-binding: t -*-

(package "org-wiki"
         "0.1.0"
         "Org-native LLM Wiki (read-only spike)")

(website-url "https://github.com/jwiegley/dot-emacs")
(keywords "org" "wiki" "llm" "mcp")

(package-file "org-wiki.el")

(files "org-wiki.el" "org-wiki-mcp.el")

(script "test" "eask test ert org-wiki-test.el")

(source "gnu")
(source "melpa")

(depends-on "emacs" "29.1")
(depends-on "org"   "9.6")
(depends-on "org-roam" "2.2")
(depends-on "org-ql" "0.7")

(development
 (depends-on "ert"))
