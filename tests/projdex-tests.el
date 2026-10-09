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
            (should-not (plist-get status :watching))
            (should (>= (plist-get status :walks) 1))
            (should (equal (plist-get status :skipped) 0))
            (should (equal (length status) 12)))
          (should (equal (emrs-call-sync
                          inst '(:query :text "main" :limit 10 :positions t) 10)
                         '(:paths ("src/main.rs") :positions ((4 5 6 7))
                           :total 1 :indexing nil)))
          ;; :limit and :positions are optional.
          (should (equal (emrs-call-sync inst '(:query :text "rs") 10)
                         '(:paths ("src/lib.rs" "src/main.rs") :positions nil
                           :total 2 :indexing nil))))
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
       (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
       ,@(mapcar (lambda (b) `(delete-directory ,(car b) t)) bindings))))

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
                     :total 1 :indexing nil)))
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

(defun projdex-test--faces-at (string)
  "Return the indices of STRING that carry `completions-common-part'."
  (cl-loop for i below (length string)
           when (memq 'completions-common-part
                      (ensure-list (get-text-property i 'face string)))
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
      (should (equal (funcall table "main" nil nil) "main"))
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
      (should (equal (completion-try-completion "main" table nil 4) '("main" . 4)))
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
      (should (equal (projdex-test--faces-at
                      (car (funcall table "main" nil t)))
                     '(4 5 6 7)))
      (should-not (get-text-property 0 'face (car (plist-get (projdex-query dir "main" 10) :paths)))))))

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
        (should (projdex-test--wait (lambda () (> (projdex--rec-epoch rec) epoch))))
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

(provide 'projdex-tests)
;;; projdex-tests.el ends here
