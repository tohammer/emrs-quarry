;;; quarry.el --- Fast project file finder backed by a Rust module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; Version: 0.3.0-snapshot
;; Package-Requires: ((emacs "30.1") (emrs "0.2.0"))
;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; quarry keeps a live index of each project's files in a Rust module
;; (built with emrs) and answers fuzzy queries from it, for
;; `project-find-file' and other `completing-read' prompts.
;;
;; This file holds the core: one service instance per project root
;; (started lazily) and one-shot instances for single prompts, event and exit handling, the query entry points and
;; the user commands.  `quarry-find-file-in-directory' answers a
;; directory below a project root from that project's index, and any
;; other local directory from a one-shot instance: one walk without a
;; watcher, stopped when the prompt ends.  The module comes from
;; emrs-install.el (installed per user), or is `quarry-module' plus
;; `module-file-suffix' on `load-path'.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'quarry-core)
(require 'project)
(require 'seq)

(defgroup quarry nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "quarry-")

;;;; Options

(defcustom quarry-limit 200
  "Number of candidates returned per query."
  :type 'natnum)

(defcustom quarry-highlight t
  "Non-nil means matched characters are highlighted in candidates.
Each term of the query gets a face of `quarry-match-faces'."
  :type 'boolean)

(defcustom quarry-match-style 'fuzzy
  "How a plain term of the query matches a path.
`fuzzy': its characters in order, with gaps allowed; a term written
\='term matches as a substring.
`substring': as a contiguous substring; a term written \='term
matches fuzzily, as in fzf's --exact mode.
The prefix ^, suffix $ and negation ! work the same in both."
  :type '(choice (const :tag "Fuzzy" fuzzy)
                 (const :tag "Substring" substring)))

(defface quarry-match-0
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#72a4ff")
    (((class color) (min-colors 88) (background light)) :foreground "#223fbf")
    (t :foreground "blue"))
  "Face for the characters the first term of a query matched.")

(defface quarry-match-1
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#ed92f8")
    (((class color) (min-colors 88) (background light)) :foreground "#8f0075")
    (t :foreground "magenta"))
  "Face for the characters the second term of a query matched.")

(defface quarry-match-2
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#90d800")
    (((class color) (min-colors 88) (background light)) :foreground "#145a00")
    (t :foreground "green"))
  "Face for the characters the third term of a query matched.")

(defface quarry-match-3
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#f0ce43")
    (((class color) (min-colors 88) (background light)) :foreground "#804000")
    (t :foreground "yellow"))
  "Face for the characters the fourth term of a query matched.")

(defcustom quarry-match-faces
  '(quarry-match-0 quarry-match-1 quarry-match-2 quarry-match-3)
  "Faces for matched characters, one per query term, used in turn.
A single face, such as `completions-common-part', highlights all terms
alike."
  :type '(repeat face))

(defcustom quarry-query-timeout 10.0
  "Seconds before a query gives up.
This is a safety net against a stuck instance, not a latency budget."
  :type 'number)

(defcustom quarry-provide-project-files nil
  "Non-nil means `quarry-mode' serves `project-files' from the index."
  :type 'boolean)

(defcustom quarry-files-timeout 10.0
  "Seconds `project-files' waits for the index before falling back."
  :type 'number)

(defcustom quarry-find-file-command 'quarry-find-file
  "Command `quarry-mode' runs in place of `project-find-file'.
`quarry-consult-find-file' needs the consult package."
  :type '(choice (const quarry-find-file)
                 (const quarry-consult-find-file)))

;;;; Instances

(defvar quarry--next-id 0
  "Counter giving each instance record a unique id.")

(cl-defstruct (quarry--rec (:constructor quarry--make-rec) (:copier nil))
  "State of the service instance of one project root.
A record with `one-shot' non-nil belongs to an instance started for a
single prompt (see `quarry--start'); `quarry--instances' never holds
it."
  instance root (files 0) indexing watching (epoch 0) warned one-shot
  (id (cl-incf quarry--next-id)))

(defvar quarry--instances (make-hash-table :test 'equal)
  "Running instance records, keyed by project root.")

(defvar quarry--failures (make-hash-table :test 'equal)
  "Message of the last failed exit, keyed by project root.")

(defun quarry--root (root)
  "Return the canonical form of ROOT, a directory name."
  (file-name-as-directory (expand-file-name root)))

(defun quarry--current-root ()
  "Return the root of the current project."
  (quarry--root (project-root (project-current t))))

(defun quarry--on-event (rec event)
  "Update the record REC for EVENT, a plist from the service."
  (pcase (car-safe event)
    (:indexed
     (setf (quarry--rec-files rec) (or (plist-get (cdr event) :files) 0)
           (quarry--rec-indexing rec) nil)
     (cl-incf (quarry--rec-epoch rec)))
    (:changed
     (cl-incf (quarry--rec-files rec)
              (- (or (plist-get (cdr event) :added) 0)
                 (or (plist-get (cdr event) :removed) 0)))
     (cl-incf (quarry--rec-epoch rec)))
    (:watch-failed
     (setf (quarry--rec-watching rec) nil)
     (unless (quarry--rec-warned rec)
       (setf (quarry--rec-warned rec) t)
       (display-warning
        'quarry
        (format "File watching for %s failed, so quarry rescans before each prompt: %s%s"
                (quarry--rec-root rec) (plist-get (cdr event) :message)
                (if (eq system-type 'gnu/linux)
                    "\nIf the inotify watch limit was reached, raise it, e.g. \
`sudo sysctl fs.inotify.max_user_watches=524288', then run `quarry-stop'."
                  "")))))))

(defun quarry--on-exit (rec status err)
  "Forget the record REC after its instance exited with STATUS and ERR.
A one-shot record is in neither table; its failure only warns, since
the calls on it see no more than that the instance terminated."
  (let ((root (quarry--rec-root rec))
        (message (or (plist-get err :message) "unknown error")))
    (cond
     ((quarry--rec-one-shot rec)
      (when (eq status 'failed)
        (display-warning
         'quarry (format "The walk of %s failed: %s" root message))))
     (t
      (when (eq (gethash root quarry--instances) rec)
        (remhash root quarry--instances))
      (when (eq status 'failed)
        (puthash root message quarry--failures)
        (display-warning
         'quarry (format "Instance for %s failed: %s" root message)))))))

(defun quarry--start (root &optional one-shot)
  "Start an instance for ROOT and return its record.
With ONE-SHOT, start it without a file watcher, for a single prompt:
the record is not put into `quarry--instances' and its failure not
into `quarry--failures', and the caller stops it with `emrs-stop'."
  (quarry--load-module)
  (unless one-shot
    (remhash root quarry--failures))
  (let ((rec (quarry--make-rec :root root :indexing t :watching (not one-shot)
                               :one-shot (and one-shot t))))
    (setf (quarry--rec-instance rec)
          (emrs-start 'quarry "index"
                      (append (list :root root
                                    :include-hidden (and quarry-include-hidden t)
                                    :ignores quarry-ignores)
                              (and one-shot '(:watch nil)))
                      :on-event (lambda (_inst event) (quarry--on-event rec event))
                      :on-exit (lambda (_inst status err)
                                 (quarry--on-exit rec status err))))
    (unless one-shot
      (puthash root rec quarry--instances))
    rec))

(defun quarry--ensure (root)
  "Return the running record for ROOT, starting an instance if needed."
  (let* ((root (quarry--root root))
         (rec (gethash root quarry--instances)))
    (if (and rec (memq (emrs-instance-state (quarry--rec-instance rec))
                       '(starting running)))
        rec
      (quarry--start root))))

(defun quarry--lookup (root)
  "Return the record for ROOT, or nil when no instance exists."
  (gethash (quarry--root root) quarry--instances))

(defun quarry--target-rec (target)
  "Return the record of TARGET, a project root or a one-shot record.
For a root, that is `quarry--ensure', which may start an instance.  A
one-shot record is returned while its instance is starting or running;
otherwise signal a `user-error', since it is never restarted."
  (if (stringp target)
      (quarry--ensure target)
    (if (memq (emrs-instance-state (quarry--rec-instance target))
              '(starting running))
        target
      (user-error "quarry: the walk of %s has ended" (quarry--rec-root target)))))

;;;; Queries

(defun quarry--drop (rec)
  "Remove the record REC from the table if it is still current."
  (when (eq (gethash (quarry--rec-root rec) quarry--instances) rec)
    (remhash (quarry--rec-root rec) quarry--instances)))

(defun quarry--request (text limit positions &optional dir)
  "Return the query request for TEXT, LIMIT and POSITIONS.
The match style is `quarry-match-style'.  With DIR, a directory
relative to the root, the request asks for the paths below it only."
  (append (list :query :text text :limit limit :positions (and positions t)
                :substring (eq quarry-match-style 'substring))
          (and dir (list :dir dir))))

(defun quarry--call-sync (target request)
  "Send REQUEST to the instance of TARGET and return the reply.
TARGET is a project root or a one-shot record.  Signal a `user-error'
when the instance failed or stopped."
  (let ((rec (quarry--target-rec target)))
    (condition-case err
        (emrs-call-sync (quarry--rec-instance rec) request quarry-query-timeout)
      (emrs-error
       (pcase (cadr err)
         ((or 'failed 'stopped)
          (if (quarry--rec-one-shot rec)
              (user-error "quarry: %s" (nth 2 err))
            (quarry--drop rec)
            (user-error "quarry: %s"
                        (or (gethash (quarry--rec-root rec) quarry--failures)
                            (nth 2 err)))))
         (_ (signal (car err) (cdr err))))))))

(defun quarry-query (root text limit &optional positions dir)
  "Query the index of ROOT for TEXT, returning at most LIMIT paths.
Return the reply plist (:paths :positions :groups :total :indexing).
With POSITIONS, also return the matched character indices and, in
:groups, the number of the query term that matched each of them.
With DIR, a directory relative to ROOT, `/'-separated, only the paths
below it are matched, and they are returned relative to it.  Plain
terms match as `quarry-match-style' says.  Signal a `user-error' when
the instance failed or stopped.  ROOT may also be a one-shot record,
as `quarry--call-sync' takes."
  (quarry--call-sync root (quarry--request text limit positions dir)))

(defun quarry-query-async (root text limit positions callback &optional dir)
  "Query the index of ROOT for TEXT like `quarry-query', asynchronously.
DIR is as for `quarry-query'.  CALLBACK is called as (CALLBACK REPLY
ERR); ERR is nil on success and an error plist otherwise.  Return the
call, which `emrs-cancel' cancels.  ROOT may also be a one-shot record,
as `quarry--target-rec' takes."
  (emrs-call (quarry--rec-instance (quarry--target-rec root))
             (quarry--request text limit positions dir)
             callback))

;;;; Completion

(defvar quarry-file-history nil
  "Minibuffer history of `quarry-find-file'.")

(defvar quarry-directory-file-history nil
  "Minibuffer history of `quarry-find-file-in-directory'.")

(defconst quarry--cache-size 4
  "Number of recent query results a completion table keeps.")

(defun quarry--highlight (path positions groups)
  "Return a copy of PATH with match faces at POSITIONS.
GROUPS, parallel to POSITIONS, holds the term number of each position;
term N gets face N of `quarry-match-faces', modulo their number."
  (let ((copy (copy-sequence path))
        (faces (or quarry-match-faces '(completions-common-part))))
    (cl-loop for pos in positions
             for group = (or (pop groups) 0)
             do (add-face-text-property pos (1+ pos)
                                        (nth (mod group (length faces)) faces)
                                        nil copy))
    copy))

(defun quarry--table (target &optional dir)
  "Return a completion table for the files of TARGET.
TARGET is a project root or a one-shot record.  With DIR, a directory
relative to the root, the candidates are the files below it, relative
to it.  The whole input is the query; the candidates keep the order of
the index.  Results are cached per input, instance, epoch, limit,
highlighting and match style; replies of a still indexing instance are
not cached.  When the instance cannot be started or failed, or a
one-shot instance has ended, the table reports it once and has no
candidates from then on."
  (let ((cache nil)
        (warned nil)
        (failed nil))
    (cl-flet ((results (string)
                ;; Return a list of (PATH POSITIONS GROUPS), best first.
                (unless failed
                  (condition-case err
                      (let* ((rec (quarry--target-rec target))
                             (limit quarry-limit)
                             (highlight (and quarry-highlight t))
                             (key (list string (quarry--rec-id rec)
                                        (quarry--rec-epoch rec) limit highlight
                                        quarry-match-style))
                             (hit (assoc key cache)))
                        (if hit
                            (cdr hit)
                          (let* ((reply (quarry-query target string limit highlight
                                                      dir))
                                 (paths (plist-get reply :paths))
                                 (none (make-list (length paths) nil))
                                 (value (cl-mapcar #'list paths
                                                   (or (plist-get reply :positions) none)
                                                   (or (plist-get reply :groups) none))))
                            (unless (plist-get reply :indexing)
                              (setq cache (seq-take (cons (cons key value) cache)
                                                    quarry--cache-size)))
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
                             (message "quarry: query timed out"))
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
           (let ((highlight (and quarry-highlight t)))
             (cl-loop for (path positions groups) in (results string)
                      when (or (null pred) (funcall pred path))
                      collect (if (and highlight positions)
                                  (quarry--highlight path positions groups)
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

(defun quarry-completion-try (string table pred point)
  "Try-completion function of the `quarry' style.
Pass STRING to TABLE with PRED.  A string TABLE completes STRING to is
returned with point at its end; otherwise STRING and POINT are kept."
  (let ((result (funcall table string pred nil)))
    (cond ((not (stringp result)) result)
          ((equal result string) (cons string point))
          (t (cons result (length result))))))

(defun quarry-completion-all (string table pred _point)
  "All-completions function of the `quarry' style.
Return the candidates of TABLE for STRING and PRED as they are, with
base size 0."
  (let ((all (funcall table string pred t)))
    (and all (nconc all 0))))

(add-to-list 'completion-styles-alist
             '(quarry quarry-completion-try quarry-completion-all
                       "Pass the input to the table unchanged and keep its ranking."))

;;;; Commands

(defun quarry--rescan (root)
  "Rescan ROOT asynchronously and report the file count when done."
  (emrs-call (quarry--rec-instance (quarry--ensure root)) '(:rescan)
             (lambda (count err)
               (if err
                   (message "quarry: rescan of %s failed: %s"
                            root (plist-get err :message))
                 (message "quarry: %s has %d files" root count)))))

(defun quarry--stop (root)
  "Stop the instance of ROOT, if any."
  (when-let* ((rec (quarry--lookup root)))
    (emrs-stop (quarry--rec-instance rec))))

(defun quarry--status (root)
  "Return a readable status line for ROOT."
  (let* ((rec (quarry--ensure root))
         (s (emrs-call-sync (quarry--rec-instance rec) '(:status)
                            quarry-query-timeout)))
    (format "quarry: %s: %d files, indexing %s, watching %s, %d walks, %d skipped"
            (plist-get s :root) (plist-get s :files)
            (if (plist-get s :indexing) "yes" "no")
            (if (plist-get s :watching) "yes" "no")
            (plist-get s :walks) (plist-get s :skipped))))

;;;###autoload
(defun quarry-rescan ()
  "Rescan the current project and report the file count when done."
  (interactive)
  (quarry--rescan (quarry--current-root))
  nil)

;;;###autoload
(defun quarry-stop ()
  "Stop the index instance of the current project.
The next command starts a new one, with the current options."
  (interactive)
  (quarry--stop (quarry--current-root)))

;;;###autoload
(defun quarry-stop-all ()
  "Stop all index instances."
  (interactive)
  (maphash (lambda (_root rec) (emrs-stop (quarry--rec-instance rec)))
           quarry--instances))

;;;###autoload
(defun quarry-status ()
  "Show the status of the current project's index in the echo area."
  (interactive)
  (message "%s" (quarry--status (quarry--current-root))))

(defvar quarry--first-page-wait 1.0
  "Seconds `quarry-find-file' waits at most for a first page of files.")

(defun quarry--await-first-page (target)
  "Wait until the index of TARGET can fill the first page of a prompt.
TARGET is a project root or a one-shot record.  That is when no walk
runs or the index holds `quarry-limit' files, or after
`quarry--first-page-wait' seconds.  Completion UIs ask for the empty
input once and do not refresh, so a prompt opened on a new instance
would otherwise stay empty until the user types.  Signal a
`user-error' when the instance failed or stopped."
  (let ((deadline (+ (float-time) quarry--first-page-wait)))
    (while (let ((status (quarry--call-sync target '(:status))))
             (and (plist-get status :indexing)
                  (< (or (plist-get status :files) 0) quarry-limit)
                  (< (float-time) deadline)))
      (sleep-for 0.02))))

(defun quarry--prepare (target &optional no-wait)
  "Make the instance of TARGET ready for a prompt.
TARGET is a project root or a one-shot record.  Ensure the instance,
rescan when it is not watching, and wait for a first page of files.
A one-shot record is not rescanned: it is not watching by design, and
its first walk is the only one.  With NO-WAIT, do not wait: probe the
instance once instead.  That suits a prompt that refreshes its
candidates while the index fills, as `quarry-consult-find-file' does;
the wait is for completion UIs that ask for the empty input once.
Signal a `user-error' when the instance cannot be started or failed,
including the offer to build a missing module.  Callers run this
before their prompt, so that nothing starts an instance from inside
the minibuffer."
  (let ((rec (quarry--target-rec target)))
    (unless (or (quarry--rec-watching rec) (quarry--rec-one-shot rec))
      (emrs-send (quarry--rec-instance rec) '(:rescan))))
  ;; `:status' probes, so that an instance that cannot be started or
  ;; failed is reported here, before the prompt, as a `user-error',
  ;; and a new instance has files to show.  `:status' does not score
  ;; the index, unlike an empty query.
  (if no-wait
      (quarry--call-sync target '(:status))
    (quarry--await-first-page target))
  nil)

(defun quarry--check-directory (dir)
  "Return DIR as an absolute directory name, as `quarry--root' does.
Signal a `user-error' when it is remote or not an existing directory."
  (let ((dir (quarry--root dir)))
    (when (file-remote-p dir)
      (user-error "quarry finds files in local directories only: %s" dir))
    (cond ((file-directory-p dir))
          ((file-exists-p (directory-file-name dir))
           (user-error "Not a directory: %s" (directory-file-name dir)))
          (t (user-error "Directory does not exist: %s" dir)))
    dir))

(defun quarry--dir-target (dir &optional no-wait)
  "Return (TARGET . REL) for finding files below DIR.
DIR is an absolute, local, existing directory name.  When DIR is the
root of the current project, that is (ROOT . nil).  When it is below
the root (compared as true names) and the project index has files below
it, it is (ROOT . REL), REL being DIR relative to the root with a
trailing slash.  Otherwise, also when the index is still walking and
has not reached DIR, it is (REC . nil), REC a one-shot record for DIR.
The target is prepared with `quarry--prepare' and NO-WAIT; a one-shot
instance that cannot be prepared is stopped.  Callers stop a one-shot
target with `emrs-stop' when their prompt ends."
  (let* ((project (project-current nil dir))
         (root (and project (quarry--root (project-root project))))
         (true-dir (and root (not (file-remote-p root))
                        (file-name-as-directory (file-truename dir))))
         (true-root (and true-dir (file-name-as-directory (file-truename root)))))
    (cond
     ((and true-dir (equal true-dir true-root))
      (quarry--prepare root no-wait)
      (cons root nil))
     ((and true-dir
           (string-prefix-p true-root true-dir)
           (let ((rel (substring true-dir (length true-root))))
             (quarry--prepare root no-wait)
             (let ((reply (quarry-query root "" 1 nil rel)))
               (and (> (or (plist-get reply :total) 0) 0)
                    (cons root rel))))))
     (t
      (let ((rec (quarry--start (quarry--root dir) t))
            (ready nil))
        (unwind-protect
            (progn (quarry--prepare rec no-wait)
                   (setq ready t))
          (unless ready
            (emrs-stop (quarry--rec-instance rec))))
        (cons rec nil))))))

(defun quarry--read-file (prompt target dir history)
  "Read a file of TARGET with PROMPT and HISTORY; return its path.
TARGET and DIR are as for `quarry--table'; the path is relative to the
root, or to DIR when given.  Only the `quarry' completion style applies
in the prompt."
  (let* ((completion-category-overrides
          (cons '(project-file (styles quarry)) completion-category-overrides))
         (table (quarry--table target dir))
         (path (minibuffer-with-setup-hook
                   ;; Appended, so it runs after UIs that set styles in
                   ;; their own setup hook (fido-mode sets `flex').
                   (:append
                    (lambda ()
                      ;; The override only puts `quarry' first: Emacs
                      ;; appends `completion-styles', which would run
                      ;; when quarry finds nothing and, since the table
                      ;; ignores `completion-regexp-list', list every
                      ;; file.  Buffer-local, so other minibuffers keep
                      ;; the user's styles.
                      (setq-local completion-styles '(quarry))))
                 (completing-read prompt table nil 'confirm nil history)))
         ;; With `confirm', RET accepts the input as typed.  When it
         ;; is not a file of the index but completes to exactly one,
         ;; visit that one rather than a new file.
         (match (and (not (equal path "")) (funcall table path nil nil))))
    (if (stringp match) match path)))

;;;###autoload
(defun quarry-find-file (&optional include-all)
  "Visit a file of the current project, chosen from quarry's index.
With INCLUDE-ALL, or in a remote project, defer to `project-find-file'
with INCLUDE-ALL."
  (interactive "P")
  (let* ((project (project-current t))
         (root (quarry--root (project-root project))))
    (if (or include-all (file-remote-p root))
        (project-find-file include-all)
      (quarry--prepare root)
      (let ((path (quarry--read-file (format "Find file in %s: " (project-name project))
                                     root nil 'quarry-file-history)))
        ;; Not `expand-file-name': a path like "~/x" must stay below ROOT.
        (find-file (concat root path))))))

;;;###autoload
(defun quarry-find-file-in-directory (&optional dir)
  "Visit a file below DIR, chosen with quarry's matcher and ranking.
DIR is `default-directory' by default; with a prefix argument, ask for
it.  A directory below the root of the current project is answered from
the project's index when that has files below it.  Any other local
directory is walked once for the prompt, without a watcher, and the
walk is stopped when the prompt ends.  The candidates are relative to
DIR."
  (interactive
   (list (and current-prefix-arg
              (read-directory-name "Find file in directory: "))))
  (let* ((dir (quarry--check-directory (or dir default-directory)))
         (target (quarry--dir-target dir))
         (path (unwind-protect
                   (quarry--read-file (format "Find file in %s: "
                                              (abbreviate-file-name dir))
                                      (car target) (cdr target)
                                      'quarry-directory-file-history)
                 (unless (stringp (car target))
                   (emrs-stop (quarry--rec-instance (car target)))))))
    ;; Not `expand-file-name': a path like "~/x" must stay below DIR.
    (find-file (concat dir path))))

;;;; project-files

(defun quarry--files-applicable-p (project dirs)
  "Return the root record when `project-files' of PROJECT in DIRS is served.
That needs `quarry-mode', `quarry-provide-project-files', DIRS nil or
the project root alone, a local root and a starting or running instance."
  (and (bound-and-true-p quarry-mode)
       quarry-provide-project-files
       (let ((root (quarry--root (project-root project))))
         (and (not (file-remote-p root))
              (or (null dirs)
                  (and (null (cdr dirs))
                       (equal (quarry--root (car dirs)) root)))
              (let ((rec (quarry--lookup root)))
                (and rec
                     (memq (emrs-instance-state (quarry--rec-instance rec))
                           '(starting running))
                     rec))))))

(defun quarry--collect-files (rec)
  "Return the absolute file names the index of REC holds, or `fail'.
Wait up to `quarry-files-timeout' seconds for the stream to end."
  (let ((root (quarry--rec-root rec)))
    ;; Signals on failure, on timeout and when the instance stopped or
    ;; stops in the meantime; cancels the call on timeout and on a quit.
    (condition-case nil
        (mapcar (lambda (path) (concat root path))
                (emrs-call-stream-sync (quarry--rec-instance rec) '(:files)
                                       quarry-files-timeout))
      (emrs-error 'fail))))

(cl-defmethod project-files :around (project &optional dirs)
  "Serve the files of PROJECT from the quarry index when enabled.
See `quarry-provide-project-files'.  Fall back to the next method
when the index is not applicable, times out or fails."
  (let* ((rec (quarry--files-applicable-p project dirs))
         (files (and rec (quarry--collect-files rec))))
    (if (or (null rec) (eq files 'fail))
        (cl-call-next-method)
      files)))

;;;; Mode

(defvar-keymap quarry-mode-map
  :doc "Keymap of `quarry-mode'."
  ;; A plain binding, not a filtered menu item: `where-is-internal'
  ;; ignores filters, so the command's key would not be shown.  The
  ;; watcher below keeps it in step with the option.
  "<remap> <project-find-file>" quarry-find-file-command)

(defun quarry--find-file-command-watcher (_symbol newval operation where)
  "Rebind the remap of `quarry-mode-map' to NEWVAL.
A variable watcher of `quarry-find-file-command', so that a plain
`setq' takes effect at once, with or without the mode enabled.
OPERATION `let' and `unlet' rebind too, the latter to the restored
value, so the binding always follows the current value.  Buffer-local
values (WHERE non-nil) are ignored, since the keymap is global, and so
are `makunbound' and `defvaralias'."
  (when (and (memq operation '(set let unlet)) (null where))
    (keymap-set quarry-mode-map "<remap> <project-find-file>" newval)))

(add-variable-watcher 'quarry-find-file-command
                      #'quarry--find-file-command-watcher)

;;;###autoload
(define-minor-mode quarry-mode
  "Use quarry's index for `project-find-file'.
The command run instead is `quarry-find-file-command'."
  :global t
  :keymap quarry-mode-map)

(provide 'quarry)
;;; quarry.el ends here
