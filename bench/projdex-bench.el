;;; projdex-bench.el --- Benchmark driver for projdex  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Driver of bench/run-bench.sh; not part of the package.  Two entry
;; points, both for `emacs --batch':
;;
;; - `projdex-bench-generate' writes the directory and file lists of a
;;   deterministic AOSP-like tree; the shell script creates the tree.
;; - `projdex-bench-run' measures one tree: time to the first `:indexed'
;;   event, Emacs RSS, and the latency of completion-table calls for a
;;   fixed sequence of typed queries, for projdex and (optionally) for the
;;   `project-files' + `flex' baseline.  It prints a table and RESULT lines
;;   and exits non-zero when projdex's p99 exceeds the threshold.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'projdex)

;;;; Tree generator

(defconst projdex-bench-generator-version 2
  "Version of the generator; a change invalidates generated trees.")

(defvar projdex-bench--seed 1
  "State of the MINSTD generator.")

(defun projdex-bench--rand (n)
  "Return a pseudo-random integer in [0, N)."
  (setq projdex-bench--seed (% (* projdex-bench--seed 48271) 2147483647))
  (/ (* projdex-bench--seed n) 2147483647))

(defun projdex-bench--pick (vec)
  "Return a random element of the vector VEC."
  (aref vec (projdex-bench--rand (length vec))))

(defun projdex-bench--chance (percent)
  "Return non-nil with probability PERCENT/100."
  (< (projdex-bench--rand 100) percent))

(defconst projdex-bench--words
  ["Activity" "Manager" "Service" "Window" "Surface" "Flinger" "Package"
   "Input" "Display" "Power" "Battery" "Audio" "Media" "Camera" "Sensor"
   "Network" "Wifi" "Bluetooth" "Telephony" "Location" "Notification" "Job"
   "Alarm" "Account" "Content" "Provider" "Resolver" "View" "Layout" "Text"
   "Image" "Bitmap" "Canvas" "Paint" "Shader" "Render" "Thread" "Looper"
   "Handler" "Message" "Binder" "Parcel" "Intent" "Bundle" "Task" "Stack"
   "Key" "Event" "Touch" "Gesture" "Accessibility" "Storage" "Volume"
   "Mount" "User" "Permission" "Settings" "Shell" "Split" "Pip" "Bubble"
   "Status" "Bar" "Nav" "Keyguard" "Lock" "Screen" "Recent" "Launcher"
   "Widget" "Host" "Clip" "Board" "Font" "Color" "Theme" "Dream"
   "Wallpaper" "Backup" "Usage" "Stats" "Overlay" "Animation" "Transition"
   "Drag" "Focus" "Ime" "Session" "Token" "Hal" "Codec" "Extractor" "Track"
   "Buffer" "Queue" "Fence" "Composer" "Layer" "Gralloc" "Vibrator"
   "Thermal" "Health" "Boot" "Update" "Zygote" "Process" "Memory" "Heap"
   "Dex" "Class" "Loader" "Compiler" "Runtime" "Native" "Bridge" "Pkg"
   "Mgr" "Shortcut" "Device" "Policy" "Insets" "Rotation" "Brightness"]
  "Words of CamelCase file names.")

(defconst projdex-bench--suffixes
  ["Manager" "Service" "Controller" "Impl" "Helper" "Utils" "Callback"
   "Listener" "Info" "State" "Record" "Stub" "Proxy" "Client" "Test"
   "Tests" "Factory" "Builder" "Adapter" "Fragment" "Activity" "Receiver"
   "Provider" "Config" "Policy" "Tracker" "Monitor" "Handler" "Session"
   "Constants" "Internal" "Compat" "Wrapper" "Delegate" "Cache"]
  "Suffixes of CamelCase file names.")

(defconst projdex-bench--java-dirs
  ["app" "view" "widget" "content" "os" "util" "net" "server" "internal"
   "wm" "am" "pm" "policy" "display" "input" "media" "graphics"
   "accessibility" "telephony" "location" "hardware" "provider" "service"
   "statusbar" "notification" "keyguard" "shell" "pip" "splitscreen"
   "bubbles" "recents" "power" "job" "backup" "usage" "storage" "security"
   "permission" "inputmethod" "textclassifier" "transition" "animation"
   "compat" "pkgmgr" "settings" "biometrics" "companion" "contentcapture"
   "devicepolicy" "tests" "utils" "common" "data" "model" "ui" "res"]
  "Directory names below Java source roots.")

