;;; quarry-grep-tests.el --- ERT suite for quarry-grep  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh, which loads tests/quarry-tests.el first;
;; its helpers are used here.  The tests load the module, so their names
;; start with `quarry-test-grep-' to sort after
;; `quarry-test-build-async-installs' (docs/backlog/project.md).
;;
;; The result buffer is read through its text properties, never by
;; column or by a regexp on its layout (docs/decisions/0012).

;;; Code:

(require 'ert)
(require 'quarry-tests)
(require 'quarry-grep)
(require 'quarry-grep-menu)

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

(defconst quarry-test-grep--sort-budget-ms 60000
  "The sort budget of the tests' searches, as the Rust tests use it.
With the service's 150 ms a slow search, such as a regexp with `\\w' in
a debug build on a busy machine, sends its files in the order the walker
threads finish them.")

(defun quarry-test-grep--add-sort-budget (args)
  "Add `quarry-test-grep--sort-budget-ms' to a search request in ARGS.
ARGS are the arguments of `emrs-call-stream'."
  (pcase-let ((`(,instance ,request . ,rest) args))
    (if (eq (car-safe request) :search)
        `(,instance (,@request :sort-budget-ms ,quarry-test-grep--sort-budget-ms) ,@rest)
      args)))

(defmacro quarry-test-grep--with-tree (spec &rest body)
  "Run BODY with a tree; SPEC is (DIR [FILES]).
DIR is bound to a tree of FILES (default `quarry-test-grep--files') and
is the `default-directory'.  The result buffer has a name of its own,
the options have their defaults, and the requests and calls of
`emrs-call-stream' are recorded.  Searches reach the service with
`quarry-test-grep--sort-budget-ms', so their files arrive in path order
however long they take; the recorded requests are as Lisp sent them."
  (declare (indent 1))
  (let ((dir (car spec)))
    `(let* ((,dir (quarry-test-grep--tree ,(or (cadr spec) 'quarry-test-grep--files)))
            (default-directory ,dir)
            (quarry-grep-buffer-name "*quarry-grep-test*")
            (quarry-grep-case 'smart)
            (quarry-grep-max-lines 50000)
            (quarry-grep-max-columns 500)
            (quarry-grep-context-before 0)
            (quarry-grep-context-after 0)
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
       (advice-add 'emrs-call-stream :filter-args
                   #'quarry-test-grep--add-sort-budget
                   '((name . quarry-test-grep-sort-budget) (depth . 100)))
       (unwind-protect
           (save-window-excursion ,@body)
         (advice-remove 'emrs-call-stream 'quarry-test-grep-requests)
         (advice-remove 'emrs-call-stream 'quarry-test-grep-calls)
         (advice-remove 'emrs-call-stream 'quarry-test-grep-sort-budget)
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
                         :file-types '("rust")
                         :no-ignore nil :hidden t :ignores nil
                         :max-lines 50000 :max-columns 500
                         :before 0 :after 0)))
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
    (should-not (plist-member (cdr (quarry-test-grep--request)) :file-types))
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
      (should-not (plist-member (cdr (quarry-test-grep--request)) :file-types))
      (should-not (plist-member (cdr (quarry-test-grep--request)) :globs))
      (should (equal (quarry-test-grep--results) quarry-test-grep--needles)))
    ;; Outside a project.
    (quarry-test-grep--visit-file dir "sub/deep.txt")
    (quarry-grep-project "needle" "txt")
    (quarry-test-grep--wait)
    (should (equal (quarry-test-grep--request :dir) (expand-file-name "sub/" dir)))
    (should (equal (quarry-test-grep--request :file-types) '("txt")))
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
      (should (equal (quarry-test-grep--request :file-types) '("rust")))
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
    (should (equal (quarry-grep--parse-files "everything") (cons nil nil)))
    (should (equal (quarry-grep--parse-files " ") (cons nil nil)))
    (should (equal (quarry-grep--parse-files "rust") '(("rust"))))
    (should (equal (quarry-grep--parse-files " *.a  *.b ") '(nil "*.a" "*.b")))
    (should (equal (quarry-grep--parse-files "*.rs") '(nil "*.rs")))))

(ert-deftest quarry-test-grep-classify-files ()
  "A word that is a type name is a type, any other word a glob."
  (quarry-test-grep--with-tree (dir)
    (should (equal (quarry-grep--classify-files nil) '(nil)))
    (should (equal (quarry-grep--classify-files "rust") '(("rust"))))
    (should (equal (quarry-grep--classify-files "*.rs") '(nil "*.rs")))
    (should (equal (quarry-grep--classify-files '("*.a" "!b/**")) '(nil "*.a" "!b/**")))
    (should (equal (quarry-grep--classify-files '("!gen/**" "rust" "src/**"))
                   '(("rust") "!gen/**" "src/**")))
    (should (equal (quarry-grep--parse-files "rust !gen/** src/**")
                   '(("rust") "!gen/**" "src/**")))
    (should (equal (quarry-grep--parse-files "everything") '(nil)))
    ;; A glob that is not spelled like a type name.
    (should (equal (quarry-grep--parse-files "[m]ake") '(nil "[m]ake")))
    ;; Several types, in order; a name given twice counts once.
    (should (equal (quarry-grep--classify-files '("rust" "*.a" "txt"))
                   '(("rust" "txt") "*.a")))
    (should (equal (quarry-grep--parse-files "rust txt md")
                   '(("rust" "txt" "md"))))
    (should (equal (quarry-grep--parse-files "txt rust txt *.a")
                   '(("txt" "rust") "*.a")))
    (should (equal (quarry-grep--files-argument (quarry-grep--parse-files "txt *.a rust"))
                   '("txt" "rust" "*.a")))
    (should-not (quarry-grep--files-argument (quarry-grep--parse-files "everything")))))

(ert-deftest quarry-test-grep-files-text-and-request ()
  "The restriction is shown as typed; the request has what the search has."
  (should (equal (quarry-grep--files-text nil nil) "everything"))
  (should (equal (quarry-grep--files-text '("rust") nil) "rust"))
  (should (equal (quarry-grep--files-text '("rust" "txt") nil) "rust txt"))
  (should (equal (quarry-grep--files-text nil '("*.a" "*.b")) "*.a *.b"))
  (should (equal (quarry-grep--files-text '("rust" "txt") '("!gen/**" "src/**"))
                 "rust txt !gen/** src/**"))
  (let ((search (quarry-grep--make-search :dir "/x/")))
    (should-not (plist-member (cdr (quarry-grep--request search)) :file-types))
    (should-not (plist-member (cdr (quarry-grep--request search)) :globs))
    (let ((request (cdr (quarry-grep--request
                         (quarry-grep--make-search :dir "/x/" :types '("rust" "txt"))))))
      (should (equal (plist-get request :file-types) '("rust" "txt")))
      (should-not (plist-member request :globs)))
    (let ((request (cdr (quarry-grep--request
                         (quarry-grep--make-search :dir "/x/" :globs '("a/**" "!b"))))))
      (should (equal (plist-get request :globs) '("a/**" "!b")))
      (should-not (plist-member request :file-types)))
    (let ((request (cdr (quarry-grep--request
                         (quarry-grep--make-search :dir "/x/" :types '("rust")
                                                   :globs '("!gen/**"))))))
      (should (equal (plist-get request :file-types) '("rust")))
      (should (equal (plist-get request :globs) '("!gen/**"))))))

(ert-deftest quarry-test-grep-change-files-path-globs ()
  "Path globs, excluding globs and a type with globs, with the real module."
  (quarry-test-grep--with-tree
      (dir (append quarry-test-grep--files
                   '(("src/gen/g.rs" . "let needle = 3;\n")
                     ("docs/x.md" . "needle md\n"))))
    (quarry-test-grep--search dir)
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "docs/x.md" "notes.txt" "src/a.rs" "src/gen/g.rs"
                     "sub/deep.txt")))
    (quarry-test-grep--keys "f sub/*.txt RET")
    (should (equal (quarry-test-grep--request :globs) '("sub/*.txt")))
    (should (equal (quarry-test-grep--headings) '("sub/deep.txt")))
    (quarry-test-grep--keys "f src/** RET")
    (should (equal (quarry-test-grep--headings) '("src/a.rs" "src/gen/g.rs")))
    (quarry-test-grep--keys "f !*.md RET")
    (should (equal (quarry-test-grep--request :globs) '("!*.md")))
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "notes.txt" "src/a.rs" "src/gen/g.rs" "sub/deep.txt")))
    (quarry-test-grep--keys "f rust SPC !src/gen/** RET")
    (should (equal (quarry-test-grep--request :file-types) '("rust")))
    (should (equal (quarry-test-grep--request :globs) '("!src/gen/**")))
    (should (equal (quarry-test-grep--headings) '("src/a.rs")))
    (should (string-prefix-p " files: rust !src/gen/**   " (quarry-test-grep--header)))
    ;; The default of the prompt is what is searched now.
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "f RET")))))
      (should (string-match-p "(default rust !src/gen/\\*\\*): " (car (car prompts)))))
    (should (equal (quarry-test-grep--headings) '("src/a.rs")))
    ;; Two types search both; the others are not found.
    (quarry-test-grep--keys "f rust SPC md RET")
    (should (equal (quarry-test-grep--request :file-types) '("rust" "md")))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :globs))
    (should (equal (quarry-test-grep--headings) '("docs/x.md" "src/a.rs" "src/gen/g.rs")))
    (should (string-prefix-p " files: rust md   " (quarry-test-grep--header)))
    ;; Two types and an excluding glob.
    (quarry-test-grep--keys "f rust SPC md SPC !src/gen/** RET")
    (should (equal (quarry-test-grep--headings) '("docs/x.md" "src/a.rs")))
    (should (string-prefix-p " files: rust md !src/gen/**   " (quarry-test-grep--header)))))

(ert-deftest quarry-test-grep-command-files-argument ()
  "The FILES argument of the commands is classified by the same rule."
  (quarry-test-grep--with-tree (dir)
    (quarry-grep "needle" '("txt" "!sub/**") dir)
    (quarry-test-grep--wait)
    (should (equal (quarry-test-grep--request :file-types) '("txt")))
    (should (equal (quarry-test-grep--request :globs) '("!sub/**")))
    (should (equal (quarry-test-grep--headings) '(".hidden.txt" "notes.txt")))
    (quarry-grep "needle" '("txt" "*.rs" "rust") dir)
    (quarry-test-grep--wait)
    (should (equal (quarry-test-grep--request :file-types) '("txt" "rust")))
    (should (equal (quarry-test-grep--request :globs) '("*.rs")))
    (should (equal (quarry-test-grep--headings) '("src/a.rs")))))

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
                   (format " files: everything   dir: %s   case: smart   ign: on   hidden: on   ctx: 0   hits: 5 in 4 files   ? menu"
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
    (should (string-suffix-p "hits: 0 in 0 files   ? menu" (quarry-test-grep--header)))))

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
                   ("R" . quarry-grep-replace)
                   ("C-c C-c" . quarry-grep-replace-apply)
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
    (should (equal (quarry-test-grep--request :file-types) '("txt")))
    (should (string-prefix-p " files: txt   " (quarry-test-grep--header)))
    (should (equal (quarry-test-grep--headings)
                   '(".hidden.txt" "notes.txt" "sub/deep.txt")))
    (let ((prompts (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "f RET")))))
      (should (string-match-p "(default txt): " (car (car prompts)))))
    (should (equal (quarry-test-grep--request :file-types) '("txt")))
    (quarry-test-grep--keys "f *.rs SPC *.md RET")
    (should (equal (quarry-test-grep--request :globs) '("*.rs" "*.md")))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :file-types))
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
    ;; The order below holds because the search came in sorted.
    (should (plist-get quarry-grep--summary :sorted))
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
        (should (string-suffix-p "hits: 0 in 0 files   ? menu" (quarry-test-grep--header)))
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
        (should (string-suffix-p (format "hits: %d in %d files   ? menu" (* 3 (/ n 2)) n)
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
      ;; The hint for the menu comes last (see `quarry-test-grep-header-hint').
      (should (equal (car (car (last parts))) "? menu"))
      (setq parts (butlast parts))
      (should (equal (mapcar #'car parts)
                     (list "everything" (abbreviate-file-name dir) "smart" "on" "on" "0")))
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
                     (lambda () (interactive) (push 'directory asked)))
                    ((symbol-function 'quarry-grep-set-context)
                     (lambda (&optional _) (interactive "P") (push 'context asked))))
            (funcall (nth 2 (nth 0 parts)) click)
            (funcall (nth 2 (nth 1 parts)) click)
            (funcall (nth 2 (nth 5 parts)) click))
          (should (equal asked '(context directory files))))))))

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
                     '((:line nil "needle" t) (:path t "(?-i)^/a/d\\.txt$" t))))
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
                     '((:line nil "needle" t) (:path t "(?-i)^/a/d\\.txt$" t)
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
                     '(("+" "line/re" "needle" nil) ("-" "path/re" "(?-i)^/a/d\\.txt$" nil))))
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

(ert-deftest quarry-test-grep-exclude-file-exactly ()
  "- f excludes the file at point and no file with a similar path."
  (let ((odd "we.ird+(x)[y]{z}|q$ ü^*?#&~-.c")
        ;; Where case does not tell file names apart (macOS), A.C would
        ;; be a.c.
        (upper (let ((probe (make-temp-file "quarry-test")))
                 (unwind-protect (unless (file-exists-p (upcase probe)) '("A.C"))
                   (delete-file probe)))))
    (should (equal (quarry-grep--regexp-quote "a.c+(x)[y]{z}|q$^*?\\#&~- ü")
                   "a\\.c\\+\\(x\\)\\[y\\]\\{z\\}\\|q\\$\\^\\*\\?\\\\\\#\\&\\~\\- ü"))
    (quarry-test-grep--with-tree
        (dir (mapcar (lambda (path) (cons path "needle\n"))
                     (append
                      (list "a.c" "a.cpp" "a.c.orig" "axc" "sub/a.c" "sub/b.c"
                            odd (concat "sub/" odd) (concat odd "x"))
                      upper)))
      (quarry-test-grep--search dir)
      (let ((all (quarry-test-grep--headings)))
        (should (= (length all) (+ 9 (length upper))))
        (goto-char (quarry-test-grep--heading-pos "a.c"))
        (quarry-test-grep--keys "- f")
        (should (equal (quarry-test-grep--headings) (remove "a.c" all)))
        (should (equal (cadr (quarry-test-grep--filter-lines))
                       '("-" "path/re" "(?-i)^/a\\.c$" nil)))
        ;; A name full of characters that are special in a regexp.
        (goto-char (quarry-test-grep--line-pos odd 1))
        (quarry-test-grep--keys "- f")
        (should (equal (quarry-test-grep--headings) (remove odd (remove "a.c" all))))
        ;; In a directory.
        (goto-char (quarry-test-grep--heading-pos "sub/a.c"))
        (quarry-test-grep--keys "- f")
        (should (equal (quarry-test-grep--headings)
                       (remove "sub/a.c" (remove odd (remove "a.c" all)))))
        (should (eq (quarry-test-grep--state) 'done))
        ;; The same file again: the filter is switched on, not added.
        (goto-char (quarry-test-grep--filter-pos 1))
        (quarry-test-grep--keys "x")
        (should (equal (quarry-test-grep--headings) (remove "sub/a.c" (remove odd all))))
        (goto-char (quarry-test-grep--heading-pos "a.c"))
        (quarry-test-grep--keys "- f")
        (should (= (length (quarry-test-grep--filter-lines)) 4))
        (should-not (member "a.c" (quarry-test-grep--headings)))
        (when upper
          (should (member "A.C" (quarry-test-grep--headings))))))))

(ert-deftest quarry-test-grep-header-percent ()
  "A % in the directory or in a glob is doubled for the header line."
  (quarry-test-grep--with-tree (dir '(("100%b/%-x.txt" . "needle\n")))
    (let ((sub (expand-file-name "100%b/" dir)))
      (quarry-grep "needle" '("%-*.txt") sub)
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--results) '(("%-x.txt" 1 "needle"))))
      ;; The string is a mode line format: %% stands for one %.
      (should (equal (quarry-test-grep--header)
                     (format " files: %%%%-*.txt   dir: %s   case: smart   ign: on   hidden: on   ctx: 0   hits: 1 in 1 file   ? menu"
                             (string-replace "%" "%%" (abbreviate-file-name sub)))))
      (should (string-match-p "100%%b/" (quarry-test-grep--header)))
      (should-not (string-match-p "\\(?:\\`\\|[^%]\\)%\\(?:[^%]\\|\\'\\)"
                                  (quarry-test-grep--header))))))

(ert-deftest quarry-test-grep-history-survives-a-failed-start ()
  "Back and forward leave the history alone when the search cannot start."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "c")
    (quarry-test-grep--keys "H")
    (quarry-test-grep--keys "C-c <")
    (let ((current quarry-grep--current)
          (past (copy-sequence quarry-grep--past))
          (future (copy-sequence quarry-grep--future))
          (text (buffer-string)))
      (should (= (length past) 1))
      (should (= (length future) 1))
      (cl-letf (((symbol-function 'quarry-grep--ensure-instance)
                 (lambda () (user-error "No module"))))
        (dolist (command '(quarry-grep-history-back quarry-grep-history-forward
                                                    quarry-grep-rerun quarry-grep-cycle-case))
          (should-error (funcall command) :type 'user-error)
          (should (eq quarry-grep--current current))
          (should (equal quarry-grep--past past))
          (should (equal quarry-grep--future future))
          (should (equal (buffer-string) text))))
      ;; They still work afterwards.
      (quarry-test-grep--keys "C-c >")
      (should (eq quarry-grep--current (car future)))
      (should (equal quarry-grep--past (cons current past)))
      (should-not quarry-grep--future))))

(ert-deftest quarry-test-grep-narrowed-buffer ()
  "Results and the end of a search arrive in a narrowed buffer as in a whole one."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (let ((on-batch (nth 1 (car quarry-test-grep--fake)))
            (on-end (nth 2 (car quarry-test-grep--fake))))
        (set-buffer (quarry-test-grep--buffer))
        (funcall on-batch (list (quarry-test-grep--item "a.txt" '(1 "needle one" 0 6)
                                                        '(2 "needle two" 0 6))))
        (let ((bol (quarry-test-grep--line-pos "a.txt" 1)))
          (goto-char (+ bol 8))
          (narrow-to-region bol (+ bol 12))
          (funcall on-batch (list (quarry-test-grep--item "b.txt" '(3 "needle" 0 6))))
          (funcall on-batch (list (list :summary :files-searched 2 :files-matched 2 :lines 3
                                        :truncated nil :sorted t :millis 5 :skipped 0)))
          (funcall on-end 'done nil)
          ;; The narrowing and point are the user's.
          (should (buffer-narrowed-p))
          (should (= (point-min) bol))
          (should (= (point) (+ bol 8)))
          (widen)
          (should (= (point) (+ bol 8))))
        (should (equal (quarry-test-grep--results)
                       '(("a.txt" 1 "needle one") ("a.txt" 2 "needle two")
                         ("b.txt" 3 "needle"))))
        (should (equal (quarry-test-grep--headings) '("a.txt" "b.txt")))
        (should (equal (quarry-test-grep--status)
                       "Search finished: 3 lines in 2 files, 5 ms"))
        ;; One status line, and the buffer is the blocks in order.
        (should (= (length (quarry-test-grep--lines-with 'quarry-grep-status)) 1))
        (should (= (length (quarry-grep--blocks)) 2))
        ;; Folding all and a new search see the whole buffer too.
        (narrow-to-region (quarry-test-grep--line-pos "a.txt" 1)
                          (quarry-test-grep--line-pos "a.txt" 2))
        (should (= (length (quarry-grep--blocks)) 2))
        (quarry-grep-rerun)
        (should-not (buffer-narrowed-p))
        (should (equal (quarry-test-grep--status) "Searching…"))
        (should-not (quarry-test-grep--headings))
        (should (equal (quarry-test-grep--filter-lines) '(("+" "line/re" "needle" nil))))))))

(ert-deftest quarry-test-grep-stale-by-true-name ()
  "A modified buffer that visits a result file through a link makes it stale."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (should-not (quarry-grep--stale-files))
    (make-symbolic-link (expand-file-name "sub" dir) (expand-file-name "link" dir))
    (let ((visiting (find-file-noselect (expand-file-name "link/deep.txt" dir))))
      (unwind-protect
          (progn
            (should-not (get-file-buffer (expand-file-name "sub/deep.txt" dir)))
            (should-not (quarry-grep--stale-files))
            (with-current-buffer visiting
              (goto-char (point-max))
              (insert "more\n"))
            (should (equal (quarry-grep--stale-files) '("sub/deep.txt")))
            ;; Nothing is resolved while no buffer is modified.
            (with-current-buffer visiting
              (set-buffer-modified-p nil))
            (cl-letf (((symbol-function 'file-truename)
                       (lambda (&rest _) (error "A true name was asked for"))))
              (should-not (quarry-grep--stale-files))))
        (with-current-buffer visiting (set-buffer-modified-p nil))
        (kill-buffer visiting)))))

(ert-deftest quarry-test-grep-module-without-service ()
  "A module that has no grep service is reported as too old."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-grep--instance nil)
          (quarry-grep--service "no-such-service"))
      (let ((err (should-error (quarry-grep "needle" nil dir) :type 'user-error)))
        (should (string-match-p "older than quarry-grep" (cadr err)))
        (should (string-match-p "M-x quarry-build-module" (cadr err)))
        (should (string-match-p "restart Emacs" (cadr err))))
      (should-not (quarry-test-grep--buffer))
      (should-not quarry-grep--instance))))

(ert-deftest quarry-test-grep-clone-buffer ()
  "A clone of a result buffer is independent of the original."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let* ((original (quarry-test-grep--buffer))
           (text (buffer-string))
           (clone (clone-buffer "*quarry-grep-test-clone*")))
      (unwind-protect
          (progn
            (with-current-buffer clone
              (should (eq major-mode 'quarry-grep-mode))
              (should (equal (buffer-string) text))
              ;; A marker of its own, at its own status line.
              (should (eq (marker-buffer quarry-grep--status-marker) clone))
              (should (= quarry-grep--status-marker
                         (text-property-any (point-min) (point-max) 'quarry-grep-status t)))
              (should (eq quarry-grep--state 'done))
              ;; A search in the clone leaves the original alone.
              (let ((quarry-grep-buffer-name (buffer-name clone)))
                (goto-char (point-min))
                (quarry-test-grep--keys "c")
                (quarry-test-grep--keys "- l again RET")
                (should (= (length (quarry-test-grep--results)) 4))))
            (with-current-buffer original
              (should (equal (buffer-string) text))
              (should (eq (marker-buffer quarry-grep--status-marker) original))
              (should (eq (quarry-grep--search-case quarry-grep--current) 'smart))
              (should-not quarry-grep--past))
            (kill-buffer clone)
            ;; Cloned while a search runs: the search stays the original's.
            (quarry-test-grep--with-fake-stream
              (with-current-buffer original
                (quarry-grep-rerun)
                (funcall (nth 1 (car quarry-test-grep--fake))
                         (list (quarry-test-grep--item "a.txt" '(1 "needle" 0 6))))
                (setq clone (clone-buffer "*quarry-grep-test-clone*")))
              (with-current-buffer clone
                (should (eq quarry-grep--state 'cancelled))
                (should-not quarry-grep--call)
                (should-not quarry-grep--serial)
                (let ((quarry-grep-buffer-name (buffer-name clone)))
                  (should (equal (quarry-test-grep--status)
                                 "Search cancelled: 1 line in 1 file so far"))))
              (with-current-buffer original
                (should (eq quarry-grep--state 'running))
                (should (equal (quarry-test-grep--status) "Searching…"))
                (should quarry-grep--serial))
              ;; Killing the clone does not end the original's search.
              (kill-buffer clone)
              (with-current-buffer original
                (should quarry-grep--serial)
                (funcall (nth 1 (car quarry-test-grep--fake))
                         (list (quarry-test-grep--item "b.txt" '(1 "needle" 0 6))))
                (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
                (should (equal (quarry-test-grep--headings) '("a.txt" "b.txt")))
                (should (equal (quarry-test-grep--status)
                               "Search finished: 2 lines in 2 files")))))
        (when (buffer-live-p clone)
          (kill-buffer clone))))
    ;; A real search in the original is not cancelled by killing a clone.
    (set-buffer (quarry-test-grep--buffer))
    (quarry-grep-rerun)
    (let ((call (car quarry-test-grep--calls))
          (clone (clone-buffer "*quarry-grep-test-clone*")))
      (kill-buffer clone)
      (should-not (emrs-call-done call))
      (quarry-test-grep--wait)
      (should (eq (quarry-test-grep--state) 'done))
      (should (equal (quarry-test-grep--results) quarry-test-grep--needles)))))

(ert-deftest quarry-test-grep-point-returns-per-window ()
  "A window in which point was moved during the search keeps its point."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let* ((results (quarry-test-grep--buffer))
           (moved (selected-window))
           (waiting (split-window moved nil t)))
      (set-window-buffer waiting results)
      (quarry-test-grep--with-fake-stream
        (goto-char (quarry-test-grep--line-pos "src/a.rs" 4))
        (quarry-grep-rerun)
        (should (= (window-point moved) (point-min)))
        (should (= (window-point waiting) (point-min)))
        ;; The buffer is shown in two windows that are not selected, and
        ;; in one of them point is moved.
        (with-selected-window (split-window moved)
          (switch-to-buffer (get-buffer-create "*quarry-grep-test-other*"))
          (unwind-protect
              (let ((elsewhere (with-current-buffer results (point-max))))
                (set-window-point moved elsewhere)
                (with-temp-buffer
                  (funcall (nth 1 (car quarry-test-grep--fake))
                           (list (quarry-test-grep--item "src/a.rs" '(2 "needle" 0 6)
                                                         '(4 "needle" 0 6))
                                 (quarry-test-grep--item "z.txt" '(1 "needle" 0 6)))))
                (should (= (window-point moved) elsewhere))
                (should (= (window-point waiting) (quarry-test-grep--line-pos "src/a.rs" 4)))
                ;; The end does not move anything any more.
                (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
                (should (= (window-point moved) elsewhere))
                (should (= (window-point waiting) (quarry-test-grep--line-pos "src/a.rs" 4))))
            (kill-buffer "*quarry-grep-test-other*")))))))

(ert-deftest quarry-test-grep-edit-docstring ()
  "The help of the edit command reads well without wgrep."
  (let ((doc (documentation 'quarry-grep-edit)))
    (should (string-match-p "C-c C-c applies" doc))
    (should (string-match-p "C-c C-k" doc))
    (should-not (string-match-p "not currently defined\\|wgrep-mode-map" doc))))

;;;; Context lines

(defconst quarry-test-grep--context-files
  '(("ctx.txt" . "l1\nl2\nl3 needle\nl4\nl5\nl6\nl7\nl8\nl9 needle\nl10\nl11\nl12\n")
    ("two.txt" . "x\nneedle\ny\n"))
  "A tree whose hits, ctx.txt:3 and :9, are six lines apart.
With one line of context ctx.txt has a gap between 4 and 8, with two a
gap between 5 and 7, with three none; two.txt has a hit at line 2.")

(defun quarry-test-grep--layout (path)
  "Return the lines of the block of PATH: (hit N), (context N) or `gap'."
  (with-current-buffer (quarry-test-grep--buffer)
    (let ((block (quarry-grep--block-at (quarry-test-grep--heading-pos path)))
          (found nil))
      (save-excursion
        (goto-char (car block))
        (forward-line 1)
        (while (< (point) (cdr block))
          (let ((bol (point)))
            (push (cond ((get-text-property bol 'quarry-grep-gap) 'gap)
                        ((get-text-property bol 'quarry-grep-context)
                         (list 'context (get-text-property bol 'quarry-grep-line)))
                        (t (list 'hit (get-text-property bol 'quarry-grep-line))))
                  found))
          (forward-line 1)))
      (nreverse found))))

(defun quarry-test-grep--line-text (bol)
  "Return the text of the line that starts at BOL, without properties."
  (save-excursion
    (goto-char bol)
    (buffer-substring-no-properties bol (pos-eol))))

(ert-deftest quarry-test-grep-context-request-and-options ()
  "The request carries the counts; a new search takes them from the options."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (should (eql (quarry-test-grep--request :before) 0))
    (should (eql (quarry-test-grep--request :after) 0))
    (let ((quarry-grep-context-before 2)
          (quarry-grep-context-after 1))
      (quarry-test-grep--search dir)
      (should (eql (quarry-test-grep--request :before) 2))
      (should (eql (quarry-test-grep--request :after) 1))
      (quarry-grep-literal "needle" nil dir)
      (quarry-test-grep--wait)
      (should (eql (quarry-test-grep--request :before) 2))
      (should (eql (quarry-test-grep--request :after) 1))
      (quarry-grep-project "needle" nil)
      (quarry-test-grep--wait)
      (should (eql (quarry-test-grep--request :before) 2))
      (quarry-test-grep--visit-file dir "ctx.txt" "needle")
      (quarry-grep-dwim)
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--request :filters)
                     '((:target :line :exclude nil :pattern "needle" :regexp nil))))
      (should (eql (quarry-test-grep--request :after) 1)))
    ;; A command of the result buffer keeps the counts of its search,
    ;; whatever the options say now.
    (let ((quarry-grep-context-before 2)
          (quarry-grep-context-after 1))
      (quarry-test-grep--search dir))
    (quarry-test-grep--keys "c")
    (should (eql (quarry-test-grep--request :before) 2))
    (should (eql (quarry-test-grep--request :after) 1))
    (quarry-test-grep--keys "g")
    (should (eql (quarry-test-grep--request :before) 2))
    (should (eql (quarry-grep--search-after quarry-grep--current) 1))))

(ert-deftest quarry-test-grep-context-commands ()
  "C, B and A take a prefix or ask; 0 switches off; the default is the count."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (cl-flet ((counts () (list (quarry-grep--search-before quarry-grep--current)
                               (quarry-grep--search-after quarry-grep--current)))
              (sent () (list (quarry-test-grep--request :before)
                             (quarry-test-grep--request :after))))
      ;; A prefix is the count and nothing is asked.
      (should-not (quarry-test-grep--prompts (lambda () (quarry-test-grep--keys "2 C"))))
      (should (equal (counts) '(2 2)))
      (should (equal (sent) '(2 2)))
      (quarry-test-grep--keys "C-u 3 B")
      (should (equal (sent) '(3 2)))
      (quarry-test-grep--keys "0 A")
      (should (equal (sent) '(3 0)))
      (should (equal (quarry-grep--search-before quarry-grep--current) 3))
      ;; Without a prefix the number is read; the default is the count,
      ;; for C the larger one.
      (let ((prompts (quarry-test-grep--prompts (lambda () (quarry-test-grep--keys "A 4 RET")))))
        (should (string-match-p "default 0" (car (car prompts)))))
      (should (equal (sent) '(3 4)))
      (let ((prompts (quarry-test-grep--prompts (lambda () (quarry-test-grep--keys "B RET")))))
        (should (string-match-p "default 3" (car (car prompts)))))
      (should (equal (sent) '(3 4)))
      (let ((prompts (quarry-test-grep--prompts (lambda () (quarry-test-grep--keys "C RET")))))
        (should (string-match-p "default 4" (car (car prompts)))))
      (should (equal (sent) '(4 4)))
      (quarry-test-grep--keys "C 0 RET")
      (should (equal (counts) '(0 0)))
      ;; Negative: an error, and nothing changes.
      (quarry-test-grep--keys "2 C")
      (let ((requests (length quarry-test-grep--requests))
            (search quarry-grep--current))
        (dolist (keys '("C-u - 1 C" "C - 3 RET" "M-- 2 B" "B - 1 RET" "C-u - A"
                        "A - 5 RET"))
          (pop-to-buffer-same-window (quarry-test-grep--buffer))
          (should-error (execute-kbd-macro (kbd keys)) :type 'user-error))
        (should-error (quarry-grep-set-context -1) :type 'user-error)
        (should-error (quarry-grep-set-context-after -1) :type 'user-error)
        (should (= (length quarry-test-grep--requests) requests))
        (should (eq quarry-grep--current search))
        (should (equal (counts) '(2 2)))))))

(ert-deftest quarry-test-grep-context-history ()
  "A changed count is a history entry; the same count is none."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (should-not quarry-grep--past)
    (quarry-test-grep--keys "0 C")
    (should-not quarry-grep--past)
    (quarry-test-grep--keys "2 C")
    (should (= (length quarry-grep--past) 1))
    (quarry-test-grep--keys "1 A")
    (should (= (length quarry-grep--past) 2))
    (should (equal (quarry-test-grep--layout "ctx.txt")
                   '((context 1) (context 2) (hit 3) (context 4) gap
                     (context 7) (context 8) (hit 9) (context 10))))
    (quarry-test-grep--keys "C-c <")
    (should (equal (list (quarry-grep--search-before quarry-grep--current)
                         (quarry-grep--search-after quarry-grep--current))
                   '(2 2)))
    (should (equal (quarry-test-grep--layout "two.txt")
                   '((context 1) (hit 2) (context 3))))
    (quarry-test-grep--keys "C-c <")
    (should (string-match-p "ctx: 0 " (quarry-test-grep--header)))
    (should (equal (quarry-test-grep--layout "ctx.txt") '((hit 3) (hit 9))))
    (quarry-test-grep--keys "C-c > C-c >")
    (should (string-match-p "ctx: 2/1 " (quarry-test-grep--header)))))

(ert-deftest quarry-test-grep-context-header ()
  "The header shows the counts between hidden and hits; a click sets them."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (should (string-match-p "   hidden: on   ctx: 0   hits: 3 in 2 files   \\? menu\\'"
                            (quarry-test-grep--header)))
    (quarry-test-grep--keys "2 C")
    (should (string-match-p "   hidden: on   ctx: 2   hits: " (quarry-test-grep--header)))
    (quarry-test-grep--keys "1 B")
    (quarry-test-grep--keys "3 A")
    (should (string-match-p "   ctx: 1/3   hits: " (quarry-test-grep--header)))
    ;; A click on the value runs the command.
    (with-current-buffer (quarry-test-grep--buffer)
      (let* ((header (quarry-grep--header))
             (pos (string-search "1/3" header))
             (map (get-text-property pos 'keymap header)))
        (should (eq (lookup-key map [header-line mouse-1]) 
                    (lookup-key (quarry-grep--header-map #'quarry-grep-set-context)
                                [header-line mouse-1])))
        (should (eq (cdr (assq #'quarry-grep-set-context quarry-grep--header-maps)) map))))))

;; Sorts among the context tests.
(ert-deftest quarry-test-grep-context-header-and-prompts-name-the-side ()
  "B and A change one side; their prompts say which and show the other."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "2 C")
    (let ((prompts nil))
      (cl-letf (((symbol-function 'read-number)
                 (lambda (prompt default)
                   (push (cons prompt default) prompts)
                   3)))
        (with-current-buffer (quarry-test-grep--buffer)
          (quarry-grep-set-context-before)
          (quarry-test-grep--wait)
          (should (equal (car prompts)
                         '("Lines of context before each hit (after: 2): " . 2)))
          (should (string-match-p "ctx: 3/2 " (quarry-test-grep--header)))
          (quarry-grep-set-context-after)
          (quarry-test-grep--wait)
          (should (equal (car prompts)
                         '("Lines of context after each hit (before: 3): " . 2)))
          (should (string-match-p "ctx: 3   hits" (quarry-test-grep--header)))
          (quarry-grep-set-context)
          (should (equal (car prompts)
                         '("Lines of context before and after each hit: " . 3))))))))

(ert-deftest quarry-test-grep-context-lines ()
  "Context lines carry the context property and face, hits do not."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (let ((quarry-grep-context-before 1)
          (quarry-grep-context-after 1)
          (items nil))
      (advice-add 'quarry-grep--insert-file :before
                  (lambda (item) (push item items))
                  '((name . quarry-test-grep-items)))
      (unwind-protect
          (quarry-test-grep--search dir)
        (advice-remove 'quarry-grep--insert-file 'quarry-test-grep-items))
      ;; The shape of the service's items, as Emacs gets them.
      (let ((lines (plist-get (cl-find "ctx.txt" items
                                       :key (lambda (i) (plist-get i :path))
                                       :test #'equal)
                              :lines)))
        (should (equal (nth 0 lines)
                       '(:n 2 :text "l2" :spans nil :secondary nil :inexact nil
                            :context t)))
        (should (equal (nth 1 lines)
                       '(:n 3 :text "l3 needle" :spans ((3 9)) :secondary nil
                            :inexact nil))))
      (should (equal (quarry-test-grep--layout "ctx.txt")
                     '((context 2) (hit 3) (context 4) gap
                       (context 8) (hit 9) (context 10))))
      (with-current-buffer (quarry-test-grep--buffer)
        (let ((hit (quarry-test-grep--line-pos "ctx.txt" 3))
              (context (quarry-test-grep--line-pos "ctx.txt" 4)))
          (should (equal (quarry-test-grep--line-text context) "    4 l4"))
          (should (get-text-property context 'quarry-grep-context))
          (should-not (get-text-property hit 'quarry-grep-context))
          (should (eq (get-text-property (+ context 6) 'face) 'quarry-grep-context))
          (should (eq (get-text-property (+ context 2) 'face) 'quarry-grep-line-number))
          (should (get-text-property (+ context 2) 'quarry-grep-prefix))
          (should-not (get-text-property (+ context 6) 'quarry-grep-prefix))
          (should-not (get-text-property context 'quarry-grep-column))
          (should-not (get-text-property context 'quarry-grep-inexact))
          (should (eq (get-text-property context 'mouse-face) 'highlight))
          (should (get-text-property context 'follow-link))
          (should (equal (get-text-property context 'quarry-grep-file) "ctx.txt"))
          ;; The hit keeps its faces.
          (should-not (eq (get-text-property (+ hit 6) 'face) 'quarry-grep-context))
          (should (eq (get-text-property (+ hit 9) 'face) 'quarry-grep-match)))
        (should (eq (face-attribute 'quarry-grep-context :inherit) 'shadow))))))

(ert-deftest quarry-test-grep-context-gaps ()
  "A gap line stands where the line numbers jump, and only with context."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (should-not (quarry-test-grep--lines-with 'quarry-grep-gap))
    (should-not (quarry-test-grep--lines-with 'quarry-grep-context))
    (should (equal (quarry-test-grep--layout "ctx.txt") '((hit 3) (hit 9))))
    (quarry-test-grep--keys "1 C")
    (should (equal (quarry-test-grep--layout "ctx.txt")
                   '((context 2) (hit 3) (context 4) gap
                     (context 8) (hit 9) (context 10))))
    (with-current-buffer (quarry-test-grep--buffer)
      (let* ((gaps (quarry-test-grep--lines-with 'quarry-grep-gap))
             (gap (car gaps)))
        (should (= (length gaps) 1))
        (should (equal (quarry-test-grep--line-text gap) "    ⋮"))
        (should (eq (get-text-property gap 'face) 'quarry-grep-context))
        (should (equal (get-text-property gap 'quarry-grep-file) "ctx.txt"))
        (should-not (get-text-property gap 'quarry-grep-line))
        (should-not (get-text-property gap 'quarry-grep-context))
        (should-not (get-text-property gap 'mouse-face))
        (should-not (get-text-property gap 'follow-link))
        ;; In the block, so the file commands work from it.
        (goto-char gap)
        (should (equal (quarry-grep--file-at-point) "ctx.txt"))))
    (quarry-test-grep--keys "2 C")
    (should (equal (quarry-test-grep--layout "ctx.txt")
                   '((context 1) (context 2) (hit 3) (context 4) (context 5) gap
                     (context 7) (context 8) (hit 9) (context 10) (context 11))))
    ;; Touching groups, and groups that overlap, have none.
    (quarry-test-grep--keys "3 C")
    (should-not (quarry-test-grep--lines-with 'quarry-grep-gap))
    (should (equal (mapcar #'cadr (quarry-test-grep--layout "ctx.txt"))
                   (number-sequence 1 12)))
    ;; Only before, or only after: a search with context shows gaps.
    (quarry-test-grep--keys "0 C")
    (quarry-test-grep--keys "1 A")
    (should (equal (quarry-test-grep--layout "ctx.txt")
                   '((hit 3) (context 4) gap (hit 9) (context 10))))
    (quarry-test-grep--keys "0 A")
    (quarry-test-grep--keys "1 B")
    (should (equal (quarry-test-grep--layout "ctx.txt")
                   '((context 2) (hit 3) gap (context 8) (hit 9))))
    ;; Hits that are apart without context have no gap line.
    (quarry-test-grep--keys "0 B")
    (should-not (quarry-test-grep--lines-with 'quarry-grep-gap))))

(ert-deftest quarry-test-grep-context-counts ()
  "Heading, `hits' part, status line and `quarry-grep--lines' count hits."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "2 C")
    (with-current-buffer (quarry-test-grep--buffer)
      (should (= quarry-grep--lines 3))
      (should (= quarry-grep--files 2))
      (should (string-suffix-p " (2)" (quarry-test-grep--line-text
                                       (quarry-test-grep--heading-pos "ctx.txt"))))
      (should (string-suffix-p " (1)" (quarry-test-grep--line-text
                                       (quarry-test-grep--heading-pos "two.txt")))))
    (should (string-suffix-p "hits: 3 in 2 files   ? menu" (quarry-test-grep--header)))
    (should (string-match-p "\\`Search finished: 3 lines in 2 files"
                            (quarry-test-grep--status)))
    ;; The cap counts hits too: a cap of 1 hit gives that hit with its
    ;; lines before; the search stops there, so it has none after.
    (let ((quarry-grep-max-lines 1))
      (quarry-test-grep--keys "g"))
    (with-current-buffer (quarry-test-grep--buffer)
      (should (= quarry-grep--lines 1))
      (should (= quarry-grep--files 1))
      (let ((path (get-text-property (car (car (quarry-grep--blocks)))
                                     'quarry-grep-file)))
        (should (equal (quarry-test-grep--layout path)
                       (if (equal path "ctx.txt")
                           '((context 1) (context 2) (hit 3))
                         '((context 1) (hit 2)))))))
    (should (string-match-p "\\`Search stopped at 1 lines" (quarry-test-grep--status)))))

(ert-deftest quarry-test-grep-context-next-error ()
  "n, p and `next-error' go from hit to hit."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let ((results (quarry-test-grep--buffer))
          (hit3 (quarry-test-grep--line-pos "ctx.txt" 3))
          (hit9 (quarry-test-grep--line-pos "ctx.txt" 9))
          (hit2 (quarry-test-grep--line-pos "two.txt" 2)))
      (delete-other-windows)
      (goto-char (point-min))
      (quarry-test-grep--keys "n")
      (should (= (point) hit3))
      ;; Over a context line, a gap line and another context line.
      (quarry-test-grep--keys "n")
      (should (= (point) hit9))
      (quarry-test-grep--keys "n")
      (should (= (point) hit2))
      (should-error (quarry-grep-next-match) :type 'user-error)
      (quarry-test-grep--keys "p")
      (should (= (point) hit9))
      (quarry-test-grep--keys "p")
      (should (= (point) hit3))
      (should-error (quarry-grep-previous-match) :type 'user-error)
      ;; From a context line and from a gap line.
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 4))
      (quarry-test-grep--keys "n")
      (should (= (point) hit9))
      (goto-char (car (quarry-test-grep--lines-with 'quarry-grep-gap)))
      (quarry-test-grep--keys "p")
      (should (= (point) hit3))
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 8))
      (quarry-test-grep--keys "p")
      (should (= (point) hit3))
      ;; `next-error' from another buffer.
      (switch-to-buffer (get-buffer-create "*quarry-grep-test-other*"))
      (unwind-protect
          (progn
            (first-error)
            (should (equal (quarry-test-grep--place) '("ctx.txt" 3)))
            (next-error)
            (should (equal (quarry-test-grep--place) '("ctx.txt" 9)))
            (next-error)
            (should (equal (quarry-test-grep--place) '("two.txt" 2)))
            (should-error (next-error) :type 'user-error)
            (previous-error 2)
            (should (equal (quarry-test-grep--place) '("ctx.txt" 3)))
            (should-error (previous-error) :type 'user-error)
            (next-error 2)
            (should (equal (quarry-test-grep--place) '("two.txt" 2)))
            (first-error)
            (should (equal (quarry-test-grep--place) '("ctx.txt" 3))))
        (kill-buffer "*quarry-grep-test-other*"))
      (should (buffer-live-p results)))))

(ert-deftest quarry-test-grep-context-visit ()
  "RET and a click on a context line visit its line; a gap line has none."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let ((results (quarry-test-grep--buffer))
          (file (expand-file-name "ctx.txt" dir)))
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 4))
      (end-of-line)
      (quarry-test-grep--keys "RET")
      (should (equal (buffer-file-name (window-buffer)) file))
      (with-current-buffer (window-buffer)
        (should (= (line-number-at-pos) 4))
        (should (= (current-column) 0))
        (should (looking-at-p "l4")))
      (pop-to-buffer-same-window results)
      (let ((bol (quarry-test-grep--line-pos "ctx.txt" 8)))
        (quarry-grep-mouse-visit
         (list 'mouse-2 (list (selected-window) (+ bol 7) '(0 . 0) 0))))
      (should (equal (buffer-file-name) file))
      (should (= (line-number-at-pos) 8))
      (should (= (current-column) 0))
      ;; The hit still goes to its match.
      (pop-to-buffer-same-window results)
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 9))
      (quarry-grep-visit)
      (should (= (line-number-at-pos) 9))
      (should (= (current-column) 3))
      ;; A gap line: nothing to visit, as on the empty line after a block.
      (pop-to-buffer-same-window results)
      (let ((separator (text-property-any (point-min) (point-max) 'quarry-grep-separator t)))
        (goto-char separator)
        (let ((expected (should-error (quarry-grep-visit) :type 'user-error)))
          (goto-char (car (quarry-test-grep--lines-with 'quarry-grep-gap)))
          (should (equal (should-error (quarry-grep-visit) :type 'user-error)
                         expected)))))))

(ert-deftest quarry-test-grep-context-file-commands ()
  "The commands that read the file at point work from context and gap lines."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let ((gap (car (quarry-test-grep--lines-with 'quarry-grep-gap))))
      (dolist (place (list (quarry-test-grep--line-pos "ctx.txt" 4) gap))
        (goto-char place)
        (quarry-test-grep--keys "- f")
        (should (equal (quarry-test-grep--headings) '("two.txt")))
        (quarry-test-grep--keys "C-c <")
        (should (equal (quarry-test-grep--headings) '("ctx.txt" "two.txt"))))
      ;; Folding from a gap line, in and out.
      (goto-char gap)
      (quarry-test-grep--keys "TAB")
      (should (invisible-p gap))
      (should (quarry-test-grep--hidden-p "ctx.txt" 4))
      (should (= (point) (quarry-test-grep--heading-pos "ctx.txt")))
      (should-not (invisible-p (quarry-test-grep--heading-pos "two.txt")))
      (quarry-test-grep--keys "TAB")
      (should-not (invisible-p gap))
      ;; { and } from them.
      (goto-char gap)
      (quarry-test-grep--keys "}")
      (should (= (point) (quarry-test-grep--heading-pos "two.txt")))
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 8))
      (quarry-test-grep--keys "{")
      (should (= (point) (quarry-test-grep--heading-pos "ctx.txt")))
      ;; - d from a gap line offers the directory of the file.
      (goto-char (quarry-test-grep--line-pos "ctx.txt" 4))
      (should (equal (quarry-grep--file-at-point) "ctx.txt")))))

(ert-deftest quarry-test-grep-context-folding ()
  "Folding hides the gap lines of a block, and the fold of all does too."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let ((gap (car (quarry-test-grep--lines-with 'quarry-grep-gap))))
      (should-not (invisible-p gap))
      (quarry-test-grep--keys "<backtab>")
      (should (invisible-p gap))
      (should (invisible-p (save-excursion (goto-char gap) (1- (pos-eol)))))
      (dolist (path (quarry-test-grep--headings))
        (should-not (invisible-p (quarry-test-grep--heading-pos path))))
      (quarry-test-grep--keys "<backtab>")
      (should-not (invisible-p gap)))))

(ert-deftest quarry-test-grep-context-point-returns ()
  "Point returns to a context line after a new search, else to the heading."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "2 C")
    (goto-char (quarry-test-grep--line-pos "ctx.txt" 7))
    (quarry-test-grep--keys "g")
    (should (= (point) (quarry-test-grep--line-pos "ctx.txt" 7)))
    ;; Line 7 is shown with one line of context, line 6 is not.
    (goto-char (quarry-test-grep--line-pos "ctx.txt" 5))
    (quarry-test-grep--keys "1 C")
    (should (= (point) (quarry-test-grep--heading-pos "ctx.txt")))
    (quarry-test-grep--keys "2 C")
    (goto-char (quarry-test-grep--line-pos "ctx.txt" 10))
    (quarry-test-grep--keys "0 C")
    (should (= (point) (quarry-test-grep--heading-pos "ctx.txt")))
    ;; A hit stays a hit when context goes away, and a gap line returns
    ;; to the heading.
    (quarry-test-grep--keys "1 C")
    (goto-char (quarry-test-grep--line-pos "ctx.txt" 9))
    (quarry-test-grep--keys "0 C")
    (should (= (point) (quarry-test-grep--line-pos "ctx.txt" 9)))
    (quarry-test-grep--keys "1 C")
    (goto-char (car (quarry-test-grep--lines-with 'quarry-grep-gap)))
    (quarry-test-grep--keys "g")
    (should (= (point) (quarry-test-grep--heading-pos "ctx.txt")))))

;;;; Context lines: limits, the request, the stream

(defun quarry-test-grep--messages (function)
  "Call FUNCTION; return the messages it showed, oldest first."
  (let ((seen nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 ;; The echo of a prefix argument is an empty message.
                 (when (and format-string (not (equal format-string "")))
                   (push (apply #'format format-string args) seen)))))
      (funcall function))
    (nreverse seen)))

(defconst quarry-test-grep--limit-message "Context is limited to 1000 lines")

(defun quarry-test-grep--counts ()
  "Return the counts of the result buffer's search and those sent last.
That is ((BEFORE AFTER) (BEFORE AFTER))."
  (list (list (quarry-grep--search-before quarry-grep--current)
              (quarry-grep--search-after quarry-grep--current))
        (list (quarry-test-grep--request :before)
              (quarry-test-grep--request :after))))

(ert-deftest quarry-test-grep-context-limit-commands ()
  "C, B and A reduce a count above the limit to it and say so."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (should (= quarry-grep-max-context 1000))
    (quarry-test-grep--search dir)
    (let ((limited (list quarry-test-grep--limit-message)))
      ;; C, with a prefix and typed.
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "5 0 0 0 C")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      (should (string-match-p "ctx: 1000 " (quarry-test-grep--header)))
      (quarry-test-grep--keys "0 C")
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "C 1 0 0 1 RET")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      (quarry-test-grep--keys "0 C")
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "C-u 2 0 0 0 0 C")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      ;; B and A change their side only.
      (quarry-test-grep--keys "2 C")
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "9 9 9 9 B")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 2) (1000 2))))
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "A 1 2 3 4 5 RET")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      (quarry-test-grep--keys "3 C")
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "B 1 0 0 1 RET")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 3) (1000 3))))
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--keys "5 0 0 0 A")))
                     limited))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      ;; Exactly the limit, and below it: no message.
      (quarry-test-grep--keys "0 C")
      (should-not (quarry-test-grep--messages
                   (lambda () (quarry-test-grep--keys "1 0 0 0 C"))))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000))))
      (should-not (quarry-test-grep--messages
                   (lambda () (quarry-test-grep--keys "B 9 9 9 RET"))))
      (should (equal (quarry-test-grep--counts) '((999 1000) (999 1000))))
      (should-not (quarry-test-grep--messages
                   (lambda () (quarry-test-grep--keys "A 1 0 0 0 RET"))))
      (should (equal (quarry-test-grep--counts) '((999 1000) (999 1000)))))))

(ert-deftest quarry-test-grep-context-limit-message-stays ()
  "The message is the last thing in the echo area, shown after the start."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (let ((order nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (push 'message order))))
        (advice-add 'quarry-grep--run :after (lambda (&rest _) (push 'run order))
                    '((name . quarry-test-grep-order)))
        (unwind-protect
            (quarry-grep-set-context 5000)
          (advice-remove 'quarry-grep--run 'quarry-test-grep-order)))
      (should (equal order '(message run))))))

(ert-deftest quarry-test-grep-context-limit-options ()
  "A new search with an option above the limit starts with the limit."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (let ((quarry-grep-context-before 5000)
          (quarry-grep-context-after 7))
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-test-grep--search dir)))
                     (list quarry-test-grep--limit-message)))
      (should (equal (quarry-test-grep--counts) '((1000 7) (1000 7))))
      (should (string-match-p "ctx: 1000/7 " (quarry-test-grep--header)))
      ;; The options themselves are left as they are.
      (should (= quarry-grep-context-before 5000)))
    (let ((quarry-grep-context-before 2)
          (quarry-grep-context-after 99999))
      (should (equal (quarry-test-grep--messages
                      (lambda () (quarry-grep-literal "needle" nil dir)))
                     (list quarry-test-grep--limit-message)))
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--counts) '((2 1000) (2 1000)))))
    ;; Exactly the limit: no message.
    (let ((quarry-grep-context-before 1000)
          (quarry-grep-context-after 1000))
      (should-not (quarry-test-grep--messages
                   (lambda () (quarry-test-grep--search dir))))
      (should (equal (quarry-test-grep--counts) '((1000 1000) (1000 1000)))))))

(defun quarry-test-grep--raw (request)
  "Send REQUEST to the real service; wait; return (STATUS ERROR ITEMS).
A request that does not decode fails the call itself, as `quarry-grep--run'
sees it: STATUS is `failed' and ERROR the `emrs-error' data."
  (let ((items nil) (status nil) (error nil) (ended nil))
    (condition-case err
        (progn
          (emrs-call-stream
           (quarry-grep--ensure-instance) request
           :on-batch (lambda (batch) (setq items (append items batch)))
           :on-end (lambda (end-status err)
                     (setq status end-status error err ended t)))
          (should (quarry-test--wait (lambda () ended))))
      (emrs-error (setq status 'failed error (cdr err))))
    (list status error items)))

(defun quarry-test-grep--raw-lines (items)
  "Return the lines of the file items among ITEMS."
  (cl-loop for item in items
           when (eq (car item) :file)
           append (plist-get (cdr item) :lines)))

(ert-deftest quarry-test-grep-context-raw-request ()
  "The service decodes :before and :after as Lisp sends them."
  (quarry-test-grep--with-tree (dir '(("a.txt" . "x\ny\nneedle\nz\nw\n")))
    (let ((base `(:search :dir ,dir
                          :filters ((:target :line :pattern "needle")))))
      ;; Without the fields: the defaults.
      (pcase-let ((`(,status ,err ,items) (quarry-test-grep--raw base)))
        (should (eq status 'done))
        (should-not err)
        (let ((lines (quarry-test-grep--raw-lines items)))
          (should (equal (mapcar (lambda (line) (plist-get line :n)) lines) '(3)))
          (should-not (cl-some (lambda (line) (plist-get line :context)) lines))))
      ;; A negative count and a float fail the call.
      (dolist (bad '(-1 1.5))
        (dolist (field '(:before :after))
          (pcase-let ((`(,status ,err ,items)
                       (quarry-test-grep--raw (append base (list field bad)))))
            (should (eq status 'failed))
            (should err)
            (should-not (cl-some (lambda (item) (eq (car item) :file)) items)))))
      ;; Both fields: context lines carry :context t, hits none.
      (pcase-let ((`(,status ,_ ,items)
                   (quarry-test-grep--raw (append base '(:before 1 :after 1)))))
        (should (eq status 'done))
        (let ((lines (quarry-test-grep--raw-lines items)))
          (should (equal (mapcar (lambda (line) (plist-get line :n)) lines) '(2 3 4)))
          (should (equal (mapcar (lambda (line) (plist-get line :context)) lines)
                         '(t nil t))))))))

(defun quarry-test-grep--context-item (path &rest lines)
  "Return a file item for PATH with LINES, each (N TEXT) or (N TEXT :context).
A hit has the text `needle' and the match at its start."
  (list :file :path path :path-spans nil :mtime 1760103296123
        :lines (mapcar (lambda (line)
                         (if (eq (nth 2 line) :context)
                             (list :n (nth 0 line) :text (nth 1 line)
                                   :spans nil :secondary nil :inexact nil
                                   :context t)
                           (list :n (nth 0 line) :text (nth 1 line)
                                 :spans '((0 6)) :secondary nil :inexact nil)))
                       lines)))

(ert-deftest quarry-test-grep-context-cancelled-counts-hits ()
  "The status of a cancelled search counts hits, not context lines."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-grep-context-before 1)
          (quarry-grep-context-after 1))
      (quarry-test-grep--with-fake-stream
        (quarry-grep "needle" nil dir)
        (funcall (nth 1 (car quarry-test-grep--fake))
                 (list (quarry-test-grep--context-item
                        "a.txt" '(1 "one" :context) '(2 "needle") '(3 "three" :context))
                       (quarry-test-grep--context-item
                        "b.txt" '(1 "needle") '(2 "two" :context))))
        (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil)
        (should (eq (quarry-test-grep--state) 'cancelled))
        (should (equal (quarry-test-grep--status)
                       "Search cancelled: 2 lines in 2 files so far"))
        (should (string-suffix-p "hits: 2 in 2 files   ? menu" (quarry-test-grep--header)))))))

(ert-deftest quarry-test-grep-context-fractional-count ()
  "1.5 typed at the prompt of C is a user-error and changes nothing."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "2 C")
    (let ((requests (length quarry-test-grep--requests))
          (search quarry-grep--current))
      (dolist (keys '("C 1 . 5 RET" "B 2 . 5 RET" "A 0 . 5 RET"))
        (pop-to-buffer-same-window (quarry-test-grep--buffer))
        (should-error (execute-kbd-macro (kbd keys)) :type 'user-error))
      (should (= (length quarry-test-grep--requests) requests))
      (should (eq quarry-grep--current search))
      (should (equal (quarry-test-grep--counts) '((2 2) (2 2)))))))

(ert-deftest quarry-test-grep-context-bare-universal-argument ()
  "C-u C without a number sets both counts to 4 and asks nothing."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (should-not (quarry-test-grep--prompts
                 (lambda () (quarry-test-grep--keys "C-u C"))))
    (should (equal (quarry-test-grep--counts) '((4 4) (4 4))))
    (quarry-test-grep--keys "0 C")
    (quarry-test-grep--keys "C-u B")
    (should (equal (quarry-test-grep--counts) '((4 0) (4 0))))))

(ert-deftest quarry-test-grep-context-directory-filters ()
  "- d and + d from a context line and a gap line offer the block's directory."
  (quarry-test-grep--with-tree
      (dir '(("sub/ctx.txt" . "l1\nl2\nl3 needle\nl4\nl5\nl6\nl7\nl8\nl9 needle\nl10\n")
             ("other/o.txt" . "needle\n")))
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let ((places (list (cons "context" (quarry-test-grep--line-pos "sub/ctx.txt" 4))
                        (cons "gap" (car (quarry-test-grep--lines-with
                                          'quarry-grep-gap))))))
      (should (= (length places) 2))
      (dolist (place places)
        (goto-char (cdr place))
        (let ((prompts (quarry-test-grep--prompts
                        (lambda () (quarry-test-grep--keys "- d RET")))))
          (should (equal prompts '(("Exclude paths containing: " . "/sub/")))))
        (should (equal (quarry-test-grep--headings) '("other/o.txt")))
        (quarry-test-grep--keys "C-c <")
        (goto-char (cdr place))
        (let ((prompts (quarry-test-grep--prompts
                        (lambda () (quarry-test-grep--keys "+ d RET")))))
          (should (equal prompts '(("Keep only paths containing: " . "/sub/")))))
        (should (equal (quarry-test-grep--headings) '("sub/ctx.txt")))
        (quarry-test-grep--keys "C-c <")))))

(ert-deftest quarry-test-grep-context-clone-buffer ()
  "A clone of a result buffer with context has its layout; n passes context."
  (quarry-test-grep--with-tree (dir quarry-test-grep--context-files)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "1 C")
    (let* ((layouts (mapcar (lambda (path) (cons path (quarry-test-grep--layout path)))
                            '("ctx.txt" "two.txt")))
           (clone (clone-buffer "*quarry-grep-test-clone*")))
      (unwind-protect
          (let ((quarry-grep-buffer-name (buffer-name clone)))
            (should (equal (quarry-test-grep--layout "ctx.txt")
                           '((context 2) (hit 3) (context 4) gap
                             (context 8) (hit 9) (context 10))))
            (dolist (layout layouts)
              (should (equal (quarry-test-grep--layout (car layout)) (cdr layout))))
            (should (= (length (quarry-test-grep--lines-with 'quarry-grep-gap)) 1))
            (delete-other-windows)
            (set-buffer clone)
            (goto-char (quarry-test-grep--line-pos "ctx.txt" 3))
            (quarry-test-grep--keys "n")
            (should (= (point) (quarry-test-grep--line-pos "ctx.txt" 9)))
            (quarry-test-grep--keys "n")
            (should (= (point) (quarry-test-grep--line-pos "two.txt" 2)))
            (quarry-test-grep--keys "p")
            (should (= (point) (quarry-test-grep--line-pos "ctx.txt" 9)))
            (should (equal (quarry-test-grep--counts) '((1 1) (1 1)))))
        (kill-buffer clone)))))

(ert-deftest quarry-test-grep-context-gaps-in-several-batches ()
  "Each file item of its own batch gets its gap line where its numbers jump."
  (quarry-test-grep--with-tree (dir)
    (let ((quarry-grep-context-before 1)
          (quarry-grep-context-after 1))
      (quarry-test-grep--with-fake-stream
        (quarry-grep "needle" nil dir)
        (let ((on-batch (nth 1 (car quarry-test-grep--fake))))
          (funcall on-batch
                   (list (quarry-test-grep--context-item
                          "a.txt" '(2 "two" :context) '(3 "needle") '(4 "four" :context)
                          '(8 "eight" :context) '(9 "needle"))))
          (should (equal (quarry-test-grep--layout "a.txt")
                         '((context 2) (hit 3) (context 4) gap (context 8) (hit 9))))
          (funcall on-batch
                   (list (quarry-test-grep--context-item
                          "b.txt" '(1 "needle") '(2 "two" :context)
                          '(10 "ten" :context) '(11 "needle"))
                         (quarry-test-grep--context-item
                          "c.txt" '(5 "five" :context) '(6 "needle"))))
          (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
          (should (equal (quarry-test-grep--layout "a.txt")
                         '((context 2) (hit 3) (context 4) gap (context 8) (hit 9))))
          (should (equal (quarry-test-grep--layout "b.txt")
                         '((hit 1) (context 2) gap (context 10) (hit 11))))
          (should (equal (quarry-test-grep--layout "c.txt") '((context 5) (hit 6))))
          (should (= (length (quarry-test-grep--lines-with 'quarry-grep-gap)) 2))
          (should (string-match-p "\\`Search finished: 5 lines in 3 files"
                                  (quarry-test-grep--status))))))))

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

;;;; Conditions for the commands

(defmacro quarry-test-grep--with-wgrep (installed &rest body)
  "Run BODY as if wgrep were not loaded and INSTALLED, a form, says if it is found.
Nothing is loaded; the answers of `featurep' and `locate-library' for
wgrep are replaced, so the test does not depend on the environment."
  (declare (indent 1))
  `(let ((real-featurep (symbol-function 'featurep))
         (found ,installed))
     (cl-letf (((symbol-function 'featurep)
                (lambda (feature &rest args)
                  (and (not (eq feature 'wgrep)) (apply real-featurep feature args))))
               ((symbol-function 'locate-library)
                (lambda (name &rest _) (and found (equal name "wgrep") "/x/wgrep.el"))))
       ,@body)))

(defconst quarry-test-grep--condition-predicates
  '(quarry-grep--filter-at-point-p quarry-grep--file-at-point-p
    quarry-grep--directory-at-point-p quarry-grep--block-at-point-p
    quarry-grep--running-p quarry-grep--has-results-p
    quarry-grep--wgrep-available-p quarry-grep--editable-p
    quarry-grep--earlier-search-p quarry-grep--later-search-p
    quarry-grep--other-filters-p quarry-grep--replace-p
    quarry-grep--applicable-p quarry-grep--toggle-at-point-p
    quarry-grep--cancellable-p)
  "The functions that say whether a command applies; none signals.")

(ert-deftest quarry-test-grep-condition-at-point ()
  "The filter, file, directory and block conditions follow point."
  (quarry-test-grep--with-tree (dir '(("top.txt" . "needle\n")
                                      ("a/b/c.txt" . "needle\n")))
    (quarry-test-grep--search dir)
    (let ((filter (quarry-test-grep--filter-pos 0)))
      (should filter)
      ;; On a filter line.
      (goto-char filter)
      (should (quarry-grep--filter-at-point-p))
      (should-not (quarry-grep--file-at-point-p))
      (should-not (quarry-grep--directory-at-point-p))
      (should-not (quarry-grep--block-at-point-p))
      ;; On the status line and at the start of the buffer.
      (dolist (pos (list (point-min) (point-max)))
        (goto-char pos)
        (should-not (quarry-grep--file-at-point-p))
        (should-not (quarry-grep--directory-at-point-p))
        (should-not (quarry-grep--block-at-point-p)))
      (goto-char (point-max))
      (should-not (quarry-grep--filter-at-point-p))
      ;; On a result line and a heading of a file in a subdirectory.
      (dolist (pos (list (quarry-test-grep--line-pos "a/b/c.txt" 1)
                         (quarry-test-grep--heading-pos "a/b/c.txt")))
        (goto-char pos)
        (should-not (quarry-grep--filter-at-point-p))
        (should (equal (quarry-grep--file-at-point-p) "a/b/c.txt"))
        (should (equal (quarry-grep--directory-at-point-p) "a/b/"))
        (should (consp (quarry-grep--block-at-point-p))))
      ;; A file in the search directory itself has no directory.
      (dolist (pos (list (quarry-test-grep--line-pos "top.txt" 1)
                         (quarry-test-grep--heading-pos "top.txt")))
        (goto-char pos)
        (should (equal (quarry-grep--file-at-point-p) "top.txt"))
        (should-not (quarry-grep--directory-at-point-p))
        (should (quarry-grep--block-at-point-p))))))

(ert-deftest quarry-test-grep-condition-running-and-results ()
  "A running search, results, and whether the results can be edited."
  (quarry-test-grep--with-tree (dir)
    ;; Running: the fake stream never ends.
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (set-buffer (quarry-test-grep--buffer))
      (should (quarry-grep--running-p))
      (should-not (quarry-grep--has-results-p))
      (should-not (quarry-grep--editable-p))
      (funcall (nth 1 (car quarry-test-grep--fake))
               (list (quarry-test-grep--item "notes.txt" '(1 "a needle in text" 2 8))))
      (should (quarry-grep--running-p))
      (should (quarry-grep--has-results-p))
      ;; Results, but still running.
      (quarry-test-grep--with-wgrep t
        (should-not (quarry-grep--editable-p)))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
      (should-not (quarry-grep--running-p))
      (should (quarry-grep--has-results-p))
      (quarry-test-grep--with-wgrep t
        (should (quarry-grep--editable-p)))
      (quarry-test-grep--with-wgrep nil
        (should-not (quarry-grep--editable-p))))
    ;; Finished with no results.
    (quarry-test-grep--search dir "nomatchatall")
    (should-not (quarry-grep--running-p))
    (should-not (quarry-grep--has-results-p))
    (quarry-test-grep--with-wgrep t
      (should-not (quarry-grep--editable-p)))
    ;; Finished with results.
    (quarry-test-grep--search dir)
    (should (quarry-grep--has-results-p))
    (quarry-test-grep--with-wgrep t
      (should (quarry-grep--editable-p)))))

(ert-deftest quarry-test-grep-condition-wgrep-available ()
  "wgrep is available when it is loaded or found; asking does not load it."
  (let ((loaded nil))
    (cl-letf (((symbol-function 'require) (lambda (&rest args) (push args loaded) nil)))
      (quarry-test-grep--with-wgrep nil
        (should-not (quarry-grep--wgrep-available-p)))
      (quarry-test-grep--with-wgrep t
        (should (quarry-grep--wgrep-available-p)))
      (should-not loaded)))
  ;; Loaded, and not on the load path.
  (cl-letf (((symbol-function 'featurep) (lambda (feature &rest _) (eq feature 'wgrep)))
            ((symbol-function 'locate-library) #'ignore))
    (should (quarry-grep--wgrep-available-p))))

(ert-deftest quarry-test-grep-condition-history ()
  "An earlier and a later search exist as the history says."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (should-not (quarry-grep--earlier-search-p))
    (should-not (quarry-grep--later-search-p))
    (quarry-test-grep--keys "c")
    (should (quarry-grep--earlier-search-p))
    (should-not (quarry-grep--later-search-p))
    (quarry-test-grep--keys "C-c <")
    (should-not (quarry-grep--earlier-search-p))
    (should (quarry-grep--later-search-p))
    (quarry-test-grep--keys "C-c >")
    (should (quarry-grep--earlier-search-p))
    (should-not (quarry-grep--later-search-p))))

(ert-deftest quarry-test-grep-condition-other-filters ()
  "Other filters exist with a second filter, and need a primary one."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (should-not (quarry-grep--other-filters-p))
    (quarry-test-grep--run-filters '(:pattern "needle" :regexp t) '(:target path :exclude t :pattern "sub"))
    (should (quarry-grep--other-filters-p))
    (quarry-test-grep--run-filters '(:pattern "needle" :regexp t))
    (should-not (quarry-grep--other-filters-p))
    ;; Several filters, none of them primary: switched off.
    (quarry-test-grep--run-filters '(:pattern "needle" :regexp t) '(:target path :exclude t :pattern "sub"))
    (let ((search (quarry-grep--copy-search quarry-grep--current)))
      (setf (quarry-grep--search-filters search)
            (mapcar (lambda (filter)
                      (let ((new (quarry-grep--copy-filter filter)))
                        (setf (quarry-grep--filter-enabled new) nil)
                        new))
                    (quarry-grep--search-filters search)))
      (let ((quarry-grep--current search))
        (should-not (quarry-grep--primary search))
        (should-not (quarry-grep--other-filters-p))))))

(ert-deftest quarry-test-grep-conditions-do-not-signal ()
  "No condition signals, in a result buffer or any other buffer."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (dolist (pos (list (point-min) (point-max)
                       (quarry-test-grep--filter-pos 0)
                       (quarry-test-grep--heading-pos "notes.txt")
                       (quarry-test-grep--line-pos "notes.txt" 1)))
      (goto-char pos)
      (dolist (predicate quarry-test-grep--condition-predicates)
        (should-not (condition-case err (progn (funcall predicate) nil) (error err)))))
    (with-temp-buffer
      (dolist (predicate quarry-test-grep--condition-predicates)
        (should-not (condition-case err (progn (funcall predicate) nil) (error err)))
        (should-not (and (memq predicate '(quarry-grep--running-p
                                           quarry-grep--has-results-p
                                           quarry-grep--editable-p
                                           quarry-grep--earlier-search-p
                                           quarry-grep--later-search-p
                                           quarry-grep--other-filters-p
                                           quarry-grep--replace-p
                                           quarry-grep--applicable-p
                                           quarry-grep--toggle-at-point-p
                                           quarry-grep--cancellable-p))
                         (funcall predicate)))))))

(ert-deftest quarry-test-grep-condition-toggle-and-cancel ()
  "The `x' and `C-c C-k' conditions follow the state and point."
  (quarry-test-grep--with-tree (dir quarry-test-grep--apply-files)
    (quarry-test-grep--search dir "foo_([0-9])")
    (let ((filter (quarry-test-grep--filter-pos 0))
          (result (quarry-test-grep--line-pos "a.txt" 1))
          (heading (quarry-test-grep--heading-pos "a.txt")))
      ;; No preview: `x' works on a filter line only; nothing to cancel.
      (goto-char filter)
      (should (quarry-grep--toggle-at-point-p))
      (dolist (pos (list result heading (point-max)))
        (goto-char pos)
        (should-not (quarry-grep--toggle-at-point-p)))
      (should-not (quarry-grep--cancellable-p))
      ;; A preview: also on result lines and headings; `C-c C-k' leaves it.
      (quarry-grep-replace "bar_$1")
      (quarry-test-grep--wait)
      (dolist (pos (list filter (quarry-test-grep--line-pos "a.txt" 1)
                         (quarry-test-grep--heading-pos "a.txt")))
        (goto-char pos)
        (should (quarry-grep--toggle-at-point-p)))
      (goto-char (point-max))
      (should-not (quarry-grep--toggle-at-point-p))
      (should (quarry-grep--cancellable-p))
      ;; Running: cancel applies.
      (quarry-test-grep--with-fake-stream
        (quarry-grep-rerun)
        (should (quarry-grep--cancellable-p))
        (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil))
      (should (quarry-grep--cancellable-p))
      (quarry-test-grep--keys "g")
      ;; Applied: `x' is refused, `C-c C-k' still leaves the preview.
      (quarry-test-grep--answering t (quarry-grep-replace-apply))
      (goto-char (quarry-test-grep--line-pos "a.txt" 1))
      (should-not (quarry-grep--toggle-at-point-p))
      (goto-char filter)
      (should (quarry-grep--toggle-at-point-p))
      (should (quarry-grep--cancellable-p)))
    (let ((make-backup-files nil))
      (quarry-grep-cancel)
      (quarry-test-grep--wait)
      (should-not (quarry-grep--replace-p))
      (should-not (quarry-grep--cancellable-p)))))

;;;; The menu

(defun quarry-test-grep--menu-suffixes ()
  "Return the plists (:key ... :command ...) of the entries of `quarry-grep-menu'.
The layout is read from the symbol property that `transient-define-prefix'
sets.  A group is a vector whose last element lists its children.  A
suffix is a list that holds the plist: as its last element in transient
0.7.2, (LEVEL CLASS PLIST), and as the rest of the list in 0.13, (CLASS
. PLIST)."
  (let (suffixes)
    (named-let walk ((node (get 'quarry-grep-menu 'transient--layout)))
      (cond ((vectorp node) (walk (aref node (1- (length node)))))
            ((not (consp node)))
            ((keywordp (cadr node)) (push (cdr node) suffixes))
            ((let ((last (car (last node))))
               (and (consp last) (keywordp (car last))))
             (push (car (last node)) suffixes))
            (t (mapc (lambda (child) (walk child)) node))))
    (nreverse suffixes)))

(defun quarry-test-grep--menu-entries ()
  "Return the entries of `quarry-grep-menu' as a list of (KEY . COMMAND).
KEY is as `key-description' writes it."
  (mapcar (lambda (plist)
            (cons (key-description (kbd (plist-get plist :key)))
                  (plist-get plist :command)))
          (quarry-test-grep--menu-suffixes)))

(defun quarry-test-grep--keymap-entries ()
  "Return the `quarry-grep-' commands of `quarry-grep-mode-map' as (KEY . COMMAND)."
  (let (entries)
    (named-let walk ((map quarry-grep-mode-map) (prefix nil))
      (map-keymap
       (lambda (event binding)
         (let ((keys (vconcat prefix (vector event))))
           (cond ((keymapp binding) (walk binding keys))
                 ((and (symbolp binding)
                       (string-prefix-p "quarry-grep-" (symbol-name binding)))
                  (push (cons (key-description keys) binding) entries)))))
       map))
    (nreverse entries)))

(ert-deftest quarry-test-grep-menu-matches-keymap ()
  "Every key of the mode map has a menu entry with its command, and no other."
  (let* ((menu (quarry-test-grep--menu-entries))
         (skipped '("?" "M-N" "M-P" "<mouse-2>"))
         (keymap (cl-remove-if (lambda (entry) (member (car entry) skipped))
                               (quarry-test-grep--keymap-entries))))
    (should (> (length keymap) 30))
    (should (equal (sort (copy-sequence keymap) (lambda (a b) (string< (car a) (car b))))
                   (sort (copy-sequence menu) (lambda (a b) (string< (car a) (car b))))))
    (should (= (length menu) (length (delete-dups (mapcar #'car menu)))))
    ;; The menu is the command of `?' and has no entry for it.
    (should (eq (keymap-lookup quarry-grep-mode-map "?") 'quarry-grep-menu))
    (should-not (assoc "?" menu))))

(defun quarry-test-grep--menu-description (key)
  "Return the text of the description of the entry KEY, in the current buffer."
  (let ((description
         (seq-some (lambda (plist)
                     (and (equal (plist-get plist :key) key)
                          (plist-get plist :description)))
                   (quarry-test-grep--menu-suffixes))))
    (substring-no-properties (if (functionp description) (funcall description) description))))

(ert-deftest quarry-test-grep-menu-descriptions ()
  "The switches show the values of the buffer's search."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let ((texts '("d" "f" "c" "i" "H" "C" "B" "A")))
      ;; `%' names what the filter at point becomes.
      (goto-char (quarry-test-grep--filter-pos 0))
      (should (equal (quarry-test-grep--menu-description "%")
                     "make the filter at point literal"))
      (goto-char (point-max))
      (should (equal (quarry-test-grep--menu-description "%")
                     "make the filter at point regexp or literal"))
      (should (equal (mapcar #'quarry-test-grep--menu-description texts)
                     (list (format "directory: %s" (abbreviate-file-name dir))
                           "file types: everything"
                           "case: smart" "ignore files: on" "hidden files: on"
                           "context: 0" "before: 0" "after: 0")))
      ;; Another search in the same buffer: other values everywhere.
      (let ((sub (expand-file-name "sub/" dir)))
        (quarry-grep-literal "needle" "txt" sub))
      (quarry-test-grep--wait)
      (quarry-test-grep--keys "c i H")
      (quarry-test-grep--keys (kbd "C-u 1 B"))
      (quarry-test-grep--keys (kbd "C-u 3 A"))
      (goto-char (quarry-test-grep--filter-pos 0))
      (should (equal (quarry-test-grep--menu-description "%")
                     "make the filter at point a regexp"))
      (should (equal (mapcar #'quarry-test-grep--menu-description texts)
                     (list (format "directory: %s"
                                   (abbreviate-file-name (expand-file-name "sub/" dir)))
                           "file types: txt"
                           "case: sensitive" "ignore files: off" "hidden files: off"
                           "context: 1/3" "before: 1" "after: 3")))
      (quarry-test-grep--keys (kbd "C-u 2 C"))
      (should (equal (quarry-test-grep--menu-description "C") "context: 2")))))

(defun quarry-test-grep--menu-inactive (keys)
  "Return those of KEYS whose menu entry is inactive in the current buffer.
That is what the entry's own `:inapt-if-not' function says at point."
  (seq-filter
   (lambda (key)
     (let* ((plist (seq-find (lambda (plist) (equal (plist-get plist :key) key))
                             (quarry-test-grep--menu-suffixes)))
            (predicate (plist-get plist :inapt-if-not)))
       (should plist)
       (and predicate (not (funcall predicate)))))
   keys))

(ert-deftest quarry-test-grep-menu-inactive-follows-point ()
  "Each entry that depends on point is inactive exactly where its command fails."
  (quarry-test-grep--with-tree (dir '(("top.txt" . "needle\n")
                                      ("a/b/c.txt" . "needle\n")))
    (quarry-test-grep--search dir)
    (let ((keys '("+d" "-f" "-d" "%" "x" "!" "k" "TAB" "RET")))
      (goto-char (quarry-test-grep--filter-pos 0))
      (should (equal (quarry-test-grep--menu-inactive keys) '("+d" "-f" "-d" "TAB")))
      (goto-char (quarry-test-grep--line-pos "a/b/c.txt" 1))
      (should (equal (quarry-test-grep--menu-inactive keys) '("%" "x" "!" "k")))
      (goto-char (quarry-test-grep--heading-pos "a/b/c.txt"))
      (should (equal (quarry-test-grep--menu-inactive keys) '("%" "x" "!" "k")))
      ;; A file in the search directory itself has no directory to filter.
      (goto-char (quarry-test-grep--line-pos "top.txt" 1))
      (should (equal (quarry-test-grep--menu-inactive keys)
                     '("+d" "-d" "%" "x" "!" "k")))
      (goto-char (point-max))
      (should (equal (quarry-test-grep--menu-inactive keys)
                     '("+d" "-f" "-d" "%" "x" "!" "k" "TAB"))))))

(ert-deftest quarry-test-grep-menu-refused ()
  "The menu is a user-error outside a result buffer."
  (with-temp-buffer
    (should-error (quarry-grep-menu) :type 'user-error))
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (with-temp-buffer
      (text-mode)
      (should-error (quarry-grep-menu) :type 'user-error))))

(ert-deftest quarry-test-grep-menu-key-runs-command ()
  "`? c' changes the search as `c' does, and the menu closes."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (should (eq (quarry-grep--search-case quarry-grep--current) 'smart))
    (quarry-test-grep--keys "? c")
    (should (eq (quarry-grep--search-case quarry-grep--current) 'sensitive))
    (should (eq (quarry-test-grep--request :case) :sensitive))
    (should-not transient-current-command)
    ;; A key that two-key bindings use, and a key with a modifier.
    (quarry-test-grep--keys "? i")
    (should (quarry-grep--search-no-ignore quarry-grep--current))
    (quarry-test-grep--keys "g")
    (quarry-test-grep--keys "? C-c <")
    (should (eq (quarry-grep--search-case quarry-grep--current) 'sensitive))
    (should-not (quarry-grep--search-no-ignore quarry-grep--current))))

(ert-deftest quarry-test-grep-menu-prefix-argument ()
  "A numeric argument typed before `?' or after `C-u' in the menu reaches the command."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (quarry-test-grep--keys "C-u 3 ? C")
    (should (equal (quarry-grep--context-text quarry-grep--current) "3"))
    (quarry-test-grep--keys "? C-u 1 B")
    (should (equal (quarry-grep--context-text quarry-grep--current) "1/3"))
    (should-not transient-current-command)))

(ert-deftest quarry-test-grep-menu-inactive-entry ()
  "An inactive entry does not run its command; the menu goes on until C-g."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (let ((sent (length quarry-test-grep--requests)))
      ;; K needs another filter, - f a file at point.
      (pop-to-buffer-same-window (quarry-test-grep--buffer))
      (goto-char (point-min))
      (execute-kbd-macro (kbd "? K - f C-g"))
      (should (= (length quarry-test-grep--requests) sent))
      (should-not transient-current-command))))

(ert-deftest quarry-test-grep-menu-loads-transient-late ()
  "quarry-grep.el does not load transient or the menu; `?' is an autoload."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (file-name-directory (locate-library "quarry-grep")))
         (emrs (file-name-directory (locate-library "emrs")))
         (out (generate-new-buffer " *quarry-grep-late*"))
         (form '(kill-emacs
                 (progn
                   (require 'quarry-grep)
                   (if (and (not (featurep 'transient))
                            (not (featurep 'quarry-grep-menu))
                            (autoloadp (symbol-function 'quarry-grep-menu))
                            (eq (keymap-lookup quarry-grep-mode-map "?") 'quarry-grep-menu))
                       0
                     1)))))
    (unwind-protect
        (let ((status (call-process emacs nil out nil "--batch" "-Q"
                                    "-L" lisp "-L" emrs
                                    "--eval" (prin1-to-string form))))
          (should (equal (list status (with-current-buffer out (buffer-string)))
                         (list 0 (with-current-buffer out (buffer-string))))))
      (kill-buffer out))))

(ert-deftest quarry-test-grep-header-hint ()
  "The header line ends with the hint for the menu; a click runs the menu."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (with-current-buffer (quarry-test-grep--buffer)
      (let* ((header (quarry-grep--header))
             (start (- (length header) (length "? menu"))))
        (should (string-suffix-p " files   ? menu" (substring-no-properties header)))
        (should (eq (get-text-property start 'face header) 'quarry-grep-header-value))
        (should-not (get-text-property (1+ start) 'face header))
        (dolist (pos (list start (+ start 2) (+ start 5)))
          (should (equal (get-text-property pos 'help-echo header)
                         "mouse-1: show all keys (?)"))
          (should (eq (get-text-property pos 'mouse-face header) 'header-line-highlight))
          (should (eq (lookup-key (get-text-property pos 'keymap header) [header-line mouse-1])
                      (lookup-key (get-text-property pos 'keymap header) [header-line mouse-2])))
          (should (commandp (lookup-key (get-text-property pos 'keymap header)
                                        [header-line mouse-1]))))
        ;; The click opens the menu in the window of the header.
        (pop-to-buffer-same-window (current-buffer))
        (let ((click (list 'mouse-1 (list (selected-window) 'header-line '(0 . 0) 0)))
              (run (lookup-key (get-text-property start 'keymap header) [header-line mouse-1]))
              (called nil))
          (cl-letf (((symbol-function 'quarry-grep-menu)
                     (lambda () (interactive) (setq called t))))
            (funcall run click))
          (should called))))))

;;;; Replace

(defconst quarry-test-grep--replace-files
  `(("a.txt" . "foo_1 and foo_2\nnothing\nfoo_3\n")
    ("b.txt" . "über foo_4\n")
    ("long.txt" . ,(concat "foo_5 " (make-string 40 ?x) "\n"))
    ("none.txt" . "nothing\n"))
  "A tree for the preview: `foo_([0-9])' matches five times.
With `quarry-grep-max-columns' 20 the line of long.txt is shortened,
so its match cannot be replaced.")

(defmacro quarry-test-grep--with-preview (spec &rest body)
  "Run BODY with the tree of the preview searched; SPEC is (DIR).
The result buffer is current, its search is `foo_([0-9])' without a
template, and lines are cut at 20 characters."
  (declare (indent 1))
  `(quarry-test-grep--with-tree (,(car spec) quarry-test-grep--replace-files)
     (let ((quarry-grep-max-columns 20)
           (quarry-grep-replace-history nil))
       (quarry-test-grep--search ,(car spec) "foo_([0-9])")
       ,@body)))

(defun quarry-test-grep--text-start (path line)
  "Return where the text of the result line LINE of PATH starts."
  (with-current-buffer (quarry-test-grep--buffer)
    (next-single-property-change (quarry-test-grep--line-pos path line)
                                 'quarry-grep-prefix)))

(defun quarry-test-grep--results-text ()
  "Return the text of the result buffer before the status line."
  (with-current-buffer (quarry-test-grep--buffer)
    (buffer-substring-no-properties
     (point-min) (text-property-any (point-min) (point-max) 'quarry-grep-status t))))

(defun quarry-test-grep--replacement (pos)
  "Return the replacement of the match at POS as (NEW OFF DISPLAY).
DISPLAY is the text of the `display' property, or nil."
  (with-current-buffer (quarry-test-grep--buffer)
    (let ((display (get-text-property pos 'display)))
      (list (get-text-property pos 'quarry-grep-replacement)
            (get-text-property pos 'quarry-grep-replace-off)
            (and display (substring-no-properties display))))))

(defun quarry-test-grep--replace-counts ()
  "Return the counts of the header line, \"N of M\", or nil without one."
  (let ((header (quarry-test-grep--header)))
    (and (string-match "\\([0-9]+ of [0-9]+\\) matches on" header)
         (match-string 1 header))))

(ert-deftest quarry-test-grep-replace-preview ()
  "R shows old and new text per match; the buffer text stays the same."
  (quarry-test-grep--with-preview (dir)
    (let ((text (quarry-test-grep--results-text)))
      (should-not (plist-member (cdr (quarry-test-grep--request)) :replace))
      (should-not (quarry-grep--replace-p))
      (should-not (quarry-test-grep--replace-counts))
      (goto-char (point-min))
      (quarry-test-grep--keys "R bar_$1 RET")
      (should (equal (quarry-test-grep--request :replace) "bar_$1"))
      (should (equal (quarry-grep--search-replace quarry-grep--current) "bar_$1"))
      (should (quarry-grep--replace-p))
      (should (equal quarry-grep-replace-history '("bar_$1")))
      ;; Exactly the text of the search without a template.
      (should (equal (quarry-test-grep--results-text) text)))
    (let ((a1 (quarry-test-grep--text-start "a.txt" 1))
          (b1 (quarry-test-grep--text-start "b.txt" 1)))
      (should (equal (quarry-test-grep--replacement a1) '("bar_1" nil "foo_1bar_1")))
      (should (equal (quarry-test-grep--replacement (+ a1 4)) '("bar_1" nil "foo_1bar_1")))
      ;; Between the matches.
      (should (equal (quarry-test-grep--replacement (+ a1 5)) '(nil nil nil)))
      (should (equal (quarry-test-grep--replacement (+ a1 10)) '("bar_2" nil "foo_2bar_2")))
      (should (equal (quarry-test-grep--replacement (quarry-test-grep--text-start "a.txt" 3))
                     '("bar_3" nil "foo_3bar_3")))
      ;; A multibyte character before the match.
      (should (equal (quarry-test-grep--replacement (+ b1 5)) '("bar_4" nil "foo_4bar_4")))
      (should (equal (quarry-test-grep--replacement (+ b1 4)) '(nil nil nil)))
      ;; The faces of the display, and the match face kept below it.
      (let ((display (get-text-property a1 'display)))
        (should (eq (get-text-property 0 'face display) 'quarry-grep-replace-old))
        (should (eq (get-text-property 4 'face display) 'quarry-grep-replace-old))
        (should (eq (get-text-property 5 'face display) 'quarry-grep-replace-new)))
      (should (quarry-test-grep--has-face a1 'quarry-grep-match))
      ;; The shortened line has its match face and nothing to replace.
      (let* ((long (quarry-test-grep--line-pos "long.txt" 1))
             (end (save-excursion (goto-char long) (pos-eol))))
        (should (get-text-property long 'quarry-grep-inexact))
        (should (quarry-test-grep--has-face (quarry-test-grep--text-start "long.txt" 1)
                                            'quarry-grep-match))
        (should-not (text-property-not-all long end 'quarry-grep-replacement nil))
        (should-not (text-property-not-all long end 'display nil))))
    (should (equal (quarry-test-grep--replace-counts) "4 of 4"))
    (should (string-match-p "hits: 4 in 3 files   → bar_\\$1   4 of 4 matches on   \\? menu\\'"
                            (quarry-test-grep--header)))
    (should (string-match-p
             "\\`Search finished: 4 lines in 3 files, .*, 1 line cannot be replaced (shortened or not UTF-8)\\'"
             (quarry-test-grep--status)))
    ;; The template in the header runs R on a click; a % is doubled.
    (let* ((header (quarry-grep--header))
           (pos (string-search "bar_" header)))
      (should (eq (lookup-key (get-text-property pos 'keymap header) [header-line mouse-1])
                  (lookup-key (quarry-grep--header-map #'quarry-grep-replace)
                              [header-line mouse-1])))
      (should (equal (get-text-property pos 'help-echo header)
                     "mouse-1: change the replacement (R)")))
    ;; R starts from the current template.
    (should (equal (quarry-test-grep--prompts
                    (lambda () (quarry-test-grep--keys "R C-e % RET")))
                   '(("Replace matches with: " . "bar_$1"))))
    (should (equal (quarry-test-grep--request :replace) "bar_$1%"))
    (should (string-search "→ bar_$1%%   " (quarry-grep--header)))
    ;; An empty template deletes the matches.
    (quarry-grep-replace "")
    (quarry-test-grep--wait)
    (should (equal (quarry-test-grep--request :replace) ""))
    (should (equal (quarry-test-grep--replacement (quarry-test-grep--text-start "a.txt" 3))
                   '("" nil "foo_3")))
    (should (string-search "→ (empty)   4 of 4 matches on" (quarry-test-grep--header)))))

(ert-deftest quarry-test-grep-replace-toggle ()
  "x switches a match, a line or a file off and on, and moves on."
  (quarry-test-grep--with-preview (dir)
    (quarry-grep-replace "bar_$1")
    (quarry-test-grep--wait)
    (let ((a1 (quarry-test-grep--text-start "a.txt" 1))
          (a3 (quarry-test-grep--line-pos "a.txt" 3))
          (b1 (quarry-test-grep--line-pos "b.txt" 1)))
      ;; On the second match of a line: only that one, then the next line.
      (goto-char (+ a1 12))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replacement (+ a1 10)) '("bar_2" t nil)))
      (should (equal (quarry-test-grep--replacement a1) '("bar_1" nil "foo_1bar_1")))
      (should (equal (quarry-test-grep--replace-counts) "3 of 4"))
      (should (= (point) a3))
      ;; Again: on.
      (goto-char (+ a1 10))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replacement (+ a1 10)) '("bar_2" nil "foo_2bar_2")))
      (should (equal (quarry-test-grep--replace-counts) "4 of 4"))
      ;; Outside a match: the whole line, off while any is on.
      (goto-char (quarry-test-grep--line-pos "a.txt" 1))
      (quarry-test-grep--keys "x")
      (should (equal (mapcar #'cadr (list (quarry-test-grep--replacement a1)
                                          (quarry-test-grep--replacement (+ a1 10))))
                     '(t t)))
      (should (equal (quarry-test-grep--replace-counts) "2 of 4"))
      (should (= (point) a3))
      (goto-char (+ a1 10))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "3 of 4"))
      ;; One of two on: the line goes off.
      (goto-char (+ a1 6))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "2 of 4"))
      (goto-char (+ a1 6))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "4 of 4"))
      ;; A heading: the file off, then on; then the next file's line.
      (goto-char (quarry-test-grep--heading-pos "a.txt"))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "1 of 4"))
      (should (equal (quarry-test-grep--replacement (quarry-test-grep--text-start "a.txt" 3))
                     '("bar_3" t nil)))
      (should (= (point) b1))
      (goto-char (+ a1 10))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "2 of 4"))
      ;; One is on: all go off.
      (goto-char (quarry-test-grep--heading-pos "a.txt"))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "1 of 4"))
      (goto-char (quarry-test-grep--heading-pos "a.txt"))
      (quarry-test-grep--keys "x")
      (should (equal (quarry-test-grep--replace-counts) "4 of 4"))
      (should (equal (quarry-test-grep--replacement a1) '("bar_1" nil "foo_1bar_1")))
      ;; The last line with a match: point stays.
      (goto-char b1)
      (quarry-test-grep--keys "x")
      (should (= (point) b1))
      (should (equal (quarry-test-grep--replace-counts) "3 of 4"))
      ;; A folded file is passed over.
      (goto-char (quarry-test-grep--heading-pos "b.txt"))
      (quarry-test-grep--keys "TAB")
      (goto-char (quarry-test-grep--line-pos "a.txt" 1))
      (quarry-test-grep--keys "x")
      (should (= (point) a3))
      (quarry-test-grep--keys "x")
      (should (= (point) a3))
      ;; Nothing was searched again, and the text is the same.
      (should (= (length quarry-test-grep--requests) 2))
      ;; Lines with nothing to replace.
      (dolist (pos (list (quarry-test-grep--line-pos "long.txt" 1)
                         (quarry-test-grep--heading-pos "long.txt")
                         (point-max)))
        (goto-char pos)
        (quarry-test-grep--refused "No match \\(on this line\\|in this file\\) can be replaced"
          (quarry-grep-toggle-filter)))
      ;; On a filter line, x is the filter's.
      (goto-char (quarry-test-grep--filter-pos 0))
      (quarry-test-grep--refused "enabled include line filter" (quarry-grep-toggle-filter))
      ;; Applied: refused.
      (setq quarry-grep--replace-applied t)
      (goto-char a1)
      (quarry-test-grep--refused "g searches again" (quarry-grep-toggle-filter))))
  ;; Outside a preview, as before.
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--search dir)
    (goto-char (quarry-test-grep--line-pos "notes.txt" 1))
    (quarry-test-grep--refused "No filter at point" (quarry-grep-toggle-filter))))

(ert-deftest quarry-test-grep-replace-search-changes ()
  "A change keeps the template; C-c < and C-c C-k go back to the search."
  (quarry-test-grep--with-preview (dir)
    (quarry-grep-replace "bar_$1")
    (quarry-test-grep--wait)
    (should (= (length quarry-grep--past) 1))
    ;; A filter change and a switch keep the template.
    (quarry-test-grep--keys "+ l and RET")
    (should (equal (quarry-test-grep--request :replace) "bar_$1"))
    (should (equal (quarry-test-grep--results) '(("a.txt" 1 "foo_1 and foo_2"))))
    (should (equal (quarry-test-grep--replace-counts) "2 of 2"))
    (quarry-test-grep--keys "c")
    (should (equal (quarry-test-grep--request :replace) "bar_$1"))
    (should (= (length quarry-grep--past) 3))
    ;; Back to the search before R: no template.
    (quarry-test-grep--keys "C-c < C-c < C-c <")
    (should-not (quarry-grep--replace-p))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :replace))
    (should-not (quarry-test-grep--replace-counts))
    (should-not (text-property-not-all (point-min) (point-max) 'quarry-grep-replacement nil))
    (should-not (text-property-not-all (point-min) (point-max) 'display nil))
    (quarry-test-grep--keys "C-c >")
    (should (equal (quarry-test-grep--request :replace) "bar_$1"))
    ;; C-c C-k leaves the preview: a search without the template.
    (quarry-test-grep--keys "C-c C-k")
    (should-not (quarry-grep--replace-p))
    (should-not (plist-member (cdr (quarry-test-grep--request)) :replace))
    (should (equal (quarry-grep--search-filters quarry-grep--current)
                   (quarry-grep--search-filters (car quarry-grep--past))))
    (should-not (text-property-not-all (point-min) (point-max) 'display nil))
    (quarry-test-grep--refused "No search is running" (quarry-grep-cancel))
    ;; A template with a newline.
    (quarry-test-grep--refused "newline" (quarry-grep-replace "a\nb"))
    (quarry-grep-replace "bar")
    (quarry-test-grep--wait)
    ;; e during a preview.
    (quarry-test-grep--with-wgrep t
      (should-not (quarry-grep--editable-p)))
    (quarry-test-grep--refused "C-c C-k" (quarry-grep-edit))
    ;; R while editing.
    (cl-letf (((symbol-function 'quarry-grep--in-edit-mode-p) #'always))
      (setq quarry-grep--editing t)
      (unwind-protect
          (quarry-test-grep--refused "being edited" (quarry-grep-replace "x"))
        (setq quarry-grep--editing nil)))
    ;; A running preview: C-c C-k cancels it and keeps the template; the
    ;; next one leaves the preview.
    (quarry-test-grep--with-fake-stream
      (quarry-grep-rerun)
      (should (eq (quarry-test-grep--state) 'running))
      (execute-kbd-macro (kbd "C-c C-k"))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil)
      (should (eq (quarry-test-grep--state) 'cancelled))
      (should (quarry-grep--replace-p))
      (execute-kbd-macro (kbd "C-c C-k"))
      (should-not (quarry-grep--replace-p))
      (should-not (plist-member (cdr (car (car quarry-test-grep--fake))) :replace)))))

(ert-deftest quarry-test-grep-replace-old-module ()
  "A module that ignores :replace: the search runs without the template."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (set-buffer (quarry-test-grep--buffer))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
      (let ((plain quarry-grep--current))
        ;; Lines with the key, a nil one, and an inexact line without it.
        (quarry-grep-replace "x")
        (funcall (nth 1 (car quarry-test-grep--fake))
                 (list (list :file :path "a.txt" :path-spans nil :mtime nil
                             :lines '((:n 1 :text "needle" :spans ((0 6)) :secondary nil
                                       :inexact nil :replacements ("x"))
                                      (:n 2 :text "" :spans nil :secondary nil
                                       :inexact nil :replacements nil)
                                      (:n 3 :text "needle…" :spans ((0 6)) :secondary nil
                                       :inexact t)))))
        (should (= (length quarry-test-grep--fake) 2))
        (should (equal (quarry-test-grep--headings) '("a.txt")))
        (should (equal (quarry-test-grep--replace-counts) "1 of 1"))
        ;; An exact line without the key: an older module.
        (quarry-grep-rerun)
        (let ((messages
               (quarry-test-grep--messages
                (lambda ()
                  (funcall (nth 1 (car quarry-test-grep--fake))
                           (list (quarry-test-grep--item "a.txt" '(1 "needle" 0 6))))))))
          (should (equal messages
                         '("The loaded quarry module is older than replace; rebuild it with M-x quarry-build-module and restart Emacs"))))
        (should (= (length quarry-test-grep--fake) 4))
        (should-not (plist-member (cdr (car (car quarry-test-grep--fake))) :replace))
        (should (eq (quarry-test-grep--state) 'running))
        ;; The item was not shown; the search without the template replaced
        ;; the one with it, also in the history.
        (should-not (quarry-test-grep--headings))
        (should (equal quarry-grep--current plain))
        (should-not quarry-grep--past)
        (should-not quarry-grep--future)
        (should-not (quarry-test-grep--replace-counts))))))

;;;; Applying a replacement

(defmacro quarry-test-grep--answering (answer &rest body)
  "Run BODY with `y-or-n-p' giving ANSWER; return the questions asked."
  (declare (indent 1))
  `(let ((asked nil))
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt asked) ,answer)))
       ,@body)
     (nreverse asked)))

(defmacro quarry-test-grep--with-replace (spec &rest body)
  "Run BODY with a preview; SPEC is (DIR FILES PATTERN TEMPLATE).
DIR is bound to a tree of FILES, which is searched for the regexp
PATTERN with the replacement TEMPLATE.  The result buffer is current
and shown in the selected window.  Saving makes no backup files, which
the next search would find."
  (declare (indent 1))
  (pcase-let ((`(,dir ,files ,pattern ,template) spec))
    `(quarry-test-grep--with-tree (,dir ,files)
       (let ((make-backup-files nil))
         (quarry-test-grep--search ,dir ,pattern)
         (quarry-grep-replace ,template)
         (quarry-test-grep--wait)
         (pop-to-buffer-same-window (quarry-test-grep--buffer))
         ,@body))))

(defun quarry-test-grep--apply (answer)
  "Press C-c C-c in the result buffer, answering ANSWER; return the questions."
  (pop-to-buffer-same-window (quarry-test-grep--buffer))
  (quarry-test-grep--answering answer
    (execute-kbd-macro (kbd "C-c C-c"))))

(defun quarry-test-grep--bytes (dir path)
  "Return the bytes of the file PATH of DIR as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally (expand-file-name path dir))
    (buffer-string)))

(defun quarry-test-grep--write-bytes (dir path bytes)
  "Write BYTES, a unibyte string, to the file PATH of DIR as they are."
  (let ((coding-system-for-write 'no-conversion))
    (write-region bytes nil (expand-file-name path dir) nil 'silent)))

(defun quarry-test-grep--replace-results ()
  "Return what applying left on the result lines, in buffer order.
A list of (PATH LINE RESULT HELP): RESULT is `applied' or `rejected',
HELP the `help-echo' of the line.  Each overlay must cover its line
and have the face of its result."
  (with-current-buffer (quarry-test-grep--buffer)
    (mapcar (lambda (overlay)
              (let ((bol (overlay-start overlay))
                    (result (overlay-get overlay 'quarry-grep-replace-result)))
                (should (= (overlay-end overlay) (save-excursion (goto-char bol) (pos-eol))))
                (should (eq (overlay-get overlay 'face)
                            (if (eq result 'applied)
                                'quarry-grep-replace-applied
                              'quarry-grep-replace-rejected)))
                (list (get-text-property bol 'quarry-grep-file)
                      (get-text-property bol 'quarry-grep-line)
                      result
                      (overlay-get overlay 'help-echo))))
            (sort (seq-filter (lambda (overlay) (overlay-get overlay 'quarry-grep-replaced))
                              (overlays-in (point-min) (point-max)))
                  (lambda (a b) (< (overlay-start a) (overlay-start b)))))))

(defconst quarry-test-grep--apply-files
  '(("a.txt" . "foo_1 and foo_2\nnothing\nfoo_3 foo_4\n")
    ("b.txt" . "x foo_5\n")
    ("c.txt" . "keep\nfoo_6 end\nfoo_7\nlast line\n")
    ("d/e.txt" . "foo_8foo_9\n"))
  "A tree to apply `foo_([0-9])' → `bar_$1' to.")

(ert-deftest quarry-test-grep-replace-apply ()
  "C-c C-c writes the switched-on matches, into files and a visiting buffer."
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "new_${1}x")
    (let ((visiting (find-file-noselect (expand-file-name "c.txt" dir)))
          (a1 (quarry-test-grep--text-start "a.txt" 1)))
      ;; Point in the visiting buffer, after a match that gets longer.
      (with-current-buffer visiting
        (goto-char (point-min))
        (search-forward "foo_6 ")
        (should (looking-at-p "end")))
      ;; The second match of a.txt:1 and all of b.txt off.
      (goto-char (+ a1 10))
      (quarry-test-grep--keys "x")
      (goto-char (quarry-test-grep--heading-pos "b.txt"))
      (quarry-test-grep--keys "x")
      (should (quarry-grep--applicable-p))
      ;; No: nothing is written.
      (should (equal (quarry-test-grep--apply nil)
                     '("Replace 7 matches on 5 lines in 3 files? ")))
      (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1 and foo_2\nnothing\nfoo_3 foo_4\n"))
      (should-not quarry-grep--replace-applied)
      (should-not (quarry-test-grep--replace-results))
      ;; Yes.
      (let ((sent (length quarry-test-grep--requests))
            (messages (quarry-test-grep--messages
                       (lambda () (should (quarry-test-grep--apply t))))))
        (should (equal (car (last messages)) "Replaced 5 lines in 3 files; 0 rejected"))
        ;; Nothing was searched.
        (should (= (length quarry-test-grep--requests) sent)))
      (should (equal (quarry-test-grep--bytes dir "a.txt") "new_1x and foo_2\nnothing\nnew_3x new_4x\n"))
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x foo_5\n"))
      (should (equal (quarry-test-grep--bytes dir "c.txt") "keep\nnew_6x end\nnew_7x\nlast line\n"))
      (should (equal (quarry-test-grep--bytes dir "d/e.txt") "new_8xnew_9x\n"))
      ;; The visiting buffer was changed and saved; its point stayed with its text.
      (with-current-buffer visiting
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) "keep\nnew_6x end\nnew_7x\nlast line\n"))
        (should (looking-at-p "end")))
      (should (equal (quarry-test-grep--replace-results)
                     '(("a.txt" 1 applied "replaced")
                       ("a.txt" 3 applied "replaced")
                       ("c.txt" 2 applied "replaced")
                       ("c.txt" 3 applied "replaced")
                       ("d/e.txt" 1 applied "replaced"))))
      (should (string-match-p "\nReplaced 5 lines in 3 files; 0 rejected\\'"
                              (quarry-test-grep--status)))
      ;; The preview stays as it was.
      (should (equal (quarry-test-grep--replacement a1) '("new_1x" nil "foo_1new_1x")))
      ;; Applied: x, C-c C-c and e are refused, also in the menu.
      (should quarry-grep--replace-applied)
      (should-not (quarry-grep--applicable-p))
      (should (equal (quarry-test-grep--menu-inactive '("C-c C-c")) '("C-c C-c")))
      (goto-char a1)
      (quarry-test-grep--refused "g searches again" (quarry-grep-toggle-filter))
      (quarry-test-grep--refused "g searches again" (quarry-grep-replace-apply))
      (quarry-test-grep--refused "g searches again" (quarry-grep-edit))
      ;; A search ends the state and removes the overlays.
      (quarry-test-grep--keys "g")
      (should-not quarry-grep--replace-applied)
      (should-not (quarry-test-grep--replace-results))
      (should-not (string-search "Replaced" (quarry-test-grep--status)))
      (should (equal (quarry-test-grep--results)
                     '(("a.txt" 1 "new_1x and foo_2") ("b.txt" 1 "x foo_5"))))
      (should (quarry-grep--applicable-p)))))

(ert-deftest quarry-test-grep-replace-apply-after-narrowing ()
  "Files and lines that a change after R leaves out are not written."
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "new_$1")
    ;; A path filter, the file at point, a glob and a line filter.
    (quarry-test-grep--keys "- p b.txt RET")
    (goto-char (quarry-test-grep--heading-pos "c.txt"))
    (quarry-test-grep--keys "- f")
    (quarry-test-grep--keys "f !d/ RET")
    (quarry-test-grep--keys "- l foo_3 RET")
    (should (equal (quarry-test-grep--request :replace) "new_$1"))
    (should (equal (quarry-test-grep--results) '(("a.txt" 1 "foo_1 and foo_2"))))
    (should (equal (quarry-test-grep--apply t)
                   '("Replace 2 matches on 1 line in 1 file? ")))
    (should (equal (quarry-test-grep--bytes dir "a.txt") "new_1 and new_2\nnothing\nfoo_3 foo_4\n"))
    (pcase-dolist (`(,path . ,content) (cdr quarry-test-grep--apply-files))
      (should (equal (quarry-test-grep--bytes dir path) content)))))

(ert-deftest quarry-test-grep-replace-apply-refused ()
  "C-c C-c is refused without a complete preview with matches switched on."
  (quarry-test-grep--with-tree (dir quarry-test-grep--apply-files)
    (quarry-test-grep--search dir "foo_([0-9])")
    ;; No template.
    (should-not (quarry-grep--applicable-p))
    (quarry-test-grep--refused "R starts one" (quarry-grep-replace-apply))
    (quarry-grep-replace "bar_$1")
    (quarry-test-grep--wait)
    (should (quarry-grep--applicable-p))
    (should-not (quarry-test-grep--menu-inactive '("C-c C-c")))
    ;; Nothing switched on.
    (dolist (path '("a.txt" "b.txt" "c.txt" "d/e.txt"))
      (goto-char (quarry-test-grep--heading-pos path))
      (quarry-test-grep--keys "x"))
    (should-not (quarry-grep--applicable-p))
    (quarry-test-grep--refused "No match is switched on" (quarry-grep-replace-apply))
    ;; Running, cancelled and failed.
    (quarry-test-grep--with-fake-stream
      (quarry-grep-rerun)
      (should-not (quarry-grep--applicable-p))
      (quarry-test-grep--refused "search is running" (quarry-grep-replace-apply))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'cancelled nil)
      (should-not (quarry-grep--applicable-p))
      (quarry-test-grep--refused "cancelled" (quarry-grep-replace-apply))
      (quarry-grep-rerun)
      (funcall (nth 2 (car quarry-test-grep--fake)) 'error '(:kind failed :message "boom"))
      (should (eq (quarry-test-grep--state) 'failed))
      (should-not (quarry-grep--applicable-p))
      (quarry-test-grep--refused "failed" (quarry-grep-replace-apply)))
    ;; Truncated: only what is shown would be written.
    (let ((quarry-grep-max-lines 2))
      (quarry-test-grep--keys "g")
      (should (plist-get quarry-grep--summary :truncated))
      (should-not (quarry-grep--applicable-p))
      (quarry-test-grep--refused "narrow the search or raise `quarry-grep-max-lines'"
        (quarry-grep-replace-apply)))
    (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1 and foo_2\nnothing\nfoo_3 foo_4\n"))))

(ert-deftest quarry-test-grep-replace-apply-stale ()
  "A file changed since the search: search again, or stop without writing."
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((b (expand-file-name "b.txt" dir))
          (sent (length quarry-test-grep--requests)))
      (set-file-times b (time-add (file-attribute-modification-time (file-attributes b)) 3))
      ;; No: nothing is written and nothing searched.
      (let ((messages (quarry-test-grep--messages
                       (lambda ()
                         (should (equal (quarry-test-grep--apply nil)
                                        '("1 result file changed since the search (b.txt); search again first? ")))))))
        (should (equal messages '("Nothing was replaced"))))
      (should (= (length quarry-test-grep--requests) sent))
      (should-not quarry-grep--replace-applied)
      (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1 and foo_2\nnothing\nfoo_3 foo_4\n"))
      ;; Yes: the search runs again with the template; nothing is written.
      (should (equal (length (quarry-test-grep--apply t)) 1))
      (should (= (length quarry-test-grep--requests) (1+ sent)))
      (quarry-test-grep--wait)
      (should (equal (quarry-test-grep--request :replace) "bar_$1"))
      (should-not quarry-grep--replace-applied)
      (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1 and foo_2\nnothing\nfoo_3 foo_4\n"))
      ;; Now nothing is stale: the only question is the one to replace.
      (should (equal (quarry-test-grep--apply t)
                     '("Replace 9 matches on 6 lines in 4 files? ")))
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x bar_5\n")))))

(ert-deftest quarry-test-grep-replace-apply-line-changed ()
  "A line that differs from the search is rejected; the file's others are written."
  (quarry-test-grep--with-replace (dir '(("a.txt" . "foo_1\nfoo_2\nfoo_3\n")) "foo_([0-9])" "bar_$1")
    (let* ((a (expand-file-name "a.txt" dir))
           (time (file-attribute-modification-time (file-attributes a))))
      ;; Changed on disk with the time set back, so the stale check passes.
      (quarry-test-grep--write-bytes dir "a.txt" "foo_1\nfoo_2 changed\nfoo_3\n")
      (set-file-times a time)
      (should-not (quarry-grep--stale-files))
      (quarry-test-grep--apply t)
      (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1\nfoo_2 changed\nbar_3\n"))
      (should (equal (quarry-test-grep--replace-results)
                     '(("a.txt" 1 applied "replaced")
                       ("a.txt" 2 rejected "line changed since the search")
                       ("a.txt" 3 applied "replaced"))))
      (should (string-match-p "\nReplaced 2 lines in 1 file; 1 rejected\\'"
                              (quarry-test-grep--status)))
      ;; Searching again shows what still matches.
      (quarry-test-grep--keys "g")
      (should (equal (quarry-test-grep--results) '(("a.txt" 2 "foo_2 changed")))))))

(ert-deftest quarry-test-grep-replace-apply-unwritable ()
  "A file that cannot be written and a read-only buffer reject their lines."
  (skip-unless (not (zerop (user-uid))))
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((b (expand-file-name "b.txt" dir)))
      (set-file-modes b #o444)
      (with-current-buffer (find-file-noselect (expand-file-name "c.txt" dir))
        (setq buffer-read-only t))
      (quarry-test-grep--apply t)
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x foo_5\n"))
      (should (equal (quarry-test-grep--bytes dir "c.txt") "keep\nfoo_6 end\nfoo_7\nlast line\n"))
      (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1 and bar_2\nnothing\nbar_3 bar_4\n"))
      (should (equal (quarry-test-grep--bytes dir "d/e.txt") "bar_8bar_9\n"))
      (let ((results (quarry-test-grep--replace-results)))
        (should (equal (mapcar (lambda (result) (seq-take result 3)) results)
                       '(("a.txt" 1 applied) ("a.txt" 3 applied)
                         ("b.txt" 1 rejected)
                         ("c.txt" 2 rejected) ("c.txt" 3 rejected)
                         ("d/e.txt" 1 applied))))
        (should (string-match-p "Permission denied" (nth 3 (nth 2 results))))
        (should (equal (nth 3 (nth 3 results)) "buffer is read-only")))
      (should (string-match-p "\nReplaced 3 lines in 2 files; 3 rejected\\'"
                              (quarry-test-grep--status)))
      (set-file-modes b #o644))))

(ert-deftest quarry-test-grep-replace-apply-stopped ()
  "C-g stops after the file being written; the status line says what was left."
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((write (symbol-function 'quarry-grep--replace-in-file)))
      ;; As if C-g came while the first file was written.
      (cl-letf (((symbol-function 'quarry-grep--replace-in-file)
                 (lambda (&rest args)
                   (prog1 (apply write args)
                     (setq quit-flag t)))))
        (quarry-test-grep--apply t)))
    (should-not quit-flag)
    (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1 and bar_2\nnothing\nbar_3 bar_4\n"))
    (should (equal (quarry-test-grep--bytes dir "b.txt") "x foo_5\n"))
    (should (equal (quarry-test-grep--replace-results)
                   '(("a.txt" 1 applied "replaced") ("a.txt" 3 applied "replaced"))))
    (should (string-match-p
             "\nReplaced 2 lines in 1 file; 0 rejected; stopped, 3 files not processed\\'"
             (quarry-test-grep--status)))))

(ert-deftest quarry-test-grep-replace-apply-encodings ()
  "Line ends, a byte order mark and Latin-1 are kept; a Latin-1 line is not replaced."
  (quarry-test-grep--with-tree (dir '(("crlf.txt" . "") ("bom.txt" . "") ("latin.txt" . "")))
    (let ((make-backup-files nil))
      (quarry-test-grep--write-bytes dir "crlf.txt" "foo_1 x\r\nnothing\r\nfoo_2\r\n")
      ;; \x66 is f and \x62 b: a hex escape takes all hex digits after it.
      (quarry-test-grep--write-bytes dir "bom.txt" "\xef\xbb\xbf\x66oo_3\n\xc3\xbc foo_4\n")
      (quarry-test-grep--write-bytes dir "latin.txt" "caf\xe9 foo_5\nfoo_6\n")
      (quarry-test-grep--search dir "foo_([0-9])")
      (quarry-grep-replace "bär_$1")
      (quarry-test-grep--wait)
      ;; The Latin-1 line holds a byte that is not UTF-8.
      (should (get-text-property (quarry-test-grep--line-pos "latin.txt" 1) 'quarry-grep-inexact))
      (should (equal (quarry-test-grep--apply t) '("Replace 5 matches on 5 lines in 3 files? ")))
      (should (equal (quarry-test-grep--bytes dir "crlf.txt")
                     "b\xc3\xa4r_1 x\r\nnothing\r\nb\xc3\xa4r_2\r\n"))
      (should (equal (quarry-test-grep--bytes dir "bom.txt")
                     "\xef\xbb\xbf\x62\xc3\xa4r_3\n\xc3\xbc b\xc3\xa4r_4\n"))
      (should (equal (quarry-test-grep--bytes dir "latin.txt") "caf\xe9 foo_5\nb\xe4r_6\n"))
      (should (equal (seq-filter (lambda (result) (eq (nth 2 result) 'rejected))
                                 (quarry-test-grep--replace-results))
                     nil)))))

(ert-deftest quarry-test-grep-replace-apply-many-files ()
  "500 files with 4 matches each are all written as expected."
  (let* ((count 500)
         (paths (cl-loop for i below count
                         collect (format "d%d/f%03d.txt" (% i 10) i)))
         (content (lambda (word)
                    (format "x %s_1 y %s_2\nmiddle\n%s_3\nend %s_4\n" word word word word))))
    (quarry-test-grep--with-replace (dir (mapcar (lambda (path) (cons path (funcall content "foo")))
                                                 paths)
                                         "foo_([0-9])" "bar_$1")
      (should (= quarry-grep--files count))
      (let ((start (float-time)))
        (should (equal (quarry-test-grep--apply t)
                       '("Replace 2000 matches on 1500 lines in 500 files? ")))
        (message "quarry-test-grep-replace-apply-many-files: applied in %.2f s"
                 (- (float-time) start)))
      (should (string-match-p "\nReplaced 1500 lines in 500 files; 0 rejected\\'"
                              (quarry-test-grep--status)))
      (let ((expected (funcall content "bar")))
        (dolist (path paths)
          (should (equal (list path (quarry-test-grep--bytes dir path))
                         (list path expected))))))))

(ert-deftest quarry-test-grep-replace-apply-no-conversion ()
  "A file is read and written as its bytes: no format, hook or annotation runs."
  (let ((enriched "Content-Type: text/enriched\nText-Width: 70\n\nfoo\n\nfoo <bold>x</bold>\n\nfoo\n"))
    (quarry-test-grep--with-replace (dir `(("e.txt" . ,enriched)) "foo" "bar")
      (let ((after-insert-file-functions
             (list (lambda (length) (goto-char (point-min)) (insert "inserted\n") (+ length 9))))
            (write-region-annotate-functions
             (list (lambda (_start _end) '((1 . "annotated\n"))))))
        (should (equal (quarry-test-grep--apply t) '("Replace 3 matches on 3 lines in 1 file? "))))
      (should (equal (quarry-test-grep--bytes dir "e.txt")
                     (string-replace "foo" "bar" enriched)))
      (should (equal (mapcar (lambda (result) (nth 2 result)) (quarry-test-grep--replace-results))
                     '(applied applied applied))))))

(ert-deftest quarry-test-grep-replace-apply-ambiguous-encoding ()
  "A file read as Latin-1 that holds UTF-8 is not written."
  (quarry-test-grep--with-tree (dir '(("u.txt" . "")))
    (let ((make-backup-files nil)
          (bytes "\xc3\xbc foo_1\nfoo_2\nbad \xff\n"))
      (quarry-test-grep--write-bytes dir "u.txt" bytes)
      (quarry-test-grep--search dir "foo_([0-9])")
      (quarry-grep-replace "bär_$1")
      (quarry-test-grep--wait)
      (quarry-test-grep--apply t)
      (should (equal (quarry-test-grep--bytes dir "u.txt") bytes))
      (should (equal (quarry-test-grep--replace-results)
                     (mapcar (lambda (n)
                               (list "u.txt" n 'rejected
                                     "the file's encoding is ambiguous (UTF-8 mixed with other bytes)"))
                             '(1 2)))))))

(ert-deftest quarry-test-grep-replace-apply-unencodable ()
  "New text that the file's encoding cannot hold rejects the file's lines."
  (quarry-test-grep--with-tree (dir '(("latin.txt" . "")))
    (let ((make-backup-files nil)
          (bytes "caf\xe9 x\nfoo_1\nfoo_2\n"))
      (quarry-test-grep--write-bytes dir "latin.txt" bytes)
      (quarry-test-grep--search dir "foo_([0-9])")
      (quarry-grep-replace "€_$1")
      (quarry-test-grep--wait)
      (quarry-test-grep--apply t)
      (should (equal (quarry-test-grep--bytes dir "latin.txt") bytes))
      (let ((results (quarry-test-grep--replace-results)))
        (should (equal (mapcar (lambda (result) (seq-take result 3)) results)
                       '(("latin.txt" 2 rejected) ("latin.txt" 3 rejected))))
        (dolist (result results)
          (should (string-match-p "\\`The new text has a character that .*latin-1.* cannot encode: €\\'"
                                  (nth 3 result))))))))

(ert-deftest quarry-test-grep-replace-apply-save-fails ()
  "A buffer that cannot be saved gets its old text back, unmodified."
  (skip-unless (not (zerop (user-uid))))
  (quarry-test-grep--with-replace (dir '(("a.txt" . "foo_1\n") ("c.txt" . "foo_2\nfoo_3\n"))
                                       "foo_([0-9])" "bar_$1")
    (let* ((c (expand-file-name "c.txt" dir))
           (buffer (find-file-noselect c))
           (undo (buffer-local-value 'buffer-undo-list buffer))
           (asked nil))
      (set-file-modes c #o444)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq buffer-read-only nil))
            ;; No to "try to save anyway?".
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt) (push prompt asked) nil)))
              (quarry-test-grep--apply t))
            (should (string-match-p "write-protected" (car asked)))
            (with-current-buffer buffer
              (should (equal (buffer-string) "foo_2\nfoo_3\n"))
              (should-not (buffer-modified-p))
              (should (equal buffer-undo-list undo)))
            (should (equal (quarry-test-grep--bytes dir "c.txt") "foo_2\nfoo_3\n"))
            (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1\n"))
            (let ((results (quarry-test-grep--replace-results)))
              (should (equal (mapcar (lambda (result) (seq-take result 3)) results)
                             '(("a.txt" 1 applied) ("c.txt" 1 rejected) ("c.txt" 2 rejected))))
              (should (string-match-p "allowed to write" (nth 3 (nth 1 results)))))
            (should (string-match-p "\nReplaced 1 line in 1 file; 2 rejected\\'"
                                    (quarry-test-grep--status))))
        (set-file-modes c #o644)))))

(ert-deftest quarry-test-grep-replace-apply-quit-in-save ()
  "C-g while a buffer is saved restores it and stops; after the writing it stops."
  ;; Before the file is written: from `write-file-functions'.
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((buffer (find-file-noselect (expand-file-name "b.txt" dir))))
      (with-current-buffer buffer
        ;; As C-g: quits at the next chance, unless quitting is inhibited.
        (add-hook 'write-file-functions (lambda () (setq quit-flag t) (identity nil)) nil t))
      (quarry-test-grep--apply t)
      (should-not quit-flag)
      (with-current-buffer buffer
        (should (equal (buffer-string) "x foo_5\n"))
        (should-not (buffer-modified-p)))
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x foo_5\n"))
      (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1 and bar_2\nnothing\nbar_3 bar_4\n"))
      (should (equal (quarry-test-grep--bytes dir "c.txt") "keep\nfoo_6 end\nfoo_7\nlast line\n"))
      (should (equal (quarry-test-grep--replace-results)
                     '(("a.txt" 1 applied "replaced") ("a.txt" 3 applied "replaced")
                       ("b.txt" 1 rejected "stopped"))))
      (should (string-match-p
               "\nReplaced 2 lines in 1 file; 1 rejected; stopped, 2 files not processed\\'"
               (quarry-test-grep--status)))))
  ;; After the file is written: from `after-save-hook'; the file counts.
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((buffer (find-file-noselect (expand-file-name "b.txt" dir))))
      (with-current-buffer buffer
        (add-hook 'after-save-hook (lambda () (setq quit-flag t) (identity nil)) nil t))
      (quarry-test-grep--apply t)
      (should-not quit-flag)
      (with-current-buffer buffer
        (should (equal (buffer-string) "x bar_5\n"))
        (should-not (buffer-modified-p)))
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x bar_5\n"))
      (should (equal (quarry-test-grep--bytes dir "c.txt") "keep\nfoo_6 end\nfoo_7\nlast line\n"))
      (should (string-match-p
               "\nReplaced 3 lines in 2 files; 0 rejected; stopped, 2 files not processed\\'"
               (quarry-test-grep--status))))))

(ert-deftest quarry-test-grep-replace-apply-undo ()
  "The changes to a visiting buffer are one undo step."
  (quarry-test-grep--with-replace (dir '(("c.txt" . "foo_1\nfoo_2 foo_3\n")) "foo_([0-9])" "bar_$1")
    (let ((buffer (find-file-noselect (expand-file-name "c.txt" dir))))
      (quarry-test-grep--apply t)
      (with-current-buffer buffer
        (should (equal (buffer-string) "bar_1\nbar_2 bar_3\n"))
        (let ((pending-undo-list buffer-undo-list))
          (while (and pending-undo-list (null (car pending-undo-list)))
            (pop pending-undo-list))
          (undo-more 1))
        (should (equal (buffer-string) "foo_1\nfoo_2 foo_3\n"))))))

(ert-deftest quarry-test-grep-replace-apply-literal-buffer ()
  "A buffer visited literally takes ASCII new text only."
  (quarry-test-grep--with-replace (dir '(("a.txt" . "foo_1\n") ("b.txt" . "foo_2\n"))
                                       "foo_([0-9])" "bär_$1")
    (find-file-literally (expand-file-name "a.txt" dir))
    (with-current-buffer (find-file-noselect (expand-file-name "b.txt" dir))
      (setq buffer-file-coding-system 'no-conversion))
    (quarry-test-grep--apply t)
    (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1\n"))
    (should (equal (quarry-test-grep--bytes dir "b.txt") "foo_2\n"))
    (should (equal (quarry-test-grep--replace-results)
                   '(("a.txt" 1 rejected "buffer is visited literally")
                     ("b.txt" 1 rejected "buffer is visited literally"))))
    ;; ASCII is the same in every encoding.
    (quarry-grep-replace "bar_$1")
    (quarry-test-grep--wait)
    (quarry-test-grep--apply t)
    (should (equal (quarry-test-grep--bytes dir "a.txt") "bar_1\n"))
    (should (equal (quarry-test-grep--bytes dir "b.txt") "bar_2\n"))))

(ert-deftest quarry-test-grep-replace-apply-save-hooks ()
  "A buffer is saved without `before-save-hook' and a final newline; after it runs."
  (quarry-test-grep--with-replace (dir '(("c.el" . "foo_1\nfoo_2")) "foo_([0-9])" "bar_$1")
    (let ((buffer (find-file-noselect (expand-file-name "c.el" dir)))
          (after nil))
      (with-current-buffer buffer
        (should require-final-newline)
        (add-hook 'before-save-hook
                  (lambda () (goto-char (point-min)) (insert ";; hook\n"))
                  nil t)
        (add-hook 'after-save-hook (lambda () (setq after t)) nil t))
      (quarry-test-grep--apply t)
      (should (equal (quarry-test-grep--bytes dir "c.el") "bar_1\nbar_2"))
      (should after)
      (with-current-buffer buffer
        (should (equal (buffer-string) "bar_1\nbar_2"))
        (should-not (buffer-modified-p))))))

(ert-deftest quarry-test-grep-replace-apply-unpaired-replacements ()
  "A line whose new texts do not pair up with its matches cannot be replaced."
  (quarry-test-grep--with-tree (dir)
    (quarry-test-grep--with-fake-stream
      (quarry-grep "needle" nil dir)
      (set-buffer (quarry-test-grep--buffer))
      (funcall (nth 2 (car quarry-test-grep--fake)) 'done nil)
      (quarry-grep-replace "x")
      (funcall (nth 1 (car quarry-test-grep--fake))
               (list (list :file :path "a.txt" :path-spans nil :mtime nil
                           :lines '((:n 1 :text "needle needle" :spans ((0 6) (7 13))
                                     :secondary nil :inexact nil :replacements ("x"))
                                    (:n 2 :text "needle" :spans ((0 6)) :secondary nil
                                     :inexact nil :replacements ("x" "y"))
                                    (:n 3 :text "needle" :spans ((0 6)) :secondary nil
                                     :inexact nil :replacements ("x"))))))
      (should (equal (quarry-test-grep--replace-counts) "1 of 1"))
      (should (= quarry-grep--replace-inexact 2))
      (dolist (line '(1 2))
        (let ((pos (quarry-test-grep--line-pos "a.txt" line)))
          (should-not (text-property-not-all pos (save-excursion (goto-char pos) (pos-eol))
                                             'quarry-grep-replacement nil))))
      (should (equal (quarry-test-grep--replacement (quarry-test-grep--text-start "a.txt" 3))
                     '("x" nil "needlex"))))))

(ert-deftest quarry-test-grep-replace-apply-unwritable-directory ()
  "A writable file in a directory that cannot be written is written in place."
  (skip-unless (not (zerop (user-uid))))
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((d (expand-file-name "d" dir)))
      (set-file-modes (expand-file-name "e.txt" d) #o640)
      (set-file-modes d #o555)
      (unwind-protect
          (quarry-test-grep--apply t)
        (set-file-modes d #o755))
      (should (equal (quarry-test-grep--bytes dir "d/e.txt") "bar_8bar_9\n"))
      (should (= (file-modes (expand-file-name "e.txt" d)) #o640))
      ;; No new file and no lock file.
      (should (equal (directory-files d nil "\\`[^.]\\|\\`\\.[^.]") '("e.txt")))
      (should (equal (quarry-test-grep--bytes dir "b.txt") "x bar_5\n"))
      (should (equal (car (last (quarry-test-grep--replace-results)))
                     '("d/e.txt" 1 applied "replaced"))))))

(ert-deftest quarry-test-grep-replace-apply-written-then-signal ()
  "A save that wrote the file and then signalled keeps the changes."
  (quarry-test-grep--with-tree (dir '(("a.txt" . "x\nfoo\ny\n")
                                      ("b.txt" . "x\nfoo\ny\n")
                                      ("c.txt" . "x\nfoo\ny\n")))
    (let ((make-backup-files nil)
          (cases
           `(;; `after-save-hook' changes the buffer and fails.
             ("a.txt" after-save-hook
              ,(lambda () (goto-char (point-max)) (insert "z") (error "Boom"))
              "x\nbar\ny\nz" error)
             ;; `after-save-hook' changes the buffer and quits.
             ("b.txt" after-save-hook
              ,(lambda () (goto-char (point-max)) (insert "z") (signal 'quit nil))
              "x\nbar\ny\nz" quit)
             ;; `write-contents-functions' writes the file and fails:
             ;; `save-buffer' never gets to `after-save-hook'.
             ("c.txt" write-contents-functions
              ,(lambda ()
                 (let ((coding-system-for-write 'utf-8-unix))
                   (write-region nil nil buffer-file-name nil 'silent))
                 (error "Late"))
              "x\nbar\ny\n" error))))
      (pcase-dolist (`(,name ,hook ,function ,text ,signal) cases)
        (with-current-buffer (find-file-noselect (expand-file-name name dir))
          (add-hook hook function nil t)
          (let* ((result nil)
                 (quit nil)
                 (messages (quarry-test-grep--messages
                            (lambda ()
                              (let ((inhibit-quit t))
                                (setq result (quarry-grep--replace-in-file
                                              buffer-file-name '((nil 2 "foo" "bar")))
                                      quit quit-flag
                                      quit-flag nil))))))
            (should (equal (list name result) (list name '(nil))))
            (should (equal (quarry-test-grep--bytes dir name) "x\nbar\ny\n"))
            ;; The changes stay, with what the hook did.
            (should (equal (buffer-string) text))
            (should (eq (buffer-modified-p) (not (equal text "x\nbar\ny\n"))))
            (should (verify-visited-file-modtime))
            ;; A `quit' is kept for the caller, an error shown.
            (if (eq signal 'quit)
                (progn (should quit)
                       (should-not messages))
              (should-not quit)
              (should (equal messages
                             (list (format "Error after saving %s: %s" name
                                           (if (equal name "a.txt") "Boom" "Late")))))))
          (remove-hook hook function t))))))

(ert-deftest quarry-test-grep-replace-apply-unsaved-changes ()
  "A visiting buffer with unsaved changes is not changed or saved."
  ;; A hard link outside the tree: the stale check does not see it.
  (quarry-test-grep--with-replace (dir '(("a.txt" . "foo_1\n") ("b.txt" . "foo_2\n"))
                                       "foo_([0-9])" "bar_$1")
    (let* ((other (make-temp-file "quarry-test-other" t))
           (link (expand-file-name "a.txt" other)))
      (unwind-protect
          (progn
            (add-name-to-file (expand-file-name "a.txt" dir) link)
            (with-current-buffer (find-file-noselect link)
              (goto-char (point-max))
              (insert "edit\n"))
            (should-not (quarry-grep--stale-files))
            (quarry-test-grep--apply t)
            (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1\n"))
            (should (equal (quarry-test-grep--bytes dir "b.txt") "bar_2\n"))
            (with-current-buffer (get-file-buffer link)
              (should (equal (buffer-string) "foo_1\nedit\n"))
              (should (buffer-modified-p)))
            (should (equal (quarry-test-grep--replace-results)
                           '(("a.txt" 1 rejected "buffer has unsaved changes")
                             ("b.txt" 1 applied "replaced")))))
        (when-let* ((buffer (get-file-buffer link)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (delete-directory other t))))
  ;; A buffer changed by the user, called directly.
  (quarry-test-grep--with-tree (dir '(("a.txt" . "foo_1\n")))
    (with-current-buffer (find-file-noselect (expand-file-name "a.txt" dir))
      (goto-char (point-max))
      (insert "edit\n")
      (should (equal (quarry-grep--replace-in-buffer '((nil 1 "foo_1" "bar_1")))
                     '("buffer has unsaved changes")))
      (should (equal (buffer-string) "foo_1\nedit\n"))
      (should (buffer-modified-p))
      (should (equal (quarry-test-grep--bytes dir "a.txt") "foo_1\n")))))

(ert-deftest quarry-test-grep-replace-apply-unencodable-in-buffer ()
  "A visiting buffer whose encoding cannot hold a new text is not changed."
  (quarry-test-grep--with-tree (dir '(("latin.txt" . "")))
    (let ((make-backup-files nil)
          (bytes "caf\xe9\nfoo\n"))
      (quarry-test-grep--write-bytes dir "latin.txt" bytes)
      (with-current-buffer (find-file-noselect (expand-file-name "latin.txt" dir))
        (should (eq (coding-system-base buffer-file-coding-system) 'iso-latin-1))
        (let ((result (quarry-grep--replace-in-file buffer-file-name '((nil 2 "foo" "€")))))
          (should (= (length result) 1))
          (should (string-match-p
                   "\\`The new text has a character that .*latin-1.* cannot encode: €\\'"
                   (car result))))
        (should (equal (buffer-string) "café\nfoo\n"))
        (should-not (buffer-modified-p))
        (should (equal (quarry-test-grep--bytes dir "latin.txt") bytes))
        ;; Text that Latin-1 holds is written.
        (should (equal (quarry-grep--replace-in-file buffer-file-name '((nil 2 "foo" "bär")))
                       '(nil)))
        (should (equal (quarry-test-grep--bytes dir "latin.txt") "caf\xe9\nb\xe4r\n"))))))

(ert-deftest quarry-test-grep-replace-apply-round-trip ()
  "A file whose decoded text does not encode back to its bytes is not written."
  (quarry-test-grep--with-tree (dir '(("dos.txt" . "")))
    ;; The cookie says CRLF; the lines end in LF.
    (let ((bytes "-*- coding: utf-8-dos -*-\nfoo\nx\n"))
      (quarry-test-grep--write-bytes dir "dos.txt" bytes)
      (should (equal (quarry-grep--replace-in-file (expand-file-name "dos.txt" dir)
                                                   '((nil 2 "foo" "bar")))
                     '("the file does not read back as it is (encoding or line ends)")))
      (should (equal (quarry-test-grep--bytes dir "dos.txt") bytes)))))

(ert-deftest quarry-test-grep-replace-apply-utf-16 ()
  "A UTF-16 file is not taken for UTF-8 mixed with other bytes."
  (quarry-test-grep--with-tree (dir '(("u16.txt" . "")))
    ;; U+80C2 is the bytes c2 80, a UTF-8 sequence.
    (quarry-test-grep--write-bytes dir "u16.txt" "\xff\xfe\x66\0o\0o\0\n\0\xc2\x80\n\0")
    (should (equal (quarry-grep--replace-in-file (expand-file-name "u16.txt" dir)
                                                 '((nil 1 "foo" "bär")))
                   '(nil)))
    (should (equal (quarry-test-grep--bytes dir "u16.txt")
                   "\xff\xfe\x62\0\xe4\0r\0\n\0\xc2\x80\n\0"))))

(ert-deftest quarry-test-grep-replace-apply-no-file-name-handlers ()
  "A file whose name a handler claims is written as its bytes."
  (skip-unless auto-compression-mode)
  (quarry-test-grep--with-tree (dir '(("notes.gz" . "") ("plain.gz" . "")))
    (let ((file-name-handler-alist nil))
      (quarry-test-grep--write-bytes dir "notes.gz" "foo\nx\n")
      (quarry-test-grep--write-bytes dir "plain.gz" "foo\nx\n"))
    ;; Written in place, and through a new file.
    (add-name-to-file (expand-file-name "notes.gz" dir) (expand-file-name "link.gz" dir))
    (dolist (name '("notes.gz" "plain.gz"))
      (should (equal (quarry-grep--replace-in-file (expand-file-name name dir)
                                                   '((nil 1 "foo" "bar")))
                     '(nil)))
      (should (equal (list name (quarry-test-grep--bytes dir name))
                     (list name "bar\nx\n"))))))

(ert-deftest quarry-test-grep-replace-apply-fsync ()
  "Writing follows `write-region-inhibit-fsync', as Emacs's own saves do."
  (quarry-test-grep--with-tree (dir '(("a.txt" . "foo\n") ("h.txt" . "foo\n")))
    (add-name-to-file (expand-file-name "h.txt" dir) (expand-file-name "h2.txt" dir))
    (let ((seen nil))
      (cl-letf* ((write (symbol-function 'write-region))
                 ((symbol-function 'write-region)
                  (lambda (&rest args)
                    (push write-region-inhibit-fsync seen)
                    (apply write args))))
        (pcase-dolist (`(,name . ,inhibit) '(("a.txt" . t) ("h.txt" . nil)))
          (let ((write-region-inhibit-fsync inhibit))
            (should (equal (quarry-grep--replace-in-file (expand-file-name name dir)
                                                         '((nil 1 "foo" "bar")))
                           '(nil))))))
      (should (equal seen '(nil t)))
      (should (equal (quarry-test-grep--bytes dir "h2.txt") "bar\n")))))

(ert-deftest quarry-test-grep-replace-apply-lock ()
  "A file locked by another Emacs is asked about once, with C-g possible."
  (quarry-test-grep--with-tree (dir '(("u.txt" . "foo\n") ("h.txt" . "foo\n")))
    (add-name-to-file (expand-file-name "h.txt" dir) (expand-file-name "h2.txt" dir))
    (let* ((create-lockfiles t)
           (lock (lambda (name) (expand-file-name (concat ".#" name) dir)))
           (foreign (lambda (name)
                      (make-symbolic-link "someone@otherhost.99999:0" (funcall lock name) t)))
           (replace (lambda (name)
                      (let ((inhibit-quit t))
                        (quarry-grep--replace-in-file (expand-file-name name dir)
                                                      '((nil 1 "foo" "bar"))))))
           (answer nil)
           (asked nil))
      ;; `file-locked' is defined in userlock.el, which the autoloaded
      ;; `ask-user-about-lock' loads; the stub below replaces it.  Not
      ;; defined, the signal escapes `error' handlers on Emacs 30.
      (load "userlock" nil t)
      (cl-letf (((symbol-function 'ask-user-about-lock)
                 (lambda (file _user)
                   (push (list (file-name-nondirectory file) inhibit-quit) asked)
                   (pcase answer
                     ('steal t)
                     ('quit (signal 'quit nil))
                     (_ (signal 'file-locked (list file "someone")))))))
        ;; Through a new file and in place.
        (dolist (name '("u.txt" "h.txt"))
          (funcall foreign name)
          ;; No: the file stays as it was.
          (setq answer nil asked nil)
          (let ((result (funcall replace name)))
            (should (= (length result) 1))
            (should (equal (car result) "File is locked by someone")))
          (should (equal asked `((,name nil))))
          (should (equal (quarry-test-grep--bytes dir name) "foo\n"))
          ;; C-g: the file stays as it was and `quit' goes on.
          (setq answer 'quit asked nil)
          (should (eq (condition-case nil (progn (funcall replace name) 'done) (quit 'quit))
                      'quit))
          (should (equal asked `((,name nil))))
          (should (equal (quarry-test-grep--bytes dir name) "foo\n"))
          (should (equal (file-symlink-p (funcall lock name)) "someone@otherhost.99999:0"))
          ;; Steal it: asked once, written, and the lock is gone afterwards.
          (setq answer 'steal asked nil)
          (should (equal (funcall replace name) '(nil)))
          (should (equal asked `((,name nil))))
          (should (equal (quarry-test-grep--bytes dir name) "bar\n"))
          (should-not (file-symlink-p (funcall lock name))))
        ;; Nothing else is left: no new file, no lock of one.
        (should (equal (directory-files dir nil "\\`\\.[^.]") nil))))))

(ert-deftest quarry-test-grep-replace-apply-file-kinds ()
  "The new file keeps the modes; links stay links; a failed rename keeps the file."
  (let* ((dir (make-temp-file "quarry-test-write" t))
         (file (lambda (name) (expand-file-name name dir)))
         (bytes (lambda (name)
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally (funcall file name))
                    (buffer-string))))
         (replace (lambda (name)
                    (quarry-grep--replace-in-file (funcall file name)
                                                  '((nil 1 "foo_1" "bar_1"))))))
    (unwind-protect
        (progn
          (dolist (name '("modes.txt" "target.txt" "hard.txt" "kept.txt"))
            (write-region "foo_1\n" nil (funcall file name) nil 'silent))
          ;; Modes.
          (set-file-modes (funcall file "modes.txt") #o640)
          (should (equal (funcall replace "modes.txt") '(nil)))
          (should (equal (funcall bytes "modes.txt") "bar_1\n"))
          (should (= (file-modes (funcall file "modes.txt")) #o640))
          ;; A symbolic link: the file it points to changes.
          (make-symbolic-link "target.txt" (funcall file "link.txt"))
          (should (equal (funcall replace "link.txt") '(nil)))
          (should (equal (file-symlink-p (funcall file "link.txt")) "target.txt"))
          (should (equal (funcall bytes "target.txt") "bar_1\n"))
          ;; A hard link: both names see the change.
          (add-name-to-file (funcall file "hard.txt") (funcall file "hard2.txt"))
          (should (equal (funcall replace "hard.txt") '(nil)))
          (should (equal (funcall bytes "hard2.txt") "bar_1\n"))
          (should (= (file-nlinks (funcall file "hard.txt")) 2))
          ;; The new file cannot take the place of the old one.
          (cl-letf (((symbol-function 'rename-file)
                     (lambda (&rest _) (signal 'file-error '("Renaming" "No space left on device")))))
            (should (equal (funcall replace "kept.txt") '("Renaming: No space left on device"))))
          (should (equal (funcall bytes "kept.txt") "foo_1\n"))
          ;; No new file is left.
          (should (equal (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]")
                         '("hard.txt" "hard2.txt" "kept.txt" "link.txt" "modes.txt" "target.txt"))))
      (delete-directory dir t))))

(ert-deftest quarry-test-grep-replace-apply-search-directory ()
  "The files are those of the search directory, wherever the buffer is."
  (quarry-test-grep--with-replace (dir quarry-test-grep--apply-files "foo_([0-9])" "bar_$1")
    (let ((other (file-name-as-directory (make-temp-file "quarry-test-other" t))))
      (unwind-protect
          (progn
            (write-region "x foo_5\n" nil (expand-file-name "b.txt" other) nil 'silent)
            (setq default-directory other)
            (should (equal (quarry-test-grep--apply t)
                           '("Replace 9 matches on 6 lines in 4 files? ")))
            (should (equal (quarry-test-grep--bytes dir "b.txt") "x bar_5\n"))
            (should (equal (quarry-test-grep--bytes other "b.txt") "x foo_5\n"))
            (should (string-match-p "\nReplaced 6 lines in 4 files; 0 rejected\\'"
                                    (quarry-test-grep--status))))
        (delete-directory other t)))))

(provide 'quarry-grep-tests)
;;; quarry-grep-tests.el ends here
