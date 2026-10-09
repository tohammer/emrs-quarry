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
(require 'seq)

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
  "Non-nil means matched characters are highlighted in candidates.
Each term of the query gets a face of `projdex-match-faces'."
  :type 'boolean)

(defcustom projdex-match-style 'fuzzy
  "How a plain term of the query matches a path.
`fuzzy': its characters in order, with gaps allowed; a term written
\='term matches as a substring.
`substring': as a contiguous substring; a term written \='term
matches fuzzily, as in fzf's --exact mode.
The prefix ^, suffix $ and negation ! work the same in both."
  :type '(choice (const :tag "Fuzzy" fuzzy)
                 (const :tag "Substring" substring)))

(defface projdex-match-0
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#72a4ff")
    (((class color) (min-colors 88) (background light)) :foreground "#223fbf")
    (t :foreground "blue"))
  "Face for the characters the first term of a query matched.")

(defface projdex-match-1
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#ed92f8")
    (((class color) (min-colors 88) (background light)) :foreground "#8f0075")
    (t :foreground "magenta"))
  "Face for the characters the second term of a query matched.")

(defface projdex-match-2
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#90d800")
    (((class color) (min-colors 88) (background light)) :foreground "#145a00")
    (t :foreground "green"))
  "Face for the characters the third term of a query matched.")

(defface projdex-match-3
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#f0ce43")
    (((class color) (min-colors 88) (background light)) :foreground "#804000")
    (t :foreground "yellow"))
  "Face for the characters the fourth term of a query matched.")

(defcustom projdex-match-faces
  '(projdex-match-0 projdex-match-1 projdex-match-2 projdex-match-3)
  "Faces for matched characters, one per query term, used in turn.
A single face, such as `completions-common-part', highlights all terms
alike."
  :type '(repeat face))

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

(defvar projdex--next-id 0
  "Counter giving each instance record a unique id.")

(cl-defstruct (projdex--rec (:constructor projdex--make-rec) (:copier nil))
  "State of the service instance of one project root."
  instance root (files 0) indexing watching (epoch 0) warned
  (id (cl-incf projdex--next-id)))

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
        (format "File watching for %s failed, so projdex rescans before each prompt: %s%s"
                (projdex--rec-root rec) (plist-get (cdr event) :message)
                (if (eq system-type 'gnu/linux)
                    "\nIf the inotify watch limit was reached, raise it, e.g. \
`sudo sysctl fs.inotify.max_user_watches=524288', then run `projdex-stop'."
                  "")))))))

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
  "Return the query request for TEXT, LIMIT and POSITIONS.
The match style is `projdex-match-style'."
  (list :query :text text :limit limit :positions (and positions t)
        :substring (eq projdex-match-style 'substring)))

(defun projdex--call-sync (root request)
  "Send REQUEST to the instance of ROOT and return the reply.
Signal a `user-error' when the instance failed or stopped."
  (let ((rec (projdex--ensure root)))
    (condition-case err
        (emrs-call-sync (projdex--rec-instance rec) request projdex-query-timeout)
      (emrs-error
       (pcase (cadr err)
         ((or 'failed 'stopped)
          (projdex--drop rec)
          (user-error "projdex: %s"
                      (or (gethash (projdex--rec-root rec) projdex--failures)
                          (nth 2 err))))
         (_ (signal (car err) (cdr err))))))))

(defun projdex-query (root text limit &optional positions)
  "Query the index of ROOT for TEXT, returning at most LIMIT paths.
Return the reply plist (:paths :positions :groups :total :indexing).
With POSITIONS, also return the matched character indices and, in
:groups, the number of the query term that matched each of them.
Plain terms match as `projdex-match-style' says.  Signal a
`user-error' when the instance failed or stopped."
  (projdex--call-sync root (projdex--request text limit positions)))

