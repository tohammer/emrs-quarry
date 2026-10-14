;;; quarry-consult-tests.el --- ERT suite for quarry-consult  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh, which loads tests/quarry-tests.el first;
;; its helpers are used here.  The tests that need consult are skipped
;; when consult 2.0 or later is not on `load-path' (see
;; QUARRY_TEST_LOAD_PATH in run-ert.sh).

;;; Code:

(require 'ert)
(require 'quarry)
(require 'quarry-tests)
(require 'consult nil t)
(require 'quarry-consult)

(defvar consult-async-split-style)
(defvar consult-async-split-styles-alist)

(defun quarry-test-consult--consult-p ()
  "Return non-nil when consult 2.0 or later is loaded."
  (fboundp 'consult--async-pipeline))

;;;; The step, with a recording sink

(defun quarry-test-consult--step (root log)
  "Return the step for ROOT on a sink that pushes each action to LOG.
LOG is a symbol; its value lists the actions, newest first."
  (set log nil)
  (funcall (quarry-consult--async root)
           (lambda (action) (push action (symbol-value log)) nil)))

(defvar quarry-test-consult--log nil
  "Actions the recording sink received, newest first.")

(defun quarry-test-consult--finished-p ()
  "Return non-nil when the sink got an indicator other than running."
  (seq-find (lambda (a) (and (vectorp a) (not (equal a [indicator running]))))
            quarry-test-consult--log))

(ert-deftest quarry-test-consult-step-candidates ()
  "An input yields flush, quarry's highlighted candidates in order, finished."
  (quarry-test--with-index dir
    (let ((step (quarry-test-consult--step dir 'quarry-test-consult--log))
          (reply (quarry-query dir "rs" quarry-limit t)))
      (should (null (funcall step "rs")))
      (should (equal quarry-test-consult--log '([indicator running])))
      (should (quarry-test--wait #'quarry-test-consult--finished-p))
      (let ((log (reverse quarry-test-consult--log)))
        (should (equal (length log) 4))
        (should (equal (nth 0 log) [indicator running]))
        (should (eq (nth 1 log) 'flush))
        (should (equal (nth 3 log) [indicator finished]))
        ;; The same strings as `quarry--table' returns, faces included.
        (should (equal-including-properties
                 (nth 2 log)
                 (cl-mapcar #'quarry--highlight (plist-get reply :paths)
                            (plist-get reply :positions) (plist-get reply :groups))))
        (should (member "src/main.rs" (nth 2 log)))
        (should (quarry-test--faces-at (car (nth 2 log)))))
      ;; The same input again sends nothing; other actions pass on.
      (setq quarry-test-consult--log nil)
      (funcall step "rs")
      (funcall step 'refresh)
      (funcall step nil)
      (should (equal quarry-test-consult--log '(nil refresh))))))

(ert-deftest quarry-test-consult-step-plain-candidates ()
  "Without highlighting the candidates are plain copies of the paths."
  (quarry-test--with-index dir
    (let ((quarry-highlight nil)
          (step (quarry-test-consult--step dir 'quarry-test-consult--log)))
      (funcall step "main")
      (should (quarry-test--wait #'quarry-test-consult--finished-p))
      (let ((cands (nth 1 quarry-test-consult--log)))
        (should (equal-including-properties cands '("src/main.rs")))))))

(ert-deftest quarry-test-consult-step-supersede ()
  "A superseded input is cancelled and shows nothing; destroy cancels."
  (quarry-test--with-index dir
    (let ((calls nil)
          (cancelled nil))
      (advice-add 'quarry-query-async :filter-return
                  (lambda (call) (push call calls) call)
                  '((name . quarry-test-consult-calls)))
      (advice-add 'emrs-cancel :before (lambda (call) (push call cancelled))
                  '((name . quarry-test-consult-cancel)))
      (unwind-protect
          (let ((step (quarry-test-consult--step dir 'quarry-test-consult--log)))
            ;; No process output is read between the two inputs.
            (funcall step "main")
            (funcall step "lib")
            (should (quarry-test--wait #'quarry-test-consult--finished-p))
            ;; A reply to the first call would come in this time.
            (quarry-test--wait #'ignore 0.3)
            (should (equal (reverse quarry-test-consult--log)
                           '([indicator running] [indicator running]
                             flush ("src/lib.rs") [indicator finished])))
            (should (= (length calls) 2))
            (should (equal cancelled (list (cadr calls))))
            (should (emrs-call-done (cadr calls)))
            ;; destroy cancels the pending call and passes on.
            (setq quarry-test-consult--log nil)
            (funcall step "src")
            (funcall step 'destroy)
            (should (eq (car cancelled) (car calls)))
            (quarry-test--wait #'ignore 0.3)
            (should (equal (reverse quarry-test-consult--log)
                           '([indicator running] destroy)))
            ;; cancel too, and the same input then queries again.
            (setq quarry-test-consult--log nil)
            (funcall step "src")
            (funcall step 'cancel)
            (should (eq (car cancelled) (car calls)))
            (funcall step "src")
            (should (= (length calls) 5))
            (should (quarry-test--wait #'quarry-test-consult--finished-p))
            (should (equal (nth 1 quarry-test-consult--log)
                           (plist-get (quarry-query dir "src" quarry-limit) :paths))))
        (advice-remove 'quarry-query-async 'quarry-test-consult-calls)
        (advice-remove 'emrs-cancel 'quarry-test-consult-cancel)))))

;;;; Re-query while indexing

(defmacro quarry-test-consult--with-fake-replies (indexing &rest body)
  "Run BODY with `quarry-query-async' answering from a timer.
Reply N (counted from 1 in `queries', with the texts in `texts') has
the path \"fN\" and `:indexing' as (funcall INDEXING N) says."
  (declare (indent 1))
  `(let ((queries 0)
         (texts nil)
         (quarry-consult-refresh-interval 0.01))
     (ignore texts)
     (cl-letf (((symbol-function 'quarry-query-async)
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

(ert-deftest quarry-test-consult-requery-while-indexing ()
  "The step re-sends the input until a reply says indexing ended."
  (quarry-test-consult--with-fake-replies (lambda (n) (< n 4))
    (let ((step (quarry-test-consult--step "/x/" 'quarry-test-consult--log)))
      (funcall step "a")
      (should (quarry-test--wait (lambda () (>= queries 4))))
      (quarry-test--wait #'ignore 0.3)
      (should (= queries 4))
      (should (equal texts '("a" "a" "a" "a")))
      (let ((log (reverse quarry-test-consult--log)))
        ;; Each flush is followed by the new candidates: no empty list
        ;; is shown in between.
        (should (equal (cl-loop for (a b) on log when (eq a 'flush) collect b)
                       '(("f1") ("f2") ("f3") ("f4"))))
        (should (equal (car (last log)) [indicator finished]))))))

(ert-deftest quarry-test-consult-requery-stops-on-destroy ()
  (quarry-test-consult--with-fake-replies (lambda (_) t)
    (let ((step (quarry-test-consult--step "/x/" 'quarry-test-consult--log)))
      (funcall step "a")
      (should (quarry-test--wait (lambda () (>= queries 2))))
      (funcall step 'destroy)
      (let ((seen queries))
        (quarry-test--wait #'ignore 0.3)
        (should (= queries seen))
        (should (eq (car quarry-test-consult--log) 'destroy))))))

;;;; Failure

(ert-deftest quarry-test-consult-step-failed-instance ()
  "A failed instance during the prompt is reported once and shows nothing."
  (let* ((dir (quarry-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (msgs nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) msgs)))
                  ((symbol-function 'display-warning) #'ignore))
          (let ((step (quarry-test-consult--step missing 'quarry-test-consult--log)))
            (funcall step "x")
            (should (quarry-test--wait
                     (lambda () (member [indicator failed] quarry-test-consult--log))))
            ;; The failure arrives as a reply or, when the module
            ;; already knows it, is signalled by `emrs-call'.
            (should (equal (seq-take quarry-test-consult--log 2)
                           '([indicator failed] flush)))
            (should-not (seq-find #'consp quarry-test-consult--log))
            ;; A later input queries again, on a new instance.
            (setq quarry-test-consult--log nil)
            (funcall step "xy")
            (should (quarry-test--wait
                     (lambda () (member [indicator failed] quarry-test-consult--log))))
            (should (equal (seq-take quarry-test-consult--log 2)
                           '([indicator failed] flush)))
            (should-not (seq-find #'consp quarry-test-consult--log))
            (should (= (length msgs) 1))
            (should (string-prefix-p "quarry: " (car msgs)))
            (should (> (length (car msgs)) (length "quarry: ")))))
      (quarry-stop-all)
      (quarry-test--wait (lambda () (zerop (hash-table-count quarry--instances))) 3)
      (delete-directory dir t))))

(ert-deftest quarry-test-consult-step-signalling-start ()
  "An error signalled when sending the query is caught and reported once."
  (let ((msgs nil))
    (cl-letf (((symbol-function 'quarry-query-async)
               (lambda (&rest _) (user-error "Cannot load the quarry module")))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (let ((step (quarry-test-consult--step "/x/" 'quarry-test-consult--log)))
        (should (null (funcall step "a")))
        (funcall step "ab")
        (should (equal (reverse quarry-test-consult--log)
                       '(flush [indicator failed] flush [indicator failed])))
        (should (equal msgs '("Cannot load the quarry module")))))
    ;; An instance known to be gone is reported like `quarry-query' does.
    (setq msgs nil)
    (cl-letf (((symbol-function 'quarry-query-async)
               (lambda (&rest _)
                 (signal 'emrs-error '(stopped "the instance is not running" nil))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (funcall (quarry-test-consult--step "/x/" 'quarry-test-consult--log) "a")
      (should (equal msgs '("quarry: the instance is not running"))))))

;;;; End to end through `consult--read'

(defvar quarry-test-consult--answered nil
  "Inputs whose reply the step has handled, newest first.")

(defvar quarry-test-consult--queries 0
  "Number of queries sent through `quarry-test-consult--track'.")

(defvar quarry-test-consult--done nil
  "Numbers of the queries whose reply the step has handled.")

(defvar quarry-test-consult--last-text nil
  "Text of the newest query sent through `quarry-test-consult--track'.")

(defvar quarry-test-consult--failure nil
  "Why `quarry-test-consult--settle' gave up, or nil.")

(defun quarry-test-consult--track (orig root text limit positions callback
                                        &optional dir)
  "Call ORIG with ROOT, TEXT, LIMIT, POSITIONS, a wrapped CALLBACK and DIR.
The wrapper records replies, not cancellations, in
`quarry-test-consult--answered' and `quarry-test-consult--done'."
  (let ((n (cl-incf quarry-test-consult--queries)))
    (setq quarry-test-consult--last-text text)
    (apply orig root text limit positions
           (lambda (reply err)
             (funcall callback reply err)
             (unless (eq (plist-get err :kind) 'cancelled)
               (push text quarry-test-consult--answered)
               (push n quarry-test-consult--done)))
           (and dir (list dir)))))

(defun quarry-test-consult--async-input ()
  "Return the part of the minibuffer input consult sends to the step."
  (let ((style (alist-get (or consult-async-split-style 'none)
                          consult-async-split-styles-alist)))
    (substring-no-properties
     (car (funcall (plist-get style :function)
                   (minibuffer-contents-no-properties) style)))))

(defun quarry-test-consult--settle ()
  "Wait until the step has handled the reply for the minibuffer input.
Keyboard macros do not let timers or process output run; this command
does, so consult's input timers fire and the reply comes in.  It waits
until the newest query is for the current async input and its reply
was handled.  On a timeout it records why in
`quarry-test-consult--failure' and aborts the prompt."
  (interactive)
  (let ((expected (quarry-test-consult--async-input)))
    (unless (quarry-test--wait
             (lambda () (and (equal quarry-test-consult--last-text expected)
                             (memq quarry-test-consult--queries
                                   quarry-test-consult--done))))
      (setq quarry-test-consult--failure
            (format "No reply for the async input %S; newest query %S, %s"
                    expected quarry-test-consult--last-text
                    (if (memq quarry-test-consult--queries
                              quarry-test-consult--done)
                        "answered"
                      "unanswered")))
      (abort-recursive-edit))))

(defun quarry-test-consult--select-first ()
  "Replace the minibuffer input with the first candidate, as a UI's RET."
  (interactive)
  (let ((first (car (all-completions "" minibuffer-completion-table))))
    (delete-minibuffer-contents)
    (when first (insert (substring-no-properties first)))))

(defun quarry-test-consult--choose-first ()
  "Insert the first candidate and exit, in one command, as vertico's RET.
consult saves the input to the `:input' history after each command, so
the input typed before this command is saved, not the candidate."
  (interactive)
  (quarry-test-consult--select-first)
  (exit-minibuffer))

(defvar quarry-test-consult--seen nil
  "Inputs and their candidates recorded by `quarry-test-consult--record'.")

(defun quarry-test-consult--record ()
  "Record the input and the candidates the completion styles show."
  (interactive)
  (let* ((s (minibuffer-contents))
         (all (completion-all-completions s minibuffer-completion-table
                                          minibuffer-completion-predicate
                                          (length s))))
    (when all (setcdr (last all) nil))
    (push (list (substring-no-properties s) all) quarry-test-consult--seen)))

(defun quarry-test-consult--find-file-with-keys (dir keys)
  "Run `quarry-consult-find-file' in project DIR typing KEYS.
In the prompt, C-c w waits for the reply to the input, C-c s selects the
first candidate, C-c x selects it and exits and C-c t records the
candidates.  Return the visited file."
  (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
         (map (define-keymap
                "C-c w" #'quarry-test-consult--settle
                "C-c s" #'quarry-test-consult--select-first
                "C-c x" #'quarry-test-consult--choose-first
                "C-c t" #'quarry-test-consult--record))
         (minibuffer-setup-hook minibuffer-setup-hook)
         (buf nil))
    (add-hook 'minibuffer-setup-hook
              (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
              90)
    (setq quarry-test-consult--answered nil
          quarry-test-consult--queries 0
          quarry-test-consult--done nil
          quarry-test-consult--last-text nil
          quarry-test-consult--failure nil
          quarry-test-consult--seen nil)
    (advice-add 'quarry-query-async :around #'quarry-test-consult--track)
    (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p))))
      (unwind-protect
          (progn
            (condition-case err
                (execute-kbd-macro
                 (kbd (concat "M-x quarry-consult-find-file RET " keys)))
              (quit (if quarry-test-consult--failure
                        (ert-fail quarry-test-consult--failure)
                      (signal (car err) (cdr err)))))
            (setq buf (current-buffer))
            (buffer-file-name buf))
        (advice-remove 'quarry-query-async #'quarry-test-consult--track)
        (when buf (kill-buffer buf))))))

(ert-deftest quarry-test-consult-find-file-visits ()
  "The chosen candidate is visited; the history keeps the typed input."
  (skip-unless (quarry-test-consult--consult-p))
  (quarry-test--with-index dir
    (let ((prompts nil)
          (minibuffer-setup-hook minibuffer-setup-hook)
          (consult-async-split-style 'perl)
          (quarry-consult-history nil))
      (add-hook 'minibuffer-setup-hook (lambda () (push (minibuffer-prompt) prompts)))
      ;; The perl style puts the initial "#" in the minibuffer.
      (should (equal (quarry-test-consult--find-file-with-keys
                      dir "main C-c w C-c x")
                     (concat dir "src/main.rs")))
      (should (equal (car prompts)
                     (format "Find file in %s: "
                             (file-name-nondirectory (directory-file-name dir)))))
      (should (member "main" quarry-test-consult--answered))
      (should (equal quarry-consult-history '("#main"))))))

(ert-deftest quarry-test-consult-find-file-keeps-quarry-results ()
  "With an orderless-like style, the candidates are exactly quarry's."
  (skip-unless (quarry-test-consult--consult-p))
  (quarry-test--with-index dir
    (let ((completion-styles-alist
           (cons '(quarry-test-greedy quarry-test--greedy-try
                                       quarry-test--greedy-all "")
                 completion-styles-alist))
          (completion-styles '(quarry-test-greedy))
          (completion-category-defaults nil)
          (consult-async-split-style 'none))
      (quarry-test-consult--find-file-with-keys
       dir (concat "zzzqqq C-c w C-c t DEL DEL DEL DEL DEL DEL "
                   "rs C-c w C-c t C-c s RET"))
      (let ((seen (reverse quarry-test-consult--seen)))
        (should (equal (nth 0 seen) '("zzzqqq" nil)))
        (should (equal (car (nth 1 seen)) "rs"))
        (should (equal (cadr (nth 1 seen))
                       (plist-get (quarry-query dir "rs" quarry-limit) :paths)))
        (should (quarry-test--faces-at (car (cadr (nth 1 seen))))))
      ;; Other prompts keep the user's styles.
      (should (equal completion-styles '(quarry-test-greedy))))))

(ert-deftest quarry-test-consult-find-file-failed-root ()
  "A root the service cannot index signals before any prompt opens."
  (skip-unless (quarry-test-consult--consult-p))
  (let* ((dir (quarry-test--make-tree nil))
         (missing (file-name-as-directory (expand-file-name "nope" dir)))
         (project-find-functions (list (lambda (_) (list 'transient missing))))
         (prompts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                  ((symbol-function 'consult--read)
                   (lambda (&rest _) (cl-incf prompts) nil)))
          (let ((err (should-error (quarry-consult-find-file) :type 'user-error)))
            (should (string-prefix-p "quarry: " (cadr err))))
          (should (= prompts 0)))
      (quarry-stop-all)
      (delete-directory dir t))))

(ert-deftest quarry-test-consult-find-file-does-not-wait ()
  "The prompt opens after one `:status' probe, though the index is empty.
The step re-queries while indexing, so no first page is waited for."
  (skip-unless (quarry-test-consult--consult-p))
  (quarry-test--with-roots ((dir '("a.txt")))
    (let ((project-find-functions (list (lambda (_) (list 'transient dir))))
          (quarry--first-page-wait 5)
          (call-sync (symbol-function 'quarry--call-sync))
          (probes 0)
          (prompted nil)
          (start (float-time)))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                ((symbol-function 'quarry--call-sync)
                 (lambda (root request)
                   (if (equal request '(:status))
                       (progn (cl-incf probes) '(:files 0 :indexing t))
                     (funcall call-sync root request))))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) (setq prompted (- (float-time) start)) nil))
                ((symbol-function 'find-file) #'ignore))
        (quarry-consult-find-file)
        (should prompted)
        (should (< prompted 1))
        (should (= probes 1))))))

(ert-deftest quarry-test-consult-find-file-fallbacks ()
  (skip-unless (quarry-test-consult--consult-p))
  (quarry-test--with-index dir
    (let* ((project-find-functions (list (lambda (_) (list 'transient dir))))
           (args nil))
      (cl-letf (((symbol-function 'project-root) (lambda (p) (cadr p)))
                ((symbol-function 'project-find-file)
                 (lambda (&optional a) (push (list a) args))))
        (quarry-consult-find-file t)
        (should (equal args '((t))))
        (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:x:")))
          (quarry-consult-find-file nil))
        (should (equal args '((nil) (t))))))))

;;;; `quarry-consult-find-file-in-directory'

(ert-deftest quarry-test-consult-step-dir ()
  "The step sends :dir when given, and reports a stopped one-shot target."
  (let ((requests nil)
        (msgs nil))
    (cl-letf (((symbol-function 'quarry-query-async)
               (lambda (&rest args)
                 (push args requests)
                 'fake-call))
              ((symbol-function 'emrs-cancel) #'ignore))
      (funcall (funcall (quarry-consult--async "/x/" "sub/")
                        (lambda (_) nil))
               "a")
      (funcall (funcall (quarry-consult--async "/x/")
                        (lambda (_) nil))
               "b")
      ;; ROOT TEXT LIMIT POSITIONS CALLBACK [DIR]
      (should (equal (nth 5 (cadr requests)) "sub/"))
      (should (= (length (car requests)) 5)))
    ;; A one-shot record whose walk has ended: the failure message is
    ;; the error's text, and there is no root to look a failure up for.
    (let* ((rec (quarry--make-rec :root "/x/" :one-shot t))
           (step (funcall (quarry-consult--async rec)
                          (lambda (action) (push action quarry-test-consult--log) nil))))
      (setq quarry-test-consult--log nil)
      (cl-letf (((symbol-function 'quarry--target-rec)
                 (lambda (_) (user-error "quarry: the walk of /x/ has ended")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (funcall step "a")
        (should (equal msgs '("quarry: the walk of /x/ has ended")))
        (should (equal (seq-take quarry-test-consult--log 2)
                       '([indicator failed] flush)))))
    ;; The same through an `emrs-error' for the stopped instance.
    (setq msgs nil)
    (let* ((rec (quarry--make-rec :root "/x/" :one-shot t))
           (step (funcall (quarry-consult--async rec) (lambda (_) nil))))
      (cl-letf (((symbol-function 'quarry-query-async)
                 (lambda (&rest _)
                   (signal 'emrs-error '(stopped "the instance is not running" nil))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (funcall step "a")
        (should (equal msgs '("quarry: the instance is not running")))))))

(defvar quarry-test-consult--paths nil
  "Paths of the replies to the queries, newest first.")

(defun quarry-test-consult--collect (orig root text limit positions callback
                                          &optional dir)
  "Call ORIG, recording the paths of each reply in `quarry-test-consult--paths'."
  (apply orig root text limit positions
         (lambda (reply err)
           (when reply (push (plist-get reply :paths) quarry-test-consult--paths))
           (funcall callback reply err))
         (and dir (list dir))))

(defun quarry-test-consult--in-directory-with-keys (dir keys)
  "Run `quarry-consult-find-file-in-directory' in DIR typing KEYS.
The prompt has the keys of `quarry-test-consult--find-file-with-keys'.
Return the visited file."
  (let* ((map (define-keymap
                "C-c w" #'quarry-test-consult--settle
                "C-c x" #'quarry-test-consult--choose-first))
         (minibuffer-setup-hook minibuffer-setup-hook)
         (consult-async-split-style 'none)
         (buf nil))
    (add-hook 'minibuffer-setup-hook
              (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
              90)
    (setq quarry-test-consult--answered nil
          quarry-test-consult--queries 0
          quarry-test-consult--done nil
          quarry-test-consult--last-text nil
          quarry-test-consult--failure nil
          quarry-test-consult--paths nil)
    (advice-add 'quarry-query-async :around #'quarry-test-consult--track)
    (advice-add 'quarry-query-async :around #'quarry-test-consult--collect)
    (unwind-protect
        (progn
          (condition-case err
              (with-current-buffer (window-buffer)
                (let ((default-directory dir))
                  (execute-kbd-macro
                   (kbd (concat "M-x quarry-consult-find-file-in-directory RET "
                                keys)))))
            (quit (if quarry-test-consult--failure
                      (ert-fail quarry-test-consult--failure)
                    (signal (car err) (cdr err)))))
          (setq buf (window-buffer))
          (buffer-file-name buf))
      (advice-remove 'quarry-query-async #'quarry-test-consult--track)
      (advice-remove 'quarry-query-async #'quarry-test-consult--collect)
      (when (and buf (buffer-file-name buf))
        (kill-buffer buf)))))

(ert-deftest quarry-test-consult-find-file-in-directory-index ()
  "A project subdirectory: relative candidates, visited below it."
  (skip-unless (quarry-test-consult--consult-p))
  (quarry-test--with-dir-project dir
    (let ((sub (concat dir "sub/"))
          (prompts nil)
          (minibuffer-setup-hook minibuffer-setup-hook)
          (quarry-consult-directory-history nil))
      (add-hook 'minibuffer-setup-hook (lambda () (push (minibuffer-prompt) prompts)))
      (should (equal (quarry-test-consult--in-directory-with-keys
                      sub "txt C-c w C-c x")
                     (concat sub "a.txt")))
      (should (equal (car prompts)
                     (format "Find file in %s: " (abbreviate-file-name sub))))
      ;; Not top.txt or subx/c.txt, which match "txt" too.
      (should (member '("a.txt" "deep/b.txt") quarry-test-consult--paths))
      (should-not (seq-find (lambda (paths) (member "top.txt" paths))
                            quarry-test-consult--paths))
      (should (equal quarry-consult-directory-history '("txt")))
      (should (= (hash-table-count quarry--instances) 1)))))

(ert-deftest quarry-test-consult-find-file-in-directory-one-shot-visits ()
  "A directory outside any project: its files are offered and visited."
  (skip-unless (quarry-test-consult--consult-p))
  (let ((dir (quarry-test--make-tree '("o1.txt" "d/o2.txt")))
        (project-find-functions nil))
    (unwind-protect
        (progn
          (should (equal (quarry-test-consult--in-directory-with-keys
                          dir "o2 C-c w C-c x")
                         (concat dir "d/o2.txt")))
          (should (member '("d/o2.txt") quarry-test-consult--paths))
          (should (zerop (hash-table-count quarry--instances))))
      (quarry-stop-all)
      (delete-directory dir t))))

(ert-deftest quarry-test-consult-find-file-in-directory-one-shot-stops ()
  "The one-shot instance runs during the prompt; RET, quit and error stop it."
  (skip-unless (quarry-test-consult--consult-p))
  (let ((dir (quarry-test--make-tree '("o1.txt" "d/o2.txt")))
        (project-find-functions nil))
    (unwind-protect
        (pcase-dolist (`(,reply ,expected)
                       `((,(lambda () "d/o2.txt") ,(concat dir "d/o2.txt"))
                         (,(lambda () (signal 'quit nil)) (quit))
                         (,(lambda () (error "Boom")) (error "Boom"))))
          (let ((rec nil) (state nil) (rel 'unset) (bound nil) (result nil))
            (cl-letf (((symbol-function 'consult--read)
                       (lambda (&rest _)
                         (setq state (emrs-instance-state (quarry--rec-instance rec))
                               bound default-directory)
                         (funcall reply)))
                      ((symbol-function 'consult--async-pipeline) #'ignore)
                      ((symbol-function 'consult--async-split) #'ignore)
                      ((symbol-function 'consult--async-throttle) #'ignore)
                      ((symbol-function 'consult--async-indicator) #'ignore)
                      ((symbol-function 'consult--async-refresh) #'ignore))
              (advice-add 'quarry--dir-target :filter-return
                          (lambda (target) (setq rec (car target) rel (cdr target)) target)
                          '((name . quarry-test-capture)))
              (unwind-protect
                  (setq result
                        (condition-case err
                            (progn (quarry-consult-find-file-in-directory dir)
                                   (prog1 (buffer-file-name) (kill-buffer)))
                          ((error quit) err)))
                (advice-remove 'quarry--dir-target 'quarry-test-capture)))
            (should (quarry--rec-one-shot rec))
            (should-not rel)
            (should (eq state 'running))
            (should (equal bound dir))
            (should (equal result expected))
            (should (quarry-test--stopped-p rec))
            (should (zerop (hash-table-count quarry--instances)))))
      (quarry-stop-all)
      (delete-directory dir t))))

;;;; The command's own checks

(ert-deftest quarry-test-consult-find-file-in-directory-refused ()
  "Remote and missing directories are refused before any instance starts."
  (skip-unless (quarry-test-consult--consult-p))
  (let ((dir (quarry-test--make-tree '("file")))
        (count (hash-table-count quarry--instances))
        (starts 0))
    (advice-add 'emrs-start :before (lambda (&rest _) (cl-incf starts))
                '((name . quarry-test-count-start)))
    (unwind-protect
        (progn
          (let ((err (should-error (quarry-consult-find-file-in-directory
                                    "/ssh:quarry-test-host:/tmp/")
                                   :type 'user-error)))
            (should (equal (cadr err) "quarry finds files in local directories only: /ssh:quarry-test-host:/tmp/")))
          (let ((err (should-error (quarry-consult-find-file-in-directory
                                    (concat dir "nope"))
                                   :type 'user-error)))
            (should (string-match-p (regexp-quote (concat dir "nope")) (cadr err))))
          (let ((err (should-error (quarry-consult-find-file-in-directory
                                    (concat dir "file"))
                                   :type 'user-error)))
            (should (string-match-p "Not a directory" (cadr err))))
          (should (= starts 0))
          (should (= (hash-table-count quarry--instances) count)))
      (advice-remove 'emrs-start 'quarry-test-count-start)
      (delete-directory dir t))))

(ert-deftest quarry-test-consult-find-file-in-directory-prefix-argument ()
  "With a prefix argument the command asks for the directory and uses it."
  (skip-unless (quarry-test-consult--consult-p))
  (let ((dir (quarry-test--make-tree '("o1.txt")))
        (project-find-functions nil)
        (asked nil) (visited nil) (prompt nil))
    (unwind-protect
        (cl-letf (((symbol-function 'read-directory-name)
                   (lambda (&rest _) (setq asked t) dir))
                  ((symbol-function 'quarry-consult--read)
                   (lambda (p &rest _) (setq prompt p) "o1.txt"))
                  ((symbol-function 'find-file)
                   (lambda (file &rest _) (setq visited file))))
          (let ((current-prefix-arg '(4)))
            (call-interactively #'quarry-consult-find-file-in-directory))
          (should asked)
          (should (equal prompt (format "Find file in %s: " (abbreviate-file-name dir))))
          (should (equal visited (concat dir "o1.txt"))))
      (quarry-stop-all)
      (delete-directory dir t))))

;;;; Without consult

(ert-deftest quarry-test-consult-without-consult ()
  "Without consult, quarry-consult.el loads and compiles; the command says why not."
  (let* ((tmp (file-name-as-directory (make-temp-file "quarry-consult" t)))
         (file (expand-file-name "quarry-consult.el" tmp))
         (form
          `(progn
             ;; Drop any directory that holds consult, e.g. site-lisp.
             (setq load-path
                   (delq nil (mapcar (lambda (d)
                                       (unless (locate-file "consult" (list d)
                                                            '(".el" ".elc"))
                                         d))
                                     load-path)))
             (require 'quarry-consult)
             (when (featurep 'consult) (error "consult was loaded"))
             (setq byte-compile-error-on-warn t)
             (unless (byte-compile-file ,file) (error "Compiling failed"))
             (load (concat ,file "c") nil t)
             (condition-case err
                 (progn (quarry-consult-find-file)
                        (error "No user-error"))
               (user-error
                (unless (string-match-p "consult 2\\.0" (cadr err))
                  (error "Wrong user-error: %S" err))))
             (kill-emacs 0))))
    (copy-file (locate-library "quarry-consult.el") file)
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil t nil "--batch" "-Q"
                         "-L" tmp
                         "-L" (file-name-directory (locate-library "quarry"))
                         "-L" (file-name-directory (locate-library "emrs"))
                         "--eval" (prin1-to-string form))))
            (should (equal (list status (buffer-string)) (list 0 (buffer-string))))))
      (delete-directory tmp t))))

(provide 'quarry-consult-tests)
;;; quarry-consult-tests.el ends here