(defconst projdex-bench--native-dirs
  ["src" "include" "lib" "libs" "tests" "test" "utils" "common" "core"
   "impl" "default" "aidl" "hidl" "jni" "host" "device" "fuzzers"
   "benchmarks" "tools" "surfaceflinger" "renderengine" "gui" "ui" "binder"
   "hwui" "audioflinger" "camera" "codec2" "stagefright" "mediaserver"
   "sensorservice" "inputflinger" "vulkan" "opengl" "egl" "gles2" "aaudio"
   "libutils" "liblog" "libcutils" "base" "platform" "arch" "x86" "arm64"
   "riscv64" "generic" "1.0" "2.0" "aidl_api" "current" "vts" "functional"
   "internal" "private" "public" "android" "linux" "util" "net" "crypto"]
  "Directory names in native code.")

(defconst projdex-bench--res-dirs
  ["layout" "values" "values-de" "values-fr" "values-ja" "values-zh-rCN"
   "values-night" "values-sw600dp" "drawable" "drawable-hdpi"
   "drawable-xhdpi" "drawable-xxhdpi" "mipmap-xxxhdpi" "xml" "raw" "anim"
   "menu" "color" "font"]
  "Directory names below res/.")

(defconst projdex-bench--external
  ["boringssl" "skia" "protobuf" "libcxx" "libcxxabi" "llvm" "compiler-rt"
   "sqlite" "zlib" "icu" "libpng" "libjpeg-turbo" "webp" "freetype"
   "harfbuzz_ng" "expat" "libxml2" "curl" "openssh" "e2fsprogs" "f2fs-tools"
   "toybox" "iproute2" "iptables" "selinux" "pcre" "lz4" "zstd" "brotli"
   "flatbuffers" "googletest" "google-benchmark" "abseil-cpp" "grpc-grpc"
   "kotlinx.coroutines" "guava" "junit" "mockito" "robolectric" "dagger2"
   "okhttp" "conscrypt" "bouncycastle" "chromium-trace" "perfetto" "tensorflow"
   "libaom" "libvpx" "libopus" "flac" "tinyalsa" "wpa_supplicant_8" "rust"
   "crosvm" "minigbm" "mesa3d" "angle" "swiftshader" "vulkan-headers"
   "linux-kernel-headers" "fmtlib" "jsoncpp" "libevent" "dtc" "fio"]
  "Project names below external/.")

(defconst projdex-bench--top
  ;; (NAME PERCENT STYLE CHILDREN), CHILDREN a list of (NAME WEIGHT STYLE)
  ;; or nil for generated children.
  '(("frameworks" 16 java
     (("base" 50 java) ("av" 14 native) ("native" 14 native)
      ("opt" 8 java) ("libs" 7 java) ("compile" 4 native) ("hardware" 3 native)))
    ("packages" 12 app
     (("apps" 45 app) ("modules" 35 java) ("services" 10 java)
      ("providers" 6 app) ("inputmethods" 4 app)))
    ("external" 22 native nil)
    ("hardware" 5 native
     (("interfaces" 60 native) ("libhardware" 10 native) ("google" 15 native)
      ("qcom" 15 native)))
    ("system" 8 native
     (("core" 25 native) ("sepolicy" 10 native) ("bt" 15 native)
      ("netd" 5 native) ("vold" 5 native) ("update_engine" 8 native)
      ("apex" 7 native) ("tools" 8 native) ("libhidl" 5 native)
      ("media" 6 native) ("extras" 6 native)))
    ("vendor" 6 native nil)
    ("device" 3 native nil)
    ("prebuilts" 10 native nil)
    ("cts" 6 java
     (("tests" 70 java) ("hostsidetests" 20 java) ("apps" 5 app) ("libs" 5 java)))
    ("art" 3 native nil)
    ("bionic" 2 native nil)
    ("bootable" 1 native nil)
    ("development" 1 java nil)
    ("libcore" 2 java nil)
    ("tools" 2 java nil)
    ("test" 1 java nil))
  "The top two levels of the generated tree.")

