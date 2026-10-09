;;; projdex.el --- Fast project file finder backed by a Rust module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The projdex authors

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (emrs "0.1.0"))
;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; projdex keeps a live index of each project's files in a Rust module
;; (built with emrs) and answers fuzzy queries from it, for
;; `project-find-file' and other `completing-read' prompts.
;;
;; This file holds the core: one service instance per project root
;; (started lazily), event and exit handling, the query entry points and
;; the user commands.  The module must be installed as `projdex-module'
;; plus `module-file-suffix' on `load-path'.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'project)

(defgroup projdex nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "projdex-")

;;;; Options

(defcustom projdex-include-hidden t
  "Non-nil means hidden files are indexed."
  :type 'boolean)

(defcustom projdex-ignores nil
  "Extra gitignore-syntax patterns, relative to the project root."
  :type '(repeat string))

(defcustom projdex-limit 200
  "Number of candidates returned per query."
  :type 'natnum)

(defcustom projdex-highlight t
  "Non-nil means matched characters are highlighted in candidates."
  :type 'boolean)

(defcustom projdex-query-timeout 10.0
  "Seconds before a query gives up.
This is a safety net against a stuck instance, not a latency budget."
  :type 'number)

(defcustom projdex-provide-project-files nil
  "Non-nil means `projdex-mode' serves `project-files' from the index."
  :type 'boolean)

(defcustom projdex-files-timeout 10.0
  "Seconds `project-files' waits for the index before falling back."
  :type 'number)

;;;; Instances

(cl-defstruct (projdex--rec (:constructor projdex--make-rec) (:copier nil))
  "State of the service instance of one project root."
  instance root (files 0) indexing watching (epoch 0) warned)

(defvar projdex--instances (make-hash-table :test 'equal)
  "Running instance records, keyed by project root.")

(defvar projdex--failures (make-hash-table :test 'equal)
  "Message of the last failed exit, keyed by project root.")

(defun projdex--root (root)
  "Return the canonical form of ROOT, a directory name."
  (file-name-as-directory (expand-file-name root)))

(defun projdex--current-root ()
  "Return the root of the current project."
  (projdex--root (project-root (project-current t))))

(defun projdex--on-event (rec event)
  "Update the record REC for EVENT, a plist from the service."
  (pcase (car-safe event)
    (:indexed
     (setf (projdex--rec-files rec) (or (plist-get (cdr event) :files) 0)
           (projdex--rec-indexing rec) nil)
     (cl-incf (projdex--rec-epoch rec)))
    (:changed
     (cl-incf (projdex--rec-files rec)
              (- (or (plist-get (cdr event) :added) 0)
                 (or (plist-get (cdr event) :removed) 0)))
     (cl-incf (projdex--rec-epoch rec)))
    (:watch-failed
     (setf (projdex--rec-watching rec) nil)
     (unless (projdex--rec-warned rec)
       (setf (projdex--rec-warned rec) t)
       (display-warning
        'projdex
        (format "File watching for %s failed, the index may become stale: %s"
                (projdex--rec-root rec) (plist-get (cdr event) :message)))))))

(defun projdex--on-exit (rec status err)
  "Forget the record REC after its instance exited with STATUS and ERR."
  (let ((root (projdex--rec-root rec)))
    (when (eq (gethash root projdex--instances) rec)
      (remhash root projdex--instances))
    (when (eq status 'failed)
      (let ((message (or (plist-get err :message) "unknown error")))
        (puthash root message projdex--failures)
        (display-warning
         'projdex (format "Instance for %s failed: %s" root message))))))

(defun projdex--start (root)
  "Start an instance for ROOT and return its record."
  (condition-case err
      (emrs-load-module 'projdex)
    (file-missing
     (user-error "Cannot load the projdex module: install it as projdex-module%s on `load-path' (%s)"
                 module-file-suffix (error-message-string err)))
    (error
     (user-error "Cannot load the projdex module (install it as projdex-module%s on `load-path'): %s"
                 module-file-suffix (error-message-string err))))
  (remhash root projdex--failures)
  (let ((rec (projdex--make-rec :root root :indexing t :watching t)))
    (setf (projdex--rec-instance rec)
          (emrs-start 'projdex "projdex"
                      (list :root root
                            :include-hidden (and projdex-include-hidden t)
                            :ignores projdex-ignores)
                      :on-event (lambda (_inst event) (projdex--on-event rec event))
                      :on-exit (lambda (_inst status err)
                                 (projdex--on-exit rec status err))))
    (puthash root rec projdex--instances)
    rec))

(defun projdex--ensure (root)
  "Return the running record for ROOT, starting an instance if needed."
  (let* ((root (projdex--root root))
         (rec (gethash root projdex--instances)))
    (if (and rec (memq (emrs-instance-state (projdex--rec-instance rec))
                       '(starting running)))
        rec
      (projdex--start root))))

(defun projdex--lookup (root)
  "Return the record for ROOT, or nil when no instance exists."
  (gethash (projdex--root root) projdex--instances))

;;;; Queries

(defun projdex--drop (rec)
  "Remove the record REC from the table if it is still current."
  (when (eq (gethash (projdex--rec-root rec) projdex--instances) rec)
    (remhash (projdex--rec-root rec) projdex--instances)))

(defun projdex--request (text limit positions)
  "Return the query request for TEXT, LIMIT and POSITIONS."
  (list :query :text text :limit limit :positions (and positions t)))

(defun projdex-query (root text limit &optional positions)
  "Query the index of ROOT for TEXT, returning at most LIMIT paths.
Return the reply plist (:paths :positions :total :indexing).  With
POSITIONS, also return the matched character indices.  Signal a
`user-error' when the instance failed or stopped."
  (let ((rec (projdex--ensure root)))
    (condition-case err
        (emrs-call-sync (projdex--rec-instance rec)
                        (projdex--request text limit positions)
                        projdex-query-timeout)
      (emrs-error
       (pcase (cadr err)
         ((or 'failed 'stopped)
          (projdex--drop rec)
          (user-error "projdex: %s"
                      (or (gethash (projdex--rec-root rec) projdex--failures)
                          (nth 2 err))))
         (_ (signal (car err) (cdr err))))))))

(defun projdex-query-async (root text limit positions callback)
  "Query the index of ROOT for TEXT like `projdex-query', asynchronously.
CALLBACK is called as (CALLBACK REPLY ERR); ERR is nil on success and an
error plist otherwise.  Return the call, which `emrs-cancel' cancels."
  (emrs-call (projdex--rec-instance (projdex--ensure root))
             (projdex--request text limit positions)
             callback))

;;;; Commands

(defun projdex--rescan (root)
  "Rescan ROOT asynchronously and report the file count when done."
  (emrs-call (projdex--rec-instance (projdex--ensure root)) '(:rescan)
             (lambda (count err)
               (if err
                   (message "projdex: rescan of %s failed: %s"
                            root (plist-get err :message))
                 (message "projdex: %s has %d files" root count)))))

(defun projdex--stop (root)
  "Stop the instance of ROOT, if any."
  (when-let* ((rec (projdex--lookup root)))
    (emrs-stop (projdex--rec-instance rec))))

(defun projdex--status (root)
  "Return a readable status line for ROOT."
  (let* ((rec (projdex--ensure root))
         (s (emrs-call-sync (projdex--rec-instance rec) '(:status)
                            projdex-query-timeout)))
    (format "projdex: %s: %d files, indexing %s, watching %s, %d walks, %d skipped"
            (plist-get s :root) (plist-get s :files)
            (if (plist-get s :indexing) "yes" "no")
            (if (plist-get s :watching) "yes" "no")
            (plist-get s :walks) (plist-get s :skipped))))

;;;###autoload
(defun projdex-rescan ()
  "Rescan the current project and report the file count when done."
  (interactive)
  (projdex--rescan (projdex--current-root))
  nil)

;;;###autoload
(defun projdex-stop ()
  "Stop the index instance of the current project.
The next command starts a new one, with the current options."
  (interactive)
  (projdex--stop (projdex--current-root)))

;;;###autoload
(defun projdex-stop-all ()
  "Stop all index instances."
  (interactive)
  (maphash (lambda (_root rec) (emrs-stop (projdex--rec-instance rec)))
           projdex--instances))

;;;###autoload
(defun projdex-status ()
  "Show the status of the current project's index in the echo area."
  (interactive)
  (message "%s" (projdex--status (projdex--current-root))))

(provide 'projdex)
;;; projdex.el ends here
