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

(provide 'projdex-tests)
;;; projdex-tests.el ends here