(defun projdex-bench--camel ()
  "Return a random CamelCase name."
  (concat (projdex-bench--pick projdex-bench--words)
          (if (projdex-bench--chance 60) (projdex-bench--pick projdex-bench--words) "")
          (if (projdex-bench--chance 70) (projdex-bench--pick projdex-bench--suffixes) "")))

(defun projdex-bench--snake ()
  "Return a random snake_case name."
  (concat (downcase (projdex-bench--pick projdex-bench--words))
          (if (projdex-bench--chance 70)
              (concat "_" (downcase (projdex-bench--pick projdex-bench--words)))
            "")
          (if (projdex-bench--chance 30)
              (concat "_" (downcase (projdex-bench--pick projdex-bench--suffixes)))
            "")))

(defun projdex-bench--file-name (style)
  "Return a random file name for a directory of STYLE."
  (pcase style
    ('java (concat (projdex-bench--camel)
                   (if (projdex-bench--chance 20) ".kt" ".java")))
    ('res (concat (projdex-bench--snake)
                  (if (projdex-bench--chance 25) ".png" ".xml")))
    (_ (let ((r (projdex-bench--rand 100)))
         (cond ((< r 35) (concat (projdex-bench--snake) ".cpp"))
               ((< r 60) (concat (projdex-bench--snake) ".h"))
               ((< r 70) (concat (projdex-bench--camel) ".cpp"))
               ((< r 78) (concat (projdex-bench--camel) ".h"))
               ((< r 86) (concat (projdex-bench--snake) ".c"))
               ((< r 90) (concat (projdex-bench--snake) ".py"))
               ((< r 93) (concat (projdex-bench--snake) ".rs"))
               ((< r 96) (concat (projdex-bench--camel) ".aidl"))
               (t (concat (projdex-bench--snake) ".proto")))))))

(defun projdex-bench--dir-name (style depth)
  "Return a random directory name, as a relative path, for STYLE at DEPTH.
May return several components (a Java package root)."
  (pcase style
    ('java (if (and (<= depth 3) (projdex-bench--chance 30))
               (projdex-bench--pick ["core/java/android" "java/com/android"
                                     "src/com/android" "src/main/java/com/android"
                                     "services/core/java/com/android/server"
                                     "tests/src/com/android"])
             (projdex-bench--pick projdex-bench--java-dirs)))
    ('app (if (projdex-bench--chance 25)
              "res"
            (if (projdex-bench--chance 50)
                (projdex-bench--camel)
              (projdex-bench--pick projdex-bench--java-dirs))))
    ('res (projdex-bench--pick projdex-bench--res-dirs))
    (_ (if (projdex-bench--chance 15)
           (projdex-bench--snake)
         (projdex-bench--pick projdex-bench--native-dirs)))))

