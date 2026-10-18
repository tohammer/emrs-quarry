;;; quarry-consult-grep.el --- live grep through consult for quarry  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `quarry-consult-grep' searches a directory while the pattern is
;; typed in a consult prompt, and `quarry-consult-grep-project' the root
;; of the current project.  The grep service of the quarry module answers
;; each input; the hits are the candidates, in the shape of
;; `consult-grep' (ADR 0018), so preview, grouping and `embark-export'
;; work as for `consult-ripgrep'.  RET visits the hit.
;;
;; The input is a list of terms separated by spaces.  Each term is a
;; Rust regexp that a line must match; a term with `!' in front is one
;; it must not match.  After " -- " come options in rg's spelling, for
;; example `-t rust', `-T json', `-g GLOB', `-F' and `-i' (ADR 0019);
;; `-t', `-T' and `-g' may be given several times.  The whole
;; syntax is in docs/user/live-grep.md.
;; `quarry-consult-grep-quote' turns a string into input that searches
;; for it literally.
;;
;; In the prompt, `C-c C-o' (`quarry-consult-grep-to-buffer', in
;; `quarry-consult-grep-map') runs the search that is typed in the
;; `*quarry-grep*' buffer of `quarry-grep', with the terms as its
;; filters.
;;
;; The commands need consult; they were tested with consult 3.7.
;; This file loads and byte-compiles without it; the commands then
;; signal a `user-error'.  They use consult's internal async pipeline
;; (ADR 0008), so a consult upgrade can break them.  The package binds
;; no keys.
;;
;; Inside: `quarry-consult-grep--parse' turns the input into a
;; `quarry-grep--search', and `quarry-consult-grep--async' is the step
;; of the pipeline.  Each new input is parsed and sent to the service as
;; a stream; the search it supersedes is cancelled.  Errors and the
;; notice that a search stopped at `quarry-consult-grep-max-lines' hits
;; are shown by a note after the minibuffer input.

;;; Code:

(require 'cl-lib)
(require 'emrs)
(require 'project)
(require 'quarry-grep)
(require 'consult nil t)

(declare-function consult--read "consult" (table &rest options))
(declare-function consult--async-pipeline "consult" (&rest async))
(declare-function consult--async-split "consult" (&optional style))
(declare-function consult--async-min-input "consult" (&optional min-input))
(declare-function consult--async-throttle "consult" (&optional throttle debounce))
(declare-function consult--async-indicator "consult" ())
(declare-function consult--async-refresh "consult" (&optional delay))
(declare-function consult--grep-state "consult" ())
(declare-function consult--prefix-group "consult" (cand transform))
(declare-function consult--lookup-member "consult" (selected candidates &rest _))

(defvar quarry-include-hidden)
(defvar consult-async-split-style)
(defvar consult-async-split-styles-alist)

;;;; Options

(defcustom quarry-consult-grep-max-lines 1000
  "Number of hits a live search collects before it stops.
A live search uses this in place of `quarry-grep-max-lines'.  A search
that stopped here says so after the input."
  :type 'integer
  :group 'quarry)

