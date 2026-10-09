;;; projdex.el --- Fast project file finder backed by a Rust module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The projdex authors

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (emrs "0.1.0"))
;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; projdex keeps a live index of each project's files in a Rust module
;; (built with emrs) and answers fuzzy queries from it, for
;; `project-find-file' and other `completing-read' prompts.
;;
;; Not functional yet: the module service and the completion table are
;; added by the v1 spec.

;;; Code:

(require 'emrs)

(defgroup projdex nil
  "Fast project file finder backed by a Rust module."
  :group 'files
  :prefix "projdex-")

(provide 'projdex)
;;; projdex.el ends here
