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

(provide 'projdex-tests)
;;; projdex-tests.el ends here
