;;; quarry-grep-wgrep-tests.el --- ERT suite for editing quarry-grep results  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh, which loads tests/quarry-tests.el and
;; tests/quarry-grep-tests.el first; their helpers are used here.  The
;; tests that edit are skipped when wgrep is not on `load-path' (see
;; QUARRY_TEST_LOAD_PATH in run-ert.sh).

;;; Code:

(require 'ert)
(require 'quarry-grep-tests)
(require 'wgrep nil t)

(defvar wgrep-mode-map)
(defvar wgrep-auto-save-buffer)

(defconst quarry-test-grep-wgrep--files
  `(("one.txt" . "first line\nan apple here\nthird line\nan apple there\nlast line\n")
    ("two/two.txt" . "apple pie\nno fruit\n")
    ("long.txt" . ,(concat "apple " (make-string 60 ?x) " end\n"))
    ("bytes.txt" . ,(unibyte-string ?a ?p ?p ?l ?e ?\s #xff ?\s ?x ?\n)))
  "The tree the edit tests search for `apple' with `quarry-grep-max-columns' 40.
The line of long.txt is cut and the one of bytes.txt is not valid UTF-8.")

(defun quarry-test-grep-wgrep--p ()
  "Return non-nil when wgrep is loaded."
  (featurep 'wgrep))

(defmacro quarry-test-grep-wgrep--with-results (dir &rest body)
  "Search a tree bound to DIR for `apple' and run BODY in the result buffer."
  (declare (indent 1))
  `(quarry-test-grep--with-tree (,dir (let ((coding-system-for-write 'no-conversion))
                                         quarry-test-grep-wgrep--files))
     (let ((quarry-grep-max-columns 40)
           (wgrep-auto-save-buffer nil))
       (ignore wgrep-auto-save-buffer)
       (quarry-test-grep--search ,dir "apple")
       (pop-to-buffer-same-window (quarry-test-grep--buffer))
       ,@body)))

(defmacro quarry-test-grep-wgrep--answering (answer &rest body)
  "Run BODY with `y-or-n-p' giving ANSWER; return the questions asked."
  (declare (indent 1))
  `(let ((asked nil))
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt asked) ,answer)))
       ,@body)
     (nreverse asked)))

(defun quarry-test-grep-wgrep--enter ()
  "Press e in the result buffer; check that nothing was asked and edit mode is on."
  (pop-to-buffer-same-window (quarry-test-grep--buffer))
  (should-not (quarry-test-grep-wgrep--answering nil (execute-kbd-macro (kbd "e"))))
  (should (eq (current-local-map) wgrep-mode-map))
  (should-not buffer-read-only))

(defun quarry-test-grep-wgrep--replace (path line old new)
  "In the result line LINE of PATH replace the text OLD with NEW."
  (goto-char (quarry-test-grep--line-pos path line))
  (search-forward old (pos-eol))
  (replace-match new t t))

(defun quarry-test-grep-wgrep--file (dir path)
  "Return the content of the file PATH of DIR on disk."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path dir))
    (buffer-string)))

(defun quarry-test-grep-wgrep--working ()
  "Check that the current buffer is a working result buffer."
  (should (eq major-mode 'quarry-grep-mode))
  (should (eq (current-local-map) quarry-grep-mode-map))
  (should buffer-read-only)
  (should-not quarry-grep--editing)
  (should (eq buffer-undo-list t))
  (should-not (memq 'quarry-grep--edit-sync post-command-hook))
  ;; Nothing of wgrep is left in the text.
  (dolist (property '(read-only rear-nonsticky front-sticky wgrep-header wgrep-footer wgrep-ignore
                                wgrep-line-filename wgrep-line-number))
    (should-not (text-property-not-all (point-min) (point-max) property nil)))
  ;; The status line is where the marker says, and last.
  (should (= quarry-grep--status-marker
             (text-property-any (point-min) (point-max) 'quarry-grep-status t)))
  (quarry-test-grep--status)
  ;; Lines respond to the mouse again, and each block is one piece.
  (dolist (bol (append (quarry-test-grep--lines-with 'quarry-grep-line)
                       (quarry-test-grep--lines-with 'quarry-grep-heading)
                       (quarry-test-grep--lines-with 'quarry-grep-filter)))
    (should (eq (get-text-property bol 'follow-link) t)))
  (should (equal (mapcar (lambda (block) (get-text-property (car block) 'quarry-grep-file))
                         (quarry-grep--blocks))
                 (quarry-test-grep--headings)))
  (dolist (block (quarry-grep--blocks))
    (should (get-text-property (car block) 'quarry-grep-heading))
    (should (get-text-property (cdr block) 'quarry-grep-separator))))

;;;; Without wgrep

(ert-deftest quarry-test-grep-wgrep-refusals ()
  "e is refused while a search runs, without results and without wgrep."
  (quarry-test-grep--with-tree (dir)
    ;; While a search runs.
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (quarry-test-grep--refused "A search is running" (execute-kbd-macro (kbd "e")))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
      ;; Without results.
      (quarry-test-grep--refused "no results to edit" (execute-kbd-macro (kbd "e"))))
    ;; Without wgrep: the package is named.
    (quarry-test-grep--search dir)
    (let ((require (symbol-function 'require)))
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &rest args)
                   (and (not (eq feature 'wgrep)) (apply require feature args)))))
        (quarry-test-grep--refused "needs the package wgrep"
          (execute-kbd-macro (kbd "e")))))
    (should (eq (current-local-map) quarry-grep-mode-map))
    (should buffer-read-only)
    (should-not quarry-grep--editing)))

;;;; Editing

(ert-deftest quarry-test-grep-wgrep-commit ()
  "Edited lines reach the file buffers on commit and the files when saved."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (should (equal (quarry-test-grep--results)
                   '(("bytes.txt" 1 "apple � x")
                     ("long.txt" 1 "apple xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
                     ("one.txt" 2 "an apple here")
                     ("one.txt" 4 "an apple there")
                     ("two/two.txt" 1 "apple pie"))))
    (quarry-test-grep-wgrep--enter)
    ;; wgrep's own keys; ours are gone, also C-c C-k as cancel.
    (should (eq (key-binding (kbd "C-c C-c")) 'wgrep-finish-edit))
    (should (eq (key-binding (kbd "C-c C-k")) 'wgrep-abort-changes))
    (dolist (key '("g" "k" "e" "n" "q" "RET" "TAB" "- p"))
      (should-not (string-prefix-p "quarry-grep" (format "%s" (key-binding (kbd key))))))
    ;; Two edits in two files, typed.
    (goto-char (quarry-test-grep--line-pos "one.txt" 4))
    (search-forward "apple")
    (execute-kbd-macro (kbd "DEL DEL DEL DEL DEL p e a r"))
    (quarry-test-grep-wgrep--replace "two/two.txt" 1 "pie" "cake")
    (should (eq (current-local-map) wgrep-mode-map))
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    ;; The result lines show the edited text and are still result lines.
    (should (equal (quarry-test-grep--results)
                   '(("bytes.txt" 1 "apple � x")
                     ("long.txt" 1 "apple xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
                     ("one.txt" 2 "an apple here")
                     ("one.txt" 4 "an pear there")
                     ("two/two.txt" 1 "apple cake"))))
    (should (string-match-p "\\`Search finished: 5 lines in 4 files, [0-9]+ ms\nThe results were edited; g searches again\\'"
                            (quarry-test-grep--status)))
    ;; In the file buffers, not yet on disk.
    (let ((one (get-file-buffer (expand-file-name "one.txt" dir)))
          (two (get-file-buffer (expand-file-name "two/two.txt" dir))))
      (should (buffer-modified-p one))
      (should (buffer-modified-p two))
      (should (equal (with-current-buffer one (buffer-string))
                     "first line\nan apple here\nthird line\nan pear there\nlast line\n"))
      (should (equal (with-current-buffer two (buffer-string)) "apple cake\nno fruit\n"))
      (should (equal (quarry-test-grep-wgrep--file dir "two/two.txt") "apple pie\nno fruit\n"))
      (with-current-buffer one (save-buffer))
      (with-current-buffer two (save-buffer))
      (should (equal (quarry-test-grep-wgrep--file dir "one.txt")
                     "first line\nan apple here\nthird line\nan pear there\nlast line\n"))
      (should (equal (quarry-test-grep-wgrep--file dir "two/two.txt") "apple cake\nno fruit\n")))
    ;; The buffer works: visit the edited line, fold, a filter, g.
    (goto-char (quarry-test-grep--line-pos "one.txt" 4))
    (end-of-line)
    (quarry-test-grep--keys "RET")
    (should (equal (buffer-file-name (window-buffer)) (expand-file-name "one.txt" dir)))
    (should (= (with-current-buffer (window-buffer) (line-number-at-pos)) 4))
    (pop-to-buffer-same-window (quarry-test-grep--buffer))
    (goto-char (quarry-test-grep--line-pos "one.txt" 4))
    (quarry-test-grep--keys "TAB")
    (should (quarry-test-grep--hidden-p "one.txt" 2))
    (should (quarry-test-grep--hidden-p "one.txt" 4))
    (should-not (quarry-test-grep--hidden-p "two/two.txt" 1))
    (quarry-test-grep--keys "- l cake RET")
    (should (equal (quarry-test-grep--headings) '("bytes.txt" "long.txt" "one.txt")))
    ;; A new search forgets the edit.
    (should (string-match-p "\\`Search finished: 3 lines in 3 files, [0-9]+ ms\\'"
                            (quarry-test-grep--status)))
    (should-not (cl-some (lambda (overlay) (overlay-get overlay 'wgrep))
                         (overlays-in (point-min) (point-max))))
    (quarry-test-grep--keys "g")
    (should (equal (quarry-test-grep--results)
                   '(("bytes.txt" 1 "apple � x")
                     ("long.txt" 1 "apple xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
                     ("one.txt" 2 "an apple here"))))))

(ert-deftest quarry-test-grep-wgrep-abort ()
  "An abort leaves the files alone and restores the buffer's text."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (let ((before (buffer-string))
          (results (quarry-test-grep--results)))
      (quarry-test-grep-wgrep--enter)
      (quarry-test-grep-wgrep--replace "one.txt" 2 "apple" "plum")
      (quarry-test-grep-wgrep--replace "two/two.txt" 1 "pie" "cake")
      (should (member '("one.txt" 2 "an plum here") (quarry-test-grep--results)))
      (execute-kbd-macro (kbd "C-c C-k"))
      (quarry-test-grep-wgrep--working)
      (should (equal (buffer-string) before))
      (should (equal (quarry-test-grep--results) results))
      (should (string-match-p "\\`Search finished: 5 lines in 4 files, [0-9]+ ms\\'"
                              (quarry-test-grep--status)))
      (should-not (get-file-buffer (expand-file-name "one.txt" dir)))
      (should (equal (quarry-test-grep-wgrep--file dir "one.txt")
                     "first line\nan apple here\nthird line\nan apple there\nlast line\n"))
      (should (equal (quarry-test-grep-wgrep--file dir "two/two.txt") "apple pie\nno fruit\n"))
      ;; The buffer works: results arrive before the status line again.
      (goto-char (quarry-test-grep--line-pos "one.txt" 2))
      (quarry-test-grep--keys "RET")
      (should (equal (buffer-file-name (window-buffer)) (expand-file-name "one.txt" dir)))
      (pop-to-buffer-same-window (quarry-test-grep--buffer))
      (goto-char (quarry-test-grep--heading-pos "two/two.txt"))
      (quarry-test-grep--keys "TAB")
      (should (quarry-test-grep--hidden-p "two/two.txt" 1))
      (quarry-test-grep--keys "g")
      (should (equal (quarry-test-grep--results) results))
      (quarry-test-grep--keys "+ l pie RET")
      (should (equal (quarry-test-grep--results) '(("two/two.txt" 1 "apple pie"))))
      ;; And it can be edited again.
      (quarry-test-grep-wgrep--enter)
      (quarry-test-grep-wgrep--replace "two/two.txt" 1 "pie" "tart")
      (execute-kbd-macro (kbd "C-c C-c"))
      (quarry-test-grep-wgrep--working)
      (should (equal (with-current-buffer (get-file-buffer (expand-file-name "two/two.txt" dir))
                       (buffer-string))
                     "apple tart\nno fruit\n")))))

(ert-deftest quarry-test-grep-wgrep-not-editable ()
  "Filter lines, headings, the status line and inexact lines are read-only."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (should (get-text-property (quarry-test-grep--line-pos "long.txt" 1) 'quarry-grep-inexact))
    (should (get-text-property (quarry-test-grep--line-pos "bytes.txt" 1) 'quarry-grep-inexact))
    (let ((bytes (quarry-test-grep-wgrep--file dir "bytes.txt"))
          (long (quarry-test-grep-wgrep--file dir "long.txt")))
      (quarry-test-grep-wgrep--enter)
      (let ((before (buffer-string))
            (text-of (lambda (bol)
                       (next-single-property-change bol 'quarry-grep-prefix))))
        (dolist (place (list
                        ;; The filter line and the empty line after it.
                        (point-min) (+ (point-min) 4)
                        (1- (quarry-test-grep--heading-pos "bytes.txt"))
                        ;; A heading, its start and its path.
                        (quarry-test-grep--heading-pos "one.txt")
                        (+ (quarry-test-grep--heading-pos "one.txt") 8)
                        ;; The number of a result line.
                        (quarry-test-grep--line-pos "one.txt" 2)
                        (1+ (quarry-test-grep--line-pos "one.txt" 2))
                        ;; The lines that are not the file's text.
                        (funcall text-of (quarry-test-grep--line-pos "long.txt" 1))
                        (+ 3 (funcall text-of (quarry-test-grep--line-pos "long.txt" 1)))
                        (+ 3 (funcall text-of (quarry-test-grep--line-pos "bytes.txt" 1)))
                        ;; The empty line between two files.
                        (1- (quarry-test-grep--heading-pos "two/two.txt"))
                        ;; The status line.
                        (marker-position quarry-grep--status-marker)
                        (+ 5 quarry-grep--status-marker)))
          (goto-char place)
          (should-error (insert "x") :type 'text-read-only)
          (should-error (delete-char 1) :type 'text-read-only))
        ;; Lines cannot be joined.
        (goto-char (quarry-test-grep--line-pos "one.txt" 2))
        (end-of-line)
        (should-error (delete-char 1) :type 'text-read-only)
        (goto-char (quarry-test-grep--line-pos "two/two.txt" 1))
        (end-of-line)
        (should-error (delete-char 1) :type 'text-read-only)
        (should (equal (buffer-string) before))
        ;; wgrep knows nothing of the inexact lines, so even its switch
        ;; that opens everything for editing cannot write them back.
        (execute-kbd-macro (kbd "C-c C-p"))
        (quarry-test-grep-wgrep--replace "long.txt" 1 "apple" "pear")
        (quarry-test-grep-wgrep--replace "bytes.txt" 1 "apple" "pear")
        (quarry-test-grep-wgrep--replace "one.txt" 2 "apple" "pear")
        (execute-kbd-macro (kbd "C-c C-c"))
        (quarry-test-grep-wgrep--working)
        (should (equal (quarry-test-grep-wgrep--file dir "bytes.txt") bytes))
        (should (equal (quarry-test-grep-wgrep--file dir "long.txt") long))
        (should-not (get-file-buffer (expand-file-name "bytes.txt" dir)))
        (should-not (get-file-buffer (expand-file-name "long.txt" dir)))
        (should (equal (with-current-buffer (get-file-buffer (expand-file-name "one.txt" dir))
                         (buffer-string))
                       "first line\nan pear here\nthird line\nan apple there\nlast line\n"))))))

(ert-deftest quarry-test-grep-wgrep-added-line ()
  "A line added by an edit does not shift a later edit in the same file."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (quarry-test-grep-wgrep--enter)
    (quarry-test-grep-wgrep--replace "one.txt" 2 "apple" "apple\nand a pear")
    (quarry-test-grep-wgrep--replace "one.txt" 4 "there" "elsewhere")
    (execute-kbd-macro (kbd "C-c C-c"))
    (should (equal (with-current-buffer (get-file-buffer (expand-file-name "one.txt" dir))
                     (buffer-string))
                   "first line\nan apple\nand a pear here\nthird line\nan apple elsewhere\nlast line\n"))
    ;; The added line belongs to its block; the buffer still works.
    (quarry-test-grep-wgrep--working)
    (should (= (length (quarry-grep--blocks)) 4))
    (goto-char (quarry-test-grep--line-pos "one.txt" 4))
    (forward-line -1)
    (should (equal (get-text-property (point) 'quarry-grep-file) "one.txt"))
    (should-not (get-text-property (point) 'quarry-grep-line))
    (quarry-test-grep--keys "TAB")
    (should (quarry-test-grep--hidden-p "one.txt" 4))
    (should-not (quarry-test-grep--hidden-p "two/two.txt" 1))
    (with-current-buffer (get-file-buffer (expand-file-name "one.txt" dir))
      (save-buffer))
    (quarry-test-grep--keys "g")
    (should (equal (seq-filter (lambda (result) (equal (car result) "one.txt"))
                               (quarry-test-grep--results))
                   '(("one.txt" 2 "an apple") ("one.txt" 5 "an apple elsewhere"))))))

(ert-deftest quarry-test-grep-wgrep-changed-file-is-rejected ()
  "wgrep does not apply an edit to a line that is not as it was found."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (with-current-buffer (find-file-noselect (expand-file-name "one.txt" dir))
      (goto-char (point-min))
      (insert "a new first line\n"))
    (should (= (length (quarry-test-grep-wgrep--answering nil
                         (execute-kbd-macro (kbd "e"))))
               1))
    (should (eq (current-local-map) wgrep-mode-map))
    (quarry-test-grep-wgrep--replace "one.txt" 2 "apple" "pear")
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    (should (equal (with-current-buffer (get-file-buffer (expand-file-name "one.txt" dir))
                     (buffer-string))
                   "a new first line\nfirst line\nan apple here\nthird line\nan apple there\nlast line\n"))))

(ert-deftest quarry-test-grep-wgrep-unfolds ()
  "Entering edit mode unfolds all file blocks."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (quarry-grep-toggle-fold-all)
    (should (quarry-test-grep--hidden-p "one.txt" 2))
    (quarry-test-grep-wgrep--enter)
    (dolist (result (quarry-test-grep--results))
      (should-not (quarry-test-grep--hidden-p (nth 0 result) (nth 1 result))))
    (execute-kbd-macro (kbd "C-c C-k"))
    (quarry-test-grep-wgrep--working)))

(ert-deftest quarry-test-grep-wgrep-no-search-while-editing ()
  "A search cannot start in a buffer that is being edited."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (quarry-test-grep-wgrep--enter)
    (quarry-test-grep-wgrep--replace "one.txt" 2 "apple" "plum")
    (let ((text (buffer-string))
          (place (point))
          (sent (length quarry-test-grep--requests)))
      (dolist (call (list #'quarry-grep-rerun
                          #'revert-buffer
                          #'quarry-grep-cycle-case
                          #'quarry-grep-toggle-ignore
                          #'quarry-grep-history-back
                          #'quarry-grep-remove-other-filters
                          #'quarry-grep-edit
                          (lambda () (quarry-grep "apple" nil dir))
                          (lambda () (quarry-grep-literal "apple" nil dir))
                          (lambda () (quarry-grep-project "apple" nil))
                          ;; From another buffer: refused before anything
                          ;; is asked.
                          (lambda ()
                            (with-temp-buffer
                              (insert "symbol")
                              (setq default-directory dir)
                              (quarry-grep-dwim)))
                          (lambda ()
                            (let ((prompts nil))
                              (unwind-protect
                                  (with-temp-buffer
                                    (setq default-directory dir)
                                    (save-window-excursion
                                      (switch-to-buffer (current-buffer))
                                      (let ((minibuffer-setup-hook
                                             (cons (lambda ()
                                                     (push (minibuffer-prompt) prompts))
                                                   minibuffer-setup-hook)))
                                        (execute-kbd-macro
                                         (kbd "M-x quarry-grep RET apple RET RET RET")))))
                                (should (equal prompts '("M-x "))))))
                          ;; A click on the header line.
                          (lambda ()
                            (let ((header (quarry-grep--header)))
                              (funcall (lookup-key
                                        (get-text-property (string-search "smart" header)
                                                           'keymap header)
                                        [header-line mouse-1])
                                       (list 'mouse-1 (list (selected-window) 'header-line
                                                            '(0 . 0) 0)))))))
        (set-buffer (quarry-test-grep--buffer))
        (let ((err (should-error (funcall call) :type 'user-error)))
          (should (string-match-p "being edited" (cadr err)))))
      (set-buffer (quarry-test-grep--buffer))
      (should (= (length quarry-test-grep--requests) sent))
      (should (equal (buffer-string) text))
      (should (= (point) place))
      (should (eq (current-local-map) wgrep-mode-map)))
    ;; Edit mode ended from Lisp, where no command loop notices it: the
    ;; next command of the mode puts the buffer in order first.
    (wgrep-abort-changes)
    (should quarry-grep--editing)
    (quarry-grep-rerun)
    (quarry-test-grep--wait)
    (quarry-test-grep-wgrep--working)
    (should (member '("one.txt" 2 "an apple here") (quarry-test-grep--results)))))

(ert-deftest quarry-test-grep-wgrep-commit-while-narrowed ()
  "A commit from a narrowed buffer restores the whole buffer."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (quarry-test-grep-wgrep--enter)
    (let ((bol (quarry-test-grep--line-pos "one.txt" 2)))
      (narrow-to-region bol (save-excursion (goto-char bol) (pos-eol)))
      (goto-char (point-min))
      (search-forward "apple")
      (replace-match "pear" t t)
      (execute-kbd-macro (kbd "C-c C-c"))
      (should (buffer-narrowed-p))
      (widen)
      (quarry-test-grep-wgrep--working)
      (should (member '("one.txt" 2 "an pear here") (quarry-test-grep--results)))
      (should (string-match-p "The results were edited" (quarry-test-grep--status)))
      (should (= (length (quarry-test-grep--lines-with 'quarry-grep-status)) 2)))
    ;; Narrowed when e is pressed: wgrep gets the whole buffer.
    (narrow-to-region (quarry-test-grep--line-pos "two/two.txt" 1) (point-max))
    (quarry-test-grep-wgrep--answering nil (execute-kbd-macro (kbd "e")))
    (should (eq (current-local-map) wgrep-mode-map))
    (should-not (buffer-narrowed-p))
    (goto-char (point-min))
    (should-error (insert "x") :type 'text-read-only)
    (quarry-test-grep-wgrep--replace "two/two.txt" 1 "pie" "cake")
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    (should (equal (with-current-buffer (get-file-buffer (expand-file-name "two/two.txt" dir))
                     (buffer-string))
                   "apple cake\nno fruit\n"))))

;;;; Context lines

(defmacro quarry-test-grep-wgrep--with-context (dir &rest body)
  "Search the tree of DIR for `needle' with one line of context; run BODY.
The tree is `quarry-test-grep--context-files': ctx.txt has a gap."
  (declare (indent 1))
  `(quarry-test-grep--with-tree (,dir quarry-test-grep--context-files)
     (let ((quarry-grep-context-before 1)
           (quarry-grep-context-after 1)
           (wgrep-auto-save-buffer nil))
       (ignore wgrep-auto-save-buffer)
       (quarry-test-grep--search ,dir)
       (pop-to-buffer-same-window (quarry-test-grep--buffer))
       ,@body)))

(defun quarry-test-grep-wgrep--gap-pos ()
  "Return the start of the gap line of ctx.txt."
  (let ((gaps (quarry-test-grep--lines-with 'quarry-grep-gap)))
    (should (= (length gaps) 1))
    (car gaps)))

(defun quarry-test-grep-wgrep--context-kept ()
  "Check the context and gap lines of ctx.txt after edit mode."
  (should (equal (quarry-test-grep--layout "ctx.txt")
                 '((context 2) (hit 3) (context 4) gap
                   (context 8) (hit 9) (context 10))))
  (dolist (n '(2 4 8 10))
    (let* ((bol (quarry-test-grep--line-pos "ctx.txt" n))
           (eol (save-excursion (goto-char bol) (pos-eol)))
           (text (next-single-property-change bol 'quarry-grep-prefix)))
      (should (eq (get-text-property (1- eol) 'quarry-grep-context) t))
      (should (get-text-property eol 'quarry-grep-context))
      (should (eq (get-text-property text 'face) 'quarry-grep-context))
      (should-not (get-text-property bol 'quarry-grep-column))))
  (should-not (get-text-property (quarry-test-grep--line-pos "ctx.txt" 3)
                                 'quarry-grep-context))
  (let ((gap (quarry-test-grep-wgrep--gap-pos)))
    (should (get-text-property gap 'quarry-grep-gap))
    (should (equal (get-text-property gap 'quarry-grep-file) "ctx.txt"))
    (should (eq (get-text-property (+ gap 4) 'face) 'quarry-grep-context))
    (should-not (get-text-property gap 'mouse-face))
    (should-not (get-text-property gap 'quarry-grep-line))
    (should-not (get-text-property gap 'quarry-grep-context)))
  ;; A pass with n over the hits does not stop at a context line.
  (goto-char (point-min))
  (let ((seen nil))
    (condition-case nil
        (while t
          (quarry-grep-next-match)
          (push (get-text-property (point) 'quarry-grep-line) seen))
      (user-error nil))
    (should (equal (nreverse seen) '(3 9 2)))))

(ert-deftest quarry-test-grep-wgrep-context-commit ()
  "An edited context line reaches the file; the gap and the context stay."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-context dir
    (quarry-test-grep-wgrep--enter)
    (quarry-test-grep-wgrep--replace "ctx.txt" 4 "l4" "four")
    (quarry-test-grep-wgrep--replace "ctx.txt" 8 "l8" "eight")
    (quarry-test-grep-wgrep--replace "ctx.txt" 9 "l9" "nine")
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    (should (equal (with-current-buffer
                       (get-file-buffer (expand-file-name "ctx.txt" dir))
                     (buffer-string))
                   "l1\nl2\nl3 needle\nfour\nl5\nl6\nl7\neight\nnine needle\nl10\nl11\nl12\n"))
    (should (equal (quarry-test-grep-wgrep--file dir "ctx.txt")
                   (cdr (assoc "ctx.txt" quarry-test-grep--context-files))))
    (should (equal (quarry-test-grep--line-text
                    (quarry-test-grep--line-pos "ctx.txt" 4))
                   "    4 four"))
    (quarry-test-grep-wgrep--context-kept)))

(ert-deftest quarry-test-grep-wgrep-context-abort ()
  "After an abort the context and gap lines are as they were."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-context dir
    (let ((before (buffer-string)))
      (quarry-test-grep-wgrep--enter)
      (quarry-test-grep-wgrep--replace "ctx.txt" 4 "l4" "four")
      (quarry-test-grep-wgrep--replace "ctx.txt" 9 "l9" "nine")
      (execute-kbd-macro (kbd "C-c C-k"))
      (quarry-test-grep-wgrep--working)
      (should (equal (buffer-string) before))
      (quarry-test-grep-wgrep--context-kept)
      (should (equal (quarry-test-grep-wgrep--file dir "ctx.txt")
                     (cdr (assoc "ctx.txt" quarry-test-grep--context-files)))))))

(ert-deftest quarry-test-grep-wgrep-gap-not-editable ()
  "The gap line cannot be changed, nor joined to the lines around it."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-context dir
    (quarry-test-grep-wgrep--enter)
    (let ((before (buffer-string))
          (gap (quarry-test-grep-wgrep--gap-pos)))
      (dolist (place (list gap (+ gap 2) (+ gap 4) (+ gap 6)))
        (goto-char place)
        (should-error (insert "x") :type 'text-read-only)
        (should-error (delete-char 1) :type 'text-read-only))
      (goto-char (1- gap))
      (should-error (delete-char 1) :type 'text-read-only)
      (should (equal (buffer-string) before)))
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    (quarry-test-grep-wgrep--context-kept)
    (should (equal (quarry-test-grep-wgrep--file dir "ctx.txt")
                   (cdr (assoc "ctx.txt" quarry-test-grep--context-files))))
    (let ((buffer (get-file-buffer (expand-file-name "ctx.txt" dir))))
      (should-not (and buffer (buffer-modified-p buffer))))))

(ert-deftest quarry-test-grep-wgrep-no-context-change-while-editing ()
  "C changes the search, which cannot be done while editing."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-context dir
    (quarry-test-grep-wgrep--enter)
    (let ((text (buffer-string))
          (sent (length quarry-test-grep--requests)))
      (dolist (call (list (lambda () (quarry-grep-set-context 2))
                          #'quarry-grep-set-context-before
                          #'quarry-grep-set-context-after))
        (let ((err (should-error (funcall call) :type 'user-error)))
          (should (string-match-p "being edited" (cadr err)))))
      (should (= (length quarry-test-grep--requests) sent))
      (should (equal (buffer-string) text))
      (should (eq (current-local-map) wgrep-mode-map)))
    (execute-kbd-macro (kbd "C-c C-k"))
    (quarry-test-grep-wgrep--working)))

(ert-deftest quarry-test-grep-wgrep-inexact-context-not-editable ()
  "A context line that was cut cannot be edited, and is intact after abort."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep--with-tree
      (dir '(("x.txt" . "a long context line\nneedle\nshort\n")))
    (let ((quarry-grep-max-columns 6)
          (quarry-grep-context-before 1)
          (quarry-grep-context-after 1)
          (wgrep-auto-save-buffer nil))
      (ignore wgrep-auto-save-buffer)
      (quarry-test-grep--search dir)
      (pop-to-buffer-same-window (quarry-test-grep--buffer))
      (let* ((cut (quarry-test-grep--line-pos "x.txt" 1))
             (before (buffer-string))
             (file (quarry-test-grep-wgrep--file dir "x.txt"))
             (text (next-single-property-change cut 'quarry-grep-prefix)))
        (should (get-text-property cut 'quarry-grep-inexact))
        (should (get-text-property cut 'quarry-grep-context))
        (should (equal (quarry-test-grep--line-text cut) "    1 a long"))
        (quarry-test-grep-wgrep--enter)
        (should-not (get-text-property cut 'wgrep-line-filename))
        (should (get-text-property (quarry-test-grep--line-pos "x.txt" 3)
                                   'wgrep-line-filename))
        (dolist (place (list text (+ text 3)
                             (save-excursion (goto-char cut) (pos-eol))))
          (goto-char place)
          (should-error (insert "x") :type 'text-read-only)
          (should-error (delete-char 1) :type 'text-read-only))
        (should (equal (buffer-string) before))
        ;; Even with everything opened for editing nothing is written back.
        (execute-kbd-macro (kbd "C-c C-p"))
        (quarry-test-grep-wgrep--replace "x.txt" 1 "long" "short")
        (execute-kbd-macro (kbd "C-c C-k"))
        (quarry-test-grep-wgrep--working)
        (should (equal (buffer-string) before))
        (should (get-text-property cut 'quarry-grep-inexact))
        (should (eq (get-text-property
                     (1- (save-excursion (goto-char cut) (pos-eol)))
                     'quarry-grep-context)
                    t))
        (should (equal (quarry-test-grep-wgrep--file dir "x.txt") file))
        (should-not (get-file-buffer (expand-file-name "x.txt" dir)))
        ;; The same on commit.
        (quarry-test-grep-wgrep--enter)
        (execute-kbd-macro (kbd "C-c C-p"))
        (quarry-test-grep-wgrep--replace "x.txt" 1 "long" "short")
        (execute-kbd-macro (kbd "C-c C-c"))
        (quarry-test-grep-wgrep--working)
        (should (equal (quarry-test-grep-wgrep--file dir "x.txt") file))
        (should-not (let ((buffer (get-file-buffer (expand-file-name "x.txt" dir))))
                      (and buffer (buffer-modified-p buffer))))))))

(ert-deftest quarry-test-grep-wgrep-added-line-in-context ()
  "A line added by an edit of a context line belongs to the block."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-context dir
    (quarry-test-grep-wgrep--enter)
    (quarry-test-grep-wgrep--replace "ctx.txt" 4 "l4" "four\nextra")
    (execute-kbd-macro (kbd "C-c C-c"))
    (quarry-test-grep-wgrep--working)
    (should (equal (with-current-buffer
                       (get-file-buffer (expand-file-name "ctx.txt" dir))
                     (buffer-string))
                   "l1\nl2\nl3 needle\nfour\nextra\nl5\nl6\nl7\nl8\nl9 needle\nl10\nl11\nl12\n"))
    ;; The new line is a line of the block, with the file and nothing else.
    (should (= (length (quarry-grep--blocks)) 2))
    (let* ((context (quarry-test-grep--line-pos "ctx.txt" 4))
           (added (save-excursion (goto-char context) (forward-line 1) (point)))
           (block (quarry-grep--block-at context)))
      (should (equal (quarry-test-grep--line-text added) "extra"))
      (should (equal (quarry-grep--block-at added) block))
      (should (equal (quarry-grep--block-at (quarry-test-grep-wgrep--gap-pos))
                     block))
      (should (equal (get-text-property added 'quarry-grep-file) "ctx.txt"))
      (should-not (get-text-property added 'quarry-grep-line))
      (should (= (length (quarry-test-grep--lines-with 'quarry-grep-gap)) 1))
      (should (= quarry-grep--status-marker
                 (text-property-any (point-min) (point-max) 'quarry-grep-status t)))
      ;; Folding covers the added line, and n passes over it.
      (goto-char context)
      (quarry-test-grep--keys "TAB")
      (should (invisible-p added))
      (should-not (quarry-test-grep--hidden-p "two.txt" 2))
      (quarry-test-grep--keys "TAB")
      (should-not (invisible-p added))
      (goto-char (point-min))
      (let ((seen nil))
        (condition-case nil
            (while t
              (quarry-grep-next-match)
              (push (get-text-property (point) 'quarry-grep-line) seen))
          (user-error nil))
        (should (equal (nreverse seen) '(3 9 2)))))))

;;;; The stale check

(ert-deftest quarry-test-grep-wgrep-stale-check ()
  "e asks when a result file changed since the search, and only then."
  (skip-unless (quarry-test-grep-wgrep--p))
  (quarry-test-grep-wgrep--with-results dir
    (let ((one (expand-file-name "one.txt" dir))
          (two (expand-file-name "two/two.txt" dir)))
      (should-not (quarry-grep--stale-files))
      ;; A visiting buffer that is not modified does not count.
      (find-file-noselect one)
      (should-not (quarry-grep--stale-files))
      ;; The time the service reported is the file's, in milliseconds.
      (should (equal (get-text-property (quarry-test-grep--heading-pos "one.txt")
                                        'quarry-grep-mtime)
                     (quarry-grep--file-mtime one)))
      ;; A modified visiting buffer.  The answer no enters edit mode.
      (with-current-buffer (get-file-buffer one)
        (goto-char (point-max))
        (insert "more\n"))
      (should (equal (quarry-grep--stale-files) '("one.txt")))
      (should (equal (quarry-test-grep-wgrep--answering nil (execute-kbd-macro (kbd "e")))
                     '("1 result file changed since the search (one.txt); search again first? ")))
      (should (eq (current-local-map) wgrep-mode-map))
      (execute-kbd-macro (kbd "C-c C-k"))
      (quarry-test-grep-wgrep--working)
      (with-current-buffer (get-file-buffer one)
        (set-buffer-modified-p nil)
        (kill-buffer))
      (should-not (quarry-grep--stale-files))
      ;; A changed modification time, and a file that is gone.
      (set-file-times two (time-add (file-attribute-modification-time (file-attributes two))
                                    3))
      (should (equal (quarry-grep--stale-files) '("two/two.txt")))
      (delete-file (expand-file-name "long.txt" dir))
      (should (equal (quarry-grep--stale-files) '("long.txt" "two/two.txt")))
      ;; The answer yes searches again and stays out of edit mode.
      (let ((sent (length quarry-test-grep--requests)))
        (should (equal (quarry-test-grep-wgrep--answering t (execute-kbd-macro (kbd "e")))
                       '("2 result files changed since the search (long.txt, ...); search again first? ")))
        (should (eq (current-local-map) quarry-grep-mode-map))
        (should-not quarry-grep--editing)
        (should buffer-read-only)
        (should (= (length quarry-test-grep--requests) (1+ sent)))
        (quarry-test-grep--wait))
      (should (equal (quarry-test-grep--headings) '("bytes.txt" "one.txt" "two/two.txt")))
      ;; After it nothing is stale and nothing is asked.
      (should-not (quarry-grep--stale-files))
      (quarry-test-grep-wgrep--enter)
      (execute-kbd-macro (kbd "C-c C-k"))
      ;; A time the search did not learn is unknown, not changed.
      (let ((inhibit-read-only t)
            (heading (quarry-test-grep--heading-pos "one.txt")))
        (put-text-property heading (1+ heading) 'quarry-grep-mtime nil)
        (put-text-property (quarry-test-grep--heading-pos "bytes.txt")
                           (1+ (quarry-test-grep--heading-pos "bytes.txt"))
                           'quarry-grep-mtime 1))
      (should (equal (quarry-grep--stale-files) '("bytes.txt"))))))

(provide 'quarry-grep-wgrep-tests)
;;; quarry-grep-wgrep-tests.el ends here
