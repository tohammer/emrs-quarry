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
;; ask for a pattern, file types and globs and a directory and show the
;; matching lines in a result buffer, from which the search is changed and
;; run again.
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

(defconst quarry-grep-max-context 1000
  "The largest count of context lines per side.
The service enforces the same limit.  The searcher keeps the lines
before a possible hit of every file it reads, so a huge count would
hold whole files in memory, for each file searched at the same time.
A larger count is reduced to this one.")

(defcustom quarry-grep-context-before 0
  "Number of lines shown before each hit that a new search starts with.
At most `quarry-grep-max-context'; a larger number is reduced to that.
The commands of the result buffer keep the counts of the search they
change; see `quarry-grep-set-context'."
  :type 'natnum)

(defcustom quarry-grep-context-after 0
  "Number of lines shown after each hit that a new search starts with.
At most `quarry-grep-max-context'; a larger number is reduced to that.
The commands of the result buffer keep the counts of the search they
change; see `quarry-grep-set-context'."
  :type 'natnum)

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

(defcustom quarry-grep-highlight-include-filters t
  "Non-nil means the matches of all include line filters are highlighted.
The matches of the primary filter always have the face
`quarry-grep-match'; with this option those of the other include line
filters get `quarry-grep-match-secondary'.  Applies to the next search."
  :type 'boolean)

(defcustom quarry-grep-highlight-path-filters t
  "Non-nil means file headings show what the include path filters matched.
The matched parts of the path get the face `quarry-grep-path-match'.
Applies to the next search."
  :type 'boolean)

;;;; Faces

(defface quarry-grep-match '((t :inherit match))
  "Face for the matches of the primary filter in a result line.
The pattern of the primary filter has it in the filter block too.")

(defface quarry-grep-match-secondary '((t :inherit lazy-highlight))
  "Face for the matches of the other include line filters in a result line.
See `quarry-grep-highlight-include-filters'.")

(defface quarry-grep-path-match '((t :inherit highlight))
  "Face for the parts of a file heading that include path filters matched.
See `quarry-grep-highlight-path-filters'.")

(defface quarry-grep-file-heading '((t :inherit font-lock-function-name-face))
  "Face for the path in a file heading.")

(defface quarry-grep-line-number '((t :inherit shadow))
  "Face for the line number of a result line.")

(defface quarry-grep-context '((t :inherit shadow))
  "Face for a context line in a result block and for the gap line.
A context line is a line before or after a hit, shown for its sake.")

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
  types                                 ; file type names, nil for all files
  globs                                 ; list of path globs, nil for none
  (case 'smart)                         ; `smart', `sensitive', `insensitive'
  no-ignore                             ; non-nil: ignore files are not used
  (hidden t)                            ; non-nil: hidden files are searched
  (before 0)                            ; lines of context before each hit
  (after 0)                             ; lines of context after each hit
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
  (let ((types (quarry-grep--search-types search))
        (globs (quarry-grep--search-globs search))
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
     (and types (list :file-types types))
     (and globs (list :globs globs))
     (list :no-ignore (and no-ignore t)
           :hidden (and (quarry-grep--search-hidden search) t)
           ;; Without ignore files everything is searched except the
           ;; version control directories, so the extra lines go too.
           :ignores (and (not no-ignore) quarry-ignores)
           :max-lines quarry-grep-max-lines
           :max-columns quarry-grep-max-columns
           :before (quarry-grep--search-before search)
           :after (quarry-grep--search-after search)))))

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

(defvar quarry-grep--service "grep"
  "Name of the service of the quarry module that searches.")

(defun quarry-grep--ensure-instance ()
  "Return the running grep instance, starting one if needed.
Signal a `user-error' when the module cannot be loaded, or when the
module that is loaded has no grep service."
  (if (and quarry-grep--instance
           (memq (emrs-instance-state quarry-grep--instance) '(starting running)))
      quarry-grep--instance
    (quarry--load-module)
    (setq quarry-grep--instance
          (condition-case err
              (emrs-start 'quarry quarry-grep--service nil
                          :on-exit #'quarry-grep--on-exit)
            ;; Emacs cannot unload a module, so new Lisp can meet a
            ;; module from before the grep service existed.
            (emrs-error
             (user-error "The loaded quarry module is older than quarry-grep (%s); rebuild it with M-x quarry-build-module and restart Emacs"
                         (nth 2 err)))))))

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

(defvar-local quarry-grep--return nil
  "Where point is to go when the running search brings it back, or nil.
A list (PATH LINE START): the file and the line number (nil for the
heading) point was on when the search started, and where point was put
then.  Point is only moved where it is still at START: in the buffer,
and in each window that shows it.")

(defvar-local quarry-grep--return-block nil
  "Start of the file block `quarry-grep--return' waits for, once inserted.")

(defvar-local quarry-grep--editing nil
  "Non-nil while the buffer is in wgrep's edit mode, as far as known.
See `quarry-grep--edit-sync'.")

(defvar-local quarry-grep--edited nil
  "Non-nil when edits were committed from this buffer since the search.")

(defvar-local quarry-grep--edit-properties nil
  "The per-file text properties put on for wgrep, to be removed again.")

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
;; `quarry-grep-line'     on a result line, a hit or a context line: its
;;                        line number in the file.
;; `quarry-grep-context'  t on a context line.
;; `quarry-grep-gap'      t on a gap line, which stands between two
;;                        context blocks of a file whose lines are not
;;                        adjacent.  It has `quarry-grep-file' and
;;                        no `quarry-grep-line'.
;; `quarry-grep-column'   on a result line: the character offset of the
;;                        first primary match in the line, or nil (always
;;                        nil on a context line).
;; `quarry-grep-inexact'  t on a result line whose text is not exactly
;;                        the file's line.
;; `quarry-grep-prefix'   t on the line number and the space after it;
;;                        the rest of the line is the line's text.
;; `quarry-grep-separator' t on the empty line that ends a file block.
;; `quarry-grep-status'   t on the status line.
;;
;; The properties of a line cover its newline, so the line at point is
;; identified at the beginning of the line.

(defun quarry-grep--plural (n noun)
  "Return \"N NOUN\", with NOUN in the plural unless N is 1."
  (format "%d %s%s" n noun (if (= n 1) "" "s")))

(defun quarry-grep--files-text (types globs)
  "Return the file restriction of a search as the user would type it.
TYPES is the list of file type names, GLOBS the list of globs.  That is
\"everything\" for none, else the types followed by the globs, separated
by spaces."
  (if (or types globs)
      (mapconcat #'identity (append types globs) " ")
    "everything"))

(defun quarry-grep--search-files-text (search)
  "Return the file restriction of SEARCH as `quarry-grep--files-text' shows it."
  (quarry-grep--files-text (quarry-grep--search-types search)
                           (quarry-grep--search-globs search)))

(defun quarry-grep--filter-kind (filter)
  "Return the kind of FILTER as shown: `line', `line/re', `path', `path/re'."
  (concat (symbol-name (quarry-grep--filter-target filter))
          (if (quarry-grep--filter-regexp filter) "/re" "")))

(defun quarry-grep--filter-roles (search)
  "Return an alist from the filters of SEARCH to the face of their matches.
It holds the primary filter and, as the highlight options say, the other
enabled include filters."
  (let ((primary (quarry-grep--primary search)))
    (delq nil
          (mapcar
           (lambda (filter)
             (cond ((eq filter primary) (cons filter 'quarry-grep-match))
                   ((or (not (quarry-grep--filter-enabled filter))
                        (quarry-grep--filter-exclude filter))
                    nil)
                   ((eq (quarry-grep--filter-target filter) 'line)
                    (and quarry-grep-highlight-include-filters
                         (cons filter 'quarry-grep-match-secondary)))
                   (t (and quarry-grep-highlight-path-filters
                           (cons filter 'quarry-grep-path-match)))))
           (quarry-grep--search-filters search)))))

(defun quarry-grep--insert-filter (filter &optional match-face)
  "Insert the line of FILTER at point.
MATCH-FACE, if non-nil, is the face its matches have in the results; the
pattern is shown in it, so that the colours can be told apart."
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
                        'face (cond (off 'quarry-grep-filter-disabled)
                                    (match-face)
                                    (t 'quarry-grep-filter-pattern))))
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
         ;; Context lines are not counted.
         (hits (cl-count-if-not (lambda (line) (plist-get line :context))
                                lines))
         (gaps (or (> (quarry-grep--search-before quarry-grep--current) 0)
                   (> (quarry-grep--search-after quarry-grep--current) 0)))
         (previous nil)
         (start (point)))
    (insert "File: " path (format " (%d)" hits))
    (put-text-property (+ start 6) (+ start 6 (length path))
                       'face 'quarry-grep-file-heading)
    (when quarry-grep-highlight-path-filters
      (dolist (span (plist-get item :path-spans))
        (add-face-text-property (+ start 6 (car span)) (+ start 6 (cadr span))
                                'quarry-grep-path-match)))
    (when (and quarry-grep--return (equal path (car quarry-grep--return)))
      (setq quarry-grep--return-block start))
    (add-text-properties start (point) '(mouse-face highlight follow-link t))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'quarry-grep-heading t
                               'quarry-grep-mtime (plist-get item :mtime)))
    (dolist (line lines)
      (let* ((bol (point))
             (spans (plist-get line :spans))
             (context (plist-get line :context))
             (prefix (format "%5d " (plist-get line :n)))
             (text-start (+ bol (length prefix))))
        (when (and gaps previous (> (plist-get line :n) (1+ previous)))
          (insert (propertize "    ⋮\n" 'face 'quarry-grep-context
                              'quarry-grep-gap t))
          (setq bol (point)
                text-start (+ bol (length prefix))))
        (setq previous (plist-get line :n))
        (insert prefix (plist-get line :text))
        (add-text-properties bol (point) '(mouse-face highlight follow-link t))
        (when context
          (put-text-property text-start (point) 'face 'quarry-grep-context))
        (insert "\n")
        (add-text-properties bol (point)
                             (list 'quarry-grep-line (plist-get line :n)
                                   'quarry-grep-column (car (car spans))))
        (when context
          (put-text-property bol (point) 'quarry-grep-context t))
        (when (plist-get line :inexact)
          (put-text-property bol (point) 'quarry-grep-inexact t))
        (add-text-properties bol text-start
                             '(quarry-grep-prefix t face quarry-grep-line-number))
        (dolist (span spans)
          (put-text-property (+ text-start (car span)) (+ text-start (cadr span))
                             'face 'quarry-grep-match))
        (when quarry-grep-highlight-include-filters
          (dolist (span (plist-get line :secondary))
            (put-text-property (+ text-start (car span)) (+ text-start (cadr span))
                               'face 'quarry-grep-match-secondary)))))
    (put-text-property start (point) 'quarry-grep-file path)
    (insert (propertize "\n" 'quarry-grep-separator t))
    (cl-incf quarry-grep--files)
    (cl-incf quarry-grep--lines hits)))

(defun quarry-grep--counts-text ()
  "Return the number of lines and files in the buffer as text."
  (format "%s in %s"
          (quarry-grep--plural quarry-grep--lines "line")
          (quarry-grep--plural quarry-grep--files "file")))

(defun quarry-grep--status-text ()
  "Return the text of the status line for the buffer's state."
  (concat (quarry-grep--search-status-text)
          (if quarry-grep--edited
              "\nThe results were edited; g searches again"
            "")))

(defun quarry-grep--search-status-text ()
  "Return what the status line says about the search."
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
them does not carry them along and no window scrolls.  FUNCTION sees
the whole buffer; a narrowing is put back afterwards."
  (let ((point (point))
        (windows (mapcar (lambda (window)
                           (list window (window-point window) (window-start window)))
                         (get-buffer-window-list nil nil t))))
    (save-restriction
      (widen)
      (funcall function))
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
Point stays on the filter line it was on, by position in the list (on
the last line when the list got shorter).  From a result line or a file
heading it goes to the start of the buffer, and `quarry-grep--return'
is set so that the results bring it back."
  (let* ((inhibit-read-only t)
         (bol (pos-bol))
         (filters (quarry-grep--search-filters quarry-grep--current))
         (roles (quarry-grep--filter-roles quarry-grep--current))
         ;; The filter block starts the buffer, one line per filter.
         (index (and (get-text-property bol 'quarry-grep-filter)
                     (count-lines (point-min) bol)))
         (column (- (point) bol))
         (path (get-text-property bol 'quarry-grep-file))
         (line (get-text-property bol 'quarry-grep-line)))
    (remove-overlays (point-min) (point-max) 'quarry-grep-fold t)
    ;; What a commit with wgrep left on the edited lines.
    (remove-overlays (point-min) (point-max) 'wgrep t)
    (erase-buffer)
    (dolist (filter filters)
      (quarry-grep--insert-filter filter (alist-get filter roles)))
    (insert "\n")
    (set-marker quarry-grep--status-marker (point))
    (insert (propertize "\n" 'quarry-grep-status t))
    (quarry-grep--update-status)
    (let ((filter-line (quarry-grep--filter-position
                        (and index filters
                             (nth (min index (1- (length filters))) filters)))))
      (quarry-grep--goto
       (if filter-line
           (save-excursion
             (goto-char filter-line)
             (min (+ filter-line column) (pos-eol)))
         (point-min))))
    (setq quarry-grep--return (and path (list path line (point)))
          quarry-grep--return-block nil)
    (dolist (window (get-buffer-window-list nil nil t))
      ;; Not forced: a forced start would drag point back into view
      ;; when the results have moved it before the next redisplay.
      (set-window-start window (point-min) t))))

(defun quarry-grep--return-goto (pos)
  "Move point to POS where it still waits for the results; forget the wait.
That is in each window that shows the buffer and whose point is still
where the search put it, and in the buffer when its own point is.  A
window in which the user moved point is left alone."
  (let ((start (nth 2 quarry-grep--return)))
    (setq quarry-grep--return nil
          quarry-grep--return-block nil)
    (when pos
      (dolist (window (get-buffer-window-list nil nil t))
        (when (= (window-point window) start)
          (set-window-point window pos)))
      (when (= (point) start)
        (goto-char pos)))))

(defun quarry-grep--return-to-block ()
  "Move point to the place it had, when its file block has arrived.
That is the result line with the same line number, else the heading."
  (when (and quarry-grep--return quarry-grep--return-block)
    (let* ((start quarry-grep--return-block)
           (end (cdr (quarry-grep--block-at start)))
           (line (nth 1 quarry-grep--return)))
      (quarry-grep--return-goto
       (or (and line (text-property-any start end 'quarry-grep-line line))
           start)))))

(defun quarry-grep--return-near ()
  "Move point near the place it had, when its file did not come back.
That is the first heading whose path sorts after the file's, else the
first heading; without results point stays at the start."
  (when quarry-grep--return
    (let ((path (car quarry-grep--return))
          (blocks (quarry-grep--blocks)))
      (quarry-grep--return-goto
       (car (or (cl-find-if (lambda (block)
                              (string< path (get-text-property
                                             (car block) 'quarry-grep-file)))
                            blocks)
                (car blocks)))))))

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
  (save-restriction
    (widen)
    (quarry-grep--update-status)
    (if (eq quarry-grep--state 'done)
        (quarry-grep--return-near)
      (setq quarry-grep--return nil))
    (when-let* ((line (quarry-grep--filter-position quarry-grep--error-filter)))
      ;; Nothing was searched, so there are no results to keep point on;
      ;; RET now corrects the pattern.
      (quarry-grep--goto line))))

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
        (save-restriction
          (widen)
          (quarry-grep--return-to-block))
        (force-mode-line-update)))))

(defun quarry-grep--on-end (buffer serial instance status err)
  "End search SERIAL of BUFFER, served by INSTANCE, with STATUS and ERR."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eql serial quarry-grep--serial)
        (quarry-grep--finish status err instance)))))

(defun quarry-grep--run (search &optional history)
  "Make SEARCH the search of the current result buffer and run it.
A running search is cancelled.  HISTORY says what becomes of the search
shown so far.  Nil: it becomes a history entry when SEARCH differs from
it.  `back' or `forward': SEARCH is the first of `quarry-grep--past' or
`quarry-grep--future' and is taken from there, and the search shown so
far goes to the other list.  The lists change only when nothing can
stop the search from starting any more."
  (quarry-grep--check-not-editing)
  ;; First, so that a missing module leaves the buffer as it is.
  (let ((instance (quarry-grep--ensure-instance))
        (buffer (current-buffer))
        (serial (cl-incf quarry-grep--serial-counter)))
    (quarry-grep--abandon)
    (pcase history
      ('back
       (pop quarry-grep--past)
       (push quarry-grep--current quarry-grep--future))
      ('forward
       (pop quarry-grep--future)
       (push quarry-grep--current quarry-grep--past))
      (_
       (unless (or (null quarry-grep--current)
                   (equal quarry-grep--current search))
         (push quarry-grep--current quarry-grep--past)
         (setq quarry-grep--future nil))))
    ;; A narrowing belonged to the results that go.
    (widen)
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
          quarry-grep--dead-instance nil
          quarry-grep--edited nil)
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
  "Return the search of the current buffer or signal a `user-error'.
That is also signalled while the results are being edited."
  (quarry-grep--check-not-editing)
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
  "Minibuffer history of the file types and globs prompt of quarry-grep.")

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
  "Read the pattern of a new search, a regexp if REGEXP, else a literal.
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

(defun quarry-grep--classify-files (files)
  "Return (TYPES . GLOBS) for FILES, words that do not say what they are.
FILES is nil, a string (a list of one word) or a list of strings.  Each
word that is the name of a file type (see `quarry-grep--type-list') is
a type, every other word is a glob.  TYPES and GLOBS are lists of
strings in their order, nil for none; a type name given twice counts
once."
  (let ((names (mapcar (lambda (type) (plist-get type :name))
                       (quarry-grep--type-list)))
        types globs)
    (dolist (word (if (listp files) files (list files)))
      (if (member word names)
          (cl-pushnew word types :test #'equal)
        (push word globs)))
    (cons (nreverse types) (nreverse globs))))

(defun quarry-grep--parse-files (input)
  "Return (TYPES . GLOBS) for the file restriction INPUT names.
Both are nil for `everything' or nothing; else the words of INPUT,
separated by spaces, go through `quarry-grep--classify-files'."
  (let ((input (string-trim input)))
    (if (member input '("" "everything"))
        (cons nil nil)
      (quarry-grep--classify-files (split-string input "[ \t]+" t)))))

(defun quarry-grep--files-argument (files)
  "Return the FILES argument of the commands for FILES, a (TYPES . GLOBS).
That is nil for none, else the list of the type names and the globs."
  (append (car files) (cdr files)))

(defun quarry-grep--read-files (&optional default)
  "Read a file restriction; the value is that of `quarry-grep--parse-files'.
DEFAULT is the text offered as default; without it that is the type of
the current buffer's file, else `everything'."
  (let* ((names (cons "everything"
                      (mapcar (lambda (type) (plist-get type :name))
                              (quarry-grep--type-list))))
         (default (or default (quarry-grep--default-type) "everything")))
    (quarry-grep--parse-files
     (minibuffer-with-setup-hook
         (lambda ()
           ;; Words are separated by spaces, which complete by default.
           (let ((map (make-sparse-keymap)))
             (set-keymap-parent map (current-local-map))
             (keymap-set map "SPC" #'self-insert-command)
             (use-local-map map)))
       (completing-read (format-prompt "Search in files (types and globs)" default)
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

(defun quarry-grep--check-result-buffer ()
  "Signal a `user-error' when the result buffer cannot take a new search.
That is while its results are being edited.  The commands call this
before they ask for anything."
  (when-let* ((buffer (get-buffer quarry-grep-buffer-name)))
    (with-current-buffer buffer
      (when (derived-mode-p 'quarry-grep-mode)
        (quarry-grep--check-not-editing)))))

(defun quarry-grep--start-search (search)
  "Run SEARCH, a `quarry-grep--search', in the result buffer and show it.
The buffer is reused; it is an error while its results are being edited."
  (quarry-grep--check-result-buffer)
  ;; Before the buffer is made: a missing module is a `user-error'.
  (quarry-grep--ensure-instance)
  (let ((buffer (get-buffer-create quarry-grep-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'quarry-grep-mode)
        (quarry-grep-mode))
      (goto-char (point-min))
      (quarry-grep--run search))
    (pop-to-buffer buffer)))

(defun quarry-grep--start (pattern regexp files dir)
  "Search DIR for PATTERN in FILES and show the result buffer.
PATTERN is a regexp if REGEXP is non-nil, else a literal string.  FILES
is nil for all files, a string or a list of strings: a word that is the
name of a file type is a type, the others are globs (see
`quarry-grep--classify-files')."
  (quarry-grep--check-result-buffer)
  (quarry-grep--check-pattern pattern)
  (let* ((dir (quarry-grep--check-directory dir))
         (classified (quarry-grep--classify-files files)))
    (quarry-grep--start-search
     (quarry-grep--make-search
      :dir dir
      :types (car classified)
      :globs (cdr classified)
      :case quarry-grep-case
      :before (min quarry-grep-context-before quarry-grep-max-context)
      :after (min quarry-grep-context-after quarry-grep-max-context)
      :hidden (and quarry-include-hidden t)
      :filters (list (quarry-grep--make-filter
                      :pattern pattern :regexp (and regexp t)))))
    (when (> (max quarry-grep-context-before quarry-grep-context-after)
             quarry-grep-max-context)
      (quarry-grep--tell-context-limit))))

;;;###autoload
(defun quarry-grep (regexp files dir)
  "Search DIR for lines that match REGEXP, in FILES.
REGEXP is a Rust regexp.  FILES is nil for all files, the name of a
file type, a list of globs, or a list of type names and globs.  A word
that is the name of a file type is a type, any other is a glob.  A file
must be of one of the types, if any, and match one of the including
globs, if any.
The matches are shown in the buffer `quarry-grep-buffer-name'; see
`quarry-grep-mode' for what can be done there.  Interactively, ask for
the three."
  (interactive
   (progn
     (quarry-grep--check-result-buffer)
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern t)
           (quarry-grep--files-argument (quarry-grep--read-files))
           (quarry-grep--read-directory))))
  (quarry-grep--start regexp t files dir))

;;;###autoload
(defun quarry-grep-literal (string files dir)
  "Search DIR for lines that contain STRING, in FILES.
Like `quarry-grep', but STRING is a literal, not a regexp."
  (interactive
   (progn
     (quarry-grep--check-result-buffer)
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern nil)
           (quarry-grep--files-argument (quarry-grep--read-files))
           (quarry-grep--read-directory))))
  (quarry-grep--start string nil files dir))

;;;###autoload
(defun quarry-grep-project (regexp files)
  "Search the current project for lines that match REGEXP, in FILES.
Like `quarry-grep' in the project's root, or in `default-directory'
outside a project."
  (interactive
   (progn
     (quarry-grep--check-result-buffer)
     (quarry-grep--project-root)
     (quarry-grep--type-list)
     (list (quarry-grep--read-pattern t)
           (quarry-grep--files-argument (quarry-grep--read-files)))))
  (quarry-grep--start regexp t files (quarry-grep--project-root)))

;;;###autoload
(defun quarry-grep-dwim ()
  "Search the current project for the symbol at point.
The symbol is searched as a literal in the files of the current
buffer's file type, in the project's root or, outside a project, in
`default-directory'."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t))
        (root (quarry-grep--project-root)))
    (unless symbol
      (user-error "No symbol at point"))
    (quarry-grep--start symbol nil (quarry-grep--default-type) root)))

;;;; Visiting results

(defun quarry-grep--nth-line (from n property &optional except)
  "Return the start of the Nth line with PROPERTY after the line of FROM.
A line with the property EXCEPT does not count.  A negative N counts
backwards; 0 means the line of FROM itself.  Nil when there is no such
line."
  (save-excursion
    (goto-char from)
    (forward-line 0)
    (cl-flet ((counts ()
                (and (get-text-property (point) property)
                     (not (and except (get-text-property (point) except))))))
      (let ((step (if (< n 0) -1 1))
            (left (abs n)))
        (while (and (> left 0) (zerop (forward-line step)))
          (when (counts)
            (cl-decf left)))
        (and (zerop left)
             (counts)
             (point))))))

(defun quarry-grep--visit (bol &optional found)
  "Visit the file of the result or heading line that starts at BOL.
For a result line, go to its line and to the column of its first primary
match; for a context line, to its first column.  The file is shown in
another window when the result buffer's window is selected, else in the
selected window; its window is selected.
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
  ;; Hits only: context lines are not results.
  (let ((pos (quarry-grep--nth-line (if reset (point-min) (point)) n
                                    'quarry-grep-line 'quarry-grep-context)))
    (unless pos
      (user-error (if (< n 0) "No previous match" "No more matches")))
    (quarry-grep--unfold-at pos)
    (quarry-grep--goto pos)
    (quarry-grep--visit pos)))

(defun quarry-grep-visit ()
  "Visit the result at point, or edit the filter at point.
On a result line, visit the file at that line, at the column of the
first match of the primary filter.  On a context line, visit the file
at that line.  On a file heading, visit the file.  On a filter line,
edit its pattern in the minibuffer."
  (interactive nil quarry-grep-mode)
  (let ((bol (pos-bol)))
    (cond ((get-text-property bol 'quarry-grep-filter)
           (quarry-grep-edit-filter))
          ((get-text-property bol 'quarry-grep-gap)
           (user-error "Nothing to visit on this line"))
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
  "Return the file blocks of the buffer as a list of (START . END).
A narrowing is ignored."
  (save-restriction
    (widen)
    (let ((pos (point-min))
          (blocks nil))
      (while (setq pos (text-property-not-all pos (point-max) 'quarry-grep-file nil))
        (let ((end (or (next-single-property-change pos 'quarry-grep-file)
                       (point-max))))
          (push (cons pos end) blocks)
          (setq pos end)))
      (nreverse blocks))))

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

(defun quarry-grep--block-at-point-p ()
  "Return the file block at point as (START . END), or nil.
Does not signal."
  (quarry-grep--block-at (point)))

(defun quarry-grep-toggle-fold ()
  "Hide or show the result lines of the file block at point."
  (interactive nil quarry-grep-mode)
  (let ((block (quarry-grep--block-at-point-p)))
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
    ;; All blocks, also those outside a narrowing.
    (save-restriction
      (widen)
      (if (cl-every #'quarry-grep--fold-overlay blocks)
          (remove-overlays (point-min) (point-max) 'quarry-grep-fold t)
        (dolist (block blocks)
          (unless (quarry-grep--fold-overlay block)
            (quarry-grep--fold block)))))))

;;;; Commands that change the search

(defun quarry-grep-rerun ()
  "Run the buffer's search again."
  (interactive nil quarry-grep-mode)
  (quarry-grep--run (quarry-grep--current)))

(defun quarry-grep--running-p ()
  "Return non-nil when the search of this buffer is running.
Does not signal."
  (eq quarry-grep--state 'running))

(defun quarry-grep-cancel ()
  "Cancel the running search.  The results that arrived stay."
  (interactive nil quarry-grep-mode)
  (unless (and (quarry-grep--running-p) quarry-grep--call)
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

(defun quarry-grep--filter-at-point-p ()
  "Return the filter of the line at point, or nil.  Does not signal."
  (get-text-property (pos-bol) 'quarry-grep-filter))

(defun quarry-grep--filter-at-point ()
  "Return the filter of the line at point or signal a `user-error'."
  (quarry-grep--current)
  (or (quarry-grep--filter-at-point-p)
      (user-error "No filter at point")))

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
  "Edit the primary filter as a literal."
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
  "Search other files: file types and globs, or everything."
  (interactive nil quarry-grep-mode)
  (let ((files (quarry-grep--read-files
                (quarry-grep--search-files-text (quarry-grep--current)))))
    (quarry-grep--change
     (lambda (search)
       (setf (quarry-grep--search-types search) (car files)
             (quarry-grep--search-globs search) (cdr files))))))

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

;;;; Context

(defun quarry-grep--read-count (prompt default prefix)
  "Return the count of context lines: PREFIX, else read with DEFAULT.
PROMPT says which side is asked for.  Signal a `user-error' when the
count is negative or not a whole number."
  (let ((n (if prefix
               (prefix-numeric-value prefix)
             (read-number prompt default))))
    (unless (natnump n)
      (user-error "The number of context lines must be a whole number"))
    n))

(defun quarry-grep--tell-context-limit ()
  "Tell that a count of context lines was reduced to the limit."
  (message "Context is limited to %d lines" quarry-grep-max-context))

(defun quarry-grep--set-context (before after)
  "Run the current search with BEFORE and AFTER lines of context.
Either is nil to keep the count the search has.  A count above
`quarry-grep-max-context' becomes that, and the user is told."
  (let ((limited (or (and before (> before quarry-grep-max-context))
                     (and after (> after quarry-grep-max-context)))))
    (quarry-grep--change
     (lambda (search)
       (when before
         (setf (quarry-grep--search-before search)
               (min before quarry-grep-max-context)))
       (when after
         (setf (quarry-grep--search-after search)
               (min after quarry-grep-max-context)))))
    ;; After the search started: nothing else writes to the echo area.
    (when limited
      (quarry-grep--tell-context-limit))))

(defun quarry-grep-set-context (&optional count)
  "Show COUNT lines before and after each hit; 0 shows none.
Interactively, a numeric prefix argument is COUNT; without one, read it,
offering the larger of the two counts the search has.  A negative count
is a `user-error'.  A count above `quarry-grep-max-context' becomes that
and the echo area says so."
  (interactive "P" quarry-grep-mode)
  (let* ((search (quarry-grep--current))
         (n (quarry-grep--read-count
             "Lines of context before and after each hit: "
             (max (quarry-grep--search-before search)
                  (quarry-grep--search-after search))
             count)))
    (quarry-grep--set-context n n)))

(defun quarry-grep-set-context-before (&optional count)
  "Show COUNT lines before each hit; 0 shows none.
The count of lines after each hit stays as it is.  Asks for COUNT as
`quarry-grep-set-context' does."
  (interactive "P" quarry-grep-mode)
  (let* ((search (quarry-grep--current))
         (n (quarry-grep--read-count
             (format "Lines of context before each hit (after: %d): "
                     (quarry-grep--search-after search))
             (quarry-grep--search-before search) count)))
    (quarry-grep--set-context n nil)))

(defun quarry-grep-set-context-after (&optional count)
  "Show COUNT lines after each hit; 0 shows none.
The count of lines before each hit stays as it is.  Asks for COUNT as
`quarry-grep-set-context' does."
  (interactive "P" quarry-grep-mode)
  (let* ((search (quarry-grep--current))
         (n (quarry-grep--read-count
             (format "Lines of context after each hit (before: %d): "
                     (quarry-grep--search-before search))
             (quarry-grep--search-after search) count)))
    (quarry-grep--set-context nil n)))

;;;; Filters

(defvar quarry-grep-line-filter-history nil
  "Minibuffer history of the line filters added in a result buffer.")

(defvar quarry-grep-path-filter-history nil
  "Minibuffer history of the path filters added in a result buffer.")

(defun quarry-grep--filter-text (filter)
  "Return FILTER as text for a message, as its line shows it."
  (format "%s %s %s"
          (if (quarry-grep--filter-exclude filter) "-" "+")
          (quarry-grep--filter-kind filter)
          (quarry-grep--filter-pattern filter)))

(defun quarry-grep--set-filters (filters)
  "Run the current search with FILTERS as its filter list.
Signal a `user-error' when FILTERS has no enabled include line filter:
a search needs one to scan the files for."
  (let ((search (quarry-grep--copy-search (quarry-grep--current))))
    (setf (quarry-grep--search-filters search) filters)
    (unless (quarry-grep--primary search)
      (user-error "A search needs an enabled include line filter"))
    (quarry-grep--run search)))

(defun quarry-grep--add-filter (target exclude pattern regexp)
  "Add a filter to the current search and run it.
The filter matches PATTERN, a regexp if REGEXP is non-nil, against
TARGET (`line' or `path') and excludes what matches if EXCLUDE is
non-nil.  It goes to the end of the list.  A filter the search already
has is not added again: it is switched on, or a `user-error' when it is
on."
  (quarry-grep--check-pattern pattern)
  (let* ((filters (quarry-grep--search-filters (quarry-grep--current)))
         (new (quarry-grep--make-filter :target target :exclude (and exclude t)
                                        :pattern pattern :regexp (and regexp t)))
         (same (cl-find new filters
                        :test (lambda (a b)
                                (let ((b (quarry-grep--copy-filter b)))
                                  (setf (quarry-grep--filter-enabled b) t)
                                  (equal a b))))))
    (cond ((null same)
           (quarry-grep--set-filters (append filters (list new))))
          ((quarry-grep--filter-enabled same)
           (user-error "The search already has the filter %s"
                       (quarry-grep--filter-text same)))
          (t
           (quarry-grep--set-filters
            (mapcar (lambda (filter) (if (eq filter same) new filter)) filters))))))

(defun quarry-grep--read-filter (target exclude regexp &optional initial)
  "Read the pattern of a new filter on TARGET, starting from INITIAL.
The prompt says whether it will EXCLUDE and whether it is a REGEXP."
  (quarry-grep--check-pattern
   (read-string (format "%s %ss %s: "
                        (if exclude "Exclude" "Keep only")
                        target
                        (if regexp "matching regexp" "containing"))
                initial
                (if (eq target 'path)
                    'quarry-grep-path-filter-history
                  'quarry-grep-line-filter-history))))

(defun quarry-grep-exclude-path (&optional regexp)
  "Add a filter that excludes the files whose path contains a literal.
From Lisp, a non-nil REGEXP makes the pattern a regexp; that is the
command `quarry-grep-exclude-path-regexp'.  The path is matched as a
slash followed by the path relative to the search directory, so
`/test/' names a directory at any depth."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (quarry-grep--add-filter 'path t (quarry-grep--read-filter 'path t regexp) regexp))

(defun quarry-grep-include-path (&optional regexp)
  "Add a filter that includes only the files whose path contains a literal.
From Lisp, a non-nil REGEXP makes the pattern a regexp; that is the
command `quarry-grep-include-path-regexp'.  See
`quarry-grep-exclude-path' for what the path is."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (quarry-grep--add-filter 'path nil (quarry-grep--read-filter 'path nil regexp) regexp))

(defun quarry-grep-exclude-line (&optional regexp)
  "Add a filter that excludes the lines that contain a literal.
From Lisp, a non-nil REGEXP makes the pattern a regexp; that is the
command `quarry-grep-exclude-line-regexp'."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (quarry-grep--add-filter 'line t (quarry-grep--read-filter 'line t regexp) regexp))

(defun quarry-grep-include-line (&optional regexp)
  "Add a filter that includes only the lines that also contain a literal.
From Lisp, a non-nil REGEXP makes the pattern a regexp; that is the
command `quarry-grep-include-line-regexp'."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (quarry-grep--add-filter 'line nil (quarry-grep--read-filter 'line nil regexp) regexp))

(defun quarry-grep-exclude-path-regexp ()
  "Add a filter that excludes the files whose path matches a regexp.
See `quarry-grep-exclude-path' for what the path is."
  (interactive nil quarry-grep-mode)
  (quarry-grep-exclude-path t))

(defun quarry-grep-include-path-regexp ()
  "Add a filter that includes only the files whose path matches a regexp.
See `quarry-grep-exclude-path' for what the path is."
  (interactive nil quarry-grep-mode)
  (quarry-grep-include-path t))

(defun quarry-grep-exclude-line-regexp ()
  "Add a filter that excludes the lines that match a regexp."
  (interactive nil quarry-grep-mode)
  (quarry-grep-exclude-line t))

(defun quarry-grep-include-line-regexp ()
  "Add a filter that includes only the lines that also match a regexp."
  (interactive nil quarry-grep-mode)
  (quarry-grep-include-line t))

(defun quarry-grep--file-at-point-p ()
  "Return the path of the file block at point, or nil.  Does not signal."
  (get-text-property (pos-bol) 'quarry-grep-file))

(defun quarry-grep--file-at-point ()
  "Return the path of the file block at point or signal a `user-error'."
  (quarry-grep--current)
  (or (quarry-grep--file-at-point-p)
      (user-error "No file at point")))

(defun quarry-grep--directory-at-point-p ()
  "Return the directory of the file at point, or nil.
That is the directory relative to the search directory.  There is none
without a file at point and for a file in the search directory itself.
Does not signal."
  (when-let* ((path (quarry-grep--file-at-point-p)))
    (file-name-directory path)))

(defun quarry-grep--directory-at-point ()
  "Return the directory of the file at point as a path filter pattern.
That is a slash, the directory relative to the search directory, and a
slash.  Signal a `user-error' for a file in the search directory itself."
  (let ((path (quarry-grep--file-at-point)))
    (concat "/" (or (quarry-grep--directory-at-point-p)
                    (user-error "%s is in the search directory itself" path)))))

(defun quarry-grep--regexp-quote (string)
  "Return a Rust regexp that matches STRING and nothing else.
Unlike `regexp-quote', which quotes for Emacs regexps, this escapes
every character that is special in the syntax of the `regex' crate."
  (replace-regexp-in-string "[][\\.+*?()|{}^$#&~-]" "\\\\\\&" string t))

(defun quarry-grep--file-pattern (path)
  "Return a path filter regexp that matches the file PATH and no other.
A literal path filter would not do: it matches anywhere in a path, so
`/a.c' also names `a.cpp' and `sub/a.c'.  The regexp is anchored at both
ends and keeps case apart, whatever smart case makes of it."
  (concat "(?-i)^/" (quarry-grep--regexp-quote path) "$"))

(defun quarry-grep-exclude-file ()
  "Add a filter that excludes the file at point, and only that file."
  (interactive nil quarry-grep-mode)
  (quarry-grep--add-filter
   'path t (quarry-grep--file-pattern (quarry-grep--file-at-point)) t))

(defun quarry-grep-exclude-directory ()
  "Add a filter that excludes the directory of the file at point.
The minibuffer holds the directory; shorten it to drop a parent."
  (interactive nil quarry-grep-mode)
  (let ((dir (quarry-grep--directory-at-point)))
    (quarry-grep--add-filter 'path t (quarry-grep--read-filter 'path t nil dir) nil)))

(defun quarry-grep-include-directory ()
  "Add a filter that includes only the directory of the file at point.
The minibuffer holds the directory; shorten it to keep a parent."
  (interactive nil quarry-grep-mode)
  (let ((dir (quarry-grep--directory-at-point)))
    (quarry-grep--add-filter 'path nil (quarry-grep--read-filter 'path nil nil dir) nil)))

(defun quarry-grep-remove-filter ()
  "Remove the filter at point from the search."
  (interactive nil quarry-grep-mode)
  (let ((filter (quarry-grep--filter-at-point)))
    (quarry-grep--set-filters
     (remq filter (quarry-grep--search-filters quarry-grep--current)))))

(defun quarry-grep--replace-filter-checked (old new)
  "Run the current search with the filter OLD replaced by NEW.
Signal a `user-error' when that leaves no enabled include line filter."
  (quarry-grep--set-filters
   (mapcar (lambda (filter) (if (eq filter old) new filter))
           (quarry-grep--search-filters quarry-grep--current))))

(defun quarry-grep-toggle-filter ()
  "Switch the filter at point off or on.
A filter that is off stays in the list and is not applied."
  (interactive nil quarry-grep-mode)
  (let* ((filter (quarry-grep--filter-at-point))
         (new (quarry-grep--copy-filter filter)))
    (setf (quarry-grep--filter-enabled new) (not (quarry-grep--filter-enabled filter)))
    (quarry-grep--replace-filter-checked filter new)))

(defun quarry-grep-flip-filter ()
  "Make the filter at point exclude what it included, or the reverse."
  (interactive nil quarry-grep-mode)
  (let* ((filter (quarry-grep--filter-at-point))
         (new (quarry-grep--copy-filter filter)))
    (setf (quarry-grep--filter-exclude new) (not (quarry-grep--filter-exclude filter)))
    (quarry-grep--replace-filter-checked filter new)))

(defun quarry-grep--other-filters-p ()
  "Return non-nil when the search has a primary filter and other filters.
That is when `quarry-grep-remove-other-filters' has something to remove.
Does not signal."
  (and quarry-grep--current
       (quarry-grep--primary quarry-grep--current)
       (cdr (quarry-grep--search-filters quarry-grep--current))
       t))

(defun quarry-grep-remove-other-filters ()
  "Remove all filters except the primary one, also those switched off."
  (interactive nil quarry-grep-mode)
  (let* ((search (quarry-grep--current))
         (primary (or (quarry-grep--primary search)
                      (user-error "The search has no primary filter"))))
    (unless (quarry-grep--other-filters-p)
      (user-error "The search has no other filters"))
    (quarry-grep--set-filters (list primary))))

;;;; Editing with wgrep

;; wgrep is optional (docs/decisions/0013): nothing here loads it except
;; `quarry-grep-edit'.  wgrep is told what the lines are by two functions
;; that translate the properties above into its own; no text is parsed.

(defvar wgrep-mode-map)
(defvar wgrep-prepared)
(defvar wgrep-original-mode-map)
(defvar wgrep-header&footer-parser)
(defvar wgrep-results-parser)
(declare-function wgrep-change-to-wgrep-mode "ext:wgrep" ())
(declare-function wgrep-construct-filename-property "ext:wgrep" (filename))

(defconst quarry-grep--link-properties '(mouse-face highlight follow-link t)
  "The properties that make a line respond to the mouse.")

(defun quarry-grep--in-edit-mode-p ()
  "Return non-nil when the buffer's keys are those of wgrep's edit mode."
  (and (boundp 'wgrep-mode-map)
       (eq (current-local-map) wgrep-mode-map)))

(defun quarry-grep--edit-sync ()
  "Make the buffer a result buffer again when wgrep's edit mode has ended.
wgrep has no hook for that, so this runs after each command while the
buffer is edited (`post-command-hook') and before the commands of
this file look at the buffer."
  (when (and quarry-grep--editing (not (quarry-grep--in-edit-mode-p)))
    (quarry-grep--edit-restore)))

(defun quarry-grep--check-not-editing ()
  "Signal a `user-error' while the results are being edited."
  (quarry-grep--edit-sync)
  (when quarry-grep--editing
    (user-error "The results are being edited; finish with C-c C-c or abort with C-c C-k first")))

(defun quarry-grep--edit-header-and-footer ()
  "Mark the header and the footer for wgrep.
The value of `wgrep-header&footer-parser' in a result buffer.  The
header is everything before the first file block, the footer the
status line."
  (let ((first (or (text-property-any (point-min) (point-max) 'quarry-grep-heading t)
                   (point-max)))
        (status (or (text-property-any (point-min) (point-max) 'quarry-grep-status t)
                    (point-max))))
    (add-text-properties (point-min) first '(read-only t wgrep-header t))
    ;; `read-only' does not keep text from being put before it, and
    ;; nothing stands before the first character.
    (put-text-property (point-min) (min (1+ (point-min)) first) 'front-sticky '(read-only))
    (add-text-properties status (point-max) '(read-only t wgrep-footer t))
    ;; A click with mouse-1 must set point while editing, not follow a
    ;; link to a key that the edit mode does not have.
    (remove-list-of-text-properties (point-min) (point-max) '(mouse-face follow-link))))

(defun quarry-grep--edit-results ()
  "Tell wgrep what the lines between header and footer are.
The value of `wgrep-results-parser' in a result buffer; wgrep calls it
with the buffer narrowed to that part.  A result line gets its file and
line number on its prefix, so the rest of it can be edited; that holds
for a context line as for a hit.  File headings, separators, gap lines
and the lines whose text is not exactly the file's line
(`quarry-grep-inexact') are marked to be left alone."
  (goto-char (point-min))
  (setq quarry-grep--edit-properties nil)
  (while (not (eobp))
    (let* ((bol (point))
           (path (get-text-property bol 'quarry-grep-file))
           ;; Not `expand-file-name': a path like "~/x" must stay below
           ;; the search directory.
           (file (and path (concat default-directory path)))
           (text (and (get-text-property bol 'quarry-grep-line)
                      (not (get-text-property bol 'quarry-grep-inexact))
                      (next-single-property-change bol 'quarry-grep-prefix nil
                                                   (pos-eol)))))
      (cond (text
             (add-text-properties bol text
                                  (list 'wgrep-line-filename file
                                        'wgrep-line-number
                                        (get-text-property bol 'quarry-grep-line))))
            (t
             ;; With its newline: wgrep makes the newline before such a
             ;; run read-only, and an empty line would otherwise be no
             ;; run at all and leave the line above it open at its end.
             (put-text-property bol (min (1+ (pos-eol)) (point-max)) 'wgrep-ignore t)
             (when (get-text-property bol 'quarry-grep-heading)
               ;; wgrep looks for a file's lines from this property on.
               (let ((property (wgrep-construct-filename-property file)))
                 (push property quarry-grep--edit-properties)
                 (put-text-property bol (pos-eol) property file))))))
    (forward-line 1)))

(defun quarry-grep--edit-restore ()
  "Make the buffer a result buffer again after wgrep's edit mode.
Remove wgrep's text properties, give the lines back what an edit or an
abort took from them, find the status line again, and say in it when
changes were committed."
  (with-silent-modifications
   (save-restriction
    ;; The user may have narrowed while editing.
    (widen)
    (remove-list-of-text-properties
     (point-min) (point-max)
     (append '(read-only rear-nonsticky front-sticky wgrep-header wgrep-footer wgrep-ignore
                         wgrep-line-filename wgrep-line-number)
             quarry-grep--edit-properties))
    (save-excursion
      (goto-char (point-min))
      (let ((path nil) (block nil) (status nil))
        (while (and (not status) (not (eobp)))
          (let ((bol (point)) (eol (pos-eol)))
            (cond
             ((get-text-property bol 'quarry-grep-status)
              (setq status bol))
             ((get-text-property bol 'quarry-grep-filter)
              (add-text-properties bol eol quarry-grep--link-properties))
             ((get-text-property bol 'quarry-grep-heading)
              (setq path (get-text-property bol 'quarry-grep-file)
                    block bol)
              (add-text-properties bol eol quarry-grep--link-properties))
             ((get-text-property bol 'quarry-grep-separator)
              ;; Typed text does not inherit the block's property.
              (when path
                (put-text-property block bol 'quarry-grep-file path))
              (setq path nil))
             ((and path (get-text-property bol 'quarry-grep-line))
              (add-text-properties
               bol (min (1+ eol) (point-max))
               (list 'quarry-grep-line (get-text-property bol 'quarry-grep-line)
                     'quarry-grep-column (get-text-property bol 'quarry-grep-column)))
              (add-text-properties bol eol quarry-grep--link-properties)
              (when (get-text-property bol 'quarry-grep-context)
                (put-text-property bol (min (1+ eol) (point-max))
                                   'quarry-grep-context t)
                (put-text-property
                 (next-single-property-change bol 'quarry-grep-prefix nil eol)
                 eol 'face 'quarry-grep-context)))))
          (forward-line 1))
        (when path
          (put-text-property block (or status (point-max)) 'quarry-grep-file path))
        ;; An abort replaces the whole text, which takes the marker along.
        (set-marker quarry-grep--status-marker (or status (point-max)))))))
  (remove-hook 'post-command-hook #'quarry-grep--edit-sync t)
  (buffer-disable-undo)
  (setq buffer-read-only t
        quarry-grep--editing nil
        quarry-grep--edit-properties nil)
  (when (cl-some (lambda (overlay) (overlay-get overlay 'wgrep-result))
                 (save-restriction (widen) (overlays-in (point-min) (point-max))))
    (setq quarry-grep--edited t))
  (quarry-grep--update-status))

(defun quarry-grep--file-mtime (file)
  "Return the modification time of FILE in milliseconds, rounded down.
That is how the service reports it.  Nil when FILE does not exist."
  (when-let* ((attributes (file-attributes file)))
    (car (time-convert (file-attribute-modification-time attributes) 1000))))

(defun quarry-grep--stale-files ()
  "Return the result files that are not as the search saw them.
Those are the files that are gone, whose modification time differs
from the one the search reported, or that a modified buffer visits,
under whatever name.  A file whose time the search did not learn counts
as unchanged."
  ;; By true name: a buffer may visit the file through a symbolic link.
  ;; Collected once, and nothing is resolved while no buffer is modified.
  (let ((modified (delq nil (mapcar (lambda (buffer)
                                      (and (buffer-file-name buffer)
                                           (buffer-modified-p buffer)
                                           (buffer-local-value 'buffer-file-truename
                                                               buffer)))
                                    (buffer-list))))
        (stale nil))
    (save-restriction
      (widen)
      (dolist (block (quarry-grep--blocks))
        (let* ((path (get-text-property (car block) 'quarry-grep-file))
               (seen (get-text-property (car block) 'quarry-grep-mtime))
               (file (concat default-directory path))
               (now (quarry-grep--file-mtime file)))
          (when (or (null now)
                    (and seen (/= seen now))
                    (and modified
                         (member (abbreviate-file-name (file-truename file)) modified)))
            (push path stale)))))
    (nreverse stale)))

(defun quarry-grep--has-results-p ()
  "Return non-nil when the buffer has result lines.  Does not signal."
  (not (zerop quarry-grep--lines)))

(defun quarry-grep--wgrep-available-p ()
  "Return non-nil when wgrep is loaded or can be loaded.
Does not load it and does not signal."
  (and (or (featurep 'wgrep) (locate-library "wgrep")) t))

(defun quarry-grep--editable-p ()
  "Return non-nil when `quarry-grep-edit' can start.
That is when no search is running, there are results and wgrep is
installed.  Does not signal."
  (and (not (quarry-grep--running-p))
       (quarry-grep--has-results-p)
       (quarry-grep--wgrep-available-p)))

(defun quarry-grep-edit ()
  "Edit the results with wgrep.
In wgrep's edit mode the text of the result lines can be changed;
C-c C-c applies the changes to the buffers of the files and C-c C-k
discards them.  Lines that are shown cut or that hold bytes that are
not valid UTF-8 cannot be edited.  When a result file changed since the
search, ask whether to search again first; after that search, run this
command again.  Needs the package wgrep."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (when (quarry-grep--running-p)
    (user-error "A search is running; wait for it or cancel it with C-c C-k"))
  (unless (quarry-grep--has-results-p)
    (user-error "There are no results to edit"))
  (unless (require 'wgrep nil t)
    (user-error "Editing the results needs the package wgrep; install it and try again"))
  (let ((stale (quarry-grep--stale-files)))
    (if (and stale
             (y-or-n-p (format "%s changed since the search (%s%s); search again first? "
                               (quarry-grep--plural (length stale) "result file")
                               (car stale)
                               (if (cdr stale) ", ..." ""))))
        (progn
          (quarry-grep-rerun)
          (message "Searching again; press e when the search is done"))
      ;; wgrep reads the buffer from its ends.
      (widen)
      ;; An edit in hidden text would be a trap.
      (remove-overlays (point-min) (point-max) 'quarry-grep-fold t)
      (remove-overlays (point-min) (point-max) 'wgrep t)
      (setq-local wgrep-header&footer-parser #'quarry-grep--edit-header-and-footer
                  wgrep-results-parser #'quarry-grep--edit-results
                  ;; The map wgrep goes back to.  `wgrep-setup-internal'
                  ;; would set it too, and bind a key in it.
                  wgrep-original-mode-map (current-local-map)
                  ;; The properties of an earlier edit are gone.
                  wgrep-prepared nil)
      (setq quarry-grep--editing t)
      (add-hook 'post-command-hook #'quarry-grep--edit-sync nil t)
      (wgrep-change-to-wgrep-mode))))

;;;; History

(defun quarry-grep--earlier-search-p ()
  "Return non-nil when the history has a search before the current one.
Does not signal."
  (and quarry-grep--past t))

(defun quarry-grep--later-search-p ()
  "Return non-nil when the history has a search after the current one.
Does not signal."
  (and quarry-grep--future t))

(defun quarry-grep-history-back ()
  "Run the search that preceded the current one in this buffer."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (unless (quarry-grep--earlier-search-p)
    (user-error "No earlier search"))
  (quarry-grep--run (car quarry-grep--past) 'back))

(defun quarry-grep-history-forward ()
  "Run the search that `quarry-grep-history-back' went back from."
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (unless (quarry-grep--later-search-p)
    (user-error "No later search"))
  (quarry-grep--run (car quarry-grep--future) 'forward))

;;;; Header line

(autoload 'quarry-grep-menu "quarry-grep-menu" nil t)

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
With COMMAND, a click on VALUE runs it and HELP is its tooltip.  Each %
in VALUE is doubled: Emacs takes the string an `:eval' form returns as
a mode line format again."
  (setq value (string-replace "%" "%%" value))
  (concat label ": "
          (if command
              (propertize value
                          'face 'quarry-grep-header-value
                          'mouse-face 'header-line-highlight
                          'help-echo (concat "mouse-1: " help)
                          'keymap (quarry-grep--header-map command))
            (propertize value 'face 'quarry-grep-header-value))))

(defun quarry-grep--context-text (search)
  "Return the lines of context of SEARCH as shown to the user.
That is the count when both sides are equal, else \"BEFORE/AFTER\"."
  (let ((before (quarry-grep--search-before search))
        (after (quarry-grep--search-after search)))
    (if (= before after)
        (number-to-string before)
      (format "%d/%d" before after))))

(defun quarry-grep--header-hint ()
  "Return the part of the header line that names the key of the menu.
A click on it runs `quarry-grep-menu'."
  (propertize (concat (propertize "?" 'face 'quarry-grep-header-value) " menu")
              'mouse-face 'header-line-highlight
              'help-echo "mouse-1: show all keys (?)"
              'keymap (quarry-grep--header-map #'quarry-grep-menu)))

(defun quarry-grep--header ()
  "Return the header line of the result buffer.
It ends with the hint for the menu, except while the results are
being edited: `?' is text then."
  (let ((search quarry-grep--current))
    (if (null search)
        ""
      (concat
       " "
       (mapconcat
        #'identity
        (delq
         nil
         (list
          (quarry-grep--header-part
           "files" (quarry-grep--search-files-text search)
           #'quarry-grep-change-files "change the file types and globs (f)")
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
           "ctx" (quarry-grep--context-text search)
           #'quarry-grep-set-context "set the lines of context (C, B, A)")
          (quarry-grep--header-part
           "hits" (format "%d in %s" quarry-grep--lines
                          (quarry-grep--plural quarry-grep--files "file")))
          (unless quarry-grep--editing
            (quarry-grep--header-hint))))
          "   ")))))

;;;; Mode

(defvar-keymap quarry-grep-mode-map
  :doc "Keymap of `quarry-grep-mode'."
  "?" #'quarry-grep-menu
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
  "- p" #'quarry-grep-exclude-path
  "+ p" #'quarry-grep-include-path
  "- l" #'quarry-grep-exclude-line
  "+ l" #'quarry-grep-include-line
  "- P" #'quarry-grep-exclude-path-regexp
  "+ P" #'quarry-grep-include-path-regexp
  "- L" #'quarry-grep-exclude-line-regexp
  "+ L" #'quarry-grep-include-line-regexp
  "- f" #'quarry-grep-exclude-file
  "- d" #'quarry-grep-exclude-directory
  "+ d" #'quarry-grep-include-directory
  "k" #'quarry-grep-remove-filter
  "x" #'quarry-grep-toggle-filter
  "!" #'quarry-grep-flip-filter
  "K" #'quarry-grep-remove-other-filters
  "d" #'quarry-grep-change-directory
  "f" #'quarry-grep-change-files
  "c" #'quarry-grep-cycle-case
  "i" #'quarry-grep-toggle-ignore
  "H" #'quarry-grep-toggle-hidden
  "C" #'quarry-grep-set-context
  "B" #'quarry-grep-set-context-before
  "A" #'quarry-grep-set-context-after
  "C-c <" #'quarry-grep-history-back
  "C-c >" #'quarry-grep-history-forward
  "C-c C-k" #'quarry-grep-cancel
  "e" #'quarry-grep-edit)

(defun quarry-grep--after-clone ()
  "Make the current buffer, a new clone of a result buffer, independent.
`clone-buffer' copies the local variables, so the clone would share
the original's status marker and its running search.  It gets a marker
of its own and no search: one that was running is shown as cancelled
here and goes on in the original."
  (quarry-grep--edit-sync)
  (setq quarry-grep--status-marker
        (save-restriction
          (widen)
          (copy-marker (or (text-property-any (point-min) (point-max)
                                              'quarry-grep-status t)
                           (point-max))))
        quarry-grep--call nil
        quarry-grep--serial nil
        quarry-grep--return nil
        quarry-grep--return-block nil)
  (when (eq quarry-grep--state 'running)
    (setq quarry-grep--state 'cancelled)
    (quarry-grep--update-status)))

(define-derived-mode quarry-grep-mode special-mode "quarry-grep"
  "Major mode of the result buffer of `quarry-grep'.
The buffer shows the filters of the search, one block per file with the
matching lines, and a status line.  The header line shows the file
type, the directory and the switches; its parts can be clicked.
\\`?' shows a menu of all keys; \\`h' shows this help.

\\{quarry-grep-mode-map}"
  :interactive nil
  (buffer-disable-undo)
  (setq-local next-error-function #'quarry-grep--next-error)
  (setq-local revert-buffer-function (lambda (&rest _) (quarry-grep-rerun)))
  (setq-local header-line-format '(:eval (quarry-grep--header)))
  (add-to-invisibility-spec '(quarry-grep-fold . t))
  (add-hook 'clone-buffer-hook #'quarry-grep--after-clone nil t)
  (add-hook 'kill-buffer-hook #'quarry-grep--abandon nil t)
  (add-hook 'change-major-mode-hook #'quarry-grep--abandon nil t))

(provide 'quarry-grep)
;;; quarry-grep.el ends here