(defun projdex-bench--child-style (style name)
  "Return the style of a child directory NAME of a STYLE directory."
  (cond ((string= name "res") 'res)
        ((eq style 'res) 'res)
        ((eq style 'app) (if (string-match-p "/" name) 'java 'app))
        (t style)))

(defvar projdex-bench--files nil "Files generated so far, reversed.")
(defvar projdex-bench--seen nil "Hash table of the files generated so far.")

(defconst projdex-bench--landmarks
  '("frameworks/base/core/java/android/app/ActivityManager.java"
    "frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
    "frameworks/base/services/core/java/com/android/server/pm/PackageManagerService.java"
    "frameworks/base/core/java/android/view/View.java"
    "frameworks/base/core/java/android/view/ViewRootImpl.java"
    "frameworks/base/libs/WindowManager/Shell/src/com/android/wm/shell/ShellTaskOrganizer.java"
    "frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp"
    "frameworks/native/services/surfaceflinger/SurfaceFlinger.h"
    "frameworks/native/services/surfaceflinger/main_surfaceflinger.cpp"
    "frameworks/native/services/surfaceflinger/Android.bp")
  "Real AOSP paths every generated tree contains.")

(defun projdex-bench--add (dir name)
  "Add the file NAME in DIR, with a number before the extension if taken."
  (let ((path (concat dir name))
        (k 2))
    (while (gethash path projdex-bench--seen)
      (setq path (concat dir (if (string-match "\\.[a-z0-9]+\\'" name)
                                 (concat (substring name 0 (match-beginning 0))
                                         (number-to-string k) (match-string 0 name))
                               (format "%s%d" name k))))
      (cl-incf k))
    (puthash path t projdex-bench--seen)
    (push path projdex-bench--files)))

(defun projdex-bench--emit-files (dir style n)
  "Add N distinct files of STYLE to DIR (a path ending in /)."
  (dolist (special '(("Android.bp" . 40) ("Android.mk" . 5) ("OWNERS" . 10)))
    (when (and (> n 0) (not (eq style 'res)) (projdex-bench--chance (cdr special)))
      (projdex-bench--add dir (car special))
      (cl-decf n)))
  (dotimes (_ n)
    (projdex-bench--add dir (projdex-bench--file-name style))))

(defun projdex-bench--split (n weights)
  "Split N into parts proportional to WEIGHTS; return the list of parts."
  (let* ((sum (apply #'+ weights))
         (parts (mapcar (lambda (w) (/ (* n w) sum)) weights))
         (rest (- n (apply #'+ parts))))
    (cl-incf (car parts) rest)
    parts))

(defun projdex-bench--gen (dir style n depth)
  "Generate N files below DIR (ending in /) of STYLE at DEPTH."
  (let ((leaf (+ 6 (projdex-bench--rand 30))))
    (if (or (<= n leaf) (>= depth 10)
            ;; Resource directories (res/layout/ ...) hold files only.
            (and (eq style 'res) (not (string-suffix-p "/res/" dir))))
        (projdex-bench--emit-files dir style n)
      (let* ((here (min n (projdex-bench--rand 6)))
             (k (+ 2 (projdex-bench--rand 7)))
             (names nil))
        (projdex-bench--emit-files dir style here)
        (while (< (length names) k)
          (let ((name (projdex-bench--dir-name style depth)))
            (unless (member name names) (push name names))))
        (let ((parts (projdex-bench--split
                      (- n here)
                      (mapcar (lambda (_) (let ((r (1+ (projdex-bench--rand 10)))) (* r r)))
                              names))))
          (cl-loop for name in names
                   for part in parts
                   when (> part 0)
                   do (projdex-bench--gen
                       (concat dir name "/")
                       (projdex-bench--child-style style name)
                       part
                       (+ depth 1 (cl-count ?/ name)))))))))

(defun projdex-bench--gen-children (dir style n children depth)
  "Generate N files below DIR with fixed CHILDREN, or generated ones."
  (if (null children)
      (let* ((pool (if (string= dir "external/")
                       projdex-bench--external
                     (vconcat (mapcar #'downcase projdex-bench--words))))
             (k (min (length pool) (max 4 (/ n 2000))))
             (names nil))
        (while (< (length names) k)
          (let ((name (projdex-bench--pick pool)))
            (unless (member name names) (push name names))))
        (cl-loop for name in names
                 for part in (projdex-bench--split
                              n (mapcar (lambda (_) (1+ (projdex-bench--rand 20))) names))
                 when (> part 0)
                 do (projdex-bench--gen (concat dir name "/") style part depth)))
    (cl-loop for (name _w cstyle) in children
             for part in (projdex-bench--split n (mapcar #'cadr children))
             when (> part 0)
             do (projdex-bench--gen (concat dir name "/") cstyle part depth))))

(defun projdex-bench-generate (n out)
  "Write the lists of a generated tree of N files to OUT.dirs and OUT.files.
Paths are relative, separated by newlines, and contain no whitespace or
quotes, so `xargs' can take them."
  (setq projdex-bench--seed 20261009
        projdex-bench--files nil
        projdex-bench--seen (make-hash-table :test 'equal :size n))
  (dolist (path projdex-bench--landmarks)
    (projdex-bench--add (file-name-directory path) (file-name-nondirectory path)))
  (cl-loop for (name _p style children) in projdex-bench--top
           for part in (projdex-bench--split (- n (length projdex-bench--landmarks))
                                             (mapcar #'cadr projdex-bench--top))
           do (projdex-bench--gen-children (concat name "/") style part children 2))
  (cl-assert (= (length projdex-bench--files) n))
  (let ((total 0) (depth 0) (dirs (make-hash-table :test 'equal))
        (coding-system-for-write 'utf-8-unix))
    (dolist (f projdex-bench--files)
      (cl-incf total (length f))
      (cl-incf depth (cl-count ?/ f))
      (let ((dir (file-name-directory f)))
        (while (and dir (not (gethash dir dirs)))
          (puthash dir t dirs)
          (setq dir (file-name-directory (directory-file-name dir))))))
    (with-temp-buffer
      (maphash (lambda (d _) (insert d "\n")) dirs)
      (write-region nil nil (concat out ".dirs") nil 'silent))
    (with-temp-buffer
      (dolist (f (nreverse projdex-bench--files))
        (insert f "\n"))
      (write-region nil nil (concat out ".files") nil 'silent))
    (princ (format "generated %d files in %d directories; mean path length %.1f, mean depth %.1f\n"
                   n (hash-table-count dirs) (/ total (float n))
                   (/ depth (float n))))))

;;;; Measurement

(defconst projdex-bench-queries
  '("activitymanager" "frameworks base view" "^frameworks/base" "android.bp$"
    "pkgmgr" "SurfaceFlinger" "!test main" "wm shell")
  "Queries typed character by character: one completion call per prefix.")

(defun projdex-bench--rss-mb ()
  "Return the resident set size of this Emacs in MiB."
  (with-temp-buffer
    (insert-file-contents "/proc/self/status")
    (if (re-search-forward "^VmRSS:[ \t]+\\([0-9]+\\) kB" nil t)
        (/ (string-to-number (match-string 1)) 1024.0)
      -1.0)))

(defun projdex-bench--percentile (sorted p)
  "Return the nearest-rank P-th percentile (0 < P <= 100) of SORTED."
  (nth (max 0 (1- (ceiling (* (length sorted) (/ p 100.0))))) sorted))

(defun projdex-bench--stats (times)
  "Return (P50 P95 P99 MAX) in ms of TIMES (seconds)."
  (let ((sorted (sort (mapcar (lambda (s) (* 1000 s)) times) #'<)))
    (list (projdex-bench--percentile sorted 50)
          (projdex-bench--percentile sorted 95)
          (projdex-bench--percentile sorted 99)
          (car (last sorted)))))

(defun projdex-bench--type (make-table style)
  "Type every query of `projdex-bench-queries' through STYLE.
MAKE-TABLE returns a fresh completion table, called once per query
\(as a prompt does).  Return (TIMES . ROWS): TIMES the duration of each
completion call, ROWS per query (QUERY CALLS MAX-MS RESULTS FIRST)."
  (let ((times nil) (rows nil)
        (completion-styles (list style))
        (completion-category-overrides
         (cons `(project-file (styles ,style)) completion-category-overrides)))
    (dolist (query projdex-bench-queries)
      (let ((table (funcall make-table))
            (qmax 0) (result nil))
        (dotimes (i (length query))
          ;; A new string per keystroke, as the minibuffer produces.
          (let* ((input (substring query 0 (1+ i)))
                 (start (float-time))
                 (all (completion-all-completions input table nil (length input)))
                 (dt (- (float-time) start)))
            (push dt times)
            (setq qmax (max qmax dt) result all)))
        (when (consp result) (setcdr (last result) nil))
        (push (list query (length query) (* 1000 qmax) (length result)
                    (and result (substring-no-properties (car result))))
              rows)))
    (cons times (nreverse rows))))

(defun projdex-bench--report (size impl stats extra rows)
  "Print the figures of IMPL on SIZE: STATS, EXTRA (an alist) and ROWS."
  (princ (format "\n%s on %s\n" impl size))
  (princ (format "  %-22s %6s %9s %8s  %s\n" "query" "calls" "max ms" "results" "first result"))
  (dolist (row rows)
    (princ (format "  %-22s %6d %9.1f %8d  %s\n" (nth 0 row) (nth 1 row) (nth 2 row)
                   (nth 3 row) (or (nth 4 row) "-"))))
  (princ (apply #'format "  p50 %.1f ms   p95 %.1f ms   p99 %.1f ms   max %.1f ms\n" stats))
  (princ (concat (format "RESULT size=%s impl=%s p50=%.1f p95=%.1f p99=%.1f max=%.1f"
                         size impl (nth 0 stats) (nth 1 stats) (nth 2 stats) (nth 3 stats))
                 (mapconcat (lambda (kv) (format " %s=%s" (car kv) (cdr kv))) extra "")
                 "\n")))

(defun projdex-bench--run-projdex (size tree)
  "Benchmark projdex on TREE, labelled SIZE; return its p99 in ms."
  (emrs-load-module 'projdex)
  (let* ((root (file-name-as-directory (expand-file-name tree)))
         (projdex-limit 100)
         (projdex-highlight t)
         (rss0 (projdex-bench--rss-mb))
         (start (float-time))
         (rec (projdex--ensure root)))
    (while (= (projdex--rec-epoch rec) 0)
      (accept-process-output nil 0.005))
    (let* ((index-ms (* 1000 (- (float-time) start)))
           (rss1 (projdex-bench--rss-mb))
           (status (projdex--status root))
           (gcs gcs-done) (gc-time gc-elapsed)
           (run (projdex-bench--type (lambda () (projdex--table root)) 'projdex))
           (stats (projdex-bench--stats (car run)))
           (rss2 (projdex-bench--rss-mb)))
      (princ (format "\nprojdex on %s: %d files indexed in %.0f ms; RSS %.0f MiB before, %.0f MiB after indexing, %.0f MiB after queries\n  %s\n"
                     size (projdex--rec-files rec) index-ms rss0 rss1 rss2 status))
      (projdex-bench--report
       size "projdex" stats
       `((index_ms . ,(round index-ms))
         (files . ,(projdex--rec-files rec))
         (rss_mb . ,(round rss1))
         (rss_delta_mb . ,(round (- rss1 rss0)))
         (gcs . ,(- gcs-done gcs))
         (gc_ms . ,(round (* 1000 (- gc-elapsed gc-time)))))
       (cdr run))
      (projdex-stop-all)
      (nth 2 stats))))

(defun projdex-bench--run-baseline (size tree)
  "Benchmark `project-files' with `flex' on TREE, labelled SIZE."
  (let* ((default-directory (file-name-as-directory (expand-file-name tree)))
         (list-times nil)
         (count 0)
         (gcs gcs-done) (gc-time gc-elapsed)
         (make-table
          (lambda ()
            ;; What `project-find-file' does on each invocation.
            (let* ((start (float-time))
                   (all-files (project-files (project-current nil default-directory)))
                   (prefix (try-completion "" all-files))
                   (cpd (length (and (> (length prefix) 0) (file-name-directory prefix))))
                   (files (mapcar (lambda (s) (substring s cpd)) all-files)))
              (push (- (float-time) start) list-times)
              (setq count (length files))
              (lambda (string pred action)
                (if (eq action 'metadata)
                    '(metadata (category . project-file))
                  (complete-with-action action files string pred))))))
         (run (projdex-bench--type make-table 'flex))
         (stats (projdex-bench--stats (car run)))
         (list-ms (/ (* 1000 (apply #'+ list-times)) (length list-times))))
    (princ (format "\nbaseline on %s: project-files + relative names: %d files, %.0f ms per prompt (mean of %d)\n"
                   size count list-ms (length list-times)))
    (projdex-bench--report
     size "baseline-flex" stats
     `((list_ms . ,(round list-ms))
       (files . ,count)
       (gcs . ,(- gcs-done gcs))
       (gc_ms . ,(round (* 1000 (- gc-elapsed gc-time)))))
     (cdr run))))

(defun projdex-bench-run ()
  "Run the benchmark with arguments from the command line.
Arguments: SIZE-LABEL TREE THRESHOLD-MS BASELINE (\"1\" or \"0\").
Exit with status 1 when projdex's p99 exceeds THRESHOLD-MS."
  (pcase-let ((`(,size ,tree ,threshold ,baseline) command-line-args-left))
    (setq command-line-args-left nil)
    (let ((p99 (projdex-bench--run-projdex size tree))
          (limit (string-to-number threshold)))
      (when (equal baseline "1")
        (projdex-bench--run-baseline size tree))
      (if (> p99 limit)
          (progn
            (princ (format "\nFAIL size=%s: projdex p99 %.1f ms exceeds %d ms\n" size p99 limit))
            (kill-emacs 1))
        (princ (format "\nPASS size=%s: projdex p99 %.1f ms within %d ms\n" size p99 limit))
        (kill-emacs 0)))))

(provide 'projdex-bench)
;;; projdex-bench.el ends here