(defun projdex-query-async (root text limit positions callback)
  "Query the index of ROOT for TEXT like `projdex-query', asynchronously.
CALLBACK is called as (CALLBACK REPLY ERR); ERR is nil on success and an
error plist otherwise.  Return the call, which `emrs-cancel' cancels."
  (emrs-call (projdex--rec-instance (projdex--ensure root))
             (projdex--request text limit positions)
             callback))

;;;; Completion

(defvar projdex-file-history nil
  "Minibuffer history of `projdex-find-file'.")

(defconst projdex--cache-size 4
  "Number of recent query results a completion table keeps.")

(defun projdex--highlight (path positions groups)
  "Return a copy of PATH with match faces at POSITIONS.
GROUPS, parallel to POSITIONS, holds the term number of each position;
term N gets face N of `projdex-match-faces', modulo their number."
  (let ((copy (copy-sequence path))
        (faces (or projdex-match-faces '(completions-common-part))))
    (cl-loop for pos in positions
             for group = (or (pop groups) 0)
             do (add-face-text-property pos (1+ pos)
                                        (nth (mod group (length faces)) faces)
                                        nil copy))
    copy))

(defun projdex--table (root)
  "Return a completion table for the files of the project at ROOT.
The whole input is the query; the candidates keep the order of the
index.  Results are cached per input, instance, epoch, limit, highlighting
and match style; replies of a still indexing instance are not cached.
When the instance cannot be started or failed, the table reports it once
and has no candidates from then on."
  (let ((cache nil)
        (warned nil)
        (failed nil))
    (cl-flet ((results (string)
                ;; Return a list of (PATH POSITIONS GROUPS), best first.
                (unless failed
                  (condition-case err
                      (let* ((rec (projdex--ensure root))
                             (limit projdex-limit)
                             (highlight (and projdex-highlight t))
                             (key (list string (projdex--rec-id rec)
                                        (projdex--rec-epoch rec) limit highlight
                                        projdex-match-style))
                             (hit (assoc key cache)))
                        (if hit
                            (cdr hit)
                          (let* ((reply (projdex-query root string limit highlight))
                                 (paths (plist-get reply :paths))
                                 (none (make-list (length paths) nil))
                                 (value (cl-mapcar #'list paths
                                                   (or (plist-get reply :positions) none)
                                                   (or (plist-get reply :groups) none))))
                            (unless (plist-get reply :indexing)
                              (setq cache (seq-take (cons (cons key value) cache)
                                                    projdex--cache-size)))
                            value)))
                    (user-error
                     (setq failed t)
                     (message "%s" (cadr err))
                     nil)
                    (emrs-error
                     (if (eq (cadr err) 'timeout)
                         (progn
                           (unless warned
                             (setq warned t)
                             (message "projdex: query timed out"))
                           nil)
                       (signal (car err) (cdr err))))))))
      (lambda (string pred action)
        (pcase action
          ('metadata
           '(metadata (category . project-file)
                      (display-sort-function . identity)
                      (cycle-sort-function . identity)))
          (`(boundaries . ,_) nil)
          ('t
           (let ((highlight (and projdex-highlight t)))
             (cl-loop for (path positions groups) in (results string)
                      when (or (null pred) (funcall pred path))
                      collect (if (and highlight positions)
                                  (projdex--highlight path positions groups)
                                ;; UIs may add properties in place.
                                (copy-sequence path)))))
          (_
           (let ((paths (cl-loop for (path . _) in (results string)
                                 when (or (null pred) (funcall pred path))
                                 collect path)))
             (if (eq action 'lambda)
                 (and (member string paths) t)
               (cond ((null paths) nil)
                     ((cdr paths) string)
                     ((equal string (car paths)) t)
                     ;; Exactly one match: complete to it.
                     (t (car paths)))))))))))

(defun projdex-completion-try (string table pred point)
  "Try-completion function of the `projdex' style.
Pass STRING to TABLE with PRED.  A string TABLE completes STRING to is
returned with point at its end; otherwise STRING and POINT are kept."
  (let ((result (funcall table string pred nil)))
    (cond ((not (stringp result)) result)
          ((equal result string) (cons string point))
          (t (cons result (length result))))))

(defun projdex-completion-all (string table pred _point)
  "All-completions function of the `projdex' style.
Return the candidates of TABLE for STRING and PRED as they are, with
base size 0."
  (let ((all (funcall table string pred t)))
    (and all (nconc all 0))))

(add-to-list 'completion-styles-alist
             '(projdex projdex-completion-try projdex-completion-all
                       "Pass the input to the table unchanged and keep its ranking."))

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

