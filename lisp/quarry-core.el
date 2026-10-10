;;; quarry-core.el --- Module loading shared by the quarry tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; What the quarry tools share: finding the module file, loading it (with
;; the offer to build it when it is missing) and the options that apply to
;; both the file finder (quarry.el) and the grep tool (quarry-grep.el).
;; Neither tool needs the other, so this file requires neither.

;;; Code:

(require 'emrs)
(require 'quarry-build)

;;;; Options

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

(defun quarry--module-file ()
  "Return the module file next to the true quarry.el, or nil.
Nil when the repository cannot be found or the file does not exist."
  (let* ((repo (ignore-errors (quarry-build--find-repo)))
         (file (and repo (quarry-build--module-file repo))))
    (and file (file-exists-p file) file)))

(defun quarry--offer-build ()
  "Offer to build the missing module; signal a `user-error' either way."
  (let ((repo (ignore-errors (quarry-build--find-repo))))
    (when (get-buffer-process quarry-build--buffer)
      (user-error "The quarry module is being built; run the command again when it is done"))
    (if (and repo
             (file-exists-p (expand-file-name "Cargo.toml" repo))
             (not noninteractive)
             (y-or-n-p "quarry module not built. Build it now with cargo? "))
        (progn
          (quarry-build-module)
          (user-error "Building the quarry module; run the command again when it is done"))
      (user-error "Cannot load the quarry module: install it as quarry-module%s on `load-path', or run M-x quarry-build-module"
                  module-file-suffix))))

(defun quarry--load-module ()
  "Load the quarry module, or signal a `user-error' that says what to do."
  (condition-case err
      (emrs-load-module 'quarry (quarry--module-file))
    (file-missing
     (quarry--offer-build))
    (error
     (let ((file (quarry--module-file)))
       (if file
           (user-error "Loading %s failed: %s; rebuild it with M-x quarry-build-module"
                       file (error-message-string err))
         (user-error "Cannot load the quarry module (install it as quarry-module%s on `load-path'): %s"
                     module-file-suffix (error-message-string err)))))))

(provide 'quarry-core)
;;; quarry-core.el ends here
