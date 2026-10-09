;;; projdex-tests.el --- ERT suite for projdex  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh.

;;; Code:

(require 'ert)
(require 'projdex)

(ert-deftest projdex-test-loads ()
  "projdex.el and emrs.el load."
  (should (featurep 'projdex))
  (should (featurep 'emrs)))

;; The module must be installed as projdex-module on `load-path'
;; (tests/run-ert.sh does that).

(defun projdex-test--make-tree (files)
  "Create a temporary directory holding FILES (relative paths); return it."
  (let ((dir (file-name-as-directory (make-temp-file "projdex-test" t))))
    (dolist (file files)
      (let ((path (expand-file-name file dir)))
        (make-directory (file-name-directory path) t)
        (write-region "" nil path nil 'silent)))
    dir))

(ert-deftest projdex-test-service-round-trip ()
  "The module loads; rescan, status and query return the documented plists."
  (let* ((dir (projdex-test--make-tree '("src/main.rs" "src/lib.rs" "README.md")))
         (inst nil))
    (unwind-protect
        (progn
          (setq inst (emrs-start 'projdex "projdex" (list :root dir)))
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

(defun projdex-test--wait (pred &optional seconds)
  "Wait up to SECONDS (default 10) until PRED returns non-nil; return it."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defmacro projdex-test--with-roots (bindings &rest body)
  "Bind each (VAR FILES) in BINDINGS to a temp tree, run BODY, clean up."
  (declare (indent 1))
  `(let ,(mapcar (lambda (b) `(,(car b) (projdex-test--make-tree ,(cadr b)))) bindings)
     (unwind-protect (progn ,@body)
       (projdex-stop-all)
       (let ((gone (projdex-test--wait
                    (lambda () (zerop (hash-table-count projdex--instances))) 3)))
         ,@(mapcar (lambda (b) `(delete-directory ,(car b) t)) bindings)
         (should gone)))))

(ert-deftest projdex-test-one-instance-per-root ()
  (projdex-test--with-roots ((a '("a.txt")) (b '("b.txt")))
    (let ((ra (projdex--ensure a)))
      (should (eq ra (projdex--ensure a)))
      ;; A non-normalized spelling of the same root finds the same record.
      (should (eq ra (projdex--ensure (directory-file-name a))))
      (let ((rb (projdex--ensure b)))
        (should-not (eq ra rb))
        (should-not (eq (projdex--rec-instance ra) (projdex--rec-instance rb)))
        (should (= (hash-table-count projdex--instances) 2))))))

(ert-deftest projdex-test-stop-and-stop-all ()
  (projdex-test--with-roots ((a '("a.txt")) (b '("b.txt")))
    (let ((ra (projdex--ensure a)))
      (projdex--ensure b)
      (projdex--stop a)
      (should (projdex-test--wait (lambda () (null (projdex--lookup a)))))
      (should (eq (emrs-instance-state (projdex--rec-instance ra)) 'stopped))
      (should (projdex--lookup b))
      ;; The next use starts a new instance.
      (should-not (eq ra (projdex--ensure a)))
      (projdex-stop-all)
      (should (projdex-test--wait
               (lambda () (zerop (hash-table-count projdex--instances))))))))

(ert-deftest projdex-test-query ()
  (projdex-test--with-roots ((dir '("src/main.rs" "src/lib.rs" "README.md")))
    (emrs-call-sync (projdex--rec-instance (projdex--ensure dir)) '(:rescan) 10)
    (should (equal (projdex-query dir "main" 10 t)
                   '(:paths ("src/main.rs") :positions ((4 5 6 7))
                     :groups ((0 0 0 0)) :total 1 :indexing nil)))
    ;; `projdex-match-style' applies to queries.
    (should (equal (plist-get (projdex-query dir "smn" 10) :paths)
                   '("src/main.rs")))
    (let ((projdex-match-style 'substring))
      (should (null (plist-get (projdex-query dir "smn" 10) :paths)))
      (should (equal (plist-get (projdex-query dir "'smn" 10) :paths)
                     '("src/main.rs")))
      (should (equal (plist-get (projdex-query dir "ai rs" 10 t) :groups)
                     '((0 0 1 1)))))
    (should (equal (plist-get (projdex-query dir "rs" 1) :total) 2))
    (should (= (length (plist-get (projdex-query dir "rs" 1) :paths)) 1))))

(ert-deftest projdex-test-indexed-event ()
  (projdex-test--with-roots ((dir '("a" "b" "c")))
    (let ((rec (projdex--ensure dir)))
      (should (projdex-test--wait (lambda () (> (projdex--rec-epoch rec) 0))))
      (should (= (projdex--rec-files rec) 3))
      (should-not (projdex--rec-indexing rec)))))

(ert-deftest projdex-test-synthetic-events ()
  (let ((rec (projdex--make-rec :root "/x/" :files 10 :watching t))
        (warnings 0))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (projdex--on-event rec '(:indexed :files 5 :millis 3))
      (should (= (projdex--rec-files rec) 5))
      (should (= (projdex--rec-epoch rec) 1))
      (projdex--on-event rec '(:changed :added 4 :removed 1))
      (should (= (projdex--rec-files rec) 8))
      (should (= (projdex--rec-epoch rec) 2))
      (projdex--on-event rec '(:watch-failed :message "boom"))
      (projdex--on-event rec '(:watch-failed :message "again"))
      (should-not (projdex--rec-watching rec))
      (should (= warnings 1)))))

(ert-deftest projdex-test-exit-removes-only-own-record ()
  (let* ((old (projdex--make-rec :root "/x/"))
         (new (projdex--make-rec :root "/x/")))
    (puthash "/x/" new projdex--instances)
    (unwind-protect
        (progn (projdex--on-exit old 'stopped nil)
               (should (eq (gethash "/x/" projdex--instances) new))
               (projdex--on-exit new 'stopped nil)
               (should-not (gethash "/x/" projdex--instances)))
      (remhash "/x/" projdex--instances))))

(ert-deftest projdex-test-failing-start ()
  (let* ((dir (projdex-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir))))
    (unwind-protect
        (progn
          (should-error (projdex-query missing "x" 10) :type 'user-error)
          (should (projdex-test--wait (lambda () (null (projdex--lookup missing)))))
          ;; A second attempt starts afresh and fails the same way.
          (should-error (projdex-query missing "x" 10) :type 'user-error)
          (should (null (projdex--lookup missing))))
      (projdex-stop-all)
      (delete-directory dir t))))

(ert-deftest projdex-test-query-async ()
  (projdex-test--with-roots ((dir '("src/main.rs" "README.md")))
    (let ((result 'none))
      (emrs-call-sync (projdex--rec-instance (projdex--ensure dir)) '(:rescan) 10)
      (projdex-query-async dir "main" 10 nil
                           (lambda (reply err) (setq result (list reply err))))
      (should (projdex-test--wait (lambda () (not (eq result 'none)))))
      (should (null (cadr result)))
      (should (equal (plist-get (car result) :paths) '("src/main.rs"))))))

(ert-deftest projdex-test-status-and-rescan ()
  (projdex-test--with-roots ((dir '("a" "b")))
    (let ((msgs nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (projdex--rescan dir)
        (should (projdex-test--wait (lambda () msgs)))
        (should (string-match-p "2 files" (car msgs)))
        (should (string-match-p "2 files, indexing no" (projdex--status dir)))))))

;;;; Completion table, style, finder

(defconst projdex-test--files
  '("src/main.rs" "src/lib.rs" "README.md" "docs/ünï/größe.txt" "a/b/foo_bar.el" "foobar.el")
  "Files of the completion test tree.")

(defmacro projdex-test--with-index (var &rest body)
  "Run BODY with VAR bound to an indexed temp tree."
  (declare (indent 1))
  `(projdex-test--with-roots ((,var projdex-test--files))
     (emrs-call-sync (projdex--rec-instance (projdex--ensure ,var)) '(:rescan) 10)
     ,@body))

(defun projdex-test--faces-at (string &optional face)
  "Return the indices of STRING that carry FACE.
Without FACE, any face of `projdex-match-faces'."
  (cl-loop for i below (length string)
           for faces = (ensure-list (get-text-property i 'face string))
           when (if face (memq face faces)
                  (seq-intersection faces projdex-match-faces))
           collect i))

(ert-deftest projdex-test-table-basics ()
  (projdex-test--with-index dir
    (let ((table (projdex--table dir)))
      (should (equal (funcall table "" nil 'metadata)
                     '(metadata (category . project-file)
                                (display-sort-function . identity)
                                (cycle-sort-function . identity))))
      (should (equal (funcall table "main" nil t) '("src/main.rs")))
      (should (equal (funcall table "rs$" nil t) (quote ("src/lib.rs" "src/main.rs"))))
      (should (equal (funcall table "" (lambda (p) (string-suffix-p ".md" p)) t)
                     '("README.md")))
      (should (equal (funcall table "" nil t)
                     (plist-get (projdex-query dir "" 200) :paths)))
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

(ert-deftest projdex-test-table-limit ()
  (projdex-test--with-index dir
    (let ((projdex-limit 2))
      (should (= (length (funcall (projdex--table dir) "" nil t)) 2)))))

(ert-deftest projdex-test-style-keeps-rust-order ()
  (projdex-test--with-index dir
    (let* ((completion-styles '(projdex))
           ;; The table's category has its own default styles.
           (completion-category-overrides '((project-file (styles projdex))))
           (table (projdex--table dir))
           (expected (plist-get (projdex-query dir "foobar" 200) :paths))
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

(ert-deftest projdex-test-highlighting ()
  (projdex-test--with-index dir
    (let* ((table (projdex--table dir))
           (reply (projdex-query dir "main" 10 t))
           (paths (funcall table "main" nil t)))
      (should (equal (projdex-test--faces-at (car paths))
                     (car (plist-get reply :positions))))
      (should (equal (projdex-test--faces-at (car paths)) '(4 5 6 7)))
      ;; Non-ASCII: indices are characters.
      (let* ((p (car (funcall table "größe" nil t)))
             (pos (car (plist-get (projdex-query dir "größe" 10 t) :positions))))
        (should (equal p "docs/ünï/größe.txt"))
        (should (equal (projdex-test--faces-at p) pos))
        (should (equal (mapcar (lambda (i) (aref p i)) pos)
                       (string-to-list "größe"))))
      ;; Cached originals are not mutated: a repeated call is identical and
      ;; highlighting off yields plain strings from the same cache epoch.
      (should (equal-including-properties (funcall table "main" nil t) paths))
      (let ((projdex-highlight nil))
        (should (null (projdex-test--faces-at
                       (car (funcall table "main" nil t))))))
      ;; One face per term, in turn; negated terms get none.
      (let ((p (car (funcall table "'rs !zz 'ai 'c 'm 'n" nil t))))
        (should (equal p "src/main.rs"))
        ;; The fifth term, n, wraps around to the first face.
        (should (equal (projdex-test--faces-at p 'projdex-match-0) '(7 9 10)))
        (should (equal (projdex-test--faces-at p 'projdex-match-1) '(5 6)))
        (should (equal (projdex-test--faces-at p 'projdex-match-2) '(2)))
        (should (equal (projdex-test--faces-at p 'projdex-match-3) '(4))))
      (let ((projdex-match-faces '(completions-common-part)))
        (should (equal (projdex-test--faces-at
                        (car (funcall table "ai rs" nil t)) 'completions-common-part)
                       '(5 6 9 10))))
      (should (equal (projdex-test--faces-at
                      (car (funcall table "main" nil t)))
                     '(4 5 6 7)))
      (should-not (get-text-property 0 'face (car (plist-get (projdex-query dir "main" 10) :paths))))
      ;; A UI that adds properties in place does not corrupt the cache,
      ;; with highlighting and without.
      (let ((str (car (funcall table "main" nil t))))
        (put-text-property 0 (length str) 'face 'bold str)
        (should (equal (projdex-test--faces-at (car (funcall table "main" nil t)))
                       '(4 5 6 7)))
        (should-not (memq 'bold (ensure-list
                                 (get-text-property 0 'face (car (funcall table "main" nil t)))))))
      (let ((projdex-highlight nil)
            (table (projdex--table dir)))
        (let ((str (car (funcall table "main" nil t))))
          (put-text-property 0 (length str) 'face 'bold str))
        (should-not (get-text-property 0 'face (car (funcall table "main" nil t))))))))

(ert-deftest projdex-test-cache ()
  (projdex-test--with-index dir
    (let ((calls 0)
          (table (projdex--table dir))
          (rec (projdex--ensure dir)))
      (advice-add 'projdex-query :before (lambda (&rest _) (cl-incf calls))
                  '((name . projdex-test-count)))
      (unwind-protect
          (progn
            (funcall table "main" nil t)
            (funcall table "main" nil nil)
            (funcall table "main" nil 'lambda)
            (should (= calls 1))
            (funcall table "lib" nil t)
            (should (= calls 2))
            (cl-incf (projdex--rec-epoch rec))
            (funcall table "main" nil t)
            (should (= calls 3)))
        (advice-remove 'projdex-query 'projdex-test-count)))))

(ert-deftest projdex-test-cache-invalidation-synthetic ()
  (projdex-test--with-index dir
    (let ((table (projdex--table dir))
          (rec (projdex--ensure dir)))
      (should-not (funcall table "newfile" nil t))
      (write-region "" nil (expand-file-name "newfile.txt" dir) nil 'silent)
      (emrs-call-sync (projdex--rec-instance rec) '(:rescan) 10)
      (projdex--on-event rec '(:changed :added 1 :removed 0))
      (should (equal (funcall table "newfile" nil t) '("newfile.txt"))))))

(ert-deftest projdex-test-cache-invalidation-watcher ()
  :tags '(watcher)
  (projdex-test--with-roots ((dir '("a.txt")))
    (let* ((rec (projdex--ensure dir))
           (table (projdex--table dir)))
      (should (projdex-test--wait (lambda () (> (projdex--rec-epoch rec) 0))))
      (should-not (funcall table "newfile" nil t))
      (let ((epoch (projdex--rec-epoch rec)))
        (write-region "" nil (expand-file-name "newfile.txt" dir) nil 'silent)
        (unless (projdex-test--wait (lambda () (> (projdex--rec-epoch rec) epoch)))
          (ert-fail "No :changed event: this test needs a working file watcher (inotify, FSEvents or ReadDirectoryChanges)"))
        (should (equal (funcall table "newfile" nil t) '("newfile.txt")))))))

(ert-deftest projdex-test-table-timeout ()
  (let ((msgs nil)
        (table nil))
    (cl-letf (((symbol-function 'projdex--ensure)
               (lambda (_) (projdex--make-rec :root "/x/")))
              ((symbol-function 'projdex-query)
               (lambda (&rest _) (signal 'emrs-error '(timeout "slow"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (setq table (projdex--table "/x/"))
      (should (null (funcall table "a" nil t)))
      (should (null (funcall table "ab" nil t)))
      (should (= (length msgs) 1)))))

(ert-deftest projdex-test-find-file-round-trip ()
  (projdex-test--with-index dir
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
                  (execute-kbd-macro (kbd "M-x projdex-find-file RET src/main.rs RET")))
                (should (equal (car seen) (list (format "Find file in %s: "
                                                  (project-name (project-current)))
                                          'projdex))))
              (setq buf (current-buffer))
              (should (equal (buffer-file-name buf)
                             (expand-file-name "src/main.rs" dir))))
          (when buf (kill-buffer buf)))))))

(defun projdex-test--find-file-while-indexing (dir fake)
  "Run `projdex-find-file' in DIR; the first FAKE `:status' replies say
indexing with no files.  Return (FAKE-LEFT SHOWN): the fake replies
not used up when the prompt opened, and the candidates for empty input."
  (let ((project-find-functions (list (lambda (_) (list 'transient dir))))
        (call-sync (symbol-function 'projdex--call-sync))
        (left nil)
        (shown nil)
        (buf nil))
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
              ((symbol-function 'projdex--call-sync)
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
            (projdex-find-file)
            (setq buf (current-buffer))
            (list left shown))
        (when buf (kill-buffer buf))))))

(ert-deftest projdex-test-find-file-waits-for-first-page ()
  "The prompt of a new instance opens once its index has files to show.
UIs ask for the empty input once and do not refresh while indexing runs."
  (projdex-test--with-roots ((dir '("a.txt" "b.txt")))
    (pcase-let ((`(,left ,shown) (projdex-test--find-file-while-indexing dir 3)))
      (should (= left 0))
      (should (equal (sort shown #'string<) '("a.txt" "b.txt"))))))

(ert-deftest projdex-test-find-file-first-page-wait-is-capped ()
  "An index that stays empty does not hold the prompt back for long."
  (projdex-test--with-roots ((dir '("a.txt")))
    (let ((projdex--first-page-wait 0.2)
          (start (float-time)))
      (pcase-let ((`(,left ,_) (projdex-test--find-file-while-indexing dir 1000)))
        (should (> left 0))
        (should (< (- (float-time) start) 2))))))

(defun projdex-test--find-file-with-keys (dir keys)
  "Run `projdex-find-file' in project DIR typing KEYS; return the visited file."
  (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
         (buf nil))
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
      (unwind-protect
          (progn
            (execute-kbd-macro (kbd (concat "M-x projdex-find-file RET " keys)))
            (setq buf (current-buffer))
            (buffer-file-name buf))
        (when buf (kill-buffer buf))))))

(ert-deftest projdex-test-ui-unique-match ()
  "TAB completes a unique match and RET accepts the completion."
  (projdex-test--with-index dir
    (let* ((contents nil)
           (orig (symbol-function 'completing-read))
           )
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest args)
                   (setq contents (apply orig args)))))
      ;; TAB completes `main' to the only candidate; RET visits it.
      (should (equal (projdex-test--find-file-with-keys dir "main TAB RET")
                     (concat dir "src/main.rs")))
      (should (equal contents "src/main.rs"))
      ;; `confirm' makes the first RET ask for confirmation and the
      ;; second accept the input as typed; `projdex-find-file' then
      ;; resolves it to the unique match instead of <root>/main.
      (setq contents nil)
      (should (equal (projdex-test--find-file-with-keys dir "main RET RET")
                     (concat dir "src/main.rs")))
      (should (equal contents "main"))
      ;; Input matching several files is visited as typed.
      (should (equal (projdex-test--find-file-with-keys dir "rs$ RET RET")
                     (concat dir "rs$")))))))

;; A style like orderless: asks the table for all candidates of the
;; empty prefix and relies on `completion-regexp-list' to filter them.
(defun projdex-test--greedy-all (_string table pred _point)
  (let ((all (all-completions "" table pred)))
    (and all (nconc all 0))))

(defun projdex-test--greedy-try (_string _table _pred _point) nil)

(ert-deftest projdex-test-ui-no-match-shows-nothing ()
  "No match gives no candidates, whatever the user's `completion-styles'."
  (projdex-test--with-index dir
    (let* ((completion-styles-alist
            (cons '(projdex-test-greedy projdex-test--greedy-try
                                        projdex-test--greedy-all "")
                  completion-styles-alist))
           (completion-styles '(projdex-test-greedy))
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
      (projdex-test--find-file-with-keys dir "zzzqqq C-c t DEL DEL DEL DEL DEL DEL main C-c t RET")
      (should (equal (nth 1 seen) '("zzzqqq" (projdex) nil)))
      (should (equal (car (nth 0 seen)) "main"))
      (should (equal (car (nth 2 (nth 0 seen))) "src/main.rs"))
      ;; Other prompts keep the user's styles.
      (should (equal completion-styles '(projdex-test-greedy))))))

(ert-deftest projdex-test-ui-fido-keeps-projdex-style ()
  "fido-mode's setup does not replace the projdex style."
  (projdex-test--with-index dir
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
              (projdex-test--find-file-with-keys dir "src/main.rs RET")))
        (fido-mode (if fido 1 -1)))
      (should (equal (car seen) '(projdex))))))

(ert-deftest projdex-test-ui-multiple-matches-keep-input ()
  (projdex-test--with-index dir
    (let ((table (projdex--table dir)))
      (should (equal (funcall table "rs$" nil nil) "rs$"))
      (should (equal (completion-try-completion "rs$" table nil 3) '("rs$" . 3))))))

(ert-deftest projdex-test-find-file-tilde-directory ()
  "An index path starting with a `~' directory stays below the root."
  (let ((dir (projdex-test--make-tree '("a.txt"))))
    (make-directory (concat dir "~/") t)
    (write-region "" nil (concat dir "~/x") nil 'silent)
    (unwind-protect
        (progn
          (emrs-call-sync (projdex--rec-instance (projdex--ensure dir)) '(:rescan) 10)
          (let ((file (projdex-test--find-file-with-keys dir "~/x RET")))
            (should (equal file (concat dir "~/x")))
            (should (string-prefix-p dir file))))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(ert-deftest projdex-test-find-file-failed-root ()
  "A project root the service cannot index gives a `user-error'."
  (let* ((dir (projdex-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (project-find-functions (list (lambda (_) (list 'transient missing)))))
    (unwind-protect
        (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
          (let ((err (should-error (projdex-find-file) :type 'user-error)))
            (should (string-prefix-p "projdex: " (cadr err)))
            (should (> (length (cadr err)) (length "projdex: ")))))
      (projdex-stop-all)
      (delete-directory dir t))))

(ert-deftest projdex-test-module-not-found ()
  (let ((dir (projdex-test--make-tree nil)))
    (unwind-protect
        (cl-letf (((symbol-function 'emrs-load-module)
                   (lambda (&rest _) (signal 'file-missing '("Cannot open load file" "projdex-module")))))
          (let ((err (should-error (projdex--ensure dir) :type 'user-error)))
            (should (string-match-p "Cannot load the projdex module" (cadr err)))
            (should (string-match-p "load-path" (cadr err))))
          (should-not (projdex--lookup dir)))
      (delete-directory dir t))))

;;;; Building and finding the module

(defun projdex-test--make-repo (&optional cargo-toml)
  "Create a temp repository with lisp/projdex.el; return its root.
Cargo.toml is created unless CARGO-TOML is the symbol `none'."
  (projdex-test--make-tree
   (append '("lisp/projdex.el")
           (unless (eq cargo-toml 'none) '("Cargo.toml")))))

(defun projdex-test--fake-cargo (dir exit-code)
  "Write a fake cargo script into DIR and return its name.
It creates the release library in the current directory and exits with
EXIT-CODE (without creating anything when that is not 0)."
  (let ((script (expand-file-name "fake-cargo" dir))
        (library (file-relative-name (projdex-build--library "/") "/")))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              (if (zerop exit-code)
                  (format "mkdir -p %s && echo built > %s\n"
                          (file-name-directory library) library)
                "echo 'error: build failed'\n")
              (format "exit %d\n" exit-code)))
    (set-file-modes script #o755)
    script))

(defmacro projdex-test--with-build (vars &rest body)
  "Run BODY with `load-path' reaching a symlinked projdex.el of a temp repo.
VARS is (REPO CARGO-DIR [CARGO-TOML]): REPO is bound to the repository
root and CARGO-DIR to a directory for fake programs.  The symlink lives
in a separate build directory, as with straight."
  (declare (indent 1))
  (let ((repo (nth 0 vars)) (cdir (nth 1 vars)) (build (make-symbol "build")))
    `(let* ((,repo (projdex-test--make-repo ,(nth 2 vars)))
            (,cdir (projdex-test--make-tree nil))
            (,build (projdex-test--make-tree nil))
            (load-path (cons (directory-file-name ,build) load-path)))
       (make-symbolic-link (expand-file-name "lisp/projdex.el" ,repo)
                           (expand-file-name "projdex.el" ,build))
       (unwind-protect (progn ,@body)
         (when (get-buffer projdex-build--buffer)
           (kill-buffer projdex-build--buffer))
         (delete-directory ,repo t)
         (delete-directory ,cdir t)
         (delete-directory ,build t)))))

(ert-deftest projdex-test-build-repo-through-symlink ()
  "The repository is found through a symlinked projdex.el."
  (projdex-test--with-build (repo cdir)
    (should (equal (file-truename (projdex-build--repo)) (file-truename repo)))
    (should (equal (projdex-build--module-file (projdex-build--repo))
                   (expand-file-name (concat "lisp/projdex-module" module-file-suffix)
                                     (projdex-build--repo))))))

(ert-deftest projdex-test-build-repo-without-cargo-toml ()
  (projdex-test--with-build (repo cdir 'none)
    (let ((err (should-error (projdex-build--repo) :type 'user-error)))
      (should (string-match-p "projdex source not found" (cadr err)))
      (should (string-match-p "README" (cadr err))))))

(ert-deftest projdex-test-build-sync-installs ()
  "A successful sync build installs the module file and returns non-nil."
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program (projdex-test--fake-cargo cdir 0)))
      (should (projdex-build-module-sync))
      (let ((module (expand-file-name
                     (concat "lisp/projdex-module" module-file-suffix) repo)))
        (should (file-exists-p module))
        (should (equal (projdex--module-file) (file-truename module)))
        ;; No temporary file is left behind.
        (should (equal (directory-files (expand-file-name "lisp" repo) nil "\\`projdex-module")
                       (list (file-name-nondirectory module))))))))

(ert-deftest projdex-test-build-sync-failure-warns ()
  "A failing build leaves no module, warns and does not signal."
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program (projdex-test--fake-cargo cdir 1))
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type msg &rest _) (push (cons type msg) warnings))))
        (should-not (projdex-build-module-sync)))
      (should-not (file-exists-p (projdex-build--module-file repo)))
      (should (eq (caar warnings) 'projdex))
      (should (string-match-p "projdex-build-module" (cdar warnings))))))

(ert-deftest projdex-test-build-sync-missing-program ()
  "A missing cargo and a missing repository only warn."
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program "projdex-no-such-program")
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type msg &rest _) (push (cons type msg) warnings))))
        (should-not (projdex-build-module-sync))
        (should (string-match-p "projdex-no-such-program" (cdar warnings)))
        (delete-file (expand-file-name "Cargo.toml" repo))
        (should-not (projdex-build-module-sync))
        (should (string-match-p "source not found" (cdar warnings)))
        (should (= (length warnings) 2))))))

(ert-deftest projdex-test-build-install-replaces-by-rename ()
  "Installing over an existing module file gives it a new inode."
  (projdex-test--with-build (repo cdir)
    (let* ((projdex-build-cargo-program (projdex-test--fake-cargo cdir 0))
           (module (projdex-build--module-file repo)))
      (write-region "old" nil module nil 'silent)
      (let ((inode (file-attribute-inode-number (file-attributes module))))
        (should (projdex-build-module-sync))
        (should-not (equal inode (file-attribute-inode-number
                                  (file-attributes module))))
        (should (equal (with-temp-buffer (insert-file-contents module)
                                         (string-trim (buffer-string)))
                       "built"))))))

(defun projdex-test--run-async (&optional wait)
  "Run `projdex-build-module', wait for the process; return the messages.
Wait for WAIT seconds at most (default 10)."
  (let ((msgs nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (let ((proc (projdex-build-module)))
        (should (projdex-test--wait (lambda () (not (process-live-p proc)))
                                    (or wait 10)))
        ;; The sentinel may run after the process has exited.
        (projdex-test--wait (lambda () msgs) 3)))
    (nreverse msgs)))

(ert-deftest projdex-test-build-async-installs ()
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program (projdex-test--fake-cargo cdir 0)))
      (should (member "projdex module built" (projdex-test--run-async)))
      (should (file-exists-p (projdex-build--module-file repo)))
      (should (get-buffer projdex-build--buffer)))))

(ert-deftest projdex-test-build-async-failure ()
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program (projdex-test--fake-cargo cdir 1)))
      (should (cl-some (lambda (m) (string-match-p "build failed" m))
                       (projdex-test--run-async)))
      (should-not (file-exists-p (projdex-build--module-file repo))))))

(ert-deftest projdex-test-build-async-missing-program ()
  (projdex-test--with-build (repo cdir)
    (let ((projdex-build-cargo-program "projdex-no-such-program"))
      (let ((err (should-error (projdex-build-module) :type 'user-error)))
        (should (string-match-p "projdex-build-cargo-program" (cadr err)))))))

(ert-deftest projdex-test-start-module-lookup ()
  "`projdex--start' passes the module file when it exists, else nil."
  (projdex-test--with-build (repo cdir)
    (let ((loaded nil))
      (cl-letf (((symbol-function 'emrs-load-module)
                 (lambda (_name &optional file) (push file loaded) (signal 'error '("stop")))))
        (should-error (projdex--start repo) :type 'user-error)
        (should (equal loaded '(nil)))
        (write-region "" nil (projdex-build--module-file repo) nil 'silent)
        (should-error (projdex--start repo) :type 'user-error)
        (should (equal (car loaded)
                       (file-truename (projdex-build--module-file repo))))))))

(ert-deftest projdex-test-missing-module-offer ()
  "A missing module offers a build; yes starts it, no gives the hint."
  (projdex-test--with-build (repo cdir)
    (let ((built 0) (asked 0) (answer t) (noninteractive nil))
      (cl-letf (((symbol-function 'emrs-load-module)
                 (lambda (&rest _) (signal 'file-missing '("Cannot open load file" "projdex-module"))))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (cl-incf asked) answer))
                ((symbol-function 'projdex-build-module)
                 (lambda () (cl-incf built))))
        (let ((err (should-error (projdex--start repo) :type 'user-error)))
          (should (string-match-p "Building the projdex module" (cadr err)))
          (should (= built 1)))
        (setq answer nil)
        (let ((err (should-error (projdex--start repo) :type 'user-error)))
          (should (string-match-p "M-x projdex-build-module" (cadr err)))
          (should (string-match-p "load-path" (cadr err)))
          (should (= built 1))
          (should (= asked 2)))
        ;; Batch mode and a missing Cargo.toml do not ask.
        (setq noninteractive t)
        (should-error (projdex--start repo) :type 'user-error)
        (setq noninteractive nil)
        (delete-file (expand-file-name "Cargo.toml" repo))
        (should-error (projdex--start repo) :type 'user-error)
        (should (= asked 2))))))

(ert-deftest projdex-test-failed-instance-table ()
  "A table on a failed instance starts it once and reports it once."
  (let* ((dir (projdex-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (starts 0) (msgs nil) (queries 0))
    (advice-add 'projdex--start :before (lambda (&rest _) (cl-incf starts))
                '((name . projdex-test-count-start)))
    (advice-add 'projdex-query :before (lambda (&rest _) (cl-incf queries))
                '((name . projdex-test-count-query)))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
          (let ((table (projdex--table missing)))
            (dotimes (_ 4)
              (should (null (funcall table "x" nil t)))
              (should (null (funcall table "xy" nil nil))))
            (should (= starts 1))
            (should (= queries 1))
            (should (= (length msgs) 1))
            (should (string-prefix-p "projdex: " (car msgs)))))
      (advice-remove 'projdex--start 'projdex-test-count-start)
      (advice-remove 'projdex-query 'projdex-test-count-query)
      (projdex-stop-all)
      (delete-directory dir t))))

(ert-deftest projdex-test-cache-instance-identity ()
  "A restarted instance does not hit the cache of the old one."
  (projdex-test--with-index dir
    (let ((calls 0)
          (table (projdex--table dir)))
      (advice-add 'projdex-query :before (lambda (&rest _) (cl-incf calls))
                  '((name . projdex-test-count)))
      (unwind-protect
          (progn
            (funcall table "main" nil t)
            (should (= calls 1))
            (let ((old (projdex--ensure dir)))
              (projdex--stop dir)
              (should (projdex-test--wait (lambda () (null (projdex--lookup dir)))))
              (let ((new (projdex--ensure dir)))
                (should-not (eq old new))
                (should-not (= (projdex--rec-id old) (projdex--rec-id new)))
                ;; Same epoch number on purpose.
                (setf (projdex--rec-epoch new) (projdex--rec-epoch old))
                (funcall table "main" nil t)
                (should (= calls 2)))))
        (advice-remove 'projdex-query 'projdex-test-count)))))

(ert-deftest projdex-test-cache-skips-indexing-replies ()
  (let ((calls 0)
        (rec (projdex--make-rec :root "/x/")))
    (cl-letf (((symbol-function 'projdex--ensure) (lambda (_) rec))
              ((symbol-function 'projdex-query)
               (lambda (&rest _)
                 (cl-incf calls)
                 (list :paths '("a") :positions nil :total 1 :indexing (< calls 3)))))
      (let ((table (projdex--table "/x/")))
        (funcall table "a" nil t)
        (funcall table "a" nil t)
        (should (= calls 2))
        ;; The third reply is complete and cached.
        (funcall table "a" nil t)
        (funcall table "a" nil t)
        (should (= calls 3))))))

(ert-deftest projdex-test-find-file-fallbacks ()
  (projdex-test--with-index dir
    (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
           (args nil))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                ((symbol-function 'project-find-file)
                 (lambda (&optional a) (push (list a) args))))
        (projdex-find-file t)
        (should (equal args '((t))))
        (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:x:")))
          (projdex-find-file nil))
        (should (equal args '((nil) (t))))))))

(ert-deftest projdex-test-mode-remap ()
  (let ((was projdex-mode))
    (unwind-protect
        (progn
          (projdex-mode 1)
          (should (eq (command-remapping 'project-find-file) 'projdex-find-file))
          (projdex-mode -1)
          (should-not (eq (command-remapping 'project-find-file) 'projdex-find-file)))
      (projdex-mode (if was 1 -1)))))

;;;; project-files

(cl-defmethod project-root ((project (head projdex-test)))
  (cdr project))

(cl-defmethod project-files ((_project (head projdex-test)) &optional _dirs)
  "The next method in the tests: a marker nothing else returns."
  '("NEXT-METHOD"))

(defmacro projdex-test--counting-streams (var &rest body)
  "Run BODY with VAR counting the calls to `emrs-call-stream'."
  (declare (indent 1))
  `(let ((,var 0)
         (orig (symbol-function 'emrs-call-stream)))
     (cl-letf (((symbol-function 'emrs-call-stream)
                (lambda (&rest args) (cl-incf ,var) (apply orig args))))
       ,@body)))

(defun projdex-test--files-tree ()
  "Create a tree with ignore rules and hidden files; return its root."
  (let ((dir (projdex-test--make-tree
              '("a.txt" "src/main.rs" "src/deep/er/x.rs" "src/skip.log"
                "build/out.o" ".hidden" "docs/.dot/note.md" "größe/ü.txt"))))
    (write-region "build/\n*.log\n" nil (expand-file-name ".gitignore" dir) nil 'silent)
    dir))

(defconst projdex-test--files-expected
  '(".gitignore" ".hidden" "a.txt" "docs/.dot/note.md" "größe/ü.txt"
    "src/deep/er/x.rs" "src/main.rs"))

(ert-deftest projdex-test-project-files-inactive ()
  (let ((dir (projdex-test--files-tree)))
    (unwind-protect
        (let ((project (cons 'projdex-test dir)))
          (projdex--ensure dir)
          (emrs-call-sync (projdex--rec-instance (projdex--lookup dir)) '(:rescan) 10)
          (projdex-test--counting-streams n
            (let ((projdex-mode nil) (projdex-provide-project-files t))
              (should (equal (project-files project) '("NEXT-METHOD"))))
            (unwind-protect
                (progn
                  (projdex-mode 1)
                  (let ((projdex-provide-project-files nil))
                    (should (equal (project-files project) '("NEXT-METHOD")))))
              (projdex-mode -1))
            (should (= n 0))))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(ert-deftest projdex-test-project-files-active ()
  (let ((dir (projdex-test--files-tree)))
    (unwind-protect
        (let ((project (cons 'projdex-test dir))
              (projdex-provide-project-files t))
          (emrs-call-sync (projdex--rec-instance (projdex--ensure dir)) '(:rescan) 10)
          (unwind-protect
              (progn
                (projdex-mode 1)
                (let ((expected (sort (mapcar (lambda (f) (concat dir f))
                                              projdex-test--files-expected)
                                      #'string<)))
                  (should (equal (sort (project-files project) #'string<) expected))
                  ;; DIRS naming the root, in another spelling, is served too.
                  (should (equal (sort (project-files project (list (directory-file-name dir)))
                                       #'string<)
                                 expected))
                  (projdex-test--counting-streams n
                    ;; Other directories and extra DIRS go to the next method.
                    (should (equal (project-files project (list (concat dir "src/")))
                                   '("NEXT-METHOD")))
                    (should (equal (project-files project (list dir (concat dir "src/")))
                                   '("NEXT-METHOD")))
                    (should (= n 0)))))
            (projdex-mode -1)))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(ert-deftest projdex-test-project-files-stopping ()
  "While an instance is stopping, `project-files' uses the next method."
  (let ((dir (projdex-test--files-tree)))
    (unwind-protect
        (let ((projdex-provide-project-files t))
          (emrs-call-sync (projdex--rec-instance (projdex--ensure dir)) '(:rescan) 10)
          (unwind-protect
              (progn
                (projdex-mode 1)
                (projdex--stop dir)
                (should (eq (emrs-instance-state (projdex--rec-instance (projdex--lookup dir)))
                            'stopping))
                (should (equal (project-files (cons 'projdex-test dir)) '("NEXT-METHOD")))
                ;; The same when the state changes after the applicability check.
                (cl-letf (((symbol-function 'projdex--files-applicable-p)
                           (lambda (&rest _) (projdex--lookup dir))))
                  (should (equal (project-files (cons 'projdex-test dir))
                                 '("NEXT-METHOD")))))
            (projdex-mode -1)))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(ert-deftest projdex-test-project-files-no-instance ()
  (let ((dir (projdex-test--files-tree)))
    (unwind-protect
        (let ((projdex-provide-project-files t))
          (unwind-protect
              (progn
                (projdex-mode 1)
                (projdex-test--counting-streams n
                  (should (equal (project-files (cons 'projdex-test dir))
                                 '("NEXT-METHOD")))
                  (should (= n 0))
                  (should-not (projdex--lookup dir))
                  (should (zerop (hash-table-count projdex--instances)))))
            (projdex-mode -1)))
      (delete-directory dir t))))

(ert-deftest projdex-test-project-files-timeout ()
  (let ((dir (projdex-test--files-tree))
        (cancelled nil))
    (unwind-protect
        (let ((projdex-provide-project-files t)
              (projdex-files-timeout 0.2)
              (started (float-time)))
          (projdex--ensure dir)
          (unwind-protect
              (progn
                (projdex-mode 1)
                (cl-letf (((symbol-function 'emrs-call-stream)
                           (lambda (&rest _) 'dummy-call))
                          ((symbol-function 'emrs-cancel)
                           (lambda (call) (push call cancelled))))
                  (should (equal (project-files (cons 'projdex-test dir))
                                 '("NEXT-METHOD")))
                  (should (equal cancelled '(dummy-call)))
                  (should (>= (- (float-time) started) 0.2))))
            (projdex-mode -1)))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(provide 'projdex-tests)
;;; projdex-tests.el ends here
