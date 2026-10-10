;;; quarry-grep-tests.el --- ERT suite for quarry-grep  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh, which loads tests/quarry-tests.el first;
;; its helpers are used here.  The tests load the module, so their names
;; start with `quarry-test-grep-' to sort after
;; `quarry-test-build-async-installs' (docs/backlog.md).
;;
;; The result buffer is read through its text properties, never by
;; column or by a regexp on its layout (docs/decisions/0012).

;;; Code:

(require 'ert)
(require 'quarry-tests)
(require 'quarry-grep)

;;;; Helpers

(defconst quarry-test-grep--files
  '(("src/a.rs" . "fn main() {\n    let needle = 1;\n}\n// Needle again, needle\n")
    ("src/b.rs" . "fn other() {}\n")
    ("notes.txt" . "a needle in text\nnothing\n")
    ("sub/deep.txt" . "über needle\n")
    (".hidden.txt" . "hidden needle\n")
    ("ignored.txt" . "ignored needle\n")
    (".ignore" . "ignored.txt\n"))
  "The tree most tests search: an alist from path to content.
A search for `needle' finds, in this order, .hidden.txt:1, notes.txt:1,
src/a.rs:2 and :4, sub/deep.txt:1.")

(defconst quarry-test-grep--needles
  '((".hidden.txt" 1 "hidden needle")
    ("notes.txt" 1 "a needle in text")
    ("src/a.rs" 2 "    let needle = 1;")
    ("src/a.rs" 4 "// Needle again, needle")
    ("sub/deep.txt" 1 "über needle"))
  "What `quarry-test-grep--results' returns for `needle' in the tree.")

(defvar quarry-test-grep--requests nil
  "The requests sent with `emrs-call-stream', newest first.")

(defvar quarry-test-grep--calls nil
  "The calls `emrs-call-stream' returned, newest first.")

(defvar quarry-test-grep--fake nil
  "What the fake stream got: lists (REQUEST ON-BATCH ON-END), newest first.")

(defun quarry-test-grep--tree (files)
  "Create a temporary directory with FILES, an alist from path to content."
  (let ((dir (quarry-test--make-tree (mapcar #'car files))))
    (pcase-dolist (`(,path . ,content) files)
      (write-region content nil (expand-file-name path dir) nil 'silent))
    dir))

(defmacro quarry-test-grep--with-tree (spec &rest body)
  "Run BODY with a tree; SPEC is (DIR [FILES]).
DIR is bound to a tree of FILES (default `quarry-test-grep--files') and
is the `default-directory'.  The result buffer has a name of its own,
the options have their defaults, and the requests and calls of
`emrs-call-stream' are recorded."
  (declare (indent 1))
  (let ((dir (car spec)))
    `(let* ((,dir (quarry-test-grep--tree ,(or (cadr spec) 'quarry-test-grep--files)))
            (default-directory ,dir)
            (quarry-grep-buffer-name "*quarry-grep-test*")
            (quarry-grep-case 'smart)
            (quarry-grep-max-lines 50000)
            (quarry-grep-max-columns 500)
            (quarry-include-hidden t)
            (quarry-ignores nil)
            (project-find-functions nil))
       (setq quarry-test-grep--requests nil
             quarry-test-grep--calls nil
             quarry-test-grep--fake nil)
       (advice-add 'emrs-call-stream :before
                   (lambda (_instance request &rest _)
                     (push request quarry-test-grep--requests))
                   '((name . quarry-test-grep-requests)))
       (advice-add 'emrs-call-stream :filter-return
                   (lambda (call) (push call quarry-test-grep--calls) call)
                   '((name . quarry-test-grep-calls)))
       (unwind-protect
           (save-window-excursion ,@body)
         (advice-remove 'emrs-call-stream 'quarry-test-grep-requests)
         (advice-remove 'emrs-call-stream 'quarry-test-grep-calls)
         (when (get-buffer quarry-grep-buffer-name)
           (kill-buffer quarry-grep-buffer-name))
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p ,dir (buffer-file-name buffer)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (delete-directory ,dir t)))))

(defmacro quarry-test-grep--with-fake-stream (&rest body)
  "Run BODY with `emrs-call-stream' recording instead of sending.
Each use is pushed to `quarry-test-grep--fake'; the test plays the
service by calling the recorded callbacks."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'emrs-call-stream)
              (lambda (_instance request &rest keys)
                (push (list request (plist-get keys :on-batch) (plist-get keys :on-end))
                      quarry-test-grep--fake)
                (emrs--make-call :done t))))
     ,@body))

(defun quarry-test-grep--buffer ()
  "Return the result buffer."
  (get-buffer quarry-grep-buffer-name))

(defun quarry-test-grep--state ()
  "Return the state of the result buffer's search."
  (buffer-local-value 'quarry-grep--state (quarry-test-grep--buffer)))

(defun quarry-test-grep--wait ()
  "Wait until the search of the result buffer has ended; make it current."
  (should (quarry-test--wait
           (lambda () (not (eq (quarry-test-grep--state) 'running)))))
  (set-buffer (quarry-test-grep--buffer)))

(defun quarry-test-grep--search (dir &optional pattern)
  "Search DIR for the regexp PATTERN (default `needle') and wait for the end."
  (quarry-grep (or pattern "needle") nil dir)
  (quarry-test-grep--wait))

(defun quarry-test-grep--keys (keys)
  "Type KEYS, a `kbd' string or a vector, in the result buffer; wait."
  (pop-to-buffer-same-window (quarry-test-grep--buffer))
  (execute-kbd-macro (if (stringp keys) (kbd keys) keys))
  (quarry-test-grep--wait))

(defun quarry-test-grep--request (&optional field)
  "Return the request sent last, or its FIELD."
  (let ((request (car quarry-test-grep--requests)))
    (should (eq (car request) :search))
    (if field (plist-get (cdr request) field) request)))

(defun quarry-test-grep--lines-with (property)
  "Return the starts of the result buffer's lines that have PROPERTY."
  (with-current-buffer (quarry-test-grep--buffer)
    (save-excursion
      (goto-char (point-min))
      (let ((found nil))
        (while (not (eobp))
          (when (get-text-property (point) property)
            (push (point) found))
          (forward-line 1))
        (nreverse found)))))

(defun quarry-test-grep--results ()
  "Return the result lines as a list of (PATH LINE TEXT)."
  (with-current-buffer (quarry-test-grep--buffer)
    (mapcar (lambda (bol)
              (list (get-text-property bol 'quarry-grep-file)
                    (get-text-property bol 'quarry-grep-line)
                    (save-excursion
                      (goto-char bol)
                      (buffer-substring-no-properties
                       (next-single-property-change bol 'quarry-grep-prefix)
                       (pos-eol)))))
            (quarry-test-grep--lines-with 'quarry-grep-line))))

(defun quarry-test-grep--headings ()
  "Return the paths of the file headings, in buffer order."
  (with-current-buffer (quarry-test-grep--buffer)
    (mapcar (lambda (bol) (get-text-property bol 'quarry-grep-file))
            (quarry-test-grep--lines-with 'quarry-grep-heading))))

(defun quarry-test-grep--line-pos (path line)
  "Return the start of the result line LINE of PATH."
  (with-current-buffer (quarry-test-grep--buffer)
    (seq-find (lambda (bol)
                (and (equal (get-text-property bol 'quarry-grep-file) path)
                     (eql (get-text-property bol 'quarry-grep-line) line)))
              (quarry-test-grep--lines-with 'quarry-grep-line))))

(defun quarry-test-grep--heading-pos (path)
  "Return the start of the heading of PATH."
  (with-current-buffer (quarry-test-grep--buffer)
    (seq-find (lambda (bol) (equal (get-text-property bol 'quarry-grep-file) path))
              (quarry-test-grep--lines-with 'quarry-grep-heading))))

(defun quarry-test-grep--hidden-p (path line)
  "Return non-nil when the result line LINE of PATH is folded away."
  (with-current-buffer (quarry-test-grep--buffer)
    (invisible-p (quarry-test-grep--line-pos path line))))

(defun quarry-test-grep--part (bol part)
  "Return the text of PART in the filter line that starts at BOL, or nil."
  (save-excursion
    (goto-char bol)
    (let ((start (text-property-any bol (pos-eol) 'quarry-grep-part part)))
      (and start
           (buffer-substring-no-properties
            start (next-single-property-change start 'quarry-grep-part nil (pos-eol)))))))

(defun quarry-test-grep--filter-lines ()
  "Return the filter lines as a list of (SIGN KIND PATTERN OFF)."
  (with-current-buffer (quarry-test-grep--buffer)
    (mapcar (lambda (bol)
              (mapcar (lambda (part) (quarry-test-grep--part bol part))
                      '(sign kind pattern off)))
            (quarry-test-grep--lines-with 'quarry-grep-filter))))

(defun quarry-test-grep--status ()
  "Return the text of the status line, without its newline."
  (with-current-buffer (quarry-test-grep--buffer)
    (let ((start (text-property-any (point-min) (point-max) 'quarry-grep-status t)))
      (should start)
      ;; The status line is the end of the buffer.
      (should-not (text-property-not-all start (point-max) 'quarry-grep-status t))
      (string-trim-right (buffer-substring-no-properties start (point-max)) "\n"))))

(defun quarry-test-grep--header ()
  "Return the header line of the result buffer as plain text."
  (with-current-buffer (quarry-test-grep--buffer)
    (should (equal header-line-format '(:eval (quarry-grep--header))))
    (substring-no-properties (quarry-grep--header))))

(defun quarry-test-grep--prompts (function)
  "Call FUNCTION; return the minibuffer prompts it showed, oldest first.
Each is (PROMPT . INITIAL-CONTENTS)."
  (let ((seen nil))
    (let ((minibuffer-setup-hook
           (cons (lambda () (push (cons (minibuffer-prompt) (minibuffer-contents)) seen))
                 minibuffer-setup-hook)))
      (funcall function))
    (nreverse seen)))

(defun quarry-test-grep--visit-file (dir path &optional text)
  "Show the file PATH of DIR in the selected window, point before TEXT."
  (switch-to-buffer (find-file-noselect (expand-file-name path dir)))
  (goto-char (point-min))
  (when text
    (search-forward text)
    (goto-char (match-beginning 0))))

;;;; Commands and prompts

(ert-deftest quarry-test-grep-command-regexp ()
  "`quarry-grep' asks for regexp, type and directory, with their defaults."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--visit-file dir "src/a.rs")
    (let ((prompts (quarry-test-grep--prompts
                    (lambda ()
                      (execute-kbd-macro (kbd "M-x quarry-grep RET needle RET RET RET"))))))
      (quarry-test-grep--wait)
      ;; M-x, then the three prompts: the symbol at point, the type of
      ;; a.rs, the directory of the buffer.
      (should (= (length prompts) 4))
      (should (string-match-p "\\`Regexp search for (default fn): " (car (nth 1 prompts))))
      (should (string-match-p "\\`Search in files.*(default rust): " (car (nth 2 prompts))))
      (should (equal (car (nth 3 prompts)) "Search in directory: "))
      (should (equal (expand-file-name (cdr (nth 3 prompts)))
                     (expand-file-name "src/" dir))))
    (should (equal (quarry-test-grep--request)
                   (list :search
                         :dir (expand-file-name "src/" dir)
                         :filters '((:target :line :exclude nil :pattern "needle" :regexp t))
                         :case :smart
                         :file-type "rust"
                         :no-ignore nil :hidden t :ignores nil
                         :max-lines 50000 :max-columns 500)))
    (should (eq major-mode 'quarry-grep-mode))
    (should buffer-read-only)
    (should (equal default-directory (expand-file-name "src/" dir)))
    (should (eq (window-buffer) (quarry-test-grep--buffer)))
    (should (equal (quarry-test-grep--results)
                   '(("a.rs" 2 "    let needle = 1;")
                     ("a.rs" 4 "// Needle again, needle"))))))

(ert-deftest quarry-test-grep-command-literal-globs ()
  "`quarry-grep-literal' takes the default pattern, globs and a directory."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--visit-file dir "src/a.rs" "needle")
    (let ((prompts
           (quarry-test-grep--prompts
            (lambda ()
              (execute-kbd-macro
               (vconcat (kbd "M-x quarry-grep-literal RET RET *.txt SPC *.md RET C-a C-k")
                        dir (kbd "RET")))))))
      (quarry-test-grep--wait)
      (should (equal (car (nth 1 prompts)) "Literal search for (default needle): ")))
    (should (equal (quarry-test-grep--request :filters)
                   '((:target :line :exclude nil :pattern "needle" :regexp nil))))
    (should (equal (quarry-test-grep--request :globs) '("*.txt" "*.md")))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :file-type))
    (should (equal (quarry-test-grep--request :dir) dir))
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "notes.txt" "sub/deep.txt")))
    ;; The active region is the default, before the symbol at point.
    (quarry-test-grep--visit-file dir "src/a.rs" "main")
    (let ((transient-mark-mode t))
      (set-mark (point))
      (forward-char 2)
      (activate-mark)
      (should (equal (quarry-grep--default-pattern) "ma")))))

(ert-deftest quarry-test-grep-command-project ()
  "`quarry-grep-project' searches the project root, else the directory."
  (quarry-test-grep--with-tree (dir)
    (let ((project-find-functions (list (lambda (_) (cons 'transient dir)))))
      (quarry-test-grep--visit-file dir "sub/deep.txt")
      (let ((prompts
             (quarry-test-grep--prompts
              (lambda ()
                (execute-kbd-macro
                 (kbd "M-x quarry-grep-project RET ne+dle RET everything RET"))))))
        (quarry-test-grep--wait)
        ;; No directory prompt.
        (should (= (length prompts) 3))
        (should (string-match-p "(default txt): " (car (nth 2 prompts)))))
      (should (equal (quarry-test-grep--request :dir) dir))
      (should (equal (quarry-test-grep--request :filters)
                     '((:target :line :exclude nil :pattern "ne+dle" :regexp t))))
      (should-not (plist-member (cdr (quarry-test-grep--request)) :file-type))
      (should-not (plist-member (cdr (quarry-test-grep--request)) :globs))
      (should (equal (quarry-test-grep--results) quarry-test-grep--needles)))
    ;; Outside a project.
    (quarry-test-grep--visit-file dir "sub/deep.txt")
    (quarry-grep-project "needle" "txt")
    (quarry-test-grep--wait)
    (should (equal (quarry-test-grep--request :dir) (expand-file-name "sub/" dir)))
    (should (equal (quarry-test-grep--request :file-type) "txt"))
    (should (equal (quarry-test-grep--results) '(("deep.txt" 1 "über needle"))))))

(ert-deftest quarry-test-grep-command-dwim ()
  "`quarry-grep-dwim' searches the project for the symbol at point."
  (quarry-test-grep--with-tree (dir)
    (let ((project-find-functions (list (lambda (_) (cons 'transient dir)))))
      (quarry-test-grep--visit-file dir "src/a.rs" "main")
      (let ((prompts (quarry-test-grep--prompts
                      (lambda ()
                        (execute-kbd-macro (kbd "M-x quarry-grep-dwim RET"))))))
        (should (= (length prompts) 1)))
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--request :dir) dir))
      (should (equal (quarry-test-grep--request :file-type) "rust"))
      (should (equal (quarry-test-grep--request :filters)
                     '((:target :line :exclude nil :pattern "main" :regexp nil))))
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 1 "fn main() {"))))
      ;; Without a symbol at point.
      (with-temp-buffer
        (let ((err (should-error (quarry-grep-dwim) :type 'user-error)))
          (should (string-match-p "No symbol at point" (cadr err))))))))

(ert-deftest quarry-test-grep-file-types ()
  "The type list is asked for once; the default type and the input parse."
  (quarry-test-grep--with-tree (dir)
    (let ((types (quarry-grep--type-list)))
      (should (member '(:name "rust" :globs ("*.rs")) types))
      ;; Cached for the session.
      (cl-letf (((symbol-function 'emrs-call-sync)
                 (lambda (&rest _) (error "The type list was asked for again"))))
        (should (eq (quarry-grep--type-list) types))))
    (with-temp-buffer
      (should-not (quarry-grep--default-type))
      ;; Several types have *.h: the first, unless one is named like
      ;; the major mode.
      (setq buffer-file-name (expand-file-name "x.h" dir))
      (should (equal (quarry-grep--default-type) "c"))
      (setq major-mode 'objc-mode)
      (should (equal (quarry-grep--default-type) "objc"))
      (setq major-mode 'objcpp-ts-mode)
      (should (equal (quarry-grep--default-type) "objcpp"))
      (setq buffer-file-name (expand-file-name "x.no-such-type" dir))
      (should-not (quarry-grep--default-type))
      (setq buffer-file-name nil)
      (set-buffer-modified-p nil))
    (should-not (quarry-grep--parse-files "everything"))
    (should-not (quarry-grep--parse-files " "))
    (should (equal (quarry-grep--parse-files "rust") "rust"))
    (should (equal (quarry-grep--parse-files " *.a  *.b ") '("*.a" "*.b")))
    (should (equal (quarry-grep--parse-files "*.rs") '("*.rs")))
    (should (equal (quarry-grep--files-text '("*.a" "*.b")) "*.a *.b"))
    (should (equal (quarry-grep--files-text nil) "everything"))))

;;;; The result buffer

(ert-deftest quarry-test-grep-buffer-content ()
  "Filter block, file blocks, status line and header of a finished search."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (should (eq (quarry-test-grep--state) 'done))
    (should (equal default-directory dir))
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "needle" nil))))
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "notes.txt" "src/a.rs" "sub/deep.txt")))
    (should (equal (quarry-test-grep--results) quarry-test-grep--needles))
    (should (string-match-p "\\`Search finished: 5 lines in 4 files, [0-9]+ ms\\'"
                            (quarry-test-grep--status)))
    (should (equal (quarry-test-grep--header)
                   (format " files: everything   dir: %s   case: smart   ign: on   hidden: on   hits: 5 in 4 files"
                           (abbreviate-file-name dir))))
    ;; The filter block is the start of the buffer, the filter's line
    ;; holds the search's own filter object.
    (should (eq (get-text-property (point-min) 'quarry-grep-filter)
                (car (quarry-grep--search-filters quarry-grep--current))))
    (should (= (point) (point-min)))
    ;; A heading knows the file's modification time, in milliseconds.
    (let* ((heading (quarry-test-grep--heading-pos "src/a.rs"))
           (mtime (get-text-property heading 'quarry-grep-mtime))
           (real (float-time (file-attribute-modification-time
                              (file-attributes (expand-file-name "src/a.rs" dir))))))
      (should (integerp mtime))
      (should (< (abs (- (/ mtime 1000.0) real)) 1.0))
      (should (eq (get-text-property heading 'follow-link) t))
      (should-not (get-text-property heading 'quarry-grep-line)))
    ;; A result line: the prefix, then exactly the text; the column and
    ;; the face of the primary matches.
    (let* ((bol (quarry-test-grep--line-pos "src/a.rs" 4))
           (text (next-single-property-change bol 'quarry-grep-prefix)))
      (should (get-text-property bol 'quarry-grep-prefix))
      (should (eq (get-text-property bol 'face) 'quarry-grep-line-number))
      (should-not (text-property-not-all bol text 'quarry-grep-prefix t))
      (should (equal (string-trim (buffer-substring-no-properties bol text)) "4"))
      (should (eql (get-text-property bol 'quarry-grep-column) 3))
      (should-not (get-text-property bol 'quarry-grep-inexact))
      (should (eq (get-text-property bol 'follow-link) t))
      (should (eq (get-text-property bol 'mouse-face) 'highlight))
      ;; "// Needle again, needle": characters 3 to 8 and 17 to 22.
      (should (equal (cl-loop for i from 0 below 23
                              when (eq (get-text-property (+ text i) 'face)
                                       'quarry-grep-match)
                              collect i)
                     '(3 4 5 6 7 8 17 18 19 20 21 22))))
    ;; Positions are characters, not bytes.
    (should (eql (get-text-property (quarry-test-grep--line-pos "sub/deep.txt" 1)
                                    'quarry-grep-column)
                 5))))

(ert-deftest quarry-test-grep-no-match ()
  "A search without matches shows the filter block and says so."
  (quarry-test-grep--with-tree (dir)
    (quarry-grep-literal "no such text anywhere" nil dir)
    (quarry-test-grep--wait)
    (should (eq (quarry-test-grep--state) 'done))
    (should (equal (quarry-test-grep--filter-lines)
                   '(("+" "line" "no such text anywhere" nil))))
    (should-not (quarry-test-grep--headings))
    (should-not (quarry-test-grep--results))
    (should (string-match-p "\\`Search finished: no matches in [0-9]+ files, [0-9]+ ms\\'"
                            (quarry-test-grep--status)))
    (should (string-suffix-p "hits: 0 in 0 files" (quarry-test-grep--header)))))

(ert-deftest quarry-test-grep-caps ()
  "The line cap is named in the status line; a cut line is marked."
  (quarry-test-grep--with-tree (dir '(("a.txt" . "needle 1\nneedle 2\nneedle 3\n")
                                      ("long.txt" . "0123456789abcdef needle\n")))
    (let ((quarry-grep-max-lines 2))
      (quarry-test-grep--search dir)
      (should (equal (quarry-test-grep--request :max-lines) 2))
      (should (= (length (quarry-test-grep--results)) 2))
      (should (string-match-p
               "\\`Search stopped at 2 lines, narrow the search: 2 lines in [12] files?, [0-9]+ ms\\'"
               (quarry-test-grep--status))))
    (let ((quarry-grep-max-columns 12))
      (quarry-test-grep--search dir)
      (should (equal (quarry-test-grep--request :max-columns) 12))
      (should (member '("long.txt" 1 "0123456789ab") (quarry-test-grep--results)))
      (let ((cut (quarry-test-grep--line-pos "long.txt" 1))
            (whole (quarry-test-grep--line-pos "a.txt" 1)))
        (should (eq (get-text-property cut 'quarry-grep-inexact) t))
        ;; The match lies beyond the cut.
        (should-not (get-text-property cut 'quarry-grep-column))
        (should-not (get-text-property whole 'quarry-grep-inexact))
        (should (eql (get-text-property whole 'quarry-grep-column) 0))))))

(ert-deftest quarry-test-grep-filter-states ()
  "Every filter state is rendered and only enabled filters are sent."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let* ((filters (list (quarry-grep--make-filter :pattern "ne+dle" :regexp t)
                          (quarry-grep--make-filter :pattern "zzz" :enabled nil)
                          (quarry-grep--make-filter :pattern "^//" :regexp t :exclude t)
                          (quarry-grep--make-filter :target 'path :pattern "/sub/" :exclude t)
                          (quarry-grep--make-filter :target 'path :pattern "\\.(rs|txt)$"
                                                    :regexp t)
                          (quarry-grep--make-filter :target 'path :pattern "nowhere"
                                                    :regexp t :exclude t :enabled nil)))
           (search (quarry-grep--copy-search quarry-grep--current)))
      (setf (quarry-grep--search-filters search) filters)
      (quarry-grep--run search)
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "ne+dle" nil)
                       ("+" "line" "zzz" "(off)")
                       ("-" "line/re" "^//" nil)
                       ("-" "path" "/sub/" nil)
                       ("+" "path/re" "\\.(rs|txt)$" nil)
                       ("-" "path/re" "nowhere" "(off)"))))
      ;; Each line holds its filter; a disabled one is dimmed as a whole.
      (let ((lines (quarry-test-grep--lines-with 'quarry-grep-filter)))
        (should (equal (mapcar (lambda (bol) (get-text-property bol 'quarry-grep-filter))
                               lines)
                       filters))
        (should (eq (get-text-property (nth 0 lines) 'face) 'quarry-grep-filter-include))
        (should (eq (get-text-property (nth 2 lines) 'face) 'quarry-grep-filter-exclude))
        (dolist (bol (list (nth 1 lines) (nth 5 lines)))
          (dolist (part '(sign kind pattern off))
            (should (eq (get-text-property
                         (text-property-any bol (point-max) 'quarry-grep-part part)
                         'face)
                        'quarry-grep-filter-disabled)))))
      (should (equal (quarry-test-grep--request :filters)
                     '((:target :line :exclude nil :pattern "ne+dle" :regexp t)
                       (:target :line :exclude t :pattern "^//" :regexp t)
                       (:target :path :exclude t :pattern "/sub/" :regexp nil)
                       (:target :path :exclude nil :pattern "\\.(rs|txt)$" :regexp t))))
      (should (eq (quarry-grep--primary search) (car filters)))
      (should (equal (quarry-test-grep--results)
                     '((".hidden.txt" 1 "hidden needle")
                       ("notes.txt" 1 "a needle in text")
                       ("src/a.rs" 2 "    let needle = 1;"))))
      ;; A command on a filter line leaves point on that line.
      (goto-char (nth 2 (quarry-test-grep--lines-with 'quarry-grep-filter)))
      (quarry-test-grep--keys "%")
      (should (equal (nth 2 (quarry-test-grep--filter-lines)) '("-" "line" "^//" nil)))
      (should (= (point) (nth 2 (quarry-test-grep--lines-with 'quarry-grep-filter))))
      ;; The first enabled include line filter is the primary one.
      (let ((second (quarry-grep--copy-search search)))
        (setf (quarry-grep--search-filters second)
              (list (quarry-grep--make-filter :pattern "hidden" :enabled nil)
                    (quarry-grep--make-filter :pattern "x" :exclude t)
                    (quarry-grep--make-filter :pattern "again")))
        (should (eq (quarry-grep--primary second)
                    (nth 2 (quarry-grep--search-filters second))))))))

(ert-deftest quarry-test-grep-keymap ()
  "The keys of the mode are bound."
  (pcase-dolist (`(,key . ,command)
                 '(("RET" . quarry-grep-visit)
                   ("<mouse-2>" . quarry-grep-mouse-visit)
                   ("n" . quarry-grep-next-match)
                   ("p" . quarry-grep-previous-match)
                   ("}" . quarry-grep-next-file)
                   ("{" . quarry-grep-previous-file)
                   ("M-N" . quarry-grep-next-file)
                   ("M-P" . quarry-grep-previous-file)
                   ("TAB" . quarry-grep-toggle-fold)
                   ("<backtab>" . quarry-grep-toggle-fold-all)
                   ("g" . quarry-grep-rerun)
                   ("r" . quarry-grep-change-regexp)
                   ("t" . quarry-grep-change-literal)
                   ("%" . quarry-grep-toggle-regexp)
                   ("d" . quarry-grep-change-directory)
                   ("f" . quarry-grep-change-files)
                   ("c" . quarry-grep-cycle-case)
                   ("i" . quarry-grep-toggle-ignore)
                   ("H" . quarry-grep-toggle-hidden)
                   ("C-c <" . quarry-grep-history-back)
                   ("C-c >" . quarry-grep-history-forward)
                   ("C-c C-k" . quarry-grep-cancel)
                   ("- p" . quarry-grep-exclude-path)
                   ("+ p" . quarry-grep-include-path)
                   ("- l" . quarry-grep-exclude-line)
                   ("+ l" . quarry-grep-include-line)
                   ("- f" . quarry-grep-exclude-file)
                   ("- d" . quarry-grep-exclude-directory)
                   ("+ d" . quarry-grep-include-directory)
                   ("k" . quarry-grep-remove-filter)
                   ("x" . quarry-grep-toggle-filter)
                   ("!" . quarry-grep-flip-filter)
                   ("K" . quarry-grep-remove-other-filters)
                   ("- P" . quarry-grep-exclude-path-regexp)
                   ("+ P" . quarry-grep-include-path-regexp)
                   ("- L" . quarry-grep-exclude-line-regexp)
                   ("+ L" . quarry-grep-include-line-regexp)
                   ("e" . quarry-grep-edit)
                   ("q" . quit-window)))
    (should (eq (keymap-lookup quarry-grep-mode-map key) command)))
  (should (eq (get 'quarry-grep-mode 'derived-mode-parent) 'special-mode)))

;;;; Visiting

(ert-deftest quarry-test-grep-visit ()
  "RET and a click visit the line and column; a heading visits the file."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let ((results (quarry-test-grep--buffer))
          (a (expand-file-name "src/a.rs" dir)))
      ;; From the end of a result line.
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
      (end-of-line)
      (quarry-test-grep--keys "RET")
      (should (equal (buffer-file-name (window-buffer)) a))
      (with-current-buffer (window-buffer)
        (should (= (line-number-at-pos) 4))
        (should (= (current-column) 3))
        (should (looking-at-p "Needle again")))
      ;; In another window: the results stay visible.
      (should (get-buffer-window results))
      (should (eq next-error-last-buffer results))
      ;; A narrowed buffer is widened when the line is outside.
      (with-current-buffer (get-file-buffer a)
        (goto-char (point-min))
        (narrow-to-region (point-min) (pos-eol)))
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--line-pos "src/a.rs" 2))
      (quarry-grep-visit)
      (should (equal (buffer-file-name) a))
      (should (= (line-number-at-pos nil t) 2))
      (should (looking-at-p "needle = 1"))
      (should-not (buffer-narrowed-p))
      ;; A column after a non-ASCII character.
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--line-pos "sub/deep.txt" 1))
      (quarry-grep-visit)
      (should (equal (buffer-file-name) (expand-file-name "sub/deep.txt" dir)))
      (should (looking-at-p "needle"))
      ;; A heading visits the file.
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--heading-pos "src/a.rs"))
      (quarry-grep-visit)
      (should (equal (buffer-file-name) a))
      (should (equal (buffer-file-name (window-buffer)) a))
      ;; A click on the line number of a result.
      (pop-to-buffer-same-window results)
      (goto-char (point-min))
      (let ((bol (quarry-test-grep--line-pos "notes.txt" 1)))
        (should (get-text-property (1+ bol) 'quarry-grep-prefix))
        (quarry-grep-mouse-visit
         (list 'mouse-2 (list (selected-window) (1+ bol) '(0 . 0) 0))))
      (should (equal (buffer-file-name) (expand-file-name "notes.txt" dir)))
      (should (= (line-number-at-pos) 1))
      (should (looking-at-p "needle in text"))
      ;; Nothing to visit on the status line; a file that is gone.
      (pop-to-buffer-same-window results)
      (goto-char (point-max))
      (forward-line -1)
      (should (get-text-property (point) 'quarry-grep-status))
      (should-error (quarry-grep-visit) :type 'user-error)
      (delete-file (expand-file-name "notes.txt" dir))
      (kill-buffer (get-file-buffer (expand-file-name "notes.txt" dir)))
      (goto-char (quarry-test-grep--line-pos "notes.txt" 1))
      (let ((err (should-error (quarry-grep-visit) :type 'user-error)))
        (should (string-match-p "no longer exists" (cadr err)))))))

(defun quarry-test-grep--place ()
  "Return (FILE-NAME LINE) of the selected window's buffer and point."
  (with-current-buffer (window-buffer)
    (list (file-name-nondirectory (buffer-file-name))
          (line-number-at-pos (window-point)))))

(ert-deftest quarry-test-grep-next-error ()
  "`next-error' walks the results from another buffer, also folded ones."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let ((results (quarry-test-grep--buffer)))
      (should (eq (buffer-local-value 'next-error-function results)
                  'quarry-grep--next-error))
      ;; Fold everything first: a folded block is opened by the visit.
      (quarry-grep-toggle-fold-all)
      (should (quarry-test-grep--hidden-p "notes.txt" 1))
      (switch-to-buffer (get-buffer-create "*quarry-grep-test-other*"))
      (unwind-protect
          (progn
            (next-error)
            (should (equal (quarry-test-grep--place) '(".hidden.txt" 1)))
            (next-error)
            (should (equal (quarry-test-grep--place) '("notes.txt" 1)))
            (should-not (quarry-test-grep--hidden-p "notes.txt" 1))
            (should (quarry-test-grep--hidden-p "src/a.rs" 2))
            ;; Point in the result buffer follows.
            (with-current-buffer results
              (should (= (point) (quarry-test-grep--line-pos "notes.txt" 1))))
            (next-error 2)
            (should (equal (quarry-test-grep--place) '("a.rs" 4)))
            (should (= (with-current-buffer (window-buffer) (current-column)) 3))
            (previous-error)
            (should (equal (quarry-test-grep--place) '("a.rs" 2)))
            (next-error 2)
            (should (equal (quarry-test-grep--place) '("deep.txt" 1)))
            (should-error (next-error) :type 'user-error)
            (first-error)
            (should (equal (quarry-test-grep--place) '(".hidden.txt" 1)))
            (should-error (previous-error) :type 'user-error))
        (kill-buffer "*quarry-grep-test-other*"))
      ;; n and p show the match in another window and stay.
      (pop-to-buffer-same-window results)
      (delete-other-windows)
      (goto-char (point-min))
      (quarry-test-grep--keys "n")
      (should (eq (window-buffer) results))
      (should (= (point) (quarry-test-grep--line-pos ".hidden.txt" 1)))
      (quarry-test-grep--keys "n n")
      (should (eq (window-buffer) results))
      (should (= (point) (quarry-test-grep--line-pos "src/a.rs" 2)))
      (let ((window (get-buffer-window (get-file-buffer (expand-file-name "src/a.rs" dir)))))
        (should window)
        (should-not (eq window (selected-window)))
        (should (= (with-current-buffer (window-buffer window)
                     (line-number-at-pos (window-point window)))
                   2)))
      (quarry-test-grep--keys "p")
      (should (= (point) (quarry-test-grep--line-pos "notes.txt" 1))))))

(ert-deftest quarry-test-grep-file-headings ()
  "} and { move over the file headings."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (goto-char (point-min))
    (quarry-test-grep--keys "}")
    (should (= (point) (quarry-test-grep--heading-pos ".hidden.txt")))
    (quarry-test-grep--keys "} M-N")
    (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
    (quarry-test-grep--keys "{")
    (should (= (point) (quarry-test-grep--heading-pos "notes.txt")))
    (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
    (quarry-test-grep--keys "M-P")
    (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
    (quarry-test-grep--keys "}")
    (should (= (point) (quarry-test-grep--heading-pos "sub/deep.txt")))
    (should-error (quarry-grep-next-file) :type 'user-error)
    (goto-char (point-min))
    (should-error (quarry-grep-previous-file) :type 'user-error)))

(ert-deftest quarry-test-grep-folding ()
  "TAB folds the block at point, S-TAB all; headings stay visible."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (cl-flet ((folded () (cl-loop for (path line _) in quarry-test-grep--needles
                                  when (quarry-test-grep--hidden-p path line)
                                  collect (list path line))))
      ;; From inside the block; point goes to the heading.
      (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
      (quarry-test-grep--keys "TAB")
      (should (equal (folded) '(("src/a.rs" 2) ("src/a.rs" 4))))
      (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
      (should-not (invisible-p (point)))
      ;; The heading's own text stays, and so does the next block.
      (should-not (invisible-p (1- (pos-eol))))
      (should-not (invisible-p (quarry-test-grep--heading-pos "sub/deep.txt")))
      ;; From the heading, open again.
      (quarry-test-grep--keys "TAB")
      (should-not (folded))
      ;; All: fold the rest when some are folded, unfold when all are.
      (goto-char (quarry-test-grep--heading-pos "notes.txt"))
      (quarry-test-grep--keys "TAB")
      (should (equal (folded) '(("notes.txt" 1))))
      (quarry-test-grep--keys "<backtab>")
      (should (equal (folded) (mapcar (lambda (r) (list (car r) (cadr r)))
                                      quarry-test-grep--needles)))
      (dolist (path (quarry-test-grep--headings))
        (should-not (invisible-p (quarry-test-grep--heading-pos path))))
      (quarry-test-grep--keys "<backtab>")
      (should-not (folded))
      ;; Not on a block.
      (goto-char (point-min))
      (should-error (quarry-grep-toggle-fold) :type 'user-error)
      ;; A new search starts unfolded.
      (quarry-grep-toggle-fold-all)
      (quarry-test-grep--keys "g")
      (should-not (folded)))))

;;;; Changing the search

(ert-deftest quarry-test-grep-rerun-and-toggles ()
  "g, c, i and H send the request they say and update the header."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-ignores '("notes.txt")))
      (quarry-test-grep--search dir)
      (should (equal (quarry-test-grep--request :ignores) '("notes.txt")))
      (should (equal (quarry-test-grep--headings)
                     '(".hidden.txt" "src/a.rs" "sub/deep.txt")))
      (let ((first (quarry-test-grep--request)))
        ;; g: the same request again.
        (delete-file (expand-file-name "sub/deep.txt" dir))
        (quarry-test-grep--keys "g")
        (should (= (length quarry-test-grep--requests) 2))
        (should (equal (quarry-test-grep--request) first))
        (should (equal (quarry-test-grep--headings) '(".hidden.txt" "src/a.rs")))
        ;; `revert-buffer' is the same.
        (revert-buffer)
        (quarry-test-grep--wait)
        (should (= (length quarry-test-grep--requests) 3))
        (should (equal (quarry-test-grep--request) first)))
      ;; c: smart, sensitive, insensitive, smart.
      (quarry-test-grep--keys "c")
      (should (eq (quarry-test-grep--request :case) :sensitive))
      (should (string-match-p "   case: sensitive   " (quarry-test-grep--header)))
      (should (equal (quarry-test-grep--results)
                     '((".hidden.txt" 1 "hidden needle")
                       ("src/a.rs" 2 "    let needle = 1;")
                       ("src/a.rs" 4 "// Needle again, needle"))))
      (quarry-test-grep--keys "c")
      (should (eq (quarry-test-grep--request :case) :insensitive))
      (should (string-match-p "   case: insensitive   " (quarry-test-grep--header)))
      (quarry-test-grep--keys "c")
      (should (eq (quarry-test-grep--request :case) :smart))
      ;; i: no ignore files and no extra ignore lines.
      (quarry-test-grep--keys "i")
      (should (eq (quarry-test-grep--request :no-ignore) t))
      (should-not (quarry-test-grep--request :ignores))
      (should (string-match-p "   ign: off   " (quarry-test-grep--header)))
      (should (equal (quarry-test-grep--headings)
                     '(".hidden.txt" "ignored.txt" "notes.txt" "src/a.rs")))
      (quarry-test-grep--keys "i")
      (should-not (quarry-test-grep--request :no-ignore))
      (should (equal (quarry-test-grep--request :ignores) '("notes.txt")))
      (should (string-match-p "   ign: on   " (quarry-test-grep--header)))
      ;; H: hidden files.
      (quarry-test-grep--keys "H")
      (should-not (quarry-test-grep--request :hidden))
      (should (plist-member (cdr (quarry-test-grep--request)) :hidden))
      (should (string-match-p "   hidden: off   " (quarry-test-grep--header)))
      (should (equal (quarry-test-grep--headings) '("src/a.rs")))
      (quarry-test-grep--keys "H")
      (should (eq (quarry-test-grep--request :hidden) t)))
    ;; The options are where a new search starts from.
    (let ((quarry-include-hidden nil)
          (quarry-grep-case 'sensitive))
      (quarry-test-grep--search dir)
      (should-not (quarry-test-grep--request :hidden))
      (should (eq (quarry-test-grep--request :case) :sensitive))
      (should-not (quarry-test-grep--request :no-ignore)))))

(ert-deftest quarry-test-grep-change-directory-and-files ()
  "d and f ask as the commands do and search with the answer."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    ;; f: a type, globs, everything; the default is what is searched now.
    (quarry-test-grep--keys "f txt RET")
    (should (equal (quarry-test-grep--request :file-type) "txt"))
    (should (string-prefix-p " files: txt   " (quarry-test-grep--header)))
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "notes.txt" "sub/deep.txt")))
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "f RET")))))
      (should (string-match-p "(default txt): " (car (car prompts)))))
    (should (equal (quarry-test-grep--request :file-type) "txt"))
    (quarry-test-grep--keys "f *.rs SPC *.md RET")
    (should (equal (quarry-test-grep--request :globs) '("*.rs" "*.md")))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :file-type))
    (should (string-prefix-p " files: *.rs *.md   " (quarry-test-grep--header)))
    (should (equal (quarry-test-grep--headings) '("src/a.rs")))
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "f everything RET")))))
      (should (string-match-p "(default \\*\\.rs \\*\\.md): " (car (car prompts)))))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :globs))
    (should (equal (quarry-test-grep--results) quarry-test-grep--needles))
    ;; d: the directory; paths are relative to it.
    (let ((sub (expand-file-name "sub/" dir)))
      (quarry-test-grep--keys (vconcat (kbd "d C-a C-k") sub (kbd "RET")))
      (should (equal (quarry-test-grep--request :dir) sub))
      (should (equal default-directory sub))
      (should (string-match-p (regexp-quote (format "   dir: %s   " (abbreviate-file-name sub)))
                              (quarry-test-grep--header)))
      (should (equal (quarry-test-grep--results) '(("deep.txt" 1 "über needle"))))
      ;; A directory that is not one changes nothing.
      (let ((sent (length quarry-test-grep--requests)))
        (pop-to-buffer-same-window (quarry-test-grep--buffer))
        (should-error
         (execute-kbd-macro (vconcat (kbd "d C-a C-k") dir "nope/" (kbd "RET")))
         :type 'user-error)
        (should (= (length quarry-test-grep--requests) sent))
        (should (equal (quarry-grep--search-dir quarry-grep--current) sub))))))

(ert-deftest quarry-test-grep-edit-pattern ()
  "RET on the filter line, r, t and % change the first filter."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    ;; RET on the filter line: the minibuffer holds the pattern.
    (goto-char (point-min))
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "RET C-a C-k hidden RET")))))
      (should (equal prompts '(("Line regexp: " . "needle")))))
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "hidden" nil))))
    (should (equal (quarry-test-grep--request :filters)
                   '((:target :line :exclude nil :pattern "hidden" :regexp t))))
    (should (equal (quarry-test-grep--results) '((".hidden.txt" 1 "hidden needle"))))
    ;; t from anywhere: the same pattern as a literal.
    (goto-char (point-max))
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "t C-a C-k main() RET")))))
      (should (equal prompts '(("Line literal: " . "hidden")))))
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line" "main()" nil))))
    (should (equal (quarry-test-grep--request :filters)
                   '((:target :line :exclude nil :pattern "main()" :regexp nil))))
    (should (equal (quarry-test-grep--results) '(("src/a.rs" 1 "fn main() {"))))
    ;; r: as a regexp.
    (quarry-test-grep--keys "r C-a C-k ^fn SPC \\w+ RET")
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "^fn \\w+" nil))))
    (should (equal (quarry-test-grep--results)
                   '(("src/a.rs" 1 "fn main() {") ("src/b.rs" 1 "fn other() {}"))))
    ;; %: literal and regexp, on a filter line only.
    (goto-char (point-min))
    (quarry-test-grep--keys "%")
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line" "^fn \\w+" nil))))
    (should-not (quarry-test-grep--results))
    (should (= (point) (point-min)))
    (quarry-test-grep--keys "%")
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "^fn \\w+" nil))))
    (goto-char (quarry-test-grep--heading-pos "src/a.rs"))
    (should-error (quarry-grep-toggle-regexp) :type 'user-error)
    ;; An empty pattern is refused and nothing is searched.
    (let ((sent (length quarry-test-grep--requests)))
      (goto-char (point-min))
      (let ((err (should-error (execute-kbd-macro (kbd "RET C-a C-k RET"))
                               :type 'user-error)))
        (should (string-match-p "pattern is empty" (cadr err))))
      (should-error (execute-kbd-macro (kbd "r C-a C-k RET")) :type 'user-error)
      (should (= (length quarry-test-grep--requests) sent))
      (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "^fn \\w+" nil)))))))

(ert-deftest quarry-test-grep-history ()
  "Each differing search is an entry; back and forward run it again."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (cl-flet ((shown () (list (quarry-grep--search-case quarry-grep--current)
                              (quarry-grep--search-hidden quarry-grep--current)
                              (cadr (car (quarry-test-grep--filter-lines)))))
              (depth () (list (length quarry-grep--past) (length quarry-grep--future))))
      (should (equal (depth) '(0 0)))
      (should-error (quarry-grep-history-back) :type 'user-error)
      ;; The same search again is no entry.
      (quarry-test-grep--keys "g")
      (should (equal (depth) '(0 0)))
      (quarry-test-grep--keys "c")
      (quarry-test-grep--keys "H")
      (goto-char (point-min))
      ;; A change of a filter is an entry too.
      (quarry-test-grep--keys "%")
      (should (equal (shown) '(sensitive nil "line")))
      (should (equal (depth) '(3 0)))
      (let ((sent (length quarry-test-grep--requests)))
        (quarry-test-grep--keys "C-c <")
        (should (equal (shown) '(sensitive nil "line/re")))
        (should (equal (depth) '(2 1)))
        ;; It ran: one more request, for that search.
        (should (= (length quarry-test-grep--requests) (1+ sent)))
        (should (eq (quarry-test-grep--request :case) :sensitive))
        (should-not (quarry-test-grep--request :hidden))
        ;; Without the hidden file.
        (should (equal (quarry-test-grep--results) (cdr quarry-test-grep--needles))))
      (quarry-test-grep--keys "C-c <")
      (quarry-test-grep--keys "C-c <")
      (should (equal (shown) '(smart t "line/re")))
      (should (equal (depth) '(0 3)))
      (should (equal (quarry-test-grep--results) quarry-test-grep--needles))
      (should-error (quarry-grep-history-back) :type 'user-error)
      (quarry-test-grep--keys "C-c >")
      (should (equal (shown) '(sensitive t "line/re")))
      (should (equal (depth) '(1 2)))
      ;; g in the middle keeps both directions.
      (quarry-test-grep--keys "g")
      (should (equal (depth) '(1 2)))
      (quarry-test-grep--keys "C-c >")
      (quarry-test-grep--keys "C-c >")
      (should (equal (shown) '(sensitive nil "line")))
      (should (equal (depth) '(3 0)))
      (should-error (quarry-grep-history-forward) :type 'user-error)
      ;; A new search after going back drops what was ahead.
      (quarry-test-grep--keys "C-c <")
      (quarry-test-grep--keys "i")
      (should (equal (depth) '(3 0)))
      (should-error (quarry-grep-history-forward) :type 'user-error)
      ;; A command reuses the buffer and its history.
      (quarry-test-grep--search dir "other")
      (should (equal (depth) '(4 0)))
      (quarry-test-grep--keys "C-c <")
      (should (eq (quarry-grep--search-no-ignore quarry-grep--current) t)))))

;;;; Streams

(defun quarry-test-grep--item (path &rest lines)
  "Return a file item for PATH with LINES, each (N TEXT START END)."
  (list :file :path path :path-spans nil :mtime 1760103296123
        :lines (mapcar (lambda (line)
                         (list :n (nth 0 line) :text (nth 1 line)
                               :spans (list (list (nth 2 line) (nth 3 line)))
                               :secondary nil :inexact nil))
                       lines)))

(ert-deftest quarry-test-grep-arriving-results-keep-positions ()
  "Results go before the status line; point and window start stay."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (let* ((results (quarry-test-grep--buffer))
             (window (get-buffer-window results))
             (on-batch (nth 1 (car quarry-test-grep--fake)))
             (on-end (nth 2 (car quarry-test-grep--fake)))
             (n 0))
        (should (eq window (selected-window)))
        (should (eq (quarry-test-grep--state) 'running))
        (should (equal (quarry-test-grep--status) "Searching…"))
        (should (string-suffix-p "hits: 0 in 0 files" (quarry-test-grep--header)))
        (cl-flet ((feed ()
                    ;; From a process filter: any buffer may be current.
                    (with-temp-buffer
                      (funcall on-batch
                               (list (quarry-test-grep--item
                                      (format "f%d.txt" (cl-incf n))
                                      '(1 "needle one" 0 6) '(7 "a needle" 2 8))
                                     (quarry-test-grep--item
                                      (format "f%d.txt" (cl-incf n))
                                      '(3 "needle" 0 6)))))))
          (with-current-buffer results
            (dolist (place (list (point-max)
                                 (text-property-any (point-min) (point-max)
                                                    'quarry-grep-status t)
                                 (+ (point-min) 3)))
              (goto-char place)
              (set-window-point window place)
              (dolist (start (list (point-min) place))
                (set-window-start window start)
                (feed)
                (should (= (point) place))
                (should (= (window-point window) place))
                (should (= (window-start window) start))
                (should (equal (quarry-test-grep--status) "Searching…"))))
            ;; A second window on the buffer keeps its own place.
            (let ((other (split-window window))
                  (place (quarry-test-grep--line-pos "f1.txt" 7))
              (end (point-max)))
              (set-window-buffer other results)
              (set-window-point other end)
              (set-window-start other place)
              (feed)
              (should (= (window-point other) end))
              (should (= (window-start other) place))
              (should (> (point-max) end))
              (delete-window other))))
        ;; In arrival order, and counted in the header as they arrive.
        (should (equal (quarry-test-grep--headings)
                       (cl-loop for i from 1 to n collect (format "f%d.txt" i))))
        (should (string-suffix-p (format "hits: %d in %d files" (* 3 (/ n 2)) n)
                                 (quarry-test-grep--header)))
        (should (equal (seq-take (quarry-test-grep--results) 3)
                       '(("f1.txt" 1 "needle one") ("f1.txt" 7 "a needle")
                         ("f2.txt" 3 "needle"))))
        ;; The summary and the end.
        (funcall on-batch (list (list :summary :files-searched 40 :files-matched n
                                      :lines (* 3 (/ n 2)) :truncated nil :sorted nil
                                      :millis 321 :skipped 2)))
        (should (equal (quarry-test-grep--status) "Searching…"))
        (funcall on-end 'done nil)
        (should (eq (quarry-test-grep--state) 'done))
        (should (equal (quarry-test-grep--status)
                       (format "Search finished: %d lines in %d files, 321 ms, 2 files skipped (could not be read)"
                               (* 3 (/ n 2)) n)))))))

(ert-deftest quarry-test-grep-superseded-search ()
  "Items and the end of a search that was replaced do not appear."
  (quarry-test-grep--with-tree (dir)
    (let ((cancelled nil))
      (advice-add 'emrs-cancel :before (lambda (call) (push call cancelled))
                  '((name . quarry-test-grep-cancel)))
      (unwind-protect
          (progn
            ;; No process output is read between the two searches.
            (quarry-grep "needle" nil dir)
            (quarry-grep-literal "other" nil dir)
            (should (= (length quarry-test-grep--calls) 2))
            (should (equal cancelled (list (cadr quarry-test-grep--calls))))
            (should (emrs-call-done (cadr quarry-test-grep--calls)))
            (quarry-test-grep--wait)
            (should (equal (quarry-test-grep--results) '(("src/b.rs" 1 "fn other() {}"))))
            ;; Items of the first search would come in this time.
            (quarry-test--wait #'ignore 0.3)
            (should (equal (quarry-test-grep--results) '(("src/b.rs" 1 "fn other() {}"))))
            (should (eq (quarry-test-grep--state) 'done))
            (should (string-match-p "\\`Search finished: 1 line in 1 file, "
                                    (quarry-test-grep--status))))
        (advice-remove 'emrs-cancel 'quarry-test-grep-cancel)))
    ;; The callbacks of a superseded search, called late.
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (quarry-grep "needle" nil dir)
      (pcase-let ((`((,_ ,new-batch ,_) (,_ ,old-batch ,old-end)) quarry-test-grep--fake))
        (funcall old-batch (list (quarry-test-grep--item "old.txt" '(1 "needle" 0 6))))
        (funcall old-end 'done nil)
        (should (eq (quarry-test-grep--state) 'running))
        (should-not (quarry-test-grep--headings))
        (funcall new-batch (list (quarry-test-grep--item "new.txt" '(1 "needle" 0 6))))
        (should (equal (quarry-test-grep--headings) '("new.txt")))
        ;; A killed buffer is left alone.
        (kill-buffer (quarry-test-grep--buffer))
        (funcall new-batch (list (quarry-test-grep--item "late.txt" '(1 "needle" 0 6))))
        (funcall old-end 'done nil)
        (should-not (quarry-test-grep--buffer))))))

(ert-deftest quarry-test-grep-cancel ()
  "C-c C-k cancels the running search; so does killing the buffer."
  (quarry-test-grep--with-tree
      (dir (cl-loop for i from 0 below 200
                    collect (cons (format "d%d/f%d.txt" (% i 10) i)
                                  (apply #'concat (make-list 20 "a needle here\n")))))
    ;; The search was sent and no process output has been read, so it
    ;; cannot have ended on the Lisp side.
    (quarry-grep "needle" nil dir)
    (let ((call (car quarry-test-grep--calls)))
      (should (eq (quarry-test-grep--state) 'running))
      (should-not (emrs-call-done call))
      (quarry-test-grep--keys "C-c C-k")
      (should (emrs-call-done call))
      (should (eq (quarry-test-grep--state) 'cancelled))
      (should (equal (quarry-test-grep--status)
                     "Search cancelled: 0 lines in 0 files so far"))
      ;; Nothing arrives afterwards.
      (quarry-test--wait #'ignore 0.3)
      (should-not (quarry-test-grep--results))
      (should (eq (quarry-test-grep--state) 'cancelled))
      (should-error (quarry-grep-cancel) :type 'user-error))
    ;; A cancelled search keeps what had arrived, and can be run again.
    (quarry-test-grep--with-fake-stream
      (quarry-grep-rerun)
      (funcall (nth 1 (car quarry-test-grep--fake))
               (list (quarry-test-grep--item "d0/f0.txt" '(1 "a needle here" 2 8))))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil)
      (should (equal (quarry-test-grep--status)
                     "Search cancelled: 1 line in 1 file so far"))
      (should (equal (quarry-test-grep--headings) '("d0/f0.txt"))))
    (quarry-test-grep--keys "g")
    (should (eq (quarry-test-grep--state) 'done))
    (should (string-match-p "\\`Search finished: 4000 lines in 200 files, "
                            (quarry-test-grep--status)))
    ;; Killing the buffer cancels.
    (quarry-grep-rerun)
    (let ((call (car quarry-test-grep--calls)))
      (should-not (emrs-call-done call))
      (kill-buffer (quarry-test-grep--buffer))
      (should (emrs-call-done call)))))

;;;; Errors

(ert-deftest quarry-test-grep-invalid-regexp ()
  "An invalid regexp is shown with its pattern and corrected with RET."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir "main(")
    (should (eq (quarry-test-grep--state) 'failed))
    (should (string-prefix-p "Search failed: invalid filter `main(`: "
                             (quarry-test-grep--status)))
    (should (eq (get-text-property
                 (text-property-any (point-min) (point-max) 'quarry-grep-status t) 'face)
                'quarry-grep-error))
    ;; The filter stays, and RET on it corrects it.
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "main(" nil))))
    (should (eq quarry-grep--error-filter
                (car (quarry-grep--search-filters quarry-grep--current))))
    (should-not (quarry-test-grep--results))
    (should (= (point) (point-min)))
    (quarry-test-grep--keys "RET C-a C-k main\\( RET")
    (should (eq (quarry-test-grep--state) 'done))
    (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "main\\(" nil))))
    (should (equal (quarry-test-grep--results) '(("src/a.rs" 1 "fn main() {"))))
    (should-not quarry-grep--error-filter)
    ;; The service counts the filters it was sent: a disabled one before
    ;; the bad one must not shift the blame.
    (let ((search (quarry-grep--copy-search quarry-grep--current)))
      (setf (quarry-grep--search-filters search)
            (list (quarry-grep--make-filter :pattern "needle")
                  (quarry-grep--make-filter :pattern "(" :regexp t :enabled nil)
                  (quarry-grep--make-filter :target 'path :pattern "[" :regexp t
                                            :exclude t)))
      (quarry-grep--run search)
      (quarry-test-grep--wait)
      (should (eq (quarry-test-grep--state) 'failed))
      (should (string-prefix-p "Search failed: invalid filter `[`: "
                               (quarry-test-grep--status)))
      (should (eq quarry-grep--error-filter (nth 2 (quarry-grep--search-filters search))))
      ;; Point is on the filter to correct.
      (should (eq (get-text-property (point) 'quarry-grep-filter)
                  quarry-grep--error-filter))
      (should (= (length (quarry-test-grep--filter-lines)) 3)))))

(ert-deftest quarry-test-grep-directory-errors ()
  "Missing, plain-file and remote directories; a directory that vanished."
  (quarry-test-grep--with-tree (dir)
    (let ((err (should-error (quarry-grep "x" nil (expand-file-name "nope" dir))
                             :type 'user-error)))
      (should (string-match-p "does not exist" (cadr err))))
    (let ((err (should-error (quarry-grep "x" nil (expand-file-name "notes.txt" dir))
                             :type 'user-error)))
      (should (string-match-p "Not a directory" (cadr err))))
    ;; At the prompt.
    (with-temp-buffer
      (setq default-directory dir)
      (switch-to-buffer (current-buffer))
      (should-error
       (execute-kbd-macro
        (vconcat (kbd "M-x quarry-grep RET x RET RET C-a C-k") dir "nope/" (kbd "RET")))
       :type 'user-error))
    ;; Remote: refused without a connection, and rg.el is named.
    (dolist (call (list (lambda () (quarry-grep "x" nil "/ssh:quarry-test.invalid:/tmp/"))
                        (lambda () (quarry-grep-literal "x" nil "/ssh:quarry-test.invalid:/tmp/"))
                        (lambda ()
                          (let ((default-directory "/ssh:quarry-test.invalid:/tmp/"))
                            (quarry-grep-project "x" nil)))
                        (lambda ()
                          (with-temp-buffer
                            (insert "symbol")
                            (let ((default-directory "/ssh:quarry-test.invalid:/tmp/"))
                              (quarry-grep-dwim))))))
      (let ((err (should-error (funcall call) :type 'user-error)))
        (should (string-match-p "local directories only" (cadr err)))
        (should (string-match-p "rg\\.el" (cadr err)))))
    (should-not (quarry-test-grep--buffer))
    (should-not quarry-test-grep--requests)
    ;; A directory that vanished before a rerun: in the status line.
    (let ((sub (expand-file-name "sub/" dir)))
      (quarry-test-grep--search sub)
      (should (equal (quarry-test-grep--results) '(("deep.txt" 1 "über needle"))))
      (delete-directory sub t)
      (quarry-test-grep--keys "g")
      (should (eq (quarry-test-grep--state) 'failed))
      (should (string-match-p (concat "\\`Search failed: grep directory "
                                      (regexp-quote sub) " cannot be used: ")
                              (quarry-test-grep--status)))
      (should-not (quarry-test-grep--results))
      (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "needle" nil)))))))

(ert-deftest quarry-test-grep-empty-pattern ()
  "An empty pattern is a `user-error', before the other prompts."
  (quarry-test-grep--with-tree (dir)
    (dolist (call (list (lambda () (quarry-grep "" nil dir))
                        (lambda () (quarry-grep-literal "" nil dir))
                        (lambda () (quarry-grep-project "" nil))))
      (let ((err (should-error (funcall call) :type 'user-error)))
        (should (string-match-p "pattern is empty" (cadr err)))))
    (with-temp-buffer
      (setq default-directory dir)
      (switch-to-buffer (current-buffer))
      (let ((prompts nil))
        (let ((minibuffer-setup-hook
               (cons (lambda () (push (minibuffer-prompt) prompts))
                     minibuffer-setup-hook)))
          (should-error (execute-kbd-macro (kbd "M-x quarry-grep RET RET RET RET"))
                        :type 'user-error))
        ;; M-x and the pattern prompt, nothing after it.
        (should (equal prompts '("Regexp search for: " "M-x ")))))
    (should-not (quarry-test-grep--buffer))
    (should-not quarry-test-grep--requests)))

(ert-deftest quarry-test-grep-instance ()
  "One instance, started on first use; a new one after it stopped or failed."
  (quarry-test-grep--with-tree (dir)
    (let ((index-instances (hash-table-count quarry--instances)))
      (quarry-test-grep--search dir)
      ;; No index instance is involved.
      (should (= (hash-table-count quarry--instances) index-instances)))
    (let ((first quarry-grep--instance))
      (should (emrs-instance-p first))
      (quarry-test-grep--keys "g")
      (should (eq quarry-grep--instance first))
      ;; A search whose instance fails: the calls fail first, with a
      ;; message that does not say why, then the exit handler runs.
      (quarry-test-grep--with-fake-stream
        (quarry-grep-rerun)
        (should (eq (quarry-test-grep--state) 'running))
        (funcall (nth 2 (car quarry-test-grep--fake))
                 'failed '(:kind failed :message "The instance terminated" :data nil))
        (should (eq (quarry-test-grep--state) 'failed))
        (should (equal (quarry-test-grep--status)
                       "Search failed: The instance terminated"))
        (let ((warnings nil))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (quarry-grep--on-exit first 'failed '(:kind failed :message "the task panicked")))
          (should (equal warnings '("The grep instance failed: the task panicked"))))
        (should (equal (quarry-test-grep--status) "Search failed: the task panicked"))
        (should-not quarry-grep--instance))
      ;; The exit of an older instance does not forget the current one.
      (setq quarry-grep--instance first)
      (quarry-grep--on-exit (emrs--make-instance) 'stopped nil)
      (should (eq quarry-grep--instance first))
      ;; The instance really stops: the next search starts a new one.
      (emrs-stop first)
      (quarry-test-grep--keys "g")
      (let ((second quarry-grep--instance))
        (should (emrs-instance-p second))
        (should-not (eq second first))
        (should (eq (quarry-test-grep--state) 'done))
        (should (equal (quarry-test-grep--results) quarry-test-grep--needles))
        (should (quarry-test--wait
                 (lambda () (eq (emrs-instance-state first) 'stopped))))
        (should (eq quarry-grep--instance second))
        ;; A stop while a search runs ends it with an error.
        (quarry-grep-rerun)
        (emrs-stop second)
        (quarry-test-grep--wait)
        (should (memq (quarry-test-grep--state) '(failed done)))
        (should (quarry-test--wait (lambda () (null quarry-grep--instance))))
        (quarry-test-grep--keys "g")
        (should (eq (quarry-test-grep--state) 'done))
        (should-not (memq quarry-grep--instance (list first second)))
        (should (equal (quarry-test-grep--results) quarry-test-grep--needles))))))

(ert-deftest quarry-test-grep-module-missing ()
  "A missing module is the shared `user-error'; no buffer is made."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-grep--instance nil))
      (cl-letf (((symbol-function 'emrs-load-module)
                 (lambda (&rest _)
                   (signal 'file-missing '("Cannot open load file" "quarry-module")))))
        (let ((err (should-error (quarry-grep "needle" nil dir) :type 'user-error)))
          (should (string-match-p "Cannot load the quarry module" (cadr err))))
        (should-not (quarry-test-grep--buffer))
        (should-not quarry-grep--instance)))))

(ert-deftest quarry-test-grep-header-clicks ()
  "The parts of the header line run their commands on a click."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (pop-to-buffer-same-window (quarry-test-grep--buffer))
    (let ((header (quarry-grep--header))
          (parts nil)
          (pos 0))
      ;; Collect (TEXT HELP COMMAND-RUN-BY-MOUSE-1) of the clickable runs.
      (while (setq pos (text-property-not-all pos (length header) 'keymap nil header))
        (let ((end (or (next-single-property-change pos 'keymap header) (length header))))
          (push (list (substring-no-properties header pos end)
                      (get-text-property pos 'help-echo header)
                      (lookup-key (get-text-property pos 'keymap header)
                                  [header-line mouse-1])
                      (get-text-property pos 'mouse-face header))
                parts)
          (setq pos end)))
      (setq parts (nreverse parts))
      (should (equal (mapcar #'car parts)
                     (list "everything" (abbreviate-file-name dir) "smart" "on" "on")))
      (dolist (part parts)
        (should (string-prefix-p "mouse-1: " (nth 1 part)))
        (should (commandp (nth 2 part)))
        (should (eq (nth 3 part) 'header-line-highlight)))
      ;; mouse-2 runs the same command.
      (should (eq (lookup-key (get-text-property (string-search "smart" header)
                                                 'keymap header)
                              [header-line mouse-2])
                  (nth 2 (nth 2 parts))))
      ;; The hits are not clickable.
      (should-not (get-text-property (string-search "5 in 4" header) 'keymap header))
      (let ((click (list 'mouse-1 (list (selected-window) 'header-line '(0 . 0) 0))))
        (funcall (nth 2 (nth 2 parts)) click)
        (quarry-test-grep--wait)
        (should (eq (quarry-test-grep--request :case) :sensitive))
        (funcall (nth 2 (nth 3 parts)) click)
        (quarry-test-grep--wait)
        (should (eq (quarry-test-grep--request :no-ignore) t))
        (funcall (nth 2 (nth 4 parts)) click)
        (quarry-test-grep--wait)
        (should-not (quarry-test-grep--request :hidden))
        ;; The two that ask.
        (let ((asked nil))
          (cl-letf (((symbol-function 'quarry-grep-change-files)
                     (lambda () (interactive) (push 'files asked)))
                    ((symbol-function 'quarry-grep-change-directory)
                     (lambda () (interactive) (push 'directory asked))))
            (funcall (nth 2 (nth 0 parts)) click)
            (funcall (nth 2 (nth 1 parts)) click))
          (should (equal asked '(directory files))))))))

;;;; Filters

(defun quarry-test-grep--filter-pos (n)
  "Return the start of the Nth filter line, counted from 0."
  (nth n (quarry-test-grep--lines-with 'quarry-grep-filter)))

(defun quarry-test-grep--run-filters (&rest filters)
  "Run the current search with FILTERS, lists of `quarry-grep--make-filter' arguments."
  (set-buffer (quarry-test-grep--buffer))
  (let ((search (quarry-grep--copy-search quarry-grep--current)))
    (setf (quarry-grep--search-filters search)
          (mapcar (lambda (args) (apply #'quarry-grep--make-filter args)) filters))
    (quarry-grep--run search)
    (quarry-test-grep--wait)))

(defun quarry-test-grep--sent ()
  "Return the filters of the last request as lists (TARGET EXCLUDE PATTERN REGEXP)."
  (mapcar (lambda (filter)
            (mapcar (lambda (key) (plist-get filter key))
                    '(:target :exclude :pattern :regexp)))
          (quarry-test-grep--request :filters)))

(defun quarry-test-grep--has-face (pos face)
  "Return non-nil when the text at POS of the result buffer has FACE."
  (with-current-buffer (quarry-test-grep--buffer)
    (let ((value (get-text-property pos 'face)))
      (if (listp value) (memq face value) (eq value face)))))

(defmacro quarry-test-grep--refused (message &rest body)
  "Check that BODY signals a `user-error' matching MESSAGE and sends nothing."
  (declare (indent 1))
  `(let ((sent (length quarry-test-grep--requests))
         (lines (quarry-test-grep--filter-lines)))
     (pop-to-buffer-same-window (quarry-test-grep--buffer))
     (let ((err (should-error (progn ,@body) :type 'user-error)))
       (should (string-match-p ,message (cadr err))))
     (should (= (length quarry-test-grep--requests) sent))
     (should (equal (quarry-test-grep--filter-lines) lines))))

(ert-deftest quarry-test-grep-add-filters ()
  "- p, + p, - l and + l ask for a pattern and append a filter."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-grep-line-filter-history nil)
          (quarry-grep-path-filter-history nil))
      (quarry-test-grep--search dir)
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "- p sub RET")))))
        (should (equal prompts '(("Exclude paths containing: " . "")))))
      (should (equal (quarry-test-grep--sent)
                     '((:line nil "needle" t) (:path t "sub" nil))))
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" nil) ("-" "path" "sub" nil))))
      (should (equal (quarry-test-grep--headings) '(".hidden.txt" "notes.txt" "src/a.rs")))
      ;; The uppercase keys take a regexp.
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "+ P \\.(rs|md)$ RET")))))
        (should (equal prompts '(("Keep only paths matching regexp: " . "")))))
      (should (equal (nth 2 (quarry-test-grep--sent)) '(:path nil "\\.(rs|md)$" t)))
      (should (equal (quarry-test-grep--headings) '("src/a.rs")))
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "- l again RET")))))
        (should (equal prompts '(("Exclude lines containing: " . "")))))
      (should (equal (nth 3 (quarry-test-grep--sent)) '(:line t "again" nil)))
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 2 "    let needle = 1;"))))
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "+ l = SPC 1 RET")))))
        (should (equal prompts '(("Keep only lines containing: " . "")))))
      (should (equal (nth 4 (quarry-test-grep--sent)) '(:line nil "= 1" nil)))
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "- L ^\\s*// RET")))))
        (should (equal prompts '(("Exclude lines matching regexp: " . "")))))
      (quarry-test-grep--keys "+ L let\\s RET")
      (quarry-test-grep--keys "- P \\.org$ RET")
      ;; A prefix argument does not make a regexp of it.
      (quarry-test-grep--keys "C-u + l needle RET")
      (should (equal (car (last (quarry-test-grep--sent))) '(:line nil "needle" nil)))
      (goto-char (quarry-test-grep--filter-pos 8))
      (quarry-test-grep--keys "k")
      (should (equal (quarry-test-grep--sent)
                     '((:line nil "needle" t) (:path t "sub" nil)
                       (:path nil "\\.(rs|md)$" t) (:line t "again" nil)
                       (:line nil "= 1" nil) (:line t "^\\s*//" t)
                       (:line nil "let\\s" t) (:path t "\\.org$" t))))
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" nil) ("-" "path" "sub" nil)
                       ("+" "path/re" "\\.(rs|md)$" nil) ("-" "line" "again" nil)
                       ("+" "line" "= 1" nil) ("-" "line/re" "^\\s*//" nil)
                       ("+" "line/re" "let\\s" nil) ("-" "path/re" "\\.org$" nil))))
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 2 "    let needle = 1;"))))
      ;; Each kind has its history.
      (should (equal quarry-grep-path-filter-history '("\\.org$" "\\.(rs|md)$" "sub")))
      (should (equal quarry-grep-line-filter-history
                     '("needle" "let\\s" "^\\s*//" "= 1" "again")))
      ;; An empty pattern.
      (quarry-test-grep--refused "pattern is empty" (execute-kbd-macro (kbd "- p RET")))
      (quarry-test-grep--refused "pattern is empty" (execute-kbd-macro (kbd "+ L RET")))
      ;; A filter the search has is not added again; the same pattern in
      ;; another direction or syntax is a different filter.
      (quarry-test-grep--refused "already has the filter - path sub"
        (execute-kbd-macro (kbd "- p sub RET")))
      (quarry-test-grep--refused "already has the filter \\+ line/re let"
        (execute-kbd-macro (kbd "+ L let\\s RET")))
      ;; One that is switched off is switched on instead.
      (goto-char (quarry-test-grep--filter-pos 1))
      (quarry-test-grep--keys "x")
      (should (equal (nth 1 (quarry-test-grep--filter-lines)) '("-" "path" "sub" "(off)")))
      (quarry-test-grep--keys "- p sub RET")
      (should (= (length (quarry-test-grep--filter-lines)) 8))
      (should (equal (nth 1 (quarry-test-grep--filter-lines)) '("-" "path" "sub" nil)))
      (quarry-test-grep--keys "+ p sub RET")
      (should (equal (nth 8 (quarry-test-grep--filter-lines)) '("+" "path" "sub" nil))))))

(ert-deftest quarry-test-grep-filters-from-point ()
  "- f, - d and + d take the file or directory of the result at point."
  (quarry-test-grep--with-tree (dir '(("top.txt" . "needle\n")
                                      ("a/b/c.txt" . "needle\n")
                                      ("a/d.txt" . "needle\n")
                                      ("e/f.txt" . "needle\n")))
    (let ((quarry-grep-path-filter-history nil))
      (quarry-test-grep--search dir)
      (should (equal (quarry-test-grep--headings)
                     '("a/b/c.txt" "a/d.txt" "e/f.txt" "top.txt")))
      ;; Not in a file block.
      (dolist (keys '("- f" "- d" "+ d"))
        (goto-char (point-min))
        (quarry-test-grep--refused "No file at point" (execute-kbd-macro (kbd keys))))
      ;; A file in the search directory has no directory to name.
      (dolist (keys '("- d" "+ d"))
        (goto-char (quarry-test-grep--line-pos "top.txt" 1))
        (quarry-test-grep--refused "top\\.txt is in the search directory itself"
          (execute-kbd-macro (kbd keys))))
      ;; - f, from a result line, without a prompt.
      (goto-char (quarry-test-grep--line-pos "a/d.txt" 1))
      (should-not (quarry-test-grep--prompts (lambda () (quarry-test-grep--keys "- f"))))
      (should (equal (quarry-test-grep--sent)
                     '((:line nil "needle" t) (:path t "/a/d.txt" nil))))
      (should (equal (quarry-test-grep--headings) '("a/b/c.txt" "e/f.txt" "top.txt")))
      ;; Point is on the file that follows the one that went.
      (should (= (point) (quarry-test-grep--heading-pos "e/f.txt")))
      ;; - d: the prompt holds the directory and is shortened to a parent.
      (goto-char (quarry-test-grep--heading-pos "a/b/c.txt"))
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "- d DEL DEL RET")))))
        (should (equal prompts '(("Exclude paths containing: " . "/a/b/")))))
      (should (equal (nth 2 (quarry-test-grep--sent)) '(:path t "/a/" nil)))
      (should (equal (quarry-test-grep--headings) '("e/f.txt" "top.txt")))
      (should (= (point) (quarry-test-grep--heading-pos "e/f.txt")))
      (should (equal (car quarry-grep-path-filter-history) "/a/"))
      ;; + d, as it stands, on the search before.
      (quarry-test-grep--keys "C-c <")
      (goto-char (quarry-test-grep--line-pos "a/b/c.txt" 1))
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "+ d RET")))))
        (should (equal prompts '(("Keep only paths containing: " . "/a/b/")))))
      (should (equal (quarry-test-grep--sent)
                     '((:line nil "needle" t) (:path t "/a/d.txt" nil)
                       (:path nil "/a/b/" nil))))
      (should (equal (quarry-test-grep--headings) '("a/b/c.txt")))
      (should (= (point) (quarry-test-grep--line-pos "a/b/c.txt" 1)))
      ;; The file is excluded already.
      (quarry-test-grep--keys "C-c <")
      (quarry-test-grep--keys "C-c <")
      (should (equal (quarry-test-grep--sent) '((:line nil "needle" t))))
      (quarry-test-grep--keys "C-c >")
      (goto-char (quarry-test-grep--filter-pos 1))
      (quarry-test-grep--keys "x")
      (should (member "a/d.txt" (quarry-test-grep--headings)))
      (goto-char (quarry-test-grep--heading-pos "a/d.txt"))
      (quarry-test-grep--keys "- f")
      ;; Switched on again, not added a second time.
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" nil) ("-" "path" "/a/d.txt" nil))))
      (should-not (member "a/d.txt" (quarry-test-grep--headings))))))

(ert-deftest quarry-test-grep-filter-line-commands ()
  "k, x, !, % and K change the filter at point; the primary one is kept."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (quarry-test-grep--run-filters '(:pattern "needle" :regexp t)
                                   '(:pattern "again")
                                   '(:target path :pattern "/sub/" :exclude t)
                                   '(:target path :pattern "txt" :enabled nil))
    (let ((all '(("+" "line/re" "needle" nil) ("+" "line" "again" nil)
                 ("-" "path" "/sub/" nil) ("+" "path" "txt" "(off)"))))
      (should (equal (quarry-test-grep--filter-lines) all))
      (should (equal (quarry-test-grep--sent)
                     '((:line nil "needle" t) (:line nil "again" nil) (:path t "/sub/" nil))))
      ;; Not on a filter line.
      (dolist (keys '("k" "x" "!" "%"))
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-test-grep--refused "No filter at point" (execute-kbd-macro (kbd keys))))
      ;; x: off, not sent, and on again; point stays on the line.
      (goto-char (1+ (quarry-test-grep--filter-pos 1)))
      (quarry-test-grep--keys "x")
      (should (equal (nth 1 (quarry-test-grep--filter-lines)) '("+" "line" "again" "(off)")))
      (should (equal (quarry-test-grep--sent) '((:line nil "needle" t) (:path t "/sub/" nil))))
      (should (= (length (quarry-test-grep--results)) 4))
      (should (= (point) (1+ (quarry-test-grep--filter-pos 1))))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--filter-lines) all))
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 4 "// Needle again, needle"))))
      ;; !: include and exclude.
      (quarry-test-grep--keys "!")
      (should (equal (nth 1 (quarry-test-grep--filter-lines)) '("-" "line" "again" nil)))
      (should (equal (nth 1 (quarry-test-grep--sent)) '(:line t "again" nil)))
      (should (= (length (quarry-test-grep--results)) 3))
      (quarry-test-grep--keys "!")
      (goto-char (quarry-test-grep--filter-pos 2))
      (quarry-test-grep--keys "!")
      (should (equal (nth 2 (quarry-test-grep--sent)) '(:path nil "/sub/" nil)))
      (should-not (quarry-test-grep--results))
      (quarry-test-grep--keys "!")
      ;; %: also on a path filter.
      (quarry-test-grep--keys "%")
      (should (equal (nth 2 (quarry-test-grep--filter-lines)) '("-" "path/re" "/sub/" nil)))
      (should (equal (nth 2 (quarry-test-grep--sent)) '(:path t "/sub/" t)))
      (quarry-test-grep--keys "%")
      (should (equal (quarry-test-grep--filter-lines) all))
      ;; k: the line that takes its place; from the last line, the new
      ;; last line.
      (should (= (point) (quarry-test-grep--filter-pos 2)))
      (quarry-test-grep--keys "k")
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" nil) ("+" "line" "again" nil)
                       ("+" "path" "txt" "(off)"))))
      (should (= (point) (quarry-test-grep--filter-pos 2)))
      (quarry-test-grep--keys "k")
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" nil) ("+" "line" "again" nil))))
      (should (= (point) (quarry-test-grep--filter-pos 1)))
      (should (equal (quarry-test-grep--sent) '((:line nil "needle" t) (:line nil "again" nil))))
      ;; The primary filter goes: the next include line filter takes over.
      (should (eql (get-text-property (quarry-test-grep--line-pos "src/a.rs" 4)
                                      'quarry-grep-column)
                   3))
      (goto-char (point-min))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--filter-lines)
                     '(("+" "line/re" "needle" "(off)") ("+" "line" "again" nil))))
      (should (eq (quarry-grep--primary quarry-grep--current)
                  (get-text-property (quarry-test-grep--filter-pos 1) 'quarry-grep-filter)))
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 4 "// Needle again, needle"))))
      (should (eql (get-text-property (quarry-test-grep--line-pos "src/a.rs" 4)
                                      'quarry-grep-column)
                   10))
      ;; r and t edit the one that is primary now.
      (let ((prompts (quarry-test-grep--prompts
                      (lambda () (quarry-test-grep--keys "t RET")))))
        (should (equal prompts '(("Line literal: " . "again")))))
      ;; The only enabled include line filter cannot be lost.
      (goto-char (quarry-test-grep--filter-pos 1))
      (dolist (keys '("k" "x" "!"))
        (quarry-test-grep--refused "needs an enabled include line filter"
          (execute-kbd-macro (kbd keys))))
      ;; With the other one on again, each of the three is allowed.
      (goto-char (point-min))
      (quarry-test-grep--keys "x")
      (quarry-test-grep--keys "!")
      (should (equal (quarry-test-grep--filter-lines)
                     '(("-" "line/re" "needle" nil) ("+" "line" "again" nil))))
      (should-not (quarry-test-grep--results))
      (quarry-test-grep--keys "k")
      (should (equal (quarry-test-grep--filter-lines) '(("+" "line" "again" nil))))
      (quarry-test-grep--refused "needs an enabled include line filter"
        (execute-kbd-macro (kbd "k")))
      ;; K: only the primary filter stays, from anywhere.
      (quarry-test-grep--refused "no other filters" (execute-kbd-macro (kbd "K")))
      (quarry-test-grep--run-filters '(:pattern "hidden" :enabled nil)
                                     '(:pattern "zzz" :exclude t)
                                     '(:pattern "needle" :regexp t)
                                     '(:pattern "again")
                                     '(:target path :pattern "txt" :enabled nil))
      (let ((before (quarry-test-grep--filter-lines)))
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-test-grep--keys "K")
        (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "needle" nil))))
        (should (equal (quarry-test-grep--sent) '((:line nil "needle" t))))
        (should (equal (quarry-test-grep--results) quarry-test-grep--needles))
        ;; History holds the whole list, the disabled filters too.
        (quarry-test-grep--keys "C-c <")
        (should (equal (quarry-test-grep--filter-lines) before))
        (should (equal (quarry-test-grep--sent)
                       '((:line t "zzz" nil) (:line nil "needle" t) (:line nil "again" nil))))
        (quarry-test-grep--keys "C-c <")
        (should (equal (quarry-test-grep--filter-lines) '(("+" "line" "again" nil))))
        (quarry-test-grep--keys "C-c >")
        (quarry-test-grep--keys "C-c >")
        (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "needle" nil))))))))

(ert-deftest quarry-test-grep-highlighting ()
  "Primary, secondary and path matches have their faces; two options."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (cl-flet ((faces ()
                ;; For "// Needle again, needle": P, S or - per character.
                (let* ((bol (quarry-test-grep--line-pos "src/a.rs" 4))
                       (text (next-single-property-change bol 'quarry-grep-prefix)))
                  (mapconcat (lambda (i)
                               (cond ((quarry-test-grep--has-face (+ text i) 'quarry-grep-match)
                                      "P")
                                     ((quarry-test-grep--has-face
                                       (+ text i) 'quarry-grep-match-secondary)
                                      "S")
                                     (t "-")))
                             (number-sequence 0 22) "")))
              (path-faces ()
                ;; For the heading's "src/a.rs": M where a path filter matched.
                (let ((path (+ (quarry-test-grep--heading-pos "src/a.rs") 6)))
                  (should (equal (buffer-substring-no-properties path (+ path 8)) "src/a.rs"))
                  (mapconcat (lambda (i)
                               (should (quarry-test-grep--has-face
                                        (+ path i) 'quarry-grep-file-heading))
                               (if (quarry-test-grep--has-face (+ path i) 'quarry-grep-path-match)
                                   "M"
                                 "-"))
                             (number-sequence 0 7) "")))
              (pattern-face (n)
                (get-text-property
                 (text-property-any (quarry-test-grep--filter-pos n) (point-max)
                                    'quarry-grep-part 'pattern)
                 'face)))
      (should (equal (faces) "---PPPPPP--------PPPPPP"))
      (should (equal (path-faces) "--------"))
      (should (eq (pattern-face 0) 'quarry-grep-match))
      ;; A second include line filter, one whose match overlaps a primary
      ;; one (the rest of it lies next to that), and two path filters.
      (quarry-test-grep--keys "+ l again RET")
      (quarry-test-grep--keys "+ l Needle SPC a RET")
      (quarry-test-grep--keys "+ p rc/ RET")
      (quarry-test-grep--keys "+ P \\.rs$ RET")
      (quarry-test-grep--keys "- l zzz RET")
      (should (equal (quarry-test-grep--results) '(("src/a.rs" 4 "// Needle again, needle"))))
      (should (equal (faces) "---PPPPPPSSSSSS--PPPPPP"))
      (should (equal (path-faces) "-MMM-MMM"))
      (should (eql (get-text-property (quarry-test-grep--line-pos "src/a.rs" 4)
                                      'quarry-grep-column)
                   3))
      ;; The filter block shows which colour is whose.
      (should (equal (mapcar #'pattern-face '(0 1 2 3 4 5))
                     '(quarry-grep-match quarry-grep-match-secondary
                       quarry-grep-match-secondary quarry-grep-path-match
                       quarry-grep-path-match quarry-grep-filter-pattern)))
      ;; A filter that is off has no colour.
      (goto-char (quarry-test-grep--filter-pos 1))
      (quarry-test-grep--keys "x")
      (should (eq (pattern-face 1) 'quarry-grep-filter-disabled))
      (should (equal (faces) "---PPPPPPSS------PPPPPP"))
      (quarry-test-grep--keys "x")
      ;; The options, read at the next search.
      (let ((quarry-grep-highlight-include-filters nil))
        (should (equal (faces) "---PPPPPPSSSSSS--PPPPPP"))
        (quarry-test-grep--keys "g")
        (should (equal (faces) "---PPPPPP--------PPPPPP"))
        (should (equal (path-faces) "-MMM-MMM"))
        (should (equal (mapcar #'pattern-face '(0 1 2 3 4 5))
                       '(quarry-grep-match quarry-grep-filter-pattern
                         quarry-grep-filter-pattern quarry-grep-path-match
                         quarry-grep-path-match quarry-grep-filter-pattern))))
      (let ((quarry-grep-highlight-path-filters nil))
        (quarry-test-grep--keys "g")
        (should (equal (faces) "---PPPPPPSSSSSS--PPPPPP"))
        (should (equal (path-faces) "--------"))
        (should (equal (mapcar #'pattern-face '(0 1 2 3 4 5))
                       '(quarry-grep-match quarry-grep-match-secondary
                         quarry-grep-match-secondary quarry-grep-filter-pattern
                         quarry-grep-filter-pattern quarry-grep-filter-pattern))))
      (should (equal (list (default-value 'quarry-grep-highlight-include-filters)
                           (default-value 'quarry-grep-highlight-path-filters))
                     '(t t)))
      (dolist (face '(quarry-grep-match quarry-grep-match-secondary quarry-grep-path-match))
        (should (facep face))))))

(ert-deftest quarry-test-grep-point-returns ()
  "A search started in the buffer brings point back to its result."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    ;; The same line.
    (goto-char (+ (quarry-test-grep--line-pos "src/a.rs" 4) 9))
    (quarry-test-grep--keys "g")
    (should (= (point) (quarry-test-grep--line-pos "src/a.rs" 4)))
    (should (= (window-point) (point)))
    (quarry-test-grep--keys "c")
    (should (= (point) (quarry-test-grep--line-pos "src/a.rs" 4)))
    (quarry-test-grep--keys "C-c <")
    (should (= (point) (quarry-test-grep--line-pos "src/a.rs" 4)))
    ;; A heading.
    (goto-char (quarry-test-grep--heading-pos "notes.txt"))
    (quarry-test-grep--keys "H")
    (should (= (point) (quarry-test-grep--heading-pos "notes.txt")))
    ;; The line is gone, its file is not: the heading.
    (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
    (quarry-test-grep--keys "- l again RET")
    (should (equal (quarry-test-grep--results)
                   '(("notes.txt" 1 "a needle in text")
                     ("src/a.rs" 2 "    let needle = 1;")
                     ("sub/deep.txt" 1 "über needle"))))
    (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
    ;; The file is gone: the heading that sorts after it, else the first.
    (goto-char (quarry-test-grep--line-pos "notes.txt" 1))
    (quarry-test-grep--keys "- f")
    (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
    (goto-char (quarry-test-grep--line-pos "sub/deep.txt" 1))
    (quarry-test-grep--keys "- f")
    (should (equal (quarry-test-grep--headings) '("src/a.rs")))
    (should (= (point) (quarry-test-grep--heading-pos "src/a.rs")))
    ;; No results: the start of the buffer.
    (quarry-test-grep--keys "+ l zzz RET")
    (should-not (quarry-test-grep--headings))
    (should (= (point) (point-min)))
    ;; From the status line: the start too.
    (quarry-test-grep--keys "K")
    (goto-char (point-max))
    (quarry-test-grep--keys "g")
    (should (= (point) (point-min)))
    ;; A command starts at the start of the buffer.
    (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
    (quarry-test-grep--search dir)
    (should (= (point) (point-min)))
    ;; Played by hand: the block arrives in a later batch, and results
    ;; after it leave point where it was put.
    (quarry-test-grep--with-fake-stream
      (cl-flet ((batch (&rest items) (apply (nth 1 (car quarry-test-grep--fake)) (list items)))
                (end () (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)))
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-grep-rerun)
        (should (= (point) (point-min)))
        (batch (quarry-test-grep--item "a.txt" '(1 "needle" 0 6)))
        (should (= (point) (point-min)))
        (batch (quarry-test-grep--item "b.txt" '(1 "needle" 0 6))
               (quarry-test-grep--item "src/a.rs" '(2 "needle" 0 6) '(4 "needle" 0 6))
               (quarry-test-grep--item "c.txt" '(1 "needle" 0 6)))
        (let ((place (quarry-test-grep--line-pos "src/a.rs" 4)))
          (should (= (point) place))
          (should (= (window-point) place))
          (batch (quarry-test-grep--item "d.txt" '(1 "needle" 0 6)))
          (end)
          (should (= (point) place)))
        ;; The user moved point while the search ran: it is left alone,
        ;; when the block arrives and at the end.
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-grep-rerun)
        (batch (quarry-test-grep--item "a.txt" '(1 "needle" 0 6)))
        (let ((place (quarry-test-grep--heading-pos "a.txt")))
          (goto-char place)
          (batch (quarry-test-grep--item "src/a.rs" '(4 "needle" 0 6)))
          (should (= (point) place))
          (end)
          (should (= (point) place)))
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-grep-rerun)
        (goto-char (point-max))
        (let ((place (point)))
          (batch (quarry-test-grep--item "z.txt" '(1 "needle" 0 6)))
          (end)
          (should (= (point) place)))
        ;; The file does not come back and the files are not sorted: the
        ;; first heading that sorts after it.
        (goto-char (quarry-test-grep--heading-pos "z.txt"))
        (quarry-grep-rerun)
        (batch (quarry-test-grep--item "y.txt" '(1 "needle" 0 6))
               (quarry-test-grep--item "zz.txt" '(1 "needle" 0 6))
               (quarry-test-grep--item "zy.txt" '(1 "needle" 0 6)))
        (should (= (point) (point-min)))
        (end)
        (should (= (point) (quarry-test-grep--heading-pos "zz.txt")))
        ;; A cancelled or failed search leaves point at the start.
        (quarry-grep-rerun)
        (batch (quarry-test-grep--item "zzz.txt" '(1 "needle" 0 6)))
        (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil)
        (should (= (point) (point-min)))))))

;;;; Loading

(ert-deftest quarry-test-grep-loads-alone ()
  "quarry-grep.el loads and searches without quarry.el and `quarry-mode'."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (file-name-directory (locate-library "quarry-grep")))
         (emrs (file-name-directory (locate-library "emrs")))
         (dir (quarry-test-grep--tree quarry-test-grep--files))
         (out (generate-new-buffer " *quarry-grep-alone*"))
         (form
          `(progn
             (require 'quarry-grep)
             (quarry-grep "needle" nil ,dir)
             (let ((deadline (+ (float-time) 10)))
               (while (and (eq quarry-grep--state 'running) (< (float-time) deadline))
                 (accept-process-output nil 0.05)))
             (let ((ok (and (eq quarry-grep--state 'done)
                            (= quarry-grep--lines 5)
                            (= quarry-grep--files 4)
                            (not (featurep 'quarry))
                            (not (featurep 'quarry-consult))
                            (not (boundp 'quarry-mode))
                            (not (boundp 'quarry--instances))
                            (commandp 'quarry-grep-dwim))))
               (unless ok
                 (princ (list quarry-grep--state quarry-grep--lines features)))
               (kill-emacs (if ok 0 1))))))
    (unwind-protect
        (let ((status (call-process emacs nil out nil "--batch" "-Q"
                                    "-L" lisp "-L" emrs
                                    "--eval" (prin1-to-string form))))
          (should (equal (list status (with-current-buffer out (buffer-string)))
                         (list 0 (with-current-buffer out (buffer-string))))))
      (kill-buffer out)
      (delete-directory dir t))))

(provide 'quarry-grep-tests)
;;; quarry-grep-tests.el ends here
