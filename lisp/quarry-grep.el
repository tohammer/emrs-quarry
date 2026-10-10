;;; quarry-grep.el --- Interactive grep backed by the quarry module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; Keywords: tools, matching
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; An interactive grep session in the manner of rg.el.  `quarry-grep',
;; `quarry-grep-literal', `quarry-grep-project' and `quarry-grep-dwim'
;; ask for a pattern, a file type and a directory and show the matching
;; lines in a result buffer, from which the search is changed and run
;; again.
;;
;; The search runs in the `grep' service of the quarry module and its
;; results arrive as structured values.  The result buffer is therefore
;; not a `compilation-mode' buffer: `quarry-grep-mode' derives from
;; `special-mode', every line carries text properties that say what it
;; is, and no command reads the buffer's text (docs/decisions/0012).
;;
;; This file needs quarry-core.el and emrs.el, not quarry.el: it works
;; with `quarry-mode' off and never starts an index instance.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'project)
(require 'quarry-core)
(require 'subr-x)

(defgroup quarry-grep nil
  "Interactive grep backed by the quarry module."
  :group 'quarry
  :prefix "quarry-grep-")

;;;; Options

(defcustom quarry-grep-case 'smart
  "Case rule a new search starts with.
`smart' means a line filter ignores case unless its pattern has an
uppercase letter."
  :type '(choice (const :tag "Smart" smart)
                 (const :tag "Sensitive" sensitive)
                 (const :tag "Insensitive" insensitive)))

(defcustom quarry-grep-max-lines 50000
  "Number of matching lines after which a search stops."
  :type 'natnum)

(defcustom quarry-grep-max-columns 500
  "Number of characters after which a matching line is cut.
A line that was cut is shown shortened and cannot be edited."
  :type 'natnum)

(defcustom quarry-grep-buffer-name "*quarry-grep*"
  "Name of the result buffer."
  :type 'string)

;;;; Faces

(defface quarry-grep-match '((t :inherit match))
  "Face for the matches of the primary filter in a result line.")

(defface quarry-grep-file-heading '((t :inherit font-lock-function-name-face))
  "Face for the path in a file heading.")

(defface quarry-grep-line-number '((t :inherit shadow))
  "Face for the line number of a result line.")

(defface quarry-grep-filter-include '((t :inherit success))
  "Face for the sign of an including filter.")

(defface quarry-grep-filter-exclude '((t :inherit error))
  "Face for the sign of an excluding filter.")

(defface quarry-grep-filter-kind '((t :inherit font-lock-keyword-face))
  "Face for the kind of a filter: its target and whether it is a regexp.")

(defface quarry-grep-filter-pattern '((t :inherit font-lock-string-face))
  "Face for the pattern of a filter.")

(defface quarry-grep-filter-disabled '((t :inherit shadow))
  "Face for a filter that is switched off.")

(defface quarry-grep-status '((t :inherit italic))
  "Face for the status line at the end of the result buffer.")

(defface quarry-grep-error '((t :inherit error))
  "Face for the status line of a search that failed.")

(defface quarry-grep-header-value '((t :inherit bold))
  "Face for the values in the header line.")

;;;; The search

;; Searches and filters are values: a command that changes a search
;; builds a new one and never modifies a search or a filter that the
;; buffer or its history holds.  The filter objects of the current
;; search are the values of the `quarry-grep-filter' text property.

(cl-defstruct (quarry-grep--filter (:constructor quarry-grep--make-filter)
                                   (:copier quarry-grep--copy-filter))
  "One filter of a search."
  (target 'line)                        ; `line' or `path'
  exclude                               ; non-nil: drop what matches
  (pattern "")
  regexp                                ; non-nil: a Rust regexp, else literal
  (enabled t))                          ; nil: kept in the list, not sent

(cl-defstruct (quarry-grep--search (:constructor quarry-grep--make-search)
                                   (:copier quarry-grep--copy-search))
  "A search: where, in which files, how, and the ordered filters."
  dir                                   ; absolute directory name, with slash
  files                                 ; nil: all; string: type; list: globs
  (case 'smart)                         ; `smart', `sensitive', `insensitive'
  no-ignore                             ; non-nil: ignore files are not used
  (hidden t)                            ; non-nil: hidden files are searched
  filters)                              ; list of `quarry-grep--filter'

(defun quarry-grep--primary (search)
  "Return the primary filter of SEARCH, or nil.
That is its first enabled include line filter."
  (cl-find-if (lambda (filter)
                (and (quarry-grep--filter-enabled filter)
                     (eq (quarry-grep--filter-target filter) 'line)
                     (not (quarry-grep--filter-exclude filter))))
              (quarry-grep--search-filters search)))

(defun quarry-grep--sent-filters (search)
  "Return the filters of SEARCH that go to the service: the enabled ones."
  (cl-remove-if-not #'quarry-grep--filter-enabled
                    (quarry-grep--search-filters search)))

(defun quarry-grep--request (search)
  "Return the `:search' request for SEARCH.
See the module docs of src/grep/service.rs for the fields."
  (let ((files (quarry-grep--search-files search))
        (no-ignore (quarry-grep--search-no-ignore search)))
    (append
     (list :search
           :dir (quarry-grep--search-dir search)
           :filters
           (mapcar (lambda (filter)
                     (list :target (if (eq (quarry-grep--filter-target filter) 'path)
                                       :path
                                     :line)
                           :exclude (and (quarry-grep--filter-exclude filter) t)
                           :pattern (quarry-grep--filter-pattern filter)
                           :regexp (and (quarry-grep--filter-regexp filter) t)))
                   (quarry-grep--sent-filters search))
           :case (pcase (quarry-grep--search-case search)
                   ('sensitive :sensitive)
                   ('insensitive :insensitive)
                   (_ :smart)))
     (cond ((stringp files) (list :file-type files))
           (files (list :globs files)))
     (list :no-ignore (and no-ignore t)
           :hidden (and (quarry-grep--search-hidden search) t)
           ;; Without ignore files everything is searched except the
           ;; version control directories, so the extra lines go too.
           :ignores (and (not no-ignore) quarry-ignores)
           :max-lines quarry-grep-max-lines
           :max-columns quarry-grep-max-columns))))

;;;; The instance

(defvar quarry-grep--instance nil
  "The instance of the grep service all result buffers share, or nil.")

(defvar quarry-grep--types nil
  "The reply to `(:types)', cached for the Emacs session.
A list of plists (:name NAME :globs GLOBS), sorted by name.")

(defconst quarry-grep--types-timeout 10.0
  "Seconds to wait for the list of file types.")

(defvar-local quarry-grep--dead-instance nil
  "The instance whose exit ended this buffer's search, or nil.")

(defvar-local quarry-grep--error nil
  "Message of the failure that ended this buffer's search, or nil.")

(defun quarry-grep--on-exit (instance status err)
  "Forget INSTANCE after it exited with STATUS and ERR.
A failed exit is reported with a warning and in the status line of the
result buffers whose search it ended: their calls failed before this
ran, with a message that does not say why."
  (when (eq quarry-grep--instance instance)
    (setq quarry-grep--instance nil))
  (when (eq status 'failed)
    (let ((message (or (plist-get err :message) "unknown error")))
      (display-warning 'quarry (format "The grep instance failed: %s" message))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'quarry-grep-mode)
                     (eq quarry-grep--dead-instance instance))
            (setq quarry-grep--error message)
            (quarry-grep--update-status)))))))

(defun quarry-grep--ensure-instance ()
  "Return the running grep instance, starting one if needed.
Signal a `user-error' when the module cannot be loaded."
  (if (and quarry-grep--instance
           (memq (emrs-instance-state quarry-grep--instance) '(starting running)))
      quarry-grep--instance
    (quarry--load-module)
    (setq quarry-grep--instance
          (emrs-start 'quarry "grep" nil :on-exit #'quarry-grep--on-exit))))

(defun quarry-grep--type-list ()
  "Return the file types of the service, asking it on first use."
  (or quarry-grep--types
      (setq quarry-grep--types
            (condition-case err
                (emrs-call-sync (quarry-grep--ensure-instance) '(:types)
                                quarry-grep--types-timeout)
              (emrs-error
               (user-error "quarry-grep: cannot get the file types: %s" (nth 2 err)))))))

;;;; Buffer state

(defvar-local quarry-grep--current nil
  "The search this buffer shows, a `quarry-grep--search', or nil.")

(defvar-local quarry-grep--past nil
  "Earlier searches of this buffer, the most recent first.")

(defvar-local quarry-grep--future nil
  "Searches this buffer went back from, the next one first.")

(defvar quarry-grep--serial-counter 0
  "Number of the search started last, in any buffer.")

(defvar-local quarry-grep--serial nil
  "Number of the search whose items this buffer accepts, or nil.")

(defvar-local quarry-grep--call nil
  "The stream call of the running search, or nil.")

(defvar-local quarry-grep--sent nil
  "The filters sent with the last request, in the order sent.")

(defvar-local quarry-grep--state nil
  "State of the search: `running', `done', `cancelled' or `failed'.")

(defvar-local quarry-grep--lines 0
  "Number of result lines in the buffer.")

(defvar-local quarry-grep--files 0
  "Number of file blocks in the buffer.")

(defvar-local quarry-grep--summary nil
  "The summary item of the finished search, a plist, or nil.")

(defvar-local quarry-grep--error-filter nil
  "The filter the service rejected, or nil.")

(defvar-local quarry-grep--status-marker nil
  "Marker at the start of the status line.  File blocks go before it.")

;;;; Rendering

;; Text properties, the only thing commands read:
;;
;; `quarry-grep-filter'   on a filter line: its `quarry-grep--filter'.
;; `quarry-grep-part'     in a filter line: `sign', `kind', `pattern', `off'.
;; `quarry-grep-file'     on a file block (heading and result lines): the
;;                        path relative to `default-directory'.
;; `quarry-grep-heading'  t on a file heading.
;; `quarry-grep-mtime'    on a file heading: the file's modification time
;;                        at the search, milliseconds since the epoch.
;; `quarry-grep-line'     on a result line: its line number in the file.
;; `quarry-grep-column'   on a result line: the character offset of the
;;                        first primary match in the line, or nil.
;; `quarry-grep-inexact'  t on a result line whose text is not exactly
;;                        the file's line.
;; `quarry-grep-prefix'   t on the line number and the space after it;
;;                        the rest of the line is the line's text.
;; `quarry-grep-status'   t on the status line.
;;
;; The properties of a line cover its newline, so the line at point is
;; identified at the beginning of the line.

(defun quarry-grep--plural (n noun)
  "Return \"N NOUN\", with NOUN in the plural unless N is 1."
  (format "%d %s%s" n noun (if (= n 1) "" "s")))

(defun quarry-grep--files-text (files)
  "Return the file restriction FILES of a search as shown to the user."
  (cond ((null files) "everything")
        ((stringp files) files)
        (t (mapconcat #'identity files " "))))

(defun quarry-grep--filter-kind (filter)
  "Return the kind of FILTER as shown: `line', `line/re', `path', `path/re'."
  (concat (symbol-name (quarry-grep--filter-target filter))
          (if (quarry-grep--filter-regexp filter) "/re" "")))

(defun quarry-grep--insert-filter (filter)
  "Insert the line of FILTER at point."
  (let* ((start (point))
         (off (not (quarry-grep--filter-enabled filter)))
         (exclude (quarry-grep--filter-exclude filter)))
    (insert (propertize (if exclude "-" "+")
                        'quarry-grep-part 'sign
                        'face (cond (off 'quarry-grep-filter-disabled)
                                    (exclude 'quarry-grep-filter-exclude)
                                    (t 'quarry-grep-filter-include)))
            " "
            (propertize (quarry-grep--filter-kind filter)
                        'quarry-grep-part 'kind
                        'face (if off 'quarry-grep-filter-disabled 'quarry-grep-filter-kind))
            (make-string (max 2 (- 9 (length (quarry-grep--filter-kind filter)))) ?\s)
            (propertize (quarry-grep--filter-pattern filter)
                        'quarry-grep-part 'pattern
                        'face (if off 'quarry-grep-filter-disabled 'quarry-grep-filter-pattern)))
    (when off
      (insert "  " (propertize "(off)" 'quarry-grep-part 'off
                                'face 'quarry-grep-filter-disabled)))
    (add-text-properties start (point) '(mouse-face highlight follow-link t))
    (insert "\n")
    (put-text-property start (point) 'quarry-grep-filter filter)))

(defun quarry-grep--insert-file (item)
  "Insert the file block of ITEM at point.
ITEM is the plist of a file item of the service."
  (let* ((path (plist-get item :path))
         (lines (plist-get item :lines))
         (start (point)))
    (insert "File: " path (format " (%d)" (length lines)))
    (put-text-property (+ start 6) (+ start 6 (length path))
                       'face 'quarry-grep-file-heading)
    (add-text-properties start (point) '(mouse-face highlight follow-link t))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'quarry-grep-heading t
                               'quarry-grep-mtime (plist-get item :mtime)))
    (dolist (line lines)
      (let* ((bol (point))
             (spans (plist-get line :spans))
             (prefix (format "%5d " (plist-get line :n)))
             (text-start (+ bol (length prefix))))
        (insert prefix (plist-get line :text))
        (add-text-properties bol (point) '(mouse-face highlight follow-link t))
        (insert "\n")
        (add-text-properties bol (point)
                             (list 'quarry-grep-line (plist-get line :n)
                                   'quarry-grep-column (car (car spans))))
        (when (plist-get line :inexact)
          (put-text-property bol (point) 'quarry-grep-inexact t))
        (add-text-properties bol text-start
                             '(quarry-grep-prefix t face quarry-grep-line-number))
        (dolist (span spans)
          (put-text-property (+ text-start (car span)) (+ text-start (cadr span))
                             'face 'quarry-grep-match))))
    (put-text-property start (point) 'quarry-grep-file path)
    (insert "\n")
    (cl-incf quarry-grep--files)
    (cl-incf quarry-grep--lines (length lines))))

(defun quarry-grep--counts-text ()
  "Return the number of lines and files in the buffer as text."
  (format "%s in %s"
          (quarry-grep--plural quarry-grep--lines "line")
          (quarry-grep--plural quarry-grep--files "file")))

(defun quarry-grep--status-text ()
  "Return the text of the status line for the buffer's state."
  (pcase quarry-grep--state
    ('running "Searching…")
    ('cancelled (format "Search cancelled: %s so far" (quarry-grep--counts-text)))
    ('failed (format "Search failed: %s" (or quarry-grep--error "unknown error")))
    (_
     (let* ((summary quarry-grep--summary)
            (millis (plist-get summary :millis))
            (skipped (or (plist-get summary :skipped) 0)))
       (concat
        (cond ((plist-get summary :truncated)
               (format "Search stopped at %d lines, narrow the search: %s"
                       quarry-grep--lines (quarry-grep--counts-text)))
              ((zerop quarry-grep--lines)
               (format "Search finished: no matches in %s"
                       (quarry-grep--plural (or (plist-get summary :files-searched) 0)
                                            "file")))
              (t (format "Search finished: %s" (quarry-grep--counts-text))))
        (if millis (format ", %d ms" millis) "")
        (if (> skipped 0)
            (format ", %s skipped (could not be read)"
                    (quarry-grep--plural skipped "file"))
          ""))))))

(defun quarry-grep--keeping-positions (function)
  "Call FUNCTION; keep point and each window's point and start in place.
The positions are kept as numbers, so text that FUNCTION inserts before
them does not carry them along and no window scrolls."
  (let ((point (point))
        (windows (mapcar (lambda (window)
                           (list window (window-point window) (window-start window)))
                         (get-buffer-window-list nil nil t))))
    (funcall function)
    (goto-char (min point (point-max)))
    (pcase-dolist (`(,window ,window-point ,start) windows)
      (set-window-point window (min window-point (point-max)))
      (unless (= (window-start window) start)
        (set-window-start window (min start (point-max)) t)))))

(defun quarry-grep--goto (pos)
  "Move point to POS, in the buffer and in the windows that show it."
  (goto-char pos)
  (dolist (window (get-buffer-window-list nil nil t))
    (set-window-point window pos)))

(defun quarry-grep--update-status ()
  "Replace the status line with the one for the buffer's state."
  (when (marker-position quarry-grep--status-marker)
    (quarry-grep--keeping-positions
     (lambda ()
       (let ((inhibit-read-only t))
         (delete-region quarry-grep--status-marker (point-max))
         (goto-char quarry-grep--status-marker)
         (insert (propertize (concat (quarry-grep--status-text) "\n")
                             'quarry-grep-status t
                             'face (if (eq quarry-grep--state 'failed)
                                       'quarry-grep-error
                                     'quarry-grep-status))))))
    (force-mode-line-update)))

(defun quarry-grep--filter-position (filter)
  "Return the start of the line of FILTER, or nil."
  (and filter
       (text-property-any (point-min) (point-max) 'quarry-grep-filter filter)))

(defun quarry-grep--render-start ()
  "Show the filter block and the status line of the current search.
Point stays on the filter line it was on, by position in the list;
otherwise it goes to the start of the buffer."
  (let* ((inhibit-read-only t)
         (old (get-text-property (pos-bol) 'quarry-grep-filter))
         ;; The filter block starts the buffer, one line per filter.
         (index (and old (count-lines (point-min) (pos-bol))))
         (column (- (point) (pos-bol))))
    (remove-overlays (point-min) (point-max) 'quarry-grep-fold t)
    (erase-buffer)
    (dolist (filter (quarry-grep--search-filters quarry-grep--current))
      (quarry-grep--insert-filter filter))
    (insert "\n")
    (set-marker quarry-grep--status-marker (point))
    (insert (propertize "\n" 'quarry-grep-status t))
    (quarry-grep--update-status)
    (let ((line (quarry-grep--filter-position
                 (and index (nth index (quarry-grep--search-filters
                                        quarry-grep--current))))))
      (quarry-grep--goto
       (if line
           (save-excursion
             (goto-char line)
             (min (+ line column) (pos-eol)))
         (point-min))))
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-start window (point-min)))))

;;;; Running a search

(defun quarry-grep--abandon ()
  "Cancel the running search of this buffer without showing it."
  (setq quarry-grep--serial nil)
  (when quarry-grep--call
    (let ((call quarry-grep--call))
      (setq quarry-grep--call nil)
      (emrs-cancel call))))

(defun quarry-grep--finish (status err &optional instance)
  "End the buffer's search with STATUS and the error plist ERR.
STATUS is what `emrs-call-stream' gives its ON-END.  INSTANCE is the
instance that served the search."
  (setq quarry-grep--call nil
        quarry-grep--state (pcase status
                             ('done 'done)
                             ('cancelled 'cancelled)
                             (_ 'failed)))
  (when (eq quarry-grep--state 'failed)
    (setq quarry-grep--error (or (plist-get err :message) "unknown error"))
    (when (memq (plist-get err :kind) '(failed stopped))
      ;; `quarry-grep--on-exit' runs after this and knows the reason.
      (setq quarry-grep--dead-instance instance))
    ;; `:data (:filter INDEX)' counts in the list that was sent.
    (let ((index (plist-get (plist-get err :data) :filter)))
      (setq quarry-grep--error-filter (and (integerp index)
                                           (nth index quarry-grep--sent)))))
  (quarry-grep--update-status)
  (when-let* ((line (quarry-grep--filter-position quarry-grep--error-filter)))
    ;; Nothing was searched, so there are no results to keep point on;
    ;; RET now corrects the pattern.
    (quarry-grep--goto line)))

(defun quarry-grep--on-batch (buffer serial items)
  "Show ITEMS, stream items of search SERIAL, in BUFFER.
Items of a search that BUFFER does not wait for any more are dropped."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eql serial quarry-grep--serial)
        (quarry-grep--keeping-positions
         (lambda ()
           (let ((inhibit-read-only t))
             (goto-char quarry-grep--status-marker)
             (dolist (item items)
               (pcase (car-safe item)
                 (:file (quarry-grep--insert-file (cdr item)))
                 (:summary (setq quarry-grep--summary (cdr item)))))
             (set-marker quarry-grep--status-marker (point)))))
        (force-mode-line-update)))))

(defun quarry-grep--on-end (buffer serial instance status err)
  "End search SERIAL of BUFFER, served by INSTANCE, with STATUS and ERR."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eql serial quarry-grep--serial)
        (quarry-grep--finish status err instance)))))

(defun quarry-grep--run (search &optional keep-history)
  "Make SEARCH the search of the current result buffer and run it.
A running search is cancelled.  Unless KEEP-HISTORY, the search shown
so far becomes a history entry when SEARCH differs from it."
  ;; First, so that a missing module leaves the buffer as it is.
  (let ((instance (quarry-grep--ensure-instance))
        (buffer (current-buffer))
        (serial (cl-incf quarry-grep--serial-counter)))
    (quarry-grep--abandon)
    (unless (or keep-history
                (null quarry-grep--current)
                (equal quarry-grep--current search))
      (push quarry-grep--current quarry-grep--past)
      (setq quarry-grep--future nil))
    (setq quarry-grep--current search
          default-directory (quarry-grep--search-dir search)
          quarry-grep--serial serial
          quarry-grep--sent (quarry-grep--sent-filters search)
          quarry-grep--state 'running
          quarry-grep--lines 0
          quarry-grep--files 0
          quarry-grep--summary nil
          quarry-grep--error nil
          quarry-grep--error-filter nil
          quarry-grep--dead-instance nil)
    (unless quarry-grep--status-marker
      (setq quarry-grep--status-marker (make-marker)))
    ;; As `compilation-start' does: `next-error' now means these results.
    (setq next-error-last-buffer buffer)
    (quarry-grep--render-start)
    (condition-case err
        (setq quarry-grep--call
              (emrs-call-stream
               instance (quarry-grep--request search)
               :on-batch (lambda (items)
                           (quarry-grep--on-batch buffer serial items))
               :on-end (lambda (status err)
                         (quarry-grep--on-end buffer serial instance status err))))
      ;; The instance stopped between the check and the call.
      (emrs-error
       (quarry-grep--finish 'failed (list :kind (nth 1 err) :message (nth 2 err))
                            instance)))))

(defun quarry-grep--current ()
  "Return the search of the current buffer or signal a `user-error'."
  (or (and (derived-mode-p 'quarry-grep-mode) quarry-grep--current)
      (user-error "This buffer has no quarry-grep search")))

(defun quarry-grep--change (function)
  "Run a copy of the current search that FUNCTION has changed.
FUNCTION is called with the copy.  It may set its slots, but must
replace the filter list and the filters instead of modifying them."
  (let ((search (quarry-grep--copy-search (quarry-grep--current))))
    (funcall function search)
    (quarry-grep--run search)))

(defun quarry-grep--replace-filter (old new)
  "Run the current search with the filter OLD replaced by NEW."
  (quarry-grep--change
   (lambda (search)
     (setf (quarry-grep--search-filters search)
           (mapcar (lambda (filter) (if (eq filter old) new filter))
                   (quarry-grep--search-filters search))))))

;;;; Prompts

(defvar quarry-grep-pattern-history nil
  "Minibuffer history of the patterns of quarry-grep.")

(defvar quarry-grep-files-history nil
  "Minibuffer history of the file type prompt of quarry-grep.")

(defun quarry-grep--default-pattern ()
  "Return the active region or the symbol at point, or nil."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (thing-at-point 'symbol t)))

(defun quarry-grep--check-pattern (pattern)
  "Return PATTERN, or signal a `user-error' when it is empty."
  (when (or (null pattern) (equal pattern ""))
    (user-error "The search pattern is empty"))
  pattern)

(defun quarry-grep--read-pattern (regexp)
  "Read the pattern of a new search, a regexp if REGEXP, else a string.
The default is the active region or the symbol at point."
  (let ((default (quarry-grep--default-pattern)))
    (quarry-grep--check-pattern
     (if regexp
         (read-regexp "Regexp search for" default 'quarry-grep-pattern-history)
       (read-string (format-prompt "Literal search for" default)
                    nil 'quarry-grep-pattern-history default)))))

(defun quarry-grep--default-type ()
  "Return the name of the file type of the current buffer's file, or nil.
That is a type with a glob that matches the file's name; of several,
the one named like the major mode, else the first."
  (when-let* ((file (buffer-file-name))
              (name (file-name-nondirectory file)))
    (let* ((case-fold-search nil)
           (matching
            (cl-remove-if-not
             (lambda (type)
               (cl-some (lambda (glob)
                          (string-match-p (wildcard-to-regexp glob) name))
                        (plist-get type :globs)))
             (quarry-grep--type-list)))
           (mode (replace-regexp-in-string "-\\(?:ts-\\)?mode\\'" ""
                                           (symbol-name major-mode))))
      (plist-get (or (cl-find mode matching
                              :key (lambda (type) (plist-get type :name))
                              :test #'equal)
                     (car matching))
                 :name))))

(defun quarry-grep--parse-files (input)
  "Return the file restriction INPUT names.
Nil for `everything' or nothing, a type name, or else the list of the
globs INPUT holds, separated by spaces."
  (let ((input (string-trim input)))
    (cond ((member input '("" "everything")) nil)
          ((cl-some (lambda (type) (equal (plist-get type :name) input))
                    (quarry-grep--type-list))
           input)
          (t (split-string input "[ \t]+" t)))))

(defun quarry-grep--read-files (&optional default)
  "Read a file restriction; see `quarry-grep--parse-files' for the value.
DEFAULT is the text offered as default; without it that is the type of
the current buffer's file, else `everything'."
  (let* ((names (cons "everything"
                      (mapcar (lambda (type) (plist-get type :name))
                              (quarry-grep--type-list))))
         (default (or default (quarry-grep--default-type) "everything")))
    (quarry-grep--parse-files
     (minibuffer-with-setup-hook
         (lambda ()
           ;; Globs are separated by spaces, which complete by default.
           (let ((map (make-sparse-keymap)))
             (set-keymap-parent map (current-local-map))
             (keymap-set map "SPC" #'self-insert-command)
             (use-local-map map)))
       (completing-read (format-prompt "Search in files (a type, or globs)" default)
                        names nil nil nil 'quarry-grep-files-history default)))))

(defun quarry-grep--check-directory (dir)
  "Return DIR as an absolute directory name.
Signal a `user-error' when it is remote or not an existing directory."
  (when (file-remote-p dir)
    (user-error "quarry-grep searches local directories only; use rg.el for %s" dir))
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (cond ((file-directory-p dir))
          ((file-exists-p (directory-file-name dir))
           (user-error "Not a directory: %s" (directory-file-name dir)))
          (t (user-error "Directory does not exist: %s" dir)))
    dir))

(defun quarry-grep--read-directory ()
  "Read the directory to search, `default-directory' by default."
  (quarry-grep--check-directory
   (read-directory-name "Search in directory: ")))

(defun quarry-grep--project-root ()
  "Return the root of the current project, or `default-directory'."
  ;; Checked first: `project-current' would connect to a remote host.
  (quarry-grep--check-directory default-directory)
  (let ((project (project-current)))
    (if project (project-root project) default-directory)))

;;;; Commands that start a search

(defun quarry-grep--start (pattern regexp files dir)
  "Search DIR for PATTERN in FILES and show the result buffer.
PATTERN is a regexp if REGEXP is non-nil, else a literal string.  FILES
is nil for all files, the name of a file type, or a list of globs."
  (quarry-grep--check-pattern pattern)
  (let ((search (quarry-grep--make-search
                 :dir (quarry-grep--check-directory dir)
                 :files files
                 :case quarry-grep-case
                 :hidden (and quarry-include-hidden t)
                 :filters (list (quarry-grep--make-filter
                                 :pattern pattern :regexp (and regexp t))))))
    ;; Before the buffer is made: a missing module is a `user-error'.
    (quarry-grep--ensure-instance)
    (let ((buffer (get-buffer-create quarry-grep-buffer-name)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'quarry-grep-mode)
          (quarry-grep-mode))
        (goto-char (point-min))
        (quarry-grep--run search))
      (pop-to-buffer buffer))))

;;;###autoload
(defun quarry-grep (regexp files dir)
  "Search DIR for lines that match REGEXP, in FILES.
REGEXP is a Rust regexp.  FILES is nil for all files, the name of a
file type, or a list of globs.  The matches are shown in the buffer
`quarry-grep-buffer-name'; see `quarry-grep-mode' for what can be done
there.  Interactively, ask for the three."
  (interactive
   (progn
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern t)
           (quarry-grep--read-files)
           (quarry-grep--read-directory))))
  (quarry-grep--start regexp t files dir))

;;;###autoload
(defun quarry-grep-literal (string files dir)
  "Search DIR for lines that contain STRING, in FILES.
Like `quarry-grep', but STRING is not a regexp."
  (interactive
   (progn
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern nil)
           (quarry-grep--read-files)
           (quarry-grep--read-directory))))
  (quarry-grep--start string nil files dir))

;;;###autoload
(defun quarry-grep-project (regexp files)
  "Search the current project for lines that match REGEXP, in FILES.
Like `quarry-grep' in the project's root, or in `default-directory'
outside a project."
  (interactive
   (progn
     (quarry-grep--project-root)
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern t)
           (quarry-grep--read-files))))
  (quarry-grep--start regexp t files (quarry-grep--project-root)))

;;;###autoload
(defun quarry-grep-dwim ()
  "Search the current project for the symbol at point.
The symbol is searched as a literal string in the files of the current
buffer's type, in the project's root or, outside a project, in
`default-directory'."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t))
        (root (quarry-grep--project-root)))
    (unless symbol
      (user-error "No symbol at point"))
    (quarry-grep--start symbol nil (quarry-grep--default-type) root)))

;;;; Visiting results

(defun quarry-grep--nth-line (from n property)
  "Return the start of the Nth line with PROPERTY after the line of FROM.
A negative N counts backwards; 0 means the line of FROM itself.  Nil
when there is no such line."
  (save-excursion
    (goto-char from)
    (forward-line 0)
    (let ((step (if (< n 0) -1 1))
          (left (abs n)))
      (while (and (> left 0) (zerop (forward-line step)))
        (when (get-text-property (point) property)
          (cl-decf left)))
      (and (zerop left)
           (get-text-property (point) property)
           (point)))))

(defun quarry-grep--visit (bol &optional found)
  "Visit the file of the result or heading line that starts at BOL.
For a result line, go to its line and to the column of its first primary
match.  The file is shown in another window when the result buffer's
window is selected, else in the selected window; its window is selected.
With FOUND, tell `next-error' about the visit."
  (let* ((results (current-buffer))
         (path (get-text-property bol 'quarry-grep-file))
         (line (get-text-property bol 'quarry-grep-line))
         (column (or (get-text-property bol 'quarry-grep-column) 0))
         ;; Not `expand-file-name': a path like "~/x" must stay below
         ;; the search directory.
         (file (concat default-directory path)))
    (unless (file-exists-p file)
      (user-error "File no longer exists: %s" file))
    (let ((buffer (find-file-noselect file)))
      (if (eq (window-buffer) results)
          (pop-to-buffer buffer t)
        (pop-to-buffer-same-window buffer))
      (when line
        ;; The line number is one of the whole file.
        (let ((pos (save-excursion
                     (save-restriction
                       (widen)
                       (goto-char (point-min))
                       (forward-line (1- line))
                       (min (+ (point) column) (pos-eol))))))
          (unless (<= (point-min) pos (point-max))
            (widen))
          (goto-char pos)))
      (when found
        (next-error-found results buffer)))))

(defun quarry-grep--next-error (n &optional reset)
  "Visit the Nth next result, the `next-error-function' of the mode.
With RESET, count from the start of the buffer."
  (let ((pos (quarry-grep--nth-line (if reset (point-min) (point)) n
                                    'quarry-grep-line)))
    (unless pos
      (user-error (if (< n 0) "No previous match" "No more matches")))
    (quarry-grep--unfold-at pos)
    (quarry-grep--goto pos)
    (quarry-grep--visit pos)))

(defun quarry-grep-visit ()
  "Visit the result at point, or edit the filter at point.
On a result line, visit the file at that line, at the column of the
first match of the primary filter.  On a file heading, visit the file.
On a filter line, edit its pattern in the minibuffer."
  (interactive nil quarry-grep-mode)
  (let ((bol (pos-bol)))
    (cond ((get-text-property bol 'quarry-grep-filter)
           (quarry-grep-edit-filter))
          ((get-text-property bol 'quarry-grep-file)
           (quarry-grep--visit bol t))
          (t (user-error "Nothing to visit on this line")))))

(defun quarry-grep-mouse-visit (event)
  "Do what `quarry-grep-visit' does at the position of the click EVENT."
  (interactive "e" quarry-grep-mode)
  (let ((posn (event-end event)))
    (select-window (posn-window posn))
    (goto-char (posn-point posn))
    (quarry-grep-visit)))

(defun quarry-grep-next-match (&optional n)
  "Show the Nth next result in another window without selecting it."
  (interactive "p" quarry-grep-mode)
  ;; `next-error' prefers the buffer it used last.
  (setq next-error-last-buffer (current-buffer))
  (next-error-no-select n))

(defun quarry-grep-previous-match (&optional n)
  "Show the Nth previous result in another window without selecting it."
  (interactive "p" quarry-grep-mode)
  (quarry-grep-next-match (- (or n 1))))

(defun quarry-grep-next-file (&optional n)
  "Move to the Nth next file heading."
  (interactive "p" quarry-grep-mode)
  (let ((pos (quarry-grep--nth-line (point) (or n 1) 'quarry-grep-heading)))
    (unless pos
      (user-error (if (< (or n 1) 0) "No previous file" "No more files")))
    (goto-char pos)))

(defun quarry-grep-previous-file (&optional n)
  "Move to the Nth previous file heading."
  (interactive "p" quarry-grep-mode)
  (quarry-grep-next-file (- (or n 1))))

;;;; Folding

(defun quarry-grep--block-at (pos)
  "Return (START . END) of the file block that holds the line of POS, or nil."
  (let ((bol (save-excursion (goto-char pos) (pos-bol))))
    (when (get-text-property bol 'quarry-grep-file)
      (cons (or (previous-single-property-change (1+ bol) 'quarry-grep-file)
                (point-min))
            (or (next-single-property-change bol 'quarry-grep-file)
                (point-max))))))

(defun quarry-grep--blocks ()
  "Return the file blocks of the buffer as a list of (START . END)."
  (let ((pos (point-min))
        (blocks nil))
    (while (setq pos (text-property-not-all pos (point-max) 'quarry-grep-file nil))
      (let ((end (or (next-single-property-change pos 'quarry-grep-file)
                     (point-max))))
        (push (cons pos end) blocks)
        (setq pos end)))
    (nreverse blocks)))

(defun quarry-grep--fold-overlay (block)
  "Return the overlay that folds BLOCK, or nil when it is not folded."
  (cl-find-if (lambda (overlay) (overlay-get overlay 'quarry-grep-fold))
              (overlays-in (car block) (cdr block))))

(defun quarry-grep--fold (block)
  "Hide the result lines of BLOCK; its heading stays visible."
  (let* ((from (save-excursion (goto-char (car block)) (pos-eol)))
         (to (1- (cdr block)))
         (overlay (make-overlay from to nil t nil)))
    (overlay-put overlay 'quarry-grep-fold t)
    (overlay-put overlay 'invisible 'quarry-grep-fold)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'isearch-open-invisible #'delete-overlay)
    (when (and (> (point) from) (<= (point) to))
      (goto-char (car block)))))

(defun quarry-grep--unfold-at (pos)
  "Show the result lines of the file block at POS."
  (when-let* ((block (quarry-grep--block-at pos))
              (overlay (quarry-grep--fold-overlay block)))
    (delete-overlay overlay)))

(defun quarry-grep-toggle-fold ()
  "Hide or show the result lines of the file block at point."
  (interactive nil quarry-grep-mode)
  (let ((block (quarry-grep--block-at (point))))
    (unless block
      (user-error "No file block at point"))
    (let ((overlay (quarry-grep--fold-overlay block)))
      (if overlay
          (delete-overlay overlay)
        (quarry-grep--fold block)))))

(defun quarry-grep-toggle-fold-all ()
  "Hide the result lines of all file blocks, or show them when all are hidden."
  (interactive nil quarry-grep-mode)
  (let ((blocks (quarry-grep--blocks)))
    (unless blocks
      (user-error "No results to fold"))
    (if (cl-every #'quarry-grep--fold-overlay blocks)
        (remove-overlays (point-min) (point-max) 'quarry-grep-fold t)
      (dolist (block blocks)
        (unless (quarry-grep--fold-overlay block)
          (quarry-grep--fold block))))))

;;;; Commands that change the search

(defun quarry-grep-rerun ()
  "Run the buffer's search again."
  (interactive nil quarry-grep-mode)
  (quarry-grep--run (quarry-grep--current)))

(defun quarry-grep-cancel ()
  "Cancel the running search.  The results that arrived stay."
  (interactive nil quarry-grep-mode)
  (unless quarry-grep--call
    (user-error "No search is running"))
  ;; Its `:on-end' runs at once and shows the cancellation.
  (emrs-cancel quarry-grep--call))

(defun quarry-grep--read-edit (filter regexp)
  "Read a new pattern for FILTER, starting from its pattern.
The prompt says REGEXP or literal.  An empty pattern is a `user-error'."
  (quarry-grep--check-pattern
   (read-string (format "%s %s: "
                        (capitalize (symbol-name (quarry-grep--filter-target filter)))
                        (if regexp "regexp" "literal"))
                (quarry-grep--filter-pattern filter)
                'quarry-grep-pattern-history)))

(defun quarry-grep--filter-at-point ()
  "Return the filter of the line at point or signal a `user-error'."
  (quarry-grep--current)
  (or (get-text-property (pos-bol) 'quarry-grep-filter)
      (user-error "No filter on this line")))

(defun quarry-grep-edit-filter ()
  "Edit the pattern of the filter at point in the minibuffer."
  (interactive nil quarry-grep-mode)
  (let* ((filter (quarry-grep--filter-at-point))
         (new (quarry-grep--copy-filter filter)))
    (setf (quarry-grep--filter-pattern new)
          (quarry-grep--read-edit filter (quarry-grep--filter-regexp filter)))
    (quarry-grep--replace-filter filter new)))

(defun quarry-grep--edit-primary (regexp)
  "Edit the pattern of the primary filter and make it a REGEXP or a literal."
  (let* ((filter (or (quarry-grep--primary (quarry-grep--current))
                     (user-error "The search has no primary filter")))
         (new (quarry-grep--copy-filter filter)))
    (setf (quarry-grep--filter-pattern new) (quarry-grep--read-edit filter regexp)
          (quarry-grep--filter-regexp new) regexp)
    (quarry-grep--replace-filter filter new)))

(defun quarry-grep-change-regexp ()
  "Edit the primary filter as a regexp."
  (interactive nil quarry-grep-mode)
  (quarry-grep--edit-primary t))

(defun quarry-grep-change-literal ()
  "Edit the primary filter as a literal string."
  (interactive nil quarry-grep-mode)
  (quarry-grep--edit-primary nil))

(defun quarry-grep-toggle-regexp ()
  "Switch the filter at point between literal and regexp."
  (interactive nil quarry-grep-mode)
  (let* ((filter (quarry-grep--filter-at-point))
         (new (quarry-grep--copy-filter filter)))
    (setf (quarry-grep--filter-regexp new) (not (quarry-grep--filter-regexp filter)))
    (quarry-grep--replace-filter filter new)))

(defun quarry-grep-change-directory ()
  "Search another directory."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (let ((dir (quarry-grep--read-directory)))
    (quarry-grep--change
     (lambda (search) (setf (quarry-grep--search-dir search) dir)))))

(defun quarry-grep-change-files ()
  "Search other files: a file type, globs, or everything."
  (interactive nil quarry-grep-mode)
  (let ((files (quarry-grep--read-files
                (quarry-grep--files-text
                 (quarry-grep--search-files (quarry-grep--current))))))
    (quarry-grep--change
     (lambda (search) (setf (quarry-grep--search-files search) files)))))

(defun quarry-grep-cycle-case ()
  "Change the case rule: smart, then sensitive, then insensitive."
  (interactive nil quarry-grep-mode)
  (quarry-grep--change
   (lambda (search)
     (setf (quarry-grep--search-case search)
           (pcase (quarry-grep--search-case search)
             ('smart 'sensitive)
             ('sensitive 'insensitive)
             (_ 'smart))))))

(defun quarry-grep-toggle-ignore ()
  "Switch the use of ignore files on or off.
Off, everything is searched except version control directories."
  (interactive nil quarry-grep-mode)
  (quarry-grep--change
   (lambda (search)
     (setf (quarry-grep--search-no-ignore search)
           (not (quarry-grep--search-no-ignore search))))))

(defun quarry-grep-toggle-hidden ()
  "Switch the search of hidden files on or off."
  (interactive nil quarry-grep-mode)
  (quarry-grep--change
   (lambda (search)
     (setf (quarry-grep--search-hidden search)
           (not (quarry-grep--search-hidden search))))))

;;;; History

(defun quarry-grep-history-back ()
  "Run the search that preceded the current one in this buffer."
  (interactive nil quarry-grep-mode)
  (let ((current (quarry-grep--current)))
    (unless quarry-grep--past
      (user-error "No earlier search"))
    (push current quarry-grep--future)
    (quarry-grep--run (pop quarry-grep--past) t)))

(defun quarry-grep-history-forward ()
  "Run the search that `quarry-grep-history-back' went back from."
  (interactive nil quarry-grep-mode)
  (let ((current (quarry-grep--current)))
    (unless quarry-grep--future
      (user-error "No later search"))
    (push current quarry-grep--past)
    (quarry-grep--run (pop quarry-grep--future) t)))

;;;; Header line

(defvar quarry-grep--header-maps nil
  "Alist from a command to the keymap that runs it on a header line click.")

(defun quarry-grep--header-map (command)
  "Return a keymap in which a click on the header line runs COMMAND."
  (or (alist-get command quarry-grep--header-maps)
      (let ((map (make-sparse-keymap))
            (run (lambda (event)
                   (interactive "e")
                   (select-window (posn-window (event-start event)))
                   (call-interactively command))))
        ;; Where `mouse-1-click-follows-link' applies to the header
        ;; line, a click arrives as mouse-2.
        (keymap-set map "<header-line> <mouse-1>" run)
        (keymap-set map "<header-line> <mouse-2>" run)
        (push (cons command map) quarry-grep--header-maps)
        map)))

(defun quarry-grep--header-part (label value &optional command help)
  "Return \"LABEL: VALUE\" for the header line.
With COMMAND, a click on VALUE runs it and HELP is its tooltip."
  (concat label ": "
          (if command
              (propertize value
                          'face 'quarry-grep-header-value
                          'mouse-face 'header-line-highlight
                          'help-echo (concat "mouse-1: " help)
                          'keymap (quarry-grep--header-map command))
            (propertize value 'face 'quarry-grep-header-value))))

(defun quarry-grep--header ()
  "Return the header line of the result buffer."
  (let ((search quarry-grep--current))
    (if (null search)
        ""
      (concat
       " "
       (mapconcat
        #'identity
        (list
         (quarry-grep--header-part
          "files" (quarry-grep--files-text (quarry-grep--search-files search))
          #'quarry-grep-change-files "change the file type (f)")
         (quarry-grep--header-part
          "dir" (abbreviate-file-name (quarry-grep--search-dir search))
          #'quarry-grep-change-directory "change the directory (d)")
         (quarry-grep--header-part
          "case" (symbol-name (quarry-grep--search-case search))
          #'quarry-grep-cycle-case "cycle smart, sensitive, insensitive (c)")
         (quarry-grep--header-part
          "ign" (if (quarry-grep--search-no-ignore search) "off" "on")
          #'quarry-grep-toggle-ignore "switch ignore files on or off (i)")
         (quarry-grep--header-part
          "hidden" (if (quarry-grep--search-hidden search) "on" "off")
          #'quarry-grep-toggle-hidden "switch hidden files on or off (H)")
         (quarry-grep--header-part
          "hits" (format "%d in %s" quarry-grep--lines
                         (quarry-grep--plural quarry-grep--files "file"))))
        "   ")))))

;;;; Mode

(defvar-keymap quarry-grep-mode-map
  :doc "Keymap of `quarry-grep-mode'."
  "RET" #'quarry-grep-visit
  ;; A click with mouse-1 on a line arrives as mouse-2: the lines have
  ;; the `follow-link' property.
  "<mouse-2>" #'quarry-grep-mouse-visit
  "n" #'quarry-grep-next-match
  "p" #'quarry-grep-previous-match
  "}" #'quarry-grep-next-file
  "{" #'quarry-grep-previous-file
  "M-N" #'quarry-grep-next-file
  "M-P" #'quarry-grep-previous-file
  "TAB" #'quarry-grep-toggle-fold
  "<backtab>" #'quarry-grep-toggle-fold-all
  "g" #'quarry-grep-rerun
  "r" #'quarry-grep-change-regexp
  "t" #'quarry-grep-change-literal
  "%" #'quarry-grep-toggle-regexp
  "d" #'quarry-grep-change-directory
  "f" #'quarry-grep-change-files
  "c" #'quarry-grep-cycle-case
  "i" #'quarry-grep-toggle-ignore
  "H" #'quarry-grep-toggle-hidden
  "C-c <" #'quarry-grep-history-back
  "C-c >" #'quarry-grep-history-forward
  "C-c C-k" #'quarry-grep-cancel)

(define-derived-mode quarry-grep-mode special-mode "quarry-grep"
  "Major mode of the result buffer of `quarry-grep'.
The buffer shows the filters of the search, one block per file with the
matching lines, and a status line.  The header line shows the file
type, the directory and the switches; its parts can be clicked.

\\{quarry-grep-mode-map}"
  :interactive nil
  (buffer-disable-undo)
  (setq-local next-error-function #'quarry-grep--next-error)
  (setq-local revert-buffer-function (lambda (&rest _) (quarry-grep-rerun)))
  (setq-local header-line-format '(:eval (quarry-grep--header)))
  (add-to-invisibility-spec '(quarry-grep-fold . t))
  (add-hook 'kill-buffer-hook #'quarry-grep--abandon nil t)
  (add-hook 'change-major-mode-hook #'quarry-grep--abandon nil t))

(provide 'quarry-grep)
;;; quarry-grep.el ends here
