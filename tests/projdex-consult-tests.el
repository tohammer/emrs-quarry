;;; projdex-consult-tests.el --- ERT suite for projdex-consult  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh, which loads tests/projdex-tests.el first;
;; its helpers are used here.  The tests that need consult are skipped
;; when consult 2.0 or later is not on `load-path' (see
;; PROJDEX_TEST_LOAD_PATH in run-ert.sh).

;;; Code:

(require 'ert)
(require 'projdex)
(require 'projdex-tests)
(require 'consult nil t)
(require 'projdex-consult)

(defvar consult-async-split-style)

(defun projdex-test-consult--consult-p ()
  "Return non-nil when consult 2.0 or later is loaded."
  (fboundp 'consult--async-pipeline))

;;;; The step, with a recording sink

(defun projdex-test-consult--step (root log)
  "Return the step for ROOT on a sink that pushes each action to LOG.
LOG is a symbol; its value lists the actions, newest first."
  (set log nil)
  (funcall (projdex-consult--async root)
           (lambda (action) (push action (symbol-value log)) nil)))

(defvar projdex-test-consult--log nil
  "Actions the recording sink received, newest first.")

(defun projdex-test-consult--finished-p ()
  "Return non-nil when the sink got an indicator other than running."
  (seq-find (lambda (a) (and (vectorp a) (not (equal a [indicator running]))))
            projdex-test-consult--log))

(ert-deftest projdex-test-consult-step-candidates ()
  "An input yields flush, projdex's highlighted candidates in order, finished."
  (projdex-test--with-index dir
    (let ((step (projdex-test-consult--step dir 'projdex-test-consult--log))
          (reply (projdex-query dir "rs" projdex-limit t)))
      (should (null (funcall step "rs")))
      (should (equal projdex-test-consult--log '([indicator running])))
      (should (projdex-test--wait #'projdex-test-consult--finished-p))
      (let ((log (reverse projdex-test-consult--log)))
        (should (equal (length log) 4))
        (should (equal (nth 0 log) [indicator running]))
        (should (eq (nth 1 log) 'flush))
        (should (equal (nth 3 log) [indicator finished]))
        ;; The same strings as `projdex--table' returns, faces included.
        (should (equal-including-properties
                 (nth 2 log)
                 (cl-mapcar #'projdex--highlight (plist-get reply :paths)
                            (plist-get reply :positions) (plist-get reply :groups))))
        (should (member "src/main.rs" (nth 2 log)))
        (should (projdex-test--faces-at (car (nth 2 log)))))
      ;; The same input again sends nothing; other actions pass on.
      (setq projdex-test-consult--log nil)
      (funcall step "rs")
      (funcall step 'refresh)
      (funcall step nil)
      (should (equal projdex-test-consult--log '(nil refresh))))))

(ert-deftest projdex-test-consult-step-plain-candidates ()
  "Without highlighting the candidates are plain copies of the paths."
  (projdex-test--with-index dir
    (let ((projdex-highlight nil)
          (step (projdex-test-consult--step dir 'projdex-test-consult--log)))
      (funcall step "main")
      (should (projdex-test--wait #'projdex-test-consult--finished-p))
      (let ((cands (nth 1 projdex-test-consult--log)))
        (should (equal-including-properties cands '("src/main.rs")))))))

(ert-deftest projdex-test-consult-step-supersede ()
  "A superseded input is cancelled and shows nothing; destroy cancels."
  (projdex-test--with-index dir
    (let ((calls nil)
          (cancelled nil))
      (advice-add 'projdex-query-async :filter-return
                  (lambda (call) (push call calls) call)
                  '((name . projdex-test-consult-calls)))
      (advice-add 'emrs-cancel :before (lambda (call) (push call cancelled))
                  '((name . projdex-test-consult-cancel)))
      (unwind-protect
          (let ((step (projdex-test-consult--step dir 'projdex-test-consult--log)))
            ;; No process output is read between the two inputs.
            (funcall step "main")
            (funcall step "lib")
            (should (projdex-test--wait #'projdex-test-consult--finished-p))
            ;; A reply to the first call would come in this time.
            (projdex-test--wait #'ignore 0.3)
            (should (equal (reverse projdex-test-consult--log)
                           '([indicator running] [indicator running]
                             flush ("src/lib.rs") [indicator finished])))
            (should (= (length calls) 2))
            (should (equal cancelled (list (cadr calls))))
            (should (emrs-call-done (cadr calls)))
            ;; destroy cancels the pending call and passes on.
            (setq projdex-test-consult--log nil)
            (funcall step "src")
            (funcall step 'destroy)
            (should (eq (car cancelled) (car calls)))
            (projdex-test--wait #'ignore 0.3)
            (should (equal (reverse projdex-test-consult--log)
                           '([indicator running] destroy)))
            ;; cancel too, and the same input then queries again.
            (setq projdex-test-consult--log nil)
            (funcall step "src")
            (funcall step 'cancel)
            (should (eq (car cancelled) (car calls)))
            (funcall step "src")
            (should (= (length calls) 5))
            (should (projdex-test--wait #'projdex-test-consult--finished-p))
            (should (equal (nth 1 projdex-test-consult--log)
                           (plist-get (projdex-query dir "src" projdex-limit) :paths))))
        (advice-remove 'projdex-query-async 'projdex-test-consult-calls)
        (advice-remove 'emrs-cancel 'projdex-test-consult-cancel)))))

;;;; Re-query while indexing

(defmacro projdex-test-consult--with-fake-replies (indexing &rest body)
  "Run BODY with `projdex-query-async' answering from a timer.
Reply N (counted from 1 in `queries', with the texts in `texts') has
the path \"fN\" and `:indexing' as (funcall INDEXING N) says."
  (declare (indent 1))
  `(let ((queries 0)
         (texts nil)
         (projdex-consult-refresh-interval 0.01))
     (ignore texts)
     (cl-letf (((symbol-function 'projdex-query-async)
                (lambda (_root text _limit _positions callback)
                  (let ((n (cl-incf queries)))
                    (push text texts)
                    (run-at-time 0 nil callback
                                 (list :paths (list (format "f%d" n))
                                       :indexing (funcall ,indexing n))
                                 nil)
                    (list 'fake-call n))))
               ((symbol-function 'emrs-cancel) #'ignore))
       ,@body)))

(ert-deftest projdex-test-consult-requery-while-indexing ()
  "The step re-sends the input until a reply says indexing ended."
  (projdex-test-consult--with-fake-replies (lambda (n) (< n 4))
    (let ((step (projdex-test-consult--step "/x/" 'projdex-test-consult--log)))
      (funcall step "a")
      (should (projdex-test--wait (lambda () (>= queries 4))))
      (projdex-test--wait #'ignore 0.3)
      (should (= queries 4))
      (should (equal texts '("a" "a" "a" "a")))
      (let ((log (reverse projdex-test-consult--log)))
        ;; Each flush is followed by the new candidates: no empty list
        ;; is shown in between.
        (should (equal (cl-loop for (a b) on log when (eq a 'flush) collect b)
                       '(("f1") ("f2") ("f3") ("f4"))))
        (should (equal (car (last log)) [indicator finished]))))))

(ert-deftest projdex-test-consult-requery-stops-on-destroy ()
  (projdex-test-consult--with-fake-replies (lambda (_) t)
    (let ((step (projdex-test-consult--step "/x/" 'projdex-test-consult--log)))
      (funcall step "a")
      (should (projdex-test--wait (lambda () (>= queries 2))))
      (funcall step 'destroy)
      (let ((seen queries))
        (projdex-test--wait #'ignore 0.3)
        (should (= queries seen))
        (should (eq (car projdex-test-consult--log) 'destroy))))))

;;;; Failure

(ert-deftest projdex-test-consult-step-failed-instance ()
  "A failed instance during the prompt is reported once and shows nothing."
  (let* ((dir (projdex-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (msgs nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) msgs)))
                  ((symbol-function 'display-warning) #'ignore))
          (let ((step (projdex-test-consult--step missing 'projdex-test-consult--log)))
            (funcall step "x")
            (should (projdex-test--wait
                     (lambda () (member [indicator failed] projdex-test-consult--log))))
            ;; The failure arrives as a reply or, when the module
            ;; already knows it, is signalled by `emrs-call'.
            (should (equal (seq-take projdex-test-consult--log 2)
                           '([indicator failed] flush)))
            (should-not (seq-find #'consp projdex-test-consult--log))
            ;; A later input queries again, on a new instance.
            (setq projdex-test-consult--log nil)
            (funcall step "xy")
            (should (projdex-test--wait
                     (lambda () (member [indicator failed] projdex-test-consult--log))))
            (should (equal (seq-take projdex-test-consult--log 2)
                           '([indicator failed] flush)))
            (should-not (seq-find #'consp projdex-test-consult--log))
            (should (= (length msgs) 1))
            (should (string-prefix-p "projdex: " (car msgs)))
            (should (> (length (car msgs)) (length "projdex: ")))))
      (projdex-stop-all)
      (projdex-test--wait (lambda () (zerop (hash-table-count projdex--instances))) 3)
      (delete-directory dir t))))

(ert-deftest projdex-test-consult-step-signalling-start ()
  "An error signalled when sending the query is caught and reported once."
  (let ((msgs nil))
    (cl-letf (((symbol-function 'projdex-query-async)
               (lambda (&rest _) (user-error "Cannot load the projdex module")))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (let ((step (projdex-test-consult--step "/x/" 'projdex-test-consult--log)))
        (should (null (funcall step "a")))
        (funcall step "ab")
        (should (equal (reverse projdex-test-consult--log)
                       '(flush [indicator failed] flush [indicator failed])))
        (should (equal msgs '("Cannot load the projdex module")))))
    ;; An instance known to be gone is reported like `projdex-query' does.
    (setq msgs nil)
    (cl-letf (((symbol-function 'projdex-query-async)
               (lambda (&rest _)
                 (signal 'emrs-error '(stopped "the instance is not running" nil))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (funcall (projdex-test-consult--step "/x/" 'projdex-test-consult--log) "a")
      (should (equal msgs '("projdex: the instance is not running"))))))

;;;; End to end through `consult--read'

(defvar projdex-test-consult--answered nil
  "Inputs whose reply the step has handled, newest first.")

(defvar projdex-test-consult--queries 0
  "Number of queries sent through `projdex-test-consult--track'.")

(defvar projdex-test-consult--done nil
  "Numbers of the queries whose reply the step has handled.")

(defun projdex-test-consult--track (orig root text limit positions callback)
  "Call ORIG with ROOT, TEXT, LIMIT, POSITIONS and a wrapped CALLBACK.
The wrapper records replies, not cancellations, in
`projdex-test-consult--answered' and `projdex-test-consult--done'."
  (let ((n (cl-incf projdex-test-consult--queries)))
    (funcall orig root text limit positions
             (lambda (reply err)
               (funcall callback reply err)
               (unless (eq (plist-get err :kind) 'cancelled)
                 (push text projdex-test-consult--answered)
                 (push n projdex-test-consult--done))))))

(defun projdex-test-consult--settle ()
  "Wait until the step has handled the reply for the minibuffer input.
Keyboard macros do not let timers or process output run; this command
does, so consult's input timers fire and the reply comes in.  It waits
for the input timers first, then for the reply to the last query."
  (interactive)
  (projdex-test--wait #'ignore
                      (* 3 (+ projdex-consult-input-debounce
                              projdex-consult-input-throttle)))
  (projdex-test--wait (lambda () (memq projdex-test-consult--queries
                                       projdex-test-consult--done))))

(defun projdex-test-consult--select-first ()
  "Replace the minibuffer input with the first candidate, as a UI's RET."
  (interactive)
  (let ((first (car (all-completions "" minibuffer-completion-table))))
    (delete-minibuffer-contents)
    (when first (insert (substring-no-properties first)))))

(defvar projdex-test-consult--seen nil
  "Inputs and their candidates recorded by `projdex-test-consult--record'.")

(defun projdex-test-consult--record ()
  "Record the input and the candidates the completion styles show."
  (interactive)
  (let* ((s (minibuffer-contents))
         (all (completion-all-completions s minibuffer-completion-table
                                          minibuffer-completion-predicate
                                          (length s))))
    (when all (setcdr (last all) nil))
    (push (list (substring-no-properties s) all) projdex-test-consult--seen)))

(defun projdex-test-consult--find-file-with-keys (dir keys)
  "Run `projdex-consult-find-file' in project DIR typing KEYS.
In the prompt, C-c w waits for the reply to the input, C-c s selects the
first candidate and C-c t records the candidates.  Return the visited
file."
  (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
         (map (define-keymap
                "C-c w" #'projdex-test-consult--settle
                "C-c s" #'projdex-test-consult--select-first
                "C-c t" #'projdex-test-consult--record))
         (minibuffer-setup-hook minibuffer-setup-hook)
         (buf nil))
    (add-hook 'minibuffer-setup-hook
              (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
              90)
    (setq projdex-test-consult--answered nil
          projdex-test-consult--queries 0
          projdex-test-consult--done nil
          projdex-test-consult--seen nil)
    (advice-add 'projdex-query-async :around #'projdex-test-consult--track)
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
      (unwind-protect
          (progn
            (execute-kbd-macro (kbd (concat "M-x projdex-consult-find-file RET " keys)))
            (setq buf (current-buffer))
            (buffer-file-name buf))
        (advice-remove 'projdex-query-async #'projdex-test-consult--track)
        (when buf (kill-buffer buf))))))

(ert-deftest projdex-test-consult-find-file-visits ()
  "The chosen candidate is visited."
  (skip-unless (projdex-test-consult--consult-p))
  (projdex-test--with-index dir
    (let ((prompts nil)
          (minibuffer-setup-hook minibuffer-setup-hook))
      (add-hook 'minibuffer-setup-hook (lambda () (push (minibuffer-prompt) prompts)))
      (should (equal (projdex-test-consult--find-file-with-keys
                      dir "main C-c w C-c s RET")
                     (concat dir "src/main.rs")))
      (should (equal (car prompts)
                     (format "Find file in %s: "
                             (file-name-nondirectory (directory-file-name dir)))))
      (should (member "main" projdex-test-consult--answered))
      (should (equal (car projdex-consult-history) "src/main.rs")))))

(ert-deftest projdex-test-consult-find-file-keeps-projdex-results ()
  "With an orderless-like style, the candidates are exactly projdex's."
  (skip-unless (projdex-test-consult--consult-p))
  (projdex-test--with-index dir
    (let ((completion-styles-alist
           (cons '(projdex-test-greedy projdex-test--greedy-try
                                       projdex-test--greedy-all "")
                 completion-styles-alist))
          (completion-styles '(projdex-test-greedy))
          (completion-category-defaults nil)
          (consult-async-split-style 'none))
      (projdex-test-consult--find-file-with-keys
       dir (concat "zzzqqq C-c w C-c t DEL DEL DEL DEL DEL DEL "
                   "rs C-c w C-c t C-c s RET"))
      (let ((seen (reverse projdex-test-consult--seen)))
        (should (equal (nth 0 seen) '("zzzqqq" nil)))
        (should (equal (car (nth 1 seen)) "rs"))
        (should (equal (cadr (nth 1 seen))
                       (plist-get (projdex-query dir "rs" projdex-limit) :paths)))
        (should (projdex-test--faces-at (car (cadr (nth 1 seen))))))
      ;; Other prompts keep the user's styles.
      (should (equal completion-styles '(projdex-test-greedy))))))

(ert-deftest projdex-test-consult-find-file-failed-root ()
  "A root the service cannot index signals before any prompt opens."
  (skip-unless (projdex-test-consult--consult-p))
  (let* ((dir (projdex-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (project-find-functions (list (lambda (_) (list 'transient missing))))
         (prompts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                  ((symbol-function 'consult--read)
                   (lambda (&rest _) (cl-incf prompts) nil)))
          (let ((err (should-error (projdex-consult-find-file) :type 'user-error)))
            (should (string-prefix-p "projdex: " (cadr err))))
          (should (= prompts 0)))
      (projdex-stop-all)
      (delete-directory dir t))))

(ert-deftest projdex-test-consult-find-file-fallbacks ()
  (skip-unless (projdex-test-consult--consult-p))
  (projdex-test--with-index dir
    (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
           (args nil))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                ((symbol-function 'project-find-file)
                 (lambda (&optional a) (push (list a) args))))
        (projdex-consult-find-file t)
        (should (equal args '((t))))
        (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:x:")))
          (projdex-consult-find-file nil))
        (should (equal args '((nil) (t))))))))

;;;; Without consult

(ert-deftest projdex-test-consult-without-consult ()
  "Without consult, projdex-consult.el loads and compiles; the command says why not."
  (let* ((tmp (file-name-as-directory (make-temp-file "projdex-consult" t)))
         (file (expand-file-name "projdex-consult.el" tmp))
         (form
          `(progn
             ;; Drop any directory that holds consult, e.g. site-lisp.
             (setq load-path
                   (delq nil (mapcar (lambda (d)
                                       (unless (locate-file "consult" (list d)
                                                            '(".el" ".elc"))
                                         d))
                                     load-path)))
             (require 'projdex-consult)
             (when (featurep 'consult) (error "consult was loaded"))
             (setq byte-compile-error-on-warn t)
             (unless (byte-compile-file ,file) (error "Compiling failed"))
             (load (concat ,file "c") nil t)
             (condition-case err
                 (progn (projdex-consult-find-file)
                        (error "No user-error"))
               (user-error
                (unless (string-match-p "consult 2\\.0" (cadr err))
                  (error "Wrong user-error: %S" err))))
             (kill-emacs 0))))
    (copy-file (locate-library "projdex-consult.el") file)
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil t nil "--batch" "-Q"
                         "-L" tmp
                         "-L" (file-name-directory (locate-library "projdex"))
                         "-L" (file-name-directory (locate-library "emrs"))
                         "--eval" (prin1-to-string form))))
            (should (equal (list status (buffer-string)) (list 0 (buffer-string))))))
      (delete-directory tmp t))))

(provide 'projdex-consult-tests)
;;; projdex-consult-tests.el ends here
