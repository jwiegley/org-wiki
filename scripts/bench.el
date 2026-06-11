;;; bench.el --- Performance benchmark harness for org-wiki -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Benchmark the public org-wiki read API against a generated fixture
;; tree and print one tab-separated "name<TAB>ratio" line per
;; benchmark on stdout.  Within every rep the benchmark and a
;; calibration loop are timed back-to-back and their CPU-time ratio
;; taken; the reported value is the median per-rep ratio.  Because
;; the two measurements in a rep run within milliseconds of each
;; other on the same core, scheduler placement and frequency scaling
;; inflate both alike and cancel out — which is what makes a 5%
;; regression gate workable on a developer machine.
;;
;; Usage:
;;
;;   emacs -Q --batch -L . -l scripts/bench.el -f org-wiki-bench-run

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-ql)
(require 'org-wiki)

(defconst org-wiki-bench--file-count 40
  "Number of fixture files to generate.")

(defconst org-wiki-bench--reps 9
  "Number of timed reps per benchmark; the median per-rep ratio is reported.")

(defvar org-ql-cache)

(defun org-wiki-bench--node-id (i)
  "Return the fixture node ID for file index I."
  (format "00000000-0000-4000-8000-%012d" i))

(defun org-wiki-bench--fixture (i)
  "Return fixture file content for index I.
Even indices are wiki nodes; odd indices are plain notes."
  (if (cl-evenp i)
      (format "#+title: Node %1$04d
#+filetags: :wiki:concept:

* Node %1$04d
  :PROPERTIES:
  :ID:           %2$s
  :WIKI_KIND:    Concept
  :CONFIDENCE:   high
  :END:

** Summary

Summary for node %1$04d, covering storage, hashing, and addressing.

** Definition

A longer body paragraph for node %1$04d.  Content addressing
identifies data by a hash of its bytes rather than by a path, so
renames cannot break references.
"
              i (org-wiki-bench--node-id i))
    (format "#+title: Note %1$04d
#+filetags: :journal:

* Note %1$04d
  :PROPERTIES:
  :ID:           %2$s
  :END:

An ordinary note that is not part of the wiki.
"
            i (org-wiki-bench--node-id i))))

(defun org-wiki-bench--setup ()
  "Create the fixture tree and point org-wiki at it.  Return its root."
  (let ((root (make-temp-file "org-wiki-bench-" t)))
    (dotimes (i org-wiki-bench--file-count)
      (let ((file (expand-file-name (format "node-%04d.org" i) root)))
        (with-temp-file file
          (insert (org-wiki-bench--fixture i)))
        (puthash (org-wiki-bench--node-id i) file org-id-locations)))
    root))

(defun org-wiki-bench--cpu-time ()
  "Return CPU run time of this Emacs process in float seconds."
  (float-time (get-internal-run-time)))

(defun org-wiki-bench--median (values)
  "Return the median of VALUES."
  (let* ((sorted (sort (copy-sequence values) #'<))
         (n (length sorted)))
    (if (cl-oddp n)
        (nth (/ n 2) sorted)
      (/ (+ (nth (1- (/ n 2)) sorted) (nth (/ n 2) sorted)) 2.0))))

(defun org-wiki-bench--sample (body)
  "Return the CPU seconds BODY takes to run once."
  (garbage-collect)
  (let ((start (org-wiki-bench--cpu-time)))
    (funcall body)
    (- (org-wiki-bench--cpu-time) start)))

(defvar org-wiki-bench--calibration-body
  (byte-compile
   (lambda ()
     (let ((h 0))
       (dotimes (i 500000)
         (setq h (sxhash (format "calibration-%d-%d" i h)))))))
  "Calibration workload: allocation, formatting, and hashing,
roughly the mix the real benchmarks exercise.  Sized to ~100ms of
CPU, comparable to one benchmark sample, so timer granularity does
not show up in the ratio's denominator.")

(defun org-wiki-bench--run-one (name iterations thunk)
  "Report NAME's median per-rep benchmark/calibration CPU-time ratio.
THUNK is executed ITERATIONS times per rep."
  (let ((body (byte-compile
               (lambda ()
                 (dotimes (_ iterations)
                   (funcall thunk))))))
    ;; Warm up both workloads, untimed.
    (funcall org-wiki-bench--calibration-body)
    (funcall body)
    (let ((ratios
           (cl-loop repeat org-wiki-bench--reps
                    collect (/ (org-wiki-bench--sample body)
                               (org-wiki-bench--sample
                                org-wiki-bench--calibration-body)))))
      (princ (format "%s\t%.4f\n" name (org-wiki-bench--median ratios))))))

(defun org-wiki-bench-run ()
  "Run all org-wiki benchmarks, printing TSV results to stdout."
  (setq gc-cons-threshold most-positive-fixnum)
  (let* ((org-id-locations (make-hash-table :test 'equal))
         (root (org-wiki-bench--setup))
         (org-wiki-root (file-name-as-directory root))
         (org-id-locations-file (expand-file-name ".org-id-locations" root))
         (wiki-id (org-wiki-bench--node-id 0)))
    (unwind-protect
        ;; Iteration counts are sized so each timed sample is on the
        ;; order of 100ms of CPU; much shorter and timer granularity
        ;; swamps the 5% regression tolerance.
        (progn
          (org-wiki-bench--run-one
           "all-files" 2000
           (lambda () (org-wiki--all-files)))
          (org-wiki-bench--run-one
           "search" 100
           (lambda ()
             ;; Fresh cache per call so we measure the query, not
             ;; org-ql's memoization.
             (let ((org-ql-cache (make-hash-table :weakness 'key)))
               (org-wiki--search "storage" 10))))
          (org-wiki-bench--run-one
           "read-node" 1000
           (lambda () (org-wiki-read-node wiki-id)))
          (org-wiki-bench--run-one
           "node-metadata" 1000
           (lambda () (org-wiki-node-metadata wiki-id))))
      (delete-directory root t))))

;;; bench.el ends here
