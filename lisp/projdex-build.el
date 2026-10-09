;;; projdex-build.el --- Build the projdex module with cargo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The projdex authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Builds the Rust module from the repository that holds this package and
;; installs it as lisp/projdex-module plus `module-file-suffix', next to
;; projdex.el.  This file depends neither on emrs nor on the module, so a
;; package manager can load it standalone from a pre-build step before
;; projdex is built:
;;
;;   (load (expand-file-name "lisp/projdex-build.el") nil t)
;;   (projdex-build-module-sync)
;;
;; `projdex-build-module' is the interactive, asynchronous variant.

;;; Code:

(defgroup projdex nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "projdex-")

(defcustom projdex-build-cargo-program "cargo"
  "Program that builds the projdex module (`cargo build --release')."
  :type 'string
  :group 'projdex)

(defconst projdex-build--file (or load-file-name buffer-file-name)
  "File this library was loaded from, or nil.")

(defconst projdex-build--buffer "*projdex-build*"
  "Name of the buffer that receives the build output.")

(defconst projdex-build--hint
  "run M-x projdex-build-module later"
  "What to do after a failed automatic build.")

(defun projdex-build--find-repo ()
  "Return the repository root as a directory name, or nil.
It is the parent of the directory of the true name of this file (its .el
sibling when loaded from a .elc), so the build tree is the one this file
belongs to even when another projdex.el is on `load-path'.  When that is
unknown, it is the parent of the directory of the true name of projdex.el
on `load-path'.  The root need not contain Cargo.toml."
  (let* ((own (and projdex-build--file
                   (if (string-suffix-p ".elc" projdex-build--file)
                       (substring projdex-build--file 0 -1)
                     projdex-build--file)))
         (lib (or (and own (file-exists-p own) (file-truename own))
                  (let ((found (locate-library "projdex.el" t)))
                    (and found (file-truename found))))))
    (and lib
         (file-name-directory
          (directory-file-name (file-name-directory lib))))))

(defun projdex-build--repo ()
  "Return the repository root, which holds Cargo.toml.
Signal a `user-error' when there is none."
  (let ((repo (projdex-build--find-repo)))
    (unless (and repo (file-exists-p (expand-file-name "Cargo.toml" repo)))
      (user-error "projdex source not found (installed without its repository?); install the module by hand, see the README"))
    repo))

(defun projdex-build--module-file (repo)
  "Return the file the module is installed as in REPO."
  (expand-file-name (concat "lisp/projdex-module" module-file-suffix) repo))

(defun projdex-build--library (repo)
  "Return the file `cargo build --release' produces in REPO."
  (expand-file-name
   (concat "target/release/"
           (pcase system-type
             ('darwin "libprojdex.dylib")
             ('windows-nt "projdex.dll")
             (_ "libprojdex.so")))
   repo))

(defun projdex-build--arguments (repo)
  "Return the arguments of the cargo command that builds REPO.
The target directory is explicit, so neither CARGO_TARGET_DIR nor the
cargo configuration can move the library from `projdex-build--library'."
  (list "build" "--release" "--target-dir"
        (expand-file-name "target" repo)))

(defun projdex-build--install (repo)
  "Install the library built in REPO as its module file.
The copy goes to a temporary file first and replaces the module file by
rename, so an Emacs that has the old module loaded keeps a valid file."
  (let* ((library (projdex-build--library repo))
         (target (projdex-build--module-file repo))
         (temp (progn
                 (unless (file-exists-p library)
                   (user-error "Cargo produced no %s" library))
                 (make-temp-file
                  (expand-file-name "projdex-module.tmp-" (file-name-directory target))
                  nil module-file-suffix))))
    (condition-case err
        (progn (copy-file library temp t)
               (set-file-modes temp #o755)
               (rename-file temp target t))
      (error (ignore-errors (delete-file temp))
             (signal (car err) (cdr err))))
    target))

(defun projdex-build--loaded-p ()
  "Return non-nil when a projdex module is loaded in this Emacs."
  (or (featurep 'projdex-module)
      (and (boundp 'emrs--modules) (hash-table-p emrs--modules)
           (gethash 'projdex emrs--modules)
           t)))

(defun projdex-build--program ()
  "Return the full name of the cargo program, or signal a `user-error'."
  (or (executable-find projdex-build-cargo-program)
      (user-error "Program `%s' not found; install Rust or set `projdex-build-cargo-program'"
                  projdex-build-cargo-program)))

(defun projdex-build--finish (repo success)
  "Install the library of REPO when SUCCESS and report the result."
  (if (not success)
      (message "projdex module build failed (see %s)" projdex-build--buffer)
    (condition-case err
        (progn (projdex-build--install repo)
               (message (if (projdex-build--loaded-p)
                            "projdex module built; restart Emacs to use it"
                          "projdex module built")))
      (error (message "projdex module build failed: %s" (error-message-string err))
             (setq success nil))))
  success)

;;;###autoload
(defun projdex-build-module ()
  "Build the projdex module with cargo, asynchronously.
The output goes to the buffer `*projdex-build*'.  On success the module
is installed next to projdex.el; a running Emacs needs a restart to use
a rebuilt module.  Recompiling in that buffer installs as well.  Return
the build process."
  (interactive)
  (when (get-buffer-process projdex-build--buffer)
    (user-error "The projdex module is being built (see %s)" projdex-build--buffer))
  (let* ((repo (projdex-build--repo))
         (program (projdex-build--program))
         (default-directory repo)
         (buffer (compilation-start
                  (mapconcat #'shell-quote-argument
                             (cons program (projdex-build--arguments repo)) " ")
                  'compilation-mode
                  (lambda (_mode) projdex-build--buffer))))
    (get-buffer-process buffer)))

(defun projdex-build--compilation-finished (buffer message)
  "Install the module when the build in BUFFER ended with MESSAGE.
Meant for `compilation-finish-functions'; it ignores other buffers."
  (when (equal (buffer-name buffer) projdex-build--buffer)
    (projdex-build--finish
     (buffer-local-value 'default-directory buffer)
     (equal message "finished\n"))))

(add-hook 'compilation-finish-functions #'projdex-build--compilation-finished)

(defun projdex-build--output-tail (&optional lines)
  "Return the last LINES (default 30) lines of the build buffer."
  (with-current-buffer projdex-build--buffer
    (save-excursion
      (goto-char (point-max))
      (forward-line (- (or lines 30)))
      (string-trim (buffer-substring-no-properties (point) (point-max))))))

;;;###autoload
(defun projdex-build-module-sync ()
  "Build the projdex module with cargo, waiting for it to finish.
Never signal: a failure becomes a warning.  In batch mode the warning
includes the end of the build output, which is lost with the process.
Return non-nil on success."
  (condition-case err
      (let* ((repo (projdex-build--repo))
             (program (projdex-build--program))
             (default-directory repo)
             (buffer (get-buffer-create projdex-build--buffer))
             status)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)))
        (setq status (apply #'call-process program nil buffer nil
                            (projdex-build--arguments repo)))
        (unless (eql status 0)
          (if noninteractive
              (error "The build failed:\n%s" (projdex-build--output-tail))
            (error "The build failed (see %s)" projdex-build--buffer)))
        (projdex-build--install repo)
        (message "projdex module built")
        t)
    (error
     (display-warning
      'projdex (format "Cannot build the module: %s; %s"
                       (error-message-string err) projdex-build--hint))
     nil)))

(provide 'projdex-build)
;;; projdex-build.el ends here
