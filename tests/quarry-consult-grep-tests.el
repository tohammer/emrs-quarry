;;; quarry-consult-grep-tests.el --- ERT suite for quarry-consult-grep  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh.  The tests of the parser, the quote helper
;; and the step need neither consult nor the module: the step runs on a
;; recording sink, with stand-ins for `emrs-call-stream' and
;; `emrs-cancel'.  The tests of the commands' directory logic run with
;; the prompt replaced.  The test through `consult--grep-position' and
;; the tests that open the prompt (end to end and the hand-over to the
;; result buffer, with the real module) are skipped when consult is not
;; on `load-path' (see QUARRY_TEST_LOAD_PATH in run-ert.sh).

;;; Code:

(require 'ert)
(require 'ert-x)
(require 'emrs)
(require 'consult nil t)
(require 'quarry-consult-grep)

(declare-function consult--grep-position "consult" (cand &optional find-file))

(defvar consult-async-split-style)
(defvar consult-async-split-styles-alist)
(defvar consult-async-min-input)
(defvar consult-async-refresh-delay)
(defvar quarry-include-hidden)
(defvar quarry-ignores)

(defconst quarry-test-consult-grep--styles
  '((perl :initial "#") (perl-char :initial ?#) (comma :separator ?,) (none))
  "Split styles like consult's, for the quote tests.
The initial character is a string in older versions of consult and a
character in consult 3.")

(defun quarry-test-consult-grep--parse (input)
  "Parse INPUT in the directory \"/d/\"."
  (quarry-consult-grep--parse "/d/" input))

(defun quarry-test-consult-grep--filters (input)
  "Return the filters of INPUT as a list of (EXCLUDE PATTERN REGEXP)."
  (mapcar (lambda (f)
            (list (quarry-grep--filter-exclude f)
                  (quarry-grep--filter-pattern f)
                  (quarry-grep--filter-regexp f)))
          (quarry-grep--search-filters (quarry-test-consult-grep--parse input))))

(defun quarry-test-consult-grep--quoted (style string)
  "Return the filters of STRING quoted under split STYLE, parsed again."
  (let ((consult-async-split-style style)
        (consult-async-split-styles-alist quarry-test-consult-grep--styles))
    (let ((input (quarry-consult-grep-quote string)))
      (cons input (quarry-test-consult-grep--parse input)))))

;;;; Terms

(ert-deftest quarry-test-consult-grep-defaults ()
  (let* ((quarry-grep-case 'sensitive)
         (quarry-include-hidden nil)
         (s (quarry-test-consult-grep--parse "foo")))
    (should (equal (quarry-grep--search-dir s) "/d/"))
    (should-not (quarry-grep--search-types s))
    (should-not (quarry-grep--search-globs s))
    (should (eq (quarry-grep--search-case s) 'sensitive))
    (should-not (quarry-grep--search-no-ignore s))
    (should (eq (quarry-grep--search-hidden s) nil))
    (should (= 0 (quarry-grep--search-before s)))
    (should (= 0 (quarry-grep--search-after s)))
    (should (equal (quarry-test-consult-grep--filters "foo")
                   '((nil "foo" t)))))
  (let ((quarry-grep-case 'insensitive)
        (quarry-include-hidden t))
    (let ((s (quarry-test-consult-grep--parse "foo")))
      (should (eq (quarry-grep--search-case s) 'insensitive))
      (should (eq (quarry-grep--search-hidden s) t)))))

(ert-deftest quarry-test-consult-grep-hidden-default-is-boolean ()
  (let ((quarry-include-hidden 'yes))
    (should (eq (quarry-grep--search-hidden
                 (quarry-test-consult-grep--parse "a"))
                t))))

(ert-deftest quarry-test-consult-grep-terms-order ()
  (should (equal (quarry-test-consult-grep--filters "a !b c !d")
                 '((nil "a" t) (t "b" t) (nil "c" t) (t "d" t))))
  (should (equal (quarry-test-consult-grep--filters "!x a")
                 '((t "x" t) (nil "a" t))))
  (should (equal (quarry-test-consult-grep--filters "  a   b ")
                 '((nil "a" t) (nil "b" t)))))

(ert-deftest quarry-test-consult-grep-escapes ()
  (should (equal (quarry-test-consult-grep--filters "a\\ b c")
                 '((nil "a b" t) (nil "c" t))))
  (should (equal (quarry-test-consult-grep--filters "a\\\\ b")
                 '((nil "a\\\\" t) (nil "b" t))))
  (should (equal (quarry-test-consult-grep--filters "a\\.b")
                 '((nil "a\\.b" t))))
  ;; A backslash that ends the input unpaired is being typed.
  (should (equal (quarry-test-consult-grep--filters "a\\")
                 '((nil "a" t))))
  (should (equal (quarry-test-consult-grep--filters "a b\\\\\\")
                 '((nil "a" t) (nil "b\\\\" t))))
  (should (equal (quarry-test-consult-grep--filters "a\\\\")
                 '((nil "a\\\\" t))))
  (should (equal (quarry-test-consult-grep--filters "a \\")
                 '((nil "a" t))))
  (should-not (quarry-test-consult-grep--parse "\\"))
  (should (equal (quarry-test-consult-grep--filters "\\!x")
                 '((nil "!x" t))))
  (should (equal (quarry-test-consult-grep--filters "a !\\ b")
                 '((nil "a" t) (t " b" t))))
  (should (equal (quarry-test-consult-grep--filters "a\tb")
                 '((nil "a" t) (nil "b" t)))))

(ert-deftest quarry-test-consult-grep-lone-bang ()
  (should (equal (quarry-test-consult-grep--filters "a !")
                 '((nil "a" t))))
  (should-not (quarry-test-consult-grep--parse "!")))

(ert-deftest quarry-test-consult-grep-nothing-to-search ()
  (should-not (quarry-test-consult-grep--parse ""))
  (should-not (quarry-test-consult-grep--parse "   "))
  (should-not (quarry-test-consult-grep--parse "!a"))
  (should-not (quarry-test-consult-grep--parse "!a -- -F"))
  (should-not (quarry-test-consult-grep--parse "-- -F"))
  (should-not (quarry-test-consult-grep--parse "--"))
  (should-not (quarry-test-consult-grep--parse " -- -t")))

;;;; The cut

(ert-deftest quarry-test-consult-grep-cut ()
  (let ((s (quarry-test-consult-grep--parse "foo -- -F")))
    (should (equal (quarry-test-consult-grep--filters "foo -- -F")
                   '((nil "foo" nil))))
    (should (equal (quarry-grep--search-dir s) "/d/")))
  (should (equal (quarry-test-consult-grep--filters "foo   --   -F")
                 '((nil "foo" nil))))
  (should (equal (quarry-test-consult-grep--filters "foo --")
                 '((nil "foo" t))))
  (should (equal (quarry-test-consult-grep--filters "foo -- ")
                 '((nil "foo" t))))
  (should (equal (quarry-test-consult-grep--filters "foo--bar")
                 '((nil "foo--bar" t))))
  (should (equal (quarry-test-consult-grep--filters "foo --bar")
                 '((nil "foo" t) (nil "--bar" t)))))

(ert-deftest quarry-test-consult-grep-cut-at-first ()
  ;; Cut at the first; a later `--' is an unknown option.
  (let ((err (should-error (quarry-test-consult-grep--parse "a -- -F -- b")
                           :type 'user-error)))
    (should (equal (cadr err) "Unknown option --; see the README for the options")))
  (should (equal (quarry-test-consult-grep--filters "a\\ -- b")
                 '((nil "a --" t) (nil "b" t)))))

;;;; Options

(defun quarry-test-consult-grep--opt (opts)
  "Parse \"a -- OPTS\"."
  (quarry-test-consult-grep--parse (concat "a -- " opts)))

(ert-deftest quarry-test-consult-grep-option-type ()
  (dolist (opts '("-t rust" "--type rust" "-trust" "--type=rust"))
    (should (equal (quarry-grep--search-types (quarry-test-consult-grep--opt opts))
                   '("rust"))))
  (should-not (quarry-grep--search-types (quarry-test-consult-grep--opt "-F")))
  ;; Any number of types, in order, each once.
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t rust --type=c -ttxt"))
                 '("rust" "c" "txt")))
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t rust -t c -t rust"))
                 ;; A repeated type is kept at its last place (ADR 0024).
                 '("c" "rust"))))

(ert-deftest quarry-test-consult-grep-option-type-not ()
  (dolist (opts '("-T json" "-Tjson" "--type-not=json" "--type-not json"))
    (should (equal (quarry-grep--search-types (quarry-test-consult-grep--opt opts))
                   '("!json"))))
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t cpp -T c"))
                 '("cpp" "!c")))
  ;; The last copy of an entry wins.
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t c -T c -t c"))
                 '("!c" "c")))
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-T c -T c"))
                 '("!c")))
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t rust -t rust"))
                 '("rust")))
  ;; No special case: the service rejects it.
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-T !json"))
                 '("!!json")))
  ;; Being typed is no error.
  (dolist (opts '("-T" "--type-not" "--type-not=" "-T="))
    (should-not (quarry-grep--search-types (quarry-test-consult-grep--opt opts)))))

(ert-deftest quarry-test-consult-grep-option-glob ()
  (dolist (opts '("-g *.el" "--glob *.el" "-g*.el" "--glob=*.el"))
    (should (equal (quarry-grep--search-globs (quarry-test-consult-grep--opt opts))
                   '("*.el"))))
  (should (equal (quarry-grep--search-globs
                  (quarry-test-consult-grep--opt "-g *.el --glob=!x/** -g b -g*.c"))
                 '("*.el" "!x/**" "b" "*.c"))))

(ert-deftest quarry-test-consult-grep-option-fixed ()
  (dolist (opts '("-F" "--fixed-strings"))
    (should (equal (mapcar #'quarry-grep--filter-regexp
                           (quarry-grep--search-filters
                            (quarry-test-consult-grep--parse
                             (concat "a !b c -- " opts))))
                   '(nil nil nil))))
  (should (equal (quarry-test-consult-grep--filters "\\!a -- -F")
                 '((nil "!a" nil)))))

(ert-deftest quarry-test-consult-grep-option-case ()
  (dolist (row '(("-i" . insensitive) ("--ignore-case" . insensitive)
                 ("-s" . sensitive) ("--case-sensitive" . sensitive)
                 ("-S" . smart) ("--smart-case" . smart)))
    (let ((quarry-grep-case (if (eq (cdr row) 'smart) 'sensitive 'smart)))
      (should (eq (quarry-grep--search-case (quarry-test-consult-grep--opt (car row)))
                  (cdr row)))))
  (should (eq (quarry-grep--search-case (quarry-test-consult-grep--opt "-i -s -S -i"))
              'insensitive))
  (should (eq (quarry-grep--search-case (quarry-test-consult-grep--opt "-i -s"))
              'sensitive)))

(ert-deftest quarry-test-consult-grep-option-ignore-and-hidden ()
  (let ((quarry-include-hidden nil))
    (dolist (opts '("-u" "--no-ignore"))
      (let ((s (quarry-test-consult-grep--opt opts)))
        (should (eq (quarry-grep--search-no-ignore s) t))
        (should-not (quarry-grep--search-hidden s))))
    (dolist (opts '("-uu" "-." "--hidden"))
      (should (eq (quarry-grep--search-hidden (quarry-test-consult-grep--opt opts))
                  t)))
    (should (eq (quarry-grep--search-no-ignore (quarry-test-consult-grep--opt "-uu"))
                t))
    (should-not (quarry-grep--search-no-ignore
                 (quarry-test-consult-grep--opt "-.")))
    (should-not (quarry-grep--search-hidden
                 (quarry-test-consult-grep--opt "--hidden --no-hidden"))))
  (let ((quarry-include-hidden t))
    (should-not (quarry-grep--search-hidden
                 (quarry-test-consult-grep--opt "--no-hidden")))
    (should (eq (quarry-grep--search-hidden
                 (quarry-test-consult-grep--opt "--no-hidden -."))
                t))))

(ert-deftest quarry-test-consult-grep-option-combined ()
  (let ((s (quarry-test-consult-grep--parse "a b -- -trust -g*.rs -F -uu -i")))
    (should (equal (quarry-grep--search-types s) '("rust")))
    (should (equal (quarry-grep--search-globs s) '("*.rs")))
    (should (eq (quarry-grep--search-case s) 'insensitive))
    (should (eq (quarry-grep--search-no-ignore s) t))
    (should (eq (quarry-grep--search-hidden s) t))))

;;;; Incomplete input and errors

(ert-deftest quarry-test-consult-grep-incomplete ()
  (dolist (opts '("-t" "--type" "-g" "--glob" "-F -t" "-t rust -g" "-t=" "--type="))
    (should (quarry-test-consult-grep--opt opts)))
  ;; The last word may be the start of an option.
  (dolist (opts '("-" "--" "--h" "--hidde" "--no-" "-F --fix" "--typ"))
    (should (quarry-test-consult-grep--opt opts)))
  (should-not (quarry-grep--search-hidden
               (let ((quarry-include-hidden nil))
                 (quarry-test-consult-grep--opt "--hidde"))))
  ;; Only the last word, and only a start of an option.
  (should-error (quarry-test-consult-grep--opt "--h -F") :type 'user-error)
  (should-error (quarry-test-consult-grep--opt "--hx") :type 'user-error)
  ;; `-t=rust' is `-trust'.
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t=rust"))
                 '("rust")))
  (should (equal (quarry-grep--search-globs
                  (quarry-test-consult-grep--opt "-g=*.el"))
                 '("*.el")))
  (should-not (quarry-grep--search-types (quarry-test-consult-grep--opt "-t")))
  (should-not (quarry-grep--search-globs (quarry-test-consult-grep--opt "-g")))
  (should (equal (quarry-grep--search-types
                  (quarry-test-consult-grep--opt "-t rust -g"))
                 '("rust"))))

(defun quarry-test-consult-grep--error (input)
  "Return the message of the `user-error' that INPUT signals."
  (cadr (should-error (quarry-test-consult-grep--parse input)
                      :type 'user-error)))

(ert-deftest quarry-test-consult-grep-errors ()
  (should (equal (quarry-test-consult-grep--error "a -- -x")
                 "Unknown option -x; see the README for the options"))
  (should (equal (quarry-test-consult-grep--error "a -- --wat")
                 "Unknown option --wat; see the README for the options"))
  (should (equal (quarry-test-consult-grep--error "a -- -Fi")
                 "Unknown option -Fi; see the README for the options"))
  (should (equal (quarry-test-consult-grep--error "a -- -uuu")
                 "Unknown option -uuu; see the README for the options"))
  (should (equal (quarry-test-consult-grep--error "a -- -w")
                 "Unknown option -w; see the README for the options"))
  (should (equal (quarry-test-consult-grep--error "a -- -F word")
                 "Not an option: word"))
  (should (equal (quarry-test-consult-grep--error "a -- -t rust c")
                 "Not an option: c")))

;;;; The quote helper

(defun quarry-test-consult-grep--check-quote (style string pattern)
  "Check that STRING quoted under STYLE parses to the one regexp PATTERN."
  (let* ((res (quarry-test-consult-grep--quoted style string))
         (s (cdr res)))
    (should s)
    (should (equal (mapcar (lambda (f)
                             (list (quarry-grep--filter-exclude f)
                                   (quarry-grep--filter-pattern f)
                                   (quarry-grep--filter-regexp f)))
                           (quarry-grep--search-filters s))
                   (list (list nil pattern t))))
    (should-not (quarry-grep--search-types s))
    (should-not (quarry-grep--search-globs s))
    (should-not (quarry-grep--search-no-ignore s))))

(ert-deftest quarry-test-consult-grep-quote-plain ()
  (should (equal (let ((consult-async-split-style 'none)
                       (consult-async-split-styles-alist
                        quarry-test-consult-grep--styles))
                   (quarry-consult-grep-quote "foo"))
                 "foo")))

(ert-deftest quarry-test-consult-grep-quote-spaces ()
  (should (equal (car (quarry-test-consult-grep--quoted 'none "a b  c"))
                 "a\\ b\\ \\ c"))
  (quarry-test-consult-grep--check-quote 'none "a b  c" "a b  c")
  (quarry-test-consult-grep--check-quote 'none "a\tb" "a\\tb"))

(ert-deftest quarry-test-consult-grep-quote-bang ()
  (should (equal (car (quarry-test-consult-grep--quoted 'none "!x"))
                 "\\!x"))
  (quarry-test-consult-grep--check-quote 'none "!x" "!x")
  (quarry-test-consult-grep--check-quote 'none "a!" "a!")
  (quarry-test-consult-grep--check-quote 'none "!" "!"))

(ert-deftest quarry-test-consult-grep-quote-specials ()
  (quarry-test-consult-grep--check-quote 'none "a.b*c" "a\\.b\\*c")
  (quarry-test-consult-grep--check-quote 'none "(x|y)[z]{1}^$+?" 
                                         "\\(x\\|y\\)\\[z\\]\\{1\\}\\^\\$\\+\\?")
  (quarry-test-consult-grep--check-quote 'none "a\\ b" "a\\\\ b")
  (quarry-test-consult-grep--check-quote 'none "a-b&c~d#e" "a\\-b\\&c\\~d\\#e"))

(ert-deftest quarry-test-consult-grep-quote-perl ()
  (should (equal (car (quarry-test-consult-grep--quoted 'perl "a#b"))
                 "a\\x23b"))
  (quarry-test-consult-grep--check-quote 'perl "a#b" "a\\x23b")
  (quarry-test-consult-grep--check-quote 'perl "x.y #" "x\\.y \\x23")
  (should (equal (car (quarry-test-consult-grep--quoted 'perl-char "a#b"))
                 "a\\x23b")))

(ert-deftest quarry-test-consult-grep-quote-consult-style ()
  "With consult's own styles the quoted string stays in the search part."
  (skip-unless (fboundp 'consult--split-perl))
  (dolist (style '(perl comma semicolon none))
    (let* ((consult-async-split-style style)
           (input (quarry-consult-grep-quote "a#b,c;d e"))
           (parts (quarry-consult-grep--split
                   (concat (and (eq style 'perl) "#") input))))
      (should (equal (car parts) input))
      (should (equal (cdr parts) "")))))

(ert-deftest quarry-test-consult-grep-quote-separator ()
  (should (equal (car (quarry-test-consult-grep--quoted 'comma "a,b"))
                 "a\\x2Cb"))
  (quarry-test-consult-grep--check-quote 'comma "a,b" "a\\x2Cb")
  ;; `#' is no separator under this style.
  (quarry-test-consult-grep--check-quote 'comma "a#b," "a\\#b\\x2C"))

(ert-deftest quarry-test-consult-grep-quote-no-style ()
  (let ((consult-async-split-style nil)
        (consult-async-split-styles-alist nil))
    (should (equal (quarry-consult-grep-quote "a#b,c") "a\\#b,c")))
  (quarry-test-consult-grep--check-quote 'none "a#b,c" "a\\#b,c"))

(ert-deftest quarry-test-consult-grep-quote-dashes-inside ()
  (let ((res (quarry-test-consult-grep--quoted 'none "a -- b")))
    (should (equal (car res) "a\\ \\-\\-\\ b")))
  (quarry-test-consult-grep--check-quote 'none "a -- b" "a \\-\\- b")
  (quarry-test-consult-grep--check-quote 'perl "x -- -F" "x \\-\\- \\-F"))

;;;; The candidates

(defconst quarry-test-consult-grep--item
  '(:file :path "src/walk.rs" :path-spans nil :mtime 1
          :lines ((:n 168 :text "#[inline]" :spans nil :secondary nil
                      :inexact nil :context t)
                  (:n 169 :text "pub fn walk(" :spans ((4 11))
                      :secondary ((0 3)) :inexact nil)
                  (:n 1200 :text "walk walk" :spans ((0 4) (5 9))
                       :secondary nil :inexact nil)))
  "A file item with a context line and two kept lines.")

(defun quarry-test-consult-grep--faces (string)
  "Return the stretches of STRING with a face, as (START END FACE)."
  (let ((pos 0) (out nil))
    (while (< pos (length string))
      (let ((next (next-single-property-change pos 'face string (length string)))
            (face (get-text-property pos 'face string)))
        (when face
          (push (list pos next face) out))
        (setq pos next)))
    (nreverse out)))

(ert-deftest quarry-test-consult-grep-candidates ()
  (let* ((quarry-grep-highlight-include-filters t)
         (cands (quarry-consult-grep--candidates quarry-test-consult-grep--item)))
    (should (equal cands '("src/walk.rs:169:pub fn walk("
                           "src/walk.rs:1200:walk walk")))
    (should (equal (quarry-test-consult-grep--faces (nth 0 cands))
                   '((0 11 consult-file)
                     (12 15 consult-line-number)
                     (16 19 (quarry-grep-match-secondary consult-grep-context))
                     (20 27 consult-highlight-match))))
    (should (equal (quarry-test-consult-grep--faces (nth 1 cands))
                   '((0 11 consult-file)
                     (12 16 consult-line-number)
                     (17 21 consult-highlight-match)
                     (22 26 consult-highlight-match))))
    ;; The group is on the path only, one string for the whole file.
    (let ((group (get-text-property 0 'consult--prefix-group (nth 0 cands))))
      (should (equal group "src/walk.rs"))
      (should (eq group (get-text-property 10 'consult--prefix-group (nth 0 cands))))
      (should (eq group (get-text-property 0 'consult--prefix-group (nth 1 cands))))
      (should-not (get-text-property 11 'consult--prefix-group (nth 0 cands))))
    (should-not (text-property-not-all 0 (length (nth 0 cands))
                                       'font-lock-face nil (nth 0 cands)))))

(ert-deftest quarry-test-consult-grep-candidates-no-secondary ()
  (let* ((quarry-grep-highlight-include-filters nil)
         (cands (quarry-consult-grep--candidates quarry-test-consult-grep--item)))
    (should (equal (quarry-test-consult-grep--faces (nth 0 cands))
                   '((0 11 consult-file)
                     (12 15 consult-line-number)
                     (20 27 consult-highlight-match))))))

(ert-deftest quarry-test-consult-grep-candidates-multibyte ()
  "Spans are character offsets, also after multibyte characters."
  (let* ((quarry-grep-highlight-include-filters t)
         (cands (quarry-consult-grep--candidates
                 '(:file :path "süb/dé.txt"
                         :lines ((:n 7 :text "über näedle ünd" :spans ((5 11))
                                     :secondary ((12 15))))))))
    (should (equal cands '("süb/dé.txt:7:über näedle ünd")))
    (should (equal (quarry-test-consult-grep--faces (car cands))
                   '((0 10 consult-file)
                     (11 12 consult-line-number)
                     (18 24 consult-highlight-match)
                     (25 28 (quarry-grep-match-secondary consult-grep-context)))))
    (should (equal (substring-no-properties (car cands) 18 24) "näedle"))))

(ert-deftest quarry-test-consult-grep-candidates-none ()
  (should-not (quarry-consult-grep--candidates
               '(:file :path "a" :lines ((:n 1 :text "x" :context t))))))

;;;; The note

(defun quarry-test-consult-grep--notes (buffer)
  "Return the notes shown in BUFFER as a list of (TEXT FACE START)."
  (with-current-buffer buffer
    (cl-loop for o in (overlays-in (point-min) (1+ (point-max)))
             for s = (overlay-get o 'after-string)
             when s collect (list (substring-no-properties s)
                                  (get-text-property 0 'face s)
                                  (overlay-start o)))))

(ert-deftest quarry-test-consult-grep-note-overlay ()
  (with-temp-buffer
    (insert "Grep: foo")
    (let ((o (quarry-consult-grep--show-note
              (current-buffer) "regex parse error:\n    a(\n     ^\nerror: unclosed group\n" 'error)))
      (should (overlayp o))
      ;; Of several lines the last one that is not empty.
      (should (equal (quarry-test-consult-grep--notes (current-buffer))
                     '((" [error: unclosed group]" error 10))))
      (let ((s (overlay-get o 'after-string)))
        (should (eql (get-text-property 0 'cursor s) 1))
        (should-not (get-text-property 1 'cursor s))
        (should (eq (get-text-property (1- (length s)) 'face s) 'error)))
      (should (eql (overlay-get o 'priority) 1100))
      ;; Typing at the end keeps the note after the input.
      (goto-char (point-max))
      (insert "bar")
      (should (= (overlay-start o) (point-max)))
      (quarry-consult-grep--remove-note o)
      (should-not (quarry-test-consult-grep--notes (current-buffer)))
      (quarry-consult-grep--remove-note nil))))

(ert-deftest quarry-test-consult-grep-note-no-buffer ()
  (should-not (quarry-consult-grep--show-note nil "x" 'error))
  (let ((buffer (generate-new-buffer " *quarry-test-note*")))
    (kill-buffer buffer)
    (should-not (quarry-consult-grep--show-note buffer "x" 'error))))

;;;; The step, with a recording sink and a recording stream

(defvar quarry-test-consult-grep--log nil
  "Actions the recording sink received, newest first.")

(defvar quarry-test-consult-grep--streams nil
  "What the fake stream got: (REQUEST ON-BATCH ON-END CALL), newest first.")

(defvar quarry-test-consult-grep--cancelled nil
  "The calls given to `emrs-cancel', newest first.")

(defmacro quarry-test-consult-grep--with-step (step &rest body)
  "Run BODY with STEP bound to the step for \"/d/\" on a recording sink.
`emrs-call-stream' records instead of sending and returns an open call;
`emrs-cancel' records the call and, as the real one, ends an open call
at once with `cancelled'.  No instance is started."
  (declare (indent 1))
  `(let ((quarry-test-consult-grep--log nil)
         (quarry-test-consult-grep--streams nil)
         (quarry-test-consult-grep--cancelled nil)
         (quarry-grep-case 'smart)
         (quarry-grep-max-lines 50000)
         (quarry-grep-max-columns 500)
         (quarry-consult-grep-max-lines 1000)
         (quarry-grep-highlight-include-filters t)
         (quarry-include-hidden t)
         (quarry-ignores nil))
     (cl-letf (((symbol-function 'quarry-grep--ensure-instance)
                (lambda () 'the-instance))
               ((symbol-function 'emrs-call-stream)
                (lambda (instance request &rest keys)
                  (should (eq instance 'the-instance))
                  (let ((call (emrs--make-call)))
                    (push (list request (plist-get keys :on-batch)
                                (plist-get keys :on-end) call)
                          quarry-test-consult-grep--streams)
                    call)))
               ((symbol-function 'emrs-cancel)
                (lambda (call)
                  (push call quarry-test-consult-grep--cancelled)
                  (unless (emrs-call-done call)
                    (setf (emrs-call-done call) t)
                    (funcall (nth 2 (cl-find call quarry-test-consult-grep--streams
                                             :key #'cadddr))
                             'cancelled nil)))))
       (let ((,step (funcall (quarry-consult-grep--async "/d/")
                             (lambda (action)
                               (push action quarry-test-consult-grep--log)
                               nil))))
         ,@body))))

(defun quarry-test-consult-grep--stream (n)
  "Return the Nth stream, counted from 0 in the order they were started."
  (nth n (reverse quarry-test-consult-grep--streams)))

(defun quarry-test-consult-grep--batch (n &rest items)
  "Send ITEMS as one batch of stream N."
  (funcall (nth 1 (quarry-test-consult-grep--stream n)) items))

(defun quarry-test-consult-grep--end (n status &optional err)
  "End stream N with STATUS and ERR, as the service would."
  (let ((stream (quarry-test-consult-grep--stream n)))
    (setf (emrs-call-done (nth 3 stream)) t)
    (funcall (nth 2 stream) status err)))

(defun quarry-test-consult-grep--taken ()
  "Return the sink's actions in order and forget them."
  (prog1 (reverse quarry-test-consult-grep--log)
    (setq quarry-test-consult-grep--log nil)))

(defun quarry-test-consult-grep--file (path &rest lines)
  "Return a file item for PATH; each of LINES is (N TEXT)."
  (list :file :path path
        :lines (mapcar (lambda (l) (list :n (car l) :text (cadr l))) lines)))

(ert-deftest quarry-test-consult-grep-step-flush-before-first-batch ()
  (quarry-test-consult-grep--with-step step
    (should (null (funcall step "foo")))
    (should (equal (quarry-test-consult-grep--taken) '([indicator running])))
    (quarry-test-consult-grep--batch
     0 (quarry-test-consult-grep--file "a" '(1 "foo") '(3 "a foo"))
     (quarry-test-consult-grep--file "b" '(2 "foo")))
    (should (equal (quarry-test-consult-grep--taken)
                   '(flush ("a:1:foo" "a:3:a foo" "b:2:foo"))))
    ;; A later batch is appended.
    (quarry-test-consult-grep--batch
     0 (quarry-test-consult-grep--file "c" '(9 "foo"))
     '(:summary :files-searched 3 :files-matched 3 :lines 4 :truncated nil))
    (should (equal (quarry-test-consult-grep--taken) '(("c:9:foo"))))
    (quarry-test-consult-grep--end 0 'done)
    (should (equal (quarry-test-consult-grep--taken) '([indicator finished])))
    ;; The next input keeps the candidates until its first batch.
    (funcall step "foo b")
    (should (equal (quarry-test-consult-grep--taken) '([indicator running])))
    (quarry-test-consult-grep--batch
     1 (quarry-test-consult-grep--file "b" '(2 "foo")))
    (should (equal (quarry-test-consult-grep--taken) '(flush ("b:2:foo"))))
    ;; The same input again sends nothing; other actions pass on.
    (funcall step "foo b")
    (funcall step 'refresh)
    (funcall step nil)
    (should (equal (quarry-test-consult-grep--taken) '(refresh nil)))
    (should (= (length quarry-test-consult-grep--streams) 2))))

(ert-deftest quarry-test-consult-grep-step-candidates ()
  "The step sends what `quarry-consult-grep--candidates' makes."
  (quarry-test-consult-grep--with-step step
    (funcall step "walk")
    (quarry-test-consult-grep--batch 0 quarry-test-consult-grep--item)
    (should (equal-including-properties
             (car quarry-test-consult-grep--log)
             (quarry-consult-grep--candidates quarry-test-consult-grep--item)))
    (should (get-text-property 0 'consult--prefix-group
                               (caar quarry-test-consult-grep--log)))))

(ert-deftest quarry-test-consult-grep-step-done-without-batch ()
  (quarry-test-consult-grep--with-step step
    (funcall step "foo")
    (quarry-test-consult-grep--end 0 'done)
    (should (equal (quarry-test-consult-grep--taken)
                   '([indicator running] flush [indicator finished])))
    ;; A batch with the summary alone is no batch of candidates.
    (funcall step "bar")
    (quarry-test-consult-grep--batch
     1 '(:summary :files-searched 3 :files-matched 0 :lines 0 :truncated nil))
    (should (equal (quarry-test-consult-grep--taken) '([indicator running])))
    (quarry-test-consult-grep--end 1 'done)
    (should (equal (quarry-test-consult-grep--taken)
                   '(flush [indicator finished])))))

(ert-deftest quarry-test-consult-grep-step-nothing-to-search ()
  (quarry-test-consult-grep--with-step step
    (with-temp-buffer
      (funcall step 'setup)
      (funcall step "foo")
      (quarry-test-consult-grep--taken)
      (dolist (input '("" "!x" "  "))
        (funcall step input)
        (should (equal (quarry-test-consult-grep--taken)
                       '(flush [indicator finished]))))
      (should (= (length quarry-test-consult-grep--streams) 1))
      ;; The search that ran was cancelled.
      (should (equal quarry-test-consult-grep--cancelled
                     (list (nth 3 (quarry-test-consult-grep--stream 0)))))
      (should-not (quarry-test-consult-grep--notes (current-buffer))))))

(ert-deftest quarry-test-consult-grep-step-supersede ()
  (quarry-test-consult-grep--with-step step
    (funcall step "foo")
    (funcall step "foob")
    (should (equal (quarry-test-consult-grep--taken)
                   '([indicator running] [indicator running])))
    (should (equal quarry-test-consult-grep--cancelled
                   (list (nth 3 (quarry-test-consult-grep--stream 0)))))
    ;; What the old search still delivers is dropped, also its end.
    (quarry-test-consult-grep--batch
     0 (quarry-test-consult-grep--file "a" '(1 "foo")))
    (quarry-test-consult-grep--end 0 'done)
    (quarry-test-consult-grep--end 0 'failed '(:kind service :message "late"))
    (should-not (quarry-test-consult-grep--taken))
    (quarry-test-consult-grep--batch
     1 (quarry-test-consult-grep--file "a" '(2 "foob")))
    (quarry-test-consult-grep--batch
     0 (quarry-test-consult-grep--file "a" '(1 "foo")))
    (quarry-test-consult-grep--end 1 'done)
    (should (equal (quarry-test-consult-grep--taken)
                   '(flush ("a:2:foob") [indicator finished])))
    ;; A finished call is not cancelled again by the next input.
    (funcall step "x")
    (should (= (length quarry-test-consult-grep--cancelled) 1))))

(ert-deftest quarry-test-consult-grep-step-request ()
  (quarry-test-consult-grep--with-step step
    (let ((quarry-consult-grep-max-lines 77))
      (funcall step "foo !bar -- -t rust -t elisp -g *.rs -g !x -i -u"))
    (let ((request (car (quarry-test-consult-grep--stream 0))))
      (should (eq (car request) :search))
      (let ((fields (cdr request)))
        (should (equal (plist-get fields :dir) "/d/"))
        (should (eql (plist-get fields :max-lines) 77))
        (should (equal (plist-get fields :filters)
                       '((:target :line :exclude nil :pattern "foo" :regexp t)
                         (:target :line :exclude t :pattern "bar" :regexp t))))
        (should (equal (plist-get fields :file-types) '("rust" "elisp")))
        (should (equal (plist-get fields :globs) '("*.rs" "!x")))
        (should (eq (plist-get fields :case) :insensitive))
        (should (eq (plist-get fields :no-ignore) t))
        (should (eql (plist-get fields :before) 0))
        (should (eql (plist-get fields :after) 0))))
    ;; The option of the result buffer is untouched and not used.
    (should (= quarry-grep-max-lines 50000))
    (funcall step "foo")
    (should (eql (plist-get (cdr (car (quarry-test-consult-grep--stream 1)))
                            :max-lines)
                 1000))))

(ert-deftest quarry-test-consult-grep-step-failed ()
  (quarry-test-consult-grep--with-step step
    (with-temp-buffer
      (insert "Grep: a(")
      (let ((buffer (current-buffer)))
        (funcall step 'setup)
        (should (equal (quarry-test-consult-grep--taken) '(setup)))
        (funcall step "a(")
        (quarry-test-consult-grep--taken)
        ;; The callbacks come with any buffer current.
        (with-temp-buffer
          (quarry-test-consult-grep--end
           0 'failed '(:kind service
                             :message "invalid filter `a(`: regex parse error:\n    a(\n     ^\nerror: unclosed group")))
        (should (equal (quarry-test-consult-grep--taken)
                       '(flush [indicator failed])))
        (should (equal (quarry-test-consult-grep--notes buffer)
                       '((" [error: unclosed group]" error 9))))
        ;; The next input removes the note.
        (funcall step "a")
        (should-not (quarry-test-consult-grep--notes buffer))
        ;; A failure replaces nothing but itself; destroy removes it.
        (quarry-test-consult-grep--end 1 'failed '(:kind service :message "one"))
        (should (equal (mapcar #'car (quarry-test-consult-grep--notes buffer))
                       '(" [one]")))
        (funcall step 'destroy)
        (should-not (quarry-test-consult-grep--notes buffer))))))

(ert-deftest quarry-test-consult-grep-step-parse-error ()
  (quarry-test-consult-grep--with-step step
    (with-temp-buffer
      (funcall step 'setup)
      (quarry-test-consult-grep--taken)
      (funcall step "a -- -x")
      (should-not quarry-test-consult-grep--streams)
      (should (equal (quarry-test-consult-grep--taken)
                     '(flush [indicator failed])))
      (should (equal (quarry-test-consult-grep--notes (current-buffer))
                     '((" [Unknown option -x; see the README for the options]"
                        error 1))))
      (funcall step "a -- -F")
      (should-not (quarry-test-consult-grep--notes (current-buffer)))
      (should (= (length quarry-test-consult-grep--streams) 1)))))

(ert-deftest quarry-test-consult-grep-step-start-errors ()
  "An instance that cannot be used is shown like a failed search."
  (quarry-test-consult-grep--with-step step
    (with-temp-buffer
      (funcall step 'setup)
      (quarry-test-consult-grep--taken)
      (cl-letf (((symbol-function 'quarry-grep--ensure-instance)
                 (lambda () (user-error "No module"))))
        (funcall step "a"))
      (should (equal (quarry-test-consult-grep--taken)
                     '(flush [indicator failed])))
      (should (equal (mapcar #'car (quarry-test-consult-grep--notes (current-buffer)))
                     '(" [No module]")))
      (cl-letf (((symbol-function 'emrs-call-stream)
                 (lambda (&rest _)
                   (signal 'emrs-error '(stopped "The instance stopped" nil)))))
        (funcall step "b"))
      (should (equal (quarry-test-consult-grep--taken)
                     '(flush [indicator failed])))
      (should (equal (mapcar #'car (quarry-test-consult-grep--notes (current-buffer)))
                     '(" [The instance stopped]"))))))

(ert-deftest quarry-test-consult-grep-step-truncated ()
  (quarry-test-consult-grep--with-step step
    (with-temp-buffer
      (insert "Grep: foo")
      (funcall step 'setup)
      (funcall step "foo")
      (quarry-test-consult-grep--batch
       0 (quarry-test-consult-grep--file "a" '(1 "foo"))
       '(:summary :files-searched 9 :files-matched 1 :lines 1000 :truncated t))
      ;; Not before the end.
      (should-not (quarry-test-consult-grep--notes (current-buffer)))
      (quarry-test-consult-grep--end 0 'done)
      (should (equal (quarry-test-consult-grep--notes (current-buffer))
                     '((" [first 1000 hits]" shadow 10))))
      ;; A search that was not cut shows none.
      (funcall step "fo")
      (should-not (quarry-test-consult-grep--notes (current-buffer)))
      (quarry-test-consult-grep--batch
       1 '(:summary :files-searched 9 :files-matched 0 :lines 0 :truncated nil))
      (quarry-test-consult-grep--end 1 'done)
      (should-not (quarry-test-consult-grep--notes (current-buffer))))))

(ert-deftest quarry-test-consult-grep-step-no-minibuffer ()
  "Without a captured buffer, or with a dead one, a note is not shown."
  (quarry-test-consult-grep--with-step step
    (funcall step "a -- -x")
    (should (equal (quarry-test-consult-grep--taken)
                   '(flush [indicator failed])))
    (let ((buffer (generate-new-buffer " *quarry-test-step*")))
      (with-current-buffer buffer (funcall step 'setup))
      (kill-buffer buffer)
      (funcall step "a -- -y")
      (should (equal (quarry-test-consult-grep--taken)
                     '(setup flush [indicator failed]))))))

(ert-deftest quarry-test-consult-grep-step-cancel-destroy ()
  (dolist (action '(cancel destroy))
    (quarry-test-consult-grep--with-step step
      (with-temp-buffer
        (funcall step 'setup)
        (funcall step "a -- -x")
        (should (quarry-test-consult-grep--notes (current-buffer)))
        (funcall step "foo")
        (quarry-test-consult-grep--taken)
        (funcall step action)
        ;; `cancel' ends the indicator of the search it cancelled.
        (should (equal (quarry-test-consult-grep--taken)
                       (if (eq action 'cancel)
                           '([indicator killed] cancel)
                         '(destroy))))
        (should (equal quarry-test-consult-grep--cancelled
                       (list (nth 3 (quarry-test-consult-grep--stream 0)))))
        ;; What the cancelled search still delivers is dropped.
        (quarry-test-consult-grep--batch
         0 (quarry-test-consult-grep--file "a" '(1 "foo")))
        (should-not (quarry-test-consult-grep--taken))
        ;; The same input searches again.  `destroy' dropped the buffer.
        (funcall step "foo")
        (should (= (length quarry-test-consult-grep--streams) 2))
        (should (equal (quarry-test-consult-grep--taken) '([indicator running])))
        (when (eq action 'destroy)
          (quarry-test-consult-grep--end 1 'failed '(:kind service :message "no"))
          (should-not (quarry-test-consult-grep--notes (current-buffer)))
          (funcall step 'setup)
          (funcall step "foo2"))
        ;; The note goes with the action.
        (quarry-test-consult-grep--end
         (1- (length quarry-test-consult-grep--streams))
         'failed '(:kind service :message "no"))
        (should (quarry-test-consult-grep--notes (current-buffer)))
        (funcall step action)
        (should-not (quarry-test-consult-grep--notes (current-buffer)))))))

;;;; With consult

(ert-deftest quarry-test-consult-grep-position ()
  "consult reads file, line and column from a candidate."
  (skip-unless (fboundp 'consult--grep-position))
  (let* ((dir (file-name-as-directory (make-temp-file "quarry-cg" t)))
         (default-directory dir)
         (quarry-grep-highlight-include-filters t)
         (opened nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src" dir))
          (write-region "one\npub fn walk(\n  über walk\n" nil
                        (expand-file-name "src/walk.rs" dir) nil 'silent)
          (let ((cands (quarry-consult-grep--candidates
                        '(:file :path "src/walk.rs"
                                :lines ((:n 2 :text "pub fn walk(" :spans ((7 11))
                                            :secondary ((0 3)))
                                        (:n 3 :text "  über walk" :spans ((7 11))
                                            :secondary nil))))))
            (pcase-dolist (`(,cand ,line ,column ,matches)
                           (list (list (nth 0 cands) 2 7 '((0 . 4)))
                                 (list (nth 1 cands) 3 7 '((0 . 4)))))
              (let* ((pos (consult--grep-position cand #'find-file-noselect))
                     (marker (car pos)))
                (should (markerp marker))
                (cl-pushnew (marker-buffer marker) opened)
                (should (equal (buffer-file-name (marker-buffer marker))
                               (expand-file-name "src/walk.rs" dir)))
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (should (= (line-number-at-pos) line))
                    (should (= (current-column) column))
                    (should (looking-at-p "walk"))))
                ;; The secondary match is none of consult's matches.
                (should (equal (cdr pos) matches))))))
      (dolist (buffer opened)
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (delete-directory dir t))))

;;;; The split of the input

(ert-deftest quarry-test-consult-grep-split-no-function ()
  "Without a split function the whole input is the search part."
  (let ((consult-async-split-styles-alist
         `((bare) (fake :function ,(lambda (str _style)
                                     (list (propertize (substring str 1 3) 'x t)
                                           4))))))
    (let ((consult-async-split-style 'bare))
      (should (equal (quarry-consult-grep--split "#a#b") '("#a#b" . ""))))
    (let ((consult-async-split-style 'missing))
      (should (equal (quarry-consult-grep--split "#a#b") '("#a#b" . ""))))
    (let ((consult-async-split-style 'fake))
      (let ((parts (quarry-consult-grep--split "#ab#cd")))
        (should (equal-including-properties parts '("ab" . "cd")))))))

(ert-deftest quarry-test-consult-grep-split-consult ()
  (skip-unless (fboundp 'consult--split-perl))
  (let ((consult-async-split-style 'perl))
    (should (equal (quarry-consult-grep--split "#foo bar -- -F#fil ter")
                   '("foo bar -- -F" . "fil ter")))
    (should (equal (quarry-consult-grep--split "#foo") '("foo" . "")))
    (should (equal (quarry-consult-grep--split "#foo#") '("foo" . "")))
    (should (equal (quarry-consult-grep--split "/foo/x#y") '("foo" . "x#y")))
    (should (equal (quarry-consult-grep--split "foo") '("foo" . "")))
    (should (equal (quarry-consult-grep--split "") '("" . ""))))
  (let ((consult-async-split-style 'comma))
    (should (equal (quarry-consult-grep--split "foo#x,fil") '("foo#x" . "fil"))))
  (let ((consult-async-split-style 'none))
    (should (equal (quarry-consult-grep--split "#foo#x,fil") '("#foo#x,fil" . ""))))
  ;; nil is the style `none', as for `consult--async-split'.
  (let ((consult-async-split-style nil))
    (should (equal (quarry-consult-grep--split "#foo#x") '("#foo#x" . "")))))

;;;; The commands, with the prompt replaced

(defmacro quarry-test-consult-grep--with-stubs (calls &rest body)
  "Run BODY with consult taken as present and the prompt replaced.
CALLS is bound to what happened, newest first: `types' for the type
list and (read DIR INITIAL) for the prompt."
  (declare (indent 1))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'quarry-consult-grep--available-p)
                (lambda () t))
               ((symbol-function 'quarry-grep--type-list)
                (lambda () (push 'types ,calls) nil))
               ((symbol-function 'quarry-consult-grep--read)
                (lambda (dir initial)
                  (push (list 'read dir initial) ,calls)
                  nil)))
       ,@body)))

(defmacro quarry-test-consult-grep--with-dirs (dirs &rest body)
  "Run BODY with each symbol of DIRS bound to a new temporary directory."
  (declare (indent 1))
  `(let ,(mapcar (lambda (dir)
                   `(,dir (file-name-as-directory
                           (make-temp-file "quarry-cg" t))))
                 dirs)
     (unwind-protect (progn ,@body)
       ,@(mapcar (lambda (dir) `(delete-directory ,dir t)) dirs))))

(ert-deftest quarry-test-consult-grep-command-directory ()
  (quarry-test-consult-grep--with-dirs (here other)
    (quarry-test-consult-grep--with-stubs calls
      (let ((default-directory here))
        ;; The default directory, after the type list was asked for.
        (quarry-consult-grep)
        (should (equal calls `((read ,here nil) types)))
        ;; DIR and INITIAL from Lisp; DIR becomes a directory name.
        (setq calls nil)
        (quarry-consult-grep (directory-file-name other) "foo -- -F")
        (should (equal calls `((read ,other "foo -- -F") types)))
        ;; Interactively: no question without a prefix argument.
        (setq calls nil)
        (cl-letf (((symbol-function 'read-directory-name)
                   (lambda (&rest _) (error "Asked for a directory"))))
          (let ((current-prefix-arg nil))
            (call-interactively #'quarry-consult-grep)))
        (should (equal calls `((read ,here nil) types)))
        ;; With one, the directory is asked for.
        (setq calls nil)
        (let ((asked nil))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (prompt &rest _)
                       (push prompt asked)
                       (directory-file-name other))))
            (let ((current-prefix-arg '(4)))
              (call-interactively #'quarry-consult-grep)))
          (should (equal asked '("Search in directory: ")))
          (should (equal calls `((read ,other nil) types))))))))

(ert-deftest quarry-test-consult-grep-command-project ()
  (quarry-test-consult-grep--with-dirs (root other)
    (quarry-test-consult-grep--with-stubs calls
      (let ((sub (file-name-as-directory (expand-file-name "sub" root))))
        (make-directory sub)
        (let ((default-directory sub))
          ;; In a project: its root.
          (let ((project-find-functions
                 (list (lambda (_dir) (cons 'transient root)))))
            (quarry-consult-grep-project)
            (should (equal calls `((read ,root nil) types)))
            ;; DIR from Lisp is searched as given.
            (setq calls nil)
            (quarry-consult-grep-project other "x")
            (should (equal calls `((read ,other "x") types)))
            ;; No prefix argument: no project is asked for.
            (setq calls nil)
            (cl-letf (((symbol-function 'project-prompt-project-dir)
                       (lambda (&rest _) (error "Asked for a project"))))
              (let ((current-prefix-arg nil))
                (call-interactively #'quarry-consult-grep-project)))
            (should (equal calls `((read ,root nil) types)))
            ;; A prefix argument: the chosen project.
            (setq calls nil)
            (cl-letf (((symbol-function 'project-prompt-project-dir)
                       (lambda (&rest _) (directory-file-name other))))
              (let ((current-prefix-arg '(4)))
                (call-interactively #'quarry-consult-grep-project)))
            (should (equal calls `((read ,other nil) types))))
          ;; Outside a project: the default directory.
          (setq calls nil)
          (let ((project-find-functions nil))
            (quarry-consult-grep-project)
            (should (equal calls `((read ,sub nil) types)))))))))

(ert-deftest quarry-test-consult-grep-command-refuses-directory ()
  "A remote or missing directory is refused before anything else."
  (quarry-test-consult-grep--with-dirs (here)
    (quarry-test-consult-grep--with-stubs calls
      (let ((default-directory here)
            (project-find-functions
             (list (lambda (_dir) (error "Looked for a project")))))
        (dolist (call (list (lambda () (quarry-consult-grep "/ssh:nohost.invalid:/x/"))
                            (lambda () (quarry-consult-grep-project
                                        "/ssh:nohost.invalid:/x/"))
                            (lambda () (let ((default-directory
                                              "/ssh:nohost.invalid:/x/"))
                                         (quarry-consult-grep)))
                            (lambda () (let ((default-directory
                                              "/ssh:nohost.invalid:/x/"))
                                         (quarry-consult-grep-project)))))
          (let ((err (should-error (funcall call) :type 'user-error)))
            (should (string-match-p "local directories only" (cadr err)))))
        (let ((err (should-error
                    (quarry-consult-grep (expand-file-name "nope" here))
                    :type 'user-error)))
          (should (string-prefix-p "Directory does not exist" (cadr err))))
        (should-not calls)))))

(ert-deftest quarry-test-consult-grep-command-without-consult ()
  "Without consult the commands say so before they ask for anything."
  (quarry-test-consult-grep--with-dirs (here)
    (quarry-test-consult-grep--with-stubs calls
      (cl-letf (((symbol-function 'quarry-consult-grep--available-p)
                 (lambda () nil))
                ((symbol-function 'read-directory-name)
                 (lambda (&rest _) (error "Asked for a directory")))
                ((symbol-function 'project-prompt-project-dir)
                 (lambda (&rest _) (error "Asked for a project"))))
        (let ((default-directory here)
              (project-find-functions
               (list (lambda (_dir) (error "Looked for a project")))))
          (dolist (command '(quarry-consult-grep quarry-consult-grep-project))
            (dolist (call (list (lambda () (funcall command))
                                (lambda () (funcall command here "x"))
                                (lambda () (let ((current-prefix-arg '(4)))
                                             (call-interactively command)))))
              (let ((err (should-error (funcall call) :type 'user-error)))
                (should (string-match-p "consult" (cadr err))))))
          (should-not calls))))))

(ert-deftest quarry-test-consult-grep-available ()
  "The check wants every function of consult that is called."
  (should (memq 'consult--grep-state quarry-consult-grep--consult-functions))
  (if (fboundp 'consult--async-pipeline)
      (progn
        (should (quarry-consult-grep--available-p))
        (cl-letf (((symbol-function 'consult--grep-state) nil))
          (should-not (quarry-consult-grep--available-p))))
    (should-not (quarry-consult-grep--available-p))))

(ert-deftest quarry-test-consult-grep-command-region ()
  "An active region is the initial input, quoted; the mark is deactivated."
  (quarry-test-consult-grep--with-dirs (here)
    (quarry-test-consult-grep--with-stubs calls
      (dolist (command '(quarry-consult-grep quarry-consult-grep-project))
        (with-temp-buffer
          (setq default-directory here)
          (insert "see !a.b c# here")
          (let ((transient-mark-mode t)
                (project-find-functions nil)
                (consult-async-split-style 'perl)
                (consult-async-split-styles-alist
                 quarry-test-consult-grep--styles)
                (current-prefix-arg nil))
            (set-mark 5)
            (goto-char 12)
            (activate-mark)
            (should (use-region-p))
            (setq calls nil)
            (call-interactively command)
            (should (equal calls `((read ,here "\\!a\\.b\\ c\\x23") types)))
            (should-not (region-active-p))
            ;; Without a region there is no initial input.
            (setq calls nil)
            (call-interactively command)
            (should (equal calls `((read ,here nil) types)))))))))

(ert-deftest quarry-test-consult-grep-to-buffer-outside ()
  "The hand-over command refuses to run outside the live grep prompt."
  (with-temp-buffer
    (let ((err (should-error (quarry-consult-grep-to-buffer) :type 'user-error)))
      (should (string-match-p "prompt of quarry-consult-grep" (cadr err))))
    ;; Also where the variable is set but the buffer is no minibuffer.
    (setq-local quarry-consult-grep--prompt (cons "/d/" 'tag))
    (should-error (quarry-consult-grep-to-buffer) :type 'user-error)))

(ert-deftest quarry-test-consult-grep-map ()
  (should (eq (keymap-lookup quarry-consult-grep-map "C-c C-o")
              #'quarry-consult-grep-to-buffer))
  (should (commandp #'quarry-consult-grep-to-buffer))
  (should (commandp #'quarry-consult-grep))
  (should (commandp #'quarry-consult-grep-project)))

(ert-deftest quarry-test-consult-grep-hand-over-context ()
  "The search handed over gets the context lines `quarry-grep' starts with."
  (let ((started nil)
        (parsed (quarry-consult-grep--parse "/d/" "a !b -- -t rust")))
    (cl-letf (((symbol-function 'quarry-grep--start-search)
               (lambda (search) (push search started))))
      (let ((quarry-grep-context-before 2)
            (quarry-grep-context-after 3))
        (ert-with-message-capture messages
          (quarry-consult-grep--hand-over parsed "")
          (should (equal messages "")))
        (let ((search (car started)))
          (should (= (quarry-grep--search-before search) 2))
          (should (= (quarry-grep--search-after search) 3))
          ;; A copy: the parsed search is unchanged, the rest is equal.
          (should (= (quarry-grep--search-before parsed) 0))
          (should (= (quarry-grep--search-after parsed) 0))
          (setf (quarry-grep--search-before search) 0
                (quarry-grep--search-after search) 0)
          (should (equal search parsed))))
      ;; Counts above the limit are reduced, and the user is told.
      (let ((quarry-grep-context-before 0)
            (quarry-grep-context-after (1+ quarry-grep-max-context)))
        (ert-with-message-capture messages
          (quarry-consult-grep--hand-over parsed "x y")
          (should (string-match-p "Context is limited to" messages))
          (should (string-suffix-p
                   "The filter part \"x y\" was not carried over\n" messages)))
        (should (= (quarry-grep--search-before (car started)) 0))
        (should (= (quarry-grep--search-after (car started))
                   quarry-grep-max-context))))))

;;;; The prompt, with consult and the real module

(defconst quarry-test-consult-grep--files
  '(("src/a.txt" . "one\nneedle here\nthree\n")
    ("src/b.el" . "needle el\n")
    ("c.txt" . "nothing\nx\nthe needle again\n"))
  "The tree of the prompt tests, an alist from path to content.")

(defvar quarry-test-consult-grep--thunk nil
  "What `quarry-test-consult-grep--launch' calls.")

(defvar quarry-test-consult-grep--expected nil
  "The candidates `quarry-test-consult-grep--settle' waits for, sorted.")

(defvar quarry-test-consult-grep--pick nil
  "The candidate `quarry-test-consult-grep--choose' chooses.")

(defvar quarry-test-consult-grep--failure nil
  "Why a command of the prompt tests gave up, or nil.")

(defvar quarry-test-consult-grep--seen nil
  "Minibuffer contents when `quarry-test-consult-grep--settle' ran.")

(defvar quarry-test-consult-grep--errors nil
  "What `quarry-test-consult-grep--hand' recorded: (MESSAGE OPEN INPUT).")

(defun quarry-test-consult-grep--wait (pred &optional seconds)
  "Wait up to SECONDS (default 10) until PRED returns non-nil; return it."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defun quarry-test-consult-grep--shown ()
  "Return the candidates of the prompt as sorted plain strings."
  (sort (mapcar #'substring-no-properties
                (all-completions "" minibuffer-completion-table))
        #'string<))

(defun quarry-test-consult-grep--launch ()
  "Call `quarry-test-consult-grep--thunk', as a command."
  (interactive)
  (funcall quarry-test-consult-grep--thunk))

(defun quarry-test-consult-grep--settle ()
  "Wait until the prompt has the expected candidates.
Keyboard macros do not let timers or process output run; this command
does, so consult's input timers fire and the hits come in.  On a
timeout it records why and aborts the prompt."
  (interactive)
  (push (minibuffer-contents-no-properties) quarry-test-consult-grep--seen)
  (unless (quarry-test-consult-grep--wait
           (lambda () (equal (quarry-test-consult-grep--shown)
                             quarry-test-consult-grep--expected)))
    (setq quarry-test-consult-grep--failure
          (format "For the input %S the candidates are %S, not %S"
                  (minibuffer-contents-no-properties)
                  (quarry-test-consult-grep--shown)
                  quarry-test-consult-grep--expected))
    (abort-recursive-edit)))

(defun quarry-test-consult-grep--choose ()
  "Insert the candidate to pick and exit, in one command, as a UI's RET."
  (interactive)
  (delete-minibuffer-contents)
  (insert quarry-test-consult-grep--pick)
  (exit-minibuffer))

(defun quarry-test-consult-grep--hand ()
  "Run the command that `C-c C-o' is bound to in the prompt.
When it signals a `user-error', record the message, whether the prompt
is still open and its input, and abort the prompt: an error would end
the keyboard macro and leave batch Emacs reading the terminal."
  (interactive)
  (let ((command (key-binding (kbd "C-c C-o"))))
    (if (not (commandp command))
        (setq quarry-test-consult-grep--failure
              (format "C-c C-o is bound to %S" command))
      (condition-case err
          (call-interactively command)
        (user-error
         (push (list (error-message-string err)
                     (and (minibufferp)
                          (eq (current-buffer)
                              (window-buffer (active-minibuffer-window))))
                     (minibuffer-contents-no-properties))
               quarry-test-consult-grep--errors))))
    (abort-recursive-edit)))

(defun quarry-test-consult-grep--with-keys (thunk keys)
  "Call THUNK as a command and type KEYS in the prompt it opens.
In the prompt, C-c w waits for the expected candidates, C-c x chooses
the candidate to pick and C-c h runs the hand-over key.  Return `done',
or `quit' when the prompt was aborted without a recorded failure."
  (let ((map (define-keymap
               "C-c w" #'quarry-test-consult-grep--settle
               "C-c x" #'quarry-test-consult-grep--choose
               "C-c h" #'quarry-test-consult-grep--hand))
        (minibuffer-setup-hook minibuffer-setup-hook)
        (quarry-test-consult-grep--thunk thunk))
    (add-hook 'minibuffer-setup-hook
              (lambda ()
                (use-local-map (make-composed-keymap map (current-local-map))))
              90)
    (condition-case nil
        (progn
          (execute-kbd-macro
           (kbd (concat "M-x quarry-test-consult-grep--launch RET " keys)))
          'done)
      (quit (if quarry-test-consult-grep--failure
                (ert-fail quarry-test-consult-grep--failure)
              'quit)))))

(defun quarry-test-consult-grep--visiting (dir)
  "Return the buffers that visit a file below DIR."
  (seq-filter (lambda (buffer)
                (and (buffer-file-name buffer)
                     (string-prefix-p dir (buffer-file-name buffer))))
              (buffer-list)))

(defmacro quarry-test-consult-grep--with-tree (dir &rest body)
  "Run BODY with DIR bound to a tree of `quarry-test-consult-grep--files'.
DIR is the `default-directory'.  The options have their defaults, the
delays of the prompt are short, the split style is `perl' and the
result buffer has a name of its own.  Afterwards the result buffer and
the buffers visiting files of the tree are killed."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "quarry-cg" t)))
          (default-directory ,dir)
          (quarry-grep-buffer-name "*quarry-consult-grep-test*")
          (quarry-grep-case 'smart)
          (quarry-grep-max-lines 50000)
          (quarry-grep-max-columns 500)
          (quarry-grep-context-before 0)
          (quarry-grep-context-after 0)
          (quarry-grep-highlight-include-filters t)
          (quarry-include-hidden t)
          (quarry-ignores nil)
          (quarry-consult-grep-max-lines 1000)
          (quarry-consult-grep-input-debounce 0.01)
          (quarry-consult-grep-input-throttle 0.01)
          (quarry-consult-grep-history nil)
          (consult-async-split-style 'perl)
          (consult-async-min-input 1)
          (consult-async-refresh-delay 0.01)
          (project-find-functions nil))
     (pcase-dolist (`(,path . ,content) quarry-test-consult-grep--files)
       (let ((file (expand-file-name path ,dir)))
         (make-directory (file-name-directory file) t)
         (write-region content nil file nil 'silent)))
     (setq quarry-test-consult-grep--failure nil
           quarry-test-consult-grep--seen nil
           quarry-test-consult-grep--errors nil
           quarry-test-consult-grep--expected nil
           quarry-test-consult-grep--pick nil)
     (unwind-protect
         (save-window-excursion ,@body)
       ;; Killing the result buffer cancels its search.
       (when (get-buffer quarry-grep-buffer-name)
         (kill-buffer quarry-grep-buffer-name))
       (dolist (buffer (quarry-test-consult-grep--visiting ,dir))
         (kill-buffer buffer))
       (delete-directory ,dir t))))

(defun quarry-test-consult-grep--result (seconds)
  "Wait up to SECONDS for the result buffer's search to end; return the buffer."
  (let ((buffer (get-buffer quarry-grep-buffer-name)))
    (should buffer)
    (should (quarry-test-consult-grep--wait
             (lambda ()
               (not (eq (buffer-local-value 'quarry-grep--state buffer)
                        'running)))
             seconds))
    buffer))

(ert-deftest quarry-test-consult-grep-visits ()
  "Typed input brings the hits; the chosen one is visited at its line."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (let ((prompts nil)
          (minibuffer-setup-hook minibuffer-setup-hook))
      (add-hook 'minibuffer-setup-hook
                (lambda () (push (minibuffer-prompt) prompts)))
      (setq quarry-test-consult-grep--expected
            '("c.txt:3:the needle again" "src/a.txt:2:needle here"
              "src/b.el:1:needle el")
            quarry-test-consult-grep--pick "src/a.txt:2:needle here")
      (should (eq (quarry-test-consult-grep--with-keys
                   (lambda () (quarry-consult-grep dir))
                   "needle C-c w C-c x")
                  'done))
      (should (equal (buffer-file-name (window-buffer))
                     (concat dir "src/a.txt")))
      (with-current-buffer (window-buffer)
        (should (= (line-number-at-pos (window-point)) 2))
        (should (= (save-excursion (goto-char (window-point)) (current-column))
                   0)))
      (should (equal (car prompts)
                     (format "Grep in %s: " (abbreviate-file-name dir))))
      ;; The perl style puts the initial "#" in the minibuffer.
      (should (equal quarry-test-consult-grep--seen '("#needle")))
      (should (equal quarry-consult-grep-history '("#needle")))
      (should-not (get-buffer quarry-grep-buffer-name)))))

(ert-deftest quarry-test-consult-grep-visits-initial ()
  "Initial input with options, through the project command."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (setq quarry-test-consult-grep--expected
          '("c.txt:3:the needle again" "src/a.txt:2:needle here")
          quarry-test-consult-grep--pick "c.txt:3:the needle again")
    (should (eq (quarry-test-consult-grep--with-keys
                 (lambda ()
                   (let ((default-directory
                          (expand-file-name "src/" dir))
                         (project-find-functions
                          (list (lambda (_dir) (cons 'transient dir)))))
                     (quarry-consult-grep-project nil "needle -- -g *.txt")))
                 "C-c w C-c x")
                'done))
    ;; The split style's character is in front of the initial input.
    (should (equal quarry-test-consult-grep--seen '("#needle -- -g *.txt")))
    (should (equal (buffer-file-name (window-buffer)) (concat dir "c.txt")))
    (with-current-buffer (window-buffer)
      (save-excursion
        (goto-char (window-point))
        (should (= (line-number-at-pos) 3))
        (should (= (current-column) 4))
        (should (looking-at-p "needle again"))))))

(ert-deftest quarry-test-consult-grep-hand-over ()
  "The hand-over key runs the typed search in the result buffer."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (let ((quarry-grep-context-before 2)
          (quarry-grep-context-after 1))
      (setq quarry-test-consult-grep--expected
            '("c.txt:3:the needle again" "src/a.txt:2:needle here"))
      (ert-with-message-capture messages
        (should (eq (quarry-test-consult-grep--with-keys
                     (lambda () (quarry-consult-grep dir))
                     "needle SPC !el SPC -- SPC -g SPC *.txt #again C-c w C-c h")
                    'done))
        (should-not quarry-test-consult-grep--errors)
        (should (equal quarry-test-consult-grep--seen
                       '("#needle !el -- -g *.txt#again")))
        (let ((buffer (quarry-test-consult-grep--result 10))
              (expected (quarry-consult-grep--parse
                         dir "needle !el -- -g *.txt")))
          (setf (quarry-grep--search-before expected) 2
                (quarry-grep--search-after expected) 1)
          ;; The result buffer is shown and has the parsed search.
          (should (eq (window-buffer) buffer))
          (with-current-buffer buffer
            (should (equal quarry-grep--current expected))
            (should (equal (mapcar #'quarry-grep--filter-pattern
                                   (quarry-grep--search-filters
                                    quarry-grep--current))
                           '("needle" "el")))
            (should (equal (quarry-grep--search-globs quarry-grep--current)
                           '("*.txt")))
            (should (eq quarry-grep--state 'done))
            (should (= quarry-grep--lines 2))
            (should (equal default-directory dir))))
        ;; The live candidate was not visited.
        (should-not (quarry-test-consult-grep--visiting dir))
        (should (string-match-p
                 "^The filter part \"again\" was not carried over$" messages))
        (should (equal quarry-consult-grep-history
                       '("#needle !el -- -g *.txt#again")))))))

(ert-deftest quarry-test-consult-grep-hand-over-type-not ()
  "The hand-over carries an excluded type into the result buffer."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (setq quarry-test-consult-grep--expected
          '("c.txt:3:the needle again" "src/a.txt:2:needle here"))
    (should (eq (quarry-test-consult-grep--with-keys
                 (lambda () (quarry-consult-grep dir))
                 "needle SPC -- SPC -T SPC json C-c h")
                'done))
    (with-current-buffer (quarry-test-consult-grep--result 10)
      (should (equal (quarry-grep--search-types quarry-grep--current)
                     '("!json")))
      (should (string-match-p " files: !json " (substring-no-properties (quarry-grep--header))))
      (should-not quarry-test-consult-grep--errors))))

(ert-deftest quarry-test-consult-grep-hand-over-newer-input ()
  "The hand-over takes the input as it is, not what was last searched."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (setq quarry-test-consult-grep--expected
          '("c.txt:3:the needle again" "src/a.txt:2:needle here"
            "src/b.el:1:needle el"))
    (ert-with-message-capture messages
      ;; No timer runs between the last keys: the step never saw "here".
      (should (eq (quarry-test-consult-grep--with-keys
                   (lambda () (quarry-consult-grep dir))
                   "needle C-c w SPC here SPC -- SPC -F C-c h")
                  'done))
      (let ((buffer (quarry-test-consult-grep--result 10)))
        (with-current-buffer buffer
          (should (equal quarry-grep--current
                         (quarry-consult-grep--parse dir "needle here -- -F")))
          (should (= quarry-grep--lines 1))))
      (should-not (quarry-test-consult-grep--visiting dir))
      (should-not (string-match-p "not carried over" messages)))))

(ert-deftest quarry-test-consult-grep-hand-over-refused ()
  "Input that is no search is a `user-error'; the prompt stays open."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (pcase-dolist (`(,keys ,input ,message)
                   '(("needle SPC -- SPC -x" "#needle -- -x"
                      "Unknown option -x; see the README for the options")
                     ("needle SPC -- SPC -F SPC word" "#needle -- -F word"
                      "Not an option: word")
                     ("!x" "#!x" "Nothing to search yet")
                     ("SPC" "# " "Nothing to search yet")
                     ("#needle" "##needle" "Nothing to search yet")))
      (setq quarry-test-consult-grep--errors nil)
      (should (eq (quarry-test-consult-grep--with-keys
                   (lambda () (quarry-consult-grep dir))
                   (concat keys " C-c h"))
                  'quit))
      (should (equal quarry-test-consult-grep--errors
                     (list (list message t input))))
      (should (= (minibuffer-depth) 0))
      (should-not (get-buffer quarry-grep-buffer-name)))
    ;; While the result buffer is edited, also for input that is a search.
    (setq quarry-test-consult-grep--errors nil)
    (cl-letf (((symbol-function 'quarry-grep--check-result-buffer)
               (lambda () (user-error "Being edited"))))
      (should (eq (quarry-test-consult-grep--with-keys
                   (lambda () (quarry-consult-grep dir))
                   "needle C-c h")
                  'quit)))
    (should (equal quarry-test-consult-grep--errors
                   '(("Being edited" t "#needle"))))
    (should-not (get-buffer quarry-grep-buffer-name))
    (should-not (quarry-test-consult-grep--visiting dir))))

(ert-deftest quarry-test-consult-grep-prompt-variable-is-local ()
  "The prompt's directory is known in its minibuffer only, and not after."
  (skip-unless (quarry-consult-grep--available-p))
  (quarry-test-consult-grep--with-tree dir
    (let ((inside nil)
          (minibuffer-setup-hook minibuffer-setup-hook))
      (add-hook 'minibuffer-setup-hook
                (lambda ()
                  (push (car-safe quarry-consult-grep--prompt) inside))
                95)
      (should (eq (quarry-test-consult-grep--with-keys
                   (lambda () (quarry-consult-grep dir))
                   "!x C-c h")
                  'quit))
      ;; The M-x prompt, then the grep prompt.
      (should (equal inside (list dir nil)))
      (should-not (default-value 'quarry-consult-grep--prompt))
      ;; A later prompt in the same minibuffer does not have it.
      (setq inside nil)
      (execute-kbd-macro (kbd "M-x ignore RET"))
      (should (equal inside '(nil))))))

(provide 'quarry-consult-grep-tests)
;;; quarry-consult-grep-tests.el ends here
