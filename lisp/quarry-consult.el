;;; quarry-consult.el --- consult front end for quarry  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `quarry-consult-find-file' visits a project file chosen from
;; quarry's index in a consult prompt.  Each input goes to the index
;; asynchronously, a superseded query is cancelled, and the candidates
;; update while the first walk of a project still runs.
;; `quarry-consult-find-file-in-directory' does the same for the files
;; below any local directory: from the project's index when the
;; directory is in it, else from a one-shot walk that ends with the
;; prompt.
;;
;; The command needs consult 2.0 or later.  This file loads and
;; byte-compiles without it; the command then signals a `user-error'.
;; Set `quarry-find-file-command' to `quarry-consult-find-file' to
;; make `quarry-mode' run it in place of `project-find-file'.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'project)
(require 'quarry)
(require 'consult nil t)

(declare-function consult--read "consult" (table &rest options))
(declare-function consult--async-pipeline "consult" (&rest async))
(declare-function consult--async-split "consult" (&optional style))
(declare-function consult--async-throttle "consult" (&optional throttle debounce))
(declare-function consult--async-indicator "consult" ())
(declare-function consult--async-refresh "consult" (&optional delay))

;;;; Options

(defcustom quarry-consult-input-debounce 0.05
  "Seconds of no typing before `quarry-consult-find-file' queries.
Passed to `consult--async-throttle' as its debounce delay."
  :type 'number
  :group 'quarry)

(defcustom quarry-consult-input-throttle 0.1
  "Minimum seconds between two queries of `quarry-consult-find-file'.
Passed to `consult--async-throttle' as its throttle delay."
  :type 'number
  :group 'quarry)

(defcustom quarry-consult-refresh-interval 0.25
  "Seconds between re-queries while the instance indexes."
  :type 'number
  :group 'quarry)

(defvar quarry-consult-history nil
  "Minibuffer history of `quarry-consult-find-file'.")

;;;; The async step

(defun quarry-consult--candidates (reply)
  "Return the candidates of REPLY, a `:query' reply.
They are copies of its paths, highlighted with `quarry--highlight'
where positions are present, the same strings `quarry--table' returns."
  (let ((positions (plist-get reply :positions))
        (groups (plist-get reply :groups)))
    (cl-loop for path in (plist-get reply :paths)
             for pos = (pop positions)
             for group = (pop groups)
             collect (if pos
                         (quarry--highlight path pos group)
                       ;; UIs may add properties in place.
                       (copy-sequence path)))))

(defvar quarry-consult-directory-history nil
  "Minibuffer history of `quarry-consult-find-file-in-directory'.")

(defun quarry-consult--async (root &optional dir)
  "Return a consult async step that queries the index of ROOT.
ROOT is a project root or a one-shot record, as `quarry-query-async'
takes; DIR, a directory relative to the root, limits the query to the
paths below it.
See `consult--async-pipeline' for the protocol.  Each new input string
is sent with `quarry-query-async'; the call it supersedes is cancelled.
The reply replaces the candidates.  While the instance indexes, the
current input is sent again every `quarry-consult-refresh-interval'
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
             ;; `quarry--call-sync' reports it.  A one-shot record has
             ;; none: its text is used.
             (format "quarry: %s"
                     (or (and (not (quarry--rec-p root))
                              (gethash (quarry--root root) quarry--failures))
                         text)))
           (fail (text)
             (unless reported
               (setq reported t)
               (message "%s" text))
             (funcall sink 'flush)
             (funcall sink [indicator failed]))
           (receive (reply err)
             (cond
              ((null err)
               (let ((candidates (quarry-consult--candidates reply)))
                 ;; Flush only now, so that the old candidates stay
                 ;; until the new ones arrive.
                 (funcall sink 'flush)
                 (when candidates
                   (funcall sink candidates))
                 (funcall sink [indicator finished])
                 (when (plist-get reply :indexing)
                   (setq timer (run-at-time quarry-consult-refresh-interval nil
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
                     (setq call (apply #'quarry-query-async
                                       root input quarry-limit (and quarry-highlight t)
                                       (lambda (reply err)
                                         (when (= this serial)
                                           (setq call nil)
                                           (receive reply err)))
                                       (and dir (list dir))))
                     (funcall sink [indicator running]))
                 ;; `emrs-call' signals for an instance that is known to
                 ;; have stopped or failed, and `quarry--ensure' may
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

;;;; Commands

(defun quarry-consult--require (command)
  "Signal a `user-error' naming COMMAND unless consult 2.0 or later is here."
  (unless (quarry-consult--available-p)
    (user-error "Install consult 2.0 or later to use %s" command)))

(defun quarry-consult--read (prompt target dir rel history)
  "Read a file path with PROMPT in a consult prompt and return it.
TARGET and REL are as for `quarry-consult--async', which supplies the
candidates; REL limits them to a directory.  `default-directory' is DIR
during the read.  HISTORY is the symbol of the history variable."
  (let ((default-directory dir))
    (consult--read
     (consult--async-pipeline
      (consult--async-split)
      (consult--async-throttle quarry-consult-input-throttle
                               quarry-consult-input-debounce)
      (quarry-consult--async target rel)
      (consult--async-indicator)
      (consult--async-refresh))
     :prompt prompt
     :category 'project-file
     :sort nil
     :require-match t
     :history `(:input ,history)
     ;; The pipeline above is complete; the default wrapper would add
     ;; split, indicator and refresh a second time.
     :async-wrap #'identity)))

(defun quarry-consult--available-p ()
  "Return non-nil when consult 2.0 or later is loaded or can be loaded."
  (or (fboundp 'consult--async-pipeline)
      (and (require 'consult nil t)
           (fboundp 'consult--async-pipeline))))

;;;###autoload
(defun quarry-consult-find-file (&optional include-all)
  "Visit a file of the current project, chosen in a consult prompt.
The candidates come from quarry's index, queried asynchronously as
the input changes; see `consult-async-split-style' for filtering them
further.  With INCLUDE-ALL, or in a remote project, defer to
`project-find-file' with INCLUDE-ALL.  Needs consult 2.0 or later."
  (interactive "P")
  (quarry-consult--require 'quarry-consult-find-file)
  (let* ((project (project-current t))
         (root (quarry--root (project-root project))))
    (if (or include-all (file-remote-p root))
        (project-find-file include-all)
      ;; No wait for a first page: the step re-queries while the
      ;; instance indexes, so the candidates fill in the open prompt.
      (quarry--prepare root t)
      (let ((path (quarry-consult--read
                   (format "Find file in %s: " (project-name project))
                   root root nil 'quarry-consult-history)))
        ;; Not `expand-file-name': a path like "~/x" must stay below ROOT.
        (find-file (concat root path))))))

;;;###autoload
(defun quarry-consult-find-file-in-directory (&optional dir)
  "Visit a file below DIR, chosen in a consult prompt.
DIR is `default-directory' by default; with a prefix argument, ask for
it.  A directory below the root of the current project is answered from
the project's index when that has files below it.  Any other local
directory is walked once for the prompt, without a watcher, and the
walk is stopped when the prompt ends.  The candidates are relative to
DIR.  Needs consult 2.0 or later."
  (interactive
   (progn
     (quarry-consult--require 'quarry-consult-find-file-in-directory)
     (list (if current-prefix-arg
               (read-directory-name "Find file in directory: ")
             default-directory))))
  (quarry-consult--require 'quarry-consult-find-file-in-directory)
  (let* ((dir (quarry--check-directory (or dir default-directory)))
         (target (quarry--dir-target dir t)))
    (let ((path (unwind-protect
                    (quarry-consult--read
                     (format "Find file in %s: " (abbreviate-file-name dir))
                     (car target) dir (cdr target)
                     'quarry-consult-directory-history)
                  (unless (stringp (car target))
                    (emrs-stop (quarry--rec-instance (car target)))))))
      ;; Not `expand-file-name': a path like "~/x" must stay below DIR.
      (find-file (concat dir path)))))

(provide 'quarry-consult)
;;; quarry-consult.el ends here
