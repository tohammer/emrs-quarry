;;; replace-bench.el --- Benchmark of grep replace on large change sets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The quarry authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Driver of `bench/run-bench.sh replace'; not part of the package.  For
;; `emacs --batch': `quarry-replace-bench-run' generates a tree of source
;; like files, searches it with a replacement template (time until the
;; preview is complete), applies the replacement (time of
;; `quarry-grep--apply' alone, without prompts) and verifies every file.
;; The tree is removed afterwards.  It prints one RESULT line.

;;; Code:

(require 'cl-lib)
(require 'quarry)
(require 'quarry-grep)

(defconst quarry-replace-bench--sizes
  '(("1k-5"    :files 1000  :matches 5   :min-lines 50)
    ("10k-5"   :files 10000 :matches 5   :min-lines 50)
    ("1k-100k" :files 1000  :matches 100 :min-lines 100))
  "Cases: label and plist.
:matches are the matched lines per file, one match on each; the files have
:min-lines to :min-lines + 100 lines.")

(defun quarry-replace-bench--content (index matches min-lines word)
  "Return the text of file INDEX, with MATCHES matched lines using WORD.
The file has MIN-LINES to MIN-LINES+100 lines; the matched lines are
spread evenly through it."
  (let* ((lines (+ min-lines (% (* index 37) 101)))
         (step (/ lines matches))
         (shift (% index step))
         (marks (make-hash-table :test 'eql))
         (out nil))
    (dotimes (k matches)
      (puthash (+ (/ (* k lines) matches) shift) k marks))
    (dotimes (n lines)
      (let ((k (gethash n marks)))
        (push (if k
                  (format "    int v%d = %s_fn_%d_%d(ctx, %d);\n" n word index k n)
                (format "    x = compute(a, b + %d);  // file %d line %d\n" n index n))
              out)))
    (apply #'concat (nreverse out))))

(defun quarry-replace-bench--generate (dir count matches min-lines)
  "Write COUNT files into DIR, in 100 subdirectories."
  (dotimes (i count)
    (let ((file (format "%s/d%02d/f%05d.c" dir (% i 100) i)))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (quarry-replace-bench--content i matches min-lines "old")
                      nil file nil 'silent)))))

(defun quarry-replace-bench--wait ()
  "Wait until the search of the result buffer has ended."
  (let ((deadline (+ (float-time) 1200)))
    (while (and (eq (buffer-local-value 'quarry-grep--state
                                        (get-buffer quarry-grep-buffer-name))
                    'running)
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (when (eq (buffer-local-value 'quarry-grep--state (get-buffer quarry-grep-buffer-name))
              'running)
      (error "Search did not end"))
    (set-buffer (get-buffer quarry-grep-buffer-name))))

(defun quarry-replace-bench--verify (dir count matches min-lines)
  "Return a string describing the result in DIR: remaining old matches, bad files."
  (let ((old 0) (bad 0))
    (dotimes (i count)
      (let ((file (format "%s/d%02d/f%05d.c" dir (% i 100) i))
            (expected (quarry-replace-bench--content i matches min-lines "new")))
        (with-temp-buffer
          (insert-file-contents file)
          (let ((text (buffer-string)))
            (goto-char (point-min))
            (while (search-forward "old_fn_" nil t)
              (cl-incf old))
            (unless (equal text expected)
              (cl-incf bad))))))
    (list old bad)))

(defun quarry-replace-bench--machine (dir)
  "Print facts about the machine and DIR."
  (let ((model (with-temp-buffer
                 (insert-file-contents "/proc/cpuinfo")
                 (if (re-search-forward "^model name[ \t]*: \\(.*\\)$" nil t)
                     (match-string 1)
                   "unknown")))
        (fs (ignore-errors
              (car (last (process-lines "df" "--output=fstype" dir))))))
    (princ (format "Emacs %s, %s cores, %s; tree on %s (%s)\n"
                   emacs-version (or (ignore-errors (car (process-lines "nproc"))) "?")
                   model dir (or fs "?")))))

(defun quarry-replace-bench-run ()
  "Run one case from the command line: LABEL TMPDIR."
  (pcase-let ((`(,label ,tmp) command-line-args-left))
    (setq command-line-args-left nil)
    (let* ((spec (cdr (assoc label quarry-replace-bench--sizes)))
           (count (plist-get spec :files))
           (matches (plist-get spec :matches))
           (min-lines (plist-get spec :min-lines))
           (dir (file-name-as-directory (expand-file-name (concat "tree-" label) tmp)))
           (make-backup-files nil)
           (quarry-grep-max-lines 200000)
           (gc-cons-threshold gc-cons-threshold))
      (unless spec (error "Unknown case %s" label))
      (unwind-protect
          (progn
            (make-directory dir t)
            (let ((start (float-time)))
              (quarry-replace-bench--generate dir count matches min-lines)
              (princ (format "[%s] generated %d files in %.1f s\n" label count
                             (- (float-time) start))))
            (when (equal label "1k-5") (quarry-replace-bench--machine dir))
            (let ((start (float-time)) search-s work-s apply-s)
              (quarry-grep--start-search
               (quarry-grep--make-search
                :dir dir
                :filters (list (quarry-grep--make-filter
                                :pattern "old_fn_([0-9]+)_([0-9]+)" :regexp t))
                :replace "new_fn_${1}_${2}"))
              (quarry-replace-bench--wait)
              (setq search-s (- (float-time) start))
              (unless (and (= quarry-grep--files count)
                           (= quarry-grep--replace-on (* count matches)))
                (error "Preview wrong: %S files, %S matches on"
                       quarry-grep--files quarry-grep--replace-on))
              (setq start (float-time))
              (let ((work (quarry-grep--replace-work)))
                (setq work-s (- (float-time) start))
                (setq start (float-time))
                (quarry-grep--apply work)
                (setq apply-s (- (float-time) start)))
              (pcase-let ((`(,old ,bad) (quarry-replace-bench--verify
                                         dir count matches min-lines)))
                (princ (format "[%s] applied: %S; old matches left %d, files differing %d\n"
                               label quarry-grep--replace-applied old bad))
                (princ (format "RESULT %s files=%d matches=%d preview=%.2fs work=%.2fs apply=%.2fs verified=%s\n"
                               label count (* count matches) search-s work-s apply-s
                               (if (and (zerop old) (zerop bad)) "ok" "FAILED")))
                (kill-emacs (if (and (zerop old) (zerop bad)) 0 1)))))
        (ignore-errors (quarry-stop-all))
        (delete-directory dir t)))))

(provide 'replace-bench)
;;; replace-bench.el ends here
