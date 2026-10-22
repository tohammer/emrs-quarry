;;; quarry-core.el --- Module loading shared by the quarry tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; What the quarry tools share: registering the module with emrs-install.el
;; (which finds, downloads or builds it), loading it and the options that
;; apply to both the file finder (quarry.el) and the grep tool
;; (quarry-grep.el).  Neither tool needs the other, so this file requires
;; neither.

;;; Code:

(require 'emrs)
(require 'emrs-install)

;;;; Options

(defgroup quarry nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "quarry-")

(defcustom quarry-include-hidden t
  "Non-nil means hidden files are included."
  :type 'boolean
  :group 'quarry)

(defcustom quarry-ignores nil
  "Extra gitignore-syntax patterns.
They are relative to the project root or the searched directory."
  :type '(repeat string)
  :group 'quarry)

;;;; Module

(defconst quarry-module-version "0.2.0-snapshot"
  "The version of the quarry module this Lisp expects.
It must equal `version' in Cargo.toml and the \";; Version:\" header of
quarry.el.")

(emrs-install-register 'quarry
  :version quarry-module-version
  :url "https://github.com/tohammer/emrs-quarry/releases/download"
  :source (or load-file-name buffer-file-name))

(defun quarry--load-module ()
  "Load the quarry module through emrs-install, or signal a `user-error'.
The installer finds, downloads or builds the module and says what to do
when it cannot."
  (emrs-install-load 'quarry))

(provide 'quarry-core)
;;; quarry-core.el ends here