(defcustom quarry-consult-grep-input-debounce 0.05
  "Seconds of no typing before the live grep searches.
Passed to `consult--async-throttle' as its debounce delay."
  :type 'number
  :group 'quarry)

(defcustom quarry-consult-grep-input-throttle 0.1
  "Minimum seconds between two searches of the live grep.
Passed to `consult--async-throttle' as its throttle delay."
  :type 'number
  :group 'quarry)

(defvar quarry-consult-grep-history nil
  "Minibuffer history of the live grep commands: the inputs.")

(defvar-keymap quarry-consult-grep-map
  :doc "Keymap active in the prompt of the live grep commands.
Those are `quarry-consult-grep' and `quarry-consult-grep-project'.
Bind other keys here, or another key to
`quarry-consult-grep-to-buffer'."
  "C-c C-o" #'quarry-consult-grep-to-buffer)

;;;; The words of the input

(defun quarry-consult-grep--words (input)
  "Split INPUT into a list of words.
An unescaped space or tab ends a word.  A backslash and a space give a
space inside the word; a backslash and any other character stay as they
are, so `\\\\' followed by a space is an escaped backslash and a word
boundary.  A trailing lone backslash stays."
  (let ((i 0) (n (length input)) (words nil) (word nil))
    (while (< i n)
      (let ((c (aref input i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n))
          (let ((next (aref input (1+ i))))
            (if (eq next ?\s)
                (push ?\s word)
              (push c word)
              (push next word)))
          (setq i (+ i 2)))
         ((memq c '(?\s ?\t))
          (when word
            (push (concat (nreverse word)) words)
            (setq word nil))
          (setq i (1+ i)))
         (t (push c word)
            (setq i (1+ i))))))
    (when word
      (push (concat (nreverse word)) words))
    (nreverse words)))

;;;; The options

(cl-defstruct (quarry-consult-grep--opts (:constructor quarry-consult-grep--make-opts))
  "What the option words of an input have set."
  types globs case no-ignore hidden fixed)

(defun quarry-consult-grep--add-type (opts entry)
  "Append the type ENTRY to the types of OPTS, dropping an earlier copy.
ENTRY is a type name, or \"!NAME\" for an excluded type."
  (setf (quarry-consult-grep--opts-types opts)
        (append (delete entry (quarry-consult-grep--opts-types opts))
                (list entry))))

(defconst quarry-consult-grep--options
  `(("-t" "--type" t
     ,(lambda (o v) (quarry-consult-grep--add-type o v)))
    ("-T" "--type-not" t
     ,(lambda (o v) (quarry-consult-grep--add-type o (concat "!" v))))
    ("-g" "--glob" t
     ,(lambda (o v)
        (setf (quarry-consult-grep--opts-globs o)
              (append (quarry-consult-grep--opts-globs o) (list v)))))
    ("-F" "--fixed-strings" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-fixed o) t)))
    ("-i" "--ignore-case" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-case o) 'insensitive)))
    ("-s" "--case-sensitive" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-case o) 'sensitive)))
    ("-S" "--smart-case" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-case o) 'smart)))
    ("-u" "--no-ignore" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-no-ignore o) t)))
    ("-uu" nil nil
     ,(lambda (o _)
        (setf (quarry-consult-grep--opts-no-ignore o) t
              (quarry-consult-grep--opts-hidden o) 'yes)))
    ("-." "--hidden" nil
     ,(lambda (o _) (setf (quarry-consult-grep--opts-hidden o) 'yes)))
    (nil "--no-hidden" nil
         ,(lambda (o _) (setf (quarry-consult-grep--opts-hidden o) 'no))))
  "The options of the input after \" -- \".
Each entry is (SHORT LONG VALUE FUNCTION): the spellings (either may be
nil), non-nil when the option takes a value, and a function of the
`quarry-consult-grep--opts' and the value.  A new option is one entry.")

(defun quarry-consult-grep--find-option (word)
  "Return (ENTRY . ATTACHED) for the option word WORD, or nil.
ATTACHED is the value written into WORD (`-trust', `--type=rust'), or
nil."
  (or (cl-loop for e in quarry-consult-grep--options
               when (member word (list (nth 0 e) (nth 1 e)))
               return (cons e nil))
      (cl-loop for e in quarry-consult-grep--options
               for short = (nth 0 e)
               for long = (nth 1 e)
               when (nth 2 e)
               do (cond
                   ((and short (string-prefix-p short word)
                         (not (string-prefix-p "--" word)))
                    ;; `-t=rust' is `-trust', as in rg.
                    (cl-return
                     (cons e (string-remove-prefix
                              "=" (substring word (length short))))))
                   ((and long (string-prefix-p (concat long "=") word))
                    (cl-return (cons e (substring word (1+ (length long))))))))))

(defun quarry-consult-grep--option-prefix-p (word)
  "Return non-nil when WORD is the start of an option's spelling."
  (and (string-prefix-p "-" word)
       (cl-loop for e in quarry-consult-grep--options
                thereis (cl-loop for spelling in (list (nth 0 e) (nth 1 e))
                                 thereis (and spelling
                                              (string-prefix-p word spelling))))))

(defun quarry-consult-grep--apply-options (words opts)
  "Apply the option WORDS to OPTS, a `quarry-consult-grep--opts'."
  (while words
    (let* ((word (pop words))
           (found (quarry-consult-grep--find-option word)))
      (cond
       ((null found)
        (cond
         ;; The last word may be an option that is being typed.
         ((and (null words) (quarry-consult-grep--option-prefix-p word)))
         ((string-prefix-p "-" word)
          (user-error "Unknown option %s; see docs/user/live-grep.md, \"Options\""
                      word))
         (t (user-error "Not an option: %s" word))))
       ((not (nth 2 (car found)))
        (funcall (nth 3 (car found)) opts nil))
       ((cdr found)
        (unless (string-empty-p (cdr found))
          (funcall (nth 3 (car found)) opts (cdr found))))
       (words
        (funcall (nth 3 (car found)) opts (pop words)))))))
;; A value still missing at the end of the input is being typed: ignored.

;;;; The parser

(defun quarry-consult-grep--drop-open-escape (terms input)
  "Return TERMS without the backslash that ends INPUT unpaired.
Such a backslash is the start of an escape that is being typed, and
would be an error as a regexp.  INPUT is nil when the terms do not
reach the end of the input."
  (if (and input terms
           (string-match "\\\\+\\'" input)
           (cl-oddp (- (match-end 0) (match-beginning 0))))
      (let ((last (car (last terms))))
        (append (butlast terms)
                (and (> (length last) 1)
                     (list (substring last 0 -1)))))
    terms))

(defun quarry-consult-grep--parse (dir input)
  "Return the `quarry-grep--search' that INPUT asks for in DIR.
Return nil when there is nothing to search yet, and signal a `user-error'
for input that cannot be a search.  INPUT is cut at the first \" -- \";
the words before it are terms, the words after it options."
  (let* ((words (quarry-consult-grep--words input))
         (cut (cl-position "--" words :test #'equal))
         (terms (quarry-consult-grep--drop-open-escape
                 (if cut (cl-subseq words 0 cut) words)
                 (and (not cut) input)))
         (option-words (and cut (nthcdr (1+ cut) words)))
         (parsed nil))                  ; (EXCLUDE . TEXT), in typed order
    (dolist (term terms)
      (cond
       ((equal term "!"))
       ((string-prefix-p "!" term)
        (push (cons t (substring term 1)) parsed))
       ((string-prefix-p "\\!" term)
        (push (cons nil (substring term 1)) parsed))
       (t (push (cons nil term) parsed))))
    (setq parsed (nreverse parsed))
    (when (cl-some (lambda (p) (not (car p))) parsed)
      (let ((opts (quarry-consult-grep--make-opts)))
        (quarry-consult-grep--apply-options option-words opts)
        (let ((regexp (not (quarry-consult-grep--opts-fixed opts))))
          (quarry-grep--make-search
           :dir dir
           :types (quarry-consult-grep--opts-types opts)
           :globs (quarry-consult-grep--opts-globs opts)
           :case (or (quarry-consult-grep--opts-case opts) quarry-grep-case)
           :no-ignore (quarry-consult-grep--opts-no-ignore opts)
           :hidden (pcase (quarry-consult-grep--opts-hidden opts)
                     ('yes t)
                     ('no nil)
                     (_ (and quarry-include-hidden t)))
           :before 0
           :after 0
           :filters (mapcar
                     (lambda (p)
                       (quarry-grep--make-filter
                        :exclude (car p) :pattern (cdr p) :regexp regexp))
                     parsed)))))))

;;;; Quoting

(defun quarry-consult-grep--separator ()
  "Return the separator character of the consult split style, or nil."
  (when (and (boundp 'consult-async-split-style)
             (boundp 'consult-async-split-styles-alist)
             consult-async-split-style)
    (let* ((style (cdr (assq consult-async-split-style
                             consult-async-split-styles-alist)))
           (initial (plist-get style :initial)))
      ;; A character in consult 3, a string in older versions.
      (cond ((characterp initial) initial)
            ((and (stringp initial) (> (length initial) 0))
             (aref initial 0))
            ((characterp (plist-get style :separator))
             (plist-get style :separator))))))

(defun quarry-consult-grep-quote (string)
  "Return STRING as input that searches for it literally.
Characters are quoted for the Rust regexp engine, a space becomes `\\ ',
a leading `!' becomes `\\!', and the separator of the current consult
split style becomes `\\xNN' so that it does not end the search part."
  (let ((sep (quarry-consult-grep--separator))
        (out nil))
    (dotimes (i (length string))
      (let ((c (aref string i)))
        (push (cond
               ((eq c sep) (format (if (< c 128) "\\x%02X" "\\x{%X}") c))
               ((eq c ?\s) "\\ ")
               ((eq c ?\t) "\\t")
               ((and (eq c ?!) (= i 0)) "\\!")
               (t (quarry-grep--regexp-quote (string c))))
              out)))
    (apply #'concat (nreverse out))))

;;;; The candidates

(defun quarry-consult-grep--candidates (item)
  "Return the candidates of ITEM, a file item of the grep service.
There is one per kept line, a string PATH:LINE:TEXT in the shape of
`consult-grep' (ADR 0018): `consult-file' and the group on PATH,
`consult-line-number' on LINE, `consult-highlight-match' on the matches
of the primary filter.  With `quarry-grep-highlight-include-filters'
the matches of the other include filters get
`quarry-grep-match-secondary'.  The colons and the rest of TEXT have no
face: `consult--grep-position' finds the parts by the changes of `face'."
  (let* ((file (cdr item))
         ;; One string for all lines of the file, as consult does it.
         (path (plist-get file :path))
         (path-len (length path))
         (candidates nil))
    (dolist (line (plist-get file :lines))
      (unless (plist-get line :context)
        (let* ((number (number-to-string (plist-get line :n)))
               (start (+ path-len (length number) 2))
               (cand (concat path ":" number ":" (plist-get line :text))))
          (add-text-properties
           0 path-len `(face consult-file consult--prefix-group ,path) cand)
          (put-text-property (1+ path-len) (1- start)
                             'face 'consult-line-number cand)
          (pcase-dolist (`(,from ,to) (plist-get line :spans))
            (put-text-property (+ start from) (+ start to)
                               'face 'consult-highlight-match cand))
          (when quarry-grep-highlight-include-filters
            (pcase-dolist (`(,from ,to) (plist-get line :secondary))
              ;; consult takes every stretch with a face for a match,
              ;; except where the list holds `consult-grep-context'.
              (put-text-property
               (+ start from) (+ start to) 'face
               '(quarry-grep-match-secondary consult-grep-context) cand)))
          (push cand candidates))))
    (nreverse candidates)))

;;;; The note

(defun quarry-consult-grep--note-string (text face)
  "Return the note for TEXT in FACE: one line of it in brackets.
Of several lines that is the last one that is not empty: the regexp
engine says what is wrong there, after a picture of the pattern."
  (let ((note (propertize
               (format " [%s]"
                       (string-trim
                        (or (car (last (split-string text "\n" t "[ \t]+")))
                            "")))
               'face face)))
    ;; As `minibuffer-message' does: the cursor stays before the note.
    (put-text-property 0 1 'cursor 1 note)
    note))

(defun quarry-consult-grep--show-note (buffer text face)
  "Show TEXT in FACE after the contents of BUFFER; return the overlay.
Do nothing and return nil when BUFFER is nil or dead."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((overlay (make-overlay (point-max) (point-max) buffer t t)))
        (overlay-put overlay 'after-string
                     (quarry-consult-grep--note-string text face))
        ;; Before other overlays at this position, like the candidates
        ;; of a vertical completion UI.
        (overlay-put overlay 'priority 1100)
        overlay))))

(defun quarry-consult-grep--remove-note (overlay)
  "Remove the note OVERLAY; nil is allowed."
  (when overlay
    (delete-overlay overlay)))

;;;; The async step

(defun quarry-consult-grep--async (dir)
  "Return a consult async step that searches DIR with the grep service.
See `consult--async-pipeline' for the protocol.  Each new input string
is parsed with `quarry-consult-grep--parse' and sent as a stream; the
search it supersedes is cancelled.  The candidates of the previous
input stay until the first ones of the new search arrive.  A search
collects at most `quarry-consult-grep-max-lines' hits.  Errors and the
notice of a search that stopped there are shown after the minibuffer
input, not with `message', which would hide the input."
  (lambda (sink)
    (let ((input nil)                   ; current input, nil when none
          (call nil)                    ; running call
          (serial 0)                    ; number of the running call
          (fresh nil)                   ; non-nil until candidates were sent
          (truncated nil)               ; hits of a search that was cut
          (buffer nil)                  ; the minibuffer's buffer
          (overlay nil))                ; the note
      (cl-labels
          ((stop ()
             ;; Cancel the running call and return non-nil if there was
             ;; one.  Its `:on-end' runs at once, with a stale serial.
             (cl-incf serial)
             (when call
               (let ((running call))
                 (setq call nil)
                 (emrs-cancel running)
                 t)))
           (unnote ()
             (quarry-consult-grep--remove-note overlay)
             (setq overlay nil))
           (note (text face)
             (unnote)
             (setq overlay (quarry-consult-grep--show-note buffer text face)))
           (fail (text)
             (funcall sink 'flush)
             (funcall sink [indicator failed])
             (note text 'error))
           (batch (items)
             (let ((candidates nil))
               (dolist (item items)
                 (pcase (car-safe item)
                   (:file
                    (setq candidates
                          (nconc candidates
                                 (quarry-consult-grep--candidates item))))
                   (:summary
                    (setq truncated (and (plist-get (cdr item) :truncated)
                                         (plist-get (cdr item) :lines))))))
               (when candidates
                 ;; Flush only now, so that the old candidates stay
                 ;; until the new ones arrive.
                 (when fresh
                   (setq fresh nil)
                   (funcall sink 'flush))
                 (funcall sink candidates))))
           (end (status err)
             (pcase status
               ('done
                (when fresh
                  (funcall sink 'flush))
                (funcall sink [indicator finished])
                (when truncated
                  (note (format "first %s hits" truncated) 'shadow)))
               ('failed
                (fail (format "%s" (plist-get err :message))))))
           (search ()
             (stop)
             (unnote)
             (let ((this serial))
               (condition-case err
                   (let ((search (quarry-consult-grep--parse dir input)))
                     (if (null search)
                         ;; Nothing to search yet.
                         (progn
                           (funcall sink 'flush)
                           (funcall sink [indicator finished]))
                       (setq fresh t
                             truncated nil)
                       (setq call (emrs-call-stream
                                   (quarry-grep--ensure-instance)
                                   (let ((quarry-grep-max-lines
                                          quarry-consult-grep-max-lines))
                                     (quarry-grep--request search))
                                   :on-batch (lambda (items)
                                               (when (= this serial)
                                                 (batch items)))
                                   :on-end (lambda (status err)
                                             (when (= this serial)
                                               (setq call nil)
                                               (end status err)))))
                       (funcall sink [indicator running])))
                 ;; `emrs-call-stream' signals for an instance that is
                 ;; known to have stopped; the parser and
                 ;; `quarry-grep--ensure-instance' signal a `user-error'.
                 (emrs-error (fail (format "%s" (nth 2 err))))
                 (error (fail (error-message-string err)))))))
        (lambda (action)
          (pcase action
            ((pred stringp)
             (unless (equal action input)
               (setq input (substring-no-properties action))
               (search))
             nil)
            ('setup
             ;; The callbacks run from a process filter, with any buffer
             ;; current; this action comes inside the minibuffer.
             (setq buffer (current-buffer))
             (funcall sink action))
            ((or 'cancel 'destroy)
             ;; Nothing else ends the indicator of a search cancelled
             ;; here: its `:on-end' is ignored.
             (when (and (stop) (eq action 'cancel))
               (funcall sink [indicator killed]))
             ;; The same input must search again: its call may have been
             ;; cancelled before it ended.
             (setq input nil)
             (unnote)
             (when (eq action 'destroy)
               (setq buffer nil))
             (funcall sink action))
            (_ (funcall sink action))))))))

;;;; The commands

(defconst quarry-consult-grep--consult-functions
  '(consult--read consult--async-pipeline consult--async-split
    consult--async-min-input consult--async-throttle
    consult--async-indicator consult--async-refresh consult--grep-state
    consult--prefix-group consult--lookup-member)
  "The functions of consult that the live grep calls.")

(defun quarry-consult-grep--available-p ()
  "Return non-nil when consult is there with every function used."
  (and (or (featurep 'consult) (require 'consult nil t))
       (cl-every #'fboundp quarry-consult-grep--consult-functions)))

(defun quarry-consult-grep--check-consult ()
  "Signal a `user-error' when consult cannot be used."
  (unless (quarry-consult-grep--available-p)
    (user-error "quarry-consult-grep needs consult (tested with 3.7)")))

(defvar-local quarry-consult-grep--prompt nil
  "In the minibuffer of a live grep, the cons (DIR . TAG); else nil.
DIR is the directory the prompt searches.  TAG is the `catch' tag of
the command that opened the prompt; `quarry-consult-grep-to-buffer'
throws to it.")

(defun quarry-consult-grep--split (input)
  "Return (SEARCH . FILTER), the two parts of the minibuffer INPUT.
INPUT is split by the function of the current style in
`consult-async-split-styles-alist', as `consult--async-split' does it.
With the style `none', with a style that has no function and without
consult, all of INPUT is the search part."
  (let* ((style (and (boundp 'consult-async-split-style)
                     (boundp 'consult-async-split-styles-alist)
                     (cdr (assq (or consult-async-split-style 'none)
                                consult-async-split-styles-alist))))
         (fun (plist-get style :function)))
    (if (not (functionp fun))
        (cons input "")
      (let* ((parts (funcall fun input style))
             (pos (min (or (nth 1 parts) (length input)) (length input))))
        (cons (substring-no-properties (car parts))
              (substring input pos))))))

(defun quarry-consult-grep-to-buffer ()
  "Run the search typed in the live grep prompt in the result buffer.
The prompt is left and the search part of its input becomes a search of
`quarry-grep': the terms are its filters, the options its file
restriction, case rule and switches.  The context lines are those of
`quarry-grep-context-before' and `quarry-grep-context-after', and the
search stops at `quarry-grep-max-lines' hits.  The filter part of the
input, which filters the candidates in Emacs, is not carried over.
Input that is no search is an error, and the prompt stays open."
  (interactive)
  (let ((prompt (and (minibufferp) quarry-consult-grep--prompt)))
    (unless prompt
      (user-error "This command works in the prompt of quarry-consult-grep"))
    ;; A throw from an outer minibuffer would close the inner ones too.
    (unless (innermost-minibuffer-p)
      (user-error "Not in the innermost minibuffer"))
    ;; Split again here: the step may not have seen the newest input.
    (let ((parts (quarry-consult-grep--split
                  (minibuffer-contents-no-properties))))
      (quarry-grep--check-result-buffer)
      (let ((search (quarry-consult-grep--parse (car prompt) (car parts))))
        (unless search
          (user-error "Nothing to search yet"))
        (throw (cdr prompt) (cons search (cdr parts)))))))

(defun quarry-consult-grep--hand-over (search filter)
  "Run SEARCH in the result buffer; FILTER is the input's filter part.
SEARCH gets the context lines that `quarry-grep' starts with.  A FILTER
that is not empty is reported as not carried over."
  (let ((search (quarry-grep--copy-search search)))
    (setf (quarry-grep--search-before search)
          (min quarry-grep-context-before quarry-grep-max-context)
          (quarry-grep--search-after search)
          (min quarry-grep-context-after quarry-grep-max-context))
    (quarry-grep--start-search search)
    (when (> (max quarry-grep-context-before quarry-grep-context-after)
             quarry-grep-max-context)
      (quarry-grep--tell-context-limit))
    ;; After the buffer is shown, so that nothing replaces the message.
    (unless (string-empty-p filter)
      (message "The filter part \"%s\" was not carried over" filter))))

(defun quarry-consult-grep--read (dir initial)
  "Open the live grep prompt for DIR with the initial input INITIAL.
DIR is an absolute directory name with a slash.  A chosen hit is
visited by the state function, as in `consult--grep'.  A search handed
over with `quarry-consult-grep-to-buffer' is run in the result buffer."
  ;; The hand-over leaves the prompt with a throw to this tag.  An exit
  ;; through `exit-minibuffer' would go on in `consult--read' with the
  ;; current candidate: it would be visited, or "No selection" would be
  ;; signalled.  The throw unwinds the minibuffer like a quit does:
  ;; consult's exit hook removes the preview, its unwind forms save the
  ;; input to the history and call the state function without a
  ;; candidate, so nothing is visited.  The search runs after all of
  ;; that, outside the minibuffer.  The tag is new for each prompt and
  ;; is kept in the prompt's buffer, so with recursive minibuffers the
  ;; throw can only reach the command whose prompt the key was typed in.
  (let* ((tag (make-symbol "quarry-consult-grep-to-buffer"))
         (handed
          (catch tag
            (let ((default-directory dir)
                  (symbol (thing-at-point 'symbol)))
              (minibuffer-with-setup-hook
                  (lambda ()
                    (setq-local quarry-consult-grep--prompt (cons dir tag)))
                (consult--read
                 (consult--async-pipeline
                  (consult--async-split)
                  (consult--async-min-input)
                  (consult--async-throttle quarry-consult-grep-input-throttle
                                           quarry-consult-grep-input-debounce)
                  (quarry-consult-grep--async dir)
                  (consult--async-indicator)
                  (consult--async-refresh))
                 :prompt (format "Grep in %s: " (abbreviate-file-name dir))
                 :category 'consult-grep
                 :group #'consult--prefix-group
                 :state (consult--grep-state)
                 :lookup #'consult--lookup-member
                 :require-match t
                 :sort nil
                 ;; `consult--async-split' puts the initial character of
                 ;; the split style in front of this.
                 :initial initial
                 :add-history symbol
                 :history '(:input quarry-consult-grep-history)
                 :keymap quarry-consult-grep-map
                 ;; The pipeline above is complete; the default wrapper
                 ;; would add split, indicator and refresh a second time.
                 :async-wrap #'identity)))
            nil)))
    (when handed
      (quarry-consult-grep--hand-over (car handed) (cdr handed)))))

(defun quarry-consult-grep--run (dir initial)
  "Check consult, DIR and the module, then open the prompt with INITIAL."
  (quarry-consult-grep--check-consult)
  (let ((dir (quarry-grep--check-directory dir)))
    ;; Starts the instance; a missing module is a `user-error' here.
    (quarry-grep--type-list)
    (quarry-consult-grep--read dir initial)))

(defun quarry-consult-grep--region ()
  "Return the active region as literal input and deactivate the mark.
Return nil when no region is active."
  (when (use-region-p)
    (prog1 (quarry-consult-grep-quote
            (buffer-substring-no-properties (region-beginning) (region-end)))
      (deactivate-mark))))

;;;###autoload
(defun quarry-consult-grep (&optional dir initial)
  "Search DIR while the pattern is typed, with the hits as candidates.
DIR is `default-directory' by default; with a prefix argument, ask for
it.  INITIAL is the initial input; interactively that is the active
region, quoted with `quarry-consult-grep-quote'.

The input is a list of terms separated by spaces.  A term is a Rust
regexp that a line must match; a term with `!' in front is one that it
must not match.  After a `--' that stands alone come options in rg's
spelling, among them `-t TYPE', `-T TYPE', `-g GLOB', `-F', `-i', `-s',
`-S', `-u' and `-.'; see docs/user/live-grep.md for all of them.
With the default `consult-async-split-style' the input reads
`#TERMS -- OPTIONS#FILTER', where FILTER filters the candidates in Emacs.

RET visits the hit.  In the prompt, `quarry-consult-grep-to-buffer'
runs the search in the result buffer of `quarry-grep'; it is bound in
`quarry-consult-grep-map'.  Needs consult; tested with 3.7."
  (interactive
   (progn
     (quarry-consult-grep--check-consult)
     (list (and current-prefix-arg
                (read-directory-name "Search in directory: "))
           (quarry-consult-grep--region))))
  (quarry-consult-grep--run (or dir default-directory) initial))

;;;###autoload
(defun quarry-consult-grep-project (&optional dir initial)
  "Search the current project while the pattern is typed.
That is the root of the current project, or `default-directory' outside
a project.  With a prefix argument, choose a project first.  From Lisp,
DIR is searched in place of the project root.  INITIAL and the input
are those of `quarry-consult-grep'."
  (interactive
   (progn
     (quarry-consult-grep--check-consult)
     (list (and current-prefix-arg (project-prompt-project-dir))
           (quarry-consult-grep--region))))
  ;; Before the project is looked up, which can be slow.
  (quarry-consult-grep--check-consult)
  (quarry-consult-grep--run (or dir (quarry-grep--project-root)) initial))

(provide 'quarry-consult-grep)
;;; quarry-consult-grep.el ends here