;;;###autoload
(defun projdex-find-file (&optional include-all)
  "Visit a file of the current project, chosen from projdex's index.
With INCLUDE-ALL, or in a remote project, defer to `project-find-file'
with INCLUDE-ALL."
  (interactive "P")
  (let* ((project (project-current t))
         (root (projdex--root (project-root project))))
    (if (or include-all (file-remote-p root))
        (project-find-file include-all)
      (let ((rec (projdex--ensure root)))
        (unless (projdex--rec-watching rec)
          (emrs-send (projdex--rec-instance rec) '(:rescan))))
      ;; A cheap probe, so that an instance that cannot be started or
      ;; failed is reported here, before the prompt, as a `user-error'.
      ;; `:status' does not score the index, unlike an empty query.
      (projdex--call-sync root '(:status))
      (let* ((completion-category-overrides
              (cons '(project-file (styles projdex)) completion-category-overrides))
             (table (projdex--table root))
             (path (minibuffer-with-setup-hook
                       ;; Appended, so it runs after UIs that set styles in
                       ;; their own setup hook (fido-mode sets `flex').
                       (:append
                        (lambda ()
                         ;; The override only puts `projdex' first: Emacs
                         ;; appends `completion-styles', which would run
                         ;; when projdex finds nothing and, since the table
                         ;; ignores `completion-regexp-list', list every
                         ;; file.  Buffer-local, so other minibuffers keep
                         ;; the user's styles.
                         (setq-local completion-styles '(projdex))))
                     (completing-read (format "Find file in %s: " (project-name project))
                                      table nil 'confirm nil
                                      'projdex-file-history)))
             ;; With `confirm', RET accepts the input as typed.  When it
             ;; is not a file of the index but completes to exactly one,
             ;; visit that one rather than a new file.
             (match (and (not (equal path "")) (funcall table path nil nil))))
        ;; Not `expand-file-name': a path like "~/x" must stay below ROOT.
        (find-file (concat root (if (stringp match) match path)))))))

;;;; project-files

(defun projdex--files-applicable-p (project dirs)
  "Return the root record when `project-files' of PROJECT in DIRS is served.
That needs `projdex-mode', `projdex-provide-project-files', DIRS nil or
the project root alone, a local root and a starting or running instance."
  (and (bound-and-true-p projdex-mode)
       projdex-provide-project-files
       (let ((root (projdex--root (project-root project))))
         (and (not (file-remote-p root))
              (or (null dirs)
                  (and (null (cdr dirs))
                       (equal (projdex--root (car dirs)) root)))
              (let ((rec (projdex--lookup root)))
                (and rec
                     (memq (emrs-instance-state (projdex--rec-instance rec))
                           '(starting running))
                     rec))))))

(defun projdex--collect-files (rec)
  "Return the absolute file names the index of REC holds, or `fail'.
Wait up to `projdex-files-timeout' seconds for the stream to end."
  (let* ((root (projdex--rec-root rec))
         (batches nil)
         (end nil)
         (call nil))
    (unwind-protect
        (condition-case nil
            (progn
              (setq call (emrs-call-stream
                          (projdex--rec-instance rec) '(:files)
                          :on-batch (lambda (items) (push items batches))
                          :on-end (lambda (status _err) (setq end status))))
              (let ((deadline (+ (float-time) projdex-files-timeout)))
                (while (and (not end) (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (if (eq end 'done)
                  (let ((files nil))
                    ;; BATCHES is newest first; keep the order of the index.
                    (dolist (batch batches)
                      (dolist (path (nreverse (copy-sequence batch)))
                        (push (concat root path) files)))
                    files)
                'fail))
          ;; The instance stopped or failed in the meantime.
          (emrs-error 'fail))
      ;; Cancels on timeout and on a quit; does nothing for a call that
      ;; has already ended.
      (when (and call (not end)) (emrs-cancel call)))))

(cl-defmethod project-files :around (project &optional dirs)
  "Serve the files of PROJECT from the projdex index when enabled.
See `projdex-provide-project-files'.  Fall back to the next method
when the index is not applicable, times out or fails."
  (let* ((rec (projdex--files-applicable-p project dirs))
         (files (and rec (projdex--collect-files rec))))
    (if (or (null rec) (eq files 'fail))
        (cl-call-next-method)
      files)))

;;;; Mode

(defvar-keymap projdex-mode-map
  :doc "Keymap of `projdex-mode'."
  "<remap> <project-find-file>" #'projdex-find-file)

;;;###autoload
(define-minor-mode projdex-mode
  "Use projdex's index for `project-find-file'."
  :global t
  :keymap projdex-mode-map)

(provide 'projdex)
;;; projdex.el ends here
