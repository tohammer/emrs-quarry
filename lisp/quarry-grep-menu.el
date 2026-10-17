;;; quarry-grep-menu.el --- Menu of the keys of the quarry-grep result buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; Keywords: tools, matching
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `quarry-grep-menu', bound to `?' in `quarry-grep-mode', is a
;; transient that lists the keys of the result buffer with the current
;; value of each switch.  Each entry runs the command that has the same
;; key in `quarry-grep-mode-map' and closes the menu; the menu adds no
;; command and no state of its own (docs/decisions/0016).  Entries that
;; do not apply at point or in the state of the search are shown inactive.
;;
;; `quarry-grep.el' autoloads the command, so transient is loaded on the
;; first `?'.  A test compares the menu with the keymap.

;;; Code:

(require 'quarry-grep)
(require 'transient)

;;;; Descriptions

;; Transient calls these with the result buffer current, the buffer the
;; menu was opened from.

(defun quarry-grep-menu--entry (label value)
  "Return \"LABEL: VALUE\" with VALUE in the face of a transient value."
  (concat label ": " (propertize value 'face 'transient-value)))

(defun quarry-grep-menu--case ()
  "Return the description of the case rule."
  (quarry-grep-menu--entry
   "case" (symbol-name (quarry-grep--search-case quarry-grep--current))))

(defun quarry-grep-menu--ignore ()
  "Return the description of the ignore files switch."
  (quarry-grep-menu--entry
   "ignore files"
   (if (quarry-grep--search-no-ignore quarry-grep--current) "off" "on")))

(defun quarry-grep-menu--hidden ()
  "Return the description of the hidden files switch."
  (quarry-grep-menu--entry
   "hidden files"
   (if (quarry-grep--search-hidden quarry-grep--current) "on" "off")))

(defun quarry-grep-menu--context ()
  "Return the description of the lines of context."
  (quarry-grep-menu--entry
   "context" (quarry-grep--context-text quarry-grep--current)))

(defun quarry-grep-menu--before ()
  "Return the description of the lines of context before a hit."
  (quarry-grep-menu--entry
   "before" (number-to-string (quarry-grep--search-before quarry-grep--current))))

(defun quarry-grep-menu--after ()
  "Return the description of the lines of context after a hit."
  (quarry-grep-menu--entry
   "after" (number-to-string (quarry-grep--search-after quarry-grep--current))))

(defun quarry-grep-menu--regexp ()
  "Return the description of the regexp or literal switch.
It names what the filter at point becomes."
  (let ((filter (quarry-grep--filter-at-point-p)))
    (cond ((null filter) "make the filter at point regexp or literal")
          ((quarry-grep--filter-regexp filter) "make the filter at point literal")
          (t "make the filter at point a regexp"))))

(defun quarry-grep-menu--directory ()
  "Return the description of the search directory."
  (quarry-grep-menu--entry
   "directory" (abbreviate-file-name (quarry-grep--search-dir quarry-grep--current))))

(defun quarry-grep-menu--files ()
  "Return the description of the file types and globs."
  (quarry-grep-menu--entry
   "file types"
   (quarry-grep--search-files-text quarry-grep--current)))

;;;; The menu

(transient-define-prefix quarry-grep-menu ()
  "Show the keys of the result buffer and run one of them.
A prefix argument typed before this command or with \\`C-u' in the menu
goes to the command that is run."
  [["Search"
    ("g" "search again" quarry-grep-rerun)
    ("r" "edit the primary filter as regexp" quarry-grep-change-regexp)
    ("t" "edit the primary filter as literal" quarry-grep-change-literal)
    ("d" quarry-grep-change-directory :description quarry-grep-menu--directory)
    ("f" quarry-grep-change-files :description quarry-grep-menu--files)
    ("C-c C-k" "cancel the search, or leave the preview" quarry-grep-cancel
     :inapt-if-not quarry-grep--cancellable-p)]
   ["Switches"
    ("c" quarry-grep-cycle-case :description quarry-grep-menu--case)
    ("i" quarry-grep-toggle-ignore :description quarry-grep-menu--ignore)
    ("H" quarry-grep-toggle-hidden :description quarry-grep-menu--hidden)
    ("C" quarry-grep-set-context :description quarry-grep-menu--context)
    ("B" quarry-grep-set-context-before :description quarry-grep-menu--before)
    ("A" quarry-grep-set-context-after :description quarry-grep-menu--after)]]
  [["Include"
    ("+l" "line, literal" quarry-grep-include-line)
    ("+L" "line, regexp" quarry-grep-include-line-regexp)
    ("+p" "path, literal" quarry-grep-include-path)
    ("+P" "path, regexp" quarry-grep-include-path-regexp)
    ("+d" "directory of the file at point" quarry-grep-include-directory
     :inapt-if-not quarry-grep--directory-at-point-p)]
   ["Exclude"
    ("-l" "line, literal" quarry-grep-exclude-line)
    ("-L" "line, regexp" quarry-grep-exclude-line-regexp)
    ("-p" "path, literal" quarry-grep-exclude-path)
    ("-P" "path, regexp" quarry-grep-exclude-path-regexp)
    ("-f" "the file at point" quarry-grep-exclude-file
     :inapt-if-not quarry-grep--file-at-point-p)
    ("-d" "directory of the file at point" quarry-grep-exclude-directory
     :inapt-if-not quarry-grep--directory-at-point-p)]
   ["Filters"
    ("%" quarry-grep-toggle-regexp :description quarry-grep-menu--regexp
     :inapt-if-not quarry-grep--filter-at-point-p)
    ("x" "switch the filter, or the replacement, at point off or on"
     quarry-grep-toggle-filter :inapt-if-not quarry-grep--toggle-at-point-p)
    ("!" "flip the filter at point" quarry-grep-flip-filter
     :inapt-if-not quarry-grep--filter-at-point-p)
    ("k" "remove the filter at point" quarry-grep-remove-filter
     :inapt-if-not quarry-grep--filter-at-point-p)
    ("K" "remove all but the primary filter" quarry-grep-remove-other-filters
     :inapt-if-not quarry-grep--other-filters-p)]]
  [["Results"
    ("RET" "visit the line, or edit the filter, at point" quarry-grep-visit)
    ("n" "next match" quarry-grep-next-match)
    ("p" "previous match" quarry-grep-previous-match)
    ("}" "next file" quarry-grep-next-file)
    ("{" "previous file" quarry-grep-previous-file)
    ("TAB" "fold the file at point" quarry-grep-toggle-fold
     :inapt-if-not quarry-grep--block-at-point-p)
    ("<backtab>" "fold all files" quarry-grep-toggle-fold-all)]
   ["History"
    ("C-c <" "earlier search" quarry-grep-history-back
     :inapt-if-not quarry-grep--earlier-search-p)
    ("C-c >" "later search" quarry-grep-history-forward
     :inapt-if-not quarry-grep--later-search-p)]
   ["Edit"
    ("e" "edit the results (wgrep)" quarry-grep-edit
     :inapt-if-not quarry-grep--editable-p)
    ("R" "replace the matches" quarry-grep-replace)
    ("C-c C-c" "write the replacement" quarry-grep-replace-apply
     :inapt-if-not quarry-grep--applicable-p)]]
  (interactive nil quarry-grep-mode)
  (quarry-grep--current)
  (transient-setup 'quarry-grep-menu)
  ;; Transient does not pass on an argument typed before the menu; this is
  ;; what `C-u' inside the menu does (`transient-update').
  (when current-prefix-arg
    (setq prefix-arg current-prefix-arg)))

(provide 'quarry-grep-menu)
;;; quarry-grep-menu.el ends here
