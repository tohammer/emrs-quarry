;;; quarry-tests.el --- ERT suite for quarry  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh.

;;; Code:

(require 'ert)
(require 'quarry)

;; `project-current' with MAYBE-PROMPT records the project in
;; `project-list-file'.  Keep the user's file out of the tests (parallel
;; runs would also collide on its lock); quarry-consult-tests.el loads
;; this file and shares the setting.
(setq project-list-file (make-temp-file "quarry-test-projects" nil ".eld" "()\n"))
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-file project-list-file))))

(ert-deftest quarry-test-loads ()
  "quarry.el and emrs.el load."
  (should (featurep 'quarry))
  (should (featurep 'emrs)))

;; The module must be installed as quarry-module on `load-path'
;; (tests/run-ert.sh does that).

(defun quarry-test--make-tree (files)
  "Create a temporary directory holding FILES (relative paths); return it."
  (let ((dir (file-name-as-directory (make-temp-file "quarry-test" t))))
    (dolist (file files)
      (let ((path (expand-file-name file dir)))
        (make-directory (file-name-directory path) t)
        (write-region "" nil path nil 'silent)))
    dir))

(ert-deftest quarry-test-service-round-trip ()
  "The module loads; rescan, status and query return the documented plists."
  (let* ((dir (quarry-test--make-tree '("src/main.rs" "src/lib.rs" "README.md")))
         (inst nil))
    (unwind-protect
        (progn
          (setq inst (emrs-start 'quarry "index" (list :root dir)))
          (should (equal (emrs-call-sync inst '(:rescan) 10) 3))
          (let ((status (emrs-call-sync inst '(:status) 10)))
            (should (equal (plist-get status :root) dir))
            (should (equal (plist-get status :files) 3))
            (should-not (plist-get status :indexing))
            (should (plist-get status :watching))
            (should (>= (plist-get status :walks) 1))
            (should (equal (plist-get status :skipped) 0))
            (should (equal (length status) 12)))
          (should (equal (emrs-call-sync
                          inst '(:query :text "main" :limit 10 :positions t) 10)
                         '(:paths ("src/main.rs") :positions ((4 5 6 7))
                           :groups ((0 0 0 0)) :total 1 :indexing nil)))
          ;; :limit, :positions and :substring are optional.
          (should (equal (emrs-call-sync inst '(:query :text "rs") 10)
                         '(:paths ("src/lib.rs" "src/main.rs") :positions nil
                           :groups nil :total 2 :indexing nil)))
          (should (equal (plist-get (emrs-call-sync
                                     inst '(:query :text "smn" :substring t) 10)
                                    :total)
                         0)))
      (when inst
        (emrs-stop inst))
      (delete-directory dir t))))

;;;; Instances, events, queries

(defun quarry-test--wait (pred &optional seconds)
  "Wait up to SECONDS (default 10) until PRED returns non-nil; return it."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defmacro quarry-test--with-roots (bindings &rest body)
  "Bind each (VAR FILES) in BINDINGS to a temp tree, run BODY, clean up."
  (declare (indent 1))
  `(let ,(mapcar (lambda (b) `(,(car b) (quarry-test--make-tree ,(cadr b)))) bindings)
     (unwind-protect (progn ,@body)
       (quarry-stop-all)
       (let ((gone (quarry-test--wait
                    (lambda () (zerop (hash-table-count quarry--instances))) 3)))
         ,@(mapcar (lambda (b) `(delete-directory ,(car b) t)) bindings)
         (should gone)))))

(ert-deftest quarry-test-one-instance-per-root ()
  (quarry-test--with-roots ((a '("a.txt")) (b '("b.txt")))
    (let ((ra (quarry--ensure a)))
      (should (eq ra (quarry--ensure a)))
      ;; A non-normalized spelling of the same root finds the same record.
      (should (eq ra (quarry--ensure (directory-file-name a))))
      (let ((rb (quarry--ensure b)))
        (should-not (eq ra rb))
        (should-not (eq (quarry--rec-instance ra) (quarry--rec-instance rb)))
        (should (= (hash-table-count quarry--instances) 2))))))

(ert-deftest quarry-test-stop-and-stop-all ()
  (quarry-test--with-roots ((a '("a.txt")) (b '("b.txt")))
    (let ((ra (quarry--ensure a)))
      (quarry--ensure b)
      (quarry--stop a)
      (should (quarry-test--wait (lambda () (null (quarry--lookup a)))))
      (should (eq (emrs-instance-state (quarry--rec-instance ra)) 'stopped))
      (should (quarry--lookup b))
      ;; The next use starts a new instance.
      (should-not (eq ra (quarry--ensure a)))
      (quarry-stop-all)
      (should (quarry-test--wait
               (lambda () (zerop (hash-table-count quarry--instances))))))))

(ert-deftest quarry-test-query ()
  (quarry-test--with-roots ((dir '("src/main.rs" "src/lib.rs" "README.md")))
    (emrs-call-sync (quarry--rec-instance (quarry--ensure dir)) '(:rescan) 10)
    (should (equal (quarry-query dir "main" 10 t)
                   '(:paths ("src/main.rs") :positions ((4 5 6 7))
                     :groups ((0 0 0 0)) :total 1 :indexing nil)))
    ;; `quarry-match-style' applies to queries.
    (should (equal (plist-get (quarry-query dir "smn" 10) :paths)
                   '("src/main.rs")))
    (let ((quarry-match-style 'substring))
      (should (null (plist-get (quarry-query dir "smn" 10) :paths)))
      (should (equal (plist-get (quarry-query dir "'smn" 10) :paths)
                     '("src/main.rs")))
      (should (equal (plist-get (quarry-query dir "ai rs" 10 t) :groups)
                     '((0 0 1 1)))))
    (should (equal (plist-get (quarry-query dir "rs" 1) :total) 2))
    (should (= (length (plist-get (quarry-query dir "rs" 1) :paths)) 1))))

(ert-deftest quarry-test-indexed-event ()
  (quarry-test--with-roots ((dir '("a" "b" "c")))
    (let ((rec (quarry--ensure dir)))
      (should (quarry-test--wait (lambda () (> (quarry--rec-epoch rec) 0))))
      (should (= (quarry--rec-files rec) 3))
      (should-not (quarry--rec-indexing rec)))))

(ert-deftest quarry-test-synthetic-events ()
  (let ((rec (quarry--make-rec :root "/x/" :files 10 :watching t))
        (warnings 0))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (quarry--on-event rec '(:indexed :files 5 :millis 3))
      (should (= (quarry--rec-files rec) 5))
      (should (= (quarry--rec-epoch rec) 1))
      (quarry--on-event rec '(:changed :added 4 :removed 1))
      (should (= (quarry--rec-files rec) 8))
      (should (= (quarry--rec-epoch rec) 2))
      (quarry--on-event rec '(:watch-failed :message "boom"))
      (quarry--on-event rec '(:watch-failed :message "again"))
      (should-not (quarry--rec-watching rec))
      (should (= warnings 1)))))

(ert-deftest quarry-test-exit-removes-only-own-record ()
  (let* ((old (quarry--make-rec :root "/x/"))
         (new (quarry--make-rec :root "/x/")))
    (puthash "/x/" new quarry--instances)
    (unwind-protect
        (progn (quarry--on-exit old 'stopped nil)
               (should (eq (gethash "/x/" quarry--instances) new))
               (quarry--on-exit new 'stopped nil)
               (should-not (gethash "/x/" quarry--instances)))
      (remhash "/x/" quarry--instances))))

(ert-deftest quarry-test-failing-start ()
  (let* ((dir (quarry-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir))))
    (unwind-protect
        (progn
          (should-error (quarry-query missing "x" 10) :type 'user-error)
          (should (quarry-test--wait (lambda () (null (quarry--lookup missing)))))
          ;; A second attempt starts afresh and fails the same way.
          (should-error (quarry-query missing "x" 10) :type 'user-error)
          (should (null (quarry--lookup missing))))
      (quarry-stop-all)
      (delete-directory dir t))))

(ert-deftest quarry-test-query-async ()
  (quarry-test--with-roots ((dir '("src/main.rs" "README.md")))
    (let ((result 'none))
      (emrs-call-sync (quarry--rec-instance (quarry--ensure dir)) '(:rescan) 10)
      (quarry-query-async dir "main" 10 nil
                           (lambda (reply err) (setq result (list reply err))))
      (should (quarry-test--wait (lambda () (not (eq result 'none)))))
      (should (null (cadr result)))
      (should (equal (plist-get (car result) :paths) '("src/main.rs"))))))

(ert-deftest quarry-test-status-and-rescan ()
  (quarry-test--with-roots ((dir '("a" "b")))
    (let ((msgs nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (quarry--rescan dir)
        (should (quarry-test--wait (lambda () msgs)))
        (should (string-match-p "2 files" (car msgs)))
        (should (string-match-p "2 files, indexing no" (quarry--status dir)))))))

;;;; Completion table, style, finder

(defconst quarry-test--files
  '("src/main.rs" "src/lib.rs" "README.md" "docs/ünï/größe.txt" "a/b/foo_bar.el" "foobar.el")
  "Files of the completion test tree.")

(defmacro quarry-test--with-index (var &rest body)
  "Run BODY with VAR bound to an indexed temp tree."
  (declare (indent 1))
  `(quarry-test--with-roots ((,var quarry-test--files))
     (emrs-call-sync (quarry--rec-instance (quarry--ensure ,var)) '(:rescan) 10)
     ,@body))

(defun quarry-test--faces-at (string &optional face)
  "Return the indices of STRING that carry FACE.
Without FACE, any face of `quarry-match-faces'."
  (cl-loop for i below (length string)
           for faces = (ensure-list (get-text-property i 'face string))
           when (if face (memq face faces)
                  (seq-intersection faces quarry-match-faces))
           collect i))

(ert-deftest quarry-test-table-basics ()
  (quarry-test--with-index dir
    (let ((table (quarry--table dir)))
      (should (equal (funcall table "" nil 'metadata)
                     '(metadata (category . project-file)
                                (display-sort-function . identity)
                                (cycle-sort-function . identity))))
      (should (equal (funcall table "main" nil t) '("src/main.rs")))
      (should (equal (funcall table "rs$" nil t) (quote ("src/lib.rs" "src/main.rs"))))
      (should (equal (funcall table "" (lambda (p) (string-suffix-p ".md" p)) t)
                     '("README.md")))
      (should (equal (funcall table "" nil t)
                     (plist-get (quarry-query dir "" 200) :paths)))
      ;; try-completion
      (should (eq (funcall table "src/main.rs" nil nil) t))
      (should (equal (funcall table "main" nil nil) "src/main.rs"))
      (should (equal (funcall table "rs$" nil nil) "rs$"))
      (should (null (funcall table "zzzzqq" nil nil)))
      ;; test-completion
      (should (funcall table "src/main.rs" nil 'lambda))
      (should-not (funcall table "main" nil 'lambda))
      (should-not (funcall table "src/main.rs"
                           (lambda (_) nil) 'lambda))
      ;; boundaries
      (should (null (funcall table "a/b" nil '(boundaries . "c")))))))

(ert-deftest quarry-test-table-limit ()
  (quarry-test--with-index dir
    (let ((quarry-limit 2))
      (should (= (length (funcall (quarry--table dir) "" nil t)) 2)))))

(ert-deftest quarry-test-style-keeps-rust-order ()
  (quarry-test--with-index dir
    (let* ((completion-styles '(quarry))
           ;; The table's category has its own default styles.
           (completion-category-overrides '((project-file (styles quarry))))
           (table (quarry--table dir))
           (expected (plist-get (quarry-query dir "foobar" 200) :paths))
           (all (completion-all-completions "foobar" table nil 6)))
      ;; The nucleo order differs from the alphabetical one here.
      (should (cdr expected))
      (should-not (equal expected (sort (copy-sequence expected) #'string<)))
      (should (equal (cl-loop for c on all while (consp c) collect (car c))
                     expected))
      (should (= (cdr (last all)) 0))
      (should (null (completion-all-completions "zzzzqq" table nil 6)))
      (should (equal (completion-try-completion "main" table nil 4)
                     '("src/main.rs" . 11)))
      (should (equal (completion-try-completion "rs$" table nil 3) '("rs$" . 3)))
      (should (eq (completion-try-completion "src/main.rs" table nil 11) t))
      (should (null (completion-try-completion "zzzzqq" table nil 6))))))

(ert-deftest quarry-test-highlighting ()
  (quarry-test--with-index dir
    (let* ((table (quarry--table dir))
           (reply (quarry-query dir "main" 10 t))
           (paths (funcall table "main" nil t)))
      (should (equal (quarry-test--faces-at (car paths))
                     (car (plist-get reply :positions))))
      (should (equal (quarry-test--faces-at (car paths)) '(4 5 6 7)))
      ;; Non-ASCII: indices are characters.
      (let* ((p (car (funcall table "größe" nil t)))
             (pos (car (plist-get (quarry-query dir "größe" 10 t) :positions))))
        (should (equal p "docs/ünï/größe.txt"))
        (should (equal (quarry-test--faces-at p) pos))
        (should (equal (mapcar (lambda (i) (aref p i)) pos)
                       (string-to-list "größe"))))
      ;; Cached originals are not mutated: a repeated call is identical and
      ;; highlighting off yields plain strings from the same cache epoch.
      (should (equal-including-properties (funcall table "main" nil t) paths))
      (let ((quarry-highlight nil))
        (should (null (quarry-test--faces-at
                       (car (funcall table "main" nil t))))))
      ;; One face per term, in turn; negated terms get none.
      (let ((p (car (funcall table "'rs !zz 'ai 'c 'm 'n" nil t))))
        (should (equal p "src/main.rs"))
        ;; The fifth term, n, wraps around to the first face.
        (should (equal (quarry-test--faces-at p 'quarry-match-0) '(7 9 10)))
        (should (equal (quarry-test--faces-at p 'quarry-match-1) '(5 6)))
        (should (equal (quarry-test--faces-at p 'quarry-match-2) '(2)))
        (should (equal (quarry-test--faces-at p 'quarry-match-3) '(4))))
      (let ((quarry-match-faces '(completions-common-part)))
        (should (equal (quarry-test--faces-at
                        (car (funcall table "ai rs" nil t)) 'completions-common-part)
                       '(5 6 9 10))))
      (should (equal (quarry-test--faces-at
                      (car (funcall table "main" nil t)))
                     '(4 5 6 7)))
      (should-not (get-text-property 0 'face (car (plist-get (quarry-query dir "main" 10) :paths))))
      ;; A UI that adds properties in place does not corrupt the cache,
      ;; with highlighting and without.
      (let ((str (car (funcall table "main" nil t))))
        (put-text-property 0 (length str) 'face 'bold str)
        (should (equal (quarry-test--faces-at (car (funcall table "main" nil t)))
                       '(4 5 6 7)))
        (should-not (memq 'bold (ensure-list
                                 (get-text-property 0 'face (car (funcall table "main" nil t)))))))
      (let ((quarry-highlight nil)
            (table (quarry--table dir)))
        (let ((str (car (funcall table "main" nil t))))
          (put-text-property 0 (length str) 'face 'bold str))
        (should-not (get-text-property 0 'face (car (funcall table "main" nil t))))))))

(ert-deftest quarry-test-cache ()
  (quarry-test--with-index dir
    (let ((calls 0)
          (table (quarry--table dir))
          (rec (quarry--ensure dir)))
      (advice-add 'quarry-query :before (lambda (&rest _) (cl-incf calls))
                  '((name . quarry-test-count)))
      (unwind-protect
          (progn
            (funcall table "main" nil t)
            (funcall table "main" nil nil)
            (funcall table "main" nil 'lambda)
            (should (= calls 1))
            (funcall table "lib" nil t)
            (should (= calls 2))
            (cl-incf (quarry--rec-epoch rec))
            (funcall table "main" nil t)
            (should (= calls 3)))
        (advice-remove 'quarry-query 'quarry-test-count)))))

(ert-deftest quarry-test-cache-invalidation-synthetic ()
  (quarry-test--with-index dir
    (let ((table (quarry--table dir))
          (rec (quarry--ensure dir)))
      (should-not (funcall table "newfile" nil t))
      (write-region "" nil (expand-file-name "newfile.txt" dir) nil 'silent)
      (emrs-call-sync (quarry--rec-instance rec) '(:rescan) 10)
      (quarry--on-event rec '(:changed :added 1 :removed 0))
      (should (equal (funcall table "newfile" nil t) '("newfile.txt"))))))

(ert-deftest quarry-test-cache-invalidation-watcher ()
  :tags '(watcher)
  (quarry-test--with-roots ((dir '("a.txt")))
    (let* ((rec (quarry--ensure dir))
           (table (quarry--table dir)))
      (should (quarry-test--wait (lambda () (> (quarry--rec-epoch rec) 0))))
      (should-not (funcall table "newfile" nil t))
      (let ((epoch (quarry--rec-epoch rec)))
        (write-region "" nil (expand-file-name "newfile.txt" dir) nil 'silent)
        (unless (quarry-test--wait (lambda () (> (quarry--rec-epoch rec) epoch)))
          (ert-fail "No :changed event: this test needs a working file watcher (inotify, FSEvents or ReadDirectoryChanges)"))
        (should (equal (funcall table "newfile" nil t) '("newfile.txt")))))))

(ert-deftest quarry-test-table-timeout ()
  (let ((msgs nil)
        (table nil))
    (cl-letf (((symbol-function 'quarry--ensure)
               (lambda (_) (quarry--make-rec :root "/x/")))
              ((symbol-function 'quarry-query)
               (lambda (&rest _) (signal 'emrs-error '(timeout "slow"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (setq table (quarry--table "/x/"))
      (should (null (funcall table "a" nil t)))
      (should (null (funcall table "ab" nil t)))
      (should (= (length msgs) 1)))))

(ert-deftest quarry-test-find-file-round-trip ()
  (quarry-test--with-index dir
    (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
           (buf nil))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
        (unwind-protect
            (progn
              ;; In batch mode the minibuffer would read stdin, but not
              ;; while a keyboard macro runs, so drive the command with one.
              (let ((seen nil))
                (let ((minibuffer-setup-hook
                       (cons (lambda ()
                               (push (list (minibuffer-prompt)
                                           (cadr (assq 'styles (assq 'project-file
                                                                     completion-category-overrides))))
                                     seen))
                             minibuffer-setup-hook)))
                  (execute-kbd-macro (kbd "M-x quarry-find-file RET src/main.rs RET")))
                (should (equal (car seen) (list (format "Find file in %s: "
                                                  (project-name (project-current)))
                                          'quarry))))
              (setq buf (current-buffer))
              (should (equal (buffer-file-name buf)
                             (expand-file-name "src/main.rs" dir))))
          (when buf (kill-buffer buf)))))))

(defun quarry-test--find-file-while-indexing (dir fake)
  "Run `quarry-find-file' in DIR; the first FAKE `:status' replies say
indexing with no files.  Return (FAKE-LEFT SHOWN): the fake replies
not used up when the prompt opened, and the candidates for empty input."
  (let ((project-find-functions (list (lambda (_) (list 'transient dir))))
        (call-sync (symbol-function 'quarry--call-sync))
        (left nil)
        (shown nil)
        (buf nil))
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
              ((symbol-function 'quarry--call-sync)
               (lambda (root request)
                 (if (and (equal request '(:status)) (> fake 0))
                     (progn (cl-decf fake) '(:files 0 :indexing t))
                   (funcall call-sync root request))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq left fake
                       shown (all-completions "" table))
                 "a.txt")))
      (unwind-protect
          (progn
            (quarry-find-file)
            (setq buf (current-buffer))
            (list left shown))
        (when buf (kill-buffer buf))))))

(ert-deftest quarry-test-find-file-waits-for-first-page ()
  "The prompt of a new instance opens once its index has files to show.
UIs ask for the empty input once and do not refresh while indexing runs."
  (quarry-test--with-roots ((dir '("a.txt" "b.txt")))
    (pcase-let ((`(,left ,shown) (quarry-test--find-file-while-indexing dir 3)))
      (should (= left 0))
      (should (equal (sort shown #'string<) '("a.txt" "b.txt"))))))

(ert-deftest quarry-test-find-file-first-page-wait-is-capped ()
  "An index that stays empty does not hold the prompt back for long."
  (quarry-test--with-roots ((dir '("a.txt")))
    (let ((quarry--first-page-wait 0.2)
          (start (float-time)))
      (pcase-let ((`(,left ,_) (quarry-test--find-file-while-indexing dir 1000)))
        (should (> left 0))
        (should (< (- (float-time) start) 2))))))

(defun quarry-test--find-file-with-keys (dir keys)
  "Run `quarry-find-file' in project DIR typing KEYS; return the visited file."
  (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
         (buf nil))
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
      (unwind-protect
          (progn
            (execute-kbd-macro (kbd (concat "M-x quarry-find-file RET " keys)))
            (setq buf (current-buffer))
            (buffer-file-name buf))
        (when buf (kill-buffer buf))))))

(ert-deftest quarry-test-ui-unique-match ()
  "TAB completes a unique match and RET accepts the completion."
  (quarry-test--with-index dir
    (let* ((contents nil)
           (orig (symbol-function 'completing-read))
           )
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest args)
                   (setq contents (apply orig args)))))
      ;; TAB completes `main' to the only candidate; RET visits it.
      (should (equal (quarry-test--find-file-with-keys dir "main TAB RET")
                     (concat dir "src/main.rs")))
      (should (equal contents "src/main.rs"))
      ;; `confirm' makes the first RET ask for confirmation and the
      ;; second accept the input as typed; `quarry-find-file' then
      ;; resolves it to the unique match instead of <root>/main.
      (setq contents nil)
      (should (equal (quarry-test--find-file-with-keys dir "main RET RET")
                     (concat dir "src/main.rs")))
      (should (equal contents "main"))
      ;; Input matching several files is visited as typed.
      (should (equal (quarry-test--find-file-with-keys dir "rs$ RET RET")
                     (concat dir "rs$")))))))

;; A style like orderless: asks the table for all candidates of the
;; empty prefix and relies on `completion-regexp-list' to filter them.
(defun quarry-test--greedy-all (_string table pred _point)
  (let ((all (all-completions "" table pred)))
    (and all (nconc all 0))))

(defun quarry-test--greedy-try (_string _table _pred _point) nil)

(ert-deftest quarry-test-ui-no-match-shows-nothing ()
  "No match gives no candidates, whatever the user's `completion-styles'."
  (quarry-test--with-index dir
    (let* ((completion-styles-alist
            (cons '(quarry-test-greedy quarry-test--greedy-try
                                        quarry-test--greedy-all "")
                  completion-styles-alist))
           (completion-styles '(quarry-test-greedy))
           (seen nil)
           (map (define-keymap
                  "C-c t" (lambda ()
                            (interactive)
                            (let ((s (minibuffer-contents)))
                              (push (list s completion-styles
                                          (completion-all-completions
                                           s minibuffer-completion-table
                                           minibuffer-completion-predicate
                                           (length s)))
                                    seen)))))
           (minibuffer-setup-hook minibuffer-setup-hook))
      (add-hook 'minibuffer-setup-hook
                (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
                90)
      (quarry-test--find-file-with-keys dir "zzzqqq C-c t DEL DEL DEL DEL DEL DEL main C-c t RET")
      (should (equal (nth 1 seen) '("zzzqqq" (quarry) nil)))
      (should (equal (car (nth 0 seen)) "main"))
      (should (equal (car (nth 2 (nth 0 seen))) "src/main.rs"))
      ;; Other prompts keep the user's styles.
      (should (equal completion-styles '(quarry-test-greedy))))))

(ert-deftest quarry-test-ui-fido-keeps-quarry-style ()
  "fido-mode's setup does not replace the quarry style."
  (quarry-test--with-index dir
    (let ((seen nil)
          (fido fido-mode)
          (minibuffer-setup-hook minibuffer-setup-hook))
      (unwind-protect
          (progn
            (fido-mode 1)
            ;; fido skips its setup while a keyboard macro runs.
            (cl-letf (((symbol-function 'icomplete-simple-completing-p) (lambda () t)))
              (add-hook 'minibuffer-setup-hook
                        (lambda () (push completion-styles seen))
                        95)
              (quarry-test--find-file-with-keys dir "src/main.rs RET")))
        (fido-mode (if fido 1 -1)))
      (should (equal (car seen) '(quarry))))))

(ert-deftest quarry-test-ui-multiple-matches-keep-input ()
  (quarry-test--with-index dir
    (let ((table (quarry--table dir)))
      (should (equal (funcall table "rs$" nil nil) "rs$"))
      (should (equal (completion-try-completion "rs$" table nil 3) '("rs$" . 3))))))

(ert-deftest quarry-test-find-file-tilde-directory ()
  "An index path starting with a `~' directory stays below the root."
  (let ((dir (quarry-test--make-tree '("a.txt"))))
    (make-directory (concat dir "~/") t)
    (write-region "" nil (concat dir "~/x") nil 'silent)
    (unwind-protect
        (progn
          (emrs-call-sync (quarry--rec-instance (quarry--ensure dir)) '(:rescan) 10)
          (let ((file (quarry-test--find-file-with-keys dir "~/x RET")))
            (should (equal file (concat dir "~/x")))
            (should (string-prefix-p dir file))))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-find-file-failed-root ()
  "A project root the service cannot index gives a `user-error'."
  (let* ((dir (quarry-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (project-find-functions (list (lambda (_) (list 'transient missing)))))
    (unwind-protect
        (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
          (let ((err (should-error (quarry-find-file) :type 'user-error)))
            (should (string-prefix-p "quarry: " (cadr err)))
            (should (> (length (cadr err)) (length "quarry: ")))))
      (quarry-stop-all)
      (delete-directory dir t))))

(ert-deftest quarry-test-module-not-found ()
  (let ((dir (quarry-test--make-tree nil)))
    (unwind-protect
        (cl-letf (((symbol-function 'emrs-load-module)
                   (lambda (&rest _) (signal 'file-missing '("Cannot open load file" "quarry-module")))))
          (let ((err (should-error (quarry--ensure dir) :type 'user-error)))
            (should (string-match-p "Cannot load the quarry module" (cadr err)))
            (should (string-match-p "load-path" (cadr err))))
          (should-not (quarry--lookup dir)))
      (delete-directory dir t))))

;;;; Building and finding the module

(defun quarry-test--make-repo (&optional cargo-toml)
  "Create a temp repository with lisp/quarry.el; return its root.
Cargo.toml is created unless CARGO-TOML is the symbol `none'."
  (quarry-test--make-tree
   (append '("lisp/quarry.el")
           (unless (eq cargo-toml 'none) '("Cargo.toml")))))

(defun quarry-test--fake-cargo (dir exit-code &optional args-file sleep)
  "Write a fake cargo script into DIR and return its name.
It creates the release library in the --target-dir it is given and exits
with EXIT-CODE (without creating anything when that is not 0).  With
ARGS-FILE it records its arguments there; with SLEEP it first sleeps that
many seconds."
  (let ((script (expand-file-name "fake-cargo" dir))
        (library (file-name-nondirectory (quarry-build--library "/"))))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              (if args-file (format "echo \"$@\" > '%s'\n" args-file) "")
              (if sleep (format "sleep %s\n" sleep) "")
              "td=target\n"
              "while [ $# -gt 0 ]; do [ \"$1\" = --target-dir ] && td=$2; shift; done\n"
              (if (zerop exit-code)
                  (format "mkdir -p \"$td/release\" && echo built > \"$td/release/%s\"\n"
                          library)
                "echo 'error: distinctive failure line'\n")
              (format "exit %d\n" exit-code)))
    (set-file-modes script #o755)
    script))

(defmacro quarry-test--with-build (vars &rest body)
  "Run BODY with `load-path' reaching a symlinked quarry.el of a temp repo.
VARS is (REPO CARGO-DIR [CARGO-TOML]): REPO is bound to the repository
root and CARGO-DIR to a directory for fake programs.  The symlink lives
in a separate build directory, as with straight.  `quarry-build--file'
is nil, so the repository is found through `load-path'."
  (declare (indent 1))
  (let ((repo (nth 0 vars)) (cdir (nth 1 vars)) (build (make-symbol "build")))
    `(let* ((,repo (quarry-test--make-repo ,(nth 2 vars)))
            (,cdir (quarry-test--make-tree nil))
            (,build (quarry-test--make-tree nil))
            (quarry-build--file nil)
            (load-path (cons (directory-file-name ,build) load-path)))
       (unwind-protect
           (progn
             (make-symbolic-link (expand-file-name "lisp/quarry.el" ,repo)
                                 (expand-file-name "quarry.el" ,build))
             ,@body)
         (when (get-process quarry-build--buffer)
           (delete-process quarry-build--buffer))
         (when (get-buffer quarry-build--buffer)
           (let ((kill-buffer-query-functions nil))
             (kill-buffer quarry-build--buffer)))
         (delete-directory ,repo t)
         (delete-directory ,cdir t)
         (delete-directory ,build t)))))

(ert-deftest quarry-test-build-repo-through-symlink ()
  "The repository is found through a symlinked quarry.el."
  (quarry-test--with-build (repo cdir)
    (should (equal (file-truename (quarry-build--repo)) (file-truename repo)))
    (should (equal (quarry-build--module-file (quarry-build--repo))
                   (expand-file-name (concat "lisp/quarry-module" module-file-suffix)
                                     (quarry-build--repo))))))

(ert-deftest quarry-test-build-repo-without-cargo-toml ()
  (quarry-test--with-build (repo cdir 'none)
    (let ((err (should-error (quarry-build--repo) :type 'user-error)))
      (should (string-match-p "quarry source not found" (cadr err)))
      (should (string-match-p "README" (cadr err))))))

(ert-deftest quarry-test-build-sync-installs ()
  "A successful sync build installs the module file and returns non-nil."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0)))
      (should (quarry-build-module-sync))
      (let ((module (expand-file-name
                     (concat "lisp/quarry-module" module-file-suffix) repo)))
        (should (file-exists-p module))
        (should (equal (quarry--module-file) (file-truename module)))
        ;; No temporary file is left behind.
        (should (equal (directory-files (expand-file-name "lisp" repo) nil "\\`quarry-module")
                       (list (file-name-nondirectory module))))))))

(ert-deftest quarry-test-build-sync-failure-warns ()
  "A failing build leaves no module, warns and does not signal."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 1))
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type msg &rest _) (push (cons type msg) warnings))))
        (should-not (quarry-build-module-sync)))
      (should-not (file-exists-p (quarry-build--module-file repo)))
      (should (eq (caar warnings) 'quarry))
      (should (string-match-p "quarry-build-module" (cdar warnings))))))

(ert-deftest quarry-test-build-sync-missing-program ()
  "A missing cargo and a missing repository only warn."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program "quarry-no-such-program")
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type msg &rest _) (push (cons type msg) warnings))))
        (should-not (quarry-build-module-sync))
        (should (string-match-p "quarry-no-such-program" (cdar warnings)))
        (delete-file (expand-file-name "Cargo.toml" repo))
        (should-not (quarry-build-module-sync))
        (should (string-match-p "source not found" (cdar warnings)))
        (should (= (length warnings) 2))))))

(ert-deftest quarry-test-build-install-replaces-by-rename ()
  "Installing over an existing module file gives it a new inode."
  (quarry-test--with-build (repo cdir)
    (let* ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0))
           (module (quarry-build--module-file repo)))
      (write-region "old" nil module nil 'silent)
      (let ((inode (file-attribute-inode-number (file-attributes module))))
        (should (quarry-build-module-sync))
        (should-not (equal inode (file-attribute-inode-number
                                  (file-attributes module))))
        (should (equal (with-temp-buffer (insert-file-contents module)
                                         (string-trim (buffer-string)))
                       "built"))))))

(ert-deftest quarry-test-build-own-location-wins ()
  "The repository of quarry-build.el wins over another quarry.el on `load-path'."
  (quarry-test--with-build (repo cdir)
    (let* ((stale (quarry-test--make-tree '("lisp/quarry.el")))
           (load-path (cons (expand-file-name "lisp" stale) load-path))
           (own (expand-file-name "lisp/quarry-build.el" repo)))
      (unwind-protect
          (progn
            (write-region "" nil own nil 'silent)
            (let ((quarry-build--file nil))
              (should (equal (quarry-build--find-repo) (file-truename stale))))
            (let ((quarry-build--file own))
              (should (equal (quarry-build--find-repo) (file-truename repo)))
              (should (equal (file-truename (quarry-build--repo))
                             (file-truename repo)))))
        (delete-directory stale t)))))

(ert-deftest quarry-test-build-elc-sibling ()
  "A .elc in a build directory resolves to the repository of its .el symlink."
  (quarry-test--with-build (repo cdir)
    (let* ((other (quarry-test--make-tree nil))
           (stale (quarry-test--make-tree '("lisp/quarry.el")))
           (load-path (cons (expand-file-name "lisp" stale) load-path))
           (own (expand-file-name "lisp/quarry-build.el" repo))
           (quarry-build--file (expand-file-name "quarry-build.elc" other)))
      (unwind-protect
          (progn
            (write-region "" nil own nil 'silent)
            (write-region "" nil quarry-build--file nil 'silent)
            (make-symbolic-link own (expand-file-name "quarry-build.el" other))
            (should (equal (quarry-build--find-repo) (file-truename repo)))
            ;; Without the .el sibling, quarry.el on `load-path' is used.
            (delete-file (expand-file-name "quarry-build.el" other))
            (should (equal (quarry-build--find-repo) (file-truename stale))))
        (delete-directory other t)
        (delete-directory stale t)))))

(ert-deftest quarry-test-build-passes-target-dir ()
  "Both entry points pass an absolute --target-dir inside the repository."
  (quarry-test--with-build (repo cdir)
    (let* ((args (expand-file-name "args" cdir))
           (quarry-build-cargo-program (quarry-test--fake-cargo cdir 0 args))
           ;; The repository is found through a symlink, so cargo gets
           ;; its true name; on macOS the temporary directory is itself
           ;; below a symlink.
           (target (expand-file-name "target" (file-truename repo)))
           (module (quarry-build--module-file repo)))
      (should (quarry-build-module-sync))
      (let ((recorded (with-temp-buffer (insert-file-contents args) (buffer-string))))
        (should (string-match-p "--target-dir" recorded))
        (should (string-match-p (regexp-quote target) recorded)))
      (delete-file module)
      (delete-file args)
      (quarry-test--run-async)
      (let ((recorded (with-temp-buffer (insert-file-contents args) (buffer-string))))
        (should (string-match-p (regexp-quote (concat "--target-dir " target)) recorded)))
      (should (file-exists-p module)))))

(ert-deftest quarry-test-build-sync-batch-failure-shows-output ()
  "In batch mode the warning carries the cargo output."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 1))
          (noninteractive t)
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _) (push msg warnings))))
        (should-not (quarry-build-module-sync)))
      (should (string-match-p "distinctive failure line" (car warnings))))))

(ert-deftest quarry-test-build-recompile-installs ()
  "The finish hook installs for a rebuild in the build buffer."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0))
          (module (quarry-build--module-file repo)))
      (quarry-test--run-async)
      (should (file-exists-p module))
      (delete-file module)
      (cl-letf (((symbol-function 'message) #'ignore))
        ;; What `recompile' ends up doing when the new process exits.
        (run-hook-with-args 'compilation-finish-functions
                            (get-buffer quarry-build--buffer) "finished\n"))
      (should (file-exists-p module))
      ;; Other buffers and failures do not install.
      (delete-file module)
      (cl-letf (((symbol-function 'message) #'ignore))
        (run-hook-with-args 'compilation-finish-functions
                            (get-buffer quarry-build--buffer)
                            "exited abnormally with code 1\n")
        (with-temp-buffer
          (run-hook-with-args 'compilation-finish-functions
                              (current-buffer) "finished\n")))
      (should-not (file-exists-p module)))))

(ert-deftest quarry-test-build-recompile-command ()
  "`recompile' in the build buffer runs the build again and installs."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0))
          (module (quarry-build--module-file repo)))
      (quarry-test--run-async)
      (delete-file module)
      (cl-letf (((symbol-function 'message) #'ignore))
        (with-current-buffer quarry-build--buffer
          (recompile))
        (should (quarry-test--wait (lambda () (file-exists-p module)) 10))))))

(ert-deftest quarry-test-build-concurrent-signals ()
  "A second build while one runs signals a user-error."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0 nil 1))
          (proc nil))
      (cl-letf (((symbol-function 'message) #'ignore))
        (setq proc (quarry-build-module))
        (should (process-live-p proc))
        (let ((err (should-error (quarry-build-module) :type 'user-error)))
          (should (string-match-p "being built" (cadr err))))
        (should (quarry-test--wait (lambda () (not (process-live-p proc))) 10))))))

(ert-deftest quarry-test-offer-build-skips-prompt-while-building ()
  "No prompt is shown while a build runs."
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0 nil 1))
          (noninteractive nil)
          (proc nil))
      (cl-letf (((symbol-function 'message) #'ignore)
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (ert-fail "y-or-n-p called during a build"))))
        (setq proc (quarry-build-module))
        (let ((err (should-error (quarry--offer-build) :type 'user-error)))
          (should (string-match-p "is being built" (cadr err))))
        (should (quarry-test--wait (lambda () (not (process-live-p proc))) 10))))))

(ert-deftest quarry-test-start-module-load-failure-message ()
  "A module file that exists but fails to load is reported as such."
  (quarry-test--with-build (repo cdir)
    (write-region "" nil (quarry-build--module-file repo) nil 'silent)
    (cl-letf (((symbol-function 'emrs-load-module)
               (lambda (&rest _) (signal 'error '("bad module")))))
      (let ((err (should-error (quarry--start repo) :type 'user-error)))
        (should (string-match-p "Loading .*quarry-module.* failed: bad module" (cadr err)))
        (should (string-match-p "M-x quarry-build-module" (cadr err)))))))

(defun quarry-test--run-async (&optional wait)
  "Run `quarry-build-module', wait for the process; return the messages.
Wait for WAIT seconds at most (default 10)."
  (let ((msgs nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (let ((proc (quarry-build-module)))
        (should (quarry-test--wait (lambda () (not (process-live-p proc)))
                                    (or wait 10)))
        ;; The sentinel may run after the process has exited.
        (quarry-test--wait (lambda () msgs) 3)))
    (nreverse msgs)))

(ert-deftest quarry-test-build-async-installs ()
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 0)))
      (should (member "quarry module built" (quarry-test--run-async)))
      (should (file-exists-p (quarry-build--module-file repo)))
      (should (get-buffer quarry-build--buffer)))))

(ert-deftest quarry-test-build-async-failure ()
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program (quarry-test--fake-cargo cdir 1)))
      (should (cl-some (lambda (m) (string-match-p "build failed" m))
                       (quarry-test--run-async)))
      (should-not (file-exists-p (quarry-build--module-file repo))))))

(ert-deftest quarry-test-build-async-missing-program ()
  (quarry-test--with-build (repo cdir)
    (let ((quarry-build-cargo-program "quarry-no-such-program"))
      (let ((err (should-error (quarry-build-module) :type 'user-error)))
        (should (string-match-p "quarry-build-cargo-program" (cadr err)))))))

(ert-deftest quarry-test-start-module-lookup ()
  "`quarry--start' passes the module file when it exists, else nil."
  (quarry-test--with-build (repo cdir)
    (let ((loaded nil))
      (cl-letf (((symbol-function 'emrs-load-module)
                 (lambda (_name &optional file) (push file loaded) (signal 'error '("stop")))))
        (should-error (quarry--start repo) :type 'user-error)
        (should (equal loaded '(nil)))
        (write-region "" nil (quarry-build--module-file repo) nil 'silent)
        (should-error (quarry--start repo) :type 'user-error)
        (should (equal (car loaded)
                       (file-truename (quarry-build--module-file repo))))))))

(ert-deftest quarry-test-missing-module-offer ()
  "A missing module offers a build; yes starts it, no gives the hint."
  (quarry-test--with-build (repo cdir)
    (let ((built 0) (asked 0) (answer t) (noninteractive nil))
      (cl-letf (((symbol-function 'emrs-load-module)
                 (lambda (&rest _) (signal 'file-missing '("Cannot open load file" "quarry-module"))))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (cl-incf asked) answer))
                ((symbol-function 'quarry-build-module)
                 (lambda () (cl-incf built))))
        (let ((err (should-error (quarry--start repo) :type 'user-error)))
          (should (string-match-p "Building the quarry module" (cadr err)))
          (should (= built 1)))
        (setq answer nil)
        (let ((err (should-error (quarry--start repo) :type 'user-error)))
          (should (string-match-p "M-x quarry-build-module" (cadr err)))
          (should (string-match-p "load-path" (cadr err)))
          (should (= built 1))
          (should (= asked 2)))
        ;; Batch mode and a missing Cargo.toml do not ask.
        (setq noninteractive t)
        (should-error (quarry--start repo) :type 'user-error)
        (setq noninteractive nil)
        (delete-file (expand-file-name "Cargo.toml" repo))
        (should-error (quarry--start repo) :type 'user-error)
        (should (= asked 2))))))

(ert-deftest quarry-test-failed-instance-table ()
  "A table on a failed instance starts it once and reports it once."
  (let* ((dir (quarry-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (starts 0) (msgs nil) (queries 0))
    (advice-add 'quarry--start :before (lambda (&rest _) (cl-incf starts))
                '((name . quarry-test-count-start)))
    (advice-add 'quarry-query :before (lambda (&rest _) (cl-incf queries))
                '((name . quarry-test-count-query)))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
          (let ((table (quarry--table missing)))
            (dotimes (_ 4)
              (should (null (funcall table "x" nil t)))
              (should (null (funcall table "xy" nil nil))))
            (should (= starts 1))
            (should (= queries 1))
            ;; The warning of the instance's exit comes when the exit is
            ;; processed, which may be in here; in batch mode it is a
            ;; message too.
            (setq msgs (seq-filter (lambda (msg) (string-prefix-p "quarry: " msg)) msgs))
            (should (= (length msgs) 1))))
      (advice-remove 'quarry--start 'quarry-test-count-start)
      (advice-remove 'quarry-query 'quarry-test-count-query)
      (quarry-stop-all)
      (delete-directory dir t))))

(ert-deftest quarry-test-cache-instance-identity ()
  "A restarted instance does not hit the cache of the old one."
  (quarry-test--with-index dir
    (let ((calls 0)
          (table (quarry--table dir)))
      (advice-add 'quarry-query :before (lambda (&rest _) (cl-incf calls))
                  '((name . quarry-test-count)))
      (unwind-protect
          (progn
            (funcall table "main" nil t)
            (should (= calls 1))
            (let ((old (quarry--ensure dir)))
              (quarry--stop dir)
              (should (quarry-test--wait (lambda () (null (quarry--lookup dir)))))
              (let ((new (quarry--ensure dir)))
                (should-not (eq old new))
                (should-not (= (quarry--rec-id old) (quarry--rec-id new)))
                ;; Same epoch number on purpose.
                (setf (quarry--rec-epoch new) (quarry--rec-epoch old))
                (funcall table "main" nil t)
                (should (= calls 2)))))
        (advice-remove 'quarry-query 'quarry-test-count)))))

(ert-deftest quarry-test-cache-skips-indexing-replies ()
  (let ((calls 0)
        (rec (quarry--make-rec :root "/x/")))
    (cl-letf (((symbol-function 'quarry--ensure) (lambda (_) rec))
              ((symbol-function 'quarry-query)
               (lambda (&rest _)
                 (cl-incf calls)
                 (list :paths '("a") :positions nil :total 1 :indexing (< calls 3)))))
      (let ((table (quarry--table "/x/")))
        (funcall table "a" nil t)
        (funcall table "a" nil t)
        (should (= calls 2))
        ;; The third reply is complete and cached.
        (funcall table "a" nil t)
        (funcall table "a" nil t)
        (should (= calls 3))))))

(ert-deftest quarry-test-find-file-fallbacks ()
  (quarry-test--with-index dir
    (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
           (args nil))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                ((symbol-function 'project-find-file)
                 (lambda (&optional a) (push (list a) args))))
        (quarry-find-file t)
        (should (equal args '((t))))
        (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:x:")))
          (quarry-find-file nil))
        (should (equal args '((nil) (t))))))))

(ert-deftest quarry-test-mode-remap ()
  (let ((was quarry-mode))
    (unwind-protect
        (progn
          (quarry-mode 1)
          (should (eq (command-remapping 'project-find-file) 'quarry-find-file))
          (quarry-mode -1)
          (should-not (eq (command-remapping 'project-find-file) 'quarry-find-file)))
      (quarry-mode (if was 1 -1)))))

(ert-deftest quarry-test-mode-remap-option ()
  "The remap follows `quarry-find-file-command' without a mode restart.
`where-is' finds the key of the command it remaps to."
  (let ((was quarry-mode)
        (old-key (keymap-lookup global-map "C-x p f")))
    (unwind-protect
        (progn
          (keymap-global-set "C-x p f" #'project-find-file)
          (let ((quarry-find-file-command 'quarry-find-file))
            (quarry-mode 1)
            (should (eq (command-remapping 'project-find-file) 'quarry-find-file))
            (should (where-is-internal 'quarry-find-file))
            (setq quarry-find-file-command 'quarry-consult-find-file)
            (should (eq (command-remapping 'project-find-file)
                        'quarry-consult-find-file))
            (should (where-is-internal 'quarry-consult-find-file))
            (should-not (where-is-internal 'quarry-find-file))
            (setq quarry-find-file-command 'quarry-find-file)
            (should (eq (command-remapping 'project-find-file) 'quarry-find-file))
            (quarry-mode -1)
            ;; Set while the mode is off, the option applies when enabled.
            (setq quarry-find-file-command 'quarry-consult-find-file)
            (quarry-mode 1)
            (should (eq (command-remapping 'project-find-file)
                        'quarry-consult-find-file)))
          ;; Leaving the `let' restores the binding with the value.
          (should (eq (command-remapping 'project-find-file)
                      quarry-find-file-command)))
      (keymap-global-set "C-x p f" old-key)
      (quarry-mode (if was 1 -1)))))

;;;; project-files

(cl-defmethod project-root ((project (head quarry-test)))
  (cdr project))

(cl-defmethod project-files ((_project (head quarry-test)) &optional _dirs)
  "The next method in the tests: a marker nothing else returns."
  '("NEXT-METHOD"))

(defmacro quarry-test--counting-streams (var &rest body)
  "Run BODY with VAR counting the calls to `emrs-call-stream'."
  (declare (indent 1))
  `(let ((,var 0)
         (orig (symbol-function 'emrs-call-stream)))
     (cl-letf (((symbol-function 'emrs-call-stream)
                (lambda (&rest args) (cl-incf ,var) (apply orig args))))
       ,@body)))

(defun quarry-test--files-tree ()
  "Create a tree with ignore rules and hidden files; return its root."
  (let ((dir (quarry-test--make-tree
              '("a.txt" "src/main.rs" "src/deep/er/x.rs" "src/skip.log"
                "build/out.o" ".hidden" "docs/.dot/note.md" "größe/ü.txt"))))
    (write-region "build/\n*.log\n" nil (expand-file-name ".gitignore" dir) nil 'silent)
    dir))

(defconst quarry-test--files-expected
  '(".gitignore" ".hidden" "a.txt" "docs/.dot/note.md" "größe/ü.txt"
    "src/deep/er/x.rs" "src/main.rs"))

(ert-deftest quarry-test-project-files-inactive ()
  (let ((dir (quarry-test--files-tree)))
    (unwind-protect
        (let ((project (cons 'quarry-test dir)))
          (quarry--ensure dir)
          (emrs-call-sync (quarry--rec-instance (quarry--lookup dir)) '(:rescan) 10)
          (quarry-test--counting-streams n
            (let ((quarry-mode nil) (quarry-provide-project-files t))
              (should (equal (project-files project) '("NEXT-METHOD"))))
            (unwind-protect
                (progn
                  (quarry-mode 1)
                  (let ((quarry-provide-project-files nil))
                    (should (equal (project-files project) '("NEXT-METHOD")))))
              (quarry-mode -1))
            (should (= n 0))))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-project-files-active ()
  (let ((dir (quarry-test--files-tree)))
    (unwind-protect
        (let ((project (cons 'quarry-test dir))
              (quarry-provide-project-files t))
          (emrs-call-sync (quarry--rec-instance (quarry--ensure dir)) '(:rescan) 10)
          (unwind-protect
              (progn
                (quarry-mode 1)
                (let ((expected (sort (mapcar (lambda (f) (concat dir f))
                                              quarry-test--files-expected)
                                      #'string<)))
                  (should (equal (sort (project-files project) #'string<) expected))
                  ;; DIRS naming the root, in another spelling, is served too.
                  (should (equal (sort (project-files project (list (directory-file-name dir)))
                                       #'string<)
                                 expected))
                  (quarry-test--counting-streams n
                    ;; Other directories and extra DIRS go to the next method.
                    (should (equal (project-files project (list (concat dir "src/")))
                                   '("NEXT-METHOD")))
                    (should (equal (project-files project (list dir (concat dir "src/")))
                                   '("NEXT-METHOD")))
                    (should (= n 0)))))
            (quarry-mode -1)))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-project-files-stopping ()
  "While an instance is stopping, `project-files' uses the next method."
  (let ((dir (quarry-test--files-tree)))
    (unwind-protect
        (let ((quarry-provide-project-files t))
          (emrs-call-sync (quarry--rec-instance (quarry--ensure dir)) '(:rescan) 10)
          (unwind-protect
              (progn
                (quarry-mode 1)
                (quarry--stop dir)
                (should (eq (emrs-instance-state (quarry--rec-instance (quarry--lookup dir)))
                            'stopping))
                (should (equal (project-files (cons 'quarry-test dir)) '("NEXT-METHOD")))
                ;; The same when the state changes after the applicability check.
                (cl-letf (((symbol-function 'quarry--files-applicable-p)
                           (lambda (&rest _) (quarry--lookup dir))))
                  (should (equal (project-files (cons 'quarry-test dir))
                                 '("NEXT-METHOD")))))
            (quarry-mode -1)))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-project-files-no-instance ()
  (let ((dir (quarry-test--files-tree)))
    (unwind-protect
        (let ((quarry-provide-project-files t))
          (unwind-protect
              (progn
                (quarry-mode 1)
                (quarry-test--counting-streams n
                  (should (equal (project-files (cons 'quarry-test dir))
                                 '("NEXT-METHOD")))
                  (should (= n 0))
                  (should-not (quarry--lookup dir))
                  (should (zerop (hash-table-count quarry--instances)))))
            (quarry-mode -1)))
      (delete-directory dir t))))

(ert-deftest quarry-test-project-files-timeout ()
  "A timeout cancels the call and falls back to the next method.
The wait reads only the module, so another process's filter does not
run inside `project-files'."
  (let ((dir (quarry-test--files-tree))
        (cancelled nil)
        (other nil)
        (filtered nil))
    (unwind-protect
        (let ((quarry-provide-project-files t)
              (quarry-files-timeout 0.2)
              (started (float-time)))
          (quarry--ensure dir)
          (unwind-protect
              (progn
                (quarry-mode 1)
                ;; A stream whose batches and end reach nobody, so the
                ;; wait can only time out.
                (cl-letf* ((stream (symbol-function 'emrs-call-stream))
                           (cancel (symbol-function 'emrs-cancel))
                           ((symbol-function 'emrs-call-stream)
                            (lambda (instance request &rest _)
                              (funcall stream instance request
                                       :on-batch #'ignore :on-end #'ignore)))
                           ((symbol-function 'emrs-cancel)
                            (lambda (call)
                              (push call cancelled)
                              (funcall cancel call))))
                  (setq other (make-process
                               :name "quarry-test-other" :noquery t
                               :command '("sh" "-c" "echo hi; sleep 5")
                               :filter (lambda (_proc _string) (setq filtered t))))
                  (should (equal (project-files (cons 'quarry-test dir))
                                 '("NEXT-METHOD")))
                  (should (= (length cancelled) 1))
                  ;; Its output arrived during the wait and is read only now.
                  (should-not filtered)
                  (should (quarry-test--wait (lambda () filtered) 3))
                  (should (>= (- (float-time) started) 0.2))))
            (quarry-mode -1)))
      (when other (delete-process other))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-core-loads-alone ()
  "quarry-core.el loads without quarry.el and defines `quarry--load-module'."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (file-name-directory (locate-library "quarry-core")))
         (emrs (file-name-directory (locate-library "emrs")))
         (out (generate-new-buffer " *quarry-core-alone*")))
    (unwind-protect
        (let ((status (call-process
                       emacs nil out nil "--batch" "-Q"
                       "-L" lisp "-L" emrs
                       "--eval"
                       (concat "(progn (require 'quarry-core)"
                               " (kill-emacs (if (and (not (featurep 'quarry))"
                               " (fboundp 'quarry--load-module)) 0 1)))"))))
          (should (equal (list status (with-current-buffer out (buffer-string)))
                         (list 0 (with-current-buffer out (buffer-string))))))
      (kill-buffer out))))

(provide 'quarry-tests)
;;; quarry-tests.el ends here
