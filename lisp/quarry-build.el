;;; quarry-build.el --- Build the quarry module with cargo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Builds the Rust module from the repository that holds this package and
;; installs it as lisp/quarry-module plus `module-file-suffix', next to
;; quarry.el.  This file depends neither on emrs nor on the module, so a
;; package manager can load it standalone from a pre-build step before
;; quarry is built:
;;
;;   (load (expand-file-name "lisp/quarry-build.el") nil t)
;;   (quarry-build-module-sync)
;;
;; `quarry-build-module' is the interactive, asynchronous variant.

;;; Code:

(defgroup quarry nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "quarry-")

(defcustom quarry-build-cargo-program "cargo"
  "Program that builds the quarry module (`cargo build --release')."
  :type 'string
  :group 'quarry)

(defconst quarry-build--file (or load-file-name buffer-file-name)
  "File this library was loaded from, or nil.")

(defconst quarry-build--buffer "*quarry-build*"
  "Name of the buffer that receives the build output.")

(defconst quarry-build--hint
  "run M-x quarry-build-module later"
  "What to do after a failed automatic build.")

(defun quarry-build--find-repo ()
  "Return the repository root as a directory name, or nil.
It is the parent of the directory of the true name of this file (its .el
sibling when loaded from a .elc), so the build tree is the one this file
belongs to even when another quarry.el is on `load-path'.  When that is
unknown, it is the parent of the directory of the true name of quarry.el
on `load-path'.  The root need not contain Cargo.toml."
  (let* ((own (and quarry-build--file
                   (if (string-suffix-p ".elc" quarry-build--file)
                       (substring quarry-build--file 0 -1)
                     quarry-build--file)))
         (lib (or (and own (file-exists-p own) (file-truename own))
                  (let ((found (locate-library "quarry.el" t)))
                    (and found (file-truename found))))))
    (and lib
         (file-name-directory
          (directory-file-name (file-name-directory lib))))))

(defun quarry-build--repo ()
  "Return the repository root, which holds Cargo.toml.
Signal a `user-error' when there is none."
  (let ((repo (quarry-build--find-repo)))
    (unless (and repo (file-exists-p (expand-file-name "Cargo.toml" repo)))
      (user-error "quarry source not found (installed without its repository?); install the module by hand, see the README"))
    repo))

(defun quarry-build--module-file (repo)
  "Return the file the module is installed as in REPO."
  (expand-file-name (concat "lisp/quarry-module" module-file-suffix) repo))

(defun quarry-build--library (repo)
  "Return the file `cargo build --release' produces in REPO."
  (expand-file-name
   (concat "target/release/"
           (pcase system-type
             ('darwin "libquarry.dylib")
             ('windows-nt "quarry.dll")
             (_ "libquarry.so")))
   repo))

(defun quarry-build--arguments (repo)
  "Return the arguments of the cargo command that builds REPO.
The target directory is explicit, so neither CARGO_TARGET_DIR nor the
cargo configuration can move the library from `quarry-build--library'."
  (list "build" "--release" "--target-dir"
        (expand-file-name "target" repo)))

(defun quarry-build--install (repo)
  "Install the library built in REPO as its module file.
The copy goes to a temporary file first and replaces the module file by
rename, so an Emacs that has the old module loaded keeps a valid file."
  (let* ((library (quarry-build--library repo))
         (target (quarry-build--module-file repo))
         (temp (progn
                 (unless (file-exists-p library)
                   (user-error "Cargo produced no %s" library))
                 (make-temp-file
                  (expand-file-name "quarry-module.tmp-" (file-name-directory target))
                  nil module-file-suffix))))
    (condition-case err
        (progn (copy-file library temp t)
               (set-file-modes temp #o755)
               (rename-file temp target t))
      (error (ignore-errors (delete-file temp))
             (signal (car err) (cdr err))))
    target))

(defun quarry-build--loaded-p ()
  "Return non-nil when a quarry module is loaded in this Emacs."
  (or (featurep 'quarry-module)
      (and (boundp 'emrs--modules) (hash-table-p emrs--modules)
           (gethash 'quarry emrs--modules)
           t)))

(defun quarry-build--program ()
  "Return the full name of the cargo program, or signal a `user-error'."
  (or (executable-find quarry-build-cargo-program)
      (user-error "Program `%s' not found; install Rust or set `quarry-build-cargo-program'"
                  quarry-build-cargo-program)))

(defun quarry-build--finish (repo success)
  "Install the library of REPO when SUCCESS and report the result."
  (if (not success)
      (message "quarry module build failed (see %s)" quarry-build--buffer)
    (condition-case err
        (progn (quarry-build--install repo)
               (message (if (quarry-build--loaded-p)
                            "quarry module built; restart Emacs to use it"
                          "quarry module built")))
      (error (message "quarry module build failed: %s" (error-message-string err))
             (setq success nil))))
  success)

;;;###autoload
(defun quarry-build-module ()
  "Build the quarry module with cargo, asynchronously.
The output goes to the buffer `*quarry-build*'.  On success the module
is installed next to quarry.el; a running Emacs needs a restart to use
a rebuilt module.  Recompiling in that buffer installs as well.  Return
the build process."
  (interactive)
  (when (get-buffer-process quarry-build--buffer)
    (user-error "The quarry module is being built (see %s)" quarry-build--buffer))
  (let* ((repo (quarry-build--repo))
         (program (quarry-build--program))
         (default-directory repo)
         (buffer (compilation-start
                  (mapconcat #'shell-quote-argument
                             (cons program (quarry-build--arguments repo)) " ")
                  'compilation-mode
                  (lambda (_mode) quarry-build--buffer))))
    (get-buffer-process buffer)))

(defun quarry-build--compilation-finished (buffer message)
  "Install the module when the build in BUFFER ended with MESSAGE.
Meant for `compilation-finish-functions'; it ignores other buffers."
  (when (equal (buffer-name buffer) quarry-build--buffer)
    (quarry-build--finish
     (buffer-local-value 'default-directory buffer)
     (equal message "finished\n"))))

(add-hook 'compilation-finish-functions #'quarry-build--compilation-finished)

(defun quarry-build--output-tail (&optional lines)
  "Return the last LINES (default 30) lines of the build buffer."
  (with-current-buffer quarry-build--buffer
    (save-excursion
      (goto-char (point-max))
      (forward-line (- (or lines 30)))
      (string-trim (buffer-substring-no-properties (point) (point-max))))))

;;;###autoload
(defun quarry-build-module-sync ()
  "Build the quarry module with cargo, waiting for it to finish.
Never signal: a failure becomes a warning.  In batch mode the warning
includes the end of the build output, which is lost with the process.
Return non-nil on success."
  (condition-case err
      (let* ((repo (quarry-build--repo))
             (program (quarry-build--program))
             (default-directory repo)
             (buffer (get-buffer-create quarry-build--buffer))
             status)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)))
        (setq status (apply #'call-process program nil buffer nil
                            (quarry-build--arguments repo)))
        (unless (eql status 0)
          (if noninteractive
              (error "The build failed:\n%s" (quarry-build--output-tail))
            (error "The build failed (see %s)" quarry-build--buffer)))
        (quarry-build--install repo)
        (message "quarry module built")
        t)
    (error
     (display-warning
      'quarry (format "Cannot build the module: %s; %s"
                      (error-message-string err) quarry-build--hint))
     nil)))

(provide 'quarry-build)
;;; quarry-build.el ends here
