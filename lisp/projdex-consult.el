;;; projdex-consult.el --- consult front end for projdex  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The projdex authors

;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `projdex-consult-find-file' visits a project file chosen from
;; projdex's index in a consult prompt.  Each input goes to the index
;; asynchronously, a superseded query is cancelled, and the candidates
;; update while the first walk of a project still runs.
;;
;; The command needs consult 2.0 or later.  This file loads and
;; byte-compiles without it; the command then signals a `user-error'.
;; Set `projdex-find-file-command' to `projdex-consult-find-file' to
;; make `projdex-mode' run it in place of `project-find-file'.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'project)
(require 'projdex)
(require 'consult nil t)

(declare-function consult--read "consult" (table &rest options))
(declare-function consult--async-pipeline "consult" (&rest async))
(declare-function consult--async-split "consult" (&optional style))
(declare-function consult--async-throttle "consult" (&optional throttle debounce))
(declare-function consult--async-indicator "consult" ())
(declare-function consult--async-refresh "consult" (&optional delay))

;;;; Options

(defcustom projdex-consult-input-debounce 0.05
  "Seconds of no typing before `projdex-consult-find-file' queries.
Passed to `consult--async-throttle' as its debounce delay."
  :type 'number
  :group 'projdex)

(defcustom projdex-consult-input-throttle 0.1
  "Minimum seconds between two queries of `projdex-consult-find-file'.
Passed to `consult--async-throttle' as its throttle delay."
  :type 'number
  :group 'projdex)

(defcustom projdex-consult-refresh-interval 0.25
  "Seconds between re-queries while the instance indexes."
  :type 'number
  :group 'projdex)

(defvar projdex-consult-history nil
  "Minibuffer history of `projdex-consult-find-file'.")

;;;; The async step

(defun projdex-consult--candidates (reply)
  "Return the candidates of REPLY, a `:query' reply.
They are copies of its paths, highlighted with `projdex--highlight'
where positions are present, the same strings `projdex--table' returns."
  (let ((positions (plist-get reply :positions))
        (groups (plist-get reply :groups)))
    (cl-loop for path in (plist-get reply :paths)
             for pos = (pop positions)
             for group = (pop groups)
             collect (if pos
                         (projdex--highlight path pos group)
                       ;; UIs may add properties in place.
                       (copy-sequence path)))))

(defun projdex-consult--async (root)
  "Return a consult async step that queries the index of ROOT.
See `consult--async-pipeline' for the protocol.  Each new input string
is sent with `projdex-query-async'; the call it supersedes is cancelled.
The reply replaces the candidates.  While the instance indexes, the
current input is sent again every `projdex-consult-refresh-interval'
seconds.  The first error is reported with `message'."
  (lambda (sink)
    (let ((input nil)                   ; current input, nil when none
          (call nil)                    ; pending call
          (serial 0)                    ; number of the pending call
          (timer nil)                   ; re-query timer
          (reported nil))               ; non-nil once an error was shown
      (cl-labels
          ((stop ()
             ;; Cancel the re-query and the pending call.  The call's
             ;; callback runs at once, with a stale serial.
             (cl-incf serial)
             (when timer
               (cancel-timer timer)
               (setq timer nil))
             (when call
               (let ((pending call))
                 (setq call nil)
                 (emrs-cancel pending))))
           (failure (text)
             ;; The message of the instance's failed exit, if known, as
             ;; `projdex--call-sync' reports it.
             (format "projdex: %s"
                     (or (gethash (projdex--root root) projdex--failures) text)))
           (fail (text)
             (unless reported
               (setq reported t)
               (message "%s" text))
             (funcall sink 'flush)
             (funcall sink [indicator failed]))
           (receive (reply err)
             (cond
              ((null err)
               (let ((candidates (projdex-consult--candidates reply)))
                 ;; Flush only now, so that the old candidates stay
                 ;; until the new ones arrive.
                 (funcall sink 'flush)
                 (when candidates
                   (funcall sink candidates))
                 (funcall sink [indicator finished])
                 (when (plist-get reply :indexing)
                   (setq timer (run-at-time projdex-consult-refresh-interval nil
                                            (lambda ()
                                              (setq timer nil)
                                              (query)))))))
              ((eq (plist-get err :kind) 'cancelled))
              (t
               (fail (failure (plist-get err :message))))))
           (query ()
             (stop)
             (let ((this serial))
               (condition-case err
                   (progn
                     (setq call (projdex-query-async
                                 root input projdex-limit (and projdex-highlight t)
                                 (lambda (reply err)
                                   (when (= this serial)
                                     (setq call nil)
                                     (receive reply err)))))
                     (funcall sink [indicator running]))
                 ;; `emrs-call' signals for an instance that is known to
                 ;; have stopped or failed, and `projdex--ensure' may
                 ;; start an instance, which can signal a `user-error'.
                 (emrs-error (fail (failure (nth 2 err))))
                 (error (fail (error-message-string err)))))))
        (lambda (action)
          (pcase action
            ((pred stringp)
             (unless (equal action input)
               (setq input (substring-no-properties action))
               (query))
             nil)
            ((or 'cancel 'destroy)
             (stop)
             ;; The same input must query again: its call may have been
             ;; cancelled before it answered.
             (setq input nil)
             (funcall sink action))
            (_ (funcall sink action))))))))

;;;; Command

(defun projdex-consult--available-p ()
  "Return non-nil when consult 2.0 or later is loaded or can be loaded."
  (or (fboundp 'consult--async-pipeline)
      (and (require 'consult nil t)
           (fboundp 'consult--async-pipeline))))

;;;###autoload
(defun projdex-consult-find-file (&optional include-all)
  "Visit a file of the current project, chosen in a consult prompt.
The candidates come from projdex's index, queried asynchronously as
the input changes; see `consult-async-split-style' for filtering them
further.  With INCLUDE-ALL, or in a remote project, defer to
`project-find-file' with INCLUDE-ALL.  Needs consult 2.0 or later."
  (interactive "P")
  (unless (projdex-consult--available-p)
    (user-error "Install consult 2.0 or later to use projdex-consult-find-file"))
  (let* ((project (project-current t))
         (root (projdex--root (project-root project))))
    (if (or include-all (file-remote-p root))
        (project-find-file include-all)
      ;; No wait for a first page: the step re-queries while the
      ;; instance indexes, so the candidates fill in the open prompt.
      (projdex--prepare root t)
      (let ((path (let ((default-directory root))
                    (consult--read
                     (consult--async-pipeline
                      (consult--async-split)
                      (consult--async-throttle projdex-consult-input-throttle
                                               projdex-consult-input-debounce)
                      (projdex-consult--async root)
                      (consult--async-indicator)
                      (consult--async-refresh))
                     :prompt (format "Find file in %s: " (project-name project))
                     :category 'project-file
                     :sort nil
                     :require-match t
                     :history '(:input projdex-consult-history)
                     ;; The pipeline above is complete; the default
                     ;; wrapper would add split, indicator and refresh
                     ;; a second time.
                     :async-wrap #'identity))))
        ;; Not `expand-file-name': a path like "~/x" must stay below ROOT.
        (find-file (concat root path))))))

(provide 'projdex-consult)
;;; projdex-consult.el ends here
