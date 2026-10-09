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

(provide 'projdex-tests)
;;; projdex-tests.el ends here
