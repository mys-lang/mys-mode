;;; mys-mode.el --- Edit, debug, develop, run Python programs. -*- lexical-binding: t; -*- 

;; Version: 6.3.1

;; Keywords: languages, processes, python, oop

;; URL: https://gitlab.com/groups/mys-mode-devs

;; Package-Requires: ((emacs "24"))

;; Author: 2015-2021 https://gitlab.com/groups/mys-mode-devs
;;         2003-2014 https://launchpad.net/mys-mode
;;         1995-2002 Barry A. Warsaw
;;         1992-1994 Tim Peters
;; Maintainer: mys-mode@python.org
;; Created:    Feb 1992
;; Keywords:   python languages oop

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Includes a minor mode for handling a Python/Imys shell, and can
;; take advantage of Pymacs when installed.

;; See documentation in README.org, README.DEVEL.org

;; Please report bugs at
;; https://gitlab.com/mys-mode-devs/mys-mode/issues

;; available commands are documented in directory "doc" as
;; commands-mys-mode.org

;; As for `mys-add-abbrev':
;; Similar to `add-mode-abbrev', but uses
;; `mys-partial-expression' before point for expansion to
;; store, not `word'.  Also provides a proposal for new
;; abbrevs.

;; Proposal for an abbrev is composed from the downcased
;; initials of expansion - provided they are of char-class
;; [:alpha:]
;;
;; For example code below would be recognised as a
;; `mys-expression' composed by three
;; mys-partial-expressions.
;;
;; OrderedDict.popitem(last=True)
;;
;; Putting the curser at the EOL, M-3 M-x mys-add-abbrev
;;
;; would prompt "op" for an abbrev to store, as first
;; `mys-partial-expression' beginns with a "(", which is
;; not taken as proposal.

;;; Code:

(require 'ansi-color)
(ignore-errors (require 'subr-x))
(require 'cc-cmds)
(require 'comint)
(require 'compile)
(require 'custom)
(require 'ert)
(require 'flymake)
(require 'hippie-exp)
(require 'hideshow)
(require 'json)
(require 'shell)
(require 'thingatpt)
(require 'which-func)
(require 'tramp)
(require 'tramp-sh)
(require 'org-loaddefs)
(unless (functionp 'mapcan)
  (require 'cl-extra)
  ;; mapcan doesn't exist in Emacs 25
  (defalias 'mapcan 'cl-mapcan)
  )

;; (require 'org)

(defgroup mys-mode nil
  "Support for the Python programming language, <http://www.python.org/>"
  :group 'languages
  :prefix "mys-")

(defconst mys-version "6.3.1")

(defvar mys-install-directory nil
  "Make sure it exists.")

(defcustom mys-install-directory nil
  "Directory where mys-mode.el and it's subdirectories should be installed.

Needed for completion and other environment stuff only."

  :type 'string
  :tag "mys-install-directory"
  :group 'mys-mode)

(or
 mys-install-directory
 (and (buffer-live-p (ignore-errors (set-buffer (get-buffer "mys--mode.el"))))
      (setq mys-install-directory (ignore-errors (file-name-directory (buffer-file-name (get-buffer  "mys-mode.el"))))))
 (and (buffer-live-p (ignore-errors (set-buffer (get-buffer "mys-components-mode.el"))))
      (setq mys-install-directory (ignore-errors (file-name-directory (buffer-file-name (get-buffer  "mys-components-mode.el")))))))

(defcustom mys-font-lock-defaults-p t
  "If fontification is not required, avoiding it might speed up things."

  :type 'boolean
  :tag "mys-font-lock-defaults-p"
  :group 'mys-mode
  :safe 'booleanp)

(defcustom mys-pythonpath ""
  "Define $PYTHONPATH here, if needed.

Emacs doesn't read .bashrc"

  :type 'string
  :tag "mys-pythonpath"
  :group 'mys-mode)

(defcustom mys-mode-modeline-display "Py"
  "String to display in Emacs modeline."

  :type 'string
  :tag "mys-mode-modeline-display"
  :group 'mys-mode)

(defcustom mys-python2-modeline-display "Py2"
  "String to display in Emacs modeline."

  :type 'string
  :tag "python2-mode-modeline-display"
  :group 'mys-mode)

(defcustom mys-python3-modeline-display "Py3"
  "String to display in Emacs modeline."

  :type 'string
  :tag "python3-mode-modeline-display"
  :group 'mys-mode)

(defcustom mys-imys-modeline-display "IPy"
  "String to display in Emacs modeline."

  :type 'string
  :tag "imys-modeline-display"
  :group 'mys-mode)

(defcustom mys-jython-modeline-display "Jy"
  "String to display in Emacs modeline."

  :type 'string
  :tag "jython-modeline-display"
  :group 'mys-mode)

(defcustom mys-extensions "mys-extensions.el"
  "File where extensions to mys-mode.el should be installed.

Used by virtualenv support."

  :type 'string
  :tag "mys-extensions"
  :group 'mys-mode)

(defcustom info-lookup-mode "python"
  "Which Python documentation should be queried.

Make sure it's accessible from Emacs by \\<emacs-lisp-mode-map> \\[info] ...
See INSTALL-INFO-FILES for help."

  :type 'string
  :tag "info-lookup-mode"
  :group 'mys-mode)

(defcustom mys-fast-process-p nil
  "Use `mys-fast-process'.

Commands prefixed \"mys-fast-...\" suitable for large output

See: large output makes Emacs freeze, lp:1253907

Results arrive in output buffer, which is not in comint-mode"

  :type 'boolean
  :tag "mys-fast-process-p"
  :group 'mys-mode
  :safe 'booleanp)

;; credits to python.el
(defcustom mys-shell-compilation-regexp-alist
  `((,(rx line-start (1+ (any " \t")) "File \""
          (group (1+ (not (any "\"<")))) ; avoid `<stdin>' &c
          "\", line " (group (1+ digit)))
     1 2)
    (,(rx " in file " (group (1+ not-newline)) " on line "
          (group (1+ digit)))
     1 2)
    (,(rx line-start "> " (group (1+ (not (any "(\"<"))))
          "(" (group (1+ digit)) ")" (1+ (not (any "("))) "()")
     1 2))
  "`compilation-error-regexp-alist' for `mys-shell'."
  :type '(alist string)
  :tag "mys-shell-compilation-regexp-alist"
  :group 'mys-mode)

(defcustom mys-shift-require-transient-mark-mode-p t
  "If mys-shift commands require variable `transient-mark-mode' set to t.

Default is t"

  :type 'boolean
  :tag "mys-shift-require-transient-mark-mode-p"
  :group 'mys-mode
  :safe 'booleanp)

(defvar mys-fast-output-buffer "*Python Fast*"
  "Internally used. `buffer-name' for fast-processes.")

(defvar mys-this-result nil
  "Internally used, store return-value.")

(defconst mys-coding-re
  "\\(# *coding[ \t]*=\\|#[ \t]*\-*\-[ \t]*coding:\\|#[ \t]*encoding:\\)[ \t]*\\([[:graph:]+]\\)"
 "Fetch the coding cookie maybe.")

(defcustom mys-comment-auto-fill-p nil
  "When non-nil, fill comments.

Defaut is nil"

  :type 'boolean
  :tag "mys-comment-auto-fill-p"
  :group 'mys-mode
  :safe 'booleanp)

(defcustom mys-sexp-use-expression-p nil
  "If non-nil, `forward-sexp' will call `mys-forward-expression'.

Respective `backward-sexp' will call `mys-backward-expression'
Default is t"
  :type 'boolean
  :tag "mys-sexp-use-expression-p"
  :group 'mys-mode
  :safe 'booleanp)

(defcustom mys-session-p t
  "If commands would use an existing process.

Default is t"

  :type 'boolean
  :tag "mys-session-p"
  :group 'mys-mode
  :safe 'booleanp)

(defvar mys-chars-before " \t\n\r\f"
  "Used by `mys--string-strip'.")

(defvar mys-chars-after " \t\n\r\f"
    "Used by `mys--string-strip'.")

(unless (functionp 'file-local-name)
  (defun file-local-name (file)
    "Return the local name component of FILE.
This function removes from FILE the specification of the remote host
and the method of accessing the host, leaving only the part that
identifies FILE locally on the remote system.
The returned file name can be used directly as argument of
`process-file', `start-file-process', or `shell-command'."
    (or (file-remote-p file 'localname) file)))

(defun mys---emacs-version-greater-23 ()
  "Return `t' if emacs major version is above 23"
  (< 23 (string-to-number (car (split-string emacs-version "\\.")))))

;; (format "execfile(r'%s')\n" file)
(defun mys-execute-file-command (filename)
  "Return the command using FILENAME."
  (format "exec(compile(open(r'%s').read(), r'%s', 'exec')) # MYS-MODE\n" filename filename)
  )

(defun mys--beginning-of-buffer-p ()
  "Returns position, if cursor is at the beginning of buffer.
Return nil otherwise. "
  (when (bobp)(point)))

;;  (setq strip-chars-before  "[ \t\r\n]*")
(defun mys--string-strip (str &optional chars-before chars-after)
  "Return a copy of STR, CHARS removed.
`CHARS-BEFORE' and `CHARS-AFTER' default is \"[ \t\r\n]*\",
i.e. spaces, tabs, carriage returns, newlines and newpages."
  (let ((s-c-b (or chars-before
                   mys-chars-before))
        (s-c-a (or chars-after
                   mys-chars-after))
        (erg str))
    (setq erg (replace-regexp-in-string  s-c-b "" erg))
    (setq erg (replace-regexp-in-string  s-c-a "" erg))
    erg))

(defun mys-toggle-session-p (&optional arg)
  "Switch boolean variable `mys-session-p'.

With optional ARG message state switched to"
  (interactive "p")
  (setq mys-session-p (not mys-session-p))
  (when arg (message "mys-session-p: %s" mys-session-p)))

(defcustom mys-max-help-buffer-p nil
  "If \"\*Mys-Help\*\"-buffer should appear as the only visible.

Default is nil.  In `help-buffer', \"q\" will close it."

  :type 'boolean
  :tag "mys-max-help-buffer-p"
  :group 'mys-mode
  :safe 'booleanp)

(defcustom mys-highlight-error-source-p nil
  "Respective code in source-buffer will be highlighted.

Default is nil.

\\<mys-mode-map> `mys-remove-overlays-at-point' removes that highlighting."
  :type 'boolean
  :tag "mys-highlight-error-source-p"
  :group 'mys-mode)

(defcustom mys-set-pager-cat-p nil
  "If the shell environment variable $PAGER should set to `cat'.

Avoids lp:783828,
 \"Terminal not fully functional\", for help('COMMAND') in mys-shell

When non-nil, imports module `os'"

  :type 'boolean
  :tag "mys-set-pager-cat-p"
  :group 'mys-mode)

(defcustom mys-empty-line-closes-p nil
  "When non-nil, dedent after empty line following block.

if True:
    print(\"Part of the if-statement\")

print(\"Not part of the if-statement\")

Default is nil"

  :type 'boolean
  :tag "mys-empty-line-closes-p"
  :group 'mys-mode)

(defcustom mys-prompt-on-changed-p t
  "Ask for save before a changed buffer is sent to interpreter.

Default is t"

  :type 'boolean
  :tag "mys-prompt-on-changed-p"
  :group 'mys-mode)

(defcustom mys-dedicated-process-p nil
  "If commands executing code use a dedicated shell.

Default is nil

When non-nil and `mys-session-p', an existing
dedicated process is re-used instead of default
 - which allows executing stuff in parallel."
  :type 'boolean
  :tag "mys-dedicated-process-p"
  :group 'mys-mode)

(defcustom mys-store-result-p nil
  "Put resulting string of `mys-execute-...' into `kill-ring'.

Default is nil"

  :type 'boolean
  :tag "mys-dedicated-process-p"
  :group 'mys-mode)

(defvar mys-shell--font-lock-buffer "*PSFLB*"
  "May contain the `mys-buffer-name' currently fontified." )

(defvar mys-return-result-p nil
  "Internally used.

When non-nil, return resulting string of `mys-execute-...'.
Imports will use it with nil.
Default is nil")

(defun mys-toggle-mys-return-result-p ()
  "Toggle value of `mys-return-result-p'."
  (interactive)
  (setq mys-return-result-p (not mys-return-result-p))
  (when (called-interactively-p 'interactive) (message "mys-return-result-p: %s" mys-return-result-p)))

(defcustom mys--execute-use-temp-file-p nil
 "Assume execution at a remote machine.

 where write-access is not given."

 :type 'boolean
 :tag "mys--execute-use-temp-file-p"
 :group 'mys-mode)

(defvar mys--match-paren-forward-p nil
  "Internally used by `mys-match-paren'.")

(defvar mys-new-session-p t
  "Internally used.  See lp:1393882.

Restart `mys-shell' once with new Emacs/`mys-mode'.")

(defcustom mys-electric-close-active-p nil
  "Close completion buffer if no longer needed.

Works around a bug in `choose-completion'.
Default is nil"
  :type 'boolean
  :tag "mys-electric-close-active-p"
  :group 'mys-mode)

(defcustom mys-hide-show-minor-mode-p nil
  "If hide-show minor-mode should be on, default is nil."

  :type 'boolean
  :tag "mys-hide-show-minor-mode-p"
  :group 'mys-mode)

(defcustom mys-load-skeletons-p nil
  "If skeleton definitions should be loaded, default is nil.

If non-nil and variable `abbrev-mode' on, block-skeletons will inserted.
Pressing \"if<SPACE>\" for example will prompt for the if-condition."

  :type 'boolean
  :tag "mys-load-skeletons-p"
  :group 'mys-mode)

(defcustom mys-if-name-main-permission-p t
  "Allow execution of code inside blocks started.

by \"if __name__== '__main__':\".
Default is non-nil"

  :type 'boolean
  :tag "mys-if-name-main-permission-p"
  :group 'mys-mode)

(defcustom mys-use-font-lock-doc-face-p nil
  "If documention string inside of def or class get `font-lock-doc-face'.

`font-lock-doc-face' inherits `font-lock-string-face'.
Call \\<emacs-lisp-mode-map> \\[customize-face] in order to have a effect."

  :type 'boolean
  :tag "mys-use-font-lock-doc-face-p"
  :group 'mys-mode)

(defcustom mys-empty-comment-line-separates-paragraph-p t
  "Consider paragraph start/end lines with nothing inside but comment sign.

Default is  non-nil"
  :type 'boolean
  :tag "mys-empty-comment-line-separates-paragraph-p"
  :group 'mys-mode)

(defcustom mys-indent-honors-inline-comment nil
  "If non-nil, indents to column of inlined comment start.
Default is nil."
  :type 'boolean
  :tag "mys-indent-honors-inline-comment"
  :group 'mys-mode)

(defcustom mys-auto-fill-mode nil
  "If `mys-mode' should set `fill-column'.

according to values
in `mys-comment-fill-column' and `mys-docstring-fill-column'.
Default is  nil"

  :type 'boolean
  :tag "mys-auto-fill-mode"
  :group 'mys-mode)

(defcustom mys-error-markup-delay 4
  "Seconds error's are highlighted in exception buffer."

  :type 'integer
  :tag "mys-error-markup-delay"
  :group 'mys-mode)

(defcustom mys-fast-completion-delay 0.1
  "Used by `mys-fast-send-string'."

  :type 'float
  :tag "mys-fast-completion-delay"
  :group 'mys-mode)

(defcustom mys-new-shell-delay
    (if (eq system-type 'windows-nt)
      2.0
    1.0)

  "If a new comint buffer is connected to Python.
Commands like completion might need some delay."

  :type 'float
  :tag "mys-new-shell-delay"
  :group 'mys-mode)

(defcustom mys-autofill-timer-delay 1
  "Delay when idle."
  :type 'integer
  :tag "mys-autofill-timer-delay"
  :group 'mys-mode)

(defcustom mys-docstring-fill-column 72
  "Value of `fill-column' to use when filling a docstring.
Any non-integer value means do not use a different value of
`fill-column' when filling docstrings."
  :type '(choice (integer)
                 (const :tag "Use the current `fill-column'" t))
  :tag "mys-docstring-fill-column"
  :group 'mys-mode)

(defcustom mys-comment-fill-column 79
  "Value of `fill-column' to use when filling a comment.
Any non-integer value means do not use a different value of
`fill-column' when filling docstrings."
  :type '(choice (integer)
		 (const :tag "Use the current `fill-column'" t))
  :tag "mys-comment-fill-column"
  :group 'mys-mode)

(defcustom mys-fontify-shell-buffer-p nil
  "If code in Python shell should be highlighted as in script buffer.

Default is nil.

If t, related vars like `comment-start' will be set too.
Seems convenient when playing with stuff in Imys shell
Might not be TRT when a lot of output arrives"

  :type 'boolean
  :tag "mys-fontify-shell-buffer-p"
  :group 'mys-mode)

(defvar mys-modeline-display ""
  "Internally used.")

(defcustom mys-modeline-display-full-path-p nil
  "If the full PATH/TO/PYTHON be in modeline.

Default is nil. Note: when `mys-mys-command' is
specified with path, it's shown as an acronym in
`buffer-name' already."

  :type 'boolean
  :tag "mys-modeline-display-full-path-p"
  :group 'mys-mode)

(defcustom mys-modeline-acronym-display-home-p nil
  "If the modeline acronym should contain chars indicating the home-directory.

Default is nil"
  :type 'boolean
  :tag "mys-modeline-acronym-display-home-p"
  :group 'mys-mode)

(defun mys-autopair-check ()
  "Check, if `autopair-mode' is available.

Give some hints, if not."
  (interactive)
  (if (featurep 'autopair)
      't
    (progn
      (message "mys-autopair-check: %s" "Don't see autopair.el. Make sure, it's installed. If not, maybe see source: URL: http://autopair.googlecode.com")
      nil)))

(defvar highlight-indent-active nil)
(defvar autopair-mode nil)

(defvar-local mys--editbeg nil
  "Internally used by `mys-edit-docstring' and others")

(defvar-local mys--editend nil
  "Internally used by `mys-edit-docstring' and others")

(defvar mys--oldbuf nil
  "Internally used by `mys-edit-docstring'.")

(defvar mys-edit-buffer "Edit docstring"
  "Name of the temporary buffer to use when editing.")

(defvar mys--edit-register nil)

(defvar mys-result nil
  "Internally used.  May store result from Python process.

See var `mys-return-result-p' and command `mys-toggle-mys-return-result-p'")

(defvar mys-error nil
  "Takes the error-messages from Python process.")

(defvar mys-mys-completions "*Python Completions*"
  "Buffer name for Mys-shell completions, internally used.")

(defvar mys-imys-completions "*Imys Completions*"
  "Buffer name for Imys-shell completions, internally used.")

(defcustom mys-timer-close-completions-p t
  "If `mys-timer-close-completion-buffer' should run, default is non-nil."

  :type 'boolean
  :tag "mys-timer-close-completions-p"
  :group 'mys-mode)

(defcustom mys-autopair-mode nil
  "If `mys-mode' calls (autopair-mode-on)

Default is nil
Load `autopair-mode' written by Joao Tavora <joaotavora [at] gmail.com>
URL: http://autopair.googlecode.com"
  :type 'boolean
  :tag "mys-autopair-mode"
  :group 'mys-mode)

(defcustom mys-indent-no-completion-p nil
  "If completion function should insert a TAB when no completion found.

Default is nil"
  :type 'boolean
  :tag "mys-indent-no-completion-p"
  :group 'mys-mode)

(defcustom mys-company-pycomplete-p nil
  "Load company-pycomplete stuff.  Default is  nil."

  :type 'boolean
  :tag "mys-company-pycomplete-p"
  :group 'mys-mode)

(defvar mys-last-position nil
    "Used by `mys-help-at-point'.

Avoid repeated call at identic pos.")

(defvar mys-auto-completion-mode-p nil
  "Internally used by `mys-auto-completion-mode'.")

(defvar mys-complete-last-modified nil
  "Internally used by `mys-auto-completion-mode'.")

(defvar mys--auto-complete-timer nil
  "Internally used by `mys-auto-completion-mode'.")

(defvar mys-auto-completion-buffer nil
  "Internally used by `mys-auto-completion-mode'.")

(defvar mys--auto-complete-timer-delay 1
  "Seconds Emacs must be idle to trigger auto-completion.

See `mys-auto-completion-mode'")

(defcustom mys-auto-complete-p nil
  "Run mys-mode's built-in auto-completion via `mys-complete-function'.

Default is  nil."

  :type 'boolean
  :tag "mys-auto-complete-p"
  :group 'mys-mode)

(defcustom mys-tab-shifts-region-p nil
  "If t, TAB will indent/cycle the region, not just the current line.

Default is  nil
See also `mys-tab-indents-region-p'"

  :type 'boolean
  :tag "mys-tab-shifts-region-p"
  :group 'mys-mode)

(defcustom mys-tab-indents-region-p nil
  "When t and first TAB doesn't shift, `indent-region' is called.

Default is  nil
See also `mys-tab-shifts-region-p'"

  :type 'boolean
  :tag "mys-tab-indents-region-p"
  :group 'mys-mode)

(defcustom mys-block-comment-prefix-p t
  "If mys-comment inserts `mys-block-comment-prefix'.

Default is t"

  :type 'boolean
  :tag "mys-block-comment-prefix-p"
  :group 'mys-mode)

(defcustom mys-org-cycle-p nil
  "When non-nil, command `org-cycle' is available at shift-TAB, <backtab>.

Default is nil."
  :type 'boolean
  :tag "mys-org-cycle-p"
  :group 'mys-mode)

(defcustom mys-set-complete-keymap-p  nil
  "If `mys-complete-initialize'.

Sets up enviroment for Pymacs based mys-complete.
 Should load it's keys into `mys-mode-map'
Default is nil.
See also resp. edit `mys-complete-set-keymap'"

  :type 'boolean
  :tag "mys-set-complete-keymap-p"
  :group 'mys-mode)

(defcustom mys-outline-minor-mode-p t
  "If outline minor-mode should be on, default is t."
  :type 'boolean
  :tag "mys-outline-minor-mode-p"
  :group 'mys-mode)

(defvar mys-guess-mys-install-directory-p nil
  "If in cases, `mys-install-directory' isn't set,  `mys-set-load-path' guess it.")

(defcustom mys-guess-mys-install-directory-p nil
  "If in cases, `mys-install-directory' isn't set, `mys-set-load-path' guesses it."
  :type 'boolean
  :tag "mys-guess-mys-install-directory-p"
  :group 'mys-mode)

(defcustom mys-load-pymacs-p nil
  "If Pymacs related stuff should be loaded. Default is nil.

Pymacs has been written by François Pinard and many others.
See original source: http://pymacs.progiciels-bpi.ca"
  :type 'boolean
  :tag "mys-load-pymacs-p"
  :group 'mys-mode)

(defcustom mys-verbose-p nil
  "If functions should report results.

Default is nil."
  :type 'boolean
  :tag "mys-verbose-p"
  :group 'mys-mode)

(defcustom mys-sexp-function nil
  "Called instead of `forward-sexp', `backward-sexp'.

Default is nil."

  :type '(choice

          (const :tag "default" nil)
          (const :tag "mys-forward-partial-expression" mys-forward-partial-expression)
          (const :tag "mys-forward-expression" mys-forward-expression))
  :tag "mys-sexp-function"
  :group 'mys-mode)

(defcustom mys-close-provides-newline t
  "If a newline is inserted, when line after block isn't empty.

Default is non-nil.
When non-nil, `mys-forward-def' and related will work faster"
  :type 'boolean
  :tag "mys-close-provides-newline"
  :group 'mys-mode)

(defcustom mys-dedent-keep-relative-column t
  "If point should follow dedent or kind of electric move to end of line.

Default is t - keep relative position."
  :type 'boolean
  :tag "mys-dedent-keep-relative-column"
  :group 'mys-mode)

(defcustom mys-indent-list-style 'line-up-with-first-element
  "Sets the basic indentation style of lists.

The term ‘list’ here is seen from Emacs Lisp editing purpose.
A list symbolic expression means everything delimited by
brackets, parentheses or braces.

Setting here might be ignored in case of canonical indent.

`line-up-with-first-element' indents to 1+ column
of opening delimiter

def foo (a,
         b):

but ‘one-level-to-beginning-of-statement’ in case of EOL at list-start

def foo (
    a,
    b):

`one-level-to-beginning-of-statement' adds
`mys-indent-offset' to beginning

def long_function_name(
    var_one, var_two, var_three,
    var_four):
    print(var_one)

`one-level-from-first-element' adds `mys-indent-offset' from first element
def foo():
    if (foo &&
            baz):
        bar()"
  :type '(choice
          (const :tag "line-up-with-first-element" line-up-with-first-element)
          (const :tag "one-level-to-beginning-of-statement" one-level-to-beginning-of-statement)
          (const :tag "one-level-from-first-element" one-level-from-first-element)
          )
  :tag "mys-indent-list-style"
  :group 'mys-mode)
(make-variable-buffer-local 'mys-indent-list-style)

(defcustom mys-closing-list-dedents-bos nil
  "When non-nil, indent lists closing delimiter like start-column.

It will be lined up under the first character of
 the line that starts the multi-line construct, as in:

my_list = [
    1, 2, 3,
    4, 5, 6
]

result = some_function_that_takes_arguments(
    \\='a\\=', \\='b\\=', \\='c\\=',
    \\='d\\=', \\='e\\=', \\='f\\='
)

Default is nil, i.e.

my_list = [
    1, 2, 3,
    4, 5, 6
    ]

result = some_function_that_takes_arguments(
    \\='a\\=', \\='b\\=', \\='c\\=',
    \\='d\\=', \\='e\\=', \\='f\\='
    )

Examples from PEP8
URL: https://www.python.org/dev/peps/pep-0008/#indentation"
  :type 'boolean
  :tag "mys-closing-list-dedents-bos"
  :group 'mys-mode)

(defvar mys-imenu-max-items 99)
(defcustom mys-imenu-max-items 99
 "Mys-mode specific `imenu-max-items'."
 :type 'number
 :tag "mys-imenu-max-items"
 :group 'mys-mode)

(defcustom mys-closing-list-space 1
  "Number of chars, closing parenthesis outdent from opening, default is 1."
  :type 'number
  :tag "mys-closing-list-space"
  :group 'mys-mode)

(defcustom mys-max-specpdl-size 99
  "Heuristic exit.
e
Limiting number of recursive calls by `mys-forward-statement' and related.
Default is `max-specpdl-size'.

This threshold is just an approximation.  It might set far higher maybe.

See lp:1235375. In case code is not to navigate due to errors,
command `which-function-mode' and others might make Emacs hang.

Rather exit than."

  :type 'number
  :tag "mys-max-specpdl-size"
  :group 'mys-mode)

(defcustom mys-closing-list-keeps-space nil
  "If non-nil, closing parenthesis dedents onto column of opening.
Adds `mys-closing-list-space'.
Default is nil."
  :type 'boolean
  :tag "mys-closing-list-keeps-space"
  :group 'mys-mode)

(defcustom mys-electric-colon-active-p nil
  "`mys-electric-colon' feature.

Default is nil.  See lp:837065 for discussions.
See also `mys-electric-colon-bobl-only'"
  :type 'boolean
  :tag "mys-electric-colon-active-p"
  :group 'mys-mode)

(defcustom mys-electric-colon-bobl-only t

  "When inserting a colon, do not indent lines unless at beginning of block.

See lp:1207405 resp. `mys-electric-colon-active-p'"

  :type 'boolean
  :tag "mys-electric-colon-bobl-only"
  :group 'mys-mode)

(defcustom mys-electric-yank-active-p nil
  "When non-nil, `yank' will be followed by an `indent-according-to-mode'.

Default is nil"
  :type 'boolean
  :tag "mys-electric-yank-active-p"
  :group 'mys-mode)

(defcustom mys-electric-colon-greedy-p nil
  "If `mys-electric-colon' should indent to the outmost reasonable level.

If nil, default, it will not move from at any reasonable level."
  :type 'boolean
  :tag "mys-electric-colon-greedy-p"
  :group 'mys-mode)

(defcustom mys-electric-colon-newline-and-indent-p nil
  "If non-nil, `mys-electric-colon' will call `newline-and-indent'.

Default is nil."
  :type 'boolean
  :tag "mys-electric-colon-newline-and-indent-p"
  :group 'mys-mode)

(defcustom mys-electric-comment-p nil
  "If \"#\" should call `mys-electric-comment'. Default is nil."
  :type 'boolean
  :tag "mys-electric-comment-p"
  :group 'mys-mode)

(defcustom mys-electric-comment-add-space-p nil
  "If `mys-electric-comment' should add a space.  Default is nil."
  :type 'boolean
  :tag "mys-electric-comment-add-space-p"
  :group 'mys-mode)

(defcustom mys-mark-decorators nil
  "If decorators should be marked too.

Default is nil.

Also used by navigation"
  :type 'boolean
  :tag "mys-mark-decorators"
  :group 'mys-mode)

(defcustom mys-defun-use-top-level-p nil
 "If `beginning-of-defun', `end-of-defun' calls function `top-level' form.

Default is nil.

beginning-of defun, `end-of-defun' forms use
commands `mys-backward-top-level', `mys-forward-top-level'

`mark-defun' marks function `top-level' form at point etc."

 :type 'boolean
  :tag "mys-defun-use-top-level-p"
 :group 'mys-mode)

(defcustom mys-tab-indent t
  "Non-nil means TAB in Python mode calls `mys-indent-line'."
  :type 'boolean
  :tag "mys-tab-indent"
  :group 'mys-mode)

(defcustom mys-return-key 'mys-newline-and-indent
  "Which command <return> should call."
  :type '(choice

          (const :tag "default" mys-newline-and-indent)
          (const :tag "newline" newline)
          (const :tag "mys-newline-and-indent" mys-newline-and-indent)
          (const :tag "mys-newline-and-dedent" mys-newline-and-dedent)
          )
  :tag "mys-return-key"
  :group 'mys-mode)

(defcustom mys-complete-function 'mys-fast-complete
  "When set, enforces function todo completion, default is `mys-fast-complete'.

Might not affect Imys, as `mys-shell-complete' is the only known working here.
Normally `mys-mode' knows best which function to use."
  :type '(choice

          (const :tag "default" nil)
          (const :tag "Pymacs and company based mys-complete" mys-complete)
          (const :tag "mys-shell-complete" mys-shell-complete)
          (const :tag "mys-indent-or-complete" mys-indent-or-complete)
	  (const :tag "mys-fast-complete" mys-fast-complete)
          )
  :tag "mys-complete-function"
  :group 'mys-mode)

(defcustom mys-encoding-string " # -*- coding: utf-8 -*-"
  "Default string specifying encoding of a Python file."
  :type 'string
  :tag "mys-encoding-string"
  :group 'mys-mode)

(defcustom mys-shebang-startstring "#! /bin/env"
  "Detecting the shell in head of file."
  :type 'string
  :tag "mys-shebang-startstring"
  :group 'mys-mode)

(defcustom mys-flake8-command ""
  "Which command to call flake8.

If empty, `mys-mode' will guess some"
  :type 'string
  :tag "mys-flake8-command"
  :group 'mys-mode)

(defcustom mys-flake8-command-args ""
  "Arguments used by flake8.

Default is the empty string."
  :type 'string
  :tag "mys-flake8-command-args"
  :group 'mys-mode)

(defvar mys-flake8-history nil
  "Used by flake8, resp. `mys-flake8-command'.

Default is nil.")

(defcustom mys-message-executing-temporary-file t
  "If execute functions using a temporary file should message it.

Default is t.
Messaging increments the prompt counter of Imys shell."
  :type 'boolean
  :tag "mys-message-executing-temporary-file"
  :group 'mys-mode)

(defcustom mys-execute-no-temp-p nil
  "Seems Emacs-24.3 provided a way executing stuff without temporary files."
  :type 'boolean
  :tag "mys-execute-no-temp-p"
  :group 'mys-mode)

(defcustom mys-lhs-inbound-indent 1
  "When line starts a multiline-assignment.

How many colums indent more than opening bracket, brace or parenthesis."
  :type 'integer
  :tag "mys-lhs-inbound-indent"
  :group 'mys-mode)

(defcustom mys-continuation-offset 2
  "Additional amount of offset to give for some continuation lines.
Continuation lines are those that immediately follow a backslash
terminated line."
  :type 'integer
  :tag "mys-continuation-offset"
  :group 'mys-mode)

(defcustom mys-indent-tabs-mode nil
  "Mys-mode starts `indent-tabs-mode' with the value specified here.

Default is nil."
  :type 'boolean
  :tag "mys-indent-tabs-mode"
  :group 'mys-mode)

(defcustom mys-smart-indentation nil
  "Guess `mys-indent-offset'.  Default is nil.

Setting it to t seems useful only in cases where customizing
`mys-indent-offset' is no option - for example because the
indentation step is unknown or differs inside the code.

When this variable is non-nil, `mys-indent-offset' is guessed from existing code.

Which might slow down the proceeding."

  :type 'boolean
  :tag "mys-smart-indentation"
  :group 'mys-mode)

(defcustom mys-block-comment-prefix "##"
  "String used by \\[comment-region] to comment out a block of code.
This should follow the convention for non-indenting comment lines so
that the indentation commands won't get confused (i.e., the string
should be of the form `#x...' where `x' is not a blank or a tab, and
 `...' is arbitrary).  However, this string should not end in whitespace."
  :type 'string
  :tag "mys-block-comment-prefix"
  :group 'mys-mode)

(defcustom mys-indent-offset 4
  "Amount of offset per level of indentation.
`\\[mys-guess-indent-offset]' can usually guess a good value when
you're editing someone else's Python code."
  :type 'integer
  :tag "mys-indent-offset"
  :group 'mys-mode)
(make-variable-buffer-local 'mys-indent-offset)

(defcustom mys-backslashed-lines-indent-offset 5
  "Amount of offset per level of indentation of backslashed.
No semantic indent,  which diff to `mys-indent-offset' indicates"
  :type 'integer
  :tag "mys-backslashed-lines-indent-offset"
  :group 'mys-mode)

(defcustom mys-shell-completion-native-output-timeout 5.0
  "Time in seconds to wait for completion output before giving up."
  :version "25.1"
  :type 'float
  :tag "mys-shell-completion-native-output-timeout"
  :group 'mys-mode)

(defcustom mys-shell-completion-native-try-output-timeout 1.0
  "Time in seconds to wait for *trying* native completion output."
  :version "25.1"
  :type 'float
  :tag "mys-shell-completion-native-try-output-timeout"
  :group 'mys-mode)

(defvar mys-shell--first-prompt-received-output-buffer nil)
(defvar mys-shell--first-prompt-received nil)

(defcustom mys-shell-first-prompt-hook nil
  "Hook run upon first (non-pdb) shell prompt detection.
This is the place for shell setup functions that need to wait for
output.  Since the first prompt is ensured, this helps the
current process to not hang while waiting.  This is useful to
safely attach setup code for long-running processes that
eventually provide a shell."
  :version "25.1"
  :type 'hook
  :tag "mys-shell-first-prompt-hook"
  :group 'mys-mode)

(defvar mys-shell--parent-buffer nil)

(defvar mys-shell--package-depth 10)

(defcustom mys-indent-comments t
  "When t, comment lines are indented."
  :type 'boolean
  :tag "mys-indent-comments"
  :group 'mys-mode)

(defcustom mys-uncomment-indents-p nil
  "When non-nil, after uncomment indent lines."
  :type 'boolean
  :tag "mys-uncomment-indents-p"
  :group 'mys-mode)

(defcustom mys-separator-char "/"
  "The character, which separates the system file-path components.

Precedes guessing when not empty, returned by function `mys-separator-char'."
  :type 'string
  :tag "mys-separator-char"
  :group 'mys-mode)

(defvar mys-separator-char "/"
  "Values set by defcustom only will not be seen in batch-mode.")

(and
 ;; used as a string finally
 ;; kept a character not to break existing customizations
 (characterp mys-separator-char)(setq mys-separator-char (char-to-string mys-separator-char)))

(defcustom mys-custom-temp-directory ""
  "If set, will take precedence over guessed values from `mys-temp-directory'.

Default is the empty string."
  :type 'string
  :tag "mys-custom-temp-directory"
  :group 'mys-mode)

(defcustom mys-beep-if-tab-change t
  "Ring the bell if `tab-width' is changed.
If a comment of the form

                           \t# vi:set tabsize=<number>:

is found before the first code line when the file is entered, and the
current value of (the general Emacs variable) `tab-width' does not
equal <number>, `tab-width' is set to <number>, a message saying so is
displayed in the echo area, and if `mys-beep-if-tab-change' is non-nil
the Emacs bell is also rung as a warning."
  :type 'boolean
  :tag "mys-beep-if-tab-change"
  :group 'mys-mode)

(defcustom mys-jump-on-exception t
  "Jump to innermost exception frame in Python output buffer.
When this variable is non-nil and an exception occurs when running
Python code synchronously in a subprocess, jump immediately to the
source code of the innermost traceback frame."
  :type 'boolean
  :tag "mys-jump-on-exception"
  :group 'mys-mode)

(defcustom mys-ask-about-save t
  "If not nil, ask about which buffers to save before executing some code.
Otherwise, all modified buffers are saved without asking."
  :type 'boolean
  :tag "mys-ask-about-save"
  :group 'mys-mode)

(defcustom mys-delete-function 'delete-char
  "Function called by `mys-electric-delete' when deleting forwards."
  :type 'function
  :tag "mys-delete-function"
  :group 'mys-mode)

(defcustom mys-import-check-point-max
  20000
  "Max number of characters to search Java-ish import statement.

When `mys-mode' tries to calculate the shell
-- either a CPython or a Jython shell --
it looks at the so-called `shebang'.
If that's not available, it looks at some of the
file heading imports to see if they look Java-like."
  :type 'integer
  :tag "mys-import-check-point-max
"
  :group 'mys-mode)

;; (setq mys-shells
;; (list
;; ""
;; 'imys
;; 'imys2.7
;; 'imys3
;; 'jython
;; 'python
;; 'python2
;; 'python3
;; 'pypy
;; ))

(defcustom mys-known-shells
  (list
   "imys"
   "imys2.7"
   "imys3"
   "jython"
   "python"
   "python2"
   "python3"
   "pypy"
   )
  "A list of available shells instrumented for commands.
Expects its executables installed

Edit for your needs."
  :type '(repeat string)
  :tag "mys-shells"
  :group 'mys-mode)

(defcustom mys-known-shells-extended-commands
  (list "imys"
	"python"
	"python3"
	"pypy"
	)
  "A list of shells for finer grained commands.
like `mys-execute-statement-imys'
Expects its executables installed

Edit for your needs."
  :type '(repeat string)
  :tag "mys-shells"
  :group 'mys-mode)

(defun mys-install-named-shells-fix-doc (ele)
  "Internally used by `mys-load-named-shells'.

Argument ELE: a shell name, a string."
  (cond ((string-match "^i" ele)
	 (concat "I" (capitalize (substring ele 1))))
	((string-match "^pypy" ele)
	 "PyPy")
	(t (capitalize ele))))

(defcustom mys-jython-packages
  '("java" "javax")
  "Imported packages that imply `jython-mode'."
  :type '(repeat string)
  :tag "mys-jython-packages
"
  :group 'mys-mode)

(defcustom mys-current-defun-show t
  "If `mys-current-defun' should jump to the definition.

Highlights it while waiting MYS-WHICH-FUNC-DELAY seconds.
Afterwards returning to previous position.

Default is t."

  :type 'boolean
  :tag "mys-current-defun-show"
  :group 'mys-mode)

(defcustom mys-current-defun-delay 2
  "`mys-current-defun' waits MYS-WHICH-FUNC-DELAY seconds.

Before returning to previous position."

  :type 'number
  :tag "mys-current-defun-delay"
  :group 'mys-mode)

(defcustom mys-mys-send-delay 1
  "Seconds to wait for output, used by `mys--send-...' functions.

See also `mys-imys-send-delay'"

  :type 'number
  :tag "mys-mys-send-delay"
  :group 'mys-mode)

(defcustom mys-python3-send-delay 1
  "Seconds to wait for output, used by `mys--send-...' functions.

See also `mys-imys-send-delay'"

  :type 'number
  :tag "mys-python3-send-delay"
  :group 'mys-mode)

(defcustom mys-imys-send-delay 1
  "Seconds to wait for output, used by `mys--send-...' functions.

See also `mys-mys-send-delay'"

  :type 'number
  :tag "mys-imys-send-delay"
  :group 'mys-mode)

(defcustom mys-master-file nil
  "Execute the named master file instead of the buffer's file.

Default is nil.
With relative path variable `default-directory' is prepended.

Beside you may set this variable in the file's local
variable section, e.g.:

                           # Local Variables:
                           # mys-master-file: \"master.py\"
                           # End:"
  :type 'string
  :tag "mys-master-file"
  :group 'mys-mode)
(make-variable-buffer-local 'mys-master-file)

(defcustom mys-pychecker-command "pychecker"
  "Shell command used to run Pychecker."
  :type 'string
  :tag "mys-pychecker-command"
  :group 'mys-mode)

(defcustom mys-pychecker-command-args "--stdlib"
  "String arguments to be passed to pychecker."
  :type 'string
  :tag "mys-pychecker-command-args"
  :group 'mys-mode)

(defcustom mys-pyflakes-command "pyflakes"
  "Shell command used to run Pyflakes."
  :type 'string
  :tag "mys-pyflakes-command"
  :group 'mys-mode)

(defcustom mys-pyflakes-command-args ""
  "String arguments to be passed to pyflakes.

Default is \"\""
  :type 'string
  :tag "mys-pyflakes-command-args"
  :group 'mys-mode)

(defcustom mys-pep8-command "pep8"
  "Shell command used to run pep8."
  :type 'string
  :tag "mys-pep8-command"
  :group 'mys-mode)

(defcustom mys-pep8-command-args ""
  "String arguments to be passed to pylint.

Default is \"\""
  :type 'string
  :tag "mys-pep8-command-args"
  :group 'mys-mode)

(defcustom mys-pyflakespep8-command (concat mys-install-directory "/pyflakespep8.py")
  "Shell command used to run `pyflakespep8'."
  :type 'string
  :tag "mys-pyflakespep8-command"
  :group 'mys-mode)

(defcustom mys-pyflakespep8-command-args ""
  "String arguments to be passed to pyflakespep8.

Default is \"\""
  :type 'string
  :tag "mys-pyflakespep8-command-args"
  :group 'mys-mode)

(defcustom mys-pylint-command "pylint"
  "Shell command used to run Pylint."
  :type 'string
  :tag "mys-pylint-command"
  :group 'mys-mode)

(defcustom mys-pylint-command-args '("--errors-only")
  "String arguments to be passed to pylint.

Default is \"--errors-only\""
  :type '(repeat string)
  :tag "mys-pylint-command-args"
  :group 'mys-mode)

(defvar mys-pdbtrack-input-prompt "^[(<]*[Ii]?[Pp]y?db[>)]+ *"
  "Recognize the prompt.")

(defcustom mys-shell-input-prompt-1-regexp ">>> "
  "A regular expression to match the input prompt of the shell."
  :type 'regexp
  :tag "mys-shell-input-prompt-1-regexp"
  :group 'mys-mode)

(defcustom mys-shell-input-prompt-2-regexp "[.][.][.]:? "
  "A regular expression to match the input prompt.

Applies to the shell after the first line of input."
  :type 'string
  :tag "mys-shell-input-prompt-2-regexp"
  :group 'mys-mode)

(defvar mys-shell-imys-input-prompt-1-regexp "In \\[[0-9]+\\]: "
  "Regular Expression matching input prompt of python shell.
It should not contain a caret (^) at the beginning.")

(defvar mys-shell-imys-input-prompt-2-regexp "   \\.\\.\\.: "
  "Regular Expression matching second level input prompt of python shell.
It should not contain a caret (^) at the beginning.")

(defcustom mys-shell-input-prompt-2-regexps
  '(">>> " "\\.\\.\\. "                 ; Python
    "In \\[[0-9]+\\]: "                 ; Imys
    "   \\.\\.\\.: "                    ; Imys
    ;; Using ipdb outside Imys may fail to cleanup and leave static
    ;; Imys prompts activated, this adds some safeguard for that.
    "In : " "\\.\\.\\.: ")
  "List of regular expressions matching input prompts."
  :type '(repeat string)
  :version "24.4"
  :tag "mys-shell-input-prompt-2-regexps"
  :group 'mys-mode)

(defcustom mys-shell-input-prompt-regexps
  '(">>> " "\\.\\.\\. "                 ; Python
    "In \\[[0-9]+\\]: "                 ; Imys
    "   \\.\\.\\.: "                    ; Imys
    ;; Using ipdb outside Imys may fail to cleanup and leave static
    ;; Imys prompts activated, this adds some safeguard for that.
    "In : " "\\.\\.\\.: ")
  "List of regular expressions matching input prompts."
  :type '(repeat regexp)
  :version "24.4"
  :tag "mys-shell-input-prompt-regexps"
  :group 'mys-mode)

(defvar mys-imys-output-prompt-re "^Out\\[[0-9]+\\]: "
  "A regular expression to match the output prompt of Imys.")

(defcustom mys-shell-output-prompt-regexps
  '(""                                  ; Python
    "Out\\[[0-9]+\\]: "                 ; Imys
    "Out :")                            ; ipdb safeguard
  "List of regular expressions matching output prompts."
  :type '(repeat string)
  :version "24.4"
  :tag "mys-shell-output-prompt-regexps"
  :group 'mys-mode)

(defvar mys-pydbtrack-input-prompt "^[(]*ipydb[>)]+ "
  "Recognize the pydb-prompt.")
;; (setq mys-pdbtrack-input-prompt "^[(< \t]*[Ii]?[Pp]y?db[>)]*.*")

(defvar mys-imys-input-prompt-re "In \\[?[0-9 ]*\\]?: *\\|^[ ]\\{3\\}[.]\\{3,\\}: *"
  "A regular expression to match the Imys input prompt.")

(defvar mys-shell-prompt-regexp
  (concat "\\("
	  (mapconcat 'identity
		     (delq nil
			   (list
			    mys-shell-input-prompt-1-regexp
			    mys-shell-input-prompt-2-regexp
			    mys-imys-input-prompt-re
			    mys-imys-output-prompt-re
			    mys-pdbtrack-input-prompt
			    mys-pydbtrack-input-prompt
			    "[.]\\{3,\\}:? *"
			    ))
		     "\\|")
	  "\\)")
  "Internally used by `mys-fast-filter'.
`ansi-color-filter-apply' might return
Result: \"\\nIn [10]:    ....:    ....:    ....: 1\\n\\nIn [11]: \"")

(defvar mys-fast-filter-re
  (concat "\\("
	  (mapconcat 'identity
		     (delq nil
			   (list
			    mys-shell-input-prompt-1-regexp
			    mys-shell-input-prompt-2-regexp
			    mys-imys-input-prompt-re
			    mys-imys-output-prompt-re
			    mys-pdbtrack-input-prompt
			    mys-pydbtrack-input-prompt
			    "[.]\\{3,\\}:? *"
			    ))
		     "\\|")
	  "\\)")
  "Internally used by `mys-fast-filter'.
`ansi-color-filter-apply' might return
Result: \"\\nIn [10]:    ....:    ....:    ....: 1\\n\\nIn [11]: \"")

(defcustom mys-shell-prompt-detect-p nil
  "Non-nil enables autodetection of interpreter prompts."
  :type 'boolean
  :safe 'booleanp
  :version "24.4"
  :tag "mys-shell-prompt-detect-p"
  :group 'mys-mode)

(defcustom mys-shell-prompt-read-only t
  "If non-nil, the python prompt is read only.

Setting this variable will only effect new shells."
  :type 'boolean
  :tag "mys-shell-prompt-read-only"
  :group 'mys-mode)

(setq mys-fast-filter-re
  (concat "\\("
	  (mapconcat 'identity
		     (delq nil
			   (list
			    mys-shell-input-prompt-1-regexp
			    mys-shell-input-prompt-2-regexp
			    mys-imys-input-prompt-re
			    mys-imys-output-prompt-re
			    mys-pdbtrack-input-prompt
			    mys-pydbtrack-input-prompt
			    "[.]\\{3,\\}:? *"
			    ))
		     "\\|")
	  "\\)"))

(defcustom mys-honor-IMYSDIR-p nil
  "When non-nil imys-history file is constructed by $IMYSDIR.

Default is nil.
Otherwise value of `mys-imys-history' is used."
  :type 'boolean
  :tag "mys-honor-IMYSDIR-p"
  :group 'mys-mode)

(defcustom mys-imys-history "~/.imys/history"
  "Imys-history default file.

Used when `mys-honor-IMYSDIR-p' is nil - th default"

  :type 'string
  :tag "mys-imys-history"
  :group 'mys-mode)

(defcustom mys-honor-PYTHONHISTORY-p nil
  "When non-nil mys-history file is set by $PYTHONHISTORY.

Default is nil.
Otherwise value of `mys-mys-history' is used."
  :type 'boolean
  :tag "mys-honor-PYTHONHISTORY-p"
  :group 'mys-mode)

(defcustom mys-mys-history "~/.python_history"
  "Mys-history default file.

Used when `mys-honor-PYTHONHISTORY-p' is nil (default)."

  :type 'string
  :tag "mys-mys-history"
  :group 'mys-mode)

(defcustom mys-switch-buffers-on-execute-p nil
  "When non-nil switch to the Python output buffer.

If `mys-keep-windows-configuration' is t, this will take precedence
over setting here."

  :type 'boolean
  :tag "mys-switch-buffers-on-execute-p"
  :group 'mys-mode)
;; made buffer-local as pdb might need t in all circumstances
(make-variable-buffer-local 'mys-switch-buffers-on-execute-p)

(defcustom mys-split-window-on-execute 'just-two
  "When non-nil split windows.

Default is just-two - when code is send to interpreter.
Splits screen into source-code buffer and current `mys-shell' result.
Other buffer will be hidden that way.

When set to t, `mys-mode' tries to reuse existing windows
and will split only if needed.

With \\='always, results will displayed in a new window.

Both t and `always' is experimental still.

For the moment: If a multitude of mys-shells/buffers should be
visible, open them manually and set `mys-keep-windows-configuration' to t.

See also `mys-keep-windows-configuration'"
  :type `(choice
          (const :tag "default" just-two)
	  (const :tag "reuse" t)
          (const :tag "no split" nil)
	  (const :tag "just-two" just-two)
          (const :tag "always" always))
  :tag "mys-split-window-on-execute"
  :group 'mys-mode)

;; (defun mys-toggle-mys-split-window-on-execute ()
;;   "Toggle between customized value and nil."
;;   (interactive)
;;   (setq mys-split-window-on-execute (not mys-split-window-on-execute))
;;   (when (called-interactively-p 'interactive)
;;     (message "mys-split-window-on-execute: %s" mys-split-window-on-execute)
;;     mys-split-window-on-execute))

(defcustom mys-split-window-on-execute-threshold 3
  "Maximal number of displayed windows.

Honored, when `mys-split-window-on-execute' is t, i.e. \"reuse\".
Don't split when max number of displayed windows is reached."
  :type 'number
  :tag "mys-split-window-on-execute-threshold"
  :group 'mys-mode)

(defcustom mys-split-windows-on-execute-function 'split-window-vertically
  "How window should get splitted to display results of mys-execute-... functions."
  :type '(choice (const :tag "split-window-vertically" split-window-vertically)
                 (const :tag "split-window-horizontally" split-window-horizontally)
                 )
  :tag "mys-split-windows-on-execute-function"
  :group 'mys-mode)

(defcustom mys-shell-fontify-p 'input
  "Fontify current input in Python shell. Default is input.

INPUT will leave output unfontified.

At any case only current input gets fontified."
  :type '(choice (const :tag "Default" all)
                 (const :tag "Input" input)
		 (const :tag "Nil" nil)
                 )
  :tag "mys-shell-fontify-p"
  :group 'mys-mode)

(defcustom mys-hide-show-keywords
  '("class"    "def"    "elif"    "else"    "except"
    "for"      "if"     "while"   "finally" "try"
    "with"     "match"  "case")
  "Keywords composing visible heads."
  :type '(repeat string)
  :tag "mys-hide-show-keywords
"
  :group 'mys-mode)

(defcustom mys-hide-show-hide-docstrings t
  "Controls if doc strings can be hidden by hide-show."
  :type 'boolean
  :tag "mys-hide-show-hide-docstrings"
  :group 'mys-mode)

(defcustom mys-hide-comments-when-hiding-all t
  "Hide the comments too when you do an `hs-hide-all'."
  :type 'boolean
  :tag "mys-hide-comments-when-hiding-all"
  :group 'mys-mode)

(defcustom mys-outline-mode-keywords
  '("class"    "def"    "elif"    "else"    "except"
    "for"      "if"     "while"   "finally" "try"
    "with"     "match"  "case")
  "Keywords composing visible heads."
  :type '(repeat string)
  :tag "mys-outline-mode-keywords
"
  :group 'mys-mode)

(defcustom mys-mode-hook nil
  "Hook run when entering Python mode."

  :type 'hook
  :tag "mys-mode-hook"
  :group 'mys-mode
  )

;; (defcustom mys-shell-name
;;   (if (eq system-type 'windows-nt)
;;       "C:/Python27/python"
;;     "python")

;;   "A PATH/TO/EXECUTABLE or default value `mys-shell' may look for.

;; If no shell is specified by command.

;; On Windows default is C:/Python27/python
;; --there is no garantee it exists, please check your system--

;; Else python"
;;   :type 'string
;;   :tag "mys-shell-name
;; "
;;   :group 'mys-mode)

(defcustom mys-mys-command
  (if (eq system-type 'windows-nt)
      ;; "C:\\Python27\\python.exe"
      "python"
   ;; "C:/Python33/Lib/site-packages/Imys"
    "python")

  "Make sure directory in in the PATH-variable.

Windows: edit in \"Advanced System Settings/Environment Variables\"
Commonly \"C:\\\\Python27\\\\python.exe\"
With Anaconda for example the following works here:
\"C:\\\\Users\\\\My-User-Name\\\\Anaconda\\\\Scripts\\\\python.exe\"

Else /usr/bin/python"

  :type 'string
  :tag "mys-mys-command
"
  :group 'mys-mode)

(defvaralias 'mys-shell-name 'mys-mys-command)

(defcustom mys-mys-command-args '("-i")
  "String arguments to be used when starting a Python shell."
  :type '(repeat string)
  :tag "mys-mys-command-args"
  :group 'mys-mode)

(defcustom mys-python2-command
  (if (eq system-type 'windows-nt)
      "C:\\Python27\\python"
    ;; "python2"
    "python2")

  "Make sure, the directory where python.exe resides in in the PATH-variable.

Windows: If needed, edit in
\"Advanced System Settings/Environment Variables\"
Commonly
\"C:\\\\Python27\\\\python.exe\"
With Anaconda for example the following works here:
\"C:\\\\Users\\\\My-User-Name\\\\Anaconda\\\\Scripts\\\\python.exe\"

Else /usr/bin/python"

  :type 'string
  :tag "mys-python2-command
"
  :group 'mys-mode)

(defcustom mys-python2-command-args '("-i")
  "String arguments to be used when starting a Python shell."
  :type '(repeat string)
  :tag "mys-python2-command-args"
  :group 'mys-mode)

;; "/usr/bin/python3"
(defcustom mys-python3-command
  (if (eq system-type 'windows-nt)
    "C:/Python33/python"
    "python3")

  "A PATH/TO/EXECUTABLE or default value `mys-shell' may look for.

Unless shell is specified by command.

On Windows see C:/Python3/python.exe
--there is no garantee it exists, please check your system--

At GNU systems see /usr/bin/python3"

  :type 'string
  :tag "mys-python3-command
"
  :group 'mys-mode)

(defcustom mys-python3-command-args '("-i")
  "String arguments to be used when starting a Python3 shell."
  :type '(repeat string)
  :tag "mys-python3-command-args"
  :group 'mys-mode)

(defcustom mys-imys-command
  (if (eq system-type 'windows-nt)
      ;; "imys"
    "C:\\Python27\\python"
    ;; "C:/Python33/Lib/site-packages/Imys"
    ;; "/usr/bin/imys"
    "imys")

  "A PATH/TO/EXECUTABLE or default value.

`M-x Imys RET' may look for,
Unless Imys-shell is specified by command.

On Windows default is \"C:\\\\Python27\\\\python.exe\"
While with Anaconda for example the following works here:
\"C:\\\\Users\\\\My-User-Name\\\\Anaconda\\\\Scripts\\\\imys.exe\"

Else /usr/bin/imys"

  :type 'string
  :tag "mys-imys-command
"
  :group 'mys-mode)

(defcustom mys-imys-command-args
  (if (eq system-type 'windows-nt)
      '("-i" "C:\\Python27\\Scripts\\imys-script.py")
    ;; --simple-prompt seems to exist from Imys 5.
    (if (string-match "^[0-4]" (shell-command-to-string (concat "imys" " -V")))
	'("--pylab" "--automagic")
      '("--pylab" "--automagic" "--simple-prompt")))
  "String arguments to be used when starting a Imys shell.

At Windows make sure imys-script.py is PATH.
Also setting PATH/TO/SCRIPT here should work, for example;
C:\\Python27\\Scripts\\imys-script.py
With Anaconda the following is known to work:
\"C:\\\\Users\\\\My-User-Name\\\\Anaconda\\\\Scripts\\\\imys-script-py\""
  :type '(repeat string)
  :tag "mys-imys-command-args"
  :group 'mys-mode)

(defcustom mys-jython-command
  (if (eq system-type 'windows-nt)
      '("jython")
    '("/usr/bin/jython"))

  "A PATH/TO/EXECUTABLE or default value.
`M-x Jython RET' may look for, if no Jython-shell is specified by command.

Not known to work at windows
Default /usr/bin/jython"

  :type '(repeat string)
  :tag "mys-jython-command
"
  :group 'mys-mode)

(defcustom mys-jython-command-args '("-i")
  "String arguments to be used when starting a Jython shell."
  :type '(repeat string)
  :tag "mys-jython-command-args"
  :group 'mys-mode)

(defcustom mys-shell-toggle-1 mys-python2-command
  "A PATH/TO/EXECUTABLE or default value used by `mys-toggle-shell'."
  :type 'string
  :tag "mys-shell-toggle-1"
  :group 'mys-mode)

(defcustom mys-shell-toggle-2 mys-python3-command
  "A PATH/TO/EXECUTABLE or default value used by `mys-toggle-shell'."
  :type 'string
  :tag "mys-shell-toggle-2"
  :group 'mys-mode)

(defcustom mys--imenu-create-index-p nil
  "Non-nil means Python mode creates and displays an index menu.

Of functions and global variables."
  :type 'boolean
  :tag "mys--imenu-create-index-p"
  :group 'mys-mode)

(defvar mys-history-filter-regexp "\\`\\s-*\\S-?\\S-?\\s-*\\'\\|'''/tmp/"
  "Input matching this regexp is not saved on the history list.
Default ignores all inputs of 0, 1, or 2 non-blank characters.")

(defcustom mys-match-paren-mode nil
  "Non-nil means, cursor will jump to beginning or end of a block.
This vice versa, to beginning first.
Sets `mys-match-paren-key' in `mys-mode-map'.
Customize `mys-match-paren-key' which key to use."
  :type 'boolean
  :tag "mys-match-paren-mode"
  :group 'mys-mode)

(defcustom mys-match-paren-key "%"
  "String used by \\[comment-region] to comment out a block of code.
This should follow the convention for non-indenting comment lines so
that the indentation commands won't get confused (i.e., the string
should be of the form `#x...' where `x' is not a blank or a tab, and
                               `...' is arbitrary).
However, this string should not end in whitespace."
  :type 'string
  :tag "mys-match-paren-key"
  :group 'mys-mode)

(defcustom mys-kill-empty-line t
  "If t, `mys-indent-forward-line' kills empty lines."
  :type 'boolean
  :tag "mys-kill-empty-line"
  :group 'mys-mode)

(defcustom mys-imenu-show-method-args-p nil
  "Controls echoing of arguments of functions & methods in the Imenu buffer.
When non-nil, arguments are printed."
  :type 'boolean
  :tag "mys-imenu-show-method-args-p"
  :group 'mys-mode)

(defcustom mys-use-local-default nil
  "If t, `mys-shell' will use `mys-shell-local-path'.

Alternative to default Python.

Making switch between several virtualenv's easier,`mys-mode' should
deliver an installer, named-shells pointing to virtualenv's will be available."
  :type 'boolean
  :tag "mys-use-local-default"
  :group 'mys-mode)

(defcustom mys-edit-only-p nil
  "Don't check for installed Python executables.

Default is nil.

See bug report at launchpad, lp:944093."
  :type 'boolean
  :tag "mys-edit-only-p"
  :group 'mys-mode)

(defcustom mys-force-mys-shell-name-p nil
  "When t, execution specified in `mys-shell-name' is enforced.

Possibly shebang doesn't take precedence."

  :type 'boolean
  :tag "mys-force-mys-shell-name-p"
  :group 'mys-mode)

(defcustom mys-mode-v5-behavior-p nil
  "Execute region through `shell-command-on-region'.

As v5 did it - lp:990079.
This might fail with certain chars - see UnicodeEncodeError lp:550661"

  :type 'boolean
  :tag "mys-mode-v5-behavior-p"
  :group 'mys-mode)

(defun mys-toggle-mys-mode-v5-behavior ()
  "Switch the values of `mys-mode-v5-behavior-p'."
  (interactive)
  (setq mys-mode-v5-behavior-p (not mys-mode-v5-behavior-p))
  (when (called-interactively-p 'interactive)
    (message "mys-mode-v5-behavior-p: %s" mys-mode-v5-behavior-p)))

(defun mys-toggle-mys-verbose-p ()
  "Switch the values of `mys-verbose-p'.

Default is nil.
If on, messages value of `mys-result' for instance."
  (interactive)
  (setq mys-verbose-p (not mys-verbose-p))
  (when (called-interactively-p 'interactive)
    (message "mys-verbose-p: %s" mys-verbose-p)))

(defcustom mys-trailing-whitespace-smart-delete-p nil
  "Default is nil.

When t, `mys-mode' calls
\(add-hook \\='before-save-hook \\='delete-trailing-whitespace nil \\='local)

Also commands may delete trailing whitespace by the way.
When editing other peoples code, this may produce a larger diff than expected"
  :type 'boolean
  :tag "mys-trailing-whitespace-smart-delete-p"
  :group 'mys-mode)

(defcustom mys-newline-delete-trailing-whitespace-p t
  "Delete trailing whitespace maybe left by `mys-newline-and-indent'.

Default is t. See lp:1100892"
  :type 'boolean
  :tag "mys-newline-delete-trailing-whitespace-p"
  :group 'mys-mode)

(defcustom mys--warn-tmp-files-left-p nil
  "Warn, when `mys-temp-directory' contains files susceptible being left.

WRT previous Mys-mode sessions. See also lp:987534."
  :type 'boolean
  :tag "mys--warn-tmp-files-left-p"
  :group 'mys-mode)

(defcustom mys-complete-ac-sources '(ac-source-pycomplete)
  "List of `auto-complete' sources assigned to `ac-sources'.

In `mys-complete-initialize'.

Default is known to work an Ubuntu 14.10 - having mys-
mode, pymacs and auto-complete-el, with the following minimal
Emacs initialization:

\(require \\='pymacs)
\(require \\='auto-complete-config)
\(ac-config-default)"
  :type 'hook
  :tag "mys-complete-ac-sources"
  :options '(ac-source-pycomplete ac-source-abbrev ac-source-dictionary ac-source-words-in-same-mode-buffers)
  :group 'mys-mode)

(defcustom mys-remove-cwd-from-path t
  "Whether to allow loading of Python modules from the current directory.
If this is non-nil, Emacs removes '' from sys.path when starting
a Python process.  This is the default, for security
reasons, as it is easy for the Python process to be started
without the user's realization (e.g. to perform completion)."
  :type 'boolean
  :tag "mys-remove-cwd-from-path"
  :group 'mys-mode)

(defcustom mys-shell-local-path ""
  "`mys-shell' will use EXECUTABLE indicated here incl. path.

If `mys-use-local-default' is non-nil."

  :type 'string
  :tag "mys-shell-local-path"
  :group 'mys-mode)

(defcustom mys-mys-edit-version ""
  "When not empty, fontify according to Python version specified.

Default is the empty string, a useful value \"python3\" maybe.

When empty, version is guessed via `mys-choose-shell'."

  :type 'string
  :tag "mys-mys-edit-version"
  :group 'mys-mode)

(defcustom mys-imys-execute-delay 0.3
  "Delay needed by execute functions when no Imys shell is running."
  :type 'float
  :tag "mys-imys-execute-delay"
  :group 'mys-mode)

(defvar mys-shell-completion-setup-code
  "try:
    import readline
except ImportError:
    def __COMPLETER_all_completions(text): []
else:
    import rlcompleter
    readline.set_completer(rlcompleter.Completer().complete)
    def __COMPLETER_all_completions(text):
        import sys
        completions = []
        try:
            i = 0
            while True:
                res = readline.get_completer()(text, i)
                if not res: break
                i += 1
                completions.append(res)
        except NameError:
            pass
        return completions"
  "Code used to setup completion in Python processes.")

(defvar mys-shell-module-completion-code "';'.join(__COMPLETER_all_completions('''%s'''))"
  "Python code used to get completions separated by semicolons for imports.")

(defvar mys-imys-module-completion-code
  "import Imys
version = Imys.__version__
if \'0.10\' < version:
    from Imys.core.completerlib import module_completion
"
  "For Imys v0.11 or greater.
Use the following as the value of this variable:

';'.join(module_completion('''%s'''))")

(defvar mys-imys-module-completion-string
  "';'.join(module_completion('''%s'''))"
  "See also `mys-imys-module-completion-code'.")

(defcustom mys--imenu-create-index-function 'mys--imenu-index
  "Switch between `mys--imenu-create-index-new'  and series 5. index-machine."
  :type '(choice
	  (const :tag "'mys--imenu-create-index-new, also lists modules variables " mys--imenu-create-index-new)

	  (const :tag "mys--imenu-create-index, series 5. index-machine" mys--imenu-create-index)
	  (const :tag "mys--imenu-index, honor type annotations" mys--imenu-index)

	  )
  :tag "mys--imenu-create-index-function"
  :group 'mys-mode)

(defvar mys-line-re "^"
  "Used by generated functions." )

(defvar mys-input-filter-re "\\`\\s-*\\S-?\\S-?\\s-*\\'"
  "Input matching this regexp is not saved on the history list.
Default ignores all inputs of 0, 1, or 2 non-blank characters.")

(defvar strip-chars-before  "\\`[ \t\r\n]*"
  "Regexp indicating which chars shall be stripped before STRING.

See also `string-chars-preserve'")

(defvar strip-chars-after  "[ \t\r\n]*\\'"
  "Regexp indicating which chars shall be stripped after STRING.

See also `string-chars-preserve'")

(defcustom mys-docstring-style 'pep-257-nn
  "Implemented styles:

 are DJANGO, ONETWO, PEP-257, PEP-257-NN,SYMMETRIC, and NIL.

A value of NIL won't care about quotes
position and will treat docstrings a normal string, any other
value may result in one of the following docstring styles:

DJANGO:

    \"\"\"
    Process foo, return bar.
    \"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

ONETWO:

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

PEP-257:

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

PEP-257-NN:

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

SYMMETRIC:

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\""
  :type '(choice

          (const :tag "Don't format docstrings" nil)
          (const :tag "Django's coding standards style." django)
          (const :tag "One newline and start and Two at end style." onetwo)
          (const :tag "PEP-257 with 2 newlines at end of string." pep-257)
          (const :tag "PEP-257-nn with 1 newline at end of string." pep-257-nn)
          (const :tag "Symmetric style." symmetric))
  :tag "mys-docstring-style"
  :group 'mys-mode)

(defcustom mys-execute-directory nil
  "Stores the file's default directory-name mys-execute-... functions act upon.

Used by Mys-shell for output of `mys-execute-buffer' and related commands.
See also `mys-use-current-dir-when-execute-p'"
  :type 'string
  :tag "mys-execute-directory"
  :group 'mys-mode)

(defcustom mys-use-current-dir-when-execute-p t
  "Current directory used for output.

See also `mys-execute-directory'"
  :type 'boolean
  :tag "mys-use-current-dir-when-execute-p"
  :group 'mys-mode)

(defcustom mys-keep-shell-dir-when-execute-p nil
  "Don't change Python shell's current working directory when sending code.

See also `mys-execute-directory'"
  :type 'boolean
  :tag "mys-keep-shell-dir-when-execute-p"
  :group 'mys-mode)

(defcustom mys-fileless-buffer-use-default-directory-p t
  "`default-directory' sets current working directory of Python output shell.

When `mys-use-current-dir-when-execute-p' is non-nil and no buffer-file exists."
  :type 'boolean
  :tag "mys-fileless-buffer-use-default-directory-p"
  :group 'mys-mode)

(defcustom mys-check-command "pychecker --stdlib"
  "Command used to check a Python file."
  :type 'string
  :tag "mys-check-command"
  :group 'mys-mode)

;; (defvar mys-this-abbrevs-changed nil
;;   "Internally used by `mys-mode-hook'.")

(defvar mys-buffer-name nil
  "Internal use.

The buffer last output was sent to.")

(defvar mys-orig-buffer-or-file nil
  "Internal use.")

(defcustom mys-keep-windows-configuration nil
  "Takes precedence over:

 `mys-split-window-on-execute' and `mys-switch-buffers-on-execute-p'.
See lp:1239498

To suppres window-changes due to error-signaling also.
Set `mys-keep-windows-configuration' onto \\'force

Default is nil"

  :type '(choice
          (const :tag "nil" nil)
          (const :tag "t" t)
          (const :tag "force" 'force))
  :tag "mys-keep-windows-configuration"
  :group 'mys-mode)

(defvar mys-output-buffer "*Python Output*"
      "Used if `mys-mode-v5-behavior-p' is t.

Otherwise output buffer is created dynamically according to version process.")

(defcustom mys-force-default-output-buffer-p nil
  "Enforce sending output to the default output `buffer-name'.

Set by defvar `mys-output-buffer'
Bug #31 - wrong fontification caused by string-delimiters in output"

  :type 'boolean
  :tag "mys-force-default-output-buffer-p"
  :group 'mys-mode)

(defcustom mys-shell-unbuffered t
  "Should shell output be unbuffered?.
When non-nil, this may prevent delayed and missing output in the
Python shell.  See commentary for details."
  :type 'boolean
  :safe 'booleanp
  :tag "mys-shell-unbuffered"
  :group 'mys-mode)

(defcustom mys-shell-process-environment nil
  "List of overridden environment variables for subprocesses to inherit.
Each element should be a string of the form ENVVARNAME=VALUE.
When this variable is non-nil, values are exported into the
process environment before starting it.  Any variables already
present in the current environment are superseded by variables
set here."
  :type '(repeat string)
  :tag "mys-shell-process-environment"
  :group 'mys-mode)

(defcustom mys-shell-extra-pythonpaths nil
  "List of extra pythonpaths for Python shell.
When this variable is non-nil, values added at the beginning of
the PYTHONPATH before starting processes.  Any values present
here that already exists in PYTHONPATH are moved to the beginning
of the list so that they are prioritized when looking for
modules."
  :type '(repeat string)
  :tag "mys-shell-extra-pythonpaths"
  :group 'mys-mode)

(defcustom mys-shell-exec-path nil
  "List of paths for searching executables.
When this variable is non-nil, values added at the beginning of
the PATH before starting processes.  Any values present here that
already exists in PATH are moved to the beginning of the list so
that they are prioritized when looking for executables."
  :type '(repeat string)
  :tag "mys-shell-exec-path"
  :group 'mys-mode)

(defcustom mys-shell-remote-exec-path nil
  "List of paths to be ensured remotely for searching executables.
When this variable is non-nil, values are exported into remote
hosts PATH before starting processes.  Values defined in
`mys-shell-exec-path' will take precedence to paths defined
here.  Normally you wont use this variable directly unless you
plan to ensure a particular set of paths to all Python shell
executed through tramp connections."
  :version "25.1"
  :type '(repeat string)
  :tag "mys-shell-remote-exec-path"
  :group 'mys-mode)

(defcustom mys-shell-virtualenv-root nil
  "Path to virtualenv root.
This variable, when set to a string, makes the environment to be
modified such that shells are started within the specified
virtualenv."
  :type '(choice (const nil) string)
  :tag "mys-shell-virtualenv-root"
  :group 'mys-mode)

(defvar mys-shell-completion-native-redirect-buffer
  " *Py completions redirect*"
  "Buffer to be used to redirect output of readline commands.")

(defvar mys-shell--block-prompt nil
  "Input block prompt for inferior python shell.
Do not set this variable directly, instead use
`mys-shell-prompt-set-calculated-regexps'.")

(defvar mys-shell-output-filter-in-progress nil)
(defvar mys-shell-output-filter-buffer nil)

(defvar mys-shell--prompt-calculated-input-regexp nil
  "Calculated input prompt regexp for inferior python shell.
Do not set this variable directly.

Iff `mys-shell--prompt-calculated-input-regexp'
or `mys-shell--prompt-calculated-output-regexp' are set
`mys-shell-prompt-set-calculated-regexps' isn't run.")

(defvar mys-shell--prompt-calculated-output-regexp nil
  "Calculated output prompt regexp for inferior python shell.

`mys-shell-prompt-set-calculated-regexps'
Do not set this variable directly.

Iff `mys-shell--prompt-calculated-input-regexp'
or `mys-shell--prompt-calculated-output-regexp' are set
`mys-shell-prompt-set-calculated-regexps' isn't run.")

(defvar mys-shell-prompt-output-regexp ""
  "See `mys-shell-prompt-output-regexps'.")

(defvar mys-shell-prompt-output-regexps
  '(""                                  ; Python
    "Out\\[[0-9]+\\]: "                 ; Imys
    "Out :")                            ; ipdb safeguard
  "List of regular expressions matching output prompts.")

(defvar mys-underscore-word-syntax-p t
  "This is set later by defcustom, only initial value here.

If underscore chars should be of `syntax-class' `word', not of `symbol'.
Underscores in word-class makes `forward-word'.
Travels the indentifiers. Default is t.
See also command `mys-toggle-underscore-word-syntax-p'")

(defvar mys-autofill-timer nil)
(defvar mys-fill-column-orig fill-column
  "Used to reset fill-column")

;; defvared value isn't updated maybe
(defvar mys-mode-message-string
  (if (or (string= "mys-mode.el" (buffer-name))
	  (ignore-errors (string-match "mys-mode.el" (mys--buffer-filename-remote-maybe))))
      "mys-mode.el"
    "mys-components-mode")
  "Internally used. Reports the `mys-mode' branch.")

;; defvared value isn't updated maybe
(setq mys-mode-message-string
  (if (or (string= "mys-mode.el" (buffer-name))
	  (ignore-errors (string-match "mys-mode.el" (mys--buffer-filename-remote-maybe))))
      "mys-mode.el"
    "mys-components-mode"))

(defun mys-escaped-p (&optional pos)
  "Return t if char at POS is preceded by an odd number of backslashes. "
  (save-excursion
    (when pos (goto-char pos))
    (< 0 (% (abs (skip-chars-backward "\\\\")) 2))))

(defvar mys-mode-syntax-table nil
  "Give punctuation syntax to ASCII that normally has symbol.

Syntax or has word syntax and isn't a letter.")

(setq mys-mode-syntax-table
      (let ((table (make-syntax-table)))
        ;; Give punctuation syntax to ASCII that normally has symbol
        ;; syntax or has word syntax and isn't a letter.
        (let ((symbol (string-to-syntax "_"))
              (sst (standard-syntax-table)))
          (dotimes (i 128)
            (unless (= i ?_)
              (if (equal symbol (aref sst i))
                  (modify-syntax-entry i "." table)))))
        (modify-syntax-entry ?$ "." table)
        (modify-syntax-entry ?% "." table)
        ;; exceptions
        (modify-syntax-entry ?# "<" table)
        (modify-syntax-entry ?\n ">" table)
        (modify-syntax-entry ?' "\"" table)
        (modify-syntax-entry ?` "$" table)
        (if mys-underscore-word-syntax-p
            (modify-syntax-entry ?\_ "w" table)
          (modify-syntax-entry ?\_ "_" table))
        table))

(defvar mys-imys-completion-command-string nil
  "Select command according to Imys version.

Either `mys-imys0.10-completion-command-string'
or `mys-imys0.11-completion-command-string'.

`mys-imys0.11-completion-command-string' also covers version 0.12")

(defvar mys-imys0.10-completion-command-string
  "print(';'.join(__IP.Completer.all_completions('%s'))) #MYS-MODE SILENT\n"
  "The string send to imys to query for all possible completions.")

(defvar mys-imys0.11-completion-command-string
  "print(';'.join(get_imys().Completer.all_completions('%s'))) #MYS-MODE SILENT\n"
  "The string send to imys to query for all possible completions.")

(defvar mys-encoding-string-re "^[ \t]*#[ \t]*-\\*-[ \t]*coding:.+-\\*-"
  "Matches encoding string of a Python file.")

(defvar mys-shebang-regexp "#![ \t]?\\([^ \t\n]+\\)[ \t]*\\([biptj]+ython[^ \t\n]*\\)"
  "Detecting the shell in head of file.")

(defvar mys-temp-directory
  (let ((ok '(lambda (x)
               (and x
                    (setq x (expand-file-name x)) ; always true
                    (file-directory-p x)
                    (file-writable-p x)
                    x)))
        erg)
    (or
     (and (not (string= "" mys-custom-temp-directory))
          (if (funcall ok mys-custom-temp-directory)
              (setq erg (expand-file-name mys-custom-temp-directory))
            (if (file-directory-p (expand-file-name mys-custom-temp-directory))
                (error "Mys-custom-temp-directory set but not writable")
              (error "Mys-custom-temp-directory not an existing directory"))))
     (and (funcall ok (getenv "TMPDIR"))
          (setq erg (getenv "TMPDIR")))
     (and (funcall ok (getenv "TEMP/TMP"))
          (setq erg (getenv "TEMP/TMP")))
     (and (funcall ok "/usr/tmp")
          (setq erg "/usr/tmp"))
     (and (funcall ok "/tmp")
          (setq erg "/tmp"))
     (and (funcall ok "/var/tmp")
          (setq erg "/var/tmp"))
     (and (eq system-type 'darwin)
          (funcall ok "/var/folders")
          (setq erg "/var/folders"))
     (and (or (eq system-type 'ms-dos)(eq system-type 'windows-nt))
          (funcall ok (concat "c:" mys-separator-char "Users"))
          (setq erg (concat "c:" mys-separator-char "Users")))
     ;; (funcall ok ".")
     (error
      "Couldn't find a usable temp directory -- set `mys-temp-directory'"))
    (when erg (setq mys-temp-directory erg)))
  "Directory used for temporary files created by a *Python* process.
By default, guesses the first directory from this list that exists and that you
can write into: the value (if any) of the environment variable TMPDIR,
/usr/tmp, /tmp, /var/tmp, or the current directory.

 `mys-custom-temp-directory' will take precedence when setq")

(defvar mys-exec-command nil
  "Internally used.")

(defvar mys-which-bufname "Python")

(defvar mys-pychecker-history nil)

(defvar mys-pyflakes-history nil)

(defvar mys-pep8-history nil)

(defvar mys-pyflakespep8-history nil)

(defvar mys-pylint-history nil)

(defvar mys-mode-output-map nil
  "Keymap used in *Python Output* buffers.")

(defvar hs-hide-comments-when-hiding-all t
  "Defined in hideshow.el, silence compiler warnings here.")

(defvar mys-shell-complete-debug nil
  "For interal use when debugging, stores completions." )

(defvar mys-debug-p nil
  "Activate extra code for analysis and test purpose when non-nil.

Temporary files are not deleted. Other functions might implement
some logging, etc.
For normal operation, leave it set to nil, its default.
Defined with a defvar form to allow testing the loading of new versions.")

(defun mys-toggle-mys-debug-p ()
  "Toggle value of `mys-debug-p'."
  (interactive)
  (setq mys-debug-p (not mys-debug-p))
  (when (called-interactively-p 'interactive) (message "mys-debug-p: %s" mys-debug-p)))

(defcustom mys-shell-complete-p nil
  "Enable native completion.

Set TAB accordingly."

  :type 'boolean
  :tag "mys-shell-complete-p"
  :group 'mys-mode)
(make-variable-buffer-local 'mys-shell-complete-p)

(defcustom mys-section-start "# {{"
  "Delimit arbitrary chunks of code."
  :type 'string
  :tag "mys-section-start"
  :group 'mys-mode)

(defcustom mys-section-end "# }}"
  "Delimit arbitrary chunks of code."
  :type 'string
  :tag "mys-section-end"
  :group 'mys-mode)

(defvar mys-section-re mys-section-start)

(defvar mys-last-window-configuration nil
  "Internal use.

Restore `mys-restore-window-configuration'.")

(defvar mys-exception-buffer nil
  "Will be set internally.

Remember source buffer where error might occur.")

(defvar mys-string-delim-re "\\(\"\"\"\\|'''\\|\"\\|'\\)"
  "When looking at beginning of string.")

(defvar mys-labelled-re "[ \\t]*:[[:graph:]]+"
  "When looking at label.")
;; (setq mys-labelled-re "[ \\t]*:[[:graph:]]+")

(defvar mys-expression-skip-regexp "[^ (=:#\t\r\n\f]"
  "Expression possibly composing a `mys-expression'.")

(defvar mys-expression-skip-chars "^ (=#\t\r\n\f"
  "Chars composing a `mys-expression'.")

(setq mys-expression-skip-chars "^ [{(=#\t\r\n\f")

(defvar mys-expression-re "[^ =#\t\r\n\f]+"
  "Expression possibly composing a `mys-expression'.")

(defcustom mys-paragraph-re paragraph-start
  "Allow Python specific `paragraph-start' var."
  :type 'string
  :tag "mys-paragraph-re"
  :group 'mys-mode)

(defvar mys-not-expression-regexp "[ .=#\t\r\n\f)]+"
  "Regexp indicated probably will not compose a `mys-expression'.")

(defvar mys-not-expression-chars " #\t\r\n\f"
  "Chars indicated probably will not compose a `mys-expression'.")

(defvar mys-partial-expression-backward-chars "^] .=,\"'()[{}:#\t\r\n\f"
  "Chars indicated possibly compose a `mys-partial-expression', skip it.")
;; (setq mys-partial-expression-backward-chars "^] .=,\"'()[{}:#\t\r\n\f")

(defvar mys-partial-expression-forward-chars "^ .\"')}]:#\t\r\n\f")
;; (setq mys-partial-expression-forward-chars "^ .\"')}]:#\t\r\n\f")

(defvar mys-partial-expression-re (concat "[" mys-partial-expression-backward-chars (substring mys-partial-expression-forward-chars 1) "]+"))
(setq mys-partial-expression-re (concat "[" mys-partial-expression-backward-chars "]+"))

(defvar mys-statement-re mys-partial-expression-re)
(defvar mys-indent-re ".+"
  "This var is introduced for regularity only.")
(setq mys-indent-re ".+")

(defvar mys-operator-re "[ \t]*\\(\\.\\|+\\|-\\|*\\|//\\|//\\|&\\|%\\||\\|\\^\\|>>\\|<<\\|<\\|<=\\|>\\|>=\\|==\\|!=\\|=\\)[ \t]*"
  "Matches most of Python syntactical meaningful characters.

See also `mys-assignment-re'")

;; (setq mys-operator-re "[ \t]*\\(\\.\\|+\\|-\\|*\\|//\\|//\\|&\\|%\\||\\|\\^\\|>>\\|<<\\|<\\|<=\\|>\\|>=\\|==\\|!=\\|=\\)[ \t]*")

(defvar mys-delimiter-re "\\(\\.[[:alnum:]]\\|,\\|;\\|:\\)[ \t\n]"
  "Delimiting elements of lists or other programming constructs.")

(defvar mys-line-number-offset 0
  "When an exception occurs as a result of `mys-execute-region'.

A subsequent `mys-up-exception' needs the line number where the region
started, in order to jump to the correct file line.
This variable is set in `mys-execute-region' and used in `mys--jump-to-exception'.")

(defvar mys-match-paren-no-use-syntax-pps nil)

(defvar mys-traceback-line-re
  "[ \t]+File \"\\([^\"]+\\)\", line \\([0-9]+\\)"
  "Regular expression that describes tracebacks.")

(defvar mys-XXX-tag-face 'mys-XXX-tag-face)

(defvar mys-pseudo-keyword-face 'mys-pseudo-keyword-face)

(defface mys-variable-name-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face method decorators."
  :tag "mys-variable-name-face"
  :group 'mys-mode)

(defvar mys-variable-name-face 'mys-variable-name-face)

(defvar mys-number-face 'mys-number-face)

(defvar mys-decorators-face 'mys-decorators-face)

(defvar mys-object-reference-face 'mys-object-reference-face)

(defvar mys-builtins-face 'mys-builtins-face)

(defvar mys-class-name-face 'mys-class-name-face)

(defvar mys-def-face 'mys-def-face)

(defvar mys-exception-name-face 'mys-exception-name-face)

(defvar mys-import-from-face 'mys-import-from-face)

(defvar mys-def-class-face 'mys-def-class-face)

(defvar mys-try-if-face 'mys-try-if-face)

(defvar mys-file-queue nil
  "Queue of Python temp files awaiting execution.
Currently-active file is at the head of the list.")

(defvar jython-mode-hook nil
  "Hook called by `jython-mode'.
`jython-mode' also calls `mys-mode-hook'.")

(defvar mys-shell-hook nil
  "Hook called by `mys-shell'.")

;; (defvar mys-font-lock-keywords nil)

(defvar mys-dotted-expression-syntax-table
  (let ((table (make-syntax-table mys-mode-syntax-table)))
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?."_" table)
    table)
  "Syntax table used to identify Python dotted expressions.")

(defvar mys-default-template "if"
  "Default template to expand by `mys-expand-template'.
Updated on each expansion.")

(defvar-local mys-already-guessed-indent-offset nil
  "Internal use by `mys-indent-line'.

When `this-command' is `eq' to `last-command', use the guess already computed.")

(defvar mys-shell-template "
\(defun NAME (&optional argprompt)
  \"Start an DOCNAME interpreter in another window.

With optional \\\\[universal-argument] user is prompted
for options to pass to the DOCNAME interpreter. \"
  (interactive \"P\")
  (let\* ((mys-shell-name \"FULLNAME\"))
    (mys-shell argprompt)
    (when (called-interactively-p 'interactive)
      (switch-to-buffer (current-buffer))
      (goto-char (point-max)))))
")

;; Constants
(defconst mys-block-closing-keywords-re
  "[ \t]*\\_<\\(return\\|raise\\|break\\|continue\\|pass\\)\\_>[ \n\t]"
  "Matches the beginning of a class, method or compound statement.")

(setq mys-block-closing-keywords-re
  "[ \t]*\\_<\\(return\\|raise\\|break\\|continue\\|pass\\)\\_>[ \n\t]")

(defconst mys-finally-re
  "[ \t]*\\_<finally:"
  "Regular expression matching keyword which closes a try-block.")

(defconst mys-except-re "[ \t]*\\_<except\\_>"
  "Matches the beginning of a `except' block.")

;; (defconst mys-except-re
;;   "[ \t]*\\_<except\\_>[:( \n\t]*"
;;   "Regular expression matching keyword which composes a try-block.")

(defconst mys-return-re
  ".*:?[ \t]*\\_<\\(return\\)\\_>[ \n\t]*"
  "Regular expression matching keyword which typically closes a function.")

(defconst mys-decorator-re
  "[ \t]*@[^ ]+\\_>[ \n\t]*"
  "Regular expression matching keyword which typically closes a function.")

(defcustom mys-outdent-re-raw
  (list
   "case"
   "elif"
   "else"
   "except"
   "finally"
   )
  "Used by `mys-outdent-re'."
  :type '(repeat string)
  :tag "mys-outdent-re-raw"
  :group 'mys-mode
  )

(defconst mys-outdent-re
  (concat
   "[ \t]*"
   (regexp-opt mys-outdent-re-raw 'symbols)
   "[)\t]*")
  "Regular expression matching statements to be dedented one level.")

(defcustom mys-no-outdent-re-raw
  (list
   "break"
   "continue"
   "import"
   "pass"
   "raise"
   "return")
  "Uused by `mys-no-outdent-re'."
  :type '(repeat string)
  :tag "mys-no-outdent-re-raw"
  :group 'mys-mode)

(defconst mys-no-outdent-re
  (concat
   "[ \t]*"
   (regexp-opt mys-no-outdent-re-raw 'symbols)
   "[)\t]*$")
"Regular expression matching lines not to augment indent after.

See `mys-no-outdent-re-raw' for better readable content")

(defconst mys-assignment-re "\\(\\_<\\w+\\_>[[:alnum:]:, \t]*[ \t]*\\)\\(=\\|+=\\|*=\\|%=\\|&=\\|^=\\|<<=\\|-=\\|/=\\|**=\\||=\\|>>=\\|//=\\)\\(.*\\)"
  "If looking at the beginning of an assignment.")

;; 'name':
(defconst mys-dict-re "'\\_<\\w+\\_>':")

(defcustom mys-block-re-raw
  (list
   "async def"
   "async for"
   "async with"
   "class"
   "def"
   "for"
   "if"
   "match"
   "try"
   "while"
   "with"
   )
  "Matches the beginning of a compound statement but not it's clause."
  :type '(repeat string)
  :tag "mys-block-re-raw"
  :group 'mys-mode)

(defconst mys-block-re (concat
		       ;; "[ \t]*"
		       (regexp-opt mys-block-re-raw 'symbols)
		       "[:( \n\t]"
		       )
  "Matches the beginning of a compound statement.")

(defconst mys-minor-block-re-raw (list
				      "async for"
				      "async with"
                                      "case"
				      "except"
				      "for"
				      "if"
                                      "match"
				      "try"
				      "with"
				      )
  "Matches the beginning of an case `for', `if', `try', `except' or `with' block.")

(defconst mys-minor-block-re
  (concat
   "[ \t]*"
   (regexp-opt mys-minor-block-re-raw 'symbols)
   "[:( \n\t]")

  "Regular expression matching lines not to augment indent after.

See `mys-minor-block-re-raw' for better readable content")

(defconst mys-try-re "[ \t]*\\_<try\\_>[: \n\t]"
  "Matches the beginning of a `try' block.")

(defconst mys-case-re "[ \t]*\\_<case\\_>[: \t][^:]*:"
  "Matches a `case' clause.")

(defconst mys-match-re "[ \t]*\\_<match\\_>[: \t][^:]*:"
  "Matches a `case' clause.")

(defconst mys-for-re "[ \t]*\\_<\\(async for\\|for\\)\\_> +[[:alpha:]_][[:alnum:]_]* +in +[[:alpha:]_][[:alnum:]_()]* *[: \n\t]"
  "Matches the beginning of a `try' block.")

(defconst mys-if-re "[ \t]*\\_<if\\_> +[^\n\r\f]+ *[: \n\t]"
  "Matches the beginning of an `if' block.")

(defconst mys-else-re "[ \t]*\\_<else:[ \n\t]"
  "Matches the beginning of an `else' block.")

(defconst mys-elif-re "[ \t]*\\_<\\elif\\_>[( \n\t]"
  "Matches the beginning of a compound if-statement's clause exclusively.")

;; (defconst mys-elif-block-re "[ \t]*\\_<elif\\_> +[[:alpha:]_][[:alnum:]_]* *[: \n\t]"
;;   "Matches the beginning of an `elif' block.")

(defconst mys-class-re "[ \t]*\\_<\\(class\\)\\_>[ \n\t]"
  "Matches the beginning of a class definition.")

(defconst mys-def-or-class-re "[ \t]*\\_<\\(async def\\|class\\|def\\)\\_>[ \n\t]+\\([[:alnum:]_]*\\)"
  "Matches the beginning of a class- or functions definition.

Second group grabs the name")

;; (setq mys-def-or-class-re "[ \t]*\\_<\\(async def\\|class\\|def\\)\\_>[ \n\t]")

;; (defconst mys-def-re "[ \t]*\\_<\\(async def\\|def\\)\\_>[ \n\t]"
(defconst mys-def-re "[ \t]*\\_<\\(def\\|async def\\)\\_>[ \n\t]"
  "Matches the beginning of a functions definition.")

(defcustom mys-block-or-clause-re-raw
  (list
   "async for"
   "async with"
   "async def"
   "async class"
   "class"
   "def"
   "elif"
   "else"
   "except"
   "finally"
   "for"
   "if"
   "try"
   "while"
   "with"
   "match"
   "case"
   )
  "Matches the beginning of a compound statement or it's clause."
  :type '(repeat string)
  :tag "mys-block-or-clause-re-raw"
  :group 'mys-mode)

(defvar mys-block-or-clause-re
  (concat
   "[ \t]*"
   (regexp-opt  mys-block-or-clause-re-raw 'symbols)
   "[( \t]*.*:?")
  "See `mys-block-or-clause-re-raw', which it reads.")

(defcustom mys-extended-block-or-clause-re-raw
  (list
   "async def"
   "async for"
   "async with"
   "class"
   "def"
   "elif"
   "else"
   "except"
   "finally"
   "for"
   "if"
   "try"
   "while"
   "with"
   "match"
   "case"
   )
  "Matches the beginning of a compound statement or it's clause."
  :type '(repeat string)
  :tag "mys-extended-block-or-clause-re-raw"
  :group 'mys-mode)

(defconst mys-extended-block-or-clause-re
  (concat
   "[ \t]*"
   (regexp-opt  mys-extended-block-or-clause-re-raw 'symbols)
   "[( \t:]+")
  "See `mys-block-or-clause-re-raw', which it reads.")

(defun mys--arglist-indent (nesting &optional indent-offset)
  "Internally used by `mys-compute-indentation'"
  (if
      (and (eq 1 nesting)
           (save-excursion
             (back-to-indentation)
             (looking-at mys-extended-block-or-clause-re)))
      (progn
        (back-to-indentation)
        (1+ (+ (current-column) (* 2 (or indent-offset mys-indent-offset)))))
    (+ (current-indentation) (or indent-offset mys-indent-offset))))

(defconst mys-clause-re mys-extended-block-or-clause-re
  "See also mys-minor-clause re.")

(defcustom mys-minor-clause-re-raw
  (list
   "case"
   "elif"
   "else"
   "except"
   "finally"
   )
  "Matches the beginning of a clause."
    :type '(repeat string)
    :tag "mys-minor-clause-re-raw"
    :group 'mys-mode)

(defconst mys-minor-clause-re
  (concat
   "[ \t]*"
   (regexp-opt  mys-minor-clause-re-raw 'symbols)
   "[( \t]*.*:")
  "See `mys-minor-clause-re-raw', which it reads.")

(defcustom mys-top-level-re
  (concat
   "^[a-zA-Z_]"
   (regexp-opt  mys-extended-block-or-clause-re-raw)
   "[( \t]*.*:?")
  "A form which starts at zero indent level, but is not a comment."
  :type '(regexp)
  :tag "mys-top-level-re"
  :group 'mys-mode
  )

(defvar mys-comment-re comment-start
  "Needed for normalized processing.")

(defconst mys-block-keywords
   (regexp-opt mys-block-or-clause-re-raw 'symbols)
  "Matches known keywords opening a block.

Customizing `mys-block-or-clause-re-raw'  will change values here")

(defconst mys-try-clause-re
  (concat
   "[ \t]*\\_<\\("
   (mapconcat 'identity
              (list
               "else"
               "except"
               "finally")
              "\\|")
   "\\)\\_>[( \t]*.*:")
  "Matches the beginning of a compound try-statement's clause.")

(defcustom mys-compilation-regexp-alist
  `((,(rx line-start (1+ (any " \t")) "File \""
          (group (1+ (not (any "\"<")))) ; avoid `<stdin>' &c
          "\", line " (group (1+ digit)))
     1 2)
    (,(rx " in file " (group (1+ not-newline)) " on line "
          (group (1+ digit)))
     1 2)
    (,(rx line-start "> " (group (1+ (not (any "(\"<"))))
          "(" (group (1+ digit)) ")" (1+ (not (any "("))) "()")
     1 2))
  "Fetch errors from Mys-shell.
hooked into `compilation-error-regexp-alist'"
  :type '(alist string)
  :tag "mys-compilation-regexp-alist"
  :group 'mys-mode)

(defun mys--quote-syntax (n)
  "Put `syntax-table' property correctly on triple quote.
Used for syntactic keywords.  N is the match number (1, 2 or 3)."
  ;; Given a triple quote, we have to check the context to know
  ;; whether this is an opening or closing triple or whether it's
  ;; quoted anyhow, and should be ignored.  (For that we need to do
  ;; the same job as `syntax-ppss' to be correct and it seems to be OK
  ;; to use it here despite initial worries.) We also have to sort
  ;; out a possible prefix -- well, we don't _have_ to, but I think it
  ;; should be treated as part of the string.

  ;; Test cases:
  ;;  ur"""ar""" x='"' # """
  ;; x = ''' """ ' a
  ;; '''
  ;; x '"""' x """ \"""" x
  (save-excursion
    (goto-char (match-beginning 0))
    (cond
     ;; Consider property for the last char if in a fenced string.
     ((= n 3)
      (let* ((syntax (parse-partial-sexp (point-min) (point))))
	(when (eq t (nth 3 syntax))	; after unclosed fence
	  (goto-char (nth 8 syntax))	; fence position
	  ;; (skip-chars-forward "uUrR")	; skip any prefix
	  ;; Is it a matching sequence?
	  (if (eq (char-after) (char-after (match-beginning 2)))
	      (eval-when-compile (string-to-syntax "|"))))))
     ;; Consider property for initial char, accounting for prefixes.
     ((or (and (= n 2) ; leading quote (not prefix)
	       (not (match-end 1)))     ; prefix is null
	  (and (= n 1) ; prefix
	       (match-end 1)))          ; non-empty
      (unless (eq 'string (syntax-ppss-context (parse-partial-sexp (point-min) (point))))
	(eval-when-compile (string-to-syntax "|"))))
     ;; Otherwise (we're in a non-matching string) the property is
     ;; nil, which is OK.
     )))

(defconst mys-font-lock-syntactic-keywords
  ;; Make outer chars of matching triple-quote sequences into generic
  ;; string delimiters.  Fixme: Is there a better way?
  ;; First avoid a sequence preceded by an odd number of backslashes.
  `((,(concat "\\(?:^\\|[^\\]\\(?:\\\\.\\)*\\)" ;Prefix.
              "\\(?1:\"\\)\\(?2:\"\\)\\(?3:\"\\)\\(?4:\"\\)\\(?5:\"\\)\\(?6:\"\\)\\|\\(?1:\"\\)\\(?2:\"\\)\\(?3:\"\\)\\|\\(?1:'\\)\\(?2:'\\)\\(?3:'\\)\\(?4:'\\)\\(?5:'\\)\\(?6:'\\)\\|\\(?1:'\\)\\(?2:'\\)\\(?3:'\\)\\(?4:'\\)\\(?5:'\\)\\(?6:'\\)\\|\\(?1:'\\)\\(?2:'\\)\\(?3:'\\)")
     (1 (mys--quote-syntax 1) t t)
     (2 (mys--quote-syntax 2) t t)
     (3 (mys--quote-syntax 3) t t)
     (6 (mys--quote-syntax 1) t t))))

(defconst mys--windows-config-register 313465889
  "Internal used by `window-configuration-to-register'.")

(put 'mys-indent-offset 'safe-local-variable 'integerp)

;; testing
(defvar mys-ert-test-default-executables
  (list "python" "python3" "imys")
  "Serialize tests employing dolist.")

(defcustom mys-shell-unfontify-p t
  "Run `mys--run-unfontify-timer' unfontifying the shell banner-text.

Default is nil"

  :type 'boolean
  :tag "mys-shell-unfontify-p"
  :group 'mys-mode)

;; Pdb
;; #62, pdb-track in a shell buffer
(defcustom pdb-track-stack-from-shell-p t
  "If t, track source from shell-buffer.

Default is t.
Add hook \\='comint-output-filter-functions \\='mys--pdbtrack-track-stack-file"

  :type 'boolean
  :tag "pdb-track-stack-from-shell-p"
  :group 'mys-mode)

(defcustom mys-update-gud-pdb-history-p t
  "If pdb should provide suggestions WRT file to check and `mys-pdb-path'.

Default is t
See lp:963253"
  :type 'boolean
  :tag "mys-update-gud-pdb-history-p"
  :group 'mys-mode)

(defcustom mys-pdb-executable nil
  "Indicate PATH/TO/pdb.

Default is nil
See lp:963253"
  :type 'string
  :tag "mys-pdb-executable"
  :group 'mys-mode)

(defcustom mys-pdb-path
  (if (or (eq system-type 'ms-dos)(eq system-type 'windows-nt))
      (quote c:/python27/python\ -i\ c:/python27/Lib/pdb.py)
    '/usr/lib/python2.7/pdb.py)
  "Where to find pdb.py.  Edit this according to your system.
For example \"/usr/lib/python3.4\" might be an option too.

If you ignore the location `M-x mys-guess-pdb-path' might display it."
  :type 'variable
  :tag "mys-pdb-path"
  :group 'mys-mode)

(defvar mys-mys-ms-pdb-command ""
  "MS-systems might use that.")

(defcustom mys-shell-prompt-pdb-regexp "[(<]*[Ii]?[Pp]db[>)]+ "
  "Regular expression matching pdb input prompt of Python shell.
It should not contain a caret (^) at the beginning."
  :type 'string
  :tag "mys-shell-prompt-pdb-regexp"
  :group 'mys-mode)

(defcustom mys-pdbtrack-stacktrace-info-regexp
  "> \\([^\"(<]+\\)(\\([0-9]+\\))\\([?a-zA-Z0-9_<>]+\\)()"
  "Regular expression matching stacktrace information.
Used to extract the current line and module being inspected."
  :type 'string
  :safe 'stringp
  :tag "mys-pdbtrack-stacktrace-info-regexp"
  :group 'mys-mode)

(defvar mys-pdbtrack-tracked-buffer nil
  "Variable containing the value of the current tracked buffer.
Never set this variable directly, use
`mys-pdbtrack-set-tracked-buffer' instead.")

(defvar mys-pdbtrack-buffers-to-kill nil
  "List of buffers to be deleted after tracking finishes.")

(defcustom mys-pdbtrack-do-tracking-p t
  "Controls whether the pdbtrack feature is enabled or not.
When non-nil, pdbtrack is enabled in all comint-based buffers,
e.g. shell buffers and the *Python* buffer.  When using pdb to debug a
Python program, pdbtrack notices the pdb prompt and displays the
source file and line that the program is stopped at, much the same way
as `gud-mode' does for debugging C programs with gdb."
  :type 'boolean
  :tag "mys-pdbtrack-do-tracking-p"
  :group 'mys-mode)
(make-variable-buffer-local 'mys-pdbtrack-do-tracking-p)

(defcustom mys-pdbtrack-filename-mapping nil
  "Supports mapping file paths when opening file buffers in pdbtrack.
When non-nil this is an alist mapping paths in the Python interpreter
to paths in Emacs."
  :type 'alist
  :tag "mys-pdbtrack-filename-mapping"
  :group 'mys-mode)

(defcustom mys-pdbtrack-minor-mode-string " PDB"
  "String to use in the minor mode list when pdbtrack is enabled."
  :type 'string
  :tag "mys-pdbtrack-minor-mode-string"
  :group 'mys-mode)

(defconst mys-pdbtrack-stack-entry-regexp
   (concat ".*\\("mys-shell-input-prompt-1-regexp">\\|"mys-imys-input-prompt-re">\\|>\\) *\\(.*\\)(\\([0-9]+\\))\\([?a-zA-Z0-9_<>()]+\\)()")
  "Regular expression pdbtrack uses to find a stack trace entry.")

(defconst mys-pdbtrack-marker-regexp-file-group 2
  "Group position in gud-pydb-marker-regexp that matches the file name.")

(defconst mys-pdbtrack-marker-regexp-line-group 3
  "Group position in gud-pydb-marker-regexp that matches the line number.")

(defconst mys-pdbtrack-marker-regexp-funcname-group 4
  "Group position in gud-pydb-marker-regexp that matches the function name.")

(defconst mys-pdbtrack-track-range 10000
  "Max number of characters from end of buffer to search for stack entry.")

(defvar mys-pdbtrack-is-tracking-p nil)

(defvar mys--docbeg nil
  "Internally used by `mys--write-edit'.")

(defvar mys--docend nil
  "Internally used by `mys--write-edit'.")

(defcustom mys-completion-setup-code
  "
def __PYTHON_EL_get_completions(text):
    completions = []
    completer = None

    try:
        import readline

        try:
            import __builtin__
        except ImportError:
            # Python 3
            import builtins as __builtin__
        builtins = dir(__builtin__)

        is_imys = ('__IMYS__' in builtins or
                      '__IMYS__active' in builtins)
        splits = text.split()
        is_module = splits and splits[0] in ('from', 'import')

        if is_imys and is_module:
            from Imys.core.completerlib import module_completion
            completions = module_completion(text.strip())
        elif is_imys and '__IP' in builtins:
            completions = __IP.complete(text)
        elif is_imys and 'get_imys' in builtins:
            completions = get_imys().Completer.all_completions(text)
        else:
            # Try to reuse current completer.
            completer = readline.get_completer()
            if not completer:
                # importing rlcompleter sets the completer, use it as a
                # last resort to avoid breaking customizations.
                import rlcompleter
                completer = readline.get_completer()
            if getattr(completer, 'PYTHON_EL_WRAPPED', False):
                completer.print_mode = False
            i = 0
            while True:
                completion = completer(text, i)
                if not completion:
                    break
                i += 1
                completions.append(completion)
    except:
        pass
    finally:
        if getattr(completer, 'PYTHON_EL_WRAPPED', False):
            completer.print_mode = True
    return completions"
  "Code used to setup completion in inferior Python processes."
  :type 'string
  :tag "mys-completion-setup-code"
  :group 'mys-mode)

(defcustom mys-shell-completion-string-code
  "';'.join(__PYTHON_EL_get_completions('''%s'''))"
  "Python code used to get a string of completions separated by semicolons.
The string passed to the function is the current python name or
the full statement in the case of imports."
  :type 'string
  :tag "mys-shell-completion-string-code"
  :group 'mys-mode)

(defface mys-XXX-tag-face
  '((t (:inherit font-lock-string-face)))
  "XXX\\|TODO\\|FIXME "
  :tag "mys-XXX-tag-face"
  :group 'mys-mode)

(defface mys-pseudo-keyword-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for pseudo keywords in Python mode, like self, True, False,
  Ellipsis.

See also `mys-object-reference-face'"
  :tag "mys-pseudo-keyword-face"
  :group 'mys-mode)

(defface mys-object-reference-face
  '((t (:inherit mys-pseudo-keyword-face)))
  "Face when referencing object members from its class resp. method.,
commonly \"cls\" and \"self\""
  :tag "mys-object-reference-face"
  :group 'mys-mode)

(defface mys-number-face
 '((t (:inherit nil)))
  "Highlight numbers."
  :tag "mys-number-face"
  :group 'mys-mode)

(defface mys-try-if-face
  '((t (:inherit font-lock-keyword-face)))
  "Highlight keywords."
  :tag "mys-try-if-face"
  :group 'mys-mode)

(defface mys-import-from-face
  '((t (:inherit font-lock-keyword-face)))
  "Highlight keywords."
  :tag "mys-import-from-face"
  :group 'mys-mode)

(defface mys-def-class-face
  '((t (:inherit font-lock-keyword-face)))
  "Highlight keywords."
  :tag "mys-def-class-face"
  :group 'mys-mode)

 ;; PEP 318 decorators
(defface mys-decorators-face
  '((t (:inherit font-lock-keyword-face)))
  "Face method decorators."
  :tag "mys-decorators-face"
  :group 'mys-mode)

(defface mys-builtins-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for builtins like TypeError, object, open, and exec."
  :tag "mys-builtins-face"
  :group 'mys-mode)

(defface mys-class-name-face
  '((t (:inherit font-lock-type-face)))
  "Face for classes."
  :tag "mys-class-name-face"
  :group 'mys-mode)

(defface mys-def-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for classes."
  :tag "mys-class-name-face"
  :group 'mys-mode)

(defface mys-exception-name-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for Python exceptions."
  :tag "mys-exception-name-face"
  :group 'mys-mode)

;; subr-x.el might not exist yet
;; #73, Byte compilation on Emacs 25.3 fails on different trim-right signature

(defsubst mys--string-trim-left (strg &optional regexp)
  "Trim STRING of leading string matching REGEXP.

REGEXP defaults to \"[ \\t\\n\\r]+\"."
  (if (string-match (concat "\\`\\(?:" (or regexp "[ \t\n\r]+") "\\)") strg)
      (replace-match "" t t strg)
    strg))

(defsubst mys--string-trim-right (strg &optional regexp)
  "Trim STRING of trailing string matching REGEXP.

REGEXP defaults to \"[ \\t\\n\\r]+\"."
  (if (string-match (concat "\\(?:" (or regexp "[ \t\n\r]+") "\\)\\'") strg)
      (replace-match "" t t strg)
    strg))

(defsubst mys--string-trim (strg &optional trim-left trim-right)
  "Trim STRING of leading and trailing strings matching TRIM-LEFT and TRIM-RIGHT.

TRIM-LEFT and TRIM-RIGHT default to \"[ \\t\\n\\r]+\"."
  (mys--string-trim-left (mys--string-trim-right strg trim-right) trim-left))

(defsubst string-blank-p (strg)
  "Check whether STRING is either empty or only whitespace."
  (string-match-p "\\`[ \t\n\r]*\\'" strg))

(defsubst string-remove-prefix (prefix strg)
  "Remove PREFIX from STRING if present."
  (if (string-prefix-p prefix strg)
      (substring strg (length prefix))
    strg))

(defun mys-toggle-imenu-create-index ()
  "Toggle value of `mys--imenu-create-index-p'."
  (interactive)
  (setq mys--imenu-create-index-p (not mys--imenu-create-index-p))
  (when (called-interactively-p 'interactive)
    (message "mys--imenu-create-index-p: %s" mys--imenu-create-index-p)))

(defun mys-toggle-shell-completion ()
  "Switch value of buffer-local var `mys-shell-complete-p'."
  (interactive)
    (setq mys-shell-complete-p (not mys-shell-complete-p))
    (when (called-interactively-p 'interactive)
      (message "mys-shell-complete-p: %s" mys-shell-complete-p)))

(defun mys--at-raw-string ()
  "If at beginning of a raw-string."
  (and (looking-at "\"\"\"\\|'''") (member (char-before) (list ?u ?U ?r ?R))))

(defmacro mys-current-line-backslashed-p ()
  "Return t if current line is a backslashed continuation line."
  `(save-excursion
     (end-of-line)
     (skip-chars-backward " \t\r\n\f")
     (and (eq (char-before (point)) ?\\ )
          (mys-escaped-p))))

(defmacro mys-preceding-line-backslashed-p ()
  "Return t if preceding line is a backslashed continuation line."
  `(save-excursion
     (beginning-of-line)
     (skip-chars-backward " \t\r\n\f")
     (and (eq (char-before (point)) ?\\ )
          (mys-escaped-p))))

(defun mys--skip-to-comment-or-semicolon (done)
  "Returns position if comment or semicolon found. "
  (let ((orig (point)))
    (cond ((and done (< 0 (abs (skip-chars-forward "^#;" (line-end-position))))
                (member (char-after) (list ?# ?\;)))
           (when (eq ?\; (char-after))
             (skip-chars-forward ";" (line-end-position))))
          ((and (< 0 (abs (skip-chars-forward "^#;" (line-end-position))))
                (member (char-after) (list ?# ?\;)))
           (when (eq ?\; (char-after))
             (skip-chars-forward ";" (line-end-position))))
          ((not done)
           (end-of-line)))
    (skip-chars-backward " \t" (line-beginning-position))
    (and (< orig (point))(setq done (point))
         done)))

;;  Statement
(defun mys-forward-statement (&optional orig done repeat)
  "Go to the last char of current statement.

ORIG - consider orignial position or point.
DONE - transaktional argument
REPEAT - count and consider repeats"
  (interactive)
  (unless (eobp)
    (let ((repeat (or (and repeat (1+ repeat)) 0))
	  (orig (or orig (point)))
	  erg last
	  ;; use by scan-lists
	  forward-sexp-function pps err)
      (setq pps (parse-partial-sexp (point-min) (point)))
      ;; (origline (or origline (mys-count-lines)))
      (cond
       ;; which-function-mode, lp:1235375
       ((< mys-max-specpdl-size repeat)
	(error "mys-forward-statement reached loops max. If no error, customize `mys-max-specpdl-size'"))
       ;; list
       ((nth 1 pps)
	(if (<= orig (point))
	    (progn
	      (setq orig (point))
	      ;; do not go back at a possible unclosed list
	      (goto-char (nth 1 pps))
	      (if
		  (ignore-errors (forward-list))
		  (progn
		    (when (looking-at ":[ \t]*$")
		      (forward-char 1))
		    (setq done t)
		    (skip-chars-forward "^#" (line-end-position))
		    (skip-chars-backward " \t\r\n\f" (line-beginning-position))
		    (mys-forward-statement orig done repeat))
		(setq err (mys--record-list-error pps))
		(goto-char orig)))))
       ;; in comment
       ((and comment-start (looking-at (concat " *" comment-start)))
	(goto-char (match-end 0))
	(mys-forward-statement orig done repeat))
       ((nth 4 pps)
	(mys--end-of-comment-intern (point))
	(mys--skip-to-comment-or-semicolon done)
	(while (and (eq (char-before (point)) ?\\)
		    (mys-escaped-p) (setq last (point)))
	  (forward-line 1) (end-of-line))
	(and last (goto-char last)
	     (forward-line 1)
	     (back-to-indentation))
	;; mys-forward-statement-test-3JzvVW
	(unless (or (looking-at (concat " *" comment-start))(eolp))
	  (mys-forward-statement orig done repeat)))
       ;; string
       ((looking-at mys-string-delim-re)
	(goto-char (match-end 0))
	(mys-forward-statement orig done repeat))
       ((nth 3 pps)
	(when (mys-end-of-string)
	  (end-of-line)
	  (skip-chars-forward " \t\r\n\f")
	  (setq pps (parse-partial-sexp (point-min) (point)))
	  (unless (and done (not (or (nth 1 pps) (nth 8 pps))) (eolp)) (mys-forward-statement orig done repeat))))
       ((mys-current-line-backslashed-p)
	(end-of-line)
	(skip-chars-backward " \t\r\n\f" (line-beginning-position))
	(while (and (eq (char-before (point)) ?\\)
		    (mys-escaped-p))
	  (forward-line 1)
	  (end-of-line)
	  (skip-chars-backward " \t\r\n\f" (line-beginning-position)))
	(unless (eobp)
	  (mys-forward-statement orig done repeat)))
       ((eq orig (point))
	(if (eolp)
	    (skip-chars-forward " \t\r\n\f#'\"")
	  (end-of-line)
	  (skip-chars-backward " \t\r\n\f" orig))
	;; point at orig due to a trailing whitespace
	(and (eq (point) orig) (skip-chars-forward " \t\r\n\f"))
	(setq done t)
	(mys-forward-statement orig done repeat))
       ((eq (current-indentation) (current-column))
	(mys--skip-to-comment-or-semicolon done)
	(setq pps (parse-partial-sexp orig (point)))
	(if (nth 1 pps)
	    (mys-forward-statement orig done repeat)
	  (unless done
	    (mys-forward-statement orig done repeat))))
       ((and (looking-at "[[:print:]]+$") (not done) (mys--skip-to-comment-or-semicolon done))
	(mys-forward-statement orig done repeat)))
      (unless
	  (or
	   (eq (point) orig)
	   (member (char-before) (list 10 32 9 ?#)))
	(setq erg (point)))
      (if (and mys-verbose-p err)
	  (mys--message-error err))
      erg)))

(defun mys-backward-statement (&optional orig done limit ignore-in-string-p repeat maxindent)
  "Go to the initial line of a simple statement.

For beginning of compound statement use `mys-backward-block'.
For beginning of clause `mys-backward-clause'.

`ignore-in-string-p' allows moves inside a docstring, used when
computing indents
ORIG - consider orignial position or point.
DONE - transaktional argument
LIMIT - honor limit
IGNORE-IN-STRING-P - also much inside a string
REPEAT - count and consider repeats
Optional MAXINDENT: don't stop if indentation is larger"
  (interactive)
  (save-restriction
    (unless (bobp)
      (let* ((repeat (or (and repeat (1+ repeat)) 0))
	     (orig (or orig (point)))
             (pps (parse-partial-sexp (or limit (point-min))(point)))
             (done done)
             erg)
	;; lp:1382788
	(unless done
	  (and (< 0 (abs (skip-chars-backward " \t\r\n\f")))
 	       (setq pps (parse-partial-sexp (or limit (point-min))(point)))))
        (cond
	 ((< mys-max-specpdl-size repeat)
	  (error "Mys-forward-statement reached loops max. If no error, customize `mys-max-specpdl-size'"))
         ((and (bolp) (eolp))
          (skip-chars-backward " \t\r\n\f")
          (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; inside string
         ((and (nth 3 pps) (not ignore-in-string-p))
	  (setq done t)
	  (goto-char (nth 8 pps))
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ((nth 4 pps)
	  (while (ignore-errors (goto-char (nth 8 pps)))
	    (skip-chars-backward " \t\r\n\f")
	    (setq pps (parse-partial-sexp (line-beginning-position) (point))))
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
         ((nth 1 pps)
          (goto-char (1- (nth 1 pps)))
	  (when (mys--skip-to-semicolon-backward (save-excursion (back-to-indentation) (point)))
	    (setq done t))
          (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
         ((mys-preceding-line-backslashed-p)
          (forward-line -1)
          (back-to-indentation)
          (setq done t)
          (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; at raw-string
	 ;; (and (looking-at "\"\"\"\\|'''") (member (char-before) (list ?u ?U ?r ?R)))
	 ((and (looking-at "\"\"\"\\|'''") (member (char-before) (list ?u ?U ?r ?R)))
	  (forward-char -1)
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; BOL or at space before comment
         ((and (looking-at "[ \t]*#") (looking-back "^[ \t]*" (line-beginning-position)))
          (forward-comment -1)
          (while (and (not (bobp)) (looking-at "[ \t]*#") (looking-back "^[ \t]*" (line-beginning-position)))
            (forward-comment -1))
          (unless (bobp)
            (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent)))
	 ;; at inline comment
         ((looking-at "[ \t]*#")
	  (when (mys--skip-to-semicolon-backward (save-excursion (back-to-indentation) (point)))
	    (setq done t))
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; at beginning of string
	 ((looking-at mys-string-delim-re)
	  (when (< 0 (abs (skip-chars-backward " \t\r\n\f")))
	    (setq done t))
	  (back-to-indentation)
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; after end of statement
	 ((and (not done) (eq (char-before) ?\;))
	  (skip-chars-backward ";")
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; travel until indentation or semicolon
	 ((and (not done) (mys--skip-to-semicolon-backward))
	  (unless (and maxindent (< maxindent (current-indentation)))
	    (setq done t))
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ;; at current indent
	 ((and (not done) (not (eq 0 (skip-chars-backward " \t\r\n\f"))))
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent))
	 ((and maxindent (< maxindent (current-indentation)))
	  (forward-line -1)
	  (mys-backward-statement orig done limit ignore-in-string-p repeat maxindent)))
	;; return nil when before comment
	(unless (and (looking-at "[ \t]*#") (looking-back "^[ \t]*" (line-beginning-position)))
	  (when (< (point) orig)(setq erg (point))))
	erg))))

(defun mys-backward-statement-bol ()
  "Goto beginning of line where statement start.
Returns position reached, if successful, nil otherwise.

See also `mys-up-statement'"
  (interactive)
  (let* ((orig (point))
         erg)
    (unless (bobp)
      (cond ((bolp)
	     (and (mys-backward-statement orig)
		  (progn (beginning-of-line)
			 (setq erg (point)))))
	    (t (setq erg
		     (and
		      (mys-backward-statement)
		      (progn (beginning-of-line) (point)))))))
    erg))

(defun mys-forward-statement-bol ()
  "Go to the `beginning-of-line' following current statement."
  (interactive)
  (mys-forward-statement)
  (mys--beginning-of-line-form))

(defun mys-beginning-of-statement-p ()
  (interactive)
  (save-restriction
    (eq (point)
    (save-excursion
      (mys-forward-statement)
      (mys-backward-statement)))))

(defun mys-up-statement ()
  "go to the beginning of next statement upwards in buffer.

Return position if statement found, nil otherwise."
  (interactive)
  (if (mys--beginning-of-statement-p)
      (mys-backward-statement)
    (progn (and (mys-backward-statement) (mys-backward-statement)))))

(defun mys--end-of-statement-p ()
  "Return position, if cursor is at the end of a statement, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-statement)
      (mys-forward-statement)
      (when (eq orig (point))
        orig))))

(defun mys-down-statement ()
  "Go to the beginning of next statement downwards in buffer.

Corresponds to backward-up-list in Elisp
Return position if statement found, nil otherwise."
  (interactive)
  (let* ((orig (point)))
    (cond ((mys--end-of-statement-p)
	   (progn
	     (and
	      (mys-forward-statement)
	      (mys-backward-statement)
	      (< orig (point))
	      (point))))
	  ((ignore-errors (< orig (and (mys-forward-statement) (mys-backward-statement))))
	   (point))
	  ((ignore-errors (< orig (and (mys-forward-statement) (mys-forward-statement)(mys-backward-statement))))
	     (point)))))

(defun mys--backward-regexp (regexp &optional indent condition orig regexpvalue)
  "Search backward next regexp not in string or comment.

Return and move to match-beginning if successful"
  (save-match-data
    (unless (mys-beginning-of-statement-p) (skip-chars-backward " \t\r\n\f")
	    (mys-backward-comment (point)))
    (let* (pps
	   (regexpvalue (or regexpvalue (symbol-value regexp)))
	   (indent (or indent (current-indentation)))
	   (condition (or condition '<=))
	   (orig (or orig (point))))
      (if (eq (current-indentation) (current-column))
	  (while (and
		  (not (bobp))
		  ;; # class kugel(object) -> a[1:2]:
		  ;; class kugel(object):
		  ;; (re-search-backward regexpvalue nil 'move 1)
		  ;; (re-search-backward (concat "^ \\{0,"(format "%s" indent) "\\}"regexpvalue) nil 'move 1)
		  (re-search-backward regexpvalue nil 'move 1)
		  ;; (re-search-backward (concat "^" "def") nil 'move 1)
		  ;; re-search-backward not greedy
		  (not (and (looking-back "async *" (line-beginning-position))
			    (goto-char (match-beginning 0))))
		  (or (and
                       (setq pps (nth 8 (parse-partial-sexp (point-min) (point))))
                       (goto-char pps))
		      ;; needed by mys-backward-clause
                      (and (not (eq (current-column) 0)) indent
		      	   (funcall condition indent (current-indentation))))))
	(back-to-indentation)
	(and
         (setq pps (nth 8 (parse-partial-sexp (point-min) (point))))
         (goto-char pps))
	(unless (and (< (point) orig) (looking-at regexpvalue))
	  (mys--backward-regexp regexp (current-indentation) condition orig)))
      (unless (or (eq (point) orig)(bobp)) (back-to-indentation))
      (and (looking-at regexpvalue) (not (nth 8 (parse-partial-sexp (point-min) (point))))(point)))))

(defun mys--fetch-indent-statement-above (orig)
  "Report the preceding indent. "
  (save-excursion
    (goto-char orig)
    (forward-line -1)
    (end-of-line)
    (skip-chars-backward " \t\r\n\f")
    (back-to-indentation)
    (if (or (looking-at comment-start)(mys-beginning-of-statement-p))
        (current-indentation)
      (mys-backward-statement)
      (current-indentation))))

(defun mys--docstring-p (pos)
  "Check to see if there is a docstring at POS."
  (save-excursion
    (let ((erg
	   (progn
	     (goto-char pos)
	     (and (looking-at "\"\"\"\\|'''")
		  ;; https://github.com/swig/swig/issues/889
		  ;; def foo(rho, x):
		  ;;     r"""Calculate :math:`D^\nu \rho(x)`."""
		  ;;     return True
		  (if (mys--at-raw-string)
		      (progn
			(forward-char -1)
			(point))
		    (point))))))
      (when (and erg (mys-backward-statement))
	(when (or (bobp) (looking-at mys-def-or-class-re)(looking-at "\\_<__[[:alnum:]_]+__\\_>"))
	  erg)))))

(defun mys--font-lock-syntactic-face-function (state)
  "STATE expected as result von (parse-partial-sexp (point-min) (point)."
  (if (nth 3 state)
      (if (mys--docstring-p (nth 8 state))
          font-lock-doc-face
        font-lock-string-face)
    font-lock-comment-face))

(and (fboundp 'make-obsolete-variable)
     (make-obsolete-variable 'mys-mode-hook 'mys-mode-hook nil))

(defun mys-choose-shell-by-shebang (&optional shebang)
  "Choose shell by looking at #! on the first line.

If SHEBANG is non-nil, returns the shebang as string,
otherwise the Python resp. Jython shell command name."
  (interactive)
  ;; look for an interpreter specified in the first line
  (let* (erg res)
    (save-excursion
      (goto-char (point-min))
      (when (looking-at mys-shebang-regexp)
        (if shebang
            (setq erg (match-string-no-properties 0))
          (setq erg (split-string (match-string-no-properties 0) "[#! \t]"))
          (dolist (ele erg)
            (when (string-match "[bijp]+ython" ele)
              (setq res ele))))))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" res))
    res))

(defun mys--choose-shell-by-import ()
  "Choose CPython or Jython mode based imports.

If a file imports any packages in `mys-jython-packages', within
`mys-import-check-point-max' characters from the start of the file,
return `jython', otherwise return nil."
  (let (mode)
    (save-excursion
      (goto-char (point-min))
      (while (and (not mode)
                  (search-forward-regexp
                   "^\\(\\(from\\)\\|\\(import\\)\\) \\([^ \t\n.]+\\)"
                   mys-import-check-point-max t))
        (setq mode (and (member (match-string 4) mys-jython-packages)
                        'jython))))
    mode))

(defun mys-choose-shell-by-path (&optional separator-char)
  "SEPARATOR-CHAR according to system variable `path-separator'.

Select Python executable according to version desplayed in path.
Returns versioned string, nil if nothing appropriate found"
  (interactive)
  (let ((path (mys--buffer-filename-remote-maybe))
	(separator-char (or separator-char mys-separator-char))
                erg)
    (when (and path separator-char
               (string-match (concat separator-char "[iI]?[pP]ython[0-9.]+" separator-char) path))
      (setq erg (substring path
                           (1+ (string-match (concat separator-char "[iI]?[pP]ython[0-9.]+" separator-char) path)) (1- (match-end 0)))))
    (when (called-interactively-p 'any) (message "%s" erg))
    erg))

(defun mys-which-python (&optional shell)
  "Return version of Python of current environment, a number.
Optional argument SHELL selected shell."
  (interactive)
  (let* ((cmd (or shell (mys-choose-shell)))
	 (treffer (string-match "\\([23]*\\.?[0-9\\.]*\\)$" cmd))
         version erg)
    (if treffer
        ;; if a number if part of python name, assume it's the version
        (setq version (substring-no-properties cmd treffer))
      (setq erg (shell-command-to-string (concat cmd " --version")))
      (setq version (cond ((string-match (concat "\\(on top of Python \\)" "\\([0-9]\\.[0-9]+\\)") erg)
                           (match-string-no-properties 2 erg))
                          ((string-match "\\([0-9]\\.[0-9]+\\)" erg)
                           (substring erg 7 (1- (length erg)))))))
    (when (called-interactively-p 'any)
      (if version
          (when mys-verbose-p (message "%s" version))
        (message "%s" "Could not detect Python on your system")))
    (string-to-number version)))

(defun mys-mys-current-environment ()
  "Return path of current Python installation."
  (interactive)
  (let* ((cmd (mys-choose-shell))
         (denv (shell-command-to-string (concat "type " cmd)))
         (erg (substring denv (string-match "/" denv))))
    (when (called-interactively-p 'any)
      (if erg
          (message "%s" erg)
        (message "%s" "Could not detect Python on your system")))
    erg))

 ;; requested by org-mode still
(defalias 'mys-toggle-shells 'mys-choose-shell)

(defun mys--cleanup-process-name (res)
  "Make res ready for use by `executable-find'.

Returns RES or substring of RES"
  (if (string-match "<" res)
      (substring res 0 (match-beginning 0))
    res))

(defalias 'mys-which-shell 'mys-choose-shell)
(defun mys-choose-shell (&optional shell)
  "Return an appropriate executable as a string.

Does the following:
 - look for an interpreter with `mys-choose-shell-by-shebang'
 - examine imports using `mys--choose-shell-by-import'
 - look if Path/To/File indicates a Python version
 - if not successful, return default value of `mys-shell-name'

When interactivly called, messages the SHELL name
Return nil, if no executable found."
  (interactive)
  ;; org-babel uses `mys-toggle-shells' with arg, just return it
  (or shell
      (let* (res
	     done
	     (erg
	      (cond (mys-force-mys-shell-name-p
		     (default-value 'mys-shell-name))
		    (mys-use-local-default
		     (if (not (string= "" mys-shell-local-path))
			 (expand-file-name mys-shell-local-path)
		       (message "Abort: `mys-use-local-default' is set to `t' but `mys-shell-local-path' is empty. Maybe call `mys-toggle-local-default-use'")))
		    ((and (not mys-fast-process-p)
			  (comint-check-proc (current-buffer))
			  (setq done t)
			  (string-match "ython" (process-name (get-buffer-process (current-buffer)))))
		     (setq res (process-name (get-buffer-process (current-buffer))))
		     (mys--cleanup-process-name res))
		    ((mys-choose-shell-by-shebang))
		    ((mys--choose-shell-by-import))
		    ((mys-choose-shell-by-path))
		    (t (or
			mys-mys-command
			"python3"))))
	     (cmd (if (or
		       ;; comint-check-proc was succesful
		       done
		       mys-edit-only-p)
		      erg
		    (executable-find erg))))
	(if cmd
	    (when (called-interactively-p 'any)
	      (message "%s" cmd))
	  (when (called-interactively-p 'any) (message "%s" "Could not detect Python on your system. Maybe set `mys-edit-only-p'?")))
	erg)))

(defun mys--normalize-directory (directory)
  "Make sure DIRECTORY ends with a file-path separator char.

Returns DIRECTORY"
  (cond ((string-match (concat mys-separator-char "$") directory)
         directory)
        ((not (string= "" directory))
         (concat directory mys-separator-char))))

(defun mys--normalize-pythonpath (pythonpath)
  "Make sure PYTHONPATH ends with a colon.

Returns PYTHONPATH"
  (let ((erg (cond ((string-match (concat path-separator "$") pythonpath)
                    pythonpath)
                   ((not (string= "" pythonpath))
                    (concat pythonpath path-separator))
		   (t pythonpath))))
    erg))

(defun mys-install-directory-check ()
  "Do some sanity check for `mys-install-directory'.

Returns t if successful."
  (interactive)
  (let ((erg (and (boundp 'mys-install-directory) (stringp mys-install-directory) (< 1 (length mys-install-directory)))))
    (when (called-interactively-p 'any) (message "mys-install-directory-check: %s" erg))
    erg))

(defun mys--buffer-filename-remote-maybe (&optional file-name)
  "Argument FILE-NAME: the value of variable `buffer-file-name'."
  (let ((file-name (or file-name
                       (and
                        (ignore-errors (file-readable-p (buffer-file-name)))
                        (buffer-file-name)))))
    (if (and (featurep 'tramp) (tramp-tramp-file-p file-name))
        (tramp-file-name-localname
         (tramp-dissect-file-name file-name))
      file-name)))

(defun mys-guess-mys-install-directory ()
  "If `(locate-library \"mys-mode\")' is not succesful.

Used only, if `mys-install-directory' is empty."
  (interactive)
  (cond (;; don't reset if it already exists
	 mys-install-directory)
        ;; ((locate-library "mys-mode")
	;;  (file-name-directory (locate-library "mys-mode")))
	((ignore-errors (string-match "mys-mode" (mys--buffer-filename-remote-maybe)))
	 (file-name-directory (mys--buffer-filename-remote-maybe)))
        (t (if
	       (and (get-buffer "mys-mode.el")
		    (set-buffer (get-buffer "mys-mode.el"))
		    ;; (setq mys-install-directory (ignore-errors (file-name-directory (buffer-file-name (get-buffer  "mys-mode.el")))))
		    (buffer-file-name (get-buffer  "mys-mode.el")))
	       (setq mys-install-directory (file-name-directory (buffer-file-name (get-buffer  "mys-mode.el"))))
	     (if
		 (and (get-buffer "mys-components-mode.el")
		      (set-buffer (get-buffer "mys-components-mode.el"))
		      (buffer-file-name (get-buffer  "mys-components-mode.el")))
		 (setq mys-install-directory (file-name-directory (buffer-file-name (get-buffer  "mys-components-mode.el"))))))
	   )))

(defun mys--fetch-pythonpath ()
  "Consider settings of `mys-pythonpath'."
  (if (string= "" mys-pythonpath)
      (getenv "PYTHONPATH")
    (concat (mys--normalize-pythonpath (getenv "PYTHONPATH")) mys-pythonpath)))

(defun mys-load-pymacs ()
  "Load Pymacs as delivered.

Pymacs has been written by François Pinard and many others.
See original source: http://pymacs.progiciels-bpi.ca"
  (interactive)
  (let ((pyshell (mys-choose-shell))
        (path (mys--fetch-pythonpath))
        (mys-install-directory (cond ((string= "" mys-install-directory)
                                     (mys-guess-mys-install-directory))
                                    (t (mys--normalize-directory mys-install-directory)))))
    (if (mys-install-directory-check)
        (progn
          ;; If Pymacs has not been loaded before, prepend mys-install-directory to
          ;; PYTHONPATH, so that the Pymacs delivered with mys-mode is used.
          (unless (featurep 'pymacs)
            (setenv "PYTHONPATH" (concat
                                  (expand-file-name mys-install-directory)
                                  (if path (concat path-separator path)))))
          (setenv "PYMACS_PYTHON" (if (string-match "IP" pyshell)
                                      "python"
                                    pyshell))
          (require 'pymacs))
      (error "`mys-install-directory' not set, see INSTALL"))))

(when mys-load-pymacs-p (mys-load-pymacs))

(when (and mys-load-pymacs-p (featurep 'pymacs))
  (defun mys-load-pycomplete ()
    "Load Pymacs based pycomplete."
    (interactive)
    (let* ((path (mys--fetch-pythonpath))
           (mys-install-directory (cond ((string= "" mys-install-directory)
                                        (mys-guess-mys-install-directory))
                                       (t (mys--normalize-directory mys-install-directory))))
           (pycomplete-directory (concat (expand-file-name mys-install-directory) "completion")))
      (if (mys-install-directory-check)
          (progn
            ;; If the Pymacs process is already running, augment its path.
            (when (and (get-process "pymacs") (fboundp 'pymacs-exec))
              (pymacs-exec (concat "sys.path.insert(0, '" pycomplete-directory "')")))
            (require 'pymacs)
            (setenv "PYTHONPATH" (concat
                                  pycomplete-directory
                                  (if path (concat path-separator path))))
            (push pycomplete-directory load-path)
            (require 'pycomplete)
            (add-hook 'mys-mode-hook 'mys-complete-initialize))
        (error "`mys-install-directory' not set, see INSTALL")))))

(when (functionp 'mys-load-pycomplete)
  (mys-load-pycomplete))

(defun mys-set-load-path ()
  "Include needed subdirs of `mys-mode' directory."
  (interactive)
  (let ((install-directory (mys--normalize-directory mys-install-directory)))
    (if mys-install-directory
	(cond ((and (not (string= "" install-directory))(stringp install-directory))
               (push (expand-file-name install-directory) load-path)
               (push (concat (expand-file-name install-directory) "completion")  load-path)
               (push (concat (expand-file-name install-directory) "extensions")  load-path)
               (push (concat (expand-file-name install-directory) "test") load-path)
               )
              (t (error "Please set `mys-install-directory', see INSTALL")))
      (error "Please set `mys-install-directory', see INSTALL")))
  (when (called-interactively-p 'interactive) (message "%s" load-path)))

(defun mys-count-lines (&optional beg end)
  "Count lines in accessible part until current line.

See http://debbugs.gnu.org/cgi/bugreport.cgi?bug=7115
Optional argument BEG specify beginning.
Optional argument END specify end."
  (interactive)
  (save-excursion
    (let ((count 0)
	  (beg (or beg (point-min)))
	  (end (or end (point))))
      (save-match-data
	(if (or (eq major-mode 'comint-mode)
		(eq major-mode 'mys-shell-mode))
	    (if
		(re-search-backward mys-shell-prompt-regexp nil t 1)
		(goto-char (match-end 0))
	      ;; (when mys-debug-p (message "%s"  "mys-count-lines: Don't see a prompt here"))
	      (goto-char beg))
	  (goto-char beg)))
      (while (and (< (point) end)(not (eobp)) (skip-chars-forward "^\n" end))
        (setq count (1+ count))
        (unless (or (not (< (point) end)) (eobp)) (forward-char 1)
                (setq count (+ count (abs (skip-chars-forward "\n" end))))))
      (when (bolp) (setq count (1+ count)))
      (when (and mys-debug-p (called-interactively-p 'any)) (message "%s" count))
      count)))

(defun mys--escape-doublequotes (start end)
  "Escape doublequotes in region by START END."
  (let ((end (comys-marker end)))
    (save-excursion
      (goto-char start)
      (while (and (not (eobp)) (< 0 (abs (skip-chars-forward "^\"" end))))
	(when (eq (char-after) ?\")
	  (unless (mys-escaped-p)
	    (insert "\\")
	    (forward-char 1)))))))

(defun mys--escape-open-paren-col1 (start end)
  "Start from position START until position END."
  (goto-char start)
  (while (re-search-forward "^(" end t 1)
    (insert "\\")
    (end-of-line)))

(and mys-company-pycomplete-p (require 'company-pycomplete))

(defcustom mys-empty-line-p-chars "^[ \t\r]*$"
  "Empty-line-p-chars."
  :type 'regexp
  :tag "mys-empty-line-p-chars"
  :group 'mys-mode)

(defcustom mys-default-working-directory ""
  "If not empty used by `mys-set-current-working-directory'."
  :type 'string
  :tag "mys-default-working-directory"
  :group 'mys-mode)

(defun mys-empty-line-p ()
  "Return t if cursor is at an empty line, nil otherwise."
  (save-excursion
    (beginning-of-line)
    (looking-at mys-empty-line-p-chars)))

(defun mys-toggle-closing-list-dedents-bos (&optional arg)
  "Switch boolean variable `mys-closing-list-dedents-bos'.

With optional ARG message state switched to"
  (interactive "p")
  (setq mys-closing-list-dedents-bos (not mys-closing-list-dedents-bos))
  (when arg (message "mys-closing-list-dedents-bos: %s" mys-closing-list-dedents-bos)))

(defun mys-comint-delete-output ()
  "Delete all output from interpreter since last input.
Does not delete the prompt."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer)))
	(replacement nil)
	(inhibit-read-only t))
    (save-excursion
      (let ((pmark (progn (goto-char (process-mark proc))
			  (forward-line 0)
			  (point-marker))))
	(delete-region comint-last-input-end pmark)
	(goto-char (process-mark proc))
	(setq replacement (concat "*** output flushed ***\n"
				  (buffer-substring pmark (point))))
	(delete-region pmark (point))))
    ;; Output message and put back prompt
    (comint-output-filter proc replacement)))

(defun mys-in-comment-p ()
  "Return the beginning of current line's comment, if inside. "
  (interactive)
  (let* ((pps (parse-partial-sexp (point-min) (point)))
         (erg (and (nth 4 pps) (nth 8 pps))))
    erg))
;;
(defun mys-in-string-or-comment-p ()
  "Returns beginning position if inside a string or comment, nil otherwise. "
  (or (nth 8 (parse-partial-sexp (point-min) (point)))
      (when (or (looking-at "\"")(looking-at "[ \t]*#[ \t]*"))
        (point))))

(defvar mys-mode-map nil)
(when mys-org-cycle-p
  (define-key mys-mode-map (kbd "<backtab>") 'org-cycle))

(defun mys-forward-buffer ()
  "A complementary form used by auto-generated commands.

Returns position reached if successful"
  (interactive)
  (unless (eobp)
    (goto-char (point-max))))

(defun mys-backward-buffer ()
  "A complementary form used by auto-generated commands.

Returns position reached if successful"
  (interactive)
  (unless (bobp)
    (goto-char (point-min))))

(defun mys--end-of-comment-intern (pos)
  (while (and (not (eobp))
              (forward-comment 99999)))
  ;; forward-comment fails sometimes
  (and (eq pos (point)) (prog1 (forward-line 1) (back-to-indentation))
       (while (member (char-after) (list  (string-to-char comment-start) 10))(forward-line 1)(back-to-indentation))))

(defun mys--beginning-of-line-form ()
  "Internal use: Go to beginning of line following end of form.

Return position."
  (if (eobp)
      (point)
    (forward-line 1)
    (beginning-of-line)
    (point)))

(defun mys--skip-to-semicolon-backward (&optional limit)
  "Fetch the beginning of statement after a semicolon.

Returns `t' if point was moved"
  (prog1
      (< 0 (abs (skip-chars-backward "^;" (or limit (line-beginning-position)))))
    (skip-chars-forward " \t" (line-end-position))))

(defun mys-forward-comment ()
  "Go to the end of comment at point."
  (let ((orig (point))
        last)
    (while (and (not (eobp)) (nth 4 (parse-partial-sexp (line-beginning-position) (point))) (setq last (line-end-position)))
      (forward-line 1)
      (end-of-line))
    (when
        (< orig last)
      (goto-char last)(point))))

(defun mys--forward-string-maybe (&optional start)
  "Go to the end of string.

Expects START position of string
Return position of moved, nil otherwise."
  (let ((orig (point)))
    (when start (goto-char start)
	  (when (looking-at "\"\"\"\\|'''")
	    (goto-char (1- (match-end 0)))
	    (forward-sexp))
	  ;; maybe at the inner fence
	  (when (looking-at "\"\"\\|''")
	    (goto-char (match-end 0)))
	  (and (< orig (point)) (point)))))

(defun mys-load-skeletons ()
  "Load skeletons from extensions. "
  (interactive)
  (load (concat mys-install-directory "/extensions/mys-components-skeletons.el")))

(defun mys--kill-emacs-hook ()
  "Delete files in `mys-file-queue'.
These are Python temporary files awaiting execution."
  (mapc #'(lambda (filename)
            (ignore-errors (delete-file filename)))
        mys-file-queue))

(add-hook 'kill-emacs-hook 'mys--kill-emacs-hook)

;;  Add a designator to the minor mode strings
(or (assq 'mys-pdbtrack-is-tracking-p minor-mode-alist)
    (push '(mys-pdbtrack-is-tracking-p mys-pdbtrack-minor-mode-string)
          minor-mode-alist))

(defun mys--update-lighter (shell)
  "Select lighter for mode-line display"
  (setq mys-modeline-display
	(cond
	 ;; ((eq 2 (prefix-numeric-value argprompt))
	 ;; mys-python2-command-args)
	 ((string-match "^[^-]+3" shell)
	  mys-python3-modeline-display)
	 ((string-match "^[^-]+2" shell)
	  mys-python2-modeline-display)
	 ((string-match "^.[Ii]" shell)
	  mys-imys-modeline-display)
	 ((string-match "^.[Jj]" shell)
	  mys-jython-modeline-display)
	 (t
	  mys-mode-modeline-display))))

;;  bottle.py
;;  py   = sys.version_info
;;  py3k = py >= (3,0,0)
;;  py25 = py <  (2,6,0)
;;  py31 = (3,1,0) <= py < (3,2,0)

;;  sys.version_info[0]
(defun mys-mys-version (&optional executable verbose)
  "Returns versions number of a Python EXECUTABLE, string.

If no EXECUTABLE given, `mys-shell-name' is used.
Interactively output of `--version' is displayed. "
  (interactive)
  (let* ((executable (or executable mys-shell-name))
         (erg (mys--string-strip (shell-command-to-string (concat executable " --version")))))
    (when (called-interactively-p 'any) (message "%s" erg))
    (unless verbose (setq erg (cadr (split-string erg))))
    erg))

(defun mys-version ()
  "Echo the current version of `mys-mode' in the minibuffer."
  (interactive)
  (message "Using `mys-mode' version %s" mys-version))

(declare-function compilation-shell-minor-mode "compile" (&optional arg))

(defun mys--warn-tmp-files-left ()
  "Detect and warn about file of form \"py11046IoE\" in mys-temp-directory."
  (let ((erg1 (file-readable-p (concat mys-temp-directory mys-separator-char (car (directory-files  mys-temp-directory nil "py[[:alnum:]]+$"))))))
    (when erg1
      (message "mys--warn-tmp-files-left: %s ?" (concat mys-temp-directory mys-separator-char (car (directory-files  mys-temp-directory nil "py[[:alnum:]]*$")))))))

(defun mys--fetch-indent-line-above (&optional orig)
  "Report the preceding indent. "
  (save-excursion
    (when orig (goto-char orig))
    (forward-line -1)
    (current-indentation)))

(defun mys-continuation-offset (&optional arg)
  "Set if numeric ARG differs from 1. "
  (interactive "p")
  (and (numberp arg) (not (eq 1 arg)) (setq mys-continuation-offset arg))
  (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" mys-continuation-offset))
  mys-continuation-offset)

(defun mys-list-beginning-position (&optional start)
  "Return lists beginning position, nil if not inside.

Optional ARG indicates a start-position for `parse-partial-sexp'."
  (nth 1 (parse-partial-sexp (or start (point-min)) (point))))

(defun mys-end-of-list-position (&optional arg)
  "Return end position, nil if not inside.

Optional ARG indicates a start-position for `parse-partial-sexp'."
  (interactive)
  (let* ((ppstart (or arg (point-min)))
         (erg (parse-partial-sexp ppstart (point)))
         (beg (nth 1 erg))
         end)
    (when beg
      (save-excursion
        (goto-char beg)
        (forward-list 1)
        (setq end (point))))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" end))
    end))

(defun mys--in-comment-p ()
  "Return the beginning of current line's comment, if inside or at comment-start. "
  (save-restriction
    (widen)
    (let* ((pps (parse-partial-sexp (point-min) (point)))
           (erg (when (nth 4 pps) (nth 8 pps))))
      (unless erg
        (when (ignore-errors (looking-at (concat "[ \t]*" comment-start)))
          (setq erg (point))))
      erg)))

(defun mys-in-triplequoted-string-p ()
  "Returns character address of start tqs-string, nil if not inside. "
  (interactive)
  (let* ((pps (parse-partial-sexp (point-min) (point)))
         (erg (when (and (nth 3 pps) (nth 8 pps))(nth 2 pps))))
    (save-excursion
      (unless erg (setq erg
                        (progn
                          (when (looking-at "\"\"\"\\|''''")
                            (goto-char (match-end 0))
                            (setq pps (parse-partial-sexp (point-min) (point)))
                            (when (and (nth 3 pps) (nth 8 pps)) (nth 2 pps)))))))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" erg))
    erg))

(defun mys-in-string-p-intern (pps)
  (goto-char (nth 8 pps))
  (list (point) (char-after)(skip-chars-forward (char-to-string (char-after)))))

(defun mys-in-string-p ()
  "if inside a double- triple- or singlequoted string,

If non-nil, return a list composed of
- beginning position
- the character used as string-delimiter (in decimal)
- and length of delimiter, commonly 1 or 3 "
  (interactive)
  (save-excursion
    (let* ((pps (parse-partial-sexp (point-min) (point)))
           (erg (when (nth 3 pps)
                  (mys-in-string-p-intern pps))))
      (unless erg
        (when (looking-at "\"\\|'")
          (forward-char 1)
          (setq pps (parse-partial-sexp (line-beginning-position) (point)))
          (when (nth 3 pps)
            (setq erg (mys-in-string-p-intern pps)))))
      erg)))

(defun mys-toggle-local-default-use ()
  "Toggle boolean value of `mys-use-local-default'.

Returns `mys-use-local-default'

See also `mys-install-local-shells'
Installing named virualenv shells is the preffered way,
as it leaves your system default unchanged."
  (interactive)
  (setq mys-use-local-default (not mys-use-local-default))
  (when (called-interactively-p 'any) (message "mys-use-local-default set to %s" mys-use-local-default))
  mys-use-local-default)

(defun mys--beginning-of-buffer-position ()
  "Provided for abstract reasons."
  (point-min))

(defun mys--end-of-buffer-position ()
  "Provided for abstract reasons."
  (point-max))

(defun mys-backward-comment (&optional pos)
  "Got to beginning of a commented section.

Start from POS if specified"
  (interactive)
  (let ((erg pos)
	last)
    (when erg (goto-char erg))
    (while (and (not (bobp)) (setq erg (mys-in-comment-p)))
      (when (< erg (point))
	(goto-char erg)
	(setq last (point)))
      (skip-chars-backward " \t\r\n\f"))
    (when last (goto-char last))
    last))

(defun mys-go-to-beginning-of-comment ()
  "Go to the beginning of current line's comment, if any.

From a programm use macro `mys-backward-comment' instead"
  (interactive)
  (let ((erg (mys-backward-comment)))
    (when (and mys-verbose-p (called-interactively-p 'any))
      (message "%s" erg))))

(defun mys--up-decorators-maybe (indent)
  (let ((last (point)))
    (while (and (not (bobp))
		(mys-backward-statement)
		(eq (current-indentation) indent)
		(if (looking-at mys-decorator-re)
		    (progn (setq last (point)) nil)
		  t)))
    (goto-char last)))

(defun mys-leave-comment-or-string-backward ()
  "If inside a comment or string, leave it backward."
  (interactive)
  (let ((pps
         (if (featurep 'xemacs)
             (parse-partial-sexp (point-min) (point))
           (parse-partial-sexp (point-min) (point)))))
    (when (nth 8 pps)
      (goto-char (1- (nth 8 pps))))))

;;  Decorator
(defun mys-backward-decorator ()
  "Go to the beginning of a decorator.

Returns position if succesful"
  (interactive)
  (let ((orig (point)))
    (unless (bobp) (forward-line -1)
	    (back-to-indentation)
	    (while (and (progn (looking-at "@\\w+")(not (looking-at "\\w+")))
			(not
			 ;; (mys-empty-line-p)
			 (member (char-after) (list 9 10)))
			(not (bobp))(forward-line -1))
	      (back-to-indentation))
	    (or (and (looking-at "@\\w+") (match-beginning 0))
		(goto-char orig)))))

(defun mys-forward-decorator ()
  "Go to the end of a decorator.

Returns position if succesful"
  (interactive)
  (let ((orig (point)) erg)
    (unless (looking-at "@\\w+")
      (setq erg (mys-backward-decorator)))
    (when erg
      (if
          (re-search-forward mys-def-or-class-re nil t)
          (progn
            (back-to-indentation)
            (skip-chars-backward " \t\r\n\f")
            (mys-leave-comment-or-string-backward)
            (skip-chars-backward " \t\r\n\f")
            (setq erg (point)))
        (goto-char orig)
        (end-of-line)
        (skip-chars-backward " \t\r\n\f")
        (when (ignore-errors (goto-char (mys-list-beginning-position)))
          (forward-list))
        (when (< orig (point))
          (setq erg (point))))
      erg)))

(defun mys-beginning-of-list-pps (&optional iact last ppstart orig done)
  "Go to the beginning of a list.

IACT - if called interactively
LAST - was last match.
Optional PPSTART indicates a start-position for `parse-partial-sexp'.
ORIG - consider orignial position or point.
DONE - transaktional argument
Return beginning position, nil if not inside."
  (interactive "p")
  (let* ((orig (or orig (point)))
         (ppstart (or ppstart (re-search-backward "^[a-zA-Z]" nil t 1) (point-min)))
         erg)
    (unless done (goto-char orig))
    (setq done t)
    (if
        (setq erg (nth 1 (if (featurep 'xemacs)
                             (parse-partial-sexp ppstart (point))
                           (parse-partial-sexp (point-min) (point)))))
        (progn
          (setq last erg)
          (goto-char erg)
          (mys-beginning-of-list-pps iact last ppstart orig done))
      last)))

(defun mys-end-of-string (&optional beginning-of-string-position)
  "Go to end of string at point if any, if successful return position. "
  (interactive)
  (let ((orig (point))
        (beginning-of-string-position (or beginning-of-string-position (and (nth 3 (parse-partial-sexp 1 (point)))(nth 8 (parse-partial-sexp 1 (point))))
                                          (and (looking-at "\"\"\"\\|'''\\|\"\\|\'")(match-beginning 0))))
        erg)
    (if beginning-of-string-position
        (progn
          (goto-char beginning-of-string-position)
          (when
              ;; work around parse-partial-sexp error
              (and (nth 3 (parse-partial-sexp 1 (point)))(nth 8 (parse-partial-sexp 1 (point))))
            (goto-char (nth 3 (parse-partial-sexp 1 (point)))))
          (if (ignore-errors (setq erg (scan-sexps (point) 1)))
                              (goto-char erg)
            (goto-char orig)))

      (error (concat "mys-end-of-string: don't see end-of-string at " (buffer-name (current-buffer)) "at pos " (point))))
    erg))

(defun mys--record-list-error (pps)
  "When encountering a missing parenthesis, store its line, position.
`mys-verbose-p'  must be t"
  (let ((this-err
         (save-excursion
           (list
            (nth 1 pps)
            (progn
              (goto-char (nth 1 pps))
              (mys-count-lines (point-min) (point)))))))
    this-err))

(defun mys--message-error (err)
  "Receives a list (position line) "
  (message "Closing paren missed: line %s pos %s" (cadr err) (car err)))

(defun mys--end-base-determine-secondvalue (regexp)
  "Expects being at block-opener.

REGEXP: a symbol"
  (cond
   ((eq regexp 'mys-minor-block-re)
    (cond ((looking-at mys-else-re)
	   nil)
	  ((or (looking-at (concat mys-try-re)))
	   (concat mys-elif-re "\\|" mys-else-re "\\|" mys-except-re))
	  ((or (looking-at (concat mys-except-re "\\|" mys-elif-re "\\|" mys-if-re)))
	   (concat mys-elif-re "\\|" mys-else-re))))
   ((member regexp
	    (list
	     'mys-block-re
	     'mys-block-or-clause-re
	     'mys-clause-re
	     'mys-if-re
	     ))
    (cond ((looking-at mys-if-re)
	   (concat mys-elif-re "\\|" mys-else-re))
	  ((looking-at mys-elif-re)
	   (concat mys-elif-re "\\|" mys-else-re))
	  ((looking-at mys-else-re))
	  ((looking-at mys-try-re)
	   (concat mys-except-re "\\|" mys-else-re "\\|" mys-finally-re))
	  ((looking-at mys-except-re)
	   (concat mys-else-re "\\|" mys-finally-re))
	  ((looking-at mys-finally-re)
	   nil)))
   ((eq regexp 'mys-for-re) nil)
   ((eq regexp 'mys-try-re)
    (cond
     ((looking-at mys-try-re)
      (concat mys-except-re "\\|" mys-else-re "\\|" mys-finally-re))
     ((looking-at mys-except-re)
      (concat mys-else-re "\\|" mys-finally-re))
     ((looking-at mys-finally-re))))))

(defun mys--go-to-keyword (regexp &optional maxindent condition ignoreindent)
  "Expects being called from beginning of a statement.

Argument REGEXP: a symbol.

Return a list, whose car is indentation, cdr position.

Keyword detected from REGEXP
Honor MAXINDENT if provided
Optional IGNOREINDENT: find next keyword at any indentation"
  (unless (bobp)
    ;;    (when (mys-empty-line-p) (skip-chars-backward " \t\r\n\f"))
    (let* ((orig (point))
	   (condition
	    (or condition (if (eq regexp 'mys-clause-re) '< '<=)))
	   ;; mys-clause-re would not match block
	   (regexp (if (eq regexp 'mys-clause-re) 'mys-extended-block-or-clause-re regexp))
	   (regexpvalue (symbol-value regexp))
	   (maxindent
	    (if ignoreindent
		;; just a big value
		9999
	      (or maxindent
		  ;; (if
		  ;;     (or (looking-at regexpvalue) (eq 0 (current-indentation)))
		  ;;     (current-indentation)
		  ;;   (abs
		  ;;    (- (current-indentation) mys-indent-offset)))
                  (min (current-column) (current-indentation)))))
           (lep (line-end-position))
	   erg)
      (unless (mys-beginning-of-statement-p)
	(mys-backward-statement))
      (cond
       ((looking-at (concat (symbol-value regexp)))
	(if (eq (point) orig)
	    (setq erg (mys--backward-regexp regexp maxindent condition orig regexpvalue))
	  (setq erg (point))))
       ((looking-at mys-block-closing-keywords-re)
        ;; maybe update maxindent, if already behind the form closed here
        (unless ;; do not update if still starting line
            (eq (line-end-position) lep)
          (setq maxindent (min maxindent (- (current-indentation) mys-indent-offset))))
        (setq erg (mys--backward-regexp regexp maxindent condition orig regexpvalue)))
       (t (setq erg (mys--backward-regexp regexp maxindent condition orig regexpvalue))))
      (when erg (setq erg (cons (current-indentation) erg)))
      (list (car erg) (cdr erg) (mys--end-base-determine-secondvalue regexp)))))

(defun mys-up-base (regexp &optional indent)
  "Expects a symbol as REGEXP like `'mys-clause-re'"
  (unless (mys-beginning-of-statement-p) (mys-backward-statement))
  (unless (looking-at (symbol-value regexp))
        (mys--go-to-keyword regexp (or indent (current-indentation)) '<))
  ;; now from beginning-of-block go one indent level upwards
  (mys--go-to-keyword regexp (- (or indent (current-indentation)) mys-indent-offset) '<))

(defun mys--forward-regexp (regexp)
  "Search forward next regexp not in string or comment.

Return and move to match-beginning if successful"
  (save-match-data
    (let (erg)
      (while (and
              (setq erg (re-search-forward regexp nil 'move 1))
              (nth 8 (parse-partial-sexp (point-min) (point)))))
      (unless
	  (nth 8 (parse-partial-sexp (point-min) (point)))
        erg))))
(defun mys--forward-regexp-keep-indent (regexp &optional indent)
  "Search forward next regexp not in string or comment.

Return and move to match-beginning if successful"
  (save-match-data
    (let ((indent (or indent (current-indentation)))
          (regexp (if (stringp regexp)
                      regexp
                    (symbol-value regexp)))
	  (orig (point))
          last done)
      (forward-line 1)
      (beginning-of-line)
      (while (and
	      (not done)
              (re-search-forward regexp nil 'move 1)
              (or (nth 8 (parse-partial-sexp (point-min) (point)))
                  (or (< indent (current-indentation))(setq done t))
		  (setq last (line-end-position)))))
      (unless
          (nth 8 (parse-partial-sexp (point-min) (point)))
	(if last (goto-char last)
	  (back-to-indentation))
        (and (< orig (point)) (point))))))

(defun mys-down-base (regexp &optional indent bol)
  (let ((indent (or indent (current-indentation))))
    (and (mys--forward-regexp-keep-indent regexp indent)
	 (progn
           (if bol
               (beginning-of-line)
             (back-to-indentation))
           (point)))))

(defun mys--beginning-of-statement-p (&optional pps)
  "Return position, if cursor is at the beginning of a `statement', nil otherwise."
  (interactive)
  (save-excursion
    (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
      (and (not (or (nth 8 pps) (nth 1 pps)))
           (looking-at mys-statement-re)
           (looking-back "[^ \t]*" (line-beginning-position))
           (eq (current-column) (current-indentation))
	   (eq (point) (progn (mys-forward-statement) (mys-backward-statement)))
           (point)))))

(defun mys--beginning-of-statement-bol-p (&optional pps)
  "Return position, if cursor is at the beginning of a `statement', nil otherwise."
  (save-excursion
    (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
      (and (bolp)
           (not (or (nth 8 pps) (nth 1 pps)))
           (looking-at mys-statement-re)
           (looking-back "[^ \t]*" (line-beginning-position))
	   (eq (point) (progn (mys-forward-statement-bol) (mys-backward-statement-bol)))
           (point)))))

(defun mys--refine-regexp-maybe (regexp)
  "Use a more specific regexp if possible. "
  (let ((regexpvalue (symbol-value regexp)))
    (if (looking-at regexpvalue)
	(setq regexp
	      (cond ((looking-at mys-if-re)
		     'mys-if-re)
		    ((looking-at mys-try-re)
		     'mys-try-re)
		    ((looking-at mys-def-re)
		     'mys-def-re)
		    ((looking-at mys-class-re)
		     'mys-class-re)
		    (t regexp)))
      regexp)))

(defun mys-forward-clause-intern (indent)
  (end-of-line)
  (let (last)
    (while
        (and
         (mys-forward-statement)
         (save-excursion (mys-backward-statement) (< indent (current-indentation)))
         (setq last (point))
         ))
    (when last (goto-char last))))

(defun mys--down-according-to-indent (regexp secondvalue &optional indent use-regexp)
  "Return position if moved, nil otherwise.

Optional ENFORCE-REGEXP: search for regexp only."
  (unless (eobp)
    (let* ((orig (point))
	   (indent (or indent 0))
	   done
	   (regexpvalue (if (member regexp (list 'mys-def-re 'mys-def-or-class-re 'mys-class-re))
			    (concat (symbol-value regexp) "\\|" (symbol-value 'mys-decorator-re))
			  (symbol-value regexp)))
	   (lastvalue (and secondvalue
			   (pcase regexp
			     (`mys-try-re mys-finally-re)
			     (`mys-if-re mys-else-re)))))
      (if (eq regexp 'mys-clause-re)
          (mys-forward-clause-intern indent)
      (while
	  (and
	   (not done)
	   (progn (end-of-line)
		  (cond (use-regexp
			 ;; using regexpvalue might stop behind global settings, missing the end of form
			 (re-search-forward (concat "^ \\{0,"(format "%s" indent) "\\}"regexpvalue) nil 'move 1))
			(t (re-search-forward (concat "^ \\{"(format "0,%s" indent) "\\}[[:alnum:]_@]+") nil 'move 1))))
	   (or (nth 8 (parse-partial-sexp (point-min) (point)))
	       (progn (back-to-indentation) (mys--forward-string-maybe (nth 8 (parse-partial-sexp orig (point)))))
	       (and secondvalue (looking-at secondvalue))
	       (and lastvalue (looking-at lastvalue))
	       (and (looking-at regexpvalue) (setq done t))
	       ;; mys-forward-def-or-class-test-3JzvVW
	       ;; (setq done t)
               )))
      (and (< orig (point)) (point))))))

(defun mys--backward-empty-lines-or-comment ()
  "Travel backward"
  (while
      (or (< 0 (abs (skip-chars-backward " \t\r\n\f")))
	  (mys-backward-comment))))

;; (defun mys-kill-buffer-unconditional (buffer)
;;   "Kill buffer unconditional, kill buffer-process if existing. "
;;   (interactive
;;    (list (current-buffer)))
;;   (ignore-errors (with-current-buffer buffer
;;     (let (kill-buffer-query-functions)
;;       (set-buffer-modified-p nil)
;;       (ignore-errors (kill-process (get-buffer-process buffer)))
;;       (kill-buffer buffer)))))

(defun mys--down-end-form ()
  "Return position."
  (progn (mys--backward-empty-lines-or-comment)
	 (point)))

(defun mys--which-delay-process-dependent (buffer)
  "Call a `mys-imys-send-delay' or `mys-mys-send-delay' according to process"
  (if (string-match "^.[IJ]" buffer)
      mys-imys-send-delay
    mys-mys-send-delay))

(defun mys-temp-file-name (strg)
  (let* ((temporary-file-directory
          (if (file-remote-p default-directory)
              (concat (file-remote-p default-directory) "/tmp")
            temporary-file-directory))
         (temp-file-name (make-temp-file "py")))

    (with-temp-file temp-file-name
      (insert strg)
      (delete-trailing-whitespace))
    temp-file-name))

(defun mys--fetch-error (output-buffer &optional origline filename)
  "Highlight exceptions found in BUF.

If an exception occurred return error-string, otherwise return nil.
BUF must exist.

Indicate LINE if code wasn't run from a file,
thus remember ORIGLINE of source buffer"
  (with-current-buffer output-buffer
    (when mys-debug-p (switch-to-buffer (current-buffer)))
    ;; (setq mys-error (buffer-substring-no-properties (point) (point-max)))
    (goto-char (point-max))
    (when (re-search-backward "File \"\\(.+\\)\", line \\([0-9]+\\)\\(.*\\)$" nil t)
      (when (and filename (re-search-forward "File \"\\(.+\\)\", line \\([0-9]+\\)\\(.*\\)$" nil t)
		 (replace-match filename nil nil nil 1))
	(when (and origline (re-search-forward "line \\([0-9]+\\)\\(.*\\)$" (line-end-position) t 1))
	  (replace-match origline nil nil nil 2)))
      (setq mys-error (buffer-substring-no-properties (point) (point-max))))
        mys-error))

(defvar mys-debug-p nil
  "Used for development purposes.")

(defun mys--fetch-result (buffer limit &optional cmd)
  "CMD: some shells echo the command in output-buffer
Delete it here"
  (when mys-debug-p (message "(current-buffer): %s" (current-buffer))
	(switch-to-buffer (current-buffer)))
  (cond (mys-mode-v5-behavior-p
	 (with-current-buffer buffer
	   (mys--string-trim (buffer-substring-no-properties (point-min) (point-max)) nil "\n")))
	((and cmd (< limit (point-max)))
	 (replace-regexp-in-string cmd "" (mys--string-trim (replace-regexp-in-string mys-shell-prompt-regexp "" (buffer-substring-no-properties limit (point-max))))))
	(t (when (< limit (point-max))
	     (mys--string-trim (replace-regexp-in-string mys-shell-prompt-regexp "" (buffer-substring-no-properties limit (point-max))))))))

(defun mys--postprocess (output-buffer origline limit &optional cmd filename)
  "Provide return values, check result for error, manage windows.

According to OUTPUT-BUFFER ORIGLINE ORIG"
  ;; mys--fast-send-string doesn't set origline
  (when (or mys-return-result-p mys-store-result-p)
    (with-current-buffer output-buffer
      (when mys-debug-p (switch-to-buffer (current-buffer)))
      (sit-for (mys--which-delay-process-dependent (prin1-to-string output-buffer)))
      ;; (catch 'mys--postprocess
      (setq mys-result (mys--fetch-result output-buffer limit cmd))
      ;; (throw 'mys--postprocess (error "mys--postprocess failed"))
      ;;)
      (if (and mys-result (not (string= "" mys-result)))
	  (if (string-match "^Traceback" mys-result)
	      (if filename
		  (setq mys-error mys-result)
		(progn
		  (with-temp-buffer
		    (insert mys-result)
		    (sit-for 0.1 t)
		    (setq mys-error (mys--fetch-error origline filename)))))
	    (when mys-store-result-p
	      (kill-new mys-result))
	    (when mys-verbose-p (message "mys-result: %s" mys-result))
	    mys-result)
	(when mys-verbose-p (message "mys--postprocess: %s" "Don't see any result"))))))

(defun mys-fetch-mys-master-file ()
  "Lookup if a `mys-master-file' is specified.

See also doku of variable `mys-master-file'"
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward "^ *# Local Variables:" nil (quote move) 1)
        (when
            (re-search-forward (concat "^\\( *# mys-master-file: *\\)\"\\([^ \t]+\\)\" *$") nil t 1)
          (setq mys-master-file (match-string-no-properties 2))))))
  ;; (when (called-interactively-p 'any) (message "%s" mys-master-file))
  )

(defun mys-imys--which-version (shell)
  "Returns Imys version as string"
  (shell-command-to-string (concat (downcase (replace-regexp-in-string  "[[:punct:]+]" "" shell)) " -V")))

(defun mys--provide-command-args (shell fast-process)
  "Unbuffered WRT fast-process"
  (let ((erg
	 (delq nil
	       (cond
		;; ((eq 2 (prefix-numeric-value argprompt))
		;; mys-python2-command-args)
		((string-match "^[Ii]" shell)
		 (if (string-match "^[0-4]" (mys-imys--which-version shell))
		     (remove "--simple-prompt"  mys-imys-command-args)
		   (if (member "--simple-prompt"  mys-imys-command-args)
		       mys-imys-command-args
		     (cons "--simple-prompt"  mys-imys-command-args))))
		((string-match "^[^-]+3" shell)
		 mys-python3-command-args)
                ((string-match "^[jy]" shell)
                 mys-jython-command-args)
		(t
		 mys-mys-command-args)))))
    (if (and fast-process (not (member "-u" erg)))
	(cons "-u" erg)
      erg)))

;; This and other stuff from python.el
(defun mys-info-encoding-from-cookie ()
  "Detect current buffer's encoding from its coding cookie.
Returns the encoding as a symbol."
  (let ((first-two-lines
         (save-excursion
           (save-restriction
             (widen)
             (goto-char (point-min))
             (forward-line 2)
             (buffer-substring-no-properties
              (point)
              (point-min))))))
    (when (string-match
	   ;; (mys-rx coding-cookie)
	   "^#[[:space:]]*\\(?:coding[:=][[:space:]]*\\(?1:\\(?:[[:word:]]\\|-\\)+\\)\\|-\\*-[[:space:]]*coding:[[:space:]]*\\(?1:\\(?:[[:word:]]\\|-\\)+\\)[[:space:]]*-\\*-\\|vim:[[:space:]]*set[[:space:]]+fileencoding[[:space:]]*=[[:space:]]*\\(?1:\\(?:[[:word:]]\\|-\\)+\\)[[:space:]]*:\\)"
	   first-two-lines)
      (intern (match-string-no-properties 1 first-two-lines)))))

(defun mys-info-encoding ()
  "Return encoding for file.
Try `mys-info-encoding-from-cookie', if none is found then
default to utf-8."
  (or (mys-info-encoding-from-cookie)
      'utf-8))

(defun mys-indentation-of-statement ()
  "Returns the indenation of the statement at point. "
  (interactive)
  (let ((erg (save-excursion
               (back-to-indentation)
               (or (mys--beginning-of-statement-p)
                   (mys-backward-statement))
               (current-indentation))))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" erg))
    erg))

(defun mys--filter-result (strg)
  "Set `mys-result' according to `mys-fast-filter-re'.

Remove trailing newline"
  (mys--string-trim
   (replace-regexp-in-string
    mys-fast-filter-re
    ""
    (ansi-color-filter-apply strg))))

(defun mys--cleanup-shell (orig buffer)
  (with-current-buffer buffer
    (with-silent-modifications
      (sit-for mys-python3-send-delay)
      (when mys-debug-p (switch-to-buffer (current-buffer)))
      (delete-region orig (point-max)))))

(defun mys-shell--save-temp-file (strg)
  (let* ((temporary-file-directory
          (if (file-remote-p default-directory)
              (concat (file-remote-p default-directory) "/tmp")
            temporary-file-directory))
         (temp-file-name (make-temp-file "py"))
         (coding-system-for-write (mys-info-encoding)))
    (with-temp-file temp-file-name
      (insert strg)
      (delete-trailing-whitespace))
    temp-file-name))

(defun mys--get-process (&optional argprompt args dedicated shell buffer)
  "Get appropriate Python process for current buffer and return it.

Optional ARGPROMPT DEDICATED SHELL BUFFER"
  (interactive)
  (or (and buffer (get-buffer-process buffer))
      (get-buffer-process (current-buffer))
      (get-buffer-process (mys-shell argprompt args dedicated shell buffer))))

(defun mys-shell-send-file (file-name &optional process temp-file-name
                                     delete)
  "Send FILE-NAME to Python PROCESS.

If TEMP-FILE-NAME is passed then that file is used for processing
instead, while internally the shell will continue to use
FILE-NAME.  If TEMP-FILE-NAME and DELETE are non-nil, then
TEMP-FILE-NAME is deleted after evaluation is performed.  When
optional argument."
  (interactive
   (list
    (read-file-name "File to send: ")))
  (let* ((proc (or process (mys--get-process)))
         (encoding (with-temp-buffer
                     (insert-file-contents
                      (or temp-file-name file-name))
                     (mys-info-encoding)))
         (file-name (expand-file-name (file-local-name file-name)))
         (temp-file-name (when temp-file-name
                           (expand-file-name
                            (file-local-name temp-file-name)))))
    (mys-shell-send-string
     (format
      (concat
       "import codecs, os;"
       "__pyfile = codecs.open('''%s''', encoding='''%s''');"
       "__code = __pyfile.read().encode('''%s''');"
       "__pyfile.close();"
       (when (and delete temp-file-name)
         (format "os.remove('''%s''');" temp-file-name))
       "exec(compile(__code, '''%s''', 'exec'));")
      (or temp-file-name file-name) encoding encoding file-name)
     proc)))

(defun mys-shell-send-string (strg &optional process)
  "Send STRING to Python PROCESS.

Uses `comint-send-string'."
  (interactive
   (list (read-string "Python command: ") nil t))
  (let ((process (or process (mys--get-process))))
    (if (string-match ".\n+." strg)   ;Multiline.
        (let* ((temp-file-name (mys-shell--save-temp-file strg))
               (file-name (or (buffer-file-name) temp-file-name)))
          (mys-shell-send-file file-name process temp-file-name t))
      (comint-send-string process strg)
      (when (or (not (string-match "\n\\'" strg))
                (string-match "\n[ \t].*\n?\\'" strg))
        (comint-send-string process "\n")))))

(defun mys-fast-process (&optional buffer)
  "Connect am (I)Python process suitable for large output.

Output buffer displays \"Fast\"  by default
It is not in interactive, i.e. comint-mode,
as its bookkeepings seem linked to the freeze reported by lp:1253907"
  (interactive)
  (let ((this-buffer
         (set-buffer (or (and buffer (get-buffer-create buffer))
                         (get-buffer-create mys-shell-name)))))
    (let ((proc (start-process mys-shell-name this-buffer mys-shell-name)))
      (with-current-buffer this-buffer
        (erase-buffer))
      proc)))

(defun mys-proc (&optional argprompt)
  "Return the current Python process.

Start a new process if necessary. "
  (interactive "P")
  (let ((erg
         (cond ((comint-check-proc (current-buffer))
                (get-buffer-process (buffer-name (current-buffer))))
               (t (mys-shell argprompt)))))
    erg))

(defun mys-process-file (filename &optional output-buffer error-buffer)
  "Process \"python FILENAME\".

Optional OUTPUT-BUFFER and ERROR-BUFFER might be given."
  (interactive "fDatei:")
  (let ((coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8)
        (output-buffer (or output-buffer (make-temp-name "mys-process-file-output")))
        (pcmd (mys-choose-shell)))
    (unless (buffer-live-p output-buffer)
      (set-buffer (get-buffer-create output-buffer)))
    (shell-command (concat pcmd " " filename) output-buffer error-buffer)
    (when mys-switch-buffers-on-execute-p (switch-to-buffer output-buffer))))

(defvar mys-last-exeption-buffer nil
  "Internal use only - when `mys-up-exception' is called.

In source-buffer, this will deliver the exception-buffer again.")

(defun mys-remove-overlays-at-point ()
  "Remove overlays as set when `mys-highlight-error-source-p' is non-nil."
  (interactive "*")
  (delete-overlay (car (overlays-at (point)))))

(defun mys--jump-to-exception-intern (act exception-buffer origline)
  (let (erg)
    (set-buffer exception-buffer)
    (goto-char (point-min))
    (forward-line (1- origline))
    (and (search-forward act (line-end-position) t)
         (and mys-verbose-p (message "exception-buffer: %s on line %d" mys-exception-buffer origline))
         (and mys-highlight-error-source-p
              (setq erg (make-overlay (match-beginning 0) (match-end 0)))
              (overlay-put erg
                           'face 'highlight)))))

(defun mys--jump-to-exception (perr origline &optional file)
  "Jump to the PERR Python code at ORIGLINE in optional FILE."
  (let (
        (inhibit-point-motion-hooks t)
        (file (or file (car perr)))
        (act (nth 2 perr)))
    (cond ((and mys-exception-buffer
                (buffer-live-p mys-exception-buffer))
           ;; (pop-to-buffer procbuf)
           (mys--jump-to-exception-intern act mys-exception-buffer origline))
          ((ignore-errors (file-readable-p file))
           (find-file file)
           (mys--jump-to-exception-intern act (get-buffer (file-name-nondirectory file)) origline))
          ((buffer-live-p (get-buffer file))
           (set-buffer file)
           (mys--jump-to-exception-intern act file origline))
          (t (setq file (find-file (read-file-name "Exception file: "
                                                   nil
                                                   file t)))
             (mys--jump-to-exception-intern act file origline)))))

(defun mys-goto-exception (&optional file line)
  "Go to FILE and LINE indicated by the traceback."
  (interactive)
  (let ((file file)
        (line line))
    (unless (and file line)
      (save-excursion
        (beginning-of-line)
        (if (looking-at mys-traceback-line-re)
            (setq file (substring-no-properties (match-string 1))
                  line (string-to-number (match-string 2))))))
    (if (not file)
        (error "Not on a traceback line"))
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun mys--find-next-exception (start buffer searchdir errwhere)
  "Find the next Python exception and jump to the code that caused it.
START is the buffer position in BUFFER from which to begin searching
for an exception.  SEARCHDIR is a function, either
`re-search-backward' or `re-search-forward' indicating the direction
to search.  ERRWHERE is used in an error message if the limit (top or
bottom) of the trackback stack is encountered."
  (let (file line)
    (save-excursion
      (with-current-buffer buffer
	(goto-char start)
	(if (funcall searchdir mys-traceback-line-re nil t)
	    (setq file (match-string 1)
		  line (string-to-number (match-string 2))))))
    (if (and file line)
        (mys-goto-exception file line)
      (error "%s of traceback" errwhere))))

(defun mys-down-exception (&optional bottom)
  "Go to the next line down in the traceback.
With \\[univeral-argument] (programmatically, optional argument
BOTTOM), jump to the bottom (innermost) exception in the exception
stack."
  (interactive "P")
  (let* ((buffer mys-output-buffer))
    (if bottom
        (mys--find-next-exception 'eob buffer 're-search-backward "Bottom")
      (mys--find-next-exception 'eol buffer 're-search-forward "Bottom"))))

(defun mys-up-exception (&optional top)
  "Go to the previous line up in the traceback.
With \\[universal-argument] (programmatically, optional argument TOP)
jump to the top (outermost) exception in the exception stack."
  (interactive "P")
  (let* ((buffer mys-output-buffer))
    (if top
        (mys--find-next-exception 'bob buffer 're-search-forward "Top")
      (mys--find-next-exception 'bol buffer 're-search-backward "Top"))))

;; ;
;;  obsolete by mys--fetch-result
;;  followed by mys--fetch-error
;;  still used by mys--execute-ge24.3

(defun mys--find-next-exception-prepare (direction start)
  "According to DIRECTION and START setup exception regexps.

Depends from kind of Python shell."
  (let* ((name (get-process (substring (buffer-name (current-buffer)) 1 -1)))
         (buffer (cond (name (buffer-name (current-buffer)))
                       ((buffer-live-p (get-buffer mys-output-buffer))
                        mys-output-buffer)
                       (mys-last-exeption-buffer (buffer-name mys-last-exeption-buffer))
                       (t (error "Don't see exeption buffer")))))
    (when buffer (set-buffer (get-buffer buffer)))
    (if (eq direction 'up)
        (if (string= start "TOP")
            (mys--find-next-exception 'bob buffer 're-search-forward "Top")
          (mys--find-next-exception 'bol buffer 're-search-backward "Top"))
      (if (string= start "BOTTOM")
          (mys--find-next-exception 'eob buffer 're-search-backward "Bottom")
        (mys--find-next-exception 'eol buffer 're-search-forward "Bottom")))))

(defun mys-shell-comint-end-of-output-p (output)
  "Return non-nil if OUTPUT ends with input prompt."
  (ignore-errors (string-match
		  ;; XXX: It seems on macOS an extra carriage return is attached
		  ;; at the end of output, this handles that too.
		  (concat
		   "\r?\n?"
		   ;; Remove initial caret from calculated regexp
		   (ignore-errors (replace-regexp-in-string
				   (rx string-start ?^) ""
				   mys-shell--prompt-calculated-input-regexp))
		   (rx eos))
		  output)))

(defun mys-comint-postoutput-scroll-to-bottom (output)
  "Faster version of `comint-postoutput-scroll-to-bottom'.
Avoids `recenter' calls until OUTPUT is completely sent."
  (when (and (not (string= "" output))
             (mys-shell-comint-end-of-output-p
              (ansi-color-filter-apply output)))
    (comint-postoutput-scroll-to-bottom output))
  output)

(defmacro mys-shell--add-to-path-with-priority (pathvar paths)
  "Modify PATHVAR and ensure PATHS are added only once at beginning."
  `(dolist (path (reverse ,paths))
     (cl-delete path ,pathvar :test #'string=)
     (cl-pushnew path ,pathvar :test #'string=)))

(defun mys-shell-tramp-refresh-remote-path (vec paths)
  "Update VEC's remote-path giving PATHS priority."
  (let ((remote-path (tramp-get-connection-property vec "remote-path" nil)))
    (when remote-path
      (mys-shell--add-to-path-with-priority remote-path paths)
      (tramp-set-connection-property vec "remote-path" remote-path)
      (tramp-set-remote-path vec))))

(defun mys-shell-tramp-refresh-process-environment (vec env)
  "Update VEC's process environment with ENV."
  ;; Stolen from `tramp-open-connection-setup-interactive-shell'.
  (let ((env (append (when (fboundp 'tramp-get-remote-locale)
                       ;; Emacs<24.4 compat.
                       (list (tramp-get-remote-locale vec)))
		     (comys-sequence env)))
        (tramp-end-of-heredoc
         (if (boundp 'tramp-end-of-heredoc)
             tramp-end-of-heredoc
           (md5 tramp-end-of-output)))
	unset vars item)
    (while env
      (setq item (split-string (car env) "=" 'omit))
      (setcdr item (mapconcat 'identity (cdr item) "="))
      (if (and (stringp (cdr item)) (not (string-equal (cdr item) "")))
	  (push (format "%s %s" (car item) (cdr item)) vars)
	(push (car item) unset))
      (setq env (cdr env)))
    (when vars
      (tramp-send-command
       vec
       (format "while read var val; do export $var=$val; done <<'%s'\n%s\n%s"
	       tramp-end-of-heredoc
	       (mapconcat 'identity vars "\n")
	       tramp-end-of-heredoc)
       t))
    (when unset
      (tramp-send-command
       vec (format "unset %s" (mapconcat 'identity unset " ")) t))))

(defun mys-shell-calculate-pythonpath ()
  "Calculate the PYTHONPATH using `mys-shell-extra-pythonpaths'."
  (let ((pythonpath
         (split-string
          (or (getenv "PYTHONPATH") "") path-separator 'omit)))
    (mys-shell--add-to-path-with-priority
     pythonpath mys-shell-extra-pythonpaths)
    (mapconcat 'identity pythonpath path-separator)))

(defun mys-shell-calculate-exec-path ()
  "Calculate `exec-path'.
Prepends `mys-shell-exec-path' and adds the binary directory
for virtualenv if `mys-shell-virtualenv-root' is set - this
will use the python interpreter from inside the virtualenv when
starting the shell.  If `default-directory' points to a remote host,
the returned value appends `mys-shell-remote-exec-path' instead
of `exec-path'."
  (let ((new-path (comys-sequence
                   (if (file-remote-p default-directory)
                       mys-shell-remote-exec-path
                     exec-path)))

        ;; Windows and POSIX systems use different venv directory structures
        (virtualenv-bin-dir (if (eq system-type 'windows-nt) "Scripts" "bin")))
    (mys-shell--add-to-path-with-priority
     new-path mys-shell-exec-path)
    (if (not mys-shell-virtualenv-root)
        new-path
      (mys-shell--add-to-path-with-priority
       new-path
       (list (expand-file-name virtualenv-bin-dir mys-shell-virtualenv-root)))
      new-path)))

(defun mys-shell-calculate-process-environment ()
  "Calculate `process-environment' or `tramp-remote-process-environment'.
Prepends `mys-shell-process-environment', sets extra
pythonpaths from `mys-shell-extra-pythonpaths' and sets a few
virtualenv related vars.  If `default-directory' points to a
remote host, the returned value is intended for
`tramp-remote-process-environment'."
  (let* ((remote-p (file-remote-p default-directory))
         (process-environment (if remote-p
                                  tramp-remote-process-environment
                                process-environment))
         (virtualenv (when mys-shell-virtualenv-root
                       (directory-file-name mys-shell-virtualenv-root))))
    (dolist (env mys-shell-process-environment)
      (pcase-let ((`(,key ,value) (split-string env "=")))
        (setenv key value)))
    (when mys-shell-unbuffered
      (setenv "PYTHONUNBUFFERED" "1"))
    (when mys-shell-extra-pythonpaths
      (setenv "PYTHONPATH" (mys-shell-calculate-pythonpath)))
    (if (not virtualenv)
        process-environment
      (setenv "PYTHONHOME" nil)
      (setenv "VIRTUAL_ENV" virtualenv))
    process-environment))

(defmacro mys-shell-with-environment (&rest body)
  "Modify shell environment during execution of BODY.
Temporarily sets `process-environment' and `exec-path' during
execution of body.  If `default-directory' points to a remote
machine then modifies `tramp-remote-process-environment' and
`mys-shell-remote-exec-path' instead."
  (declare (indent 0) (debug (body)))
  (let ((vec (make-symbol "vec")))
    `(progn
       (let* ((,vec
               (when (file-remote-p default-directory)
                 (ignore-errors
                   (tramp-dissect-file-name default-directory 'noexpand))))
              (process-environment
               (if ,vec
                   process-environment
                 (mys-shell-calculate-process-environment)))
              (exec-path
               (if ,vec
                   exec-path
                 (mys-shell-calculate-exec-path)))
              (tramp-remote-process-environment
               (if ,vec
                   (mys-shell-calculate-process-environment)
                 tramp-remote-process-environment)))
         (when (tramp-get-connection-process ,vec)
           ;; For already existing connections, the new exec path must
           ;; be re-set, otherwise it won't take effect.  One example
           ;; of such case is when remote dir-locals are read and
           ;; *then* subprocesses are triggered within the same
           ;; connection.
           (mys-shell-tramp-refresh-remote-path
            ,vec (mys-shell-calculate-exec-path))
           ;; The `tramp-remote-process-environment' variable is only
           ;; effective when the started process is an interactive
           ;; shell, otherwise (like in the case of processes started
           ;; with `process-file') the environment is not changed.
           ;; This makes environment modifications effective
           ;; unconditionally.
           (mys-shell-tramp-refresh-process-environment
            ,vec tramp-remote-process-environment))
         ,(macroexp-progn body)))))

(defun mys-shell-prompt-detect ()
  "Detect prompts for the current interpreter.
When prompts can be retrieved successfully from the
interpreter run with
`mys-mys-command-args', returns a list of
three elements, where the first two are input prompts and the
last one is an output prompt.  When no prompts can be detected
shows a warning with instructions to avoid hangs and returns nil.
When `mys-shell-prompt-detect-p' is nil avoids any
detection and just returns nil."
  (when mys-shell-prompt-detect-p
    (mys-shell-with-environment
      (let* ((code (concat
                    "import sys\n"
                    "ps = [getattr(sys, 'ps%s' % i, '') for i in range(1,4)]\n"
                    ;; JSON is built manually for compatibility
                    "ps_json = '\\n[\"%s\", \"%s\", \"%s\"]\\n' % tuple(ps)\n"
                    "print (ps_json)\n"
                    "sys.exit(0)\n"))
             ;; (interpreter mys-shell-name)
             ;; (interpreter-arg mys-mys-command-args)
             (output
              (with-temp-buffer
                ;; TODO: improve error handling by using
                ;; `condition-case' and displaying the error message to
                ;; the user in the no-prompts warning.
                (ignore-errors
                  (let ((code-file
                         ;; Python 2.x on Windows does not handle
                         ;; carriage returns in unbuffered mode.
                         (let ((inhibit-eol-conversion (getenv "PYTHONUNBUFFERED")))
                           (mys-shell--save-temp-file code))))
                    (unwind-protect
                        ;; Use `process-file' as it is remote-host friendly.
                        (process-file
                         mys-shell-name
                         code-file
                         '(t nil)
                         nil
                         mys-mys-command-args)
                      ;; Try to cleanup
                      (delete-file code-file))))
                (buffer-string)))
             (prompts
              (catch 'prompts
                (dolist (line (split-string output "\n" t))
                  (let ((res
                         ;; Check if current line is a valid JSON array
                         (and (string= (substring line 0 2) "[\"")
                              (ignore-errors
                                ;; Return prompts as a list, not vector
                                (append (json-read-from-string line) nil)))))
                    ;; The list must contain 3 strings, where the first
                    ;; is the input prompt, the second is the block
                    ;; prompt and the last one is the output prompt.  The
                    ;; input prompt is the only one that can't be empty.
                    (when (and (= (length res) 3)
                               (cl-every #'stringp res)
                               (not (string= (car res) "")))
                      (throw 'prompts res))))
                nil)))
        (if (not prompts)
            (lwarn
             '(python mys-shell-prompt-regexp)
             :warning
             (concat
              "Python shell prompts cannot be detected.\n"
              "If your emacs session hangs when starting python shells\n"
              "recover with `keyboard-quit' and then try fixing the\n"
              "interactive flag for your interpreter by adjusting the\n"
              "`mys-mys-command-args' or add regexps\n"
              "matching shell prompts in the directory-local friendly vars:\n"
              "  + `mys-shell-prompt-regexp'\n"
              "  + `mys-shell-input-prompt-2-regexp'\n"
              "  + `mys-shell-prompt-output-regexp'\n"
              "Or alternatively in:\n"
              "  + `mys-shell-input-prompt-regexps'\n"
              "  + `mys-shell-prompt-output-regexps'"))
          prompts)))))

(defun mys-util-valid-regexp-p (regexp)
  "Return non-nil if REGEXP is valid."
  (ignore-errors (string-match regexp "") t))

(defun mys-shell-prompt-validate-regexps ()
  "Validate all user provided regexps for prompts.
Signals `user-error' if any of these vars contain invalid
regexps: `mys-shell-prompt-regexp',
`mys-shell-input-prompt-2-regexp',
`mys-shell-prompt-pdb-regexp',
`mys-shell-prompt-output-regexp',
`mys-shell-input-prompt-regexps',
`mys-shell-prompt-output-regexps'."
  (dolist (symbol (list 'mys-shell-input-prompt-1-regexp
                        'mys-shell-prompt-output-regexps
                        'mys-shell-input-prompt-2-regexp
                        'mys-shell-prompt-pdb-regexp))
    (dolist (regexp (let ((regexps (symbol-value symbol)))
                      (if (listp regexps)
                          regexps
                        (list regexps))))
      (when (not (mys-util-valid-regexp-p regexp))
        (user-error "Invalid regexp %s in `%s'"
                    regexp symbol)))))

(defun mys-shell-prompt-set-calculated-regexps ()
  "Detect and set input and output prompt regexps.

Build and set the values for input- and output-prompt regexp
using the values from `mys-shell-prompt-regexp',
`mys-shell-input-prompt-2-regexp', `mys-shell-prompt-pdb-regexp',
`mys-shell-prompt-output-regexp', `mys-shell-input-prompt-regexps',
 and detected prompts from `mys-shell-prompt-detect'."
  (when (not (and mys-shell--prompt-calculated-input-regexp
                  mys-shell--prompt-calculated-output-regexp))
    (let* ((detected-prompts (mys-shell-prompt-detect))
           (input-prompts nil)
           (output-prompts nil)
           (build-regexp
            (lambda (prompts)
              (concat "^\\("
                      (mapconcat #'identity
                                 (sort prompts
                                       (lambda (a b)
                                         (let ((length-a (length a))
                                               (length-b (length b)))
                                           (if (= length-a length-b)
                                               (string< a b)
                                             (> (length a) (length b))))))
                                 "\\|")
                      "\\)"))))
      ;; Validate ALL regexps
      (mys-shell-prompt-validate-regexps)
      ;; Collect all user defined input prompts
      (dolist (prompt (append mys-shell-input-prompt-regexps
                              (list mys-shell-input-prompt-2-regexp
                                    mys-shell-prompt-pdb-regexp)))
        (cl-pushnew prompt input-prompts :test #'string=))
      ;; Collect all user defined output prompts
      (dolist (prompt (cons mys-shell-prompt-output-regexp
                            mys-shell-prompt-output-regexps))
        (cl-pushnew prompt output-prompts :test #'string=))
      ;; Collect detected prompts if any
      (when detected-prompts
        (dolist (prompt (butlast detected-prompts))
          (setq prompt (regexp-quote prompt))
          (cl-pushnew prompt input-prompts :test #'string=))
        (setq mys-shell--block-prompt (nth 1 detected-prompts))
        (cl-pushnew (regexp-quote
                     (car (last detected-prompts)))
                    output-prompts :test #'string=))
      ;; Set input and output prompt regexps from collected prompts
      (setq mys-shell--prompt-calculated-input-regexp
            (funcall build-regexp input-prompts)
            mys-shell--prompt-calculated-output-regexp
            (funcall build-regexp output-prompts)))))

(defun mys-shell-output-filter (strg)
  "Filter used in `mys-shell-send-string-no-output' to grab output.
STRING is the output received to this point from the process.
This filter saves received output from the process in
`mys-shell-output-filter-buffer' and stops receiving it after
detecting a prompt at the end of the buffer."
  (let ((mys-shell--prompt-calculated-output-regexp
	 (or mys-shell--prompt-calculated-output-regexp (mys-shell-prompt-set-calculated-regexps))))
    (setq
     strg (ansi-color-filter-apply strg)
     mys-shell-output-filter-buffer
     (concat mys-shell-output-filter-buffer strg))
    (when (mys-shell-comint-end-of-output-p
	   mys-shell-output-filter-buffer)
      ;; Output ends when `mys-shell-output-filter-buffer' contains
      ;; the prompt attached at the end of it.
      (setq mys-shell-output-filter-in-progress nil
	    mys-shell-output-filter-buffer
	    (substring mys-shell-output-filter-buffer
		       0 (match-beginning 0)))
      (when (string-match
	     mys-shell--prompt-calculated-output-regexp
	     mys-shell-output-filter-buffer)
	;; Some shells, like Imys might append a prompt before the
	;; output, clean that.
	(setq mys-shell-output-filter-buffer
	      (substring mys-shell-output-filter-buffer (match-end 0)))))
    ""))

(defun mys--fast-send-string-no-output-intern (strg proc limit output-buffer no-output)
  (let (erg)
    (with-current-buffer output-buffer
      ;; (when mys-debug-p (switch-to-buffer (current-buffer)))
      ;; (erase-buffer)
      (process-send-string proc strg)
      (or (string-match "\n$" strg)
	  (process-send-string proc "\n")
	  (goto-char (point-max))
	  )
      (cond (no-output
	     (delete-region (field-beginning) (field-end))
	     ;; (erase-buffer)
	     ;; (delete-region (point-min) (line-beginning-position))
	     )
	    (t
	     (if
		 (setq erg (mys--fetch-result output-buffer limit strg))
		 (setq mys-result (mys--filter-result erg))
	       (dotimes (_ 3) (unless (setq erg (mys--fetch-result output-buffer limit))(sit-for 1 t)))
	       (or (mys--fetch-result output-buffer limit))
	       (error "mys--fast-send-string-no-output-intern: mys--fetch-result: no result")))))))

(defun mys-execute-string (strg &optional process result no-output orig output-buffer fast argprompt args dedicated shell exception-buffer split switch internal)
   "Evaluate STRG in Python PROCESS.

With optional Arg PROCESS send to process.
With optional Arg RESULT store result in var `mys-result', also return it.
With optional Arg NO-OUTPUT don't display any output
With optional Arg ORIG deliver original position.
With optional Arg OUTPUT-BUFFER specify output-buffer"
  (interactive "sPython command: ")
  (save-excursion
    (let* ((buffer (or output-buffer (or (and process (buffer-name (process-buffer process))) (buffer-name (mys-shell argprompt args dedicated shell output-buffer fast exception-buffer split switch internal)))))
	   (proc (or process (get-buffer-process buffer)))
	   ;; nil nil nil nil (buffer-name buffer))))
	   (orig (or orig (point)))
   	   (limit (ignore-errors (marker-position (process-mark proc)))))
      (cond ((and no-output fast)
	     (mys--fast-send-string-no-output-intern strg proc limit buffer no-output))
	    (no-output
	     (mys-send-string-no-output strg proc))
	    ((and (string-match ".\n+." strg) (string-match "^[Ii]"
							    ;; (buffer-name buffer)
							    buffer
							    ))  ;; multiline
	     (let* ((temp-file-name (mys-temp-file-name strg))
		    (file-name (or (buffer-file-name) temp-file-name)))
	       (mys-execute-file file-name proc)))
	    (t (with-current-buffer buffer
		 (comint-send-string proc strg)
		 (when (or (not (string-match "\n\\'" strg))
			   (string-match "\n[ \t].*\n?\\'" strg))
		   (comint-send-string proc "\n"))
		 (sit-for mys-mys-send-delay)
		 (cond (result
			(setq mys-result
			      (mys--fetch-result buffer limit strg)))
		       (no-output
			(and orig (mys--cleanup-shell orig buffer))))))))))

(defun mys--execute-file-base (filename &optional proc cmd procbuf origline fast interactivep)
  "Send to Python interpreter process PROC.

In Python version 2.. \"execfile('FILENAME')\".

Takes also CMD PROCBUF ORIGLINE NO-OUTPUT.

Make that process's buffer visible and force display.  Also make
comint believe the user typed this string so that
`kill-output-from-shell' does The Right Thing.
Returns position where output starts."
  (let* ((filename (expand-file-name filename))
	 (buffer (or procbuf (and proc (process-buffer proc)) (mys-shell nil nil nil nil nil fast)))
	 (proc (or proc (get-buffer-process buffer)))
	 (limit (marker-position (process-mark proc)))
	 (cmd (or cmd (mys-execute-file-command filename)))
	 erg)
    (if fast
	(process-send-string proc cmd)
      (mys-execute-string cmd proc))
    ;; (message "%s" (current-buffer))
    (with-current-buffer buffer
      (when (or mys-return-result-p mys-store-result-p)
	(setq erg (mys--postprocess buffer origline limit cmd filename))
	(if mys-error
	    (setq mys-error (prin1-to-string mys-error))
	  erg)))
    (when (or interactivep
	      (or mys-switch-buffers-on-execute-p mys-split-window-on-execute))
      (mys--shell-manage-windows buffer (find-file-noselect filename) mys-split-window-on-execute mys-switch-buffers-on-execute-p))))

(defun mys-restore-window-configuration ()
  "Restore `mys-restore-window-configuration'."
  (let (val)
    (and (setq val (get-register mys--windows-config-register))(and (consp val) (window-configuration-p (car val))(markerp (cadr val)))(marker-buffer (cadr val))
	 (jump-to-register mys--windows-config-register))))

(defun mys-toggle-split-window-function ()
  "If window is splitted vertically or horizontally.

When code is executed and `mys-split-window-on-execute' is t,
the result is displays in an output-buffer, \"\*Python\*\" by default.

Customizable variable `mys-split-windows-on-execute-function'
tells how to split the screen."
  (interactive)
  (if (eq 'split-window-vertically mys-split-windows-on-execute-function)
      (setq mys-split-windows-on-execute-function'split-window-horizontally)
    (setq mys-split-windows-on-execute-function 'split-window-vertically))
  (when (and mys-verbose-p (called-interactively-p 'any))
    (message "mys-split-windows-on-execute-function set to: %s" mys-split-windows-on-execute-function)))

(defun mys--manage-windows-set-and-switch (buffer)
  "Switch to output BUFFER, go to `point-max'.

Internal use"
  (set-buffer buffer)
  (goto-char (process-mark (get-buffer-process (current-buffer)))))

(defun mys--alternative-split-windows-on-execute-function ()
  "Toggle split-window-horizontally resp. vertically."
  (if (eq mys-split-windows-on-execute-function 'split-window-vertically)
      'split-window-horizontally
    'split-window-vertically))

(defun mys--get-splittable-window ()
  "Search `window-list' for a window suitable for splitting."
  (or (and (window-left-child)(split-window (window-left-child)))
      (and (window-top-child)(split-window (window-top-child)))
      (and (window-parent)(ignore-errors (split-window (window-parent))))
      (and (window-atom-root)(split-window (window-atom-root)))))

(defun mys--manage-windows-split (buffer)
  "If one window, split BUFFER.

according to `mys-split-windows-on-execute-function'."
  (interactive)
  (set-buffer buffer)
  (or
   ;; (split-window (selected-window) nil ’below)
   (ignore-errors (funcall mys-split-windows-on-execute-function))
   ;; If call didn't succeed according to settings of
   ;; `split-height-threshold', `split-width-threshold'
   ;; resp. `window-min-height', `window-min-width'
   ;; try alternative split
   (unless (ignore-errors (funcall (mys--alternative-split-windows-on-execute-function)))
     ;; if alternative split fails, look for larger window
     (mys--get-splittable-window)
     (ignore-errors (funcall (mys--alternative-split-windows-on-execute-function))))))

;; (defun mys--display-windows (output-buffer)
;;     "Otherwise new window appears above"
;;       (display-buffer output-buffer)
;;       (select-window mys-exception-window))

(defun mys--split-t-not-switch-wm (output-buffer number-of-windows exception-buffer)
  (unless (window-live-p output-buffer)
    (with-current-buffer (get-buffer exception-buffer)

      (when (< number-of-windows mys-split-window-on-execute-threshold)
	(unless
	    (member (get-buffer-window output-buffer) (window-list))
	  (mys--manage-windows-split exception-buffer)))
      (display-buffer output-buffer t)
      (switch-to-buffer exception-buffer)
      )))

(defun mys--shell-manage-windows (output-buffer &optional exception-buffer split switch)
  "Adapt or restore window configuration from OUTPUT-BUFFER.

Optional EXCEPTION-BUFFER SPLIT SWITCH
Return nil."
  (let* ((exception-buffer (or exception-buffer (other-buffer)))
	 (old-window-list (window-list))
	 (number-of-windows (length old-window-list))
	 (split (or split mys-split-window-on-execute))
	 (switch
	  (or mys-switch-buffers-on-execute-p switch mys-pdbtrack-tracked-buffer)))
    ;; (output-buffer-displayed-p)
    (cond
     (mys-keep-windows-configuration
      (mys-restore-window-configuration)
      (set-buffer output-buffer)
      (goto-char (point-max)))
     ((and (eq split 'always)
	   switch)
      (if (member (get-buffer-window output-buffer) (window-list))
	  ;; (delete-window (get-buffer-window output-buffer))
	  (select-window (get-buffer-window output-buffer))
	(mys--manage-windows-split exception-buffer)
	;; otherwise new window appears above
	(save-excursion
	  (other-window 1)
	  (switch-to-buffer output-buffer))
	(display-buffer exception-buffer)))
     ((and
       (eq split 'always)
       (not switch))
      (if (member (get-buffer-window output-buffer) (window-list))
	  (select-window (get-buffer-window output-buffer))
	(mys--manage-windows-split exception-buffer)
	(display-buffer output-buffer)
	(pop-to-buffer exception-buffer)))
     ((and
       (eq split 'just-two)
       switch)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (mys--manage-windows-split exception-buffer)
      ;; otherwise new window appears above
      (other-window 1)
      (set-buffer output-buffer)
      (switch-to-buffer (current-buffer)))
     ((and
       (eq split 'just-two)
       (not switch))
      (switch-to-buffer exception-buffer)
      (delete-other-windows)
      (unless
	  (member (get-buffer-window output-buffer) (window-list))
	(mys--manage-windows-split exception-buffer))
      ;; Fixme: otherwise new window appears above
      (save-excursion
	(other-window 1)
	(pop-to-buffer output-buffer)
	(goto-char (point-max))
	(other-window 1)))
     ((and
       split
       (not switch))
      ;; https://bugs.launchpad.net/mys-mode/+bug/1478122
      ;; > If the shell is visible in any of the windows it should re-use that window
      ;; > I did double check and mys-keep-window-configuration is nil and split is t.
      (mys--split-t-not-switch-wm output-buffer number-of-windows exception-buffer))
     ((and split switch)
      (unless
	  (member (get-buffer-window output-buffer) (window-list))
	(mys--manage-windows-split exception-buffer))
      ;; Fixme: otherwise new window appears above
      ;; (save-excursion
      ;; (other-window 1)
      ;; (pop-to-buffer output-buffer)
      ;; [Bug 1579309] python buffer window on top when using python3
      (set-buffer output-buffer)
      (switch-to-buffer output-buffer)
      (goto-char (point-max))
      ;; (other-window 1)
      )
     ((not switch)
      (let (pop-up-windows)
	(mys-restore-window-configuration))))))

(defun mys-execute-file (filename &optional proc)
  "When called interactively, user is prompted for FILENAME."
  (interactive "fFilename: ")
  (let (;; postprocess-output-buffer might want origline
        (origline 1)
        (mys-exception-buffer filename)
        erg)
    (if (file-readable-p filename)
        (if mys-store-result-p
            (setq erg (mys--execute-file-base (expand-file-name filename) nil nil nil origline))
          (mys--execute-file-base (expand-file-name filename) proc))
      (message "%s not readable. %s" filename "Do you have write permissions?"))
    (mys--shell-manage-windows mys-output-buffer mys-exception-buffer nil
                              (or (called-interactively-p 'interactive)))
    erg))

(defun mys-send-string-no-output (strg &optional process buffer-name)
  "Send STRING to PROCESS and inhibit output.

Return the output."
  (let* ((proc (or process (mys--get-process)))
	 (buffer (or buffer-name (if proc (buffer-name (process-buffer proc)) (mys-shell))))
         (comint-preoutput-filter-functions
          '(mys-shell-output-filter))
         (mys-shell-output-filter-in-progress t)
         (inhibit-quit t)
	 (delay (mys--which-delay-process-dependent buffer))
	 temp-file-name)
    (or
     (with-local-quit
       (if (and (string-match ".\n+." strg) (string-match "^\*[Ii]" buffer))  ;; Imys or multiline
           (let ((file-name (or (buffer-file-name) (setq temp-file-name (mys-temp-file-name strg)))))
	     (mys-execute-file file-name proc)
	     (when temp-file-name (delete-file temp-file-name)))
	 (mys-shell-send-string strg proc))
       ;; (switch-to-buffer buffer)
       ;; (accept-process-output proc 9)
       (while mys-shell-output-filter-in-progress
         ;; `mys-shell-output-filter' takes care of setting
         ;; `mys-shell-output-filter-in-progress' to NIL after it
         ;; detects end of output.
         (accept-process-output proc delay))
       (prog1
           mys-shell-output-filter-buffer
         (setq mys-shell-output-filter-buffer nil)))
     (with-current-buffer (process-buffer proc)
       (comint-interrupt-subjob)))))

(defun mys--leave-backward-string-list-and-comment-maybe (pps)
  (while (or (and (nth 8 pps) (goto-char (nth 8 pps)))
             (and (nth 1 pps) (goto-char (nth 1 pps)))
             (and (nth 4 pps) (goto-char (nth 4 pps))))
    ;; (back-to-indentation)
    (when (or (looking-at comment-start)(member (char-after) (list ?\" ?')))
      (skip-chars-backward " \t\r\n\f"))
    (setq pps (parse-partial-sexp (point-min) (point)))))

(defun mys-set-imys-completion-command-string (shell)
  "Set and return `mys-imys-completion-command-string' according to SHELL."
  (interactive)
  (let* ((imys-version (mys-imys--which-version shell)))
    (if (string-match "[0-9]" imys-version)
        (setq mys-imys-completion-command-string
              (cond ((string-match "^[^0].+" imys-version)
		     mys-imys0.11-completion-command-string)
                    ((string-match "^0.1[1-3]" imys-version)
                     mys-imys0.11-completion-command-string)
                    ((string= "^0.10" imys-version)
                     mys-imys0.10-completion-command-string)))
      (error imys-version))))

(defun mys-imys--module-completion-import (proc)
  "Import module-completion according to PROC."
  (interactive)
  (let ((imys-version (shell-command-to-string (concat mys-shell-name " -V"))))
    (when (and (string-match "^[0-9]" imys-version)
               (string-match "^[^0].+" imys-version))
      (process-send-string proc "from Imys.core.completerlib import module_completion"))))

(defun mys--compose-buffer-name-initials (liste)
  (let (erg)
    (dolist (ele liste)
      (unless (string= "" ele)
	(setq erg (concat erg (char-to-string (aref ele 0))))))
    erg))

(defun mys--remove-home-directory-from-list (liste)
  "Prepare for compose-buffer-name-initials according to LISTE."
  (let ((case-fold-search t)
	(liste liste)
	erg)
    (if (listp (setq erg (split-string (expand-file-name "~") "\/")))
	erg
      (setq erg (split-string (expand-file-name "~") "\\\\")))
     (while erg
      (when (member (car erg) liste)
	(setq liste (cdr (member (car erg) liste))))
      (setq erg (cdr erg)))
    (butlast liste)))

(defun mys--prepare-shell-name (erg)
  "Provide a readable shell name by capitalizing etc."
  (cond ((string-match "^imys" erg)
	 (replace-regexp-in-string "imys" "Imys" erg))
	((string-match "^jython" erg)
	 (replace-regexp-in-string "jython" "Jython" erg))
	((string-match "^python" erg)
	 (replace-regexp-in-string "python" "Python" erg))
	((string-match "^python2" erg)
	 (replace-regexp-in-string "python2" "Python2" erg))
	((string-match "^python3" erg)
	 (replace-regexp-in-string "python3" "Python3" erg))
	((string-match "^pypy" erg)
	 (replace-regexp-in-string "pypy" "PyPy" erg))
	(t erg)))

(defun mys--choose-buffer-name (&optional name dedicated fast-process)
  "Return an appropriate NAME to display in modeline.

Optional DEDICATED FAST-PROCESS
SEPCHAR is the file-path separator of your system."
  (let* ((name-first (or name mys-shell-name))
	 (erg (when name-first (if (stringp name-first) name-first (prin1-to-string name-first))))
	 (fast-process (or fast-process mys-fast-process-p))
	 prefix)
    (when (string-match "^mys-" erg)
      (setq erg (nth 1 (split-string erg "-"))))
    ;; remove home-directory from prefix to display
    (unless mys-modeline-acronym-display-home-p
      (save-match-data
	(let ((case-fold-search t))
	  (when (string-match (concat ".*" (expand-file-name "~")) erg)
	    (setq erg (replace-regexp-in-string (concat "^" (expand-file-name "~")) "" erg))))))
    (if (or (and (setq prefix (split-string erg "\\\\"))
		 (< 1 (length prefix)))
	    (and (setq prefix (split-string erg "\/"))
		 (< 1 (length prefix))))
	(progn
	  ;; exect something like default mys-shell-name
	  (setq erg (car (last prefix)))
	  (unless mys-modeline-acronym-display-home-p
	    ;; home-directory may still inside
	    (setq prefix (mys--remove-home-directory-from-list prefix))
	    (setq prefix (mys--compose-buffer-name-initials prefix))))
      (setq erg (or erg mys-shell-name))
      (setq prefix nil))
    (when fast-process (setq erg (concat erg " Fast")))
    (setq erg
          (mys--prepare-shell-name erg))
    (when (or dedicated mys-dedicated-process-p)
      (setq erg (make-temp-name (concat erg "-"))))
    (cond ((and prefix (string-match "^\*" erg))
           (setq erg (replace-regexp-in-string "^\*" (concat "*" prefix " ") erg)))
          (prefix
           (setq erg (concat "*" prefix " " erg "*")))
          (t (unless (string-match "^\*" erg) (setq erg (concat "*" erg "*")))))
    erg))

(defun mys-shell (&optional argprompt args dedicated shell buffer fast exception-buffer split switch internal)
  "Connect process to BUFFER.

Start an interpreter according to `mys-shell-name' or SHELL.

Optional ARGPROMPT: with \\[universal-argument] start in a new
dedicated shell.

Optional ARGS: Specify other than default command args.

Optional DEDICATED: start in a new dedicated shell.
Optional string SHELL overrides default `mys-shell-name'.
Optional string BUFFER allows a name, the Python process is connected to
Optional FAST: no fontification in process-buffer.
Optional EXCEPTION-BUFFER: point to error.
Optional SPLIT: see var `mys-split-window-on-execute'
Optional SWITCH: see var `mys-switch-buffers-on-execute-p'
Optional INTERNAL shell will be invisible for users

Reusing existing processes: For a given buffer and same values,
if a process is already running for it, it will do nothing.

Runs the hook `mys-shell-mode-hook' after
`comint-mode-hook' is run.  (Type \\[describe-mode] in the
process buffer for a list of commands.)"
  (interactive "p")
  (let* ((interactivep (and argprompt (eq 1 (prefix-numeric-value argprompt))))
	 (fast (unless (eq major-mode 'org-mode)
		 (or fast mys-fast-process-p)))
	 (dedicated (or (eq 4 (prefix-numeric-value argprompt)) dedicated mys-dedicated-process-p))
	 (shell (if shell
		    (if (executable-find shell)
			shell
		      (error (concat "mys-shell: Can't see an executable for `"shell "' on your system. Maybe needs a link?")))
		  (mys-choose-shell)))
	 (args (or args (mys--provide-command-args shell fast)))
         ;; Make sure a new one is created if required
	 (buffer-name
	  (or buffer
              (and mys-mode-v5-behavior-p (get-buffer-create "*Python Output*"))
	      (mys--choose-buffer-name shell dedicated fast)))
	 (proc (get-buffer-process buffer-name))
	 (done nil)
	 (delay nil)
	 (buffer
	  (or
	   (and (ignore-errors (process-buffer proc))
		(save-excursion (with-current-buffer (process-buffer proc)
				  ;; point might not be left there
				  (goto-char (point-max))
				  (push-mark)
				  (setq done t)
				  (process-buffer proc))))
	   (save-excursion
	     (mys-shell-with-environment
	       (if fast
		   (process-buffer (apply 'start-process shell buffer-name shell args))
		 (apply #'make-comint-in-buffer shell buffer-name
			shell nil args))))))
	 ;; (mys-shell-prompt-detect-p (or (string-match "^\*IP" buffer) mys-shell-prompt-detect-p))
         )
    (setq mys-output-buffer (buffer-name (if mys-mode-v5-behavior-p (get-buffer  "*Python Output*") buffer)))
    (unless done
      (with-current-buffer buffer
	(setq delay (mys--which-delay-process-dependent buffer-name))
	(unless fast
	  (when interactivep
	    (cond ((string-match "^.I" buffer-name)
		   (message "Waiting according to `mys-imys-send-delay:' %s" delay))
		  ((string-match "^.+3" buffer-name)
		   (message "Waiting according to `mys-python3-send-delay:' %s" delay))))
	  (setq mys-modeline-display (mys--update-lighter buffer-name))
	  ;; (sit-for delay t)
          )))
    (if (setq proc (get-buffer-process buffer))
	(progn
	  (with-current-buffer buffer
	    (unless (or done fast) (mys-shell-mode))
	    (and internal (set-process-query-on-exit-flag proc nil)))
	  (when (or interactivep
		    (or switch mys-switch-buffers-on-execute-p mys-split-window-on-execute))
	    (mys--shell-manage-windows buffer exception-buffer split (or interactivep switch)))
	  buffer)
      (error (concat "mys-shell:" (mys--fetch-error mys-output-buffer))))))

;; mys-components-rx

;; The `rx--translate...' functions below return (REGEXP . PRECEDENCE),
;; where REGEXP is a list of string expressions that will be
;; concatenated into a regexp, and PRECEDENCE is one of
;;
;;  t    -- can be used as argument to postfix operators (eg. "a")
;;  seq  -- can be concatenated in sequence with other seq or higher (eg. "ab")
;;  lseq -- can be concatenated to the left of rseq or higher (eg. "^a")
;;  rseq -- can be concatenated to the right of lseq or higher (eg. "a$")
;;  nil  -- can only be used in alternatives (eg. "a\\|b")
;;
;; They form a lattice:
;;
;;           t          highest precedence
;;           |
;;          seq
;;         /   \
;;      lseq   rseq
;;         \   /
;;          nil         lowest precedence


(defconst rx--char-classes
  '((digit         . digit)
    (numeric       . digit)
    (num           . digit)
    (control       . cntrl)
    (cntrl         . cntrl)
    (hex-digit     . xdigit)
    (hex           . xdigit)
    (xdigit        . xdigit)
    (blank         . blank)
    (graphic       . graph)
    (graph         . graph)
    (printing      . print)
    (print         . print)
    (alphanumeric  . alnum)
    (alnum         . alnum)
    (letter        . alpha)
    (alphabetic    . alpha)
    (alpha         . alpha)
    (ascii         . ascii)
    (nonascii      . nonascii)
    (lower         . lower)
    (lower-case    . lower)
    (punctuation   . punct)
    (punct         . punct)
    (space         . space)
    (whitespace    . space)
    (white         . space)
    (upper         . upper)
    (upper-case    . upper)
    (word          . word)
    (wordchar      . word)
    (unibyte       . unibyte)
    (multibyte     . multibyte))
  "Alist mapping rx symbols to character classes.
Most of the names are from SRE.")

(defvar rx-constituents nil
  "Alist of old-style rx extensions, for compatibility.
For new code, use `rx-define', `rx-let' or `rx-let-eval'.

Each element is (SYMBOL . DEF).

If DEF is a symbol, then SYMBOL is an alias of DEF.

If DEF is a string, then SYMBOL is a plain rx symbol defined as the
   regexp string DEF.

If DEF is a list on the form (FUN MIN-ARGS MAX-ARGS PRED), then
   SYMBOL is an rx form with at least MIN-ARGS and at most
   MAX-ARGS arguments.  If MAX-ARGS is nil, then there is no upper limit.
   FUN is a function taking the entire rx form as single argument
   and returning the translated regexp string.
   If PRED is non-nil, it is a predicate that all actual arguments must
   satisfy.")

(defvar rx--local-definitions nil
  "Alist of dynamic local rx definitions.
Each entry is:
 (NAME DEF)      -- NAME is an rx symbol defined as the rx form DEF.
 (NAME ARGS DEF) -- NAME is an rx form with arglist ARGS, defined
                    as the rx form DEF (which can contain members of ARGS).")

(defsubst rx--lookup-def (name)
  "Current definition of NAME: (DEF) or (ARGS DEF), or nil if none."
  (or (cdr (assq name rx--local-definitions))
      (get name 'rx-definition)))

(defun rx--expand-def (form)
  "FORM expanded (once) if a user-defined construct; otherwise nil."
  (cond ((symbolp form)
         (let ((def (rx--lookup-def form)))
           (and def
                (if (cdr def)
                    (error "Not an `rx' symbol definition: %s" form)
                  (car def)))))
        ((and (consp form) (symbolp (car form)))
         (let* ((op (car form))
                (def (rx--lookup-def op)))
           (and def
                (if (cdr def)
                    (rx--expand-template
                     op (cdr form) (nth 0 def) (nth 1 def))
                  (error "Not an `rx' form definition: %s" op)))))))

;; TODO: Additions to consider:
;; - A construct like `or' but without the match order guarantee,
;;   maybe `unordered-or'.  Useful for composition or generation of
;;   alternatives; permits more effective use of regexp-opt.

(defun rx--translate-symbol (sym)
  "Translate an rx symbol.  Return (REGEXP . PRECEDENCE)."
  (pcase sym
    ;; Use `list' instead of a quoted list to wrap the strings here,
    ;; since the return value may be mutated.
    ((or 'nonl 'not-newline 'any) (cons (list ".") t))
    ((or 'anychar 'anything)      (cons (list "[^z-a]") t))
    ('unmatchable                 (rx--empty))
    ((or 'bol 'line-start)        (cons (list "^") 'lseq))
    ((or 'eol 'line-end)          (cons (list "$") 'rseq))
    ((or 'bos 'string-start 'bot 'buffer-start) (cons (list "\\`") t))
    ((or 'eos 'string-end   'eot 'buffer-end)   (cons (list "\\'") t))
    ('point                       (cons (list "\\=") t))
    ((or 'bow 'word-start)        (cons (list "\\<") t))
    ((or 'eow 'word-end)          (cons (list "\\>") t))
    ('word-boundary               (cons (list "\\b") t))
    ('not-word-boundary           (cons (list "\\B") t))
    ('symbol-start                (cons (list "\\_<") t))
    ('symbol-end                  (cons (list "\\_>") t))
    ('not-wordchar                (cons (list "\\W") t))
    (_
     (cond
      ((let ((class (cdr (assq sym rx--char-classes))))
         (and class (cons (list (concat "[[:" (symbol-name class) ":]]")) t))))

      ((let ((expanded (rx--expand-def sym)))
         (and expanded (rx--translate expanded))))

      ;; For compatibility with old rx.
      ((let ((entry (assq sym rx-constituents)))
         (and (progn
                (while (and entry (not (stringp (cdr entry))))
                  (setq entry
                        (if (symbolp (cdr entry))
                            ;; Alias for another entry.
                            (assq (cdr entry) rx-constituents)
                          ;; Wrong type, try further down the list.
                          (assq (car entry)
                                (cdr (memq entry rx-constituents))))))
                entry)
              (cons (list (cdr entry)) nil))))
      (t (error "Unknown rx symbol `%s'" sym))))))

(defun rx--enclose (left-str rexp right-str)
  "Bracket REXP by LEFT-STR and RIGHT-STR."
  (append (list left-str) rexp (list right-str)))

(defun rx--bracket (rexp)
  (rx--enclose "\\(?:" rexp "\\)"))

(defun rx--sequence (left right)
  "Return the sequence (concatenation) of two translated items,
each on the form (REGEXP . PRECEDENCE), returning (REGEXP . PRECEDENCE)."
  ;; Concatenation rules:
  ;;  seq  ++ seq  -> seq
  ;;  lseq ++ seq  -> lseq
  ;;  seq  ++ rseq -> rseq
  ;;  lseq ++ rseq -> nil
  (cond ((not (car left)) right)
        ((not (car right)) left)
        (t
         (let ((l (if (memq (cdr left) '(nil rseq))
                      (cons (rx--bracket (car left)) t)
                    left))
               (r (if (memq (cdr right) '(nil lseq))
                      (cons (rx--bracket (car right)) t)
                    right)))
           (cons (append (car l) (car r))
                 (if (eq (cdr l) 'lseq)
                     (if (eq (cdr r) 'rseq)
                         nil                   ; lseq ++ rseq
                       'lseq)                  ; lseq ++ seq
                   (if (eq (cdr r) 'rseq)
                       'rseq                   ; seq ++ rseq
                     'seq)))))))               ; seq ++ seq

(defun rx--translate-seq (body)
  "Translate a sequence of zero or more rx items.
Return (REGEXP . PRECEDENCE)."
  (if body
      (let* ((items (mapcar #'rx--translate body))
             (result (car items)))
        (dolist (item (cdr items))
          (setq result (rx--sequence result item)))
        result)
    (cons nil 'seq)))

(defun rx--empty ()
  "Regexp that never matches anything."
  (cons (list regexp-unmatchable) 'seq))

;; `cl-every' replacement to avoid bootstrapping problems.
(defun rx--every (pred list)
  "Whether PRED is true for every element of LIST."
  (while (and list (funcall pred (car list)))
    (setq list (cdr list)))
  (null list))

(defun rx--foldl (f x l)
  "(F (F (F X L0) L1) L2) ...
Left-fold the list L, starting with X, by the binary function F."
  (while l
    (setq x (funcall f x (car l)))
    (setq l (cdr l)))
  x)

(defun rx--normalise-or-arg (form)
  "Normalize the `or' argument FORM.
Characters become strings, user-definitions and `eval' forms are expanded,
and `or' forms are normalized recursively."
  (cond ((characterp form)
         (char-to-string form))
        ((and (consp form) (memq (car form) '(or |)))
         (cons (car form) (mapcar #'rx--normalise-or-arg (cdr form))))
        ((and (consp form) (eq (car form) 'eval))
         (rx--normalise-or-arg (rx--expand-eval (cdr form))))
        (t
         (let ((expanded (rx--expand-def form)))
           (if expanded
               (rx--normalise-or-arg expanded)
             form)))))

(defun rx--all-string-or-args (body)
  "If BODY only consists of strings or such `or' forms, return all the strings.
Otherwise throw `rx--nonstring'."
  (mapcan (lambda (form)
            (cond ((stringp form) (list form))
                  ((and (consp form) (memq (car form) '(or |)))
                   (rx--all-string-or-args (cdr form)))
                  (t (throw 'rx--nonstring nil))))
          body))

(defun rx--translate-or (body)
  "Translate an or-pattern of zero or more rx items.
Return (REGEXP . PRECEDENCE)."
  ;; FIXME: Possible improvements:
  ;;
  ;; - Flatten sub-patterns first: (or (or A B) (or C D)) -> (or A B C D)
  ;;   Then call regexp-opt on runs of string arguments. Example:
  ;;   (or (+ digit) "CHARLIE" "CHAN" (+ blank))
  ;;   -> (or (+ digit) (or "CHARLIE" "CHAN") (+ blank))
  ;;
  ;; - Optimize single-character alternatives better:
  ;;     * classes: space, alpha, ...
  ;;     * (syntax S), for some S (whitespace, word)
  ;;   so that (or "@" "%" digit (any "A-Z" space) (syntax word))
  ;;        -> (any "@" "%" digit "A-Z" space word)
  ;;        -> "[A-Z@%[:digit:][:space:][:word:]]"
  (cond
   ((null body)                    ; No items: a never-matching regexp.
    (rx--empty))
   ((null (cdr body))              ; Single item.
    (rx--translate (car body)))
   (t
    (let* ((args (mapcar #'rx--normalise-or-arg body))
           (all-strings (catch 'rx--nonstring (rx--all-string-or-args args))))
      (cond
       (all-strings                       ; Only strings.
        (cons (list (regexp-opt all-strings nil))
              t))
       ((rx--every #'rx--charset-p args)  ; All charsets.
        (rx--translate-union nil args))
       (t
        (cons (append (car (rx--translate (car args)))
                      (mapcan (lambda (item)
                                (cons "\\|" (car (rx--translate item))))
                              (cdr args)))
              nil)))))))

(defun rx--charset-p (form)
  "Whether FORM looks like a charset, only consisting of character intervals
and set operations."
  (or (and (consp form)
           (or (and (memq (car form) '(any in char))
                    (rx--every (lambda (x) (not (symbolp x))) (cdr form)))
               (and (memq (car form) '(not or | intersection))
                    (rx--every #'rx--charset-p (cdr form)))))
      (characterp form)
      (and (stringp form) (= (length form) 1))
      (and (or (symbolp form) (consp form))
           (let ((expanded (rx--expand-def form)))
             (and expanded
                  (rx--charset-p expanded))))))

(defun rx--string-to-intervals (str)
  "Decode STR as intervals: A-Z becomes (?A . ?Z), and the single
character X becomes (?X . ?X).  Return the intervals in a list."
  ;; We could just do string-to-multibyte on the string and work with
  ;; that instead of this `decode-char' workaround.
  (let ((decode-char
         (if (multibyte-string-p str)
             #'identity
           #'unibyte-char-to-multibyte))
        (len (length str))
        (i 0)
        (intervals nil))
    (while (< i len)
      (cond ((and (< i (- len 2))
                  (= (aref str (1+ i)) ?-))
             ;; Range.
             (let ((start (funcall decode-char (aref str i)))
                   (end   (funcall decode-char (aref str (+ i 2)))))
               (cond ((and (<= start #x7f) (>= end #x3fff80))
                      ;; Ranges between ASCII and raw bytes are split to
                      ;; avoid having them absorb Unicode characters
                      ;; caught in-between.
                      (push (cons start #x7f) intervals)
                      (push (cons #x3fff80 end) intervals))
                     ((<= start end)
                      (push (cons start end) intervals))
                     (t
                      (error "Invalid rx `any' range: %s"
                             (substring str i (+ i 3)))))
               (setq i (+ i 3))))
            (t
             ;; Single character.
             (let ((char (funcall decode-char (aref str i))))
               (push (cons char char) intervals))
             (setq i (+ i 1)))))
    intervals))

(defun rx--condense-intervals (intervals)
  "Merge adjacent and overlapping intervals by mutation, preserving the order.
INTERVALS is a list of (START . END) with START ≤ END, sorted by START."
  (let ((tail intervals)
        d)
    (while (setq d (cdr tail))
      (if (>= (cdar tail) (1- (caar d)))
          (progn
            (setcdr (car tail) (max (cdar tail) (cdar d)))
            (setcdr tail (cdr d)))
        (setq tail d)))
    intervals))

(defun rx--parse-any (body)
  "Parse arguments of an (any ...) construct.
Return (INTERVALS . CLASSES), where INTERVALS is a sorted list of
disjoint intervals (each a cons of chars), and CLASSES
a list of named character classes in the order they occur in BODY."
  (let ((classes nil)
        (strings nil)
        (conses nil))
    ;; Collect strings, conses and characters, and classes in separate bins.
    (dolist (arg body)
      (cond ((stringp arg)
             (push arg strings))
            ((and (consp arg)
                  (characterp (car arg))
                  (characterp (cdr arg))
                  (<= (car arg) (cdr arg)))
             ;; Copy the cons, in case we need to modify it.
             (push (cons (car arg) (cdr arg)) conses))
            ((characterp arg)
             (push (cons arg arg) conses))
            ((and (symbolp arg)
                  (let ((class (cdr (assq arg rx--char-classes))))
                    (and class
                         (or (memq class classes)
                             (progn (push class classes) t))))))
            (t (error "Invalid rx `any' argument: %s" arg))))
    (cons (rx--condense-intervals
           (sort (append conses
                         (mapcan #'rx--string-to-intervals strings))
                 #'car-less-than-car))
          (reverse classes))))

(defun rx--generate-alt (negated intervals classes)
  "Generate a character alternative.  Return (REGEXP . PRECEDENCE).
If NEGATED is non-nil, negate the result; INTERVALS is a sorted
list of disjoint intervals and CLASSES a list of named character
classes."
  (let ((items (append intervals classes)))
    ;; Move lone ] and range ]-x to the start.
    (let ((rbrac-l (assq ?\] items)))
      (when rbrac-l
        (setq items (cons rbrac-l (delq rbrac-l items)))))

    ;; Split x-] and move the lone ] to the start.
    (let ((rbrac-r (rassq ?\] items)))
      (when (and rbrac-r (not (eq (car rbrac-r) ?\])))
        (setcdr rbrac-r ?\\)
        (setq items (cons '(?\] . ?\]) items))))

    ;; Split ,-- (which would end up as ,- otherwise).
    (let ((dash-r (rassq ?- items)))
      (when (eq (car dash-r) ?,)
        (setcdr dash-r ?,)
        (setq items (nconc items '((?- . ?-))))))

    ;; Remove - (lone or at start of interval)
    (let ((dash-l (assq ?- items)))
      (when dash-l
        (if (eq (cdr dash-l) ?-)
            (setq items (delq dash-l items))   ; Remove lone -
          (setcar dash-l ?.))                  ; Reduce --x to .-x
        (setq items (nconc items '((?- . ?-))))))

    ;; Deal with leading ^ and range ^-x.
    (when (and (consp (car items))
               (eq (caar items) ?^)
               (cdr items))
      ;; Move ^ and ^-x to second place.
      (setq items (cons (cadr items)
                        (cons (car items) (cddr items)))))

    (cond
     ;; Empty set: if negated, any char, otherwise match-nothing.
     ((null items)
      (if negated
          (rx--translate-symbol 'anything)
        (rx--empty)))
     ;; Single non-negated character.
     ((and (null (cdr items))
           (consp (car items))
           (eq (caar items) (cdar items))
           (not negated))
      (cons (list (regexp-quote (char-to-string (caar items))))
            t))
     ;; Negated newline.
     ((and (equal items '((?\n . ?\n)))
           negated)
      (rx--translate-symbol 'nonl))
     ;; At least one character or class, possibly negated.
     (t
      (cons
       (list
        (concat
         "["
         (and negated "^")
         (mapconcat (lambda (item)
                      (cond ((symbolp item)
                             (format "[:%s:]" item))
                            ((eq (car item) (cdr item))
                             (char-to-string (car item)))
                            ((eq (1+ (car item)) (cdr item))
                             (string (car item) (cdr item)))
                            (t
                             (string (car item) ?- (cdr item)))))
                    items nil)
         "]"))
       t)))))

(defun rx--translate-any (negated body)
  "Translate an (any ...) construct.  Return (REGEXP . PRECEDENCE).
If NEGATED, negate the sense."
  (let ((parsed (rx--parse-any body)))
    (rx--generate-alt negated (car parsed) (cdr parsed))))

(defun rx--intervals-to-alt (negated intervals)
  "Generate a character alternative from an interval set.
Return (REGEXP . PRECEDENCE).
INTERVALS is a sorted list of disjoint intervals.
If NEGATED, negate the sense."
  ;; Detect whether the interval set is better described in
  ;; complemented form.  This is not just a matter of aesthetics: any
  ;; range from ASCII to raw bytes will automatically exclude the
  ;; entire non-ASCII Unicode range by the regexp engine.
  (if (rx--every (lambda (iv) (not (<= (car iv) #x3ffeff (cdr iv))))
                 intervals)
      (rx--generate-alt negated intervals nil)
    (rx--generate-alt
     (not negated) (rx--complement-intervals intervals) nil)))

;; FIXME: Consider turning `not' into a variadic operator, following SRE:
;; (not A B) = (not (or A B)) = (intersection (not A) (not B)), and
;; (not) = anychar.
;; Maybe allow singleton characters as arguments.

(defun rx--translate-not (negated body)
  "Translate a (not ...) construct.  Return (REGEXP . PRECEDENCE).
If NEGATED, negate the sense (thus making it positive)."
  (unless (and body (null (cdr body)))
    (error "rx `not' form takes exactly one argument"))
  (let ((arg (car body)))
    (cond
     ((and (consp arg)
           (pcase (car arg)
             ((or 'any 'in 'char)
              (rx--translate-any      (not negated) (cdr arg)))
             ('syntax
              (rx--translate-syntax   (not negated) (cdr arg)))
             ('category
              (rx--translate-category (not negated) (cdr arg)))
             ('not
              (rx--translate-not      (not negated) (cdr arg)))
             ((or 'or '|)
              (rx--translate-union    (not negated) (cdr arg)))
             ('intersection
              (rx--translate-intersection (not negated) (cdr arg))))))
     ((let ((class (cdr (assq arg rx--char-classes))))
        (and class
             (rx--generate-alt (not negated) nil (list class)))))
     ((eq arg 'word-boundary)
      (rx--translate-symbol
       (if negated 'word-boundary 'not-word-boundary)))
     ((characterp arg)
      (rx--generate-alt (not negated) (list (cons arg arg)) nil))
     ((and (stringp arg) (= (length arg) 1))
      (let ((char (string-to-char arg)))
        (rx--generate-alt (not negated) (list (cons char char)) nil)))
     ((let ((expanded (rx--expand-def arg)))
        (and expanded
             (rx--translate-not negated (list expanded)))))
     (t (error "Illegal argument to rx `not': %S" arg)))))

(defun rx--complement-intervals (intervals)
  "Complement of the interval list INTERVALS."
  (let ((compl nil)
        (c 0))
    (dolist (iv intervals)
      (when (< c (car iv))
        (push (cons c (1- (car iv))) compl))
      (setq c (1+ (cdr iv))))
    (when (< c (max-char))
      (push (cons c (max-char)) compl))
    (nreverse compl)))

(defun rx--intersect-intervals (ivs-a ivs-b)
  "Intersection of the interval lists IVS-A and IVS-B."
  (let ((isect nil))
    (while (and ivs-a ivs-b)
      (let ((a (car ivs-a))
            (b (car ivs-b)))
        (cond
         ((< (cdr a) (car b)) (setq ivs-a (cdr ivs-a)))
         ((> (car a) (cdr b)) (setq ivs-b (cdr ivs-b)))
         (t
          (push (cons (max (car a) (car b))
                      (min (cdr a) (cdr b)))
                isect)
          (setq ivs-a (cdr ivs-a))
          (setq ivs-b (cdr ivs-b))
          (cond ((< (cdr a) (cdr b))
                 (push (cons (1+ (cdr a)) (cdr b))
                       ivs-b))
                ((> (cdr a) (cdr b))
                 (push (cons (1+ (cdr b)) (cdr a))
                       ivs-a)))))))
    (nreverse isect)))

(defun rx--union-intervals (ivs-a ivs-b)
  "Union of the interval lists IVS-A and IVS-B."
  (rx--complement-intervals
   (rx--intersect-intervals
    (rx--complement-intervals ivs-a)
    (rx--complement-intervals ivs-b))))

(defun rx--charset-intervals (charset)
  "Return a sorted list of non-adjacent disjoint intervals from CHARSET.
CHARSET is any expression allowed in a character set expression:
characters, single-char strings, `any' forms (no classes permitted),
or `not', `or' or `intersection' forms whose arguments are charsets."
  (pcase charset
    (`(,(or 'any 'in 'char) . ,body)
     (let ((parsed (rx--parse-any body)))
       (when (cdr parsed)
         (error
          "Character class not permitted in set operations: %S"
          (cadr parsed)))
       (car parsed)))
    (`(not ,x) (rx--complement-intervals (rx--charset-intervals x)))
    (`(,(or 'or '|) . ,body) (rx--charset-union body))
    (`(intersection . ,body) (rx--charset-intersection body))
    ((pred characterp)
     (list (cons charset charset)))
    ((guard (and (stringp charset) (= (length charset) 1)))
     (let ((char (string-to-char charset)))
       (list (cons char char))))
    (_ (let ((expanded (rx--expand-def charset)))
         (if expanded
             (rx--charset-intervals expanded)
           (error "Bad character set: %S" charset))))))

(defun rx--charset-union (charsets)
  "Union of CHARSETS, as a set of intervals."
  (rx--foldl #'rx--union-intervals nil
             (mapcar #'rx--charset-intervals charsets)))

(defconst rx--charset-all (list (cons 0 (max-char))))

(defun rx--charset-intersection (charsets)
  "Intersection of CHARSETS, as a set of intervals."
  (rx--foldl #'rx--intersect-intervals rx--charset-all
             (mapcar #'rx--charset-intervals charsets)))

(defun rx--translate-union (negated body)
  "Translate an (or ...) construct of charsets.  Return (REGEXP . PRECEDENCE).
If NEGATED, negate the sense."
  (rx--intervals-to-alt negated (rx--charset-union body)))

(defun rx--translate-intersection (negated body)
  "Translate an (intersection ...) construct.  Return (REGEXP . PRECEDENCE).
If NEGATED, negate the sense."
  (rx--intervals-to-alt negated (rx--charset-intersection body)))

(defun rx--atomic-regexp (item)
  "ITEM is (REGEXP . PRECEDENCE); return a regexp of precedence t."
  (if (eq (cdr item) t)
      (car item)
    (rx--bracket (car item))))

(defun rx--translate-counted-repetition (min-count max-count body)
  (let ((operand (rx--translate-seq body)))
    (if (car operand)
        (cons (append
               (rx--atomic-regexp operand)
               (list (concat "\\{"
                             (number-to-string min-count)
                             (cond ((null max-count) ",")
                                   ((< min-count max-count)
                                    (concat "," (number-to-string max-count))))
                             "\\}")))
              t)
      operand)))

(defun rx--check-repeat-arg (name min-args body)
  (unless (>= (length body) min-args)
    (error "rx `%s' requires at least %d argument%s"
           name min-args (if (= min-args 1) "" "s")))
  ;; There seems to be no reason to disallow zero counts.
  (unless (natnump (car body))
    (error "rx `%s' first argument must be nonnegative" name)))

(defun rx--translate-bounded-repetition (name body)
  (let ((min-count (car body))
        (max-count (cadr body))
        (items (cddr body)))
    (unless (and (natnump min-count)
                 (natnump max-count)
                 (<= min-count max-count))
      (error "rx `%s' range error" name))
    (rx--translate-counted-repetition min-count max-count items)))

(defun rx--translate-repeat (body)
  (rx--check-repeat-arg 'repeat 2 body)
  (if (= (length body) 2)
      (rx--translate-counted-repetition (car body) (car body) (cdr body))
    (rx--translate-bounded-repetition 'repeat body)))

(defun rx--translate-** (body)
  (rx--check-repeat-arg '** 2 body)
  (rx--translate-bounded-repetition '** body))

(defun rx--translate->= (body)
  (rx--check-repeat-arg '>= 1 body)
  (rx--translate-counted-repetition (car body) nil (cdr body)))

(defun rx--translate-= (body)
  (rx--check-repeat-arg '= 1 body)
  (rx--translate-counted-repetition (car body) (car body) (cdr body)))

(defvar rx--greedy t)

(defun rx--translate-rep (op-string greedy body)
  "Translate a repetition; OP-STRING is one of \"*\", \"+\" or \"?\".
GREEDY is a boolean.  Return (REGEXP . PRECEDENCE)."
  (let ((operand (rx--translate-seq body)))
    (if (car operand)
        (cons (append (rx--atomic-regexp operand)
                      (list (concat op-string (unless greedy "?"))))
              ;; The result has precedence seq to avoid (? (* "a")) -> "a*?"
              'seq)
      operand)))

(defun rx--control-greedy (greedy body)
  "Translate the sequence BODY with greediness GREEDY.
Return (REGEXP . PRECEDENCE)."
  (let ((rx--greedy greedy))
    (rx--translate-seq body)))

(defun rx--translate-group (body)
  "Translate the `group' form.  Return (REGEXP . PRECEDENCE)."
  (cons (rx--enclose "\\("
                     (car (rx--translate-seq body))
                     "\\)")
        t))

(defun rx--translate-group-n (body)
  "Translate the `group-n' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and (integerp (car body)) (> (car body) 0))
    (error "rx `group-n' requires a positive number as first argument"))
  (cons (rx--enclose (concat "\\(?" (number-to-string (car body)) ":")
                     (car (rx--translate-seq (cdr body)))
                     "\\)")
        t))

(defun rx--translate-backref (body)
  "Translate the `backref' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and (= (length body) 1) (integerp (car body)) (<= 1 (car body) 9))
    (error "rx `backref' requires an argument in the range 1..9"))
  (cons (list "\\" (number-to-string (car body))) t))

(defconst rx--syntax-codes
  '((whitespace         . ?-)           ; SPC also accepted
    (punctuation        . ?.)
    (word               . ?w)           ; W also accepted
    (symbol             . ?_)
    (open-parenthesis   . ?\()
    (close-parenthesis  . ?\))
    (expression-prefix  . ?\')
    (string-quote       . ?\")
    (paired-delimiter   . ?$)
    (escape             . ?\\)
    (character-quote    . ?/)
    (comment-start      . ?<)
    (comment-end        . ?>)
    (string-delimiter   . ?|)
    (comment-delimiter  . ?!)))

(defun rx--translate-syntax (negated body)
  "Translate the `syntax' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and body (null (cdr body)))
    (error "rx `syntax' form takes exactly one argument"))
  (let* ((sym (car body))
         (syntax (cdr (assq sym rx--syntax-codes))))
    (unless syntax
      (cond
       ;; Syntax character directly (sregex compatibility)
       ((and (characterp sym) (rassq sym rx--syntax-codes))
        (setq syntax sym))
       ;; Syntax character as symbol (sregex compatibility)
       ((symbolp sym)
        (let ((name (symbol-name sym)))
          (when (= (length name) 1)
            (let ((char (string-to-char name)))
              (when (rassq char rx--syntax-codes)
                (setq syntax char)))))))
      (unless syntax
        (error "Unknown rx syntax name `%s'" sym)))
    (cons (list (string ?\\ (if negated ?S ?s) syntax))
          t)))

(defconst rx--categories
  '((space-for-indent           . ?\s)
    (base                       . ?.)
    (consonant                  . ?0)
    (base-vowel                 . ?1)
    (upper-diacritical-mark     . ?2)
    (lower-diacritical-mark     . ?3)
    (tone-mark                  . ?4)
    (symbol                     . ?5)
    (digit                      . ?6)
    (vowel-modifying-diacritical-mark . ?7)
    (vowel-sign                 . ?8)
    (semivowel-lower            . ?9)
    (not-at-end-of-line         . ?<)
    (not-at-beginning-of-line   . ?>)
    (alpha-numeric-two-byte     . ?A)
    (chinese-two-byte           . ?C)
    (chinse-two-byte            . ?C)   ; A typo in Emacs 21.1-24.3.
    (greek-two-byte             . ?G)
    (japanese-hiragana-two-byte . ?H)
    (indian-two-byte            . ?I)
    (japanese-katakana-two-byte . ?K)
    (strong-left-to-right       . ?L)
    (korean-hangul-two-byte     . ?N)
    (strong-right-to-left       . ?R)
    (cyrillic-two-byte          . ?Y)
    (combining-diacritic        . ?^)
    (ascii                      . ?a)
    (arabic                     . ?b)
    (chinese                    . ?c)
    (ethiopic                   . ?e)
    (greek                      . ?g)
    (korean                     . ?h)
    (indian                     . ?i)
    (japanese                   . ?j)
    (japanese-katakana          . ?k)
    (latin                      . ?l)
    (lao                        . ?o)
    (tibetan                    . ?q)
    (japanese-roman             . ?r)
    (thai                       . ?t)
    (vietnamese                 . ?v)
    (hebrew                     . ?w)
    (cyrillic                   . ?y)
    (can-break                  . ?|)))

(defun rx--translate-category (negated body)
  "Translate the `category' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and body (null (cdr body)))
    (error "rx `category' form takes exactly one argument"))
  (let* ((arg (car body))
         (category
          (cond ((symbolp arg)
                 (let ((cat (assq arg rx--categories)))
                   (unless cat
                     (error "Unknown rx category `%s'" arg))
                   (cdr cat)))
                ((characterp arg) arg)
                (t (error "Invalid rx `category' argument `%s'" arg)))))
    (cons (list (string ?\\ (if negated ?C ?c) category))
          t)))

(defvar rx--delayed-evaluation nil
  "Whether to allow certain forms to be evaluated at runtime.")

(defun rx--translate-literal (body)
  "Translate the `literal' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and body (null (cdr body)))
    (error "rx `literal' form takes exactly one argument"))
  (let ((arg (car body)))
    (cond ((stringp arg)
           (cons (list (regexp-quote arg)) (if (= (length arg) 1) t 'seq)))
          (rx--delayed-evaluation
           (cons (list (list 'regexp-quote arg)) 'seq))
          (t (error "rx `literal' form with non-string argument")))))

(defun rx--expand-eval (body)
  "Expand `eval' arguments.  Return a new rx form."
  (unless (and body (null (cdr body)))
    (error "rx `eval' form takes exactly one argument"))
  (eval (car body)))

(defun rx--translate-eval (body)
  "Translate the `eval' form.  Return (REGEXP . PRECEDENCE)."
  (rx--translate (rx--expand-eval body)))

(defvar rx--regexp-atomic-regexp nil)

(defun rx--translate-regexp (body)
  "Translate the `regexp' form.  Return (REGEXP . PRECEDENCE)."
  (unless (and body (null (cdr body)))
    (error "rx `regexp' form takes exactly one argument"))
  (let ((arg (car body)))
    (cond ((stringp arg)
           ;; Generate the regexp when needed, since rx isn't
           ;; necessarily present in the byte-compilation environment.
           (unless rx--regexp-atomic-regexp
             (setq rx--regexp-atomic-regexp
                   ;; Match atomic (precedence t) regexps: may give
                   ;; false negatives but no false positives, assuming
                   ;; the target string is syntactically correct.
                   (rx-to-string
                    '(seq
                      bos
                      (or (seq "["
                               (opt "^")
                               (opt "]")
                               (* (or (seq "[:" (+ (any "a-z")) ":]")
                                      (not (any "]"))))
                               "]")
                          (not (any "*+?^$[\\"))
                          (seq "\\"
                               (or anything
                                   (seq (any "sScC_") anything)
                                   (seq "("
                                        (* (or (not (any "\\"))
                                               (seq "\\" (not (any ")")))))
                                        "\\)"))))
                      eos)
                    t)))
           (cons (list arg)
                 (if (string-match-p rx--regexp-atomic-regexp arg) t nil)))
          (rx--delayed-evaluation
           (cons (list arg) nil))
          (t (error "rx `regexp' form with non-string argument")))))

(defun rx--translate-compat-form (def form)
  "Translate a compatibility form from `rx-constituents'.
DEF is the definition tuple.  Return (REGEXP . PRECEDENCE)."
  (let* ((fn (nth 0 def))
         (min-args (nth 1 def))
         (max-args (nth 2 def))
         (predicate (nth 3 def))
         (nargs (1- (length form))))
    (when (< nargs min-args)
      (error "The `%s' form takes at least %d argument(s)"
             (car form) min-args))
    (when (and max-args (> nargs max-args))
      (error "The `%s' form takes at most %d argument(s)"
             (car form) max-args))
    (when (and predicate (not (rx--every predicate (cdr form))))
      (error "The `%s' form requires arguments satisfying `%s'"
             (car form) predicate))
    (let ((regexp (funcall fn form)))
      (unless (stringp regexp)
        (error "The `%s' form did not expand to a string" (car form)))
      (cons (list regexp) nil))))

(defun rx--substitute (bindings form)
  "Substitute BINDINGS in FORM.  BINDINGS is an alist of (NAME . VALUES)
where VALUES is a list to splice into FORM wherever NAME occurs.
Return the substitution result wrapped in a list, since a single value
can expand to any number of values."
  (cond ((symbolp form)
         (let ((binding (assq form bindings)))
           (if binding
               (cdr binding)
             (list form))))
        ((consp form)
         (if (listp (cdr form))
             ;; Proper list.  We substitute variables even in the head
             ;; position -- who knows, might be handy one day.
             (list (mapcan (lambda (x) (comys-sequence
                                        (rx--substitute bindings x)))
                           form))
           ;; Cons pair (presumably an interval).
           (let ((first (rx--substitute bindings (car form)))
                 (second (rx--substitute bindings (cdr form))))
             (if (and first (not (cdr first))
                      second (not (cdr second)))
                 (list (cons (car first) (car second)))
               (error
                "Cannot substitute a &rest parameter into a dotted pair")))))
        (t (list form))))

;; FIXME: Consider adding extensions in Lisp macro style, where
;; arguments are passed unevaluated to code that returns the rx form
;; to use.  Example:
;;
;;   (rx-let ((radix-digit (radix)
;;             :lisp (list 'any (cons ?0 (+ ?0 (eval radix) -1)))))
;;     (rx (radix-digit (+ 5 3))))
;; =>
;;   "[0-7]"
;;
;; While this would permit more powerful extensions, it's unclear just
;; how often they would be used in practice.  Let's wait until there is
;; demand for it.

;; FIXME: An alternative binding syntax would be
;;
;;   (NAME RXs...)
;; and
;;   ((NAME ARGS...) RXs...)
;;
;; which would have two minor advantages: multiple RXs with implicit
;; `seq' in the definition, and the arglist is no longer an optional
;; element in the middle of the list.  On the other hand, it's less
;; like traditional lisp arglist constructs (defun, defmacro).
;; Since it's a Scheme-like syntax, &rest parameters could be done using
;; dotted lists:
;;  (rx-let (((name arg1 arg2 . rest) ...definition...)) ...)

(defun rx--expand-template (op values arglist template)
  "Return TEMPLATE with variables in ARGLIST replaced with VALUES."
  (let ((bindings nil)
        (value-tail values)
        (formals arglist))
    (while formals
      (pcase (car formals)
        ('&rest
         (unless (cdr formals)
           (error
            "Expanding rx def `%s': missing &rest parameter name" op))
         (push (cons (cadr formals) value-tail) bindings)
         (setq formals nil)
         (setq value-tail nil))
        (name
         (unless value-tail
           (error
            "Expanding rx def `%s': too few arguments (got %d, need %s%d)"
            op (length values)
            (if (memq '&rest arglist) "at least " "")
            (- (length arglist) (length (memq '&rest arglist)))))
         (push (cons name (list (car value-tail))) bindings)
         (setq value-tail (cdr value-tail))))
      (setq formals (cdr formals)))
    (when value-tail
      (error
       "Expanding rx def `%s': too many arguments (got %d, need %d)"
       op (length values) (length arglist)))
    (let ((subst (rx--substitute bindings template)))
      (if (and subst (not (cdr subst)))
          (car subst)
        (error "Expanding rx def `%s': must result in a single value" op)))))

(defun rx--translate-form (form)
  "Translate an rx form (list structure).  Return (REGEXP . PRECEDENCE)."
  (let ((body (cdr form)))
    (pcase (car form)
      ((or 'seq : 'and 'sequence) (rx--translate-seq body))
      ((or 'or '|)              (rx--translate-or body))
      ((or 'any 'in 'char)      (rx--translate-any nil body))
      ('not-char                (rx--translate-any t body))
      ('not                     (rx--translate-not nil body))
      ('intersection            (rx--translate-intersection nil body))

      ('repeat                  (rx--translate-repeat body))
      ('=                       (rx--translate-= body))
      ('>=                      (rx--translate->= body))
      ('**                      (rx--translate-** body))

      ((or 'zero-or-more '0+)           (rx--translate-rep "*" rx--greedy body))
      ((or 'one-or-more '1+)            (rx--translate-rep "+" rx--greedy body))
      ((or 'zero-or-one 'opt 'optional) (rx--translate-rep "?" rx--greedy body))

      ('*                       (rx--translate-rep "*" t body))
      ('+                       (rx--translate-rep "+" t body))
      ((or '\? ?\s)             (rx--translate-rep "?" t body))

      ('*?                      (rx--translate-rep "*" nil body))
      ('+?                      (rx--translate-rep "+" nil body))
      ((or '\?? ??)             (rx--translate-rep "?" nil body))

      ('minimal-match           (rx--control-greedy nil body))
      ('maximal-match           (rx--control-greedy t   body))

      ((or 'group 'submatch)     (rx--translate-group body))
      ((or 'group-n 'submatch-n) (rx--translate-group-n body))
      ('backref                  (rx--translate-backref body))

      ('syntax                  (rx--translate-syntax nil body))
      ('not-syntax              (rx--translate-syntax t body))
      ('category                (rx--translate-category nil body))

      ('literal                 (rx--translate-literal body))
      ('eval                    (rx--translate-eval body))
      ((or 'regexp 'regex)      (rx--translate-regexp body))

      (op
       (cond
        ((not (symbolp op)) (error "Bad rx operator `%S'" op))

        ((let ((expanded (rx--expand-def form)))
           (and expanded
                (rx--translate expanded))))

        ;; For compatibility with old rx.
        ((let ((entry (assq op rx-constituents)))
           (and (progn
                  (while (and entry (not (consp (cdr entry))))
                    (setq entry
                          (if (symbolp (cdr entry))
                              ;; Alias for another entry.
                              (assq (cdr entry) rx-constituents)
                            ;; Wrong type, try further down the list.
                            (assq (car entry)
                                  (cdr (memq entry rx-constituents))))))
                  entry)
                (rx--translate-compat-form (cdr entry) form))))

        (t (error "Unknown rx form `%s'" op)))))))

(defconst rx--builtin-forms
  '(seq sequence : and or | any in char not-char not intersection
    repeat = >= **
    zero-or-more 0+ *
    one-or-more 1+ +
    zero-or-one opt optional \?
    *? +? \??
    minimal-match maximal-match
    group submatch group-n submatch-n backref
    syntax not-syntax category
    literal eval regexp regex)
  "List of built-in rx function-like symbols.")

(defconst rx--builtin-symbols
  (append '(nonl not-newline any anychar anything unmatchable
            bol eol line-start line-end
            bos eos string-start string-end
            bow eow word-start word-end
            symbol-start symbol-end
            point word-boundary not-word-boundary not-wordchar)
          (mapcar #'car rx--char-classes))
  "List of built-in rx variable-like symbols.")

(defconst rx--builtin-names
  (append rx--builtin-forms rx--builtin-symbols)
  "List of built-in rx names.  These cannot be redefined by the user.")

(defun rx--translate (item)
  "Translate the rx-expression ITEM.  Return (REGEXP . PRECEDENCE)."
  (cond
   ((stringp item)
    (if (= (length item) 0)
        (cons nil 'seq)
      (cons (list (regexp-quote item)) (if (= (length item) 1) t 'seq))))
   ((characterp item)
    (cons (list (regexp-quote (char-to-string item))) t))
   ((symbolp item)
    (rx--translate-symbol item))
   ((consp item)
    (rx--translate-form item))
   (t (error "Bad rx expression: %S" item))))


(defun rx-to-string (form &optional no-group)
  "Translate FORM from `rx' sexp syntax into a string regexp.
The arguments to `literal' and `regexp' forms inside FORM must be
constant strings.
If NO-GROUP is non-nil, don't bracket the result in a non-capturing
group.

For extending the `rx' notation in FORM, use `rx-define' or `rx-let-eval'."
  (let* ((item (rx--translate form))
         (exprs (if no-group
                    (car item)
                  (rx--atomic-regexp item))))
    (apply #'concat exprs)))

(defun rx--to-expr (form)
  "Translate the rx-expression FORM to a Lisp expression yielding a regexp."
  (let* ((rx--delayed-evaluation t)
         (elems (car (rx--translate form)))
         (args nil))
    ;; Merge adjacent strings.
    (while elems
      (let ((strings nil))
        (while (and elems (stringp (car elems)))
          (push (car elems) strings)
          (setq elems (cdr elems)))
        (let ((s (apply #'concat (nreverse strings))))
          (unless (zerop (length s))
            (push s args))))
      (when elems
        (push (car elems) args)
        (setq elems (cdr elems))))
    (cond ((null args) "")                             ; 0 args
          ((cdr args) (cons 'concat (nreverse args)))  ; ≥2 args
          (t (car args)))))                            ; 1 arg


(defmacro rx (&rest regexps)
  "Translate regular expressions REGEXPS in sexp form to a regexp string.
Each argument is one of the forms below; RX is a subform, and RX... stands
for zero or more RXs.  For details, see Info node `(elisp) Rx Notation'.
See `rx-to-string' for the corresponding function.

STRING         Match a literal string.
CHAR           Match a literal character.

(seq RX...)    Match the RXs in sequence.  Alias: :, sequence, and.
(or RX...)     Match one of the RXs.  Alias: |.

(zero-or-more RX...) Match RXs zero or more times.  Alias: 0+.
(one-or-more RX...)  Match RXs one or more times.  Alias: 1+.
(zero-or-one RX...)  Match RXs or the empty string.  Alias: opt, optional.
(* RX...)       Match RXs zero or more times; greedy.
(+ RX...)       Match RXs one or more times; greedy.
(? RX...)       Match RXs or the empty string; greedy.
(*? RX...)      Match RXs zero or more times; non-greedy.
(+? RX...)      Match RXs one or more times; non-greedy.
(?? RX...)      Match RXs or the empty string; non-greedy.
(= N RX...)     Match RXs exactly N times.
(>= N RX...)    Match RXs N or more times.
(** N M RX...)  Match RXs N to M times.  Alias: repeat.
(minimal-match RX)  Match RX, with zero-or-more, one-or-more, zero-or-one
                and aliases using non-greedy matching.
(maximal-match RX)  Match RX, with zero-or-more, one-or-more, zero-or-one
                and aliases using greedy matching, which is the default.

(any SET...)    Match a character from one of the SETs.  Each SET is a
                character, a string, a range as string \"A-Z\" or cons
                (?A . ?Z), or a character class (see below).  Alias: in, char.
(not CHARSPEC)  Match one character not matched by CHARSPEC.  CHARSPEC
                can be a character, single-char string, (any ...), (or ...),
                (intersection ...), (syntax ...), (category ...),
                or a character class.
(intersection CHARSET...) Match all CHARSETs.
                CHARSET is (any...), (not...), (or...) or (intersection...),
                a character or a single-char string.
not-newline     Match any character except a newline.  Alias: nonl.
anychar         Match any character.  Alias: anything.
unmatchable     Never match anything at all.

CHARCLASS       Match a character from a character class.  One of:
 alpha, alphabetic, letter   Alphabetic characters (defined by Unicode).
 alnum, alphanumeric         Alphabetic or decimal digit chars (Unicode).
 digit, numeric, num         0-9.
 xdigit, hex-digit, hex      0-9, A-F, a-f.
 cntrl, control              ASCII codes 0-31.
 blank                       Horizontal whitespace (Unicode).
 space, whitespace, white    Chars with whitespace syntax.
 lower, lower-case           Lower-case chars, from current case table.
 upper, upper-case           Upper-case chars, from current case table.
 graph, graphic              Graphic characters (Unicode).
 print, printing             Whitespace or graphic (Unicode).
 punct, punctuation          Not control, space, letter or digit (ASCII);
                              not word syntax (non-ASCII).
 word, wordchar              Characters with word syntax.
 ascii                       ASCII characters (codes 0-127).
 nonascii                    Non-ASCII characters (but not raw bytes).

(syntax SYNTAX)  Match a character with syntax SYNTAX, being one of:
  whitespace, punctuation, word, symbol, open-parenthesis,
  close-parenthesis, expression-prefix, string-quote,
  paired-delimiter, escape, character-quote, comment-start,
  comment-end, string-delimiter, comment-delimiter

(category CAT)   Match a character in category CAT, being one of:
  space-for-indent, base, consonant, base-vowel,
  upper-diacritical-mark, lower-diacritical-mark, tone-mark, symbol,
  digit, vowel-modifying-diacritical-mark, vowel-sign,
  semivowel-lower, not-at-end-of-line, not-at-beginning-of-line,
  alpha-numeric-two-byte, chinese-two-byte, greek-two-byte,
  japanese-hiragana-two-byte, indian-two-byte,
  japanese-katakana-two-byte, strong-left-to-right,
  korean-hangul-two-byte, strong-right-to-left, cyrillic-two-byte,
  combining-diacritic, ascii, arabic, chinese, ethiopic, greek,
  korean, indian, japanese, japanese-katakana, latin, lao,
  tibetan, japanese-roman, thai, vietnamese, hebrew, cyrillic,
  can-break

Zero-width assertions: these all match the empty string in specific places.
 line-start         At the beginning of a line.  Alias: bol.
 line-end           At the end of a line.  Alias: eol.
 string-start       At the start of the string or buffer.
                     Alias: buffer-start, bos, bot.
 string-end         At the end of the string or buffer.
                     Alias: buffer-end, eos, eot.
 point              At point.
 word-start         At the beginning of a word.  Alias: bow.
 word-end           At the end of a word.  Alias: eow.
 word-boundary      At the beginning or end of a word.
 not-word-boundary  Not at the beginning or end of a word.
 symbol-start       At the beginning of a symbol.
 symbol-end         At the end of a symbol.

(group RX...)  Match RXs and define a capture group.  Alias: submatch.
(group-n N RX...) Match RXs and define capture group N.  Alias: submatch-n.
(backref N)    Match the text that capture group N matched.

(literal EXPR) Match the literal string from evaluating EXPR at run time.
(regexp EXPR)  Match the string regexp from evaluating EXPR at run time.
(eval EXPR)    Match the rx sexp from evaluating EXPR at macro-expansion
                (compile) time.

Additional constructs can be defined using `rx-define' and `rx-let',
which see.

\(fn REGEXPS...)"
  ;; Retrieve local definitions from the macroexpansion environment.
  ;; (It's unclear whether the previous value of `rx--local-definitions'
  ;; should be included, and if so, in which order.)
  (let ((rx--local-definitions
         (cdr (assq :rx-locals macroexpand-all-environment))))
    (rx--to-expr (cons 'seq regexps))))

(defun rx--make-binding (name tail)
  "Make a definitions entry out of TAIL.
TAIL is on the form ([ARGLIST] DEFINITION)."
  (unless (symbolp name)
    (error "Bad `rx' definition name: %S" name))
  ;; FIXME: Consider using a hash table or symbol property, for speed.
  (when (memq name rx--builtin-names)
    (error "Cannot redefine built-in rx name `%s'" name))
  (pcase tail
    (`(,def)
     (list def))
    (`(,args ,def)
     (unless (and (listp args) (rx--every #'symbolp args))
       (error "Bad argument list for `rx' definition %s: %S" name args))
     (list args def))
    (_ (error "Bad `rx' definition of %s: %S" name tail))))

(defun rx--make-named-binding (bindspec)
  "Make a definitions entry out of BINDSPEC.
BINDSPEC is on the form (NAME [ARGLIST] DEFINITION)."
  (unless (consp bindspec)
    (error "Bad `rx-let' binding: %S" bindspec))
  (cons (car bindspec)
        (rx--make-binding (car bindspec) (cdr bindspec))))

(defun rx--extend-local-defs (bindspecs)
  (append (mapcar #'rx--make-named-binding bindspecs)
          rx--local-definitions))

(defmacro rx-let-eval (bindings &rest body)
  "Evaluate BODY with local BINDINGS for `rx-to-string'.
BINDINGS, after evaluation, is a list of definitions each on the form
(NAME [(ARGS...)] RX), in effect for calls to `rx-to-string'
in BODY.

For bindings without an ARGS list, NAME is defined as an alias
for the `rx' expression RX.  Where ARGS is supplied, NAME is
defined as an `rx' form with ARGS as argument list.  The
parameters are bound from the values in the (NAME ...) form and
are substituted in RX.  ARGS can contain `&rest' parameters,
whose values are spliced into RX where the parameter name occurs.

Any previous definitions with the same names are shadowed during
the expansion of BODY only.
For extensions when using the `rx' macro, use `rx-let'.
To make global rx extensions, use `rx-define'.
For more details, see Info node `(elisp) Extending Rx'.

\(fn BINDINGS BODY...)"
  (declare (indent 1) (debug (form body)))
  ;; FIXME: this way, `rx--extend-local-defs' may need to be autoloaded.
  `(let ((rx--local-definitions (rx--extend-local-defs ,bindings)))
     ,@body))

(defmacro rx-let (bindings &rest body)
  "Evaluate BODY with local BINDINGS for `rx'.
BINDINGS is an unevaluated list of bindings each on the form
(NAME [(ARGS...)] RX).
They are bound lexically and are available in `rx' expressions in
BODY only.

For bindings without an ARGS list, NAME is defined as an alias
for the `rx' expression RX.  Where ARGS is supplied, NAME is
defined as an `rx' form with ARGS as argument list.  The
parameters are bound from the values in the (NAME ...) form and
are substituted in RX.  ARGS can contain `&rest' parameters,
whose values are spliced into RX where the parameter name occurs.

Any previous definitions with the same names are shadowed during
the expansion of BODY only.
For local extensions to `rx-to-string', use `rx-let-eval'.
To make global rx extensions, use `rx-define'.
For more details, see Info node `(elisp) Extending Rx'.

\(fn BINDINGS BODY...)"
  (declare (indent 1) (debug (sexp body)))
  (let ((prev-locals (cdr (assq :rx-locals macroexpand-all-environment)))
        (new-locals (mapcar #'rx--make-named-binding bindings)))
    (macroexpand-all (cons 'progn body)
                     (cons (cons :rx-locals (append new-locals prev-locals))
                           macroexpand-all-environment))))

(defmacro rx-define (name &rest definition)
  "Define NAME as a global `rx' definition.
If the ARGS list is omitted, define NAME as an alias for the `rx'
expression RX.

If the ARGS list is supplied, define NAME as an `rx' form with
ARGS as argument list.  The parameters are bound from the values
in the (NAME ...) form and are substituted in RX.
ARGS can contain `&rest' parameters, whose values are spliced
into RX where the parameter name occurs.

Any previous global definition of NAME is overwritten with the new one.
To make local rx extensions, use `rx-let' for `rx',
`rx-let-eval' for `rx-to-string'.
For more details, see Info node `(elisp) Extending Rx'.

\(fn NAME [(ARGS...)] RX)"
  (declare (indent defun))
  `(eval-and-compile
     (put ',name 'rx-definition ',(rx--make-binding name definition))
     ',name))

;; During `rx--pcase-transform', list of defined variables in right-to-left
;; order.
(defvar rx--pcase-vars)

;; FIXME: The rewriting strategy for pcase works so-so with extensions;
;; definitions cannot expand to `let' or named `backref'.  If this ever
;; becomes a problem, we can handle those forms in the ordinary parser,
;; using a dynamic variable for activating the augmented forms.

(defun rx--pcase-transform (rx)
  "Transform RX, an rx-expression augmented with `let' and named `backref',
into a plain rx-expression, collecting names into `rx--pcase-vars'."
  (pcase rx
    (`(let ,name . ,body)
     (let* ((index (length (memq name rx--pcase-vars)))
            (i (if (zerop index)
                   (length (push name rx--pcase-vars))
                 index)))
       `(group-n ,i ,(rx--pcase-transform (cons 'seq body)))))
    ((and `(backref ,ref)
          (guard (symbolp ref)))
     (let ((index (length (memq ref rx--pcase-vars))))
       (when (zerop index)
         (error "rx `backref' variable must be one of: %s"
                (mapconcat #'symbol-name rx--pcase-vars " ")))
       `(backref ,index)))
    ((and `(,head . ,rest)
          (guard (and (or (symbolp head) (memq head '(?\s ??)))
                      (not (memq head '(literal regexp regex eval))))))
     (cons head (mapcar #'rx--pcase-transform rest)))
    (_ rx)))

(defun rx--reduce-right (f l)
  "Right-reduction on L by F.  L must be non-empty."
  (if (cdr l)
      (funcall f (car l) (rx--reduce-right f (cdr l)))
    (car l)))

(pcase-defmacro rx (&rest regexps)
  "A pattern that matches strings against `rx' REGEXPS in sexp form.
REGEXPS are interpreted as in `rx'.  The pattern matches any
string that is a match for REGEXPS, as if by `string-match'.

In addition to the usual `rx' syntax, REGEXPS can contain the
following constructs:

  (let REF RX...)  binds the symbol REF to a submatch that matches
                   the regular expressions RX.  REF is bound in
                   CODE to the string of the submatch or nil, but
                   can also be used in `backref'.
  (backref REF)    matches whatever the submatch REF matched.
                   REF can be a number, as usual, or a name
                   introduced by a previous (let REF ...)
                   construct."
  (let* ((rx--pcase-vars nil)
         (regexp (rx--to-expr (rx--pcase-transform (cons 'seq regexps)))))
    `(and (pred stringp)
          ,(pcase (length rx--pcase-vars)
            (0
             ;; No variables bound: a single predicate suffices.
             `(pred (string-match ,regexp)))
            (1
             ;; Create a match value that on a successful regexp match
             ;; is the submatch value, 0 on failure.  We can't use nil
             ;; for failure because it is a valid submatch value.
             `(app (lambda (s)
                     (if (string-match ,regexp s)
                         (match-string 1 s)
                       0))
                   (and ,(car rx--pcase-vars) (pred (not numberp)))))
            (nvars
             ;; Pack the submatches into a dotted list which is then
             ;; immediately destructured into individual variables again.
             ;; This is of course slightly inefficient.
             ;; A dotted list is used to reduce the number of conses
             ;; to create and take apart.
             `(app (lambda (s)
                     (and (string-match ,regexp s)
                          ,(rx--reduce-right
                            (lambda (a b) `(cons ,a ,b))
                            (mapcar (lambda (i) `(match-string ,i s))
                                    (number-sequence 1 nvars)))))
                   ,(list '\`
                          (rx--reduce-right
                           #'cons
                           (mapcar (lambda (name) (list '\, name))
                                   (reverse rx--pcase-vars))))))))))

;; Obsolete internal symbol, used in old versions of the `flycheck' package.
(define-obsolete-function-alias 'rx-submatch-n 'rx-to-string "27.1")

;; mys-components-extra

(defun mys-util-comint-last-prompt ()
  "Return comint last prompt overlay start and end.
This is for compatibility with Emacs < 24.4."
  (cond ((bound-and-true-p comint-last-prompt-overlay)
         (cons (overlay-start comint-last-prompt-overlay)
               (overlay-end comint-last-prompt-overlay)))
        ((bound-and-true-p comint-last-prompt)
         comint-last-prompt)
        (t nil)))

(defun mys-shell-accept-process-output (process &optional timeout regexp)
  "Accept PROCESS output with TIMEOUT until REGEXP is found.
Optional argument TIMEOUT is the timeout argument to
`accept-process-output' calls.  Optional argument REGEXP
overrides the regexp to match the end of output, defaults to
`comint-prompt-regexp'.  Returns non-nil when output was
properly captured.

This utility is useful in situations where the output may be
received in chunks, since `accept-process-output' gives no
guarantees they will be grabbed in a single call.  An example use
case for this would be the CPython shell start-up, where the
banner and the initial prompt are received separately."
  (let ((regexp (or regexp comint-prompt-regexp)))
    (catch 'found
      (while t
        (when (not (accept-process-output process timeout))
          (throw 'found nil))
        (when (looking-back
               regexp (car (mys-util-comint-last-prompt)))
          (throw 'found t))))))

(defun mys-shell-completion-get-completions (process import input)
  "Do completion at point using PROCESS for IMPORT or INPUT.
When IMPORT is non-nil takes precedence over INPUT for
completion."
  (setq input (or import input))
  (with-current-buffer (process-buffer process)
    (let ((completions
           (ignore-errors
	     (mys--string-trim
	      (mys-send-string-no-output
	       (format
		(concat mys-completion-setup-code
			"\nprint (" mys-shell-completion-string-code ")")
		input) process (buffer-name (current-buffer)))))))
      (when (> (length completions) 2)
        (split-string completions
                      "^'\\|^\"\\|;\\|'$\\|\"$" t)))))

(defun mys-shell-completion-at-point (&optional process)
  "Function for `completion-at-point-functions' in `mys-shell-mode'.
Optional argument PROCESS forces completions to be retrieved
using that one instead of current buffer's process."
  ;; (setq process (or process (get-buffer-process (current-buffer))))
  (let*
      ((process (or process (get-buffer-process (current-buffer))))
       (line-start (if (derived-mode-p 'mys-shell-mode)
		       ;; Working on a shell buffer: use prompt end.
		       (or (cdr (mys-util-comint-last-prompt))
			   (line-beginning-position))
		     (line-beginning-position)))
       (import-statement
	(when (string-match-p
	       (rx (* space) word-start (or "from" "import") word-end space)
	       (buffer-substring-no-properties line-start (point)))
	  (buffer-substring-no-properties line-start (point))))
       (start
	(save-excursion
	  (if (not (re-search-backward
		    ;; (mys-rx
		    ;;  (or whitespace open-paren close-paren string-delimiter simple-operator))
		    "[[:space:]]\\|[([{]\\|[])}]\\|\\(?:[^\"'\\]\\|\\=\\|\\(?:[^\\]\\|\\=\\)\\\\\\(?:\\\\\\\\\\)*[\"']\\)\\(?:\\\\\\\\\\)*\\(\\(?:\"\"\"\\|'''\\|[\"']\\)\\)\\|[%&*+/<->^|~-]"
		    line-start
		    t 1))
	      line-start
	    (forward-char (length (match-string-no-properties 0)))
	    (point))))
       (end (point))
              (completion-fn
	(with-current-buffer (process-buffer process)
	  #'mys-shell-completion-get-completions)))
    (list start end
          (completion-table-dynamic
           (apply-partially
            completion-fn
            process import-statement)))))

(defun mys-comint-watch-for-first-prompt-output-filter (output)
  "Run `mys-shell-first-prompt-hook' when first prompt is found in OUTPUT."
  (when (not mys-shell--first-prompt-received)
    (set (make-local-variable 'mys-shell--first-prompt-received-output-buffer)
         (concat mys-shell--first-prompt-received-output-buffer
                 (ansi-color-filter-apply output)))
    (when (mys-shell-comint-end-of-output-p
           mys-shell--first-prompt-received-output-buffer)
      (if (string-match-p
           (concat mys-shell-prompt-pdb-regexp (rx eos))
           (or mys-shell--first-prompt-received-output-buffer ""))
          ;; Skip pdb prompts and reset the buffer.
          (setq mys-shell--first-prompt-received-output-buffer nil)
        (set (make-local-variable 'mys-shell--first-prompt-received) t)
        (setq mys-shell--first-prompt-received-output-buffer nil)
        (with-current-buffer (current-buffer)
          (let ((inhibit-quit nil))
            (run-hooks 'mys-shell-first-prompt-hook))))))
  output)

(defun mys-shell-font-lock-get-or-create-buffer ()
  "Get or create a font-lock buffer for current inferior process."
  (with-current-buffer (current-buffer)
    (if mys-shell--font-lock-buffer
        mys-shell--font-lock-buffer
      (let ((process-name
             (process-name (get-buffer-process (current-buffer)))))
        (generate-new-buffer
         (format " *%s-font-lock*" process-name))))))

(defun mys-font-lock-kill-buffer ()
  "Kill the font-lock buffer safely."
  (when (and mys-shell--font-lock-buffer
             (buffer-live-p mys-shell--font-lock-buffer))
    (kill-buffer mys-shell--font-lock-buffer)
    (when (derived-mode-p 'mys-shell-mode)
      (setq mys-shell--font-lock-buffer nil))))

(defmacro mys-shell-font-lock-with-font-lock-buffer (&rest body)
  "Execute the forms in BODY in the font-lock buffer.
The value returned is the value of the last form in BODY.  See
also `with-current-buffer'."
  (declare (indent 0) (debug t))
  `(save-current-buffer
     (when (not (and mys-shell--font-lock-buffer
		     (get-buffer mys-shell--font-lock-buffer)))
       (setq mys-shell--font-lock-buffer
	     (mys-shell-font-lock-get-or-create-buffer)))
     (set-buffer mys-shell--font-lock-buffer)
     (when (not font-lock-mode)
       (font-lock-mode 1))
     (set (make-local-variable 'delay-mode-hooks) t)
     (let (mys-smart-indentation)
       (when (not (derived-mode-p 'mys-mode))
	 (mys-mode))
       ,@body)))

(defun mys-shell-font-lock-cleanup-buffer ()
  "Cleanup the font-lock buffer.
Provided as a command because this might be handy if something
goes wrong and syntax highlighting in the shell gets messed up."
  (interactive)
  (with-current-buffer (current-buffer)
    (mys-shell-font-lock-with-font-lock-buffer
      (erase-buffer))))

(defun mys-shell-font-lock-comint-output-filter-function (output)
  "Clean up the font-lock buffer after any OUTPUT."
  (if (and (not (string= "" output))
           ;; Is end of output and is not just a prompt.
           (not (member
                 (mys-shell-comint-end-of-output-p
                  (ansi-color-filter-apply output))
                 '(nil 0))))
      ;; If output is other than an input prompt then "real" output has
      ;; been received and the font-lock buffer must be cleaned up.
      (mys-shell-font-lock-cleanup-buffer)
    ;; Otherwise just add a newline.
    (mys-shell-font-lock-with-font-lock-buffer
      (goto-char (point-max))
      (newline 1)))
  output)

(defun mys-font-lock-post-command-hook ()
  "Fontifies current line in shell buffer."
  (let ((prompt-end
	 (or (cdr (mys-util-comint-last-prompt))
	     (progn (sit-for 0.1)
		    (cdr (mys-util-comint-last-prompt))))))
    (when (and prompt-end (> (point) prompt-end)
               (process-live-p (get-buffer-process (current-buffer))))
      (let* ((input (buffer-substring-no-properties
                     prompt-end (point-max)))
             (deactivate-mark nil)
             (start-pos prompt-end)
             (buffer-undo-list t)
             (font-lock-buffer-pos nil)
             (replacement
              (mys-shell-font-lock-with-font-lock-buffer
                (delete-region (line-beginning-position)
                               (point-max))
                (setq font-lock-buffer-pos (point))
                (insert input)
                ;; Ensure buffer is fontified, keeping it
                ;; compatible with Emacs < 24.4.
		(when mys-shell-fontify-p
		    (if (fboundp 'font-lock-ensure)
			(funcall 'font-lock-ensure)
		      (font-lock-default-fontify-buffer)))
                (buffer-substring font-lock-buffer-pos
                                  (point-max))))
             (replacement-length (length replacement))
             (i 0))
        ;; Inject text properties to get input fontified.
        (while (not (= i replacement-length))
          (let* ((plist (text-properties-at i replacement))
                 (next-change (or (next-property-change i replacement)
                                  replacement-length))
                 (plist (let ((face (plist-get plist 'face)))
                          (if (not face)
                              plist
                            ;; Replace FACE text properties with
                            ;; FONT-LOCK-FACE so input is fontified.
                            (plist-put plist 'face nil)
                            (plist-put plist 'font-lock-face face)))))
            (set-text-properties
             (+ start-pos i) (+ start-pos next-change) plist)
            (setq i next-change)))))))

(defun mys-shell-font-lock-turn-on (&optional msg)
  "Turn on shell font-lock.
With argument MSG show activation message."
  (interactive "p")
  (save-current-buffer
    (mys-font-lock-kill-buffer)
    (set (make-local-variable 'mys-shell--font-lock-buffer) nil)
    (add-hook 'post-command-hook
	      #'mys-font-lock-post-command-hook nil 'local)
    (add-hook 'kill-buffer-hook
              #'mys-font-lock-kill-buffer nil 'local)
    (add-hook 'comint-output-filter-functions
              #'mys-shell-font-lock-comint-output-filter-function
              'append 'local)
    (when msg
      (message "Shell font-lock is enabled"))))

(defun mys-shell-font-lock-turn-off (&optional msg)
  "Turn off shell font-lock.
With argument MSG show deactivation message."
  (interactive "p")
  (with-current-buffer (current-buffer)
    (mys-font-lock-kill-buffer)
    (when (mys-util-comint-last-prompt)
      ;; Cleanup current fontification
      (remove-text-properties
       (cdr (mys-util-comint-last-prompt))
       (line-end-position)
       '(face nil font-lock-face nil)))
    (set (make-local-variable 'mys-shell--font-lock-buffer) nil)
    (remove-hook 'post-command-hook
                 #'mys-font-lock-post-command-hook 'local)
    (remove-hook 'kill-buffer-hook
                 #'mys-font-lock-kill-buffer 'local)
    (remove-hook 'comint-output-filter-functions
                 #'mys-shell-font-lock-comint-output-filter-function
                 'local)
    (when msg
      (message "Shell font-lock is disabled"))))

(defun mys-shell-font-lock-toggle (&optional msg)
  "Toggle font-lock for shell.
With argument MSG show activation/deactivation message."
  (interactive "p")
  (with-current-buffer (current-buffer)
    (set (make-local-variable 'mys-shell-fontify-p)
         (not mys-shell-fontify-p))
    (if mys-shell-fontify-p
        (mys-shell-font-lock-turn-on msg)
      (mys-shell-font-lock-turn-off msg))
    mys-shell-fontify-p))

(when (featurep 'comint-mime)
  (defun comint-mime-setup-mys-shell ()
    "Enable `comint-mime'.

Setup code specific to `mys-shell-mode'."
    (interactive)
    ;; (if (not mys-shell--first-prompt-received)
    ;; (add-hook 'mys-shell-first-prompt-hook #'comint-mime-setup-mys-shell nil t)
    (setq mys-mys-command "imys3"
          mys-imys-command "imys3"
          mys-imys-command-args '("--pylab" "--matplotlib=inline" "--automagic" "--simple-prompt")
          mys-mys-command-args '("--pylab" "--matplotlib=inline" "--automagic" "--simple-prompt"))
    (mys-send-string-no-output
     (format "%s\n__COMINT_MIME_setup('''%s''')"
             (with-temp-buffer
               (switch-to-buffer (current-buffer))
               (insert-file-contents
                (expand-file-name "comint-mime.py"
                                  comint-mime-setup-script-dir))
               (buffer-string))
             (if (listp comint-mime-enabled-types)
                 (string-join comint-mime-enabled-types ";")
               comint-mime-enabled-types))))

  (add-hook 'mys-shell-mode-hook 'comint-mime-setup-mys-shell)
  (push '(mys-shell-mode . comint-mime-setup-mys-shell)
	comint-mime-setup-function-alist)
  ;; (setq mys-mys-command "imys3"
  ;; 	mys-imys-command "imys3"
  ;; 	mys-mys-command-args '("--pylab" "--matplotlib=inline" "--automagic" "--simple-prompt")
  ;; 	;; "-i" doesn't work with `isympy3'
  ;; 	mys-imys-command-args '("--pylab" "--matplotlib=inline" "--automagic" "--simple-prompt"))
  )

;; mys-components-shift-forms


(defun mys-shift-left (&optional count start end)
  "Dedent region according to `mys-indent-offset' by COUNT times.

If no region is active, current line is dedented.
Return indentation reached
Optional COUNT: COUNT times `mys-indent-offset'
Optional START: region beginning
Optional END: region end"
  (interactive "p")
  (mys--shift-intern (- count) start end))

(defun mys-shift-right (&optional count beg end)
  "Indent region according to `mys-indent-offset' by COUNT times.

If no region is active, current line is indented.
Return indentation reached
Optional COUNT: COUNT times `mys-indent-offset'
Optional BEG: region beginning
Optional END: region end"
  (interactive "p")
  (mys--shift-intern count beg end))

(defun mys--shift-intern (count &optional start end)
  (save-excursion
    (let* ((inhibit-point-motion-hooks t)
           deactivate-mark
           (beg (cond (start)
                      ((use-region-p)
                       (save-excursion
                         (goto-char
                          (region-beginning))))
                      (t (line-beginning-position))))
           (end (cond (end)
                      ((use-region-p)
                       (save-excursion
                         (goto-char
                          (region-end))))
                      (t (line-end-position)))))
      (setq beg (comys-marker beg))
      (setq end (comys-marker end))
      (if (< 0 count)
          (indent-rigidly beg end mys-indent-offset)
        (indent-rigidly beg end (- mys-indent-offset)))
      (push-mark beg t)
      (goto-char end)
      (skip-chars-backward " \t\r\n\f"))
    (mys-indentation-of-statement)))

(defun mys--shift-forms-base (form arg &optional beg end)
  (let* ((begform (intern-soft (concat "mys-backward-" form)))
         (endform (intern-soft (concat "mys-forward-" form)))
         (orig (comys-marker (point)))
         (beg (cond (beg)
                    ((use-region-p)
                     (save-excursion
                       (goto-char (region-beginning))
                       (line-beginning-position)))
                    (t (save-excursion
                         (funcall begform)
                         (line-beginning-position)))))
         (end (cond (end)
                    ((use-region-p)
                     (region-end))
                    (t (funcall endform))))
         (erg (mys--shift-intern arg beg end)))
    (goto-char orig)
    erg))

(defun mys-shift-block-right (&optional arg)
  "Indent block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "block" (or arg mys-indent-offset)))

(defun mys-shift-block-left (&optional arg)
  "Dedent block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "block" (- (or arg mys-indent-offset))))

(defun mys-shift-block-or-clause-right (&optional arg)
  "Indent block-or-clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "block-or-clause" (or arg mys-indent-offset)))

(defun mys-shift-block-or-clause-left (&optional arg)
  "Dedent block-or-clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "block-or-clause" (- (or arg mys-indent-offset))))

(defun mys-shift-class-right (&optional arg)
  "Indent class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "class" (or arg mys-indent-offset)))

(defun mys-shift-class-left (&optional arg)
  "Dedent class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "class" (- (or arg mys-indent-offset))))

(defun mys-shift-clause-right (&optional arg)
  "Indent clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "clause" (or arg mys-indent-offset)))

(defun mys-shift-clause-left (&optional arg)
  "Dedent clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "clause" (- (or arg mys-indent-offset))))

(defun mys-shift-comment-right (&optional arg)
  "Indent comment by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "comment" (or arg mys-indent-offset)))

(defun mys-shift-comment-left (&optional arg)
  "Dedent comment by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "comment" (- (or arg mys-indent-offset))))

(defun mys-shift-def-right (&optional arg)
  "Indent def by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "def" (or arg mys-indent-offset)))

(defun mys-shift-def-left (&optional arg)
  "Dedent def by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "def" (- (or arg mys-indent-offset))))

(defun mys-shift-def-or-class-right (&optional arg)
  "Indent def-or-class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "def-or-class" (or arg mys-indent-offset)))

(defun mys-shift-def-or-class-left (&optional arg)
  "Dedent def-or-class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "def-or-class" (- (or arg mys-indent-offset))))

(defun mys-shift-indent-right (&optional arg)
  "Indent indent by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "indent" (or arg mys-indent-offset)))

(defun mys-shift-indent-left (&optional arg)
  "Dedent indent by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "indent" (- (or arg mys-indent-offset))))

(defun mys-shift-minor-block-right (&optional arg)
  "Indent minor-block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "minor-block" (or arg mys-indent-offset)))

(defun mys-shift-minor-block-left (&optional arg)
  "Dedent minor-block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "minor-block" (- (or arg mys-indent-offset))))

(defun mys-shift-paragraph-right (&optional arg)
  "Indent paragraph by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "paragraph" (or arg mys-indent-offset)))

(defun mys-shift-paragraph-left (&optional arg)
  "Dedent paragraph by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "paragraph" (- (or arg mys-indent-offset))))

(defun mys-shift-region-right (&optional arg)
  "Indent region by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "region" (or arg mys-indent-offset)))

(defun mys-shift-region-left (&optional arg)
  "Dedent region by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "region" (- (or arg mys-indent-offset))))

(defun mys-shift-statement-right (&optional arg)
  "Indent statement by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "statement" (or arg mys-indent-offset)))

(defun mys-shift-statement-left (&optional arg)
  "Dedent statement by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "statement" (- (or arg mys-indent-offset))))

(defun mys-shift-top-level-right (&optional arg)
  "Indent top-level by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "top-level" (or arg mys-indent-offset)))

(defun mys-shift-top-level-left (&optional arg)
  "Dedent top-level by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use \[universal-argument] to specify a different value.

Return outmost indentation reached."
  (interactive "*P")
  (mys--shift-forms-base "top-level" (- (or arg mys-indent-offset))))

;; mys-components-down


(defun mys-down-block (&optional indent)
  "Go to the beginning of next block downwards according to INDENT.

Return position if block found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-block-re indent))

(defun mys-down-class (&optional indent)
  "Go to the beginning of next class downwards according to INDENT.

Return position if class found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-class-re indent))

(defun mys-down-clause (&optional indent)
  "Go to the beginning of next clause downwards according to INDENT.

Return position if clause found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-clause-re indent))

(defun mys-down-block-or-clause (&optional indent)
  "Go to the beginning of next block-or-clause downwards according to INDENT.

Return position if block-or-clause found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-block-or-clause-re indent))

(defun mys-down-def (&optional indent)
  "Go to the beginning of next def downwards according to INDENT.

Return position if def found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-def-re indent))

(defun mys-down-def-or-class (&optional indent)
  "Go to the beginning of next def-or-class downwards according to INDENT.

Return position if def-or-class found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-def-or-class-re indent))

(defun mys-down-minor-block (&optional indent)
  "Go to the beginning of next minor-block downwards according to INDENT.

Return position if minor-block found, nil otherwise."
  (interactive)
  (mys-down-base 'mys-minor-block-re indent))

(defun mys-down-block-bol (&optional indent)
  "Go to the beginning of next block below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if block found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-block-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-class-bol (&optional indent)
  "Go to the beginning of next class below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if class found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-class-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-clause-bol (&optional indent)
  "Go to the beginning of next clause below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if clause found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-clause-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-block-or-clause-bol (&optional indent)
  "Go to the beginning of next block-or-clause below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if block-or-clause found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-block-or-clause-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-def-bol (&optional indent)
  "Go to the beginning of next def below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if def found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-def-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-def-or-class-bol (&optional indent)
  "Go to the beginning of next def-or-class below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if def-or-class found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-def-or-class-re indent t)
  (progn (beginning-of-line)(point)))

(defun mys-down-minor-block-bol (&optional indent)
  "Go to the beginning of next minor-block below according to INDENT.

Go to beginning of line
Optional INDENT: honor indentation
Return position if minor-block found, nil otherwise "
  (interactive)
  (mys-down-base 'mys-minor-block-re indent t)
  (progn (beginning-of-line)(point)))

;; mys-components-down.el ends here
;; mys-components-start-Zf98zM

(defun mys--end-base (regexp &optional orig bol repeat)
  "Used internal by functions going to the end FORM.

Returns the indentation of FORM-start
Arg REGEXP, a symbol"
  (unless (eobp)
    (let (;; not looking for an assignment
	  (use-regexp (member regexp (list 'mys-def-re 'mys-class-re 'mys-def-or-class-re)))
	  (orig (or orig (point))))
      (unless (eobp)
	(unless (mys-beginning-of-statement-p)
	  (mys-backward-statement))
	(let* (;; when at block-start, be specific
	       ;; (regexp (mys--refine-regexp-maybe regexp))
               (regexpvalue (symbol-value regexp))
               ;; (regexp (or regexp (symbol-value 'mys-extended-block-or-clause-re)))
	       (repeat (if repeat (1+ repeat) 0))
	       (indent (if
			   (looking-at regexpvalue)
			   (if (bolp) 0
			     (abs
			      (- (current-indentation) mys-indent-offset)))
			 (current-indentation)))
	       ;; when at block-start, be specific
	       ;; return current-indentation, position and possibly needed clause-regexps (secondvalue)
	       (res
		(cond
		 ((and (mys-beginning-of-statement-p)
		       ;; (eq 0 (current-column))
		       (or (looking-at regexpvalue)
			   (and (member regexp (list 'mys-def-re 'mys-def-or-class-re 'mys-class-re))
				(looking-at mys-decorator-re)
				(mys-down-def-or-class (current-indentation)))
			   (and (member regexp (list 'mys-minor-block-re 'mys-if-re 'mys-for-re 'mys-try-re))
				(looking-at mys-minor-clause-re))))
		  (list (current-indentation) (point) (mys--end-base-determine-secondvalue regexp)))
		 ((looking-at regexpvalue)
		  (list (current-indentation) (point) (mys--end-base-determine-secondvalue regexp)))
		 ((eq 0 (current-indentation))
		  (mys--down-according-to-indent regexp nil 0 use-regexp))
		 ;; look upward
		 (t (mys--go-to-keyword regexp))))
	       (secondvalue (ignore-errors (nth 2 res)))
	       erg)
	  ;; (mys-for-block-p (looking-at mys-for-re))
	  (setq indent (or (and res (car-safe res)) indent))
	  (cond
	   (res (setq erg
		      (and
		       (mys--down-according-to-indent regexp secondvalue (current-indentation))
		       ;; (if (>= indent (current-indentation))
		       (mys--down-end-form)
		       ;; (mys--end-base regexp orig bol repeat)
		       ;; )
		       )))
	   (t (unless (< 0 repeat) (goto-char orig))
	      (mys--forward-regexp (symbol-value regexp))
	      (beginning-of-line)
	      (setq erg (and
			 (mys--down-according-to-indent regexp secondvalue (current-indentation) t)
			 (mys--down-end-form)))))
	  (cond ((< orig (point))
		 (setq erg (point))
		 (progn
		   (and erg bol (setq erg (mys--beginning-of-line-form)))
		   (and erg (cons (current-indentation) erg))))
		((eq (point) orig)
		 (unless (eobp)
		   (cond
		    ((and (< repeat 1)
			  (or
			   ;; looking next indent as part of body
			   (mys--down-according-to-indent regexp secondvalue
							 indent
							 ;; if expected indent is 0,
							 ;; search for new start,
							 ;; search for regexp only
							 (eq 0 indent))
			   (and
			    ;; next block-start downwards, reduce expected indent maybe
			    (setq indent (or (and (< 0 indent) (- indent mys-indent-offset)) indent))
			    (mys--down-according-to-indent regexp secondvalue
							  indent t))))
		     (mys--end-base regexp orig bol (1+ repeat))))))
		((< (point) orig)
		 (goto-char orig)
		 (when (mys--down-according-to-indent regexp secondvalue nil t)
		   (mys--end-base regexp (point) bol (1+ repeat))))))))))


;; mys-components-start-Zf98zM.el ends here
;; mys-components-backward-forms

(defun mys-backward-region ()
  "Go to the beginning of current region."
  (interactive)
  (let ((beg (region-beginning)))
    (when beg (goto-char beg))))

(defun mys-backward-block ()
 "Go to beginning of `block'.

If already at beginning, go one `block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (let (erg)
    (setq erg (car-safe (cdr-safe (mys--go-to-keyword 'mys-block-re))))
    (when mys-mark-decorators (and (mys-backward-decorator)
                                                 (setq erg (point))))
    erg))

(defun mys-backward-class ()
 "Go to beginning of `class'.

If already at beginning, go one `class' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (let (erg)
    (setq erg (car-safe (cdr-safe (mys--go-to-keyword 'mys-class-re))))
    (when mys-mark-decorators (and (mys-backward-decorator)
                                                 (setq erg (point))))
    erg))

(defun mys-backward-def ()
 "Go to beginning of `def'.

If already at beginning, go one `def' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (let (erg)
    (setq erg (car-safe (cdr-safe (mys--go-to-keyword 'mys-def-re))))
    (when mys-mark-decorators (and (mys-backward-decorator)
                                                 (setq erg (point))))
    erg))

(defun mys-backward-def-or-class ()
 "Go to beginning of `def-or-class'.

If already at beginning, go one `def-or-class' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (let (erg)
    (setq erg (car-safe (cdr-safe (mys--go-to-keyword 'mys-def-or-class-re))))
    (when mys-mark-decorators (and (mys-backward-decorator)
                                                 (setq erg (point))))
    erg))

(defun mys-backward-block-bol ()
  "Go to beginning of `block', go to BOL.
If already at beginning, go one `block' backward.
Return beginning of `block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-block)
       (progn (beginning-of-line)(point))))

;;;###autoload
(defun mys-backward-class-bol ()
  "Go to beginning of `class', go to BOL.
If already at beginning, go one `class' backward.
Return beginning of `class' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-class)
       (progn (beginning-of-line)(point))))

;;;###autoload
(defun mys-backward-def-bol ()
  "Go to beginning of `def', go to BOL.
If already at beginning, go one `def' backward.
Return beginning of `def' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-def)
       (progn (beginning-of-line)(point))))

;;;###autoload
(defun mys-backward-def-or-class-bol ()
  "Go to beginning of `def-or-class', go to BOL.
If already at beginning, go one `def-or-class' backward.
Return beginning of `def-or-class' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-def-or-class)
       (progn (beginning-of-line)(point))))

(defun mys-backward-assignment ()
 "Go to beginning of `assignment'.

If already at beginning, go one `assignment' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-assignment-re))))

(defun mys-backward-block-or-clause ()
 "Go to beginning of `block-or-clause'.

If already at beginning, go one `block-or-clause' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-block-or-clause-re))))

(defun mys-backward-clause ()
 "Go to beginning of `clause'.

If already at beginning, go one `clause' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-clause-re))))

(defun mys-backward-elif-block ()
 "Go to beginning of `elif-block'.

If already at beginning, go one `elif-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-elif-re))))

(defun mys-backward-else-block ()
 "Go to beginning of `else-block'.

If already at beginning, go one `else-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-else-re))))

(defun mys-backward-except-block ()
 "Go to beginning of `except-block'.

If already at beginning, go one `except-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-except-re))))

(defun mys-backward-for-block ()
 "Go to beginning of `for-block'.

If already at beginning, go one `for-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-for-re))))

(defun mys-backward-if-block ()
 "Go to beginning of `if-block'.

If already at beginning, go one `if-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-if-re))))

(defun mys-backward-minor-block ()
 "Go to beginning of `minor-block'.

If already at beginning, go one `minor-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-minor-block-re))))

(defun mys-backward-try-block ()
 "Go to beginning of `try-block'.

If already at beginning, go one `try-block' backward.
Return beginning of form if successful, nil otherwise"
  (interactive)
  (car-safe (cdr-safe (mys--go-to-keyword 'mys-try-re))))

(defun mys-backward-assignment-bol ()
  "Go to beginning of `assignment', go to BOL.
If already at beginning, go one `assignment' backward.
Return beginning of `assignment' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-assignment)
       (progn (beginning-of-line)(point))))

(defun mys-backward-block-or-clause-bol ()
  "Go to beginning of `block-or-clause', go to BOL.
If already at beginning, go one `block-or-clause' backward.
Return beginning of `block-or-clause' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-block-or-clause)
       (progn (beginning-of-line)(point))))

(defun mys-backward-clause-bol ()
  "Go to beginning of `clause', go to BOL.
If already at beginning, go one `clause' backward.
Return beginning of `clause' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-clause)
       (progn (beginning-of-line)(point))))

(defun mys-backward-elif-block-bol ()
  "Go to beginning of `elif-block', go to BOL.
If already at beginning, go one `elif-block' backward.
Return beginning of `elif-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-elif-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-else-block-bol ()
  "Go to beginning of `else-block', go to BOL.
If already at beginning, go one `else-block' backward.
Return beginning of `else-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-else-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-except-block-bol ()
  "Go to beginning of `except-block', go to BOL.
If already at beginning, go one `except-block' backward.
Return beginning of `except-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-except-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-for-block-bol ()
  "Go to beginning of `for-block', go to BOL.
If already at beginning, go one `for-block' backward.
Return beginning of `for-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-for-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-if-block-bol ()
  "Go to beginning of `if-block', go to BOL.
If already at beginning, go one `if-block' backward.
Return beginning of `if-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-if-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-minor-block-bol ()
  "Go to beginning of `minor-block', go to BOL.
If already at beginning, go one `minor-block' backward.
Return beginning of `minor-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-minor-block)
       (progn (beginning-of-line)(point))))

(defun mys-backward-try-block-bol ()
  "Go to beginning of `try-block', go to BOL.
If already at beginning, go one `try-block' backward.
Return beginning of `try-block' if successful, nil otherwise"
  (interactive)
  (and (mys-backward-try-block)
       (progn (beginning-of-line)(point))))

;; mys-components-forward-forms


(defun mys-forward-assignment (&optional orig bol)
  "Go to end of assignment.

Return end of `assignment' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-assignment-re orig bol)))

(defun mys-forward-assignment-bol ()
  "Goto beginning of line following end of `assignment'.

Return position reached, if successful, nil otherwise.
See also `mys-down-assignment'."
  (interactive)
  (mys-forward-assignment nil t))

(defun mys-forward-region ()
  "Go to the end of current region."
  (interactive)
  (let ((end (region-end)))
    (when end (goto-char end))))

(defun mys-forward-block (&optional orig bol)
  "Go to end of block.

Return end of `block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-block-re orig bol)))

(defun mys-forward-block-bol ()
  "Goto beginning of line following end of `block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-block'."
  (interactive)
  (mys-forward-block nil t))

(defun mys-forward-block-or-clause (&optional orig bol)
  "Go to end of block-or-clause.

Return end of `block-or-clause' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-block-or-clause-re orig bol)))

(defun mys-forward-block-or-clause-bol ()
  "Goto beginning of line following end of `block-or-clause'.

Return position reached, if successful, nil otherwise.
See also `mys-down-block-or-clause'."
  (interactive)
  (mys-forward-block-or-clause nil t))

(defun mys-forward-class (&optional orig bol)
  "Go to end of class.

Return end of `class' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-class-re orig bol)))

(defun mys-forward-class-bol ()
  "Goto beginning of line following end of `class'.

Return position reached, if successful, nil otherwise.
See also `mys-down-class'."
  (interactive)
  (mys-forward-class nil t))

(defun mys-forward-clause (&optional orig bol)
  "Go to end of clause.

Return end of `clause' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-clause-re orig bol)))

(defun mys-forward-clause-bol ()
  "Goto beginning of line following end of `clause'.

Return position reached, if successful, nil otherwise.
See also `mys-down-clause'."
  (interactive)
  (mys-forward-clause nil t))

(defun mys-forward-def (&optional orig bol)
  "Go to end of def.

Return end of `def' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-def-re orig bol)))

(defun mys-forward-def-bol ()
  "Goto beginning of line following end of `def'.

Return position reached, if successful, nil otherwise.
See also `mys-down-def'."
  (interactive)
  (mys-forward-def nil t))

(defun mys-forward-def-or-class (&optional orig bol)
  "Go to end of def-or-class.

Return end of `def-or-class' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-def-or-class-re orig bol)))

(defun mys-forward-def-or-class-bol ()
  "Goto beginning of line following end of `def-or-class'.

Return position reached, if successful, nil otherwise.
See also `mys-down-def-or-class'."
  (interactive)
  (mys-forward-def-or-class nil t))

(defun mys-forward-elif-block (&optional orig bol)
  "Go to end of elif-block.

Return end of `elif-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-elif-re orig bol)))

(defun mys-forward-elif-block-bol ()
  "Goto beginning of line following end of `elif-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-elif-block'."
  (interactive)
  (mys-forward-elif-block nil t))

(defun mys-forward-else-block (&optional orig bol)
  "Go to end of else-block.

Return end of `else-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-else-re orig bol)))

(defun mys-forward-else-block-bol ()
  "Goto beginning of line following end of `else-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-else-block'."
  (interactive)
  (mys-forward-else-block nil t))

(defun mys-forward-except-block (&optional orig bol)
  "Go to end of except-block.

Return end of `except-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-except-re orig bol)))

(defun mys-forward-except-block-bol ()
  "Goto beginning of line following end of `except-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-except-block'."
  (interactive)
  (mys-forward-except-block nil t))

(defun mys-forward-for-block (&optional orig bol)
  "Go to end of for-block.

Return end of `for-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-for-re orig bol)))

(defun mys-forward-for-block-bol ()
  "Goto beginning of line following end of `for-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-for-block'."
  (interactive)
  (mys-forward-for-block nil t))

(defun mys-forward-if-block (&optional orig bol)
  "Go to end of if-block.

Return end of `if-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-if-re orig bol)))

(defun mys-forward-if-block-bol ()
  "Goto beginning of line following end of `if-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-if-block'."
  (interactive)
  (mys-forward-if-block nil t))

(defun mys-forward-minor-block (&optional orig bol)
  "Go to end of minor-block.

Return end of `minor-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-minor-block-re orig bol)))

(defun mys-forward-minor-block-bol ()
  "Goto beginning of line following end of `minor-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-minor-block'."
  (interactive)
  (mys-forward-minor-block nil t))

(defun mys-forward-try-block (&optional orig bol)
  "Go to end of try-block.

Return end of `try-block' if successful, nil otherwise
Optional ORIG: start position
Optional BOL: go to beginning of line following end-position"
  (interactive)
  (cdr-safe (mys--end-base 'mys-try-re orig bol)))

(defun mys-forward-try-block-bol ()
  "Goto beginning of line following end of `try-block'.

Return position reached, if successful, nil otherwise.
See also `mys-down-try-block'."
  (interactive)
  (mys-forward-try-block nil t))

;; mys-components-forward-forms.el ends here
;; mys-components-start2


(defun mys--fix-start (strg)
  "Internal use by mys-execute... functions.

Takes STRG
Avoid empty lines at the beginning."
  ;; (when mys-debug-p (message "mys--fix-start:"))
  (let (mys--imenu-create-index-p
	mys-guess-mys-install-directory-p
	mys-autopair-mode
	mys-complete-function
	mys-load-pymacs-p
	mys-load-skeletons-p
	erg)
    (with-temp-buffer
      (with-current-buffer (current-buffer)
	(when mys-debug-p
	  (switch-to-buffer (current-buffer)))
	;; (mys-mode)
	(insert strg)
	(goto-char (point-min))
	(when (< 0 (setq erg (skip-chars-forward " \t\r\n\f" (line-end-position))))
	  (dotimes (_ erg)
	    (indent-rigidly-left (point-min) (point-max))))
	(unless (mys--beginning-of-statement-p)
	  (mys-forward-statement))
	(while (not (eq (current-indentation) 0))
	  (mys-shift-left mys-indent-offset))
	(goto-char (point-max))
	(unless (mys-empty-line-p)
	  (newline 1))
	(buffer-substring-no-properties 1 (point-max))))))

(defun mys-fast-send-string (strg  &optional proc output-buffer result no-output argprompt args dedicated shell exception-buffer)
  (interactive
   (list (read-string "Python command: ")))
  (mys-execute-string strg proc result no-output nil output-buffer t argprompt args dedicated shell exception-buffer))

(defun mys--fast-send-string-no-output (strg  &optional proc output-buffer result)
  (mys-fast-send-string strg proc output-buffer result t))

(defun mys--send-to-fast-process (strg proc output-buffer result)
  "Called inside of `mys--execute-base-intern'.

Optional STRG PROC OUTPUT-BUFFER RETURN"
  (let ((output-buffer (or output-buffer (process-buffer proc)))
	(inhibit-read-only t))
    ;; (switch-to-buffer (current-buffer))
    (with-current-buffer output-buffer
      ;; (erase-buffer)
      (mys-fast-send-string strg
			   proc
			   output-buffer result))))

(defun mys--point (position)
  "Returns the value of point at certain commonly referenced POSITIONs.
POSITION can be one of the following symbols:

  bol -- beginning of line
  eol -- end of line
  bod -- beginning of def or class
  eod -- end of def or class
  bob -- beginning of buffer
  eob -- end of buffer
  boi -- back to indentation
  bos -- beginning of statement

This function does not modify point or mark."
  (save-excursion
    (progn
      (cond
       ((eq position 'bol) (beginning-of-line))
       ((eq position 'eol) (end-of-line))
       ((eq position 'bod) (mys-backward-def-or-class))
       ((eq position 'eod) (mys-forward-def-or-class))
       ;; Kind of funny, I know, but useful for mys-up-exception.
       ((eq position 'bob) (goto-char (point-min)))
       ((eq position 'eob) (goto-char (point-max)))
       ((eq position 'boi) (back-to-indentation))
       ((eq position 'bos) (mys-backward-statement))
       (t (error "Unknown buffer position requested: %s" position))))))

(defun mys-backward-top-level ()
  "Go up to beginning of statments until level of indentation is null.

Returns position if successful, nil otherwise "
  (interactive)
  (let (erg done)
    (unless (bobp)
      (while (and (not done)(not (bobp))
                  (setq erg (re-search-backward "^[[:alpha:]_'\"]" nil t 1)))
        (if
            (nth 8 (parse-partial-sexp (point-min) (point)))
            (setq erg nil)
          (setq done t)))
      erg)))

;; might be slow due to repeated calls of `mys-down-statement'
(defun mys-forward-top-level ()
  "Go to end of top-level form at point.

Returns position if successful, nil otherwise"
  (interactive)
  (let ((orig (point))
        erg)
    (unless (eobp)
      (unless (mys--beginning-of-statement-p)
        (mys-backward-statement))
      (unless (eq 0 (current-column))
        (mys-backward-top-level))
      (cond ((looking-at mys-def-re)
             (setq erg (mys-forward-def)))
            ((looking-at mys-class-re)
             (setq erg (mys-forward-class)))
            ((looking-at mys-block-re)
             (setq erg (mys-forward-block)))
            (t (setq erg (mys-forward-statement))))
      (unless (< orig (point))
        (while (and (not (eobp)) (mys-down-statement)(< 0 (current-indentation))))
        (if (looking-at mys-block-re)
            (setq erg (mys-forward-block))
          (setq erg (mys-forward-statement))))
      erg)))

;; mys-components-start3

(defun toggle-force-mys-shell-name-p (&optional arg)
  "If customized default `mys-shell-name' should be enforced upon execution.

If `mys-force-mys-shell-name-p' should be on or off.
Returns value of `mys-force-mys-shell-name-p' switched to.

Optional ARG
See also commands
`force-mys-shell-name-p-on'
`force-mys-shell-name-p-off'

Caveat: Completion might not work that way."
  (interactive)
  (let ((arg (or arg (if mys-force-mys-shell-name-p -1 1))))
    (if (< 0 arg)
        (setq mys-force-mys-shell-name-p t)
      (setq mys-force-mys-shell-name-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-force-mys-shell-name-p: %s" mys-force-mys-shell-name-p))
    mys-force-mys-shell-name-p))

(defun force-mys-shell-name-p-on ()
  "Switch `mys-force-mys-shell-name-p' on.

Customized default `mys-shell-name' will be enforced upon execution.
Returns value of `mys-force-mys-shell-name-p'.

Caveat: Completion might not work that way."
  (interactive)
  (toggle-force-mys-shell-name-p 1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-force-mys-shell-name-p: %s" mys-force-mys-shell-name-p))
  mys-force-mys-shell-name-p)

(defun force-mys-shell-name-p-off ()
  "Make sure, `mys-force-mys-shell-name-p' is off.

Function to use by executes will be guessed from environment.
Returns value of `mys-force-mys-shell-name-p'."
  (interactive)
  (toggle-force-mys-shell-name-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-force-mys-shell-name-p: %s" mys-force-mys-shell-name-p))
  mys-force-mys-shell-name-p)

(defun mys--fix-if-name-main-permission (strg)
  "Remove \"if __name__ == '__main__ '\" STRG from code to execute.

See `mys-if-name-main-permission-p'"
  (let ((strg (if mys-if-name-main-permission-p strg
		(replace-regexp-in-string
		 "if[( ]*__name__[) ]*==[( ]*['\"]\\{1,3\\}__main__['\"]\\{1,3\\}[) ]*:"
		 ;; space after __main__, i.e. will not be executed
		 "if __name__ == '__main__ ':" strg))))
    strg))

(defun mys-symbol-at-point ()
  "Return the current Python symbol.

When interactively called, copy and message it"
  (interactive)
  (let ((erg (with-syntax-table
                 mys-dotted-expression-syntax-table
               (current-word))))
    (when (called-interactively-p 'interactive) (kill-new erg)
	  (message "%s" erg))
    erg))

(defun mys--line-backward-maybe ()
  "Return result of (< 0 (abs (skip-chars-backward \" \\t\\r\\n\\f\"))) "
  (skip-chars-backward " \t\f" (line-beginning-position))
  (< 0 (abs (skip-chars-backward " \t\r\n\f"))))

(defun mys--after-empty-line ()
  "Return `t' if line before contains only whitespace characters. "
  (save-excursion
    (beginning-of-line)
    (forward-line -1)
    (beginning-of-line)
    (looking-at "\\s-*$")))

(defun mys-guessed-sanity-check (guessed)
  (and (>= guessed 2)(<= guessed 8)(eq 0 (% guessed 2))))

(defun mys--guess-indent-final (indents)
  "Calculate and do sanity-check.

Expects INDENTS, a cons"
  (let* ((first (car indents))
         (second (cadr indents))
         (erg (if (and first second)
                  (if (< second first)
                      (- first second)
                    (- second first))
                (default-value 'mys-indent-offset))))
    (setq erg (and (mys-guessed-sanity-check erg) erg))
    erg))

(defun mys--guess-indent-forward ()
  "Called when moving to end of a form and `mys-smart-indentation' is on."
  (let* ((first (if
                    (mys--beginning-of-statement-p)
                    (current-indentation)
                  (progn
                    (mys-forward-statement)
                    (mys-backward-statement)
                    (current-indentation))))
         (second (if (or (looking-at mys-extended-block-or-clause-re)(eq 0 first))
                     (progn
                       (mys-forward-statement)
                       (mys-forward-statement)
                       (mys-backward-statement)
                       (current-indentation))
                   ;; when not starting from block, look above
                   (while (and (re-search-backward mys-extended-block-or-clause-re nil 'movet 1)
                               (or (>= (current-indentation) first)
                                   (nth 8 (parse-partial-sexp (point-min) (point))))))
                   (current-indentation))))
    (list first second)))

(defun mys--guess-indent-backward ()
  "Called when moving to beginning of a form and `mys-smart-indentation' is on."
  (let* ((cui (current-indentation))
         (indent (if (< 0 cui) cui 999))
         (pos (progn (while (and (re-search-backward mys-extended-block-or-clause-re nil 'move 1)
                                 (or (>= (current-indentation) indent)
                                     (nth 8 (parse-partial-sexp (point-min) (point))))))
                     (unless (bobp) (point))))
         (first (and pos (current-indentation)))
         (second (and pos (mys-forward-statement) (mys-forward-statement) (mys-backward-statement)(current-indentation))))
    (list first second)))

(defun mys-guess-indent-offset (&optional direction)
  "Guess `mys-indent-offset'.

Set local value of `mys-indent-offset', return it

Might change local value of `mys-indent-offset' only when called
downwards from beginning of block followed by a statement.
Otherwise `default-value' is returned.
Unless DIRECTION is symbol \\='forward, go backward first"
  (interactive)
  (save-excursion
    (let* ((indents
            (cond (direction
                   (if (eq 'forward direction)
                       (mys--guess-indent-forward)
                     (mys--guess-indent-backward)))
                  ;; guess some usable indent is above current position
                  ((eq 0 (current-indentation))
                   (mys--guess-indent-forward))
                  (t (mys--guess-indent-backward))))
           (erg (mys--guess-indent-final indents)))
      (if erg (setq mys-indent-offset erg)
        (setq mys-indent-offset
              (default-value 'mys-indent-offset)))
      (when (called-interactively-p 'any) (message "%s" mys-indent-offset))
      mys-indent-offset)))

(defun mys--execute-buffer-finally (strg proc procbuf origline filename fast wholebuf)
  (if (and filename wholebuf (not (buffer-modified-p)))
      (unwind-protect
	  (mys--execute-file-base filename proc nil procbuf origline fast))
    (let* ((tempfile (concat (expand-file-name mys-temp-directory) mys-separator-char "temp" (md5 (format "%s" (nth 3 (current-time)))) ".py")))
      (with-temp-buffer
	(insert strg)
	(write-file tempfile))
      (unwind-protect
	  (mys--execute-file-base tempfile proc nil procbuf origline fast)
	(and (file-readable-p tempfile) (delete-file tempfile mys-debug-p))))))

(defun mys--postprocess-intern (&optional origline exception-buffer output-buffer)
  "Highlight exceptions found in BUF.

Optional ORIGLINE EXCEPTION-BUFFER
If an exception occurred return error-string,
otherwise return nil.
BUF must exist.

Indicate LINE if code wasn't run from a file,
thus remember line of source buffer"
  (save-excursion
    (with-current-buffer output-buffer
      (let* (estring ecode erg)
	;; (switch-to-buffer (current-buffer))
	(goto-char (point-max))
	(sit-for 0.1)
	(save-excursion
	  (unless (looking-back mys-pdbtrack-input-prompt (line-beginning-position))
	    (forward-line -1)
	    (end-of-line)
	    (when (re-search-backward mys-shell-prompt-regexp t 1)
		;; (or (re-search-backward mys-shell-prompt-regexp nil t 1)
		;; (re-search-backward (concat mys-imys-input-prompt-re "\\|" mys-imys-output-prompt-re) nil t 1))
	      (save-excursion
		(when (re-search-forward "File \"\\(.+\\)\", line \\([0-9]+\\)\\(.*\\)$" nil t)
		  (setq erg (comys-marker (point)))
		  (delete-region (progn (beginning-of-line)
					(save-match-data
					  (when (looking-at
						 ;; all prompt-regexp known
						 mys-shell-prompt-regexp)
					    (goto-char (match-end 0)))))

					(progn (skip-chars-forward " \t\r\n\f"   (line-end-position))(point)))
		  (insert (concat "    File " (buffer-name exception-buffer) ", line "
				  (prin1-to-string origline)))))
	      ;; these are let-bound as `tempbuf'
	      (and (boundp 'tempbuf)
		   ;; (message "%s" tempbuf)
		   (search-forward (buffer-name tempbuf) nil t)
		   (delete-region (line-beginning-position) (1+ (line-end-position))))
	      ;; if no buffer-file exists, signal "Buffer", not "File(when
	      (when erg
		(goto-char erg)
		;; (forward-char -1)
		;; (skip-chars-backward "^\t\r\n\f")
		;; (skip-chars-forward " \t")
		(save-match-data
		  (and (not (mys--buffer-filename-remote-maybe
			     (or
			      (get-buffer exception-buffer)
			      (get-buffer (file-name-nondirectory exception-buffer)))))
		       (string-match "^[ \t]*File" (buffer-substring-no-properties (point) (line-end-position)))
		       (looking-at "[ \t]*File")
		       (replace-match " Buffer")))
		(push origline mys-error)
		(push (buffer-name exception-buffer) mys-error)
		(forward-line 1)
		(when (looking-at "[ \t]*\\([^\t\n\r\f]+\\)[ \t]*$")
		  (setq estring (match-string-no-properties 1))
		  (setq ecode (replace-regexp-in-string "[ \n\t\f\r^]+" " " estring))
		  (push 'mys-error ecode))))))
	mys-error))))

(defun mys-execute-mys-mode-v5 (start end origline filename)
  "Take START END &optional EXCEPTION-BUFFER ORIGLINE."
  (interactive "r")
  (let ((output-buffer "*Python Output*")
	(mys-split-window-on-execute 'just-two)
	(pcmd (concat mys-shell-name (if (string-equal mys-which-bufname
                                                      "Jython")
                                        " -"
                                      ;; " -c "
                                      ""))))
    (save-excursion
      (shell-command-on-region start end
                               pcmd output-buffer))
    (if (not (get-buffer output-buffer))
        (message "No output.")
      (setq mys-result (mys--fetch-result (get-buffer  output-buffer) nil))
      (if (string-match "Traceback" mys-result)
	  (message "%s" (setq mys-error (mys--fetch-error output-buffer origline filename)))
	mys-result))))

(defun mys--execute-ge24.3 (start end execute-directory which-shell &optional exception-buffer proc file origline)
  "An alternative way to do it.

According to START END EXECUTE-DIRECTORY WHICH-SHELL
Optional EXCEPTION-BUFFER PROC FILE ORIGLINE
May we get rid of the temporary file?"
  (and (mys--buffer-filename-remote-maybe) buffer-offer-save (buffer-modified-p (mys--buffer-filename-remote-maybe)) (y-or-n-p "Save buffer before executing? ")
       (write-file (mys--buffer-filename-remote-maybe)))
  (let* ((start (comys-marker start))
         (end (comys-marker end))
         (exception-buffer (or exception-buffer (current-buffer)))
         (line (mys-count-lines (point-min) (if (eq start (line-beginning-position)) (1+ start) start)))
         (strg (buffer-substring-no-properties start end))
         (tempfile (or (mys--buffer-filename-remote-maybe) (concat (expand-file-name mys-temp-directory) mys-separator-char (replace-regexp-in-string mys-separator-char "-" "temp") ".py")))

         (proc (or proc (if mys-dedicated-process-p
                            (get-buffer-process (mys-shell nil nil t which-shell))
                          (or (get-buffer-process mys-buffer-name)
                              (get-buffer-process (mys-shell nil nil mys-dedicated-process-p which-shell mys-buffer-name))))))
         (procbuf (process-buffer proc))
         (file (or file (with-current-buffer mys-buffer-name
                          (concat (file-remote-p default-directory) tempfile))))
         (filebuf (get-buffer-create file)))
    (set-buffer filebuf)
    (erase-buffer)
    (newline line)
    (save-excursion
      (insert strg))
    (mys--fix-start (buffer-substring-no-properties (point) (point-max)))
    (unless (string-match "[jJ]ython" which-shell)
      ;; (when (and execute-directory mys-use-current-dir-when-execute-p
      ;; (not (string= execute-directory default-directory)))
      ;; (message "Warning: options `execute-directory' and `mys-use-current-dir-when-execute-p' may conflict"))
      (and execute-directory
           (process-send-string proc (concat "import os; os.chdir(\"" execute-directory "\")\n"))))
    (set-buffer filebuf)
    (process-send-string proc
                         (buffer-substring-no-properties
                          (point-min) (point-max)))
    (sit-for 0.1 t)
    (if (and (setq mys-error (save-excursion (mys--postprocess-intern origline exception-buffer)))
             (car mys-error)
             (not (markerp mys-error)))
        (mys--jump-to-exception mys-error origline)
      (unless (string= (buffer-name (current-buffer)) (buffer-name procbuf))
        (when mys-verbose-p (message "Output buffer: %s" procbuf))))))

(defun mys--execute-base-intern (strg filename proc wholebuf buffer origline execute-directory start end &optional fast)
  "Select the handler according to:

STRG FILENAME PROC FILE WHOLEBUF
BUFFER ORIGLINE EXECUTE-DIRECTORY START END WHICH-SHELL
Optional FAST RETURN"
  (setq mys-error nil)
  (cond ;; (fast (mys-fast-send-string strg proc buffer result))
   ;; enforce proceeding as mys-mode.el v5
   (mys-mode-v5-behavior-p
    (mys-execute-mys-mode-v5 start end origline filename))
   (mys-execute-no-temp-p
    (mys--execute-ge24.3 start end execute-directory mys-shell-name mys-exception-buffer proc filename origline))
   ((and filename wholebuf)
    (mys--execute-file-base filename proc nil buffer origline fast))
   (t
    ;; (message "(current-buffer) %s" (current-buffer))
    (mys--execute-buffer-finally strg proc buffer origline filename fast wholebuf)
    ;; (mys--delete-temp-file tempfile)
    )))

(defun mys--execute-base (&optional start end shell filename proc wholebuf fast dedicated split switch)
  "Update optional variables.
START END SHELL FILENAME PROC FILE WHOLEBUF FAST DEDICATED SPLIT SWITCH."
  (setq mys-error nil)
  (when mys-debug-p (message "mys--execute-base: (current-buffer): %s" (current-buffer)))
  ;; (when (or fast mys-fast-process-p) (ignore-errors (mys-kill-buffer-unconditional mys-output-buffer)))
  (let* ((orig (point))
	 (fast (or fast mys-fast-process-p))
	 (exception-buffer (current-buffer))
	 (start (or start (and (use-region-p) (region-beginning)) (point-min)))
	 (end (or end (and (use-region-p) (region-end)) (point-max)))
	 (strg-raw (if mys-if-name-main-permission-p
		       (buffer-substring-no-properties start end)
		     (mys--fix-if-name-main-permission (buffer-substring-no-properties start end))))
	 (strg (mys--fix-start strg-raw))
	 (wholebuf (unless filename (or wholebuf (and (eq (buffer-size) (- end start))))))
	 ;; error messages may mention differently when running from a temp-file
	 (origline
	  (format "%s" (save-restriction
			 (widen)
			 (mys-count-lines (point-min) orig))))
	 ;; argument SHELL might be a string like "python", "Imys" "python3", a symbol holding PATH/TO/EXECUTABLE or just a symbol like 'python3
	 (shell (or
		 (and shell
		      ;; shell might be specified in different ways
		      (or (and (stringp shell) shell)
			  (ignore-errors (eval shell))
			  (and (symbolp shell) (format "%s" shell))))
		 ;; (save-excursion
		 (mys-choose-shell)
		 ;;)
		 ))
	 (shell (or shell (mys-choose-shell)))
	 (buffer-name
	  (mys--choose-buffer-name shell dedicated fast))
	 (execute-directory
	  (cond ((ignore-errors (file-name-directory (file-remote-p (buffer-file-name) 'localname))))
		((and mys-use-current-dir-when-execute-p (buffer-file-name))
		 (file-name-directory (buffer-file-name)))
		((and mys-use-current-dir-when-execute-p
		      mys-fileless-buffer-use-default-directory-p)
		 (expand-file-name default-directory))
		((stringp mys-execute-directory)
		 mys-execute-directory)
		((getenv "VIRTUAL_ENV"))
		(t (getenv "HOME"))))
	 (filename (or (and filename (expand-file-name filename))
		       (mys--buffer-filename-remote-maybe)))
	 (mys-orig-buffer-or-file (or filename (current-buffer)))
	 (proc-raw (or proc (get-buffer-process buffer-name)))

	 (proc (or proc-raw (get-buffer-process buffer-name)
		   (prog1
		       (get-buffer-process (mys-shell nil nil dedicated shell buffer-name fast exception-buffer split switch))
		     (sit-for 1)
		     )))
	 (split (if mys-mode-v5-behavior-p 'just-two split)))
    (setq mys-output-buffer (or (and mys-mode-v5-behavior-p mys-output-buffer) (and proc (buffer-name (process-buffer proc)))
			       (mys--choose-buffer-name shell dedicated fast)))
    (mys--execute-base-intern strg filename proc wholebuf mys-output-buffer origline execute-directory start end fast)
    (when (or split mys-split-window-on-execute mys-switch-buffers-on-execute-p)
      (mys--shell-manage-windows mys-output-buffer exception-buffer (or split mys-split-window-on-execute) switch))))

;; mys-components-execute-file

;; Execute file given

(defun mys-execute-file-imys (filename)
  "Send file to Imys interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "imys" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-imys3 (filename)
  "Send file to Imys3 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "imys3" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-jython (filename)
  "Send file to Jython interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "jython" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-python (filename)
  "Send file to Python interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "python" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-python2 (filename)
  "Send file to Python2 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "python2" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-python3 (filename)
  "Send file to Python3 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "python3" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-pypy (filename)
  "Send file to PyPy interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "pypy" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file- (filename)
  "Send file to  interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil nil "" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-imys-dedicated (filename)
  "Send file to a dedicatedImys interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "imys" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-imys3-dedicated (filename)
  "Send file to a dedicatedImys3 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "imys3" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-jython-dedicated (filename)
  "Send file to a dedicatedJython interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "jython" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-mys-dedicated (filename)
  "Send file to a dedicatedPython interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "python" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-python2-dedicated (filename)
  "Send file to a dedicatedPython2 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "python2" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-python3-dedicated (filename)
  "Send file to a dedicatedPython3 interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "python3" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file-pymys-dedicated (filename)
  "Send file to a dedicatedPyPy interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "pypy" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

(defun mys-execute-file--dedicated (filename)
  "Send file to a dedicated interpreter"
  (interactive "fFile: ")
  (let ((interactivep (called-interactively-p 'interactive))
        (buffer (mys-shell nil nil t "" nil t)))
    (mys--execute-file-base filename (get-buffer-process buffer) nil buffer nil t interactivep)))

;; mys-components-up


(defun mys-up-block (&optional indent)
  "Go to the beginning of next block upwards according to INDENT.
Optional INDENT
Return position if block found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-block-re indent))

(defun mys-up-class (&optional indent)
  "Go to the beginning of next class upwards according to INDENT.
Optional INDENT
Return position if class found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-class-re indent))

(defun mys-up-clause (&optional indent)
  "Go to the beginning of next clause upwards according to INDENT.
Optional INDENT
Return position if clause found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-clause-re indent))

(defun mys-up-block-or-clause (&optional indent)
  "Go to the beginning of next block-or-clause upwards according to INDENT.
Optional INDENT
Return position if block-or-clause found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-block-or-clause-re indent))

(defun mys-up-def (&optional indent)
  "Go to the beginning of next def upwards according to INDENT.
Optional INDENT
Return position if def found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-def-re indent))

(defun mys-up-def-or-class (&optional indent)
  "Go to the beginning of next def-or-class upwards according to INDENT.
Optional INDENT
Return position if def-or-class found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-def-or-class-re indent))

(defun mys-up-minor-block (&optional indent)
  "Go to the beginning of next minor-block upwards according to INDENT.
Optional INDENT
Return position if minor-block found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-minor-block-re indent))

(defun mys-up-block-bol (&optional indent)
  "Go to the beginning of next block upwards according to INDENT.

Go to beginning of line.
Return position if block found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-block-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-class-bol (&optional indent)
  "Go to the beginning of next class upwards according to INDENT.

Go to beginning of line.
Return position if class found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-class-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-clause-bol (&optional indent)
  "Go to the beginning of next clause upwards according to INDENT.

Go to beginning of line.
Return position if clause found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-clause-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-block-or-clause-bol (&optional indent)
  "Go to the beginning of next block-or-clause upwards according to INDENT.

Go to beginning of line.
Return position if block-or-clause found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-block-or-clause-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-def-bol (&optional indent)
  "Go to the beginning of next def upwards according to INDENT.

Go to beginning of line.
Return position if def found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-def-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-def-or-class-bol (&optional indent)
  "Go to the beginning of next def-or-class upwards according to INDENT.

Go to beginning of line.
Return position if def-or-class found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-def-or-class-re indent)
  (progn (beginning-of-line)(point)))

(defun mys-up-minor-block-bol (&optional indent)
  "Go to the beginning of next minor-block upwards according to INDENT.

Go to beginning of line.
Return position if minor-block found, nil otherwise."
  (interactive)
  (mys-up-base 'mys-minor-block-re indent)
  (progn (beginning-of-line)(point)))

;; mys-components-up.el ends here
;; mys-components-booleans-beginning-forms

(defun mys--beginning-of-comment-p (&optional pps)
  "If cursor is at the beginning of a `comment'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-comment-re))
         (point))))

(defun mys--beginning-of-expression-p (&optional pps)
  "If cursor is at the beginning of a `expression'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-expression-re))
         (point))))

(defun mys--beginning-of-line-p (&optional pps)
  "If cursor is at the beginning of a `line'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-line-re))
         (point))))

(defun mys--beginning-of-paragraph-p (&optional pps)
  "If cursor is at the beginning of a `paragraph'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-paragraph-re))
         (point))))

(defun mys--beginning-of-partial-expression-p (&optional pps)
  "If cursor is at the beginning of a `partial-expression'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-partial-expression-re))
         (point))))

(defun mys--beginning-of-section-p (&optional pps)
  "If cursor is at the beginning of a `section'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-section-re))
         (point))))

(defun mys--beginning-of-top-level-p (&optional pps)
  "If cursor is at the beginning of a `top-level'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at (concat "\\b" mys-top-level-re))
         (point))))

(defun mys--beginning-of-assignment-p (&optional pps)
  "If cursor is at the beginning of a `assignment'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-assignment-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-block-p (&optional pps)
  "If cursor is at the beginning of a `block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-block-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-block-or-clause-p (&optional pps)
  "If cursor is at the beginning of a `block-or-clause'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-block-or-clause-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-class-p (&optional pps)
  "If cursor is at the beginning of a `class'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-class-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-clause-p (&optional pps)
  "If cursor is at the beginning of a `clause'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-clause-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-def-p (&optional pps)
  "If cursor is at the beginning of a `def'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-def-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-def-or-class-p (&optional pps)
  "If cursor is at the beginning of a `def-or-class'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-def-or-class-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-elif-block-p (&optional pps)
  "If cursor is at the beginning of a `elif-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-elif-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-else-block-p (&optional pps)
  "If cursor is at the beginning of a `else-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-else-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-except-block-p (&optional pps)
  "If cursor is at the beginning of a `except-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-except-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-for-block-p (&optional pps)
  "If cursor is at the beginning of a `for-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-for-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-if-block-p (&optional pps)
  "If cursor is at the beginning of a `if-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-if-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-indent-p (&optional pps)
  "If cursor is at the beginning of a `indent'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-indent-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-minor-block-p (&optional pps)
  "If cursor is at the beginning of a `minor-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-minor-block-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-try-block-p (&optional pps)
  "If cursor is at the beginning of a `try-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-try-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (eq (current-column)(current-indentation))
         (point))))

(defun mys--beginning-of-assignment-bol-p (&optional pps)
  "If cursor is at the beginning of a `assignment'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-assignment-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-block-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-block-or-clause-bol-p (&optional pps)
  "If cursor is at the beginning of a `block-or-clause'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-block-or-clause-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-class-bol-p (&optional pps)
  "If cursor is at the beginning of a `class'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-class-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-clause-bol-p (&optional pps)
  "If cursor is at the beginning of a `clause'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-clause-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-def-bol-p (&optional pps)
  "If cursor is at the beginning of a `def'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-def-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-def-or-class-bol-p (&optional pps)
  "If cursor is at the beginning of a `def-or-class'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-def-or-class-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-elif-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `elif-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-elif-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-else-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `else-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-else-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-except-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `except-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-except-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-for-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `for-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-for-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-if-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `if-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-if-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-indent-bol-p (&optional pps)
  "If cursor is at the beginning of a `indent'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-indent-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-minor-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `minor-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-minor-block-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

(defun mys--beginning-of-try-block-bol-p (&optional pps)
  "If cursor is at the beginning of a `try-block'.
Return position, nil otherwise."
  (let ((pps (or pps (parse-partial-sexp (point-min) (point)))))
    (and (bolp)
         (not (or (nth 8 pps)(nth 1 pps)))
         (looking-at mys-try-re)
         (looking-back "[^ \t]*" (line-beginning-position))
         (point))))

;; mys-components-move

(defun mys-backward-paragraph ()
  "Go to beginning of current paragraph.

If already at beginning, go to start of next paragraph upwards"
  (interactive)
  (backward-paragraph)(point))

(defun mys-forward-paragraph ()
    "Go to end of current paragraph.

If already at end, go to end of next paragraph downwards"
  (interactive)
  (and (forward-paragraph)(point)))

;; Indentation
;; Travel current level of indentation
(defun mys--travel-this-indent-backward (&optional indent)
  "Travel current INDENT backward.

With optional INDENT travel bigger or equal indentation"
  (let ((indent (or indent (current-indentation)))
	last)
    (while (and (not (bobp))
		(mys-backward-statement)
		(<= indent (current-indentation))
		(setq last (point))))
    (when last (goto-char last))
    last))

(defun mys-backward-indent ()
  "Go to the beginning of a section of equal indent.

If already at the beginning or before a indent, go to next indent upwards
Returns final position when called from inside section, nil otherwise"
  (interactive)
  (unless (bobp)
    (let (erg)
      (setq erg (mys--travel-this-indent-backward))
      (when erg (goto-char erg))
      erg)))

(defun mys--travel-this-indent-backward-bol (indent)
  "Internal use.

Travel this INDENT backward until bol"
  (let (erg)
    (while (and (mys-backward-statement-bol)
		(or indent (setq indent (current-indentation)))
		(eq indent (current-indentation))(setq erg (point)) (not (bobp))))
    (when erg (goto-char erg))))

(defun mys-backward-indent-bol ()
  "Go to the beginning of line of a section of equal indent.

If already at the beginning or before an indent,
go to next indent in buffer upwards
Returns final position when called from inside section, nil otherwise"
  (interactive)
  (unless (bobp)
    (let ((indent (when (eq (current-indentation) (current-column)) (current-column)))
	  erg)
      (setq erg (mys--travel-this-indent-backward-bol indent))
      erg)))

(defun mys--travel-this-indent-forward (indent)
  "Internal use.

Travel this INDENT forward"
  (let (last erg)
    (while (and (mys-down-statement)
		(eq indent (current-indentation))
		(setq last (point))))
    (when last (goto-char last))
    (setq erg (mys-forward-statement))
    erg))

(defun mys-forward-indent ()
  "Go to the end of a section of equal indentation.

If already at the end, go down to next indent in buffer
Returns final position when moved, nil otherwise"
  (interactive)
  (let (done
	(orig (line-beginning-position))
	(indent (current-indentation))
	(last (progn (back-to-indentation) (point))))
    (while (and (not (eobp)) (not done)
		(progn (forward-line 1) (back-to-indentation) (or (mys-empty-line-p) (and (<= indent (current-indentation))(< last (point))))))
      (unless (mys-empty-line-p) (skip-chars-forward " \t\r\n\f")(setq last (point)))
      (and (not (mys-empty-line-p))(< (current-indentation) indent)(setq done t)))
    (goto-char last)
    (end-of-line)
    (skip-chars-backward " \t\r\n\f")
    (and (< orig (point))(point))))

(defun mys-forward-indent-bol ()
  "Go to beginning of line following of a section of equal indentation.

If already at the end, go down to next indent in buffer
Returns final position when called from inside section, nil otherwise"
  (interactive)
  (unless (eobp)
    (when (mys-forward-indent)
      (unless (eobp) (progn (forward-line 1) (beginning-of-line) (point))))))

;; (defun mys-forward-indent-bol ()
;;   "Go to beginning of line following of a section of equal indentation.

;; If already at the end, go down to next indent in buffer
;; Returns final position when called from inside section, nil otherwise"
;;   (interactive)
;;   (unless (eobp)
;;     (let (erg indent)
;;       ;; (when (mys-forward-statement)
;;       (when (mys-forward-indent)
;; 	;; (save-excursion
;;       	;; (setq indent (and (mys-backward-statement)(current-indentation))))
;; 	;; (setq erg (mys--travel-this-indent-forward indent))
;; 	(unless (eobp) (forward-line 1) (beginning-of-line) (setq erg (point))))
;;       erg)))

(defun mys-backward-expression (&optional orig done repeat)
  "Go to the beginning of a python expression.

If already at the beginning or before a expression,
go to next expression in buffer upwards

ORIG - consider orignial position or point.
DONE - transaktional argument
REPEAT - count and consider repeats"
  (interactive)
  (unless (bobp)
    (unless done (skip-chars-backward " \t\r\n\f"))
    (let ((repeat (or (and repeat (1+ repeat)) 0))
	  (pps (parse-partial-sexp (point-min) (point)))
          (orig (or orig (point)))
          erg)
      (if (< mys-max-specpdl-size repeat)
	  (error "`mys-backward-expression' reached loops max")
	(cond
	 ;; comments
	 ((nth 8 pps)
	  (goto-char (nth 8 pps))
	  (mys-backward-expression orig done repeat))
	 ;; lists
	 ((nth 1 pps)
	  (goto-char (nth 1 pps))
	  (skip-chars-backward mys-expression-skip-chars)
	  )
	 ;; in string
	 ((nth 3 pps)
	  (goto-char (nth 8 pps)))
	 ;; after operator
	 ((and (not done) (looking-back mys-operator-re (line-beginning-position)))
	  (skip-chars-backward "^ \t\r\n\f")
	  (skip-chars-backward " \t\r\n\f")
	  (mys-backward-expression orig done repeat))
	 ((and (not done)
	       (< 0 (abs (skip-chars-backward mys-expression-skip-chars))))
	  (setq done t)
	  (mys-backward-expression orig done repeat))))
      (unless (or (eq (point) orig)(and (bobp)(eolp)))
	(setq erg (point)))
      erg)))

(defun mys-forward-expression (&optional orig done repeat)
  "Go to the end of a compound python expression.

Operators are ignored.
ORIG - consider orignial position or point.
DONE - transaktional argument
REPEAT - count and consider repeats"
  (interactive)
  (unless done (skip-chars-forward " \t\r\n\f"))
  (unless (eobp)
    (let ((repeat (or (and repeat (1+ repeat)) 0))
	  (pps (parse-partial-sexp (point-min) (point)))
          (orig (or orig (point)))
          erg)
      (if (< mys-max-specpdl-size repeat)
	  (error "`mys-forward-expression' reached loops max")
	(cond
	 ;; in comment
	 ((nth 4 pps)
	  (or (< (point) (progn (forward-comment 1) (point)))(forward-line 1))
	  (mys-forward-expression orig done repeat))
	 ;; empty before comment
	 ((and (looking-at "[ \t]*#") (looking-back "^[ \t]*" (line-beginning-position)))
	  (while (and (looking-at "[ \t]*#") (not (eobp)))
	    (forward-line 1))
	  (mys-forward-expression orig done repeat))
	 ;; inside string
	 ((nth 3 pps)
	  (goto-char (nth 8 pps))
	  (goto-char (scan-sexps (point) 1))
	  (setq done t)
	  (mys-forward-expression orig done repeat))
	 ((looking-at "\"\"\"\\|'''\\|\"\\|'")
	  (goto-char (scan-sexps (point) 1))
	  (setq done t)
	  (mys-forward-expression orig done repeat))
	 ;; looking at opening delimiter
	 ((eq 4 (car-safe (syntax-after (point))))
	  (goto-char (scan-sexps (point) 1))
	  (skip-chars-forward mys-expression-skip-chars)
	  (setq done t))
	 ((nth 1 pps)
	  (goto-char (nth 1 pps))
	  (goto-char (scan-sexps (point) 1))
	  (skip-chars-forward mys-expression-skip-chars)
	  (setq done t)
	  (mys-forward-expression orig done repeat))
	 ((and (eq orig (point)) (looking-at mys-operator-re))
	  (goto-char (match-end 0))
	  (mys-forward-expression orig done repeat))
	 ((and (not done)
	       (< 0 (skip-chars-forward mys-expression-skip-chars)))
	  (setq done t)
	  (mys-forward-expression orig done repeat))
	 ;; at colon following arglist
	 ((looking-at ":[ \t]*$")
	  (forward-char 1)))
	(unless (or (eq (point) orig)(and (eobp) (bolp)))
	  (setq erg (point)))
	erg))))

(defun mys-backward-partial-expression ()
  "Backward partial-expression."
  (interactive)
  (let ((orig (point))
	erg)
    (and (< 0 (abs (skip-chars-backward " \t\r\n\f")))(not (bobp))(forward-char -1))
    (when (mys--in-comment-p)
      (mys-backward-comment)
      (skip-chars-backward " \t\r\n\f"))
    ;; part of mys-partial-expression-forward-chars
    (when (member (char-after) (list ?\ ?\" ?' ?\) ?} ?\] ?: ?#))
      (forward-char -1))
    (skip-chars-backward mys-partial-expression-forward-chars)
    (when (< 0 (abs (skip-chars-backward mys-partial-expression-backward-chars)))
      (while (and (not (bobp)) (mys--in-comment-p)(< 0 (abs (skip-chars-backward mys-partial-expression-backward-chars))))))
    (when (< (point) orig)
      (unless
	  (and (bobp) (member (char-after) (list ?\ ?\t ?\r ?\n ?\f)))
	(setq erg (point))))
    erg))

(defun mys-forward-partial-expression ()
  "Forward partial-expression."
  (interactive)
  (let (erg)
    (skip-chars-forward mys-partial-expression-backward-chars)
    ;; group arg
    (while
     (looking-at "[\[{(]")
     (goto-char (scan-sexps (point) 1)))
    (setq erg (point))
    erg))

;; Partial- or Minor Expression
;;  Line
(defun mys-backward-line ()
  "Go to `beginning-of-line', return position.

If already at `beginning-of-line' and not at BOB,
go to beginning of previous line."
  (interactive)
  (unless (bobp)
    (let ((erg
           (if (bolp)
               (progn
                 (forward-line -1)
                 (progn (beginning-of-line)(point)))
             (progn (beginning-of-line)(point)))))
      erg)))

(defun mys-forward-line ()
  "Go to `end-of-line', return position.

If already at `end-of-line' and not at EOB, go to end of next line."
  (interactive)
  (unless (eobp)
    (let ((orig (point)))
      (when (eolp) (forward-line 1))
      (end-of-line)
      (when (< orig (point))(point)))))

(defun mys-forward-into-nomenclature (&optional arg)
  "Move forward to end of a nomenclature symbol.

With \\[universal-argument] (programmatically, optional argument ARG), do it that many times.
IACT - if called interactively
A `nomenclature' is a fancy way of saying AWordWithMixedCaseNotUnderscores."
  (interactive "p")
  (or arg (setq arg 1))
  (let ((case-fold-search nil)
        (orig (point))
        erg)
    (if (> arg 0)
        (while (and (not (eobp)) (> arg 0))
          ;; (setq erg (re-search-forward "\\(\\W+[_[:lower:][:digit:]ß]+\\)" nil t 1))
          (cond
           ((or (not (eq 0 (skip-chars-forward "[[:blank:][:punct:]\n\r]")))
                (not (eq 0 (skip-chars-forward "_"))))
            (when (or
                   (< 1 (skip-chars-forward "[:upper:]"))
                   (not (eq 0 (skip-chars-forward "[[:lower:][:digit:]ß]")))
                   (not (eq 0 (skip-chars-forward "[[:lower:][:digit:]]"))))
              (setq arg (1- arg))))
           ((or
             (< 1 (skip-chars-forward "[:upper:]"))
             (not (eq 0 (skip-chars-forward "[[:lower:][:digit:]ß]")))
             (not (eq 0 (skip-chars-forward "[[:lower:][:digit:]]"))))
            (setq arg (1- arg)))))
      (while (and (not (bobp)) (< arg 0))
        (when (not (eq 0 (skip-chars-backward "[[:blank:][:punct:]\n\r\f_]")))

          (forward-char -1))
        (or
         (not (eq 0 (skip-chars-backward "[:upper:]")))
         (not (eq 0 (skip-chars-backward "[[:lower:][:digit:]ß]")))
         (skip-chars-backward "[[:lower:][:digit:]ß]"))
        (setq arg (1+ arg))))
    (if (< (point) orig)
        (progn
          (when (looking-back "[[:upper:]]" (line-beginning-position))
            ;; (looking-back "[[:blank:]]"
            (forward-char -1))
          (if (looking-at "[[:alnum:]ß]")
              (setq erg (point))
            (setq erg nil)))
      (if (and (< orig (point)) (not (eobp)))
          (setq erg (point))
        (setq erg nil)))
    erg))

(defun mys-backward-into-nomenclature (&optional arg)
  "Move backward to beginning of a nomenclature symbol.

With optional ARG, move that many times.  If ARG is negative, move
forward.

A `nomenclature' is a fancy way of saying AWordWithMixedCaseNotUnderscores."
  (interactive "p")
  (setq arg (or arg 1))
  (mys-forward-into-nomenclature (- arg)))

(defun mys--travel-current-indent (indent &optional orig)
  "Move down until clause is closed, i.e. current indentation is reached.

Takes a list, INDENT and ORIG position."
  (unless (eobp)
    (let ((orig (or orig (point)))
          last)
      (while (and (setq last (point))(not (eobp))(mys-forward-statement)
                  (save-excursion (or (<= indent (progn  (mys-backward-statement)(current-indentation)))(eq last (line-beginning-position))))
                  ;; (mys--end-of-statement-p)
))
      (goto-char last)
      (when (< orig last)
        last))))

(defun mys-backward-block-current-column ()
"Reach next beginning of block upwards which start at current column.

Return position"
(interactive)
(let* ((orig (point))
       (cuco (current-column))
       (str (make-string cuco ?\s))
       pps erg)
  (while (and (not (bobp))(re-search-backward (concat "^" str mys-block-keywords) nil t)(or (nth 8 (setq pps (parse-partial-sexp (point-min) (point)))) (nth 1 pps))))
  (back-to-indentation)
  (and (< (point) orig)(setq erg (point)))
  erg))

(defun mys-backward-section ()
  "Go to next section start upward in buffer.

Return position if successful"
  (interactive)
  (let ((orig (point)))
    (while (and (re-search-backward mys-section-start nil t 1)
		(nth 8 (parse-partial-sexp (point-min) (point)))))
    (when (and (looking-at mys-section-start)(< (point) orig))
      (point))))

(defun mys-forward-section ()
  "Go to next section end downward in buffer.

Return position if successful"
  (interactive)
  (let ((orig (point))
	last)
    (while (and (re-search-forward mys-section-end nil t 1)
		(setq last (point))
		(goto-char (match-beginning 0))
		(nth 8 (parse-partial-sexp (point-min) (point)))
		(goto-char (match-end 0))))
    (and last (goto-char last))
    (when (and (looking-back mys-section-end (line-beginning-position))(< orig (point)))
      (point))))

(defun mys-beginning-of-assignment()
  "Go to beginning of assigment if inside.

Return position of successful, nil of not started from inside."
  (interactive)
  (let* (last
	 (erg
	  (or (mys--beginning-of-assignment-p)
	      (progn
		(while (and (setq last (mys-backward-statement))
			    (not (looking-at mys-assignment-re))
			    ;; (not (bolp))
			    ))
		(and (looking-at mys-assignment-re) last)))))
    erg))

;; (defun mys--forward-assignment-intern ()
;;   (and (looking-at mys-assignment-re)
;;        (goto-char (match-end 2))
;;        (skip-chars-forward " \t\r\n\f")
;;        ;; (eq (car (syntax-after (point))) 4)
;;        (progn (forward-sexp) (point))))

;; (defun mys-forward-assignment()
;;   "Go to end of assigment at point if inside.

;; Return position of successful, nil of not started from inside"
;;   (interactive)
;;   (unless (eobp)
;;     (if (eq last-command 'mys-backward-assignment)
;; 	;; assume at start of an assignment
;; 	(mys--forward-assignment-intern)
;;       ;; `mys-backward-assignment' here, avoid `mys--beginning-of-assignment-p' a second time
;;       (let* (last
;; 	     (beg
;; 	      (or (mys--beginning-of-assignment-p)
;; 		  (progn
;; 		    (while (and (setq last (mys-backward-statement))
;; 				(not (looking-at mys-assignment-re))
;; 				;; (not (bolp))
;; 				))
;; 		    (and (looking-at mys-assignment-re) last))))
;; 	     erg)
;; 	(and beg (setq erg (mys--forward-assignment-intern)))
;; 	erg))))


(defun mys-up ()
  (interactive)
  (cond
   ((mys--beginning-of-class-p)
	 (mys-up-class (current-indentation)))
   ((mys--beginning-of-def-p)
	 (mys-up-def (current-indentation)))
   ((mys--beginning-of-block-p)
	 (mys-up-block (current-indentation)))
   ((mys--beginning-of-clause-p)
	 (mys-backward-block))
   ((mys-beginning-of-statement-p)
	 (mys-backward-block-or-clause))
   (t (mys-backward-statement)) 
   ))




;; mys-components-end-position-forms


(defun mys--end-of-block-position ()
  "Return end of block position."
  (save-excursion (mys-forward-block)))

(defun mys--end-of-block-or-clause-position ()
  "Return end of block-or-clause position."
  (save-excursion (mys-forward-block-or-clause)))

(defun mys--end-of-class-position ()
  "Return end of class position."
  (save-excursion (mys-forward-class)))

(defun mys--end-of-clause-position ()
  "Return end of clause position."
  (save-excursion (mys-forward-clause)))

(defun mys--end-of-comment-position ()
  "Return end of comment position."
  (save-excursion (mys-forward-comment)))

(defun mys--end-of-def-position ()
  "Return end of def position."
  (save-excursion (mys-forward-def)))

(defun mys--end-of-def-or-class-position ()
  "Return end of def-or-class position."
  (save-excursion (mys-forward-def-or-class)))

(defun mys--end-of-expression-position ()
  "Return end of expression position."
  (save-excursion (mys-forward-expression)))

(defun mys--end-of-except-block-position ()
  "Return end of except-block position."
  (save-excursion (mys-forward-except-block)))

(defun mys--end-of-if-block-position ()
  "Return end of if-block position."
  (save-excursion (mys-forward-if-block)))

(defun mys--end-of-indent-position ()
  "Return end of indent position."
  (save-excursion (mys-forward-indent)))

(defun mys--end-of-line-position ()
  "Return end of line position."
  (save-excursion (mys-forward-line)))

(defun mys--end-of-minor-block-position ()
  "Return end of minor-block position."
  (save-excursion (mys-forward-minor-block)))

(defun mys--end-of-partial-expression-position ()
  "Return end of partial-expression position."
  (save-excursion (mys-forward-partial-expression)))

(defun mys--end-of-paragraph-position ()
  "Return end of paragraph position."
  (save-excursion (mys-forward-paragraph)))

(defun mys--end-of-section-position ()
  "Return end of section position."
  (save-excursion (mys-forward-section)))

(defun mys--end-of-statement-position ()
  "Return end of statement position."
  (save-excursion (mys-forward-statement)))

(defun mys--end-of-top-level-position ()
  "Return end of top-level position."
  (save-excursion (mys-forward-top-level)))

(defun mys--end-of-try-block-position ()
  "Return end of try-block position."
  (save-excursion (mys-forward-try-block)))

(defun mys--end-of-block-position-bol ()
  "Return end of block position at `beginning-of-line'."
  (save-excursion (mys-forward-block-bol)))

(defun mys--end-of-block-or-clause-position-bol ()
  "Return end of block-or-clause position at `beginning-of-line'."
  (save-excursion (mys-forward-block-or-clause-bol)))

(defun mys--end-of-class-position-bol ()
  "Return end of class position at `beginning-of-line'."
  (save-excursion (mys-forward-class-bol)))

(defun mys--end-of-clause-position-bol ()
  "Return end of clause position at `beginning-of-line'."
  (save-excursion (mys-forward-clause-bol)))

(defun mys--end-of-def-position-bol ()
  "Return end of def position at `beginning-of-line'."
  (save-excursion (mys-forward-def-bol)))

(defun mys--end-of-def-or-class-position-bol ()
  "Return end of def-or-class position at `beginning-of-line'."
  (save-excursion (mys-forward-def-or-class-bol)))

(defun mys--end-of-elif-block-position-bol ()
  "Return end of elif-block position at `beginning-of-line'."
  (save-excursion (mys-forward-elif-block-bol)))

(defun mys--end-of-else-block-position-bol ()
  "Return end of else-block position at `beginning-of-line'."
  (save-excursion (mys-forward-else-block-bol)))

(defun mys--end-of-except-block-position-bol ()
  "Return end of except-block position at `beginning-of-line'."
  (save-excursion (mys-forward-except-block-bol)))

(defun mys--end-of-for-block-position-bol ()
  "Return end of for-block position at `beginning-of-line'."
  (save-excursion (mys-forward-for-block-bol)))

(defun mys--end-of-if-block-position-bol ()
  "Return end of if-block position at `beginning-of-line'."
  (save-excursion (mys-forward-if-block-bol)))

(defun mys--end-of-indent-position-bol ()
  "Return end of indent position at `beginning-of-line'."
  (save-excursion (mys-forward-indent-bol)))

(defun mys--end-of-minor-block-position-bol ()
  "Return end of minor-block position at `beginning-of-line'."
  (save-excursion (mys-forward-minor-block-bol)))

(defun mys--end-of-statement-position-bol ()
  "Return end of statement position at `beginning-of-line'."
  (save-excursion (mys-forward-statement-bol)))

(defun mys--end-of-try-block-position-bol ()
  "Return end of try-block position at `beginning-of-line'."
  (save-excursion (mys-forward-try-block-bol)))

;; mys-components-beginning-position-forms


(defun mys--beginning-of-block-position ()
  "Return beginning of block position."
  (save-excursion
    (or (mys--beginning-of-block-p)
        (mys-backward-block))))

(defun mys--beginning-of-block-or-clause-position ()
  "Return beginning of block-or-clause position."
  (save-excursion
    (or (mys--beginning-of-block-or-clause-p)
        (mys-backward-block-or-clause))))

(defun mys--beginning-of-class-position ()
  "Return beginning of class position."
  (save-excursion
    (or (mys--beginning-of-class-p)
        (mys-backward-class))))

(defun mys--beginning-of-clause-position ()
  "Return beginning of clause position."
  (save-excursion
    (or (mys--beginning-of-clause-p)
        (mys-backward-clause))))

(defun mys--beginning-of-comment-position ()
  "Return beginning of comment position."
  (save-excursion
    (or (mys--beginning-of-comment-p)
        (mys-backward-comment))))

(defun mys--beginning-of-def-position ()
  "Return beginning of def position."
  (save-excursion
    (or (mys--beginning-of-def-p)
        (mys-backward-def))))

(defun mys--beginning-of-def-or-class-position ()
  "Return beginning of def-or-class position."
  (save-excursion
    (or (mys--beginning-of-def-or-class-p)
        (mys-backward-def-or-class))))

(defun mys--beginning-of-expression-position ()
  "Return beginning of expression position."
  (save-excursion
    (or (mys--beginning-of-expression-p)
        (mys-backward-expression))))

(defun mys--beginning-of-except-block-position ()
  "Return beginning of except-block position."
  (save-excursion
    (or (mys--beginning-of-except-block-p)
        (mys-backward-except-block))))

(defun mys--beginning-of-if-block-position ()
  "Return beginning of if-block position."
  (save-excursion
    (or (mys--beginning-of-if-block-p)
        (mys-backward-if-block))))

(defun mys--beginning-of-indent-position ()
  "Return beginning of indent position."
  (save-excursion
    (or (mys--beginning-of-indent-p)
        (mys-backward-indent))))

(defun mys--beginning-of-line-position ()
  "Return beginning of line position."
  (save-excursion
    (or (mys--beginning-of-line-p)
        (mys-backward-line))))

(defun mys--beginning-of-minor-block-position ()
  "Return beginning of minor-block position."
  (save-excursion
    (or (mys--beginning-of-minor-block-p)
        (mys-backward-minor-block))))

(defun mys--beginning-of-partial-expression-position ()
  "Return beginning of partial-expression position."
  (save-excursion
    (or (mys--beginning-of-partial-expression-p)
        (mys-backward-partial-expression))))

(defun mys--beginning-of-paragraph-position ()
  "Return beginning of paragraph position."
  (save-excursion
    (or (mys--beginning-of-paragraph-p)
        (mys-backward-paragraph))))

(defun mys--beginning-of-section-position ()
  "Return beginning of section position."
  (save-excursion
    (or (mys--beginning-of-section-p)
        (mys-backward-section))))

(defun mys--beginning-of-statement-position ()
  "Return beginning of statement position."
  (save-excursion
    (or (mys--beginning-of-statement-p)
        (mys-backward-statement))))

(defun mys--beginning-of-top-level-position ()
  "Return beginning of top-level position."
  (save-excursion
    (or (mys--beginning-of-top-level-p)
        (mys-backward-top-level))))

(defun mys--beginning-of-try-block-position ()
  "Return beginning of try-block position."
  (save-excursion
    (or (mys--beginning-of-try-block-p)
        (mys-backward-try-block))))

(defun mys--beginning-of-block-position-bol ()
  "Return beginning of block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-block-bol-p)
        (mys-backward-block-bol))))

(defun mys--beginning-of-block-or-clause-position-bol ()
  "Return beginning of block-or-clause position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-block-or-clause-bol-p)
        (mys-backward-block-or-clause-bol))))

(defun mys--beginning-of-class-position-bol ()
  "Return beginning of class position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-class-bol-p)
        (mys-backward-class-bol))))

(defun mys--beginning-of-clause-position-bol ()
  "Return beginning of clause position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-clause-bol-p)
        (mys-backward-clause-bol))))

(defun mys--beginning-of-def-position-bol ()
  "Return beginning of def position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-def-bol-p)
        (mys-backward-def-bol))))

(defun mys--beginning-of-def-or-class-position-bol ()
  "Return beginning of def-or-class position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-def-or-class-bol-p)
        (mys-backward-def-or-class-bol))))

(defun mys--beginning-of-elif-block-position-bol ()
  "Return beginning of elif-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-elif-block-bol-p)
        (mys-backward-elif-block-bol))))

(defun mys--beginning-of-else-block-position-bol ()
  "Return beginning of else-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-else-block-bol-p)
        (mys-backward-else-block-bol))))

(defun mys--beginning-of-except-block-position-bol ()
  "Return beginning of except-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-except-block-bol-p)
        (mys-backward-except-block-bol))))

(defun mys--beginning-of-for-block-position-bol ()
  "Return beginning of for-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-for-block-bol-p)
        (mys-backward-for-block-bol))))

(defun mys--beginning-of-if-block-position-bol ()
  "Return beginning of if-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-if-block-bol-p)
        (mys-backward-if-block-bol))))

(defun mys--beginning-of-indent-position-bol ()
  "Return beginning of indent position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-indent-bol-p)
        (mys-backward-indent-bol))))

(defun mys--beginning-of-minor-block-position-bol ()
  "Return beginning of minor-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-minor-block-bol-p)
        (mys-backward-minor-block-bol))))

(defun mys--beginning-of-statement-position-bol ()
  "Return beginning of statement position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-statement-bol-p)
        (mys-backward-statement-bol))))

(defun mys--beginning-of-try-block-position-bol ()
  "Return beginning of try-block position at `beginning-of-line'."
  (save-excursion
    (or (mys--beginning-of-try-block-bol-p)
        (mys-backward-try-block-bol))))

;; mys-components-extended-executes

(defun mys--execute-prepare (form shell &optional dedicated switch beg end filename fast proc wholebuf split)
  "Update some vars."
  (save-excursion
    (let* ((form (prin1-to-string form))
           (origline (mys-count-lines))
           (fast
            (or fast mys-fast-process-p))
           (mys-exception-buffer (current-buffer))
           (beg (unless filename
                  (prog1
                      (or beg (funcall (intern-soft (concat "mys--beginning-of-" form "-p")))
                          (funcall (intern-soft (concat "mys-backward-" form)))
                          (push-mark)))))
           (end (unless filename
                  (or end (save-excursion (funcall (intern-soft (concat "mys-forward-" form))))))))
      ;; (setq mys-buffer-name nil)
      (if filename
            (if (file-readable-p filename)
                (mys--execute-file-base (expand-file-name filename) nil nil nil origline)
              (message "%s not readable. %s" filename "Do you have write permissions?"))
        (mys--execute-base beg end shell filename proc wholebuf fast dedicated split switch)))))

(defun mys-execute-block-imys (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-imys-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-imys3 (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-imys3-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-jython (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-jython-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-python (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-mys-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-python2 (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-python2-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-python3 (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-python3-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-pypy (&optional dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-pymys-dedicated (&optional fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block (&optional shell dedicated fast split switch proc)
  "Send block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-dedicated (&optional shell fast split switch proc)
  "Send block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-imys (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-imys-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-imys3 (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-imys3-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-jython (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-jython-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-python (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-mys-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-python2 (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-python2-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-python3 (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-python3-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-pypy (&optional dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-pymys-dedicated (&optional fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause (&optional shell dedicated fast split switch proc)
  "Send block-or-clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-block-or-clause-dedicated (&optional shell fast split switch proc)
  "Send block-or-clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'block-or-clause shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-buffer-imys (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'imys dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-imys-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'imys t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-imys3 (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'imys3 dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-imys3-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'imys3 t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-jython (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'jython dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-jython-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'jython t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-python (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-mys-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-python2 (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python2 dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-python2-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python2 t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-python3 (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python3 dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-python3-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'python3 t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-pypy (&optional dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'pypy dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-pymys-dedicated (&optional fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer 'pypy t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer (&optional shell dedicated fast split switch proc)
  "Send buffer at point to a python3 interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer shell dedicated switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-buffer-dedicated (&optional shell fast split switch proc)
  "Send buffer at point to a python3 unique interpreter."
  (interactive)
  (let ((mys-master-file (or mys-master-file (mys-fetch-mys-master-file)))
        (wholebuf t)
        filename buffer)
    (when mys-master-file
      (setq filename (expand-file-name mys-master-file)
            buffer (or (get-file-buffer filename)
                       (find-file-noselect filename)))
      (set-buffer buffer))
    (mys--execute-prepare 'buffer shell t switch (point-min) (point-max) nil fast proc wholebuf split)))

(defun mys-execute-class-imys (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-imys-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-imys3 (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-imys3-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-jython (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-jython-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-python (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-mys-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-python2 (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-python2-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-python3 (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-python3-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-pypy (&optional dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-pymys-dedicated (&optional fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class (&optional shell dedicated fast split switch proc)
  "Send class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-class-dedicated (&optional shell fast split switch proc)
  "Send class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'class shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-imys (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-imys-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-imys3 (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-imys3-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-jython (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-jython-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-python (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-mys-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-python2 (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-python2-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-python3 (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-python3-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-pypy (&optional dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-pymys-dedicated (&optional fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause (&optional shell dedicated fast split switch proc)
  "Send clause at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-clause-dedicated (&optional shell fast split switch proc)
  "Send clause at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'clause shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-imys (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-imys-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-imys3 (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-imys3-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-jython (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-jython-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-python (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-mys-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-python2 (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-python2-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-python3 (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-python3-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-pypy (&optional dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-pymys-dedicated (&optional fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def (&optional shell dedicated fast split switch proc)
  "Send def at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-dedicated (&optional shell fast split switch proc)
  "Send def at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-imys (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-imys-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-imys3 (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-imys3-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-jython (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-jython-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-python (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-mys-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-python2 (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-python2-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-python3 (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-python3-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-pypy (&optional dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-pymys-dedicated (&optional fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class (&optional shell dedicated fast split switch proc)
  "Send def-or-class at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-def-or-class-dedicated (&optional shell fast split switch proc)
  "Send def-or-class at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'def-or-class shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-imys (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-imys-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-imys3 (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-imys3-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-jython (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-jython-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-python (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-mys-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-python2 (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-python2-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-python3 (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-python3-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-pypy (&optional dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-pymys-dedicated (&optional fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression (&optional shell dedicated fast split switch proc)
  "Send expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-expression-dedicated (&optional shell fast split switch proc)
  "Send expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'expression shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-imys (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-imys-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-imys3 (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-imys3-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-jython (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-jython-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-python (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-mys-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-python2 (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-python2-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-python3 (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-python3-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-pypy (&optional dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-pymys-dedicated (&optional fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent (&optional shell dedicated fast split switch proc)
  "Send indent at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-indent-dedicated (&optional shell fast split switch proc)
  "Send indent at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'indent shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-imys (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-imys-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-imys3 (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-imys3-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-jython (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-jython-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-python (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-mys-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-python2 (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-python2-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-python3 (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-python3-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-pypy (&optional dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-pymys-dedicated (&optional fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line (&optional shell dedicated fast split switch proc)
  "Send line at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-line-dedicated (&optional shell fast split switch proc)
  "Send line at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'line shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-imys (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-imys-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-imys3 (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-imys3-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-jython (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-jython-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-python (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-mys-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-python2 (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-python2-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-python3 (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-python3-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-pypy (&optional dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-pymys-dedicated (&optional fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block (&optional shell dedicated fast split switch proc)
  "Send minor-block at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-minor-block-dedicated (&optional shell fast split switch proc)
  "Send minor-block at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'minor-block shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-imys (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-imys-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-imys3 (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-imys3-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-jython (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-jython-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-python (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-mys-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-python2 (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-python2-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-python3 (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-python3-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-pypy (&optional dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-pymys-dedicated (&optional fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph (&optional shell dedicated fast split switch proc)
  "Send paragraph at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-paragraph-dedicated (&optional shell fast split switch proc)
  "Send paragraph at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'paragraph shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-imys (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-imys-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-imys3 (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-imys3-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-jython (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-jython-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-python (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-mys-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-python2 (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-python2-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-python3 (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-python3-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-pypy (&optional dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-pymys-dedicated (&optional fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression (&optional shell dedicated fast split switch proc)
  "Send partial-expression at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-partial-expression-dedicated (&optional shell fast split switch proc)
  "Send partial-expression at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'partial-expression shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-region-imys (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'imys dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-imys-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'imys t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-imys3 (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'imys3 dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-imys3-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'imys3 t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-jython (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'jython dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-jython-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'jython t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-python (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-mys-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-python2 (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python2 dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-python2-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python2 t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-python3 (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python3 dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-python3-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'python3 t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-pypy (beg end &optional dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'pypy dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-pymys-dedicated (beg end &optional fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region 'pypy t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region (beg end &optional shell dedicated fast split switch proc)
  "Send region at point to a python3 interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region shell dedicated switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-region-dedicated (beg end &optional shell fast split switch proc)
  "Send region at point to a python3 unique interpreter."
  (interactive "r")
  (let ((wholebuf nil))
    (mys--execute-prepare 'region shell t switch (or beg (region-beginning)) (or end (region-end)) nil fast proc wholebuf split)))

(defun mys-execute-statement-imys (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-imys-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-imys3 (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-imys3-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-jython (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-jython-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-python (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-mys-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-python2 (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-python2-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-python3 (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-python3-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-pypy (&optional dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-pymys-dedicated (&optional fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement (&optional shell dedicated fast split switch proc)
  "Send statement at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-statement-dedicated (&optional shell fast split switch proc)
  "Send statement at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'statement shell t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-imys (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'imys dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-imys-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'imys t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-imys3 (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'imys3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-imys3-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'imys3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-jython (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'jython dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-jython-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'jython t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-python (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-mys-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter.

For `default' see value of `mys-shell-name'"
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-python2 (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python2 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-python2-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python2 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-python3 (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python3 dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-python3-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'python3 t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-pypy (&optional dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'pypy dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-pymys-dedicated (&optional fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level 'pypy t switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level (&optional shell dedicated fast split switch proc)
  "Send top-level at point to a python3 interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level shell dedicated switch nil nil nil fast proc wholebuf split)))

(defun mys-execute-top-level-dedicated (&optional shell fast split switch proc)
  "Send top-level at point to a python3 unique interpreter."
  (interactive)
  (let ((wholebuf nil))
    (mys--execute-prepare 'top-level shell t switch nil nil nil fast proc wholebuf split)))

;; mys-components-execute

(defun mys-switch-to-python (eob-p)
  "Switch to the Python process buffer, maybe starting new process.

With EOB-P, go to end of buffer."
  (interactive "p")
  (pop-to-buffer (process-buffer (mys-proc)) t) ;Runs python if needed.
  (when eob-p
    (goto-char (point-max))))

;;  Split-Windows-On-Execute forms
(defun mys-toggle-split-windows-on-execute (&optional arg)
  "If `mys-split-window-on-execute' should be on or off.

optional ARG
  Returns value of `mys-split-window-on-execute' switched to."
  (interactive)
  (let ((arg (or arg (if mys-split-window-on-execute -1 1))))
    (if (< 0 arg)
        (setq mys-split-window-on-execute t)
      (setq mys-split-window-on-execute nil))
    (when (called-interactively-p 'any) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
    mys-split-window-on-execute))

(defun mys-split-windows-on-execute-on (&optional arg)
  "Make sure, `mys-split-window-on-execute' according to ARG.

Returns value of `mys-split-window-on-execute'."
  (interactive "p")
  (let ((arg (or arg 1)))
    (mys-toggle-split-windows-on-execute arg))
  (when (called-interactively-p 'any) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
  mys-split-window-on-execute)

(defun mys-split-windows-on-execute-off ()
  "Make sure, `mys-split-window-on-execute' is off.

Returns value of `mys-split-window-on-execute'."
  (interactive)
  (mys-toggle-split-windows-on-execute -1)
  (when (called-interactively-p 'any) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
  mys-split-window-on-execute)

;;  Shell-Switch-Buffers-On-Execute forms
(defun mys-toggle-switch-buffers-on-execute (&optional arg)
  "If `mys-switch-buffers-on-execute-p' according to ARG.

  Returns value of `mys-switch-buffers-on-execute-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-switch-buffers-on-execute-p -1 1))))
    (if (< 0 arg)
        (setq mys-switch-buffers-on-execute-p t)
      (setq mys-switch-buffers-on-execute-p nil))
    (when (called-interactively-p 'any) (message "mys-shell-switch-buffers-on-execute: %s" mys-switch-buffers-on-execute-p))
    mys-switch-buffers-on-execute-p))

(defun mys-switch-buffers-on-execute-on (&optional arg)
  "Make sure, `mys-switch-buffers-on-execute-p' according to ARG.

Returns value of `mys-switch-buffers-on-execute-p'."
  (interactive "p")
  (let ((arg (or arg 1)))
    (mys-toggle-switch-buffers-on-execute arg))
  (when (called-interactively-p 'any) (message "mys-shell-switch-buffers-on-execute: %s" mys-switch-buffers-on-execute-p))
  mys-switch-buffers-on-execute-p)

(defun mys-switch-buffers-on-execute-off ()
  "Make sure, `mys-switch-buffers-on-execute-p' is off.

Returns value of `mys-switch-buffers-on-execute-p'."
  (interactive)
  (mys-toggle-switch-buffers-on-execute -1)
  (when (called-interactively-p 'any) (message "mys-shell-switch-buffers-on-execute: %s" mys-switch-buffers-on-execute-p))
  mys-switch-buffers-on-execute-p)

(defun mys-guess-default-python ()
  "Defaults to \"python\", if guessing didn't succeed."
  (interactive)
  (let* ((ptn (or mys-shell-name (mys-choose-shell) "python"))
         (erg (if mys-edit-only-p ptn (executable-find ptn))))
    (when (called-interactively-p 'any)
      (if erg
          (message "%s" ptn)
        (message "%s" "Could not detect Python on your system")))))

;;  from imys.el
(defun mys-dirstack-hook ()
  "To synchronize dir-changes."
  (make-local-variable 'shell-dirstack)
  (setq shell-dirstack nil)
  (make-local-variable 'shell-last-dir)
  (setq shell-last-dir nil)
  (make-local-variable 'shell-dirtrackp)
  (setq shell-dirtrackp t)
  (add-hook 'comint-input-filter-functions 'shell-directory-tracker nil t))

(defalias 'mys-dedicated-shell 'mys-shell-dedicated)
(defun mys-shell-dedicated (&optional argprompt)
  "Start an interpreter in another window according to ARGPROMPT.

With optional \\[universal-argument] user is prompted by
`mys-choose-shell' for command and options to pass to the Python
interpreter."
  (interactive "P")
  (mys-shell argprompt nil t))

(defun mys-kill-shell-unconditional (&optional shell)
  "With optional argument SHELL.

Otherwise kill default (I)Python shell.
Kill buffer and its process.
Receives a `buffer-name' as argument"
  (interactive)
  (let ((shell (or shell (mys-shell))))
    (ignore-errors (mys-kill-buffer-unconditional shell))))

(defun mys-kill-default-shell-unconditional ()
  "Kill buffer \"\*Python\*\" and its process."
  (interactive)
  (ignore-errors (mys-kill-buffer-unconditional "*Python*")))

(defun mys--report-executable (buffer)
  (let ((erg (downcase (replace-regexp-in-string
                        "<\\([0-9]+\\)>" ""
                        (replace-regexp-in-string
                         "\*" ""
                         (if
                             (string-match " " buffer)
                             (substring buffer (1+ (string-match " " buffer)))
                           buffer))))))
    (when (string-match "-" erg)
      (setq erg (substring erg 0 (string-match "-" erg))))
    erg))

(defun mys--guess-buffer-name (argprompt dedicated)
  "Guess the `buffer-name' core string according to ARGPROMPT DEDICATED."
  (when (and (not dedicated) argprompt
	     (eq 4 (prefix-numeric-value argprompt)))
    (read-buffer "Mys-Shell buffer: "
		 (generate-new-buffer-name (mys--choose-buffer-name)))))

(defun mys--configured-shell (name)
  "Return the configured PATH/TO/STRING if any according to NAME."
  (if (string-match "//\\|\\\\" name)
      name
    (cond ((string-match "^[Ii]" name)
	   (or mys-imys-command name))
	  ((string-match "[Pp]ython3" name)
	   (or mys-python3-command name))
	  ((string-match "[Pp]ython2" name)
	   (or mys-python2-command name))
	  ((string-match "[Jj]ython" name)
	   (or mys-jython-command name))
	  (t (or mys-mys-command name)))))

(defun mys--determine-local-default ()
  (if (not (string= "" mys-shell-local-path))
      (expand-file-name mys-shell-local-path)
    (when mys-use-local-default
      (error "Abort: `mys-use-local-default' is set to t but `mys-shell-local-path' is empty. Maybe call `y-toggle-local-default-use'"))))

(defun mys-switch-to-shell ()
  "Switch to Python process buffer."
  (interactive)
  (pop-to-buffer (mys-shell) t))

;;  Code execution commands

(defun mys--store-result-maybe (erg)
  "If no error occurred and `mys-store-result-p' store ERG for yank."
  (and (not mys-error) erg (or mys-debug-p mys-store-result-p) (kill-new erg)))

(defun mys-current-working-directory ()
  "Return the directory of current python SHELL."
  (interactive)
  (let* ((proc (get-buffer-process (current-buffer)))
	 erg)
    (if proc
	(setq erg (mys-execute-string (concat "import os\;os.getcwd()") proc nil t))
      (setq erg (replace-regexp-in-string "\n" "" (shell-command-to-string (concat mys-shell-name " -c \"import os; print(os.getcwd())\"")))))
    (when (called-interactively-p 'interactive)
      (message "CWD: %s" erg))
    erg))

(defun mys-set-working-directory (&optional directory)
  "Set working directory according to optional DIRECTORY.

When given, to value of `mys-default-working-directory' otherwise"
  (interactive)
  (let* ((proc (get-buffer-process (current-buffer)))
	 (dir (or directory mys-default-working-directory))
	 erg)
    ;; (mys-execute-string (concat "import os\;os.chdir(\"" dir "\")") proc nil t)
    (mys-execute-string (concat "import os\;os.chdir(\"" dir "\")") proc nil t)
    (setq erg (mys-execute-string "os.getcwd()" proc nil t))
    (when (called-interactively-p 'interactive)
      (message "CWD changed to: %s" erg))
    erg))

(defun mys--update-execute-directory-intern (dir proc procbuf fast)
  (let ((strg (concat "import os\;os.chdir(\"" dir "\")")))
    (if fast
	(mys-fast-send-string strg proc procbuf t t)
      (mys-execute-string strg proc nil t))))
;; (comint-send-string proc (concat "import os;os.chdir(\"" dir "\")\n")))

(defun mys--update-execute-directory (proc procbuf execute-directory fast)
  (with-current-buffer procbuf
    (let ((cwd (mys-current-working-directory)))
      (unless (string= execute-directory (concat cwd "/"))
	(mys--update-execute-directory-intern (or mys-execute-directory execute-directory) proc procbuf fast)))))

(defun mys--close-execution (tempbuf tempfile)
  "Delete TEMPBUF and TEMPFILE."
  (unless mys-debug-p
    (when tempfile (mys-delete-temporary tempfile tempbuf))))

(defun mys--mys-send-setup-code-intern (name buffer)
  "Send setup code to BUFFER according to NAME, a string."
  (save-excursion
    (let ((setup-file (concat (mys--normalize-directory mys-temp-directory) "mys-" name "-setup-code.py"))
	  mys-return-result-p mys-store-result-p)
      (unless (file-readable-p setup-file)
	(with-temp-buffer
	  (insert (eval (car (read-from-string (concat "mys-" name "-setup-code")))))
	  (write-file setup-file)))
      (mys--execute-file-base setup-file (get-buffer-process buffer) nil buffer)
      )))

(defun mys--mys-send-completion-setup-code (buffer)
  "For Python see mys--mys-send-setup-code.
Argument BUFFER the buffer completion code is sent to."
  (mys--mys-send-setup-code-intern "shell-completion" buffer))

(defun mys--imys-import-module-completion ()
  "Setup Imys v0.11 or greater.

Used by `mys-imys-module-completion-string'"
  (let ((setup-file (concat (mys--normalize-directory mys-temp-directory) "mys-imys-module-completion.py")))
    (unless (file-readable-p setup-file)
      (with-temp-buffer
	(insert mys-imys-module-completion-code)
	(write-file setup-file)))
    (mys--execute-file-base setup-file nil nil (current-buffer) nil t)))

(defun mys-delete-temporary (&optional file filebuf)
  (when (file-readable-p file)
    (delete-file file))
  (when (buffer-live-p filebuf)
    (set-buffer filebuf)
    (set-buffer-modified-p 'nil)
    (kill-buffer filebuf)))

(defun mys--insert-offset-lines (line)
  "Fix offline amount, make error point at the correct LINE."
  (insert (make-string (- line (mys-count-lines (point-min) (point))) 10)))

(defun mys-execute-string-dedicated (&optional strg shell switch fast)
  "Send the argument STRG to an unique Python interpreter.

Optional SHELL SWITCH FAST
See also `mys-execute-region'."
  (interactive)
  (let ((strg (or strg (read-from-minibuffer "String: ")))
        (shell (or shell (default-value 'mys-shell-name))))
    (with-temp-buffer
      (insert strg)
      (mys-execute-region (point-min) (point-max) shell t switch fast))))

(defun mys--insert-execute-directory (directory &optional orig done)
  (let ((orig (or orig (point)))
        (done done))
    (if done (goto-char done) (goto-char (point-min)))
    (cond ((re-search-forward "^from __future__ import " nil t 1)
           (mys-forward-statement)
           (setq done (point))
           (mys--insert-execute-directory directory orig done))
          ((re-search-forward mys-encoding-string-re nil t 1)
           (setq done (point))
           (mys--insert-execute-directory directory orig done))
          ((re-search-forward mys-shebang-regexp nil t 1)
           (setq done (point))
           (mys--insert-execute-directory directory orig done))
          (t (forward-line 1)
             (unless (eq 9 (char-after)) (newline 1))
             (insert (concat "import os; os.chdir(\"" directory "\")\n"))))))

;; `mys-execute-line' calls void function, lp:1492054,  lp:1519859
(or (functionp 'indent-rigidly-left)
    (defun indent-rigidly--pop-undo ()
      (and (memq last-command '(indent-rigidly-left indent-rigidly-right
						    indent-rigidly-left-to-tab-stop
						    indent-rigidly-right-to-tab-stop))
	   (consp buffer-undo-list)
	   (eq (car buffer-undo-list) nil)
	   (pop buffer-undo-list)))

    (defun indent-rigidly-left (beg end)
      "Indent all lines between BEG and END leftward by one space."
      (interactive "r")
      (indent-rigidly--pop-undo)
      (indent-rigidly
       beg end
       (if (eq (current-bidi-paragraph-direction) 'right-to-left) 1 -1))))

(defun mys--qualified-module-name (file)
  "Return the fully qualified Python module name for FILE.

FILE is a string.  It may be an absolute or a relative path to
any file stored inside a Python package directory, although
typically it would be a (absolute or relative) path to a Python
source code file stored inside a Python package directory.

This collects all directories names that have a __init__.py
file in them, starting with the directory of FILE and moving up."
  (let ((module-name (file-name-sans-extension (file-name-nondirectory file)))
        (dirname     (file-name-directory (expand-file-name file))))
    (while (file-exists-p (expand-file-name "__init__.py" dirname))
      (setq module-name
            (concat
             (file-name-nondirectory (directory-file-name dirname))
             "."
             module-name))
      (setq dirname (file-name-directory (directory-file-name dirname))))
    module-name))

(defun mys-execute-import-or-reload (&optional shell)
  "Import the current buffer's file in a Python interpreter.

Optional SHELL
If the file has already been imported, then do reload instead to get
the latest version.

If the file's name does not end in \".py\", then do execfile instead.

If the current buffer is not visiting a file, do `mys-execute-buffer'
instead.

If the file local variable `mys-master-file' is non-nil, import or
reload the named file instead of the buffer's file.  The file may be
saved based on the value of `mys-execute-import-or-reload-save-p'.

See also `\\[mys-execute-region]'.

This may be preferable to `\\[mys-execute-buffer]' because:

 - Definitions stay in their module rather than appearing at top
   level, where they would clutter the global namespace and not affect
   uses of qualified names (MODULE.NAME).

 - The Python debugger gets line number information about the functions."
  (interactive)
  ;; Check file local variable mys-master-file
  (when mys-master-file
    (let* ((filename (expand-file-name mys-master-file))
           (buffer (or (get-file-buffer filename)
                       (find-file-noselect filename))))
      (set-buffer buffer)))
  (let ((mys-shell-name (or shell (mys-choose-shell)))
        (file (mys--buffer-filename-remote-maybe)))
    (if file
        (let ((proc (or
                     (ignore-errors (get-process (file-name-directory shell)))
                     (get-buffer-process (mys-shell nil nil mys-dedicated-process-p shell (or shell (default-value 'mys-shell-name)))))))
          ;; Maybe save some buffers
          (save-some-buffers (not mys-ask-about-save) nil)
          (mys--execute-file-base file proc
                                (if (string-match "\\.py$" file)
                                    (let ((m (mys--qualified-module-name (expand-file-name file))))
                                      (if (string-match "python2" mys-shell-name)
                                          (format "import sys\nif sys.modules.has_key('%s'):\n reload(%s)\nelse:\n import %s\n" m m m)
                                        (format "import sys,imp\nif'%s' in sys.modules:\n imp.reload(%s)\nelse:\n import %s\n" m m m)))
                                  ;; (format "execfile(r'%s')\n" file)
                                  (mys-execute-file-command file))))
      (mys-execute-buffer))))

;; mys-components-intern

;;  Keymap

;;  Utility stuff

(defun mys--computer-closing-inner-list ()
  "Compute indentation according to mys-closing-list-dedents-bos."
  (if mys-closing-list-dedents-bos
      (+ (current-indentation) mys-indent-offset)
    (1+ (current-column))))

(defun mys--compute-closing-outer-list ()
  "Compute indentation according to mys-closing-list-dedents-bos."
  (if mys-closing-list-dedents-bos
      (current-indentation)
    (+ (current-indentation) mys-indent-offset)))

(defun mys-compute-indentation-according-to-list-style (pps)
  "See `mys-indent-list-style'

Choices are:

\\='line-up-with-first-element (default)
\\='one-level-to-beginning-of-statement
\\='one-level-from-opener

See also mys-closing-list-dedents-bos"
  (goto-char (nth 1 pps))
  (cond
   ((and (looking-back mys-assignment-re (line-beginning-position))
         ;; flexible-indentation-lp-328842
         (not (eq (match-beginning 0) (line-beginning-position))))
    (+ (current-indentation) mys-indent-offset))
   (mys-closing-list-dedents-bos
    (current-indentation))
   (t (pcase mys-indent-list-style
        (`line-up-with-first-element
         (if (and (eq (car (syntax-after (point))) 4) (save-excursion (forward-char 1) (eolp)))
             ;; asdf = {
             ;;     'a':{
             ;;          'b':3,
             ;;          'c':4"
             ;;
             ;; b is at col 9
             ;; (+ (current-indentation) mys-indent-offset) would yield 8
             ;; EOL-case dedent starts if larger at least 2
             (cond ((< 1 (- (1+ (current-column))(+ (current-indentation) mys-indent-offset)))
                   (min (+ (current-indentation) mys-indent-offset)(1+ (current-column))))
                   (t (1+ (current-column))))
           (1+ (current-column))))
        (`one-level-to-beginning-of-statement
         (+ (current-indentation) mys-indent-offset))
        (`one-level-from-first-element
         (+ 1 (current-column) mys-indent-offset))))))

(defun mys-compute-indentation-closing-list (pps)
  (cond
   ((< 1 (nth 0 pps))
    (goto-char (nth 1 pps))
    ;; reach the outer list
    (goto-char (nth 1 (parse-partial-sexp (point-min) (point))))
    (mys--computer-closing-inner-list))
   ;; just close an maybe outer list
   ((eq 1 (nth 0 pps))
    (goto-char (nth 1 pps))
    (mys-compute-indentation-according-to-list-style pps))))

(defun mys-compute-indentation-in-list (pps line closing orig)
  (if closing
      (mys-compute-indentation-closing-list pps)
    (cond ((and (not line) (looking-back mys-assignment-re (line-beginning-position)))
	   (mys--fetch-indent-statement-above orig))
	  ;; (mys-compute-indentation-according-to-list-style pps iact orig origline line nesting repeat indent-offset liep)
	  (t (when (looking-back "[ \t]*\\(\\s(\\)" (line-beginning-position))
	       (goto-char (match-beginning 1))
	       (setq pps (parse-partial-sexp (point-min) (point))))
	     (mys-compute-indentation-according-to-list-style pps)))))

(defun mys-compute-comment-indentation (pps iact orig origline closing line nesting repeat indent-offset liep)
  (cond ((nth 8 pps)
         (goto-char (nth 8 pps))
         (cond ((and line (eq (current-column) (current-indentation)))
                (current-indentation))
               ((and (eq liep (line-end-position))mys-indent-honors-inline-comment)
                (current-column))
               ((mys--line-backward-maybe)
                (setq line t)
                (skip-chars-backward " \t")
                (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
               (t (if mys-indent-comments
                      (progn
                        (mys-backward-comment)
                        (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
                    0))))
        ((and
          (looking-at (concat "[ \t]*" comment-start))
          (looking-back "^[ \t]*" (line-beginning-position))(not line)
          (eq liep (line-end-position)))
         (if mys-indent-comments
             (progn
               (setq line t)
               (skip-chars-backward " \t\r\n\f")
               ;; as previous comment-line might
               ;; be wrongly unindented, travel
               ;; whole commented section
               (mys-backward-comment)
               (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
           0))
        ((and
          (looking-at (concat "[ \t]*" comment-start))
          (looking-back "^[ \t]*" (line-beginning-position))
          (not (eq liep (line-end-position))))
         (current-indentation))
        ((and (eq 11 (syntax-after (point))) line mys-indent-honors-inline-comment)
         (current-column))))

(defun mys-compute-indentation--at-closer-maybe (pps)
  (save-excursion
    (when (looking-back "^[ \t]*\\(\\s)\\)" (line-beginning-position))
      (forward-char -1)
      (setq pps (parse-partial-sexp (point-min) (point))))
    (when (and (nth 1 pps)
               (looking-at "[ \t]*\\(\\s)\\)") (nth 0 pps))
      (cond
       ;; no indent at empty argument (list
       ((progn (skip-chars-backward " \t\r\n\f") (ignore-errors (eq 4 (car (syntax-after (1- (point)))))))
        (current-indentation))
       ;; beyond list start?
       ((ignore-errors (< (progn (unless (bobp) (forward-line -1) (line-beginning-position))) (nth 1 (setq pps (parse-partial-sexp (point-min) (point))))))
        (mys-compute-indentation-according-to-list-style pps))
       (mys-closing-list-dedents-bos
        (- (current-indentation) mys-indent-offset))
       (t (current-indentation))))))

(defun mys-compute-indentation (&optional iact orig origline closing line nesting repeat indent-offset liep)
  "Compute Python indentation.

When HONOR-BLOCK-CLOSE-P is non-nil, statements such as `return',
`raise', `break', `continue', and `pass' force one level of dedenting.

ORIG keeps original position
ORIGLINE keeps line where compute started
CLOSING is t when started at a char delimiting a list as \"]})\"
LINE indicates being not at origline now
NESTING is currently ignored, if executing from inside a list
REPEAT counter enables checks against `mys-max-specpdl-size'
INDENT-OFFSET allows calculation of block-local values
LIEP stores line-end-position at point-of-interest
"
  (interactive "p")
  (save-excursion
    (save-restriction
      (widen)
      ;; in shell, narrow from previous prompt
      ;; needed by closing
      (let* ((orig (or orig (comys-marker (point))))
             (origline (or origline (mys-count-lines (point-min) (point))))
             ;; closing indicates: when started, looked
             ;; at a single closing parenthesis
             ;; line: moved already a line backward
             (liep (or liep (line-end-position)))
	     (line (or line (not (eq origline (mys-count-lines (point-min) (point))))))
             ;; (line line)
             (pps (progn
		    (unless (eq (current-indentation) (current-column))(skip-chars-backward " " (line-beginning-position)))
		    ;; (when (eq 5 (car (syntax-after (1- (point)))))
		    ;;   (forward-char -1))
		    (parse-partial-sexp (point-min) (point))))
             (closing
              (or closing
                  ;; returns update pps
                  ;; (and line (mys-compute-indentation--at-closer-maybe pps))
                  (mys-compute-indentation--at-closer-maybe pps)))
             ;; in a recursive call already
             (repeat (if repeat
                         (setq repeat (1+ repeat))
                       0))
             ;; nesting: started nesting a list
             (nesting nesting)
             (cubuf (current-buffer))
             erg indent this-line)
        (if (and (< repeat 1)
                 (and (comint-check-proc (current-buffer))
                      (re-search-backward (concat mys-shell-prompt-regexp "\\|" mys-imys-output-prompt-re "\\|" mys-imys-input-prompt-re) nil t 1)))
            ;; common recursion not suitable because of prompt
            (with-temp-buffer
              ;; (switch-to-buffer (current-buffer))
              (insert-buffer-substring cubuf (match-end 0) orig)
              (mys-mode)
              (setq indent (mys-compute-indentation)))
          (if (< mys-max-specpdl-size repeat)
              (error "`mys-compute-indentation' reached loops max.")
            (setq nesting (nth 0 pps))
            (setq indent
                  (cond ;; closing)
                   ((bobp)
		    (cond ((eq liep (line-end-position))
                           0)
			  ;; - ((looking-at mys-outdent-re)
			  ;; - (+ (or indent-offset (and mys-smart-indentation (mys-guess-indent-offset)) mys-indent-offset) (current-indentation)))
			  ((and line (looking-at mys-block-or-clause-re))
			   mys-indent-offset)
                          ((looking-at mys-outdent-re)
                           (+ (or indent-offset (and mys-smart-indentation (mys-guess-indent-offset)) mys-indent-offset) (current-indentation)))
                          (t
                           (current-indentation))))
                   ;; (cond ((eq liep (line-end-position))
                   ;;        0)
                   ;;       ((looking-at mys-outdent-re)
                   ;;        (+ (or indent-offset (and mys-smart-indentation (mys-guess-indent-offset)) mys-indent-offset) (current-indentation)))
                   ;;       (t
                   ;;        (current-indentation)))
		   ;; in string
		   ((and (nth 3 pps) (nth 8 pps))
		    (cond
		     ((mys--docstring-p (nth 8 pps))
		      (save-excursion
			;; (goto-char (match-beginning 0))
			(back-to-indentation)
			(if (looking-at "[uUrR]?\"\"\"\\|[uUrR]?'''")
			    (progn
			      (skip-chars-backward " \t\r\n\f")
			      (back-to-indentation)
			      (if (looking-at mys-def-or-class-re)
				  (+ (current-column) mys-indent-offset)
				(current-indentation)))
			  (skip-chars-backward " \t\r\n\f")
			  (back-to-indentation)
			  (current-indentation))))
		     (t 0)))
		   ((and (looking-at "\"\"\"\\|'''") (not (bobp)))
		    (mys-backward-statement)
		    (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
		   ;; comments
		   ((or
		     (nth 8 pps)
		     (and
		      (looking-at (concat "[ \t]*" comment-start))
		      (looking-back "^[ \t]*" (line-beginning-position))(not line))
		     (and (eq 11 (syntax-after (point))) line mys-indent-honors-inline-comment))
		    (mys-compute-comment-indentation pps iact orig origline closing line nesting repeat indent-offset liep))
		   ;; lists
		   ((nth 1 pps)
		    (if (< (nth 1 pps) (line-beginning-position))
                        ;; Compute according to `mys-indent-list-style'

                        ;; Choices are:

                        ;; \\='line-up-with-first-element (default)
                        ;; \\='one-level-to-beginning-of-statement
                        ;; \\='one-level-from-opener"

                        ;; See also mys-closing-list-dedents-bos
			(mys-compute-indentation-in-list pps line closing orig)
		      (back-to-indentation)
		      (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep)))
		   ((and (eq (char-after) (or ?\( ?\{ ?\[)) line)
		    (1+ (current-column)))
		   ((mys-preceding-line-backslashed-p)
		    (progn
		      (mys-backward-statement)
		      (setq this-line (mys-count-lines))
		      (if (< 1 (- origline this-line))
                          (mys--fetch-indent-line-above orig)
			(if (looking-at "from +\\([^ \t\n]+\\) +import")
			    mys-backslashed-lines-indent-offset
                          (+ (current-indentation) mys-continuation-offset)))))
		   ((and (looking-at mys-block-closing-keywords-re)
                         (eq liep (line-end-position)))
		    (skip-chars-backward "[ \t\r\n\f]")
		    (mys-backward-statement)
		    (cond ((looking-at mys-extended-block-or-clause-re)
			   (+
			    ;; (if mys-smart-indentation (mys-guess-indent-offset) indent-offset)
			    (or indent-offset (and mys-smart-indentation (mys-guess-indent-offset)) mys-indent-offset)
			    (current-indentation)))
                          ((looking-at mys-block-closing-keywords-re)
			   (- (current-indentation) (or indent-offset mys-indent-offset)))
                          (t (current-column))))
		   ((looking-at mys-block-closing-keywords-re)
		    (if (< (line-end-position) orig)
			;; #80, Lines after return cannot be correctly indented
			(if (looking-at "return[ \\t]*$")
			    (current-indentation)
			  (- (current-indentation) (or indent-offset mys-indent-offset)))
		      (mys-backward-block-or-clause)
		      (current-indentation)))
		   ;; ((and (looking-at mys-elif-re) (eq (mys-count-lines) origline))
		   ;; (when (mys--line-backward-maybe) (setq line t))
		   ;; (car (mys--clause-lookup-keyword mys-elif-re -1 nil origline)))
		   ((and (looking-at mys-minor-clause-re) (not line)
                         (eq liep (line-end-position)))

		    (cond
                     ((looking-at mys-case-re)
                      (mys--backward-regexp 'mys-match-re) (+ (current-indentation) mys-indent-offset))
                     ((looking-at mys-outdent-re)
		      ;; (and (mys--backward-regexp 'mys-block-or-clause-re) (current-indentation)))
		      (and (mys--go-to-keyword 'mys-block-or-clause-re (current-indentation) '< t) (current-indentation)))
		     ((bobp) 0)
		     (t (save-excursion
			  ;; (skip-chars-backward " \t\r\n\f")
			  (if (mys-backward-block)
			      ;; (mys--backward-regexp 'mys-block-or-clause-re)
			      (+ mys-indent-offset (current-indentation))
			    0)))))
		   ((looking-at mys-extended-block-or-clause-re)
		    (cond ((and (not line)
				(eq liep (line-end-position)))
			   (when (mys--line-backward-maybe) (setq line t))
			   (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
                          (t (+
			      (cond (indent-offset)
				    (mys-smart-indentation
				     (mys-guess-indent-offset))
				    (t mys-indent-offset))
			      (current-indentation)))))
		   ((and
		     (< (line-end-position) liep)
		     (eq (current-column) (current-indentation)))
		    (and
		     (looking-at mys-assignment-re)
		     (goto-char (match-end 0)))
		    ;; multiline-assignment
		    (if (and nesting (looking-at " *[[{(]") (not (looking-at ".+[]})][ \t]*$")))
			(+ (current-indentation) (or indent-offset mys-indent-offset))
		      (current-indentation)))
		   ((looking-at mys-assignment-re)
		    (mys-backward-statement)
		    (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
		   ((and (< (current-indentation) (current-column))(not line))
		    (back-to-indentation)
		    (unless line
		      (setq nesting (nth 0 (parse-partial-sexp (point-min) (point)))))
		    (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
		   ((and (not (mys--beginning-of-statement-p)) (not (and line (eq 11 (syntax-after (point))))))
		    (if (bobp)
			(current-column)
		      (if (eq (point) orig)
                          (progn
			    (when (mys--line-backward-maybe) (setq line t))
			    (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
			(mys-backward-statement)
			(mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))))
		   ((or (mys--statement-opens-block-p mys-extended-block-or-clause-re) (looking-at "@"))
		    (if (< (mys-count-lines) origline)
			(+ (or indent-offset (and mys-smart-indentation (mys-guess-indent-offset)) mys-indent-offset) (current-indentation))
		      (skip-chars-backward " \t\r\n\f")
		      (setq line t)
		      (back-to-indentation)
		      (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep)))
		   ((and mys-empty-line-closes-p (mys--after-empty-line))
		    (progn (mys-backward-statement)
			   (- (current-indentation) (or indent-offset mys-indent-offset))))
		   ;; still at orignial line
		   ((and (eq liep (line-end-position))
                         (save-excursion
			   (and (setq erg (mys--go-to-keyword 'mys-extended-block-or-clause-re (* mys-indent-offset 99)))
				;; maybe Result: (nil nil nil), which evaluates to `t'
				(not (bobp))
				(if (and (not indent-offset) mys-smart-indentation) (setq indent-offset (mys-guess-indent-offset)) t)
				(ignore-errors (< orig (or (mys-forward-block-or-clause) (point)))))))
		    (+ (car erg) (if mys-smart-indentation
				     (or indent-offset (mys-guess-indent-offset))
				   (or indent-offset mys-indent-offset))))
		   ((and (not line)
                         (eq liep (line-end-position))
                         (mys--beginning-of-statement-p))
		    (mys-backward-statement)
		    (mys-compute-indentation iact orig origline closing line nesting repeat indent-offset liep))
		   (t (current-indentation))))
            (when mys-verbose-p (message "%s" indent))
            indent))))))

(defun mys--uncomment-intern (beg end)
  (uncomment-region beg end)
  (when mys-uncomment-indents-p
    (mys-indent-region beg end)))

(defun mys-uncomment (&optional beg)
  "Uncomment commented lines at point.

If region is active, restrict uncommenting at region "
  (interactive "*")
  (save-excursion
    (save-restriction
      (when (use-region-p)
        (narrow-to-region (region-beginning) (region-end)))
      (let* (last
             (beg (or beg (save-excursion
                            (while (and (mys-backward-comment) (setq last (point))(prog1 (forward-line -1)(end-of-line))))
                            last))))
        (and (mys-forward-comment))
        (mys--uncomment-intern beg (point))))))

(defun mys-load-named-shells ()
  (interactive)
  (dolist (ele mys-known-shells)
    (let ((erg (mys-install-named-shells-fix-doc ele)))
      (eval (fset (car (read-from-string ele)) (car
						(read-from-string (concat "(lambda (&optional dedicated args) \"Start a `" erg "' interpreter.
Optional DEDICATED: with \\\\[universal-argument] start in a new
dedicated shell.
Optional ARGS overriding `mys-" ele "-command-args'.

Calls `mys-shell'
\"
  (interactive \"p\") (mys-shell dedicated args nil \""ele"\"))")))))))
  (when (functionp (car (read-from-string (car-safe mys-known-shells))))
    (when mys-verbose-p (message "mys-load-named-shells: %s" "installed named-shells"))))

;; (mys-load-named-shells)

(defun mys-load-file (file-name)
  "Load a Python file FILE-NAME into the Python process.

If the file has extension `.py' import or reload it as a module.
Treating it as a module keeps the global namespace clean, provides
function location information for debugging, and supports users of
module-qualified names."
  (interactive "f")
  (mys--execute-file-base file-name (get-buffer-process (get-buffer (mys-shell)))))

;;  Hooks
;;  arrange to kill temp files when Emacs exists

(when mys--warn-tmp-files-left-p
  (add-hook 'mys-mode-hook 'mys--warn-tmp-files-left))

(defun mys-guess-pdb-path ()
  "If mys-pdb-path isn't set, find location of pdb.py. "
  (interactive)
  (let ((ele (split-string (shell-command-to-string "whereis python")))
        erg)
    (while (or (not erg)(string= "" erg))
      (when (and (string-match "^/" (car ele)) (not (string-match "/man" (car ele))))
        (setq erg (shell-command-to-string (concat "find " (car ele) " -type f -name \"pdb.py\""))))
      (setq ele (cdr ele)))
    (if erg
        (message "%s" erg)
      (message "%s" "pdb.py not found, please customize `mys-pdb-path'"))
    erg))

(if mys-mode-output-map
    nil
  (setq mys-mode-output-map (make-sparse-keymap))
  (define-key mys-mode-output-map [button2]  'mys-mouseto-exception)
  (define-key mys-mode-output-map "\C-c\C-c" 'mys-goto-exception)
  ;; TBD: Disable all self-inserting keys.  This is bogus, we should
  ;; really implement this as *Python Output* buffer being read-only
  (mapc #' (lambda (key)
             (define-key mys-mode-output-map key
               #'(lambda () (interactive) (beep))))
           (where-is-internal 'self-insert-command)))

(defun mys-toggle-comment-auto-fill (&optional arg)
  "Toggles comment-auto-fill mode"
  (interactive "P")
  (if (or (and arg (< 0 (prefix-numeric-value arg)))
	  (and (boundp 'mys-comment-auto-fill-p)(not mys-comment-auto-fill-p)))
      (progn
        (set (make-local-variable 'mys-comment-auto-fill-p) t)
        (setq fill-column mys-comment-fill-column)
        (auto-fill-mode 1))
    (set (make-local-variable 'mys-comment-auto-fill-p) nil)
    (auto-fill-mode -1)))

(defun mys-comment-auto-fill-on ()
  (interactive)
  (mys-toggle-comment-auto-fill 1))

(defun mys-comment-auto-fill-off ()
  (interactive)
  (mys-toggle-comment-auto-fill -1))

(defun mys--set-auto-fill-values ()
  "Internal use by `mys--run-auto-fill-timer'"
  (let ((pps (parse-partial-sexp (point-min) (point))))
    (cond ((and (nth 4 pps)(numberp mys-comment-fill-column))
           (setq fill-column mys-comment-fill-column))
          ((and (nth 3 pps)(numberp mys-docstring-fill-column))
           (setq fill-column mys-docstring-fill-column))
          (t (setq fill-column mys-fill-column-orig)))))

(defun mys--run-auto-fill-timer ()
  "Set fill-column to values according to environment.

`mys-docstring-fill-column' resp. to `mys-comment-fill-column'."
  (when mys-auto-fill-mode
    (unless mys-autofill-timer
      (setq mys-autofill-timer
            (run-with-idle-timer
             mys-autofill-timer-delay t
             'mys--set-auto-fill-values)))))

;;  unconditional Hooks
;;  (orgstruct-mode 1)

(defun mys-complete-auto ()
  "Auto-complete function using mys-complete. "
  ;; disable company
  ;; (when company-mode (company-mode))
  (let ((modified (buffer-chars-modified-tick)))
    ;; don't try completion if buffer wasn't modified
    (unless (eq modified mys-complete-last-modified)
      (if mys-auto-completion-mode-p
          (if (string= "*PythonCompletions*" (buffer-name (current-buffer)))
              (sit-for 0.1 t)
            (if
                (eq mys-auto-completion-buffer (current-buffer))
                ;; not after whitespace, TAB or newline
                (unless (member (char-before) (list 32 9 10))
                  (mys-complete)
                  (setq mys-complete-last-modified (buffer-chars-modified-tick)))
              (setq mys-auto-completion-mode-p nil
                    mys-auto-completion-buffer nil)
              (cancel-timer mys--auto-complete-timer)))))))

;;  End-of- p

;;  Opens
(defun mys--statement-opens-block-p (&optional regexp)
  "Return position if the current statement opens a block
in stricter or wider sense.

For stricter sense specify regexp. "
  (let* ((regexp (or regexp mys-block-or-clause-re))
         (erg (mys--statement-opens-base regexp)))
    erg))

(defun mys--statement-opens-base (regexp)
  (let ((orig (point))
        erg)
    (save-excursion
      (back-to-indentation)
      (mys-forward-statement)
      (mys-backward-statement)
      (when (and
             (<= (line-beginning-position) orig)(looking-back "^[ \t]*" (line-beginning-position))(looking-at regexp))
        (setq erg (point))))
    erg))

(defun mys--statement-opens-clause-p ()
  "Return position if the current statement opens block or clause. "
  (mys--statement-opens-base mys-clause-re))

(defun mys--statement-opens-block-or-clause-p ()
  "Return position if the current statement opens block or clause. "
  (mys--statement-opens-base mys-block-or-clause-re))

(defun mys--statement-opens-class-p ()
  "If the statement opens a functions or class.

Return `t', nil otherwise. "
  (mys--statement-opens-base mys-class-re))

(defun mys--statement-opens-def-p ()
  "If the statement opens a functions or class.
Return `t', nil otherwise. "
  (mys--statement-opens-base mys-def-re))

(defun mys--statement-opens-def-or-class-p ()
  "If the statement opens a functions or class definition.
Return `t', nil otherwise. "
  (mys--statement-opens-base mys-def-or-class-re))

(defun mys--down-top-level (&optional regexp)
  "Go to the end of a top-level form.

When already at end, go to EOB."
  (end-of-line)
  (while (and (mys--forward-regexp (or regexp "^[[:graph:]]"))
	      (save-excursion
		(beginning-of-line)
		(or
		 (looking-at mys-clause-re)
		 (looking-at comment-start)))))
  (beginning-of-line)
  (and (looking-at regexp) (point)))

(defun mys--end-of-paragraph (regexp)
  (let* ((regexp (if (symbolp regexp) (symbol-value regexp)
                   regexp)))
    (while (and (not (eobp)) (re-search-forward regexp nil 'move 1) (nth 8 (parse-partial-sexp (point-min) (point)))))))

(defun mys--look-downward-for-beginning (regexp)
  "When above any beginning of FORM, search downward. "
  (let* ((orig (point))
         (erg orig)
         pps)
    (while (and (not (eobp)) (re-search-forward regexp nil t 1) (setq erg (match-beginning 0)) (setq pps (parse-partial-sexp (point-min) (point)))
                (or (nth 8 pps) (nth 1 pps))))
    (cond ((not (or (nth 8 pps) (nth 1 pps) (or (looking-at comment-start))))
           (when (ignore-errors (< orig erg))
             erg)))))

(defun mys-look-downward-for-clause (&optional ind orig regexp)
  "If beginning of other clause exists downward in current block.

If succesful return position. "
  (interactive)
  (unless (eobp)
    (let ((ind (or ind
                   (save-excursion
                     (mys-backward-statement)
                     (if (mys--statement-opens-block-p)
                         (current-indentation)
                       (- (current-indentation) mys-indent-offset)))))
          (orig (or orig (point)))
          (regexp (or regexp mys-extended-block-or-clause-re))
          erg)
      (end-of-line)
      (when (re-search-forward regexp nil t 1)
        (when (nth 8 (parse-partial-sexp (point-min) (point)))
          (while (and (re-search-forward regexp nil t 1)
                      (nth 8 (parse-partial-sexp (point-min) (point))))))
        ;; (setq last (point))
        (back-to-indentation)
        (unless (and (looking-at mys-clause-re)
                     (not (nth 8 (parse-partial-sexp (point-min) (point)))) (eq (current-indentation) ind))
          (progn (setq ind (current-indentation))
                 (while (and (mys-forward-statement-bol)(not (looking-at mys-clause-re))(<= ind (current-indentation)))))
          (if (and (looking-at mys-clause-re)
                   (not (nth 8 (parse-partial-sexp (point-min) (point))))
                   (< orig (point)))
              (setq erg (point))
            (goto-char orig))))
      erg)))

(defun mys-current-defun ()
  "Go to the outermost method or class definition in current scope.

Python value for `add-log-current-defun-function'.
This tells add-log.el how to find the current function/method/variable.
Returns name of class or methods definition, if found, nil otherwise.

See customizable variables `mys-current-defun-show' and `mys-current-defun-delay'."
  (interactive)
  (save-restriction
    (widen)
    (save-excursion
      (let ((erg (when (mys-backward-def-or-class)
                   (forward-word 1)
                   (skip-chars-forward " \t")
                   (prin1-to-string (symbol-at-point)))))
        (when (and erg mys-current-defun-show)
          (push-mark (point) t t) (skip-chars-forward "^ (")
          (exchange-point-and-mark)
          (sit-for mys-current-defun-delay t))
        erg))))

(defun mys--join-words-wrapping (words separator prefix line-length)
  (let ((lines ())
        (current-line prefix))
    (while words
      (let* ((word (car words))
             (maybe-line (concat current-line word separator)))
        (if (> (length maybe-line) line-length)
            (setq lines (cons (substring current-line 0 -1) lines)
                  current-line (concat prefix word separator " "))
          (setq current-line (concat maybe-line " "))))
      (setq words (cdr words)))
    (setq lines (cons (substring current-line 0 (- 0 (length separator) 1)) lines))
    (mapconcat 'identity (nreverse lines) "\n")))

(defun mys-sort-imports ()
  "Sort multiline imports.

Put point inside the parentheses of a multiline import and hit
\\[mys-sort-imports] to sort the imports lexicographically"
  (interactive)
  (save-excursion
    (let ((open-paren (ignore-errors (save-excursion (progn (up-list -1) (point)))))
          (close-paren (ignore-errors (save-excursion (progn (up-list 1) (point)))))
          sorted-imports)
      (when (and open-paren close-paren)
        (goto-char (1+ open-paren))
        (skip-chars-forward " \n\t")
        (setq sorted-imports
              (sort
               (delete-dups
                (split-string (buffer-substring
                               (point)
                               (save-excursion (goto-char (1- close-paren))
                                               (skip-chars-backward " \n\t")
                                               (point)))
                              ", *\\(\n *\\)?"))
               ;; XXX Should this sort case insensitively?
               'string-lessp))
        ;; Remove empty strings.
        (delete-region open-paren close-paren)
        (goto-char open-paren)
        (insert "(\n")
        (insert (mys--join-words-wrapping (remove "" sorted-imports) "," "    " 78))
        (insert ")")))))

(defun mys--in-literal (&optional lim)
  "Return non-nil if point is in a Python literal (a comment or string).
Optional argument LIM indicates the beginning of the containing form,
i.e. the limit on how far back to scan."
  (let* ((lim (or lim (point-min)))
         (state (parse-partial-sexp lim (point))))
    (cond
     ((nth 3 state) 'string)
     ((nth 4 state) 'comment))))

(defconst mys-help-address "mys-mode@python.org"
  "List dealing with usage and developing mys-mode.

Also accepts submission of bug reports, whilst a ticket at
http://launchpad.net/mys-mode
is preferable for that. ")

;;  Utilities

(defun mys-install-local-shells (&optional local)
  "Builds Mys-shell commands from executable found in LOCAL.

If LOCAL is empty, shell-command `find' searches beneath current directory.
Eval resulting buffer to install it, see customizable `mys-extensions'. "
  (interactive)
  (let* ((local-dir (if local
                        (expand-file-name local)
                      (read-from-minibuffer "Virtualenv directory: " default-directory)))
         (path-separator (if (string-match "/" local-dir)
                             "/"
                           "\\" t))
         (shells (split-string (shell-command-to-string (concat "find " local-dir " -maxdepth 9 -type f -executable -name \"*python\""))))
         prefix end orig curexe aktpath)
    (set-buffer (get-buffer-create mys-extensions))
    (erase-buffer)
    (dolist (elt shells)
      (setq prefix "")
      (setq curexe (substring elt (1+ (string-match "/[^/]+$" elt))))
      (setq aktpath (substring elt 0 (1+ (string-match "/[^/]+$" elt))))
      (dolist (prf (split-string aktpath (regexp-quote path-separator)))
        (unless (string= "" prf)
          (setq prefix (concat prefix (substring prf 0 1)))))
      (setq orig (point))
      (insert mys-shell-template)
      (setq end (point))
      (goto-char orig)
      (when (re-search-forward "\\<NAME\\>" end t 1)
        (replace-match (concat prefix "-" (substring elt (1+ (save-match-data (string-match "/[^/]+$" elt)))))t))
      (goto-char orig)
      (while (search-forward "DOCNAME" end t 1)
        (replace-match (if (string= "imys" curexe)
                           "Imys"
                         (capitalize curexe)) t))
      (goto-char orig)
      (when (search-forward "FULLNAME" end t 1)
        (replace-match elt t))
      (goto-char (point-max)))
    (emacs-lisp-mode)
    (if (file-readable-p (concat mys-install-directory "/" mys-extensions))
        (find-file (concat mys-install-directory "/" mys-extensions)))))

(defun mys--until-found (search-string liste)
  "Search liste for search-string until found. "
  (let ((liste liste) element)
    (while liste
      (if (member search-string (car liste))
          (setq element (car liste) liste nil))
      (setq liste (cdr liste)))
    (when element
      (while (and element (not (numberp element)))
        (if (member search-string (car element))
            (setq element (car element))
          (setq element (cdr element))))
      element)))

(defun mys--report-end-marker (process)
  ;; (message "mys--report-end-marker in %s" (current-buffer))
  (if (derived-mode-p 'comint-mode)
      (if (bound-and-true-p comint-last-prompt)
	  (car-safe comint-last-prompt)
	(dotimes (_ 3) (when (not (bound-and-true-p comint-last-prompt)))(sit-for 1 t))
	(and (bound-and-true-p comint-last-prompt)
	     (car-safe comint-last-prompt)))
    (if (markerp (process-mark process))
	(process-mark process)
      (progn
	(dotimes (_ 3) (when (not (markerp (process-mark process)))(sit-for 1 t)))
	(process-mark process)))))

(defun mys-which-def-or-class (&optional orig)
  "Returns concatenated `def' and `class' names.

In hierarchical order, if cursor is inside.

Returns \"???\" otherwise
Used by variable `which-func-functions' "
  (interactive)
  (let* ((orig (or orig (point)))
         (backindent 99999)
         (re mys-def-or-class-re
          ;; (concat mys-def-or-class-re "\\([[:alnum:]_]+\\)")
          )
         erg forward indent backward limit)
    (if
        (and (looking-at re)
             (not (nth 8 (parse-partial-sexp (point-min) (point)))))
        (progn
          (setq erg (list (match-string-no-properties 2)))
          (setq backindent (current-indentation)))
      ;; maybe inside a definition's symbol
      (or (eolp) (and (looking-at "[[:alnum:]]")(forward-word 1))))
    (if
        (and (not (and erg (eq 0 (current-indentation))))
             (setq limit (mys-backward-top-level))
             (looking-at re))
        (progn
          (push (match-string-no-properties 2)  erg)
          (setq indent (current-indentation)))
      (goto-char orig)
      (while (and
              (re-search-backward mys-def-or-class-re limit t 1)
              (< (current-indentation) backindent)
              (setq backindent (current-indentation))
              (setq backward (point))
              (or (< 0 (current-indentation))
                  (nth 8 (parse-partial-sexp (point-min) (point))))))
      (when (and backward
                 (goto-char backward)
                 (looking-at re))
        (push (match-string-no-properties 2)  erg)
        (setq indent (current-indentation))))
    ;; (goto-char orig))
    (if erg
        (progn
          (end-of-line)
          (while (and (re-search-forward mys-def-or-class-re nil t 1)
                      (<= (point) orig)
                      (< indent (current-indentation))
                      (or
                       (nth 8 (parse-partial-sexp (point-min) (point)))
                       (setq forward (point)))))
          (if forward
              (progn
                (goto-char forward)
                (save-excursion
                  (back-to-indentation)
                  (and (looking-at re)
                       (setq erg (list (car erg) (match-string-no-properties 2)))
                       ;; (< (mys-forward-def-or-class) orig)
                       ;; if match was beyond definition, nil
                       ;; (setq erg nil)
)))
            (goto-char orig))))
    (if erg
        (if (< 1 (length erg))
            (setq erg (mapconcat 'identity erg "."))
          (setq erg (car erg)))
      (setq erg "???"))
    (goto-char orig)
    erg))

(defun mys--fetch-first-mys-buffer ()
  "Returns first (I)Mys-buffer found in `buffer-list'"
  (let ((buli (buffer-list))
        erg)
    (while (and buli (not erg))
      (if (string-match "Python" (prin1-to-string (car buli)))
          (setq erg (car buli))
        (setq buli (cdr buli))))
    erg))

(defun mys-unload-mys-el ()
  "Unloads mys-mode delivered by shipped python.el

Removes mys-skeleton forms from abbrevs.
These would interfere when inserting forms heading a block"
  (interactive)
  (let (done)
    (when (featurep 'python) (unload-feature 'python t))
    (when (file-readable-p abbrev-file-name)
      (find-file abbrev-file-name)
      (goto-char (point-min))
      (while (re-search-forward "^.+mys-skeleton.+$" nil t 1)
        (setq done t)
        (delete-region (match-beginning 0) (1+ (match-end 0))))
      (when done (write-file abbrev-file-name)
            ;; now reload
            (read-abbrev-file abbrev-file-name))
      (kill-buffer (file-name-nondirectory abbrev-file-name)))))

(defmacro mys--kill-buffer-unconditional (buffer)
  "Kill buffer unconditional, kill buffer-process if existing. "
  `(let ((proc (get-buffer-process ,buffer))
         kill-buffer-query-functions)
     (ignore-errors
       (and proc (kill-process proc))
       (set-buffer ,buffer)
       (set-buffer-modified-p 'nil)
       (kill-buffer (current-buffer)))))

(defun mys-down-top-level ()
  "Go to beginning of next top-level form downward.

Returns position if successful, nil otherwise"
  (interactive)
  (let ((orig (point))
        erg)
    (while (and (not (eobp))
                (progn (end-of-line)
                       (re-search-forward "^[[:alpha:]_'\"]" nil 'move 1))
                (nth 8 (parse-partial-sexp (point-min) (point)))))
    (when (and (not (eobp)) (< orig (point)))
      (goto-char (match-beginning 0))
        (setq erg (point)))
    erg))

(defun mys-forward-top-level-bol ()
  "Go to end of top-level form at point, stop at next beginning-of-line.

Returns position successful, nil otherwise"
  (interactive)
  (let (erg)
    (mys-forward-top-level)
    (unless (or (eobp) (bolp))
      (forward-line 1)
      (beginning-of-line)
      (setq erg (point)))
    erg))

(defun mys-down (&optional indent)
  "Go to beginning one level below.

Of compound statement or definition at point.

Also honor a delimited form -- string or list.
Repeated call from there will behave like down-list.

Returns position if successful, nil otherwise"
  (interactive)
  (let* ((orig (point))
         erg
         (indent (or
                  indent
                  (if
                      (mys--beginning-of-statement-p)
                      (current-indentation)
                    (progn
                      (mys-backward-statement)
                      (current-indentation))))))
    (while (and (mys-forward-statement) (mys-forward-statement) (mys-backward-statement) (> (current-indentation) indent)))
    (cond ((= indent (current-indentation))
           (setq erg (point)))
          ((< (point) orig)
           (goto-char orig))
          ((and (eq (point) orig)
                (progn (forward-char 1)
                       (skip-chars-forward "^\"'[({" (line-end-position))
                       (member (char-after) (list ?\( ?\" ?\' ?\[ ?\{)))
                (setq erg (point)))))
    (unless erg
      (goto-char orig))
    erg))

(defun mys--thing-at-point (form &optional mark-decorators)
  "Returns buffer-substring of string-argument FORM as cons.

Text properties are stripped.
If MYS-MARK-DECORATORS, `def'- and `class'-forms include decorators
If BOL is t, from beginning-of-line"
  (interactive)
  (let* ((begform (intern-soft (concat "mys-backward-" form)))
         (endform (intern-soft (concat "mys-forward-" form)))
         (begcheckform (intern-soft (concat "mys--beginning-of-" form "-p")))
         (orig (point))
         beg end erg)
    (setq beg (if
                  (setq beg (funcall begcheckform))
                  beg
                (funcall begform)))
    (and mark-decorators
         (and (setq erg (mys-backward-decorator))
              (setq beg erg)))
    (setq end (funcall endform))
    (unless end (when (< beg (point))
                  (setq end (point))))
    (if (and beg end (<= beg orig) (<= orig end))
        (buffer-substring-no-properties beg end)
      nil)))

(defun mys--thing-at-point-bol (form &optional mark-decorators)
  (let* ((begform (intern-soft (concat "mys-backward-" form "-bol")))
         (endform (intern-soft (concat "mys-forward-" form "-bol")))
         (begcheckform (intern-soft (concat "mys--beginning-of-" form "-bol-p")))
         beg end erg)
    (setq beg (if
                  (setq beg (funcall begcheckform))
                  beg
                (funcall begform)))
    (when mark-decorators
      (save-excursion
        (when (setq erg (mys-backward-decorator))
          (setq beg erg))))
    (setq end (funcall endform))
    (unless end (when (< beg (point))
                  (setq end (point))))
    (cons beg end)))

(defun mys--mark-base (form &optional mark-decorators)
  "Returns boundaries of FORM, a cons.

If MYS-MARK-DECORATORS, `def'- and `class'-forms include decorators
If BOL is t, mark from beginning-of-line"
  (let* ((begform (intern-soft (concat "mys-backward-" form)))
         (endform (intern-soft (concat "mys-forward-" form)))
         (begcheckform (intern-soft (concat "mys--beginning-of-" form "-p")))
         (orig (point))
         beg end erg)
    (setq beg (if
                  (setq beg (funcall begcheckform))
                  beg
                (funcall begform)))
    (and mark-decorators
         (and (setq erg (mys-backward-decorator))
              (setq beg erg)))
    (push-mark)
    (setq end (funcall endform))
    (unless end (when (< beg (point))
                  (setq end (point))))
    (if (and beg end (<= beg orig) (<= orig end))
        (progn
	  (cons beg end)
	  (exchange-point-and-mark))
      nil)))

(defun mys--mark-base-bol (form &optional mark-decorators)
  (let* ((begform (intern-soft (concat "mys-backward-" form "-bol")))
         (endform (intern-soft (concat "mys-forward-" form "-bol")))
         (begcheckform (intern-soft (concat "mys--beginning-of-" form "-bol-p")))
         beg end erg)
    (if (functionp begcheckform)
	(or (setq beg (funcall begcheckform))
	    (if (functionp begform)
		(setq beg (funcall begform))
	      (error (concat "mys--mark-base-bol: " begform " don't exist!" ))))
      (error (concat "mys--mark-base-bol: " begcheckform " don't exist!" )))
    (when mark-decorators
      (save-excursion
        (when (setq erg (mys-backward-decorator))
          (setq beg erg))))
    (if (functionp endform)
	(setq end (funcall endform))
      (error (concat "mys--mark-base-bol: " endform " don't exist!" )))
    (push-mark beg t t)
    (unless end (when (< beg (point))
                  (setq end (point))))
    (cons beg end)))

(defun mys-mark-base (form &optional mark-decorators)
  "Calls mys--mark-base, returns bounds of form, a cons. "
  (let* ((bounds (mys--mark-base form mark-decorators))
         (beg (car bounds)))
    (push-mark beg t t)
    bounds))

(defun mys-backward-same-level-intern (indent)
  (while (and
          (mys-backward-statement)
          (< indent (current-indentation) ))))

(defun mys-backward-same-level ()
  "Go form backward keeping indent level if possible.

If inside a delimited form --string or list-- go to its beginning.
If not at beginning of a statement or block, go to its beginning.
If at beginning of a statement or block,
go to previous beginning of at point.
If no further element at same level, go one level up."
  (interactive)
  (let* ((pps (parse-partial-sexp (point-min) (point)))
         (erg (cond ((nth 8 pps) (goto-char (nth 8 pps)))
                    ((nth 1 pps) (goto-char (nth 1 pps)))
                    (t (if (eq (current-column) (current-indentation))
                           (mys-backward-same-level-intern (current-indentation))
                         (back-to-indentation)
                         (mys-backward-same-level))))))
    erg))

(defun mys-forward-same-level ()
  "Go form forward keeping indent level if possible.

If inside a delimited form --string or list-- go to its beginning.
If not at beginning of a statement or block, go to its beginning.
If at beginning of a statement or block, go to previous beginning.
If no further element at same level, go one level up."
  (interactive)
  (let (erg)
    (unless (mys-beginning-of-statement-p)
      (mys-backward-statement))
    (setq erg (mys-down (current-indentation)))
    erg))

(defun mys--end-of-buffer-p ()
  "Returns position, if cursor is at the end of buffer, nil otherwise. "
  (when (eobp)(point)))

(defun mys-sectionize-region (&optional beg end)
  "Markup code in region as section.

Use current region unless optional args BEG END are delivered."
  (interactive "*")
  (let ((beg (or beg (region-beginning)))
        (end (or (and end (comys-marker end)) (comys-marker (region-end)))))
    (save-excursion
      (goto-char beg)
      (unless (mys-empty-line-p) (split-line))
      (beginning-of-line)
      (insert mys-section-start)
      (goto-char end)
      (unless (mys-empty-line-p) (newline 1))
      (insert mys-section-end))))

(defun mys-execute-section-prepare (&optional shell)
  "Execute section at point. "
  (save-excursion
    (let ((start (when (or (mys--beginning-of-section-p)
                           (mys-backward-section))
                   (forward-line 1)
                   (beginning-of-line)
                   (point))))
      (if (and start (mys-forward-section))
          (progn
            (beginning-of-line)
            (skip-chars-backward " \t\r\n\f")
            (if shell
                (funcall (car (read-from-string (concat "mys-execute-region-" shell))) start (point))
              (mys-execute-region start (point))))
        (error "Can't see `mys-section-start' resp. `mys-section-end'")))))

(defun mys--narrow-prepare (name)
  "Used internally. "
  (save-excursion
    (let ((start (cond ((string= name "statement")
                        (if (mys--beginning-of-statement-p)
                            (point)
                          (mys-backward-statement-bol)))
                       ((funcall (car (read-from-string (concat "mys--statement-opens-" name "-p")))))
                       (t (funcall (car (read-from-string (concat "mys-backward-" name "-bol"))))))))
      (funcall (car (read-from-string (concat "mys-forward-" name))))
      (narrow-to-region (point) start))))

(defun mys--forms-report-result (erg &optional iact)
  (let ((res (ignore-errors (buffer-substring-no-properties (car-safe erg) (cdr-safe erg)))))
    (when (and res iact)
      (goto-char (car-safe erg))
      (set-mark (point))
      (goto-char (cdr-safe erg)))
    res))

(defun mys-toggle-shell-fontification (msg)
  "Toggles value of `mys-shell-fontify-p'. "
  (interactive "p")

  (if (setq mys-shell-fontify-p (not mys-shell-fontify-p))
      (progn
	(mys-shell-font-lock-turn-on))
    (mys-shell-font-lock-turn-off))
    (when msg (message "mys-shell-fontify-p set to: %s" mys-shell-fontify-p)))

(defun mys-toggle-execute-use-temp-file ()
  (interactive)
  (setq mys--execute-use-temp-file-p (not mys--execute-use-temp-file-p)))

(defun mys--close-intern (regexp)
  "Core function, internal used only. "
  (let ((cui (car (mys--go-to-keyword regexp))))
    (message "%s" cui)
    (mys--end-base regexp (point))
    (forward-line 1)
    (if mys-close-provides-newline
        (unless (mys-empty-line-p) (split-line))
      (fixup-whitespace))
    (indent-to-column cui)
    cui))

(defun mys--backward-regexp-fast (regexp)
  "Search backward next regexp not in string or comment.

Return and move to match-beginning if successful"
  (save-match-data
    (let (last)
      (while (and
              (re-search-backward regexp nil 'move 1)
              (setq last (match-beginning 0))
              (nth 8 (parse-partial-sexp (point-min) (point)))))
      (unless (nth 8 (parse-partial-sexp (point-min) (point)))
        last))))

(defun mys-indent-and-forward (&optional indent)
  "Indent current line according to mode, move one line forward.

If optional INDENT is given, use it"
  (interactive "*")
  (beginning-of-line)
  (when (member (char-after) (list 32 9 10 12 13)) (delete-region (point) (progn (skip-chars-forward " \t\r\n\f")(point))))
  (indent-to (or indent (mys-compute-indentation)))
  (if (eobp)
      (newline-and-indent)
    (forward-line 1))
  (back-to-indentation))

(defun mys--indent-line-by-line (beg end)
  "Indent every line until end to max reasonable extend.

Starts from second line of region specified
BEG END deliver the boundaries of region to work within"
  (goto-char beg)
  (mys-indent-and-forward)
  ;; (forward-line 1)
  (while (< (line-end-position) end)
    (if (mys-empty-line-p)
	(forward-line 1)
      (mys-indent-and-forward)))
  (unless (mys-empty-line-p) (mys-indent-and-forward)))

(defun mys-indent-region (&optional beg end no-check)
  "Reindent a region delimited by BEG END.

In case first line accepts an indent, keep the remaining
lines relative.
Otherwise lines in region get outmost indent,
same with optional argument

In order to shift a chunk of code, start with second line.

Optional BEG: used by tests
Optional END: used by tests
Optional NO-CHECK: used by tests
"
  (interactive "*")
  (or no-check (use-region-p) (error "Don't see an active region"))
  (let ((end (comys-marker (or end (region-end)))))
    (goto-char (or beg (region-beginning)))
    (beginning-of-line)
    (setq beg (point))
    (skip-chars-forward " \t\r\n\f")
    (mys--indent-line-by-line beg end)))

(defun mys-find-imports ()
  "Find top-level imports.

Returns imports"
  (interactive)
  (let (imports erg)
    (save-excursion
      (if (eq major-mode 'comint-mode)
	  (progn
	    (re-search-backward comint-prompt-regexp nil t 1)
	    (goto-char (match-end 0))
	    (while (re-search-forward
		    "import *[A-Za-z_][A-Za-z_0-9].*\\|^from +[A-Za-z_][A-Za-z_0-9.]+ +import .*" nil t)
	      (setq imports
		    (concat
		     imports
		     (replace-regexp-in-string
		      "[\\]\r?\n?\s*" ""
		      (buffer-substring-no-properties (match-beginning 0) (point))) ";")))
	    (when (ignore-errors (string-match ";" imports))
	      (setq imports (split-string imports ";" t))
	      (dolist (ele imports)
		(and (string-match "import" ele)
		     (if erg
			 (setq erg (concat erg ";" ele))
		       (setq erg ele)))
		(setq imports erg))))
	(goto-char (point-min))
	(while (re-search-forward
		"^import *[A-Za-z_][A-Za-z_0-9].*\\|^from +[A-Za-z_][A-Za-z_0-9.]+ +import .*" nil t)
	  (unless (mys--end-of-statement-p)
	    (mys-forward-statement))
	  (setq imports
		(concat
		 imports
		 (replace-regexp-in-string
		  "[\\]\r*\n*\s*" ""
		  (buffer-substring-no-properties (match-beginning 0) (point))) ";")))))
    ;; (and imports
    ;; (setq imports (replace-regexp-in-string ";$" "" imports)))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" imports))
    imports))

(defun mys-kill-buffer-unconditional (&optional buffer)
  "Kill buffer unconditional, kill buffer-process if existing."
  (interactive
   (list (current-buffer)))
  (let ((buffer (or (and (bufferp buffer) buffer)
		    (get-buffer (current-buffer))))
	proc kill-buffer-query-functions)
    (if (buffer-live-p buffer)
        (progn
          (setq proc (get-buffer-process buffer))
          (and proc (kill-process proc))
          (set-buffer buffer)
          (set-buffer-modified-p 'nil)
          (kill-buffer (current-buffer)))
      (message "Can't see a buffer %s" buffer))))

;; mys-components-comys-forms


(defun mys-comys-block ()
  "Copy block at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "block")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-block-or-clause ()
  "Copy block-or-clause at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "block-or-clause")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-buffer ()
  "Copy buffer at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "buffer")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-class ()
  "Copy class at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "class")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-clause ()
  "Copy clause at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "clause")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-def ()
  "Copy def at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "def")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-def-or-class ()
  "Copy def-or-class at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "def-or-class")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-expression ()
  "Copy expression at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "expression")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-indent ()
  "Copy indent at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "indent")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-line ()
  "Copy line at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "line")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-minor-block ()
  "Copy minor-block at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "minor-block")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-paragraph ()
  "Copy paragraph at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "paragraph")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-partial-expression ()
  "Copy partial-expression at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "partial-expression")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-region ()
  "Copy region at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "region")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-statement ()
  "Copy statement at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "statement")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-top-level ()
  "Copy top-level at point.

Store data in kill ring, so it might yanked back."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "top-level")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-block-bol ()
  "Delete block bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "block")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-block-or-clause-bol ()
  "Delete block-or-clause bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "block-or-clause")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-buffer-bol ()
  "Delete buffer bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "buffer")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-class-bol ()
  "Delete class bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "class")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-clause-bol ()
  "Delete clause bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "clause")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-def-bol ()
  "Delete def bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "def")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-def-or-class-bol ()
  "Delete def-or-class bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "def-or-class")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-expression-bol ()
  "Delete expression bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "expression")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-indent-bol ()
  "Delete indent bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "indent")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-line-bol ()
  "Delete line bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "line")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-minor-block-bol ()
  "Delete minor-block bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "minor-block")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-paragraph-bol ()
  "Delete paragraph bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "paragraph")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-partial-expression-bol ()
  "Delete partial-expression bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "partial-expression")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-region-bol ()
  "Delete region bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "region")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-statement-bol ()
  "Delete statement bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "statement")))
      (comys-region-as-kill (car erg) (cdr erg)))))

(defun mys-comys-top-level-bol ()
  "Delete top-level bol at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (save-excursion
    (let ((erg (mys--mark-base-bol "top-level")))
      (comys-region-as-kill (car erg) (cdr erg)))))

;; mys-components-delete-forms


(defun mys-delete-block ()
  "Delete BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-block-or-clause ()
  "Delete BLOCK-OR-CLAUSE at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "block-or-clause")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-class (&optional arg)
  "Delete CLASS at point until `beginning-of-line'.

Don't store data in kill ring.
With ARG \\[universal-argument] or `mys-mark-decorators' set to t, `decorators' are included."
  (interactive "P")
 (let* ((mys-mark-decorators (or arg mys-mark-decorators))
        (erg (mys--mark-base "class" mys-mark-decorators)))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-clause ()
  "Delete CLAUSE at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "clause")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-def (&optional arg)
  "Delete DEF at point until `beginning-of-line'.

Don't store data in kill ring.
With ARG \\[universal-argument] or `mys-mark-decorators' set to t, `decorators' are included."
  (interactive "P")
 (let* ((mys-mark-decorators (or arg mys-mark-decorators))
        (erg (mys--mark-base "def" mys-mark-decorators)))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-def-or-class (&optional arg)
  "Delete DEF-OR-CLASS at point until `beginning-of-line'.

Don't store data in kill ring.
With ARG \\[universal-argument] or `mys-mark-decorators' set to t, `decorators' are included."
  (interactive "P")
 (let* ((mys-mark-decorators (or arg mys-mark-decorators))
        (erg (mys--mark-base "def-or-class" mys-mark-decorators)))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-elif-block ()
  "Delete ELIF-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "elif-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-else-block ()
  "Delete ELSE-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "else-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-except-block ()
  "Delete EXCEPT-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "except-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-for-block ()
  "Delete FOR-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "for-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-if-block ()
  "Delete IF-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "if-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-indent ()
  "Delete INDENT at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "indent")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-minor-block ()
  "Delete MINOR-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "minor-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-statement ()
  "Delete STATEMENT at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "statement")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-try-block ()
  "Delete TRY-BLOCK at point until `beginning-of-line'.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base-bol "try-block")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-comment ()
  "Delete COMMENT at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "comment")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-line ()
  "Delete LINE at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "line")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-paragraph ()
  "Delete PARAGRAPH at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "paragraph")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-expression ()
  "Delete EXPRESSION at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "expression")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-partial-expression ()
  "Delete PARTIAL-EXPRESSION at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "partial-expression")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-section ()
  "Delete SECTION at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "section")))
    (delete-region (car erg) (cdr erg))))

(defun mys-delete-top-level ()
  "Delete TOP-LEVEL at point.

Don't store data in kill ring."
  (interactive)
  (let ((erg (mys--mark-base "top-level")))
    (delete-region (car erg) (cdr erg))))

;; mys-components-mark-forms


(defun mys-mark-comment ()
  "Mark comment at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "comment")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-expression ()
  "Mark expression at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "expression")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-line ()
  "Mark line at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "line")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-paragraph ()
  "Mark paragraph at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "paragraph")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-partial-expression ()
  "Mark partial-expression at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "partial-expression")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-section ()
  "Mark section at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "section")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-top-level ()
  "Mark top-level at point.

Return beginning and end positions of marked area, a cons."
  (interactive)
  (mys--mark-base "top-level")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))

(defun mys-mark-assignment ()
  "Mark assignment, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "assignment")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-block ()
  "Mark block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-block-or-clause ()
  "Mark block-or-clause, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "block-or-clause")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-class (&optional arg)
  "Mark class, take beginning of line positions. 

With ARG \\[universal-argument] or `mys-mark-decorators' set to t, decorators are marked too.
Return beginning and end positions of region, a cons."
  (interactive "P")
  (let ((mys-mark-decorators (or arg mys-mark-decorators)))
    (mys--mark-base-bol "class" mys-mark-decorators))
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-clause ()
  "Mark clause, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "clause")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-def (&optional arg)
  "Mark def, take beginning of line positions. 

With ARG \\[universal-argument] or `mys-mark-decorators' set to t, decorators are marked too.
Return beginning and end positions of region, a cons."
  (interactive "P")
  (let ((mys-mark-decorators (or arg mys-mark-decorators)))
    (mys--mark-base-bol "def" mys-mark-decorators))
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-def-or-class (&optional arg)
  "Mark def-or-class, take beginning of line positions. 

With ARG \\[universal-argument] or `mys-mark-decorators' set to t, decorators are marked too.
Return beginning and end positions of region, a cons."
  (interactive "P")
  (let ((mys-mark-decorators (or arg mys-mark-decorators)))
    (mys--mark-base-bol "def-or-class" mys-mark-decorators))
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-elif-block ()
  "Mark elif-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "elif-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-else-block ()
  "Mark else-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "else-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-except-block ()
  "Mark except-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "except-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-for-block ()
  "Mark for-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "for-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-if-block ()
  "Mark if-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "if-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-indent ()
  "Mark indent, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "indent")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-minor-block ()
  "Mark minor-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "minor-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-statement ()
  "Mark statement, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "statement")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
(defun mys-mark-try-block ()
  "Mark try-block, take beginning of line positions. 

Return beginning and end positions of region, a cons."
  (interactive)
  (mys--mark-base-bol "try-block")
  (exchange-point-and-mark)
  (cons (region-beginning) (region-end)))
;; mys-components-close-forms


(defun mys-close-block ()
  "Close block at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-block-re))

(defun mys-close-class ()
  "Close class at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-class-re))

(defun mys-close-clause ()
  "Close clause at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-clause-re))

(defun mys-close-block-or-clause ()
  "Close block-or-clause at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-block-or-clause-re))

(defun mys-close-def ()
  "Close def at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-def-re))

(defun mys-close-def-or-class ()
  "Close def-or-class at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-def-or-class-re))

(defun mys-close-minor-block ()
  "Close minor-block at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-minor-block-re))

(defun mys-close-statement ()
  "Close statement at point.

Set indent level to that of beginning of function definition.

If final line isn't empty
and `mys-close-block-provides-newline' non-nil,
insert a newline."
  (interactive "*")
  (mys--close-intern 'mys-statement-re))

;; mys-components-kill-forms


(defun mys-kill-comment ()
  "Delete comment at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "comment")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-line ()
  "Delete line at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "line")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-paragraph ()
  "Delete paragraph at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "paragraph")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-expression ()
  "Delete expression at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "expression")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-partial-expression ()
  "Delete partial-expression at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "partial-expression")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-section ()
  "Delete section at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "section")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-top-level ()
  "Delete top-level at point.

Stores data in kill ring"
  (interactive "*")
  (let ((erg (mys--mark-base "top-level")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-block ()
  "Delete block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-block-or-clause ()
  "Delete block-or-clause at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "block-or-clause")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-class ()
  "Delete class at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "class")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-clause ()
  "Delete clause at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "clause")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-def ()
  "Delete def at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "def")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-def-or-class ()
  "Delete def-or-class at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "def-or-class")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-elif-block ()
  "Delete elif-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "elif-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-else-block ()
  "Delete else-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "else-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-except-block ()
  "Delete except-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "except-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-for-block ()
  "Delete for-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "for-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-if-block ()
  "Delete if-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "if-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-indent ()
  "Delete indent at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "indent")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-minor-block ()
  "Delete minor-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "minor-block")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-statement ()
  "Delete statement at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "statement")))
    (kill-region (car erg) (cdr erg))))

(defun mys-kill-try-block ()
  "Delete try-block at point.

Stores data in kill ring. Might be yanked back using `C-y'."
  (interactive "*")
  (let ((erg (mys--mark-base-bol "try-block")))
    (kill-region (car erg) (cdr erg))))

;; mys-components-forms-code

(defun mys-block (&optional decorators)
  "When called interactively, mark Block at point.

From a programm, return source of Block at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "block" (or decorators mys-mark-decorators))
    (mys--thing-at-point "block" (or decorators mys-mark-decorators))))

(defun mys-block-or-clause (&optional decorators)
  "When called interactively, mark Block-Or-Clause at point.

From a programm, return source of Block-Or-Clause at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "block-or-clause" (or decorators mys-mark-decorators))
    (mys--thing-at-point "block-or-clause" (or decorators mys-mark-decorators))))

(defun mys-buffer ()
  "When called interactively, mark Buffer at point.

From a programm, return source of Buffer at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "buffer")
    (mys--thing-at-point "buffer")))

(defun mys-class (&optional decorators)
  "When called interactively, mark Class at point.

From a programm, return source of Class at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "class" (or decorators mys-mark-decorators))
    (mys--thing-at-point "class" (or decorators mys-mark-decorators))))

(defun mys-clause ()
  "When called interactively, mark Clause at point.

From a programm, return source of Clause at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "clause")
    (mys--thing-at-point "clause")))

(defun mys-def (&optional decorators)
  "When called interactively, mark Def at point.

From a programm, return source of Def at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "def" (or decorators mys-mark-decorators))
    (mys--thing-at-point "def" (or decorators mys-mark-decorators))))

(defun mys-def-or-class (&optional decorators)
  "When called interactively, mark Def-Or-Class at point.

From a programm, return source of Def-Or-Class at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "def-or-class" (or decorators mys-mark-decorators))
    (mys--thing-at-point "def-or-class" (or decorators mys-mark-decorators))))

(defun mys-expression ()
  "When called interactively, mark Expression at point.

From a programm, return source of Expression at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "expression")
    (mys--thing-at-point "expression")))

(defun mys-indent ()
  "When called interactively, mark Indent at point.

From a programm, return source of Indent at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "indent")
    (mys--thing-at-point "indent")))

(defun mys-line ()
  "When called interactively, mark Line at point.

From a programm, return source of Line at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "line")
    (mys--thing-at-point "line")))

(defun mys-minor-block ()
  "When called interactively, mark Minor-Block at point.

From a programm, return source of Minor-Block at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "minor-block")
    (mys--thing-at-point "minor-block")))

(defun mys-paragraph ()
  "When called interactively, mark Paragraph at point.

From a programm, return source of Paragraph at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "paragraph")
    (mys--thing-at-point "paragraph")))

(defun mys-partial-expression ()
  "When called interactively, mark Partial-Expression at point.

From a programm, return source of Partial-Expression at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "partial-expression")
    (mys--thing-at-point "partial-expression")))

(defun mys-region ()
  "When called interactively, mark Region at point.

From a programm, return source of Region at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "region")
    (mys--thing-at-point "region")))

(defun mys-statement ()
  "When called interactively, mark Statement at point.

From a programm, return source of Statement at point, a string."
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "statement")
    (mys--thing-at-point "statement")))

(defun mys-top-level (&optional decorators)
  "When called interactively, mark Top-Level at point.

From a programm, return source of Top-Level at point, a string.

Optional arg DECORATORS: include decorators when called at def or class.
Also honors setting of `mys-mark-decorators'"
  (interactive)
  (if (called-interactively-p 'interactive)
      (mys--mark-base "top-level" (or decorators mys-mark-decorators))
    (mys--thing-at-point "top-level" (or decorators mys-mark-decorators))))

;; mys-components-forms-code.el ends here
;; mys-components-booleans-end-forms


(defun mys--end-of-comment-p ()
  "If cursor is at the end of a comment.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-comment)
      (mys-forward-comment)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-expression-p ()
  "If cursor is at the end of a expression.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-expression)
      (mys-forward-expression)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-line-p ()
  "If cursor is at the end of a line.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-line)
      (mys-forward-line)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-paragraph-p ()
  "If cursor is at the end of a paragraph.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-paragraph)
      (mys-forward-paragraph)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-partial-expression-p ()
  "If cursor is at the end of a partial-expression.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-partial-expression)
      (mys-forward-partial-expression)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-section-p ()
  "If cursor is at the end of a section.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-section)
      (mys-forward-section)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-top-level-p ()
  "If cursor is at the end of a top-level.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-top-level)
      (mys-forward-top-level)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-assignment-bol-p ()
  "If at `beginning-of-line' at the end of a assignment.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-assignment-bol)
      (mys-forward-assignment-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-block-bol-p ()
  "If at `beginning-of-line' at the end of a block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-block-bol)
      (mys-forward-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-block-or-clause-bol-p ()
  "If at `beginning-of-line' at the end of a block-or-clause.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-block-or-clause-bol)
      (mys-forward-block-or-clause-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-class-bol-p ()
  "If at `beginning-of-line' at the end of a class.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-class-bol)
      (mys-forward-class-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-clause-bol-p ()
  "If at `beginning-of-line' at the end of a clause.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-clause-bol)
      (mys-forward-clause-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-def-bol-p ()
  "If at `beginning-of-line' at the end of a def.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-def-bol)
      (mys-forward-def-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-def-or-class-bol-p ()
  "If at `beginning-of-line' at the end of a def-or-class.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-def-or-class-bol)
      (mys-forward-def-or-class-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-elif-block-bol-p ()
  "If at `beginning-of-line' at the end of a elif-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-elif-block-bol)
      (mys-forward-elif-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-else-block-bol-p ()
  "If at `beginning-of-line' at the end of a else-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-else-block-bol)
      (mys-forward-else-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-except-block-bol-p ()
  "If at `beginning-of-line' at the end of a except-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-except-block-bol)
      (mys-forward-except-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-for-block-bol-p ()
  "If at `beginning-of-line' at the end of a for-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-for-block-bol)
      (mys-forward-for-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-if-block-bol-p ()
  "If at `beginning-of-line' at the end of a if-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-if-block-bol)
      (mys-forward-if-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-indent-bol-p ()
  "If at `beginning-of-line' at the end of a indent.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-indent-bol)
      (mys-forward-indent-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-minor-block-bol-p ()
  "If at `beginning-of-line' at the end of a minor-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-minor-block-bol)
      (mys-forward-minor-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-try-block-bol-p ()
  "If at `beginning-of-line' at the end of a try-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-try-block-bol)
      (mys-forward-try-block-bol)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-assignment-p ()
  "If cursor is at the end of a assignment.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-assignment)
      (mys-forward-assignment)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-block-p ()
  "If cursor is at the end of a block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-block)
      (mys-forward-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-block-or-clause-p ()
  "If cursor is at the end of a block-or-clause.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-block-or-clause)
      (mys-forward-block-or-clause)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-class-p ()
  "If cursor is at the end of a class.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-class)
      (mys-forward-class)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-clause-p ()
  "If cursor is at the end of a clause.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-clause)
      (mys-forward-clause)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-def-p ()
  "If cursor is at the end of a def.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-def)
      (mys-forward-def)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-def-or-class-p ()
  "If cursor is at the end of a def-or-class.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-def-or-class)
      (mys-forward-def-or-class)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-elif-block-p ()
  "If cursor is at the end of a elif-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-elif-block)
      (mys-forward-elif-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-else-block-p ()
  "If cursor is at the end of a else-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-else-block)
      (mys-forward-else-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-except-block-p ()
  "If cursor is at the end of a except-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-except-block)
      (mys-forward-except-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-for-block-p ()
  "If cursor is at the end of a for-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-for-block)
      (mys-forward-for-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-if-block-p ()
  "If cursor is at the end of a if-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-if-block)
      (mys-forward-if-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-indent-p ()
  "If cursor is at the end of a indent.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-indent)
      (mys-forward-indent)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-minor-block-p ()
  "If cursor is at the end of a minor-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-minor-block)
      (mys-forward-minor-block)
      (when (eq orig (point))
        orig))))

(defun mys--end-of-try-block-p ()
  "If cursor is at the end of a try-block.
Return position, nil otherwise."
  (let ((orig (point)))
    (save-excursion
      (mys-backward-try-block)
      (mys-forward-try-block)
      (when (eq orig (point))
        orig))))

;; mys-components-exec-forms

;; Execute forms at point

(defun mys-execute-try-block ()
  "Send try-block at point to Python default interpreter."
  (interactive)
  (let ((beg (prog1
                 (or (mys--beginning-of-try-block-p)
                     (save-excursion
                       (mys-backward-try-block)))))
        (end (save-excursion
               (mys-forward-try-block))))
    (mys-execute-region beg end)))

(defun mys-execute-if-block ()
  "Send if-block at point to Python default interpreter."
  (interactive)
  (let ((beg (prog1
                 (or (mys--beginning-of-if-block-p)
                     (save-excursion
                       (mys-backward-if-block)))))
        (end (save-excursion
               (mys-forward-if-block))))
    (mys-execute-region beg end)))

(defun mys-execute-for-block ()
  "Send for-block at point to Python default interpreter."
  (interactive)
  (let ((beg (prog1
                 (or (mys--beginning-of-for-block-p)
                     (save-excursion
                       (mys-backward-for-block)))))
        (end (save-excursion
               (mys-forward-for-block))))
    (mys-execute-region beg end)))

;; mys-components-switches

;;  Smart indentation
(defun mys-toggle-smart-indentation (&optional arg)
  "Toggle `mys-smart-indentation' - on with positiv ARG.

Returns value of `mys-smart-indentation' switched to."
  (interactive)
  (let ((arg (or arg (if mys-smart-indentation -1 1))))
    (if (< 0 arg)
        (progn
          (setq mys-smart-indentation t)
          (mys-guess-indent-offset))
      (setq mys-smart-indentation nil)
      (setq mys-indent-offset (default-value 'mys-indent-offset)))
    (when (called-interactively-p 'any) (message "mys-smart-indentation: %s" mys-smart-indentation))
    mys-smart-indentation))

(defun mys-smart-indentation-on (&optional arg)
  "Toggle`mys-smart-indentation' - on with positive ARG.

Returns value of `mys-smart-indentation'."
  (interactive "p")
  (let ((arg (or arg 1)))
    (mys-toggle-smart-indentation arg))
  (when (called-interactively-p 'any) (message "mys-smart-indentation: %s" mys-smart-indentation))
  mys-smart-indentation)

(defun mys-smart-indentation-off (&optional arg)
  "Toggle `mys-smart-indentation' according to ARG.

Returns value of `mys-smart-indentation'."
  (interactive "p")
  (let ((arg (if arg (- arg) -1)))
    (mys-toggle-smart-indentation arg))
  (when (called-interactively-p 'any) (message "mys-smart-indentation: %s" mys-smart-indentation))
  mys-smart-indentation)

(defun mys-toggle-sexp-function ()
  "Opens customization."
  (interactive)
  (customize-variable 'mys-sexp-function))

;; Autopair mode
;; mys-autopair-mode forms
(defun mys-toggle-autopair-mode ()
  "If `mys-autopair-mode' should be on or off.

  Returns value of `mys-autopair-mode' switched to."
  (interactive)
  (and (mys-autopair-check)
       (setq mys-autopair-mode (autopair-mode (if autopair-mode 0 1)))))

(defun mys-autopair-mode-on ()
  "Make sure, mys-autopair-mode' is on.

Returns value of `mys-autopair-mode'."
  (interactive)
  (and (mys-autopair-check)
       (setq mys-autopair-mode (autopair-mode 1))))

(defun mys-autopair-mode-off ()
  "Make sure, mys-autopair-mode' is off.

Returns value of `mys-autopair-mode'."
  (interactive)
  (setq mys-autopair-mode (autopair-mode 0)))

;;  mys-switch-buffers-on-execute-p forms
(defun mys-toggle-switch-buffers-on-execute-p (&optional arg)
  "Toggle `mys-switch-buffers-on-execute-p' according to ARG.

  Returns value of `mys-switch-buffers-on-execute-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-switch-buffers-on-execute-p -1 1))))
    (if (< 0 arg)
        (setq mys-switch-buffers-on-execute-p t)
      (setq mys-switch-buffers-on-execute-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-switch-buffers-on-execute-p: %s" mys-switch-buffers-on-execute-p))
    mys-switch-buffers-on-execute-p))

(defun mys-switch-buffers-on-execute-p-on (&optional arg)
  "Toggle `mys-switch-buffers-on-execute-p' according to ARG.

Returns value of `mys-switch-buffers-on-execute-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-switch-buffers-on-execute-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-switch-buffers-on-execute-p: %s" mys-switch-buffers-on-execute-p))
  mys-switch-buffers-on-execute-p)

(defun mys-switch-buffers-on-execute-p-off ()
  "Make sure, `mys-switch-buffers-on-execute-p' is off.

Returns value of `mys-switch-buffers-on-execute-p'."
  (interactive)
  (mys-toggle-switch-buffers-on-execute-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-switch-buffers-on-execute-p: %s" mys-switch-buffers-on-execute-p))
  mys-switch-buffers-on-execute-p)

;;  mys-split-window-on-execute forms
(defun mys-toggle-split-window-on-execute (&optional arg)
  "Toggle `mys-split-window-on-execute' according to ARG.

  Returns value of `mys-split-window-on-execute' switched to."
  (interactive)
  (let ((arg (or arg (if mys-split-window-on-execute -1 1))))
    (if (< 0 arg)
        (setq mys-split-window-on-execute t)
      (setq mys-split-window-on-execute nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
    mys-split-window-on-execute))

(defun mys-split-window-on-execute-on (&optional arg)
  "Toggle `mys-split-window-on-execute' according to ARG.

Returns value of `mys-split-window-on-execute'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-split-window-on-execute arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
  mys-split-window-on-execute)

(defun mys-split-window-on-execute-off ()
  "Make sure, `mys-split-window-on-execute' is off.

Returns value of `mys-split-window-on-execute'."
  (interactive)
  (mys-toggle-split-window-on-execute -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-split-window-on-execute: %s" mys-split-window-on-execute))
  mys-split-window-on-execute)

;;  mys-fontify-shell-buffer-p forms
(defun mys-toggle-fontify-shell-buffer-p (&optional arg)
  "Toggle `mys-fontify-shell-buffer-p' according to ARG.

  Returns value of `mys-fontify-shell-buffer-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-fontify-shell-buffer-p -1 1))))
    (if (< 0 arg)
        (progn
          (setq mys-fontify-shell-buffer-p t)
          (set (make-local-variable 'font-lock-defaults)
             '(mys-font-lock-keywords nil nil nil nil
                                         (font-lock-syntactic-keywords
                                          . mys-font-lock-syntactic-keywords)))
          (unless (looking-at comint-prompt-regexp)
            (when (re-search-backward comint-prompt-regexp nil t 1)
              (font-lock-fontify-region (line-beginning-position) (point-max)))))
      (setq mys-fontify-shell-buffer-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-fontify-shell-buffer-p: %s" mys-fontify-shell-buffer-p))
    mys-fontify-shell-buffer-p))

(defun mys-fontify-shell-buffer-p-on (&optional arg)
  "Toggle `mys-fontify-shell-buffer-p' according to ARG.

Returns value of `mys-fontify-shell-buffer-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-fontify-shell-buffer-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-fontify-shell-buffer-p: %s" mys-fontify-shell-buffer-p))
  mys-fontify-shell-buffer-p)

(defun mys-fontify-shell-buffer-p-off ()
  "Make sure, `mys-fontify-shell-buffer-p' is off.

Returns value of `mys-fontify-shell-buffer-p'."
  (interactive)
  (mys-toggle-fontify-shell-buffer-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-fontify-shell-buffer-p: %s" mys-fontify-shell-buffer-p))
  mys-fontify-shell-buffer-p)

;;  mys-mode-v5-behavior-p forms
(defun mys-toggle-mys-mode-v5-behavior-p (&optional arg)
  "Toggle `mys-mode-v5-behavior-p' according to ARG.

  Returns value of `mys-mode-v5-behavior-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-mode-v5-behavior-p -1 1))))
    (if (< 0 arg)
        (setq mys-mode-v5-behavior-p t)
      (setq mys-mode-v5-behavior-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-mode-v5-behavior-p: %s" mys-mode-v5-behavior-p))
    mys-mode-v5-behavior-p))

(defun mys-mys-mode-v5-behavior-p-on (&optional arg)
  "To `mys-mode-v5-behavior-p' according to ARG.

Returns value of `mys-mode-v5-behavior-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-mys-mode-v5-behavior-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-mode-v5-behavior-p: %s" mys-mode-v5-behavior-p))
  mys-mode-v5-behavior-p)

(defun mys-mys-mode-v5-behavior-p-off ()
  "Make sure, `mys-mode-v5-behavior-p' is off.

Returns value of `mys-mode-v5-behavior-p'."
  (interactive)
  (mys-toggle-mys-mode-v5-behavior-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-mode-v5-behavior-p: %s" mys-mode-v5-behavior-p))
  mys-mode-v5-behavior-p)

;;  mys-jump-on-exception forms
(defun mys-toggle-jump-on-exception (&optional arg)
  "Toggle `mys-jump-on-exception' according to ARG.

  Returns value of `mys-jump-on-exception' switched to."
  (interactive)
  (let ((arg (or arg (if mys-jump-on-exception -1 1))))
    (if (< 0 arg)
        (setq mys-jump-on-exception t)
      (setq mys-jump-on-exception nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-jump-on-exception: %s" mys-jump-on-exception))
    mys-jump-on-exception))

(defun mys-jump-on-exception-on (&optional arg)
  "Toggle mys-jump-on-exception' according to ARG.

Returns value of `mys-jump-on-exception'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-jump-on-exception arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-jump-on-exception: %s" mys-jump-on-exception))
  mys-jump-on-exception)

(defun mys-jump-on-exception-off ()
  "Make sure, `mys-jump-on-exception' is off.

Returns value of `mys-jump-on-exception'."
  (interactive)
  (mys-toggle-jump-on-exception -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-jump-on-exception: %s" mys-jump-on-exception))
  mys-jump-on-exception)

;;  mys-use-current-dir-when-execute-p forms
(defun mys-toggle-use-current-dir-when-execute-p (&optional arg)
  "Toggle `mys-use-current-dir-when-execute-p' according to ARG.

  Returns value of `mys-use-current-dir-when-execute-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-use-current-dir-when-execute-p -1 1))))
    (if (< 0 arg)
        (setq mys-use-current-dir-when-execute-p t)
      (setq mys-use-current-dir-when-execute-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-use-current-dir-when-execute-p: %s" mys-use-current-dir-when-execute-p))
    mys-use-current-dir-when-execute-p))

(defun mys-use-current-dir-when-execute-p-on (&optional arg)
  "Toggle mys-use-current-dir-when-execute-p' according to ARG.

Returns value of `mys-use-current-dir-when-execute-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-use-current-dir-when-execute-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-use-current-dir-when-execute-p: %s" mys-use-current-dir-when-execute-p))
  mys-use-current-dir-when-execute-p)

(defun mys-use-current-dir-when-execute-p-off ()
  "Make sure, `mys-use-current-dir-when-execute-p' is off.

Returns value of `mys-use-current-dir-when-execute-p'."
  (interactive)
  (mys-toggle-use-current-dir-when-execute-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-use-current-dir-when-execute-p: %s" mys-use-current-dir-when-execute-p))
  mys-use-current-dir-when-execute-p)

;;  mys-electric-comment-p forms
(defun mys-toggle-electric-comment-p (&optional arg)
  "Toggle `mys-electric-comment-p' according to ARG.

  Returns value of `mys-electric-comment-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-electric-comment-p -1 1))))
    (if (< 0 arg)
        (setq mys-electric-comment-p t)
      (setq mys-electric-comment-p nil))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-electric-comment-p: %s" mys-electric-comment-p))
    mys-electric-comment-p))

(defun mys-electric-comment-p-on (&optional arg)
  "Toggle mys-electric-comment-p' according to ARG.

Returns value of `mys-electric-comment-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-electric-comment-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-electric-comment-p: %s" mys-electric-comment-p))
  mys-electric-comment-p)

(defun mys-electric-comment-p-off ()
  "Make sure, `mys-electric-comment-p' is off.

Returns value of `mys-electric-comment-p'."
  (interactive)
  (mys-toggle-electric-comment-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-electric-comment-p: %s" mys-electric-comment-p))
  mys-electric-comment-p)

;;  mys-underscore-word-syntax-p forms
(defun mys-toggle-underscore-word-syntax-p (&optional arg)
  "Toggle `mys-underscore-word-syntax-p' according to ARG.

  Returns value of `mys-underscore-word-syntax-p' switched to."
  (interactive)
  (let ((arg (or arg (if mys-underscore-word-syntax-p -1 1))))
    (if (< 0 arg)
        (progn
          (setq mys-underscore-word-syntax-p t)
          (modify-syntax-entry ?\_ "w" mys-mode-syntax-table))
      (setq mys-underscore-word-syntax-p nil)
      (modify-syntax-entry ?\_ "_" mys-mode-syntax-table))
    (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-underscore-word-syntax-p: %s" mys-underscore-word-syntax-p))
    mys-underscore-word-syntax-p))

(defun mys-underscore-word-syntax-p-on (&optional arg)
  "Toggle mys-underscore-word-syntax-p' according to ARG.

Returns value of `mys-underscore-word-syntax-p'."
  (interactive)
  (let ((arg (or arg 1)))
    (mys-toggle-underscore-word-syntax-p arg))
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-underscore-word-syntax-p: %s" mys-underscore-word-syntax-p))
  mys-underscore-word-syntax-p)

(defun mys-underscore-word-syntax-p-off ()
  "Make sure, `mys-underscore-word-syntax-p' is off.

Returns value of `mys-underscore-word-syntax-p'."
  (interactive)
  (mys-toggle-underscore-word-syntax-p -1)
  (when (or mys-verbose-p (called-interactively-p 'any)) (message "mys-underscore-word-syntax-p: %s" mys-underscore-word-syntax-p))
  mys-underscore-word-syntax-p)

;; mys-toggle-underscore-word-syntax-p must be known already
;; circular: mys-toggle-underscore-word-syntax-p sets and calls it
(defcustom mys-underscore-word-syntax-p t
  "If underscore chars should be of `syntax-class' word.

I.e. not of `symbol'.

Underscores in word-class like `forward-word' travel the indentifiers.
Default is t.

See bug report at launchpad, lp:940812"
  :type 'boolean
  :tag "mys-underscore-word-syntax-p"
  :group 'mys-mode
  :set (lambda (symbol value)
         (set-default symbol value)
         (mys-toggle-underscore-word-syntax-p (if value 1 0))))

;; mys-components-edit

(defun mys-insert-default-shebang ()
  "Insert in buffer shebang of installed default Python."
  (interactive "*")
  (let* ((erg (if mys-edit-only-p
                  mys-shell-name
                (executable-find mys-shell-name)))
         (sheb (concat "#! " erg)))
    (insert sheb)))

(defun mys--top-level-form-p ()
  "Return non-nil, if line start with a top level form."
  (save-excursion
    (beginning-of-line)
    (unless
	;; in string
	(nth 3 (parse-partial-sexp (point-min) (point)))
      (and (eq (current-indentation)  0)
	   (looking-at "[[:alpha:]_]+")
	   ;; (or (looking-at mys-def-or-class-re)
           ;;     (looking-at mys-block-or-clause-re)
	   ;;     (looking-at mys-assignment-re))
	   ))))

(defun mys-indent-line-outmost (&optional arg)
  "Indent the current line to the outmost reasonable indent.

With optional \\[universal-argument] ARG, unconditionally insert an indent of
`mys-indent-offset' length."
  (interactive "*P")
  (cond
   ((eq 4 (prefix-numeric-value arg))
    (if indent-tabs-mode
        (insert (make-string 1 9))
      (insert (make-string mys-indent-offset 32))))
   ;;
   (t
    (let* ((need (mys-compute-indentation (point)))
           (cui (current-indentation))
           (cuc (current-column)))
      (if (and (eq need cui)
               (not (eq cuc cui)))
          (back-to-indentation)
        (beginning-of-line)
        (delete-horizontal-space)
        (indent-to need))))))

(defun mys--re-indent-line ()
  "Re-indent the current line."
  (beginning-of-line)
  (delete-region (point)
                 (progn (skip-chars-forward " \t\r\n\f")
                        (point)))
  (indent-to (mys-compute-indentation)))

;; TODO: the following function can fall into an infinite loop.
;; See https://gitlab.com/mys-mode-devs/mys-mode/-/issues/99
(defun mys--indent-fix-region-intern (beg end)
  "Used when `mys-tab-indents-region-p' is non-nil.

Requires BEG, END as the boundery of region"
  (save-excursion
    (save-restriction
      (beginning-of-line)
      (narrow-to-region beg end)
      (goto-char beg)
      (let ((end (comys-marker end)))
	(forward-line 1)
	(narrow-to-region (line-beginning-position) end)
	(mys--re-indent-line)
	(while (< (line-end-position) end)
          (forward-line 1)
          (mys--re-indent-line))))))

(defun mys-indent-current-line (need)
  "Indent current line to NEED."
  (beginning-of-line)
  (delete-horizontal-space)
  (indent-to need))

;; TODO: Add docstring.
;; What is the intent of the this utility function?
;; What is the purpose of each argument?
(defun mys--indent-line-intern (need cui indent col &optional beg end region dedent)
  (let (erg)
    (if mys-tab-indent
	(progn
	  (and mys-tab-indents-region-p region
	       (mys--indent-fix-region-intern beg end))
	  (cond
	   ((bolp)
	    (if (and mys-tab-shifts-region-p region)
                (while (< (current-indentation) need)
                  (mys-shift-region-right 1))
	      (beginning-of-line)
	      (delete-horizontal-space)
	      (indent-to need)))
           ;;
	   ((< need cui)
	    (if (and mys-tab-shifts-region-p region)
		(progn
		  (when (eq (point) (region-end))
		    (exchange-point-and-mark))
		  (while (< 0 (current-indentation))
		    (mys-shift-region-left 1)))
	      (beginning-of-line)
	      (delete-horizontal-space)
	      (indent-to need)))
           ;;
	   ((eq need cui)
	    (if (or dedent
		    (eq this-command last-command)
		    (eq this-command 'mys-indent-line))
		(if (and mys-tab-shifts-region-p region)
		    (while (and (goto-char beg) (< 0 (current-indentation)))
		      (mys-shift-region-left 1))
		  (beginning-of-line)
		  (delete-horizontal-space)
		  (if (<= (line-beginning-position) (+ (point) (- col cui)))
		      (forward-char (- col cui))
		    (beginning-of-line)))))
           ;;
	   ((< cui need)
	    (if (and mys-tab-shifts-region-p region)
                (mys-shift-region-right 1)
              (beginning-of-line)
              (delete-horizontal-space)
              ;; indent one indent only if goal < need
              (setq erg (+ (* (/ cui indent) indent) indent))
              (if (< need erg)
                  (indent-to need)
                (indent-to erg))
              (forward-char (- col cui))))
           ;;
	   (t
	    (if (and mys-tab-shifts-region-p region)
                (while (< (current-indentation) need)
                  (mys-shift-region-right 1))
	      (beginning-of-line)
	      (delete-horizontal-space)
	      (indent-to need)
	      (back-to-indentation)
	      (if (<= (line-beginning-position) (+ (point) (- col cui)))
		  (forward-char (- col cui))
		(beginning-of-line))))))
      (insert-tab))))

(defun mys--indent-line-or-region-base (beg end region cui need arg this-indent-offset col &optional dedent)
  (cond ((eq 4 (prefix-numeric-value arg))
	 (if (and (eq cui (current-indentation))
		  (<= need cui))
	     (if indent-tabs-mode (insert "\t")(insert (make-string mys-indent-offset 32)))
	   (beginning-of-line)
	   (delete-horizontal-space)
	   (indent-to (+ need mys-indent-offset))))
	((not (eq 1 (prefix-numeric-value arg)))
	 (mys-smart-indentation-off)
	 (mys--indent-line-intern need cui this-indent-offset col beg end region dedent))
	(t (mys--indent-line-intern need cui this-indent-offset col beg end region dedent))))

(defun mys--calculate-indent-backwards (cui indent-offset)
  "Return the next reasonable indent lower than current indentation.

Requires current indent as CUI
Requires current indent-offset as INDENT-OFFSET"
  (if (< 0 (% cui mys-indent-offset))
      ;; not correctly indented at all
      (/ cui indent-offset)
    (- cui indent-offset)))

(defun mys-indent-line (&optional arg dedent)
  "Indent the current line according ARG.

When called interactivly with \\[universal-argument],
ignore dedenting rules for block closing statements
\(e.g. return, raise, break, continue, pass)

An optional \\[universal-argument] followed by a numeric argument
neither 1 nor 4 will switch off `mys-smart-indentation' for this execution.
This permits to correct allowed but unwanted indents. Similar to
`mys-toggle-smart-indentation' resp. `mys-smart-indentation-off' followed by TAB.

OUTMOST-ONLY stops circling possible indent.

When `mys-tab-shifts-region-p' is t, not just the current line,
but the region is shiftet that way.

If `mys-tab-indents-region-p' is t and first TAB doesn't shift
--as indent is at outmost reasonable--, `indent-region' is called.

Optional arg DEDENT: force dedent.

\\[quoted-insert] TAB inserts a literal TAB-character."
  (interactive "P")
  (unless (eq this-command last-command)
    (setq mys-already-guessed-indent-offset nil))
  (let ((orig (comys-marker (point)))
	;; TAB-leaves-point-in-the-wrong-lp-1178453-test
	(region (use-region-p))
        cui
	outmost
	col
	beg
	end
	need
	this-indent-offset)
    (and region
	 (setq beg (region-beginning))
	 (setq end (region-end))
	 (goto-char beg))
    (setq cui (current-indentation))
    (setq col (current-column))
    (setq this-indent-offset
	  (cond ((and mys-smart-indentation (not (eq this-command last-command)))
		 (mys-guess-indent-offset))
		((and mys-smart-indentation (eq this-command last-command) mys-already-guessed-indent-offset)
		 mys-already-guessed-indent-offset)
		(t (default-value 'mys-indent-offset))))
    (setq outmost (mys-compute-indentation nil nil nil nil nil nil nil this-indent-offset))
    ;; now choose the indent
    (unless (and (not dedent)(not (eq this-command last-command))(eq outmost (current-indentation)))
      (setq need
	    (cond ((eq this-command last-command)
		     (if (bolp)
			 ;; jump forward to max indent
			 outmost
		       (mys--calculate-indent-backwards cui this-indent-offset)))
		  ;; (mys--calculate-indent-backwards cui this-indent-offset)))))
		  (t
		   outmost
		   )))
      (mys--indent-line-or-region-base beg end region cui need arg this-indent-offset col dedent)
      (and region (or mys-tab-shifts-region-p
		      mys-tab-indents-region-p)
	   (not (eq (point) orig))
	   (exchange-point-and-mark))
      (current-indentation))))

(defun mys--delete-trailing-whitespace (orig)
  "Delete trailing whitespace.

Either `mys-newline-delete-trailing-whitespace-p'
or `
mys-trailing-whitespace-smart-delete-p' must be t.

Start from position ORIG"
  (when (or mys-newline-delete-trailing-whitespace-p mys-trailing-whitespace-smart-delete-p)
    (let ((pos (comys-marker (point))))
      (save-excursion
	(goto-char orig)
	(if (mys-empty-line-p)
	    (if (mys---emacs-version-greater-23)
		(delete-trailing-whitespace (line-beginning-position) pos)
	      (save-restriction
		(narrow-to-region (line-beginning-position) pos)
		(delete-trailing-whitespace)))
	  (skip-chars-backward " \t")
	  (if (mys---emacs-version-greater-23)
	      (delete-trailing-whitespace (line-beginning-position) pos)
	    (save-restriction
	      (narrow-to-region (point) pos)
	      (delete-trailing-whitespace))))))))

(defun mys-newline-and-indent ()
  "Add a newline and indent to outmost reasonable indent.
When indent is set back manually, this is honoured in following lines."
  (interactive "*")
  (let* ((orig (point))
	 ;; lp:1280982, deliberatly dedented by user
	 (this-dedent
	  (when
	      ;; (and (or (eq 10 (char-after))(eobp))(looking-back "^[ \t]*" (line-beginning-position)))
	      (looking-back "^[ \t]+" (line-beginning-position))
	    (current-column)))
	 erg)
    (newline 1)
    (mys--delete-trailing-whitespace orig)
    (setq erg
	  (cond (this-dedent
		 (indent-to-column this-dedent))
		((and mys-empty-line-closes-p (or (eq this-command last-command)(mys--after-empty-line)))
		 (indent-to-column (save-excursion (mys-backward-statement)(- (current-indentation) mys-indent-offset))))
		(t
		 (fixup-whitespace)
		 (indent-to-column (mys-compute-indentation)))))
    erg))

(defun mys-newline-and-dedent ()
  "Add a newline and indent to one level below current.
Returns column."
  (interactive "*")
  (let ((cui (current-indentation)))
    (newline 1)
    (when (< 0 cui)
      (indent-to (- (mys-compute-indentation) mys-indent-offset)))))

(defun mys-toggle-indent-tabs-mode ()
  "Toggle `indent-tabs-mode'.

Returns value of `indent-tabs-mode' switched to."
  (interactive)
  (when
      (setq indent-tabs-mode (not indent-tabs-mode))
    (setq tab-width mys-indent-offset))
  (when (and mys-verbose-p (called-interactively-p 'any)) (message "indent-tabs-mode %s  mys-indent-offset %s" indent-tabs-mode mys-indent-offset))
  indent-tabs-mode)

(defun mys-indent-tabs-mode (arg)
  "With positive ARG switch `indent-tabs-mode' on.

With negative ARG switch `indent-tabs-mode' off.
Returns value of `indent-tabs-mode' switched to.

If IACT is provided, message result"
  (interactive "p")
  (if (< 0 arg)
      (progn
        (setq indent-tabs-mode t)
        (setq tab-width mys-indent-offset))
    (setq indent-tabs-mode nil))
  (when (and mys-verbose-p (called-interactively-p 'any)) (message "indent-tabs-mode %s   mys-indent-offset %s" indent-tabs-mode mys-indent-offset))
  indent-tabs-mode)

(defun mys-indent-tabs-mode-on (arg)
  "Switch `indent-tabs-mode' according to ARG."
  (interactive "p")
  (mys-indent-tabs-mode (abs arg)))

(defun mys-indent-tabs-mode-off (arg)
  "Switch `indent-tabs-mode' according to ARG."
  (interactive "p")
  (mys-indent-tabs-mode (- (abs arg))))

;;  Guess indent offset

(defun mys--comment-indent-function ()
  "Python version of `comment-indent-function'."
  ;; This is required when filladapt is turned off.  Without it, when
  ;; filladapt is not used, comments which start in column zero
  ;; cascade one character to the right
  (save-excursion
    (beginning-of-line)
    (let ((eol (line-end-position)))
      (and comment-start-skip
           (re-search-forward comment-start-skip eol t)
           (setq eol (match-beginning 0)))
      (goto-char eol)
      (skip-chars-backward " \t")
      (max comment-column (+ (current-column) (if (bolp) 0 1))))))

;; ;

;;  Declarations start
(defun mys--bounds-of-declarations ()
  "Bounds of consecutive multitude of assigments resp. statements around point.

Indented same level, which don't open blocks.
Typically declarations resp. initialisations of variables following
a class or function definition.
See also `mys--bounds-of-statements'"
  (let* ((orig-indent (progn
                        (back-to-indentation)
                        (unless (mys--beginning-of-statement-p)
                          (mys-backward-statement))
                        (unless (mys--beginning-of-block-p)
                          (current-indentation))))
         (orig (point))
         last beg end)
    (when orig-indent
      (setq beg (line-beginning-position))
      ;; look upward first
      (while (and
              (progn
                (unless (mys--beginning-of-statement-p)
                  (mys-backward-statement))
                (line-beginning-position))
              (mys-backward-statement)
              (not (mys--beginning-of-block-p))
              (eq (current-indentation) orig-indent))
        (setq beg (line-beginning-position)))
      (goto-char orig)
      (while (and (setq last (line-end-position))
                  (setq end (mys-down-statement))
                  (not (mys--beginning-of-block-p))
                  (eq (mys-indentation-of-statement) orig-indent)))
      (setq end last)
      (goto-char beg)
      (if (and beg end)
          (progn
            (cons beg end))
        nil))))

(defun mys-backward-declarations ()
  "Got to the beginning of assigments resp. statements.

Move in current level which don't open blocks."
  (interactive)
  (let* ((bounds (mys--bounds-of-declarations))
         (erg (car bounds)))
    (when erg (goto-char erg))
    erg))

(defun mys-forward-declarations ()
  "Got to the end of assigments resp. statements.

Move in current level which don't open blocks."
  (interactive)
  (let* ((bounds (mys--bounds-of-declarations))
         (erg (cdr bounds)))
    (when erg (goto-char erg))
    erg))

(defun mys-declarations ()
  "Forms in current level.

Forms don't open blocks or start with a keyword.

See also `mys-statements'."
  (interactive)
  (let* ((bounds (mys--bounds-of-declarations))
         (beg (car bounds))
         (end (cdr bounds)))
    (when (and beg end)
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (kill-new (buffer-substring-no-properties beg end))
      (exchange-point-and-mark))))

(defun mys-kill-declarations ()
  "Delete variables declared in current level.

Store deleted variables in `kill-ring'"
  (interactive "*")
  (let* ((bounds (mys--bounds-of-declarations))
         (beg (car bounds))
         (end (cdr bounds)))
    (when (and beg end)
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (kill-new (buffer-substring-no-properties beg end))
      (delete-region beg end))))
;;  Declarations end

;;  Statements start
(defun mys--bounds-of-statements ()
  "Bounds of consecutive multitude of statements around point.

Indented same level, which don't open blocks."
  (interactive)
  (let* ((orig-indent (progn
                        (back-to-indentation)
                        (unless (mys--beginning-of-statement-p)
                          (mys-backward-statement))
                        (unless (mys--beginning-of-block-p)
                          (current-indentation))))
         (orig (point))
         last beg end)
    (when orig-indent
      (setq beg (point))
      (while (and (setq last beg)
                  (setq beg
                        (when (mys-backward-statement)
                          (line-beginning-position)))
		  ;; backward-statement shouldn't stop in string
                  ;; (not (mys-in-string-p))
                  (not (mys--beginning-of-block-p))
                  (eq (current-indentation) orig-indent)))
      (setq beg last)
      (goto-char orig)
      (setq end (line-end-position))
      (while (and (setq last (mys--end-of-statement-position))
                  (setq end (mys-down-statement))
                  (not (mys--beginning-of-block-p))
                  ;; (not (looking-at mys-keywords))
                  ;; (not (looking-at "pdb\."))
                  ;; (not (mys-in-string-p))
                  (eq (mys-indentation-of-statement) orig-indent)))
      (setq end last)
      (goto-char orig)
      (if (and beg end)
          (progn
            (when (called-interactively-p 'any) (message "%s %s" beg end))
            (cons beg end))
        nil))))

(defun mys-backward-statements ()
  "Got to the beginning of statements in current level which don't open blocks."
  (interactive)
  (let* ((bounds (mys--bounds-of-statements))
         (erg (car bounds)))
    (when erg (goto-char erg))
    erg))

(defun mys-forward-statements ()
  "Got to the end of statements in current level which don't open blocks."
  (interactive)
  (let* ((bounds (mys--bounds-of-statements))
         (erg (cdr bounds)))
    (when erg (goto-char erg))
    erg))

(defun mys-statements ()
  "Copy and mark simple statements level.

These statements don't open blocks.

More general than `mys-declarations'."
  (interactive)
  (let* ((bounds (mys--bounds-of-statements))
         (beg (car bounds))
         (end (cdr bounds)))
    (when (and beg end)
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (kill-new (buffer-substring-no-properties beg end))
      (exchange-point-and-mark))))

(defun mys-kill-statements ()
  "Delete statements declared in current level.

Store deleted statements in `kill-ring'"
  (interactive "*")
  (let* ((bounds (mys--bounds-of-statements))
         (beg (car bounds))
         (end (cdr bounds)))
    (when (and beg end)
      (kill-new (buffer-substring-no-properties beg end))
      (delete-region beg end))))

(defun mys-insert-super ()
  "Insert a function \"super()\" from current environment.

As example given in Python v3.1 documentation » The Python Standard Library »

class C(B):
    def method(self, arg):
        super().method(arg) # This does the same thing as:
                               # super(C, self).method(arg)

Returns the string inserted."
  (interactive "*")
  (let* ((orig (point))
         (funcname (progn
                     (mys-backward-def)
                     (when (looking-at (concat mys-def-re " *\\([^(]+\\) *(\\(?:[^),]*\\),? *\\([^)]*\\))"))
                       (match-string-no-properties 2))))
         (args (match-string-no-properties 3))
         (ver (mys-which-python))
         classname erg)
    (if (< ver 3)
        (progn
          (mys-backward-class)
          (when (looking-at (concat mys-class-re " *\\([^( ]+\\)"))
            (setq classname (match-string-no-properties 2)))
          (goto-char orig)
          (setq erg (concat "super(" classname ", self)." funcname "(" args ")"))
          ;; super(C, self).method(arg)"
          (insert erg))
      (goto-char orig)
      (setq erg (concat "super()." funcname "(" args ")"))
      (insert erg))
    erg))

;; Comments
(defun mys-delete-comments-in-def-or-class ()
  "Delete all commented lines in def-or-class at point."
  (interactive "*")
  (save-excursion
    (let ((beg (mys--beginning-of-def-or-class-position))
          (end (mys--end-of-def-or-class-position)))
      (and beg end (mys--delete-comments-intern beg end)))))

(defun mys-delete-comments-in-class ()
  "Delete all commented lines in class at point."
  (interactive "*")
  (save-excursion
    (let ((beg (mys--beginning-of-class-position))
          (end (mys--end-of-class-position)))
      (and beg end (mys--delete-comments-intern beg end)))))

(defun mys-delete-comments-in-block ()
  "Delete all commented lines in block at point."
  (interactive "*")
  (save-excursion
    (let ((beg (mys--beginning-of-block-position))
          (end (mys--end-of-block-position)))
      (and beg end (mys--delete-comments-intern beg end)))))

(defun mys-delete-comments-in-region (beg end)
  "Delete all commented lines in region delimited by BEG END."
  (interactive "r*")
  (save-excursion
    (mys--delete-comments-intern beg end)))

(defun mys--delete-comments-intern (beg end)
  (save-restriction
    (narrow-to-region beg end)
    (goto-char beg)
    (while (and (< (line-end-position) end) (not (eobp)))
      (beginning-of-line)
      (if (looking-at (concat "[ \t]*" comment-start))
          (delete-region (point) (1+ (line-end-position)))
        (forward-line 1)))))

;; Edit docstring
(defun mys--edit-set-vars ()
  (save-excursion
    (let ((mys--editbeg (when (use-region-p) (region-beginning)))
	  (mys--editend (when (use-region-p) (region-end)))
	  (pps (parse-partial-sexp (point-min) (point))))
      (when (nth 3 pps)
	(setq mys--editbeg (or mys--editbeg (progn (goto-char (nth 8 pps))
						 (skip-chars-forward (char-to-string (char-after)))(push-mark) (point))))
	(setq mys--editend (or mys--editend
			      (progn (goto-char (nth 8 pps))
				     (forward-sexp)
				     (skip-chars-backward (char-to-string (char-before)))
				     (point)))))
      (cons (comys-marker mys--editbeg) (comys-marker mys--editend)))))

(defun mys--write-edit ()
  "When edit is finished, write docstring back to orginal buffer."
  (interactive)
  (goto-char (point-min))
  (while (re-search-forward "[\"']" nil t 1)
    (or (mys-escaped-p)
	(replace-match (concat "\\\\" (match-string-no-properties 0)))))
  (jump-to-register mys--edit-register)
  ;; (mys-restore-window-configuration)
  (delete-region mys--docbeg mys--docend)
  (insert-buffer-substring mys-edit-buffer))

(defun mys-edit--intern (buffer-name mode &optional beg end prefix suffix action)
  "Edit string or active region in `mys-mode'.

arg BUFFER-NAME: a string.
arg MODE: which buffer-mode used in edit-buffer"
  (interactive "*")
  (save-excursion
    (save-restriction
      (window-configuration-to-register mys--edit-register)
      (setq mys--oldbuf (current-buffer))
      (let* ((orig (point))
	     (bounds (or (and beg end)(mys--edit-set-vars)))
	     relpos editstrg
	     erg)
	(setq mys--docbeg (or beg (car bounds)))
	(setq mys--docend (or end (cdr bounds)))
	;; store relative position in editstrg
	(setq relpos (1+ (- orig mys--docbeg)))
	(setq editstrg (buffer-substring mys--docbeg mys--docend))
	(set-buffer (get-buffer-create buffer-name))
	(erase-buffer)
	(switch-to-buffer (current-buffer))
	(when prefix (insert prefix))
	(insert editstrg)
	(when suffix (insert suffix))
	(funcall mode)
	(when action
	  (setq erg (funcall action))
	  (erase-buffer)
	  (insert erg))
	(local-set-key [(control c) (control c)] 'mys--write-edit)
	(goto-char relpos)
	(message "%s" "Type C-c C-c writes contents back")))))

(defun mys-edit-docstring ()
  "Edit docstring or active region in `mys-mode'."
  (interactive "*")
  (mys-edit--intern "Edit docstring" 'mys-mode))

(defun mys-unpretty-assignment ()
  "Revoke prettyprint, write assignment in a shortest way."
  (interactive "*")
  (save-excursion
    (let* ((beg (mys-beginning-of-assignment))
	   (end (comys-marker (mys-forward-assignment)))
	   last)
      (goto-char beg)
      (while (and (not (eobp))(re-search-forward "^\\([ \t]*\\)\[\]\"'{}]" end t 1) (setq last (comys-marker (point))))
	(save-excursion (goto-char (match-end 1))
			(when (eq (current-column) (current-indentation)) (delete-region (point) (progn (skip-chars-backward " \t\r\n\f") (point)))))
	(when last (goto-char last))))))

(defun mys--prettyprint-assignment-intern (beg end name buffer)
  (let ((proc (get-buffer-process buffer))
	erg)
    ;; (mys-send-string "import pprint" proc nil t)
    (mys-fast-send-string "import json" proc buffer)
    ;; send the dict/assigment
    (mys-fast-send-string (buffer-substring-no-properties beg end) proc buffer)
    ;; do pretty-print
    ;; print(json.dumps(neudict4, indent=4))
    (setq erg (mys-fast-send-string (concat "print(json.dumps("name", indent=5))") proc buffer t))
    (goto-char beg)
    (skip-chars-forward "^{")
    (delete-region (point) (progn (forward-sexp) (point)))
    (insert erg)))

(defun mys-prettyprint-assignment ()
  "Prettyprint assignment in `mys-mode'."
  (interactive "*")
  (window-configuration-to-register mys--windows-config-register)
  (save-excursion
    (let* ((beg (mys-beginning-of-assignment))
	   (name (mys-expression))
	   (end (mys-forward-assignment))
	   (proc-buf (mys-shell nil nil "Fast Intern Utility Re-Use")))
      (mys--prettyprint-assignment-intern beg end name proc-buf)))
  (mys-restore-window-configuration))

;; mys-components-named-shells

(defun imys (&optional argprompt args buffer fast exception-buffer split)
  "Start an Imys interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "imys" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

;; (defun imys2.7 (&optional argprompt args buffer fast exception-buffer split)
;;   "Start an Imys2.7 interpreter.

;; With optional \\[universal-argument] get a new dedicated shell."
;;   (interactive "p")
;;   (mys-shell argprompt args nil "imys2.7" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun imys3 (&optional argprompt args buffer fast exception-buffer split)
  "Start an Imys3 interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "imys3" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun jython (&optional argprompt args buffer fast exception-buffer split)
  "Start an Jython interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "jython" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun python (&optional argprompt args buffer fast exception-buffer split)
  "Start an Python interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "python" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun python2 (&optional argprompt args buffer fast exception-buffer split)
  "Start an Python2 interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "python2" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun python3 (&optional argprompt args buffer fast exception-buffer split)
  "Start an Python3 interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "python3" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun pypy (&optional argprompt args buffer fast exception-buffer split)
  "Start an Pypy interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "pypy" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

(defun isympy3 (&optional argprompt args buffer fast exception-buffer split)
  "Start an Pypy interpreter.

With optional \\[universal-argument] get a new dedicated shell."
  (interactive "p")
  (mys-shell argprompt args nil "isympy3" buffer fast exception-buffer split (unless argprompt (eq 1 (prefix-numeric-value argprompt)))))

;; mys-components-font-lock
;; (require 'python)

;; (defconst rx--builtin-symbols
;;   (append '(nonl not-newline any anychar anything unmatchable
;;             bol eol line-start line-end
;;             bos eos string-start string-end
;;             bow eow word-start word-end
;;             symbol-start symbol-end
;;             point word-boundary not-word-boundary not-wordchar)
;;           (mapcar #'car rx--char-classes))
;;   "List of built-in rx variable-like symbols.")

;; (defconst rx--builtin-forms
;;   '(seq sequence : and or | any in char not-char not intersection
;;     repeat = >= **
;;     zero-or-more 0+ *
;;     one-or-more 1+ +
;;     zero-or-one opt optional \?
;;     *? +? \??
;;     minimal-match maximal-match
;;     group submatch group-n submatch-n backref
;;     syntax not-syntax category
;;     literal eval regexp regex)
;;   "List of built-in rx function-like symbols.")

;; (defconst rx--builtin-names
;;   (append rx--builtin-forms rx--builtin-symbols)
;;   "List of built-in rx names.  These cannot be redefined by the user.")

;; (defun rx--make-binding (name tail)
;;   "Make a definitions entry out of TAIL.
;; TAIL is on the form ([ARGLIST] DEFINITION)."
;;   (unless (symbolp name)
;;     (error "Bad `rx' definition name: %S" name))
;;   ;; FIXME: Consider using a hash table or symbol property, for speed.
;;   (when (memq name rx--builtin-names)
;;     (error "Cannot redefine built-in rx name `%s'" name))
;;   (pcase tail
;;     (`(,def)
;;      (list def))
;;     (`(,args ,def)
;;      (unless (and (listp args) (rx--every #'symbolp args))
;;        (error "Bad argument list for `rx' definition %s: %S" name args))
;;      (list args def))
;;     (_ (error "Bad `rx' definition of %s: %S" name tail))))

;; (defun rx--make-named-binding (bindspec)
;;   "Make a definitions entry out of BINDSPEC.
;; BINDSPEC is on the form (NAME [ARGLIST] DEFINITION)."
;;   (unless (consp bindspec)
;;     (error "Bad `rx-let' binding: %S" bindspec))
;;   (cons (car bindspec)
;;         (rx--make-binding (car bindspec) (cdr bindspec))))

;; ;;;###autoload
;; (defmacro rx-let (bindings &rest body)
;;   "Evaluate BODY with local BINDINGS for `rx'.
;; BINDINGS is an unevaluated list of bindings each on the form
;; (NAME [(ARGS...)] RX).
;; They are bound lexically and are available in `rx' expressions in
;; BODY only.

;; For bindings without an ARGS list, NAME is defined as an alias
;; for the `rx' expression RX.  Where ARGS is supplied, NAME is
;; defined as an `rx' form with ARGS as argument list.  The
;; parameters are bound from the values in the (NAME ...) form and
;; are substituted in RX.  ARGS can contain `&rest' parameters,
;; whose values are spliced into RX where the parameter name occurs.

;; Any previous definitions with the same names are shadowed during
;; the expansion of BODY only.
;; For local extensions to `rx-to-string', use `rx-let-eval'.
;; To make global rx extensions, use `rx-define'.
;; For more details, see Info node `(elisp) Extending Rx'.

;; \(fn BINDINGS BODY...)"
;;   (declare (indent 1) (debug (sexp body)))
;;   (let ((prev-locals (cdr (assq :rx-locals macroexpand-all-environment)))
;;         (new-locals (mapcar #'rx--make-named-binding bindings)))
;;     (macroexpand-all (cons 'progn body)
;;                      (cons (cons :rx-locals (append new-locals prev-locals))
;;                            macroexpand-all-environment))))

(defmacro mys-rx (&rest regexps)
  "Python mode specialized rx macro.
This variant of `rx' supports common Python named REGEXPS."
  `(rx-let ((block-start       (seq symbol-start
                                    (or "def" "class" "if" "elif" "else" "try"
                                        "except" "finally" "for" "while" "with"
                                        ;; Python 3.10+ PEP634
                                        "match" "case"
                                        ;; Python 3.5+ PEP492
                                        (and "async" (+ space)
                                             (or "def" "for" "with")))
                                    symbol-end))
            (dedenter          (seq symbol-start
                                    (or "elif" "else" "except" "finally")
                                    symbol-end))
            (block-ender       (seq symbol-start
                                    (or
                                     "break" "continue" "pass" "raise" "return")
                                    symbol-end))
            (decorator         (seq line-start (* space) ?@ (any letter ?_)
                                    (* (any word ?_))))
            (defun             (seq symbol-start
                                    (or "def" "class"
                                        ;; Python 3.5+ PEP492
                                        (and "async" (+ space) "def"))
                                    symbol-end))
            (if-name-main      (seq line-start "if" (+ space) "__name__"
                                    (+ space) "==" (+ space)
                                    (any ?' ?\") "__main__" (any ?' ?\")
                                    (* space) ?:))
            (symbol-name       (seq (any letter ?_) (* (any word ?_))))
            (assignment-target (seq (? ?*)
                                    (* symbol-name ?.) symbol-name
                                    (? ?\[ (+ (not ?\])) ?\])))
            (grouped-assignment-target (seq (? ?*)
                                            (* symbol-name ?.) (group symbol-name)
                                            (? ?\[ (+ (not ?\])) ?\])))
            (open-paren        (or "{" "[" "("))
            (close-paren       (or "}" "]" ")"))
            (simple-operator   (any ?+ ?- ?/ ?& ?^ ?~ ?| ?* ?< ?> ?= ?%))
            (not-simple-operator (not (or simple-operator ?\n)))
            (operator          (or "==" ">=" "is" "not"
                                   "**" "//" "<<" ">>" "<=" "!="
                                   "+" "-" "/" "&" "^" "~" "|" "*" "<" ">"
                                   "=" "%"))
            (assignment-operator (or "+=" "-=" "*=" "/=" "//=" "%=" "**="
                                     ">>=" "<<=" "&=" "^=" "|="
                                     "="))
            (string-delimiter  (seq
                                ;; Match even number of backslashes.
                                (or (not (any ?\\ ?\' ?\")) point
                                    ;; Quotes might be preceded by an
                                    ;; escaped quote.
                                    (and (or (not (any ?\\)) point) ?\\
                                         (* ?\\ ?\\) (any ?\' ?\")))
                                (* ?\\ ?\\)
                                ;; Match single or triple quotes of any kind.
                                (group (or  "\"\"\"" "\"" "'''" "'"))))
            (coding-cookie (seq line-start ?# (* space)
                                (or
                                 ;; # coding=<encoding name>
                                 (: "coding" (or ?: ?=) (* space)
                                    (group-n 1 (+ (or word ?-))))
                                 ;; # -*- coding: <encoding name> -*-
                                 (: "-*-" (* space) "coding:" (* space)
                                    (group-n 1 (+ (or word ?-)))
                                    (* space) "-*-")
                                 ;; # vim: set fileencoding=<encoding name> :
                                 (: "vim:" (* space) "set" (+ space)
                                    "fileencoding" (* space) ?= (* space)
                                    (group-n 1 (+ (or word ?-)))
                                    (* space) ":")))))
     (rx ,@regexps)))

(defun mys-font-lock-assignment-matcher (regexp)
  "Font lock matcher for assignments based on REGEXP.
Search for next occurrence if REGEXP matched within a `paren'
context (to avoid, e.g., default values for arguments or passing
arguments by name being treated as assignments) or is followed by
an '=' sign (to avoid '==' being treated as an assignment.  Set
point to the position one character before the end of the
occurrence found so that subsequent searches can detect the '='
sign in chained assignment."
  (lambda (limit)
    (cl-loop while (re-search-forward regexp limit t)
             unless (or
                     ;; (mys-syntax-context 'paren)
                     (nth 1 (parse-partial-sexp (point-min) (point)))
                        (equal (char-after) ?=))
               return (progn (backward-char) t))))

(defconst mys-font-lock-keywords
  ;; Keywords
  `(,(rx symbol-start
         (or
          "if" "and" "del"  "not" "while" "as" "elif" "global"
          "or" "async with" "with" "assert" "else"  "pass" "yield" "break"
          "exec" "in" "continue" "finally" "is" "except" "raise"
          "return"  "async for" "for" "lambda" "await" "match" "case")
         symbol-end)
    (,(rx symbol-start (or "async def" "def" "class") symbol-end) . mys-def-class-face)
    (,(rx symbol-start (or "import" "from") symbol-end) . mys-import-from-face)
    (,(rx symbol-start (or "try" "if") symbol-end) . mys-try-if-face)
    ;; functions
    (,(rx symbol-start "def" (1+ space) (group (seq (any letter ?_) (* (any word ?_)))))
     ;; (1 font-lock-function-name-face))
     (1 mys-def-face))
    (,(rx symbol-start "async def" (1+ space) (group (seq (any letter ?_) (* (any word ?_)))))
     ;; (1 font-lock-function-name-face))
     (1 mys-def-face))
    ;; classes
    (,(rx symbol-start (group "class") (1+ space) (group (seq (any letter ?_) (* (any word ?_)))))
     (1 mys-def-class-face) (2 mys-class-name-face))
    (,(rx symbol-start
          (or"Ellipsis" "True" "False" "None"  "__debug__" "NotImplemented") symbol-end) . mys-pseudo-keyword-face)
    ;; Decorators.
    (,(rx line-start (* (any " \t")) (group "@" (1+ (or word ?_))
                                            (0+ "." (1+ (or word ?_)))))
     (1 mys-decorators-face))
    (,(rx symbol-start (or "cls" "self")
          symbol-end) . mys-object-reference-face)

    ;; Exceptions
    (,(rx word-start
          (or "ArithmeticError" "AssertionError" "AttributeError"
              "BaseException" "BufferError" "BytesWarning" "DeprecationWarning"
              "EOFError" "EnvironmentError" "Exception" "FloatingPointError"
              "FutureWarning" "GeneratorExit" "IOError" "ImportError"
              "ImportWarning" "IndentationError" "IndexError" "KeyError"
              "KeyboardInterrupt" "LookupError" "MemoryError" "NameError" "NoResultFound"
              "NotImplementedError" "OSError" "OverflowError"
              "PendingDeprecationWarning" "ReferenceError" "RuntimeError"
              "RuntimeWarning" "StandardError" "StopIteration" "SyntaxError"
              "SyntaxWarning" "SystemError" "SystemExit" "TabError" "TypeError"
              "UnboundLocalError" "UnicodeDecodeError" "UnicodeEncodeError"
              "UnicodeError" "UnicodeTranslateError" "UnicodeWarning"
              "UserWarning" "ValueError" "Warning" "ZeroDivisionError"
              ;; OSError subclasses
              "BlockIOError" "ChildProcessError" "ConnectionError"
              "BrokenPipError" "ConnectionAbortedError"
              "ConnectionRefusedError" "ConnectionResetError"
              "FileExistsError" "FileNotFoundError" "InterruptedError"
              "IsADirectoryError" "NotADirectoryError" "PermissionError"
              "ProcessLookupError" "TimeoutError")
          word-end) . mys-exception-name-face)
    ;; Builtins
    (,(rx
       (or space line-start (not (any ".")))
       symbol-start
       (group (or "_" "__doc__" "__import__" "__name__" "__package__" "abs" "all"
                  "any" "apply" "basestring" "bin" "bool" "buffer" "bytearray"
                  "bytes" "callable" "chr" "classmethod" "cmp" "coerce" "compile"
                  "complex" "delattr" "dict" "dir" "divmod" "enumerate" "eval"
                  "execfile" "filter" "float" "format" "frozenset"
                  "getattr" "globals" "hasattr" "hash" "help" "hex" "id" "input"
                  "int" "intern" "isinstance" "issubclass" "iter" "len" "list"
                  "locals" "long" "map" "max" "min" "next" "object" "oct" "open"
                  "ord" "pow" "property" "range" "raw_input" "reduce"
                  "reload" "repr" "reversed" "round" "set" "setattr" "slice"
                  "sorted" "staticmethod" "str" "sum" "super" "tuple" "type"
                  "unichr" "unicode" "vars" "xrange" "zip")) symbol-end) . (1 mys-builtins-face))
    ;; #104, GNU bug 44568 font lock of assignments with type hints
    ;; ("\\([._[:word:]]+\\)\\(?:\\[[^]]+]\\)?[[:space:]]*\\(?:\\(?:\\*\\*\\|//\\|<<\\|>>\\|[%&*+/|^-]\\)?=\\)"
    ;;  (1 mys-variable-name-face nil nil))
    ;; https://emacs.stackexchange.com/questions/55184/
    ;; how-to-highlight-in-different-colors-for-variables-inside-fstring-on-mys-mo
    ;;
    ;; this is the full string.
    ;; group 1 is the quote type and a closing quote is matched
    ;; group 2 is the string part
    ("f\\(['\"]\\{1,3\\}\\)\\([^\\1]+?\\)\\1"
     ;; these are the {keywords}
     ("{[^}]*?}"
      ;; Pre-match form
      (progn (goto-char (match-beginning 0)) (match-end 0))
      ;; Post-match form
      (goto-char (match-end 0))
      ;; face for this match
      ;; (0 font-lock-variable-name-face t)))
      (0 mys-variable-name-face t)))
    ;; assignment
    ;; a, b, c = (1, 2, 3)
    ;; a, *b, c = range(10)
    ;; inst.a, inst.b, inst.c = 'foo', 'bar', 'baz'
    ;; (a, b, *c, d) = x, *y = 5, 6, 7, 8, 9
    (,(mys-font-lock-assignment-matcher
       (mys-rx line-start (* space) (? (or "[" "("))
                  grouped-assignment-target (* space) ?, (* space)
                  (* assignment-target (* space) ?, (* space))
                  (? assignment-target (* space))
                  (? ?, (* space))
                  (? (or ")" "]") (* space))
                  (group assignment-operator)))
     (1 mys-variable-name-face)
     (,(mys-rx grouped-assignment-target)
      (progn
        (goto-char (match-end 1))       ; go back after the first symbol
        (match-beginning 2))            ; limit the search until the assignment
      nil
      (1 mys-variable-name-face)))
    (
     ;; "(closure (t) (limit) (let ((re \"\\(?:self\\)*\\([._[:word:]]+\\)[[:space:]]*\\(?:,[[:space:]]*[._[:word:]]+[[:space:]]*\\)*\\(?:%=\\|&=\\|\\*\\(?:\\*?=\\)\\|\\+=\\|-=\\|/\\(?:/?=\\)\\|\\(?:<<\\|>>\\|[|^]\\)=\\|[:=]\\)\") (res nil)) (while (and (setq res (re-search-forward re limit t)) (goto-char (match-end 1)) (nth 1 (parse-partial-sexp (point-min) (point))))) res))"     . (1 mys-variable-name-face nil nil)

     ,(lambda (limit)
        (let ((re (rx (* "self")(group (+ (any word ?. ?_))) (* space)
                      (* ?, (* space) (+ (any word ?. ?_)) (* space))
                      (or ":" "=" "+=" "-=" "*=" "/=" "//=" "%=" "**=" ">>=" "<<=" "&=" "^=" "|=")))
              (res nil))
          (while (and (setq res (re-search-forward re limit t))
                      (goto-char (match-end 1))
                      (nth 1 (parse-partial-sexp (point-min) (point)))
                      ;; (mys-syntax-context 'paren)
        	      ))
          res))
     . (1 mys-variable-name-face nil nil))


    ;; Numbers
    ;;        (,(rx symbol-start (or (1+ digit) (1+ hex-digit)) symbol-end) . mys-number-face)
    ("\\_<[[:digit:]]+\\_>" . mys-number-face))
     ;; ,(rx symbol-start (1+ digit) symbol-end)

  "Keywords matching font-lock")

;; mys-components-menu
(defun mys-define-menu (map)
  (easy-menu-define mys-menu map "Py"
    `("Python"
      ("Interpreter"
       ["Imys" imys
	:help " `imys'
Start an Imys interpreter."]

       ["Imys2\.7" imys2\.7
	:help " `imys2\.7'"]

       ["Imys3" imys3
	:help " `imys3'
Start an Imys3 interpreter."]

       ["Jython" jython
	:help " `jython'
Start an Jython interpreter."]

       ["Python" python
	:help " `python'
Start an Python interpreter."]

       ["Python2" python2
	:help " `python2'
Start an Python2 interpreter."]

       ["Python3" python3
	:help " `python3'
Start an Python3 interpreter."]
       ["SymPy" isympy3
	:help " `isympy3'
Start an SymPy interpreter."])

      ("Edit"
       ("Shift"
	("Shift right"
	 ["Shift block right" mys-shift-block-right
	  :help " `mys-shift-block-right'
Indent block by COUNT spaces."]

	 ["Shift block or clause right" mys-shift-block-or-clause-right
	  :help " `mys-shift-block-or-clause-right'
Indent block-or-clause by COUNT spaces."]

	 ["Shift class right" mys-shift-class-right
	  :help " `mys-shift-class-right'
Indent class by COUNT spaces."]

	 ["Shift clause right" mys-shift-clause-right
	  :help " `mys-shift-clause-right'
Indent clause by COUNT spaces."]

	 ["Shift comment right" mys-shift-comment-right
	  :help " `mys-shift-comment-right'
Indent comment by COUNT spaces."]

	 ["Shift def right" mys-shift-def-right
	  :help " `mys-shift-def-right'
Indent def by COUNT spaces."]

	 ["Shift def or class right" mys-shift-def-or-class-right
	  :help " `mys-shift-def-or-class-right'
Indent def-or-class by COUNT spaces."]

	 ["Shift indent right" mys-shift-indent-right
	  :help " `mys-shift-indent-right'
Indent indent by COUNT spaces."]

	 ["Shift minor block right" mys-shift-minor-block-right
	  :help " `mys-shift-minor-block-right'
Indent minor-block by COUNT spaces."]

	 ["Shift paragraph right" mys-shift-paragraph-right
	  :help " `mys-shift-paragraph-right'
Indent paragraph by COUNT spaces."]

	 ["Shift region right" mys-shift-region-right
	  :help " `mys-shift-region-right'
Indent region by COUNT spaces."]

	 ["Shift statement right" mys-shift-statement-right
	  :help " `mys-shift-statement-right'
Indent statement by COUNT spaces."]

	 ["Shift top level right" mys-shift-top-level-right
	  :help " `mys-shift-top-level-right'
Indent top-level by COUNT spaces."])
	("Shift left"
	 ["Shift block left" mys-shift-block-left
	  :help " `mys-shift-block-left'
Dedent block by COUNT spaces."]

	 ["Shift block or clause left" mys-shift-block-or-clause-left
	  :help " `mys-shift-block-or-clause-left'
Dedent block-or-clause by COUNT spaces."]

	 ["Shift class left" mys-shift-class-left
	  :help " `mys-shift-class-left'
Dedent class by COUNT spaces."]

	 ["Shift clause left" mys-shift-clause-left
	  :help " `mys-shift-clause-left'
Dedent clause by COUNT spaces."]

	 ["Shift comment left" mys-shift-comment-left
	  :help " `mys-shift-comment-left'
Dedent comment by COUNT spaces."]

	 ["Shift def left" mys-shift-def-left
	  :help " `mys-shift-def-left'
Dedent def by COUNT spaces."]

	 ["Shift def or class left" mys-shift-def-or-class-left
	  :help " `mys-shift-def-or-class-left'
Dedent def-or-class by COUNT spaces."]

	 ["Shift indent left" mys-shift-indent-left
	  :help " `mys-shift-indent-left'
Dedent indent by COUNT spaces."]

	 ["Shift minor block left" mys-shift-minor-block-left
	  :help " `mys-shift-minor-block-left'
Dedent minor-block by COUNT spaces."]

	 ["Shift paragraph left" mys-shift-paragraph-left
	  :help " `mys-shift-paragraph-left'
Dedent paragraph by COUNT spaces."]

	 ["Shift region left" mys-shift-region-left
	  :help " `mys-shift-region-left'
Dedent region by COUNT spaces."]

	 ["Shift statement left" mys-shift-statement-left
	  :help " `mys-shift-statement-left'
Dedent statement by COUNT spaces."]))
       ("Mark"
	["Mark block" mys-mark-block
	 :help " `mys-mark-block'
Mark block, take beginning of line positions."]

	["Mark block or clause" mys-mark-block-or-clause
	 :help " `mys-mark-block-or-clause'
Mark block-or-clause, take beginning of line positions."]

	["Mark class" mys-mark-class
	 :help " `mys-mark-class'
Mark class, take beginning of line positions."]

	["Mark clause" mys-mark-clause
	 :help " `mys-mark-clause'
Mark clause, take beginning of line positions."]

	["Mark comment" mys-mark-comment
	 :help " `mys-mark-comment'
Mark comment at point."]

	["Mark def" mys-mark-def
	 :help " `mys-mark-def'
Mark def, take beginning of line positions."]

	["Mark def or class" mys-mark-def-or-class
	 :help " `mys-mark-def-or-class'
Mark def-or-class, take beginning of line positions."]

	["Mark expression" mys-mark-expression
	 :help " `mys-mark-expression'
Mark expression at point."]

	["Mark except block" mys-mark-except-block
	 :help " `mys-mark-except-block'
Mark except-block, take beginning of line positions."]

	["Mark if block" mys-mark-if-block
	 :help " `mys-mark-if-block'
Mark if-block, take beginning of line positions."]

	["Mark indent" mys-mark-indent
	 :help " `mys-mark-indent'
Mark indent, take beginning of line positions."]

	["Mark line" mys-mark-line
	 :help " `mys-mark-line'
Mark line at point."]

	["Mark minor block" mys-mark-minor-block
	 :help " `mys-mark-minor-block'
Mark minor-block, take beginning of line positions."]

	["Mark partial expression" mys-mark-partial-expression
	 :help " `mys-mark-partial-expression'
Mark partial-expression at point."]

	["Mark paragraph" mys-mark-paragraph
	 :help " `mys-mark-paragraph'
Mark paragraph at point."]

	["Mark section" mys-mark-section
	 :help " `mys-mark-section'
Mark section at point."]

	["Mark statement" mys-mark-statement
	 :help " `mys-mark-statement'
Mark statement, take beginning of line positions."]

	["Mark top level" mys-mark-top-level
	 :help " `mys-mark-top-level'
Mark top-level, take beginning of line positions."]

	["Mark try block" mys-mark-try-block
	 :help " `mys-mark-try-block'
Mark try-block, take beginning of line positions."])
       ("Copy"
	["Copy block" mys-comys-block
	 :help " `mys-comys-block'
Copy block at point."]

	["Copy block or clause" mys-comys-block-or-clause
	 :help " `mys-comys-block-or-clause'
Copy block-or-clause at point."]

	["Copy class" mys-comys-class
	 :help " `mys-comys-class'
Copy class at point."]

	["Copy clause" mys-comys-clause
	 :help " `mys-comys-clause'
Copy clause at point."]

	["Copy comment" mys-comys-comment
	 :help " `mys-comys-comment'"]

	["Copy def" mys-comys-def
	 :help " `mys-comys-def'
Copy def at point."]

	["Copy def or class" mys-comys-def-or-class
	 :help " `mys-comys-def-or-class'
Copy def-or-class at point."]

	["Copy expression" mys-comys-expression
	 :help " `mys-comys-expression'
Copy expression at point."]

	["Copy except block" mys-comys-except-block
	 :help " `mys-comys-except-block'"]

	["Copy if block" mys-comys-if-block
	 :help " `mys-comys-if-block'"]

	["Copy indent" mys-comys-indent
	 :help " `mys-comys-indent'
Copy indent at point."]

	["Copy line" mys-comys-line
	 :help " `mys-comys-line'
Copy line at point."]

	["Copy minor block" mys-comys-minor-block
	 :help " `mys-comys-minor-block'
Copy minor-block at point."]

	["Copy partial expression" mys-comys-partial-expression
	 :help " `mys-comys-partial-expression'
Copy partial-expression at point."]

	["Copy paragraph" mys-comys-paragraph
	 :help " `mys-comys-paragraph'
Copy paragraph at point."]

	["Copy section" mys-comys-section
	 :help " `mys-comys-section'"]

	["Copy statement" mys-comys-statement
	 :help " `mys-comys-statement'
Copy statement at point."]

	["Copy top level" mys-comys-top-level
	 :help " `mys-comys-top-level'
Copy top-level at point."])
       ("Kill"
	["Kill block" mys-kill-block
	 :help " `mys-kill-block'
Delete block at point."]

	["Kill block or clause" mys-kill-block-or-clause
	 :help " `mys-kill-block-or-clause'
Delete block-or-clause at point."]

	["Kill class" mys-kill-class
	 :help " `mys-kill-class'
Delete class at point."]

	["Kill clause" mys-kill-clause
	 :help " `mys-kill-clause'
Delete clause at point."]

	["Kill comment" mys-kill-comment
	 :help " `mys-kill-comment'
Delete comment at point."]

	["Kill def" mys-kill-def
	 :help " `mys-kill-def'
Delete def at point."]

	["Kill def or class" mys-kill-def-or-class
	 :help " `mys-kill-def-or-class'
Delete def-or-class at point."]

	["Kill expression" mys-kill-expression
	 :help " `mys-kill-expression'
Delete expression at point."]

	["Kill except block" mys-kill-except-block
	 :help " `mys-kill-except-block'
Delete except-block at point."]

	["Kill if block" mys-kill-if-block
	 :help " `mys-kill-if-block'
Delete if-block at point."]

	["Kill indent" mys-kill-indent
	 :help " `mys-kill-indent'
Delete indent at point."]

	["Kill line" mys-kill-line
	 :help " `mys-kill-line'
Delete line at point."]

	["Kill minor block" mys-kill-minor-block
	 :help " `mys-kill-minor-block'
Delete minor-block at point."]

	["Kill partial expression" mys-kill-partial-expression
	 :help " `mys-kill-partial-expression'
Delete partial-expression at point."]

	["Kill paragraph" mys-kill-paragraph
	 :help " `mys-kill-paragraph'
Delete paragraph at point."]

	["Kill section" mys-kill-section
	 :help " `mys-kill-section'
Delete section at point."]

	["Kill statement" mys-kill-statement
	 :help " `mys-kill-statement'
Delete statement at point."]

	["Kill top level" mys-kill-top-level
	 :help " `mys-kill-top-level'
Delete top-level at point."]

	["Kill try block" mys-kill-try-block
	 :help " `mys-kill-try-block'
Delete try-block at point."])
       ("Delete"
	["Delete block" mys-delete-block
	 :help " `mys-delete-block'
Delete BLOCK at point until beginning-of-line."]

	["Delete block or clause" mys-delete-block-or-clause
	 :help " `mys-delete-block-or-clause'
Delete BLOCK-OR-CLAUSE at point until beginning-of-line."]

	["Delete class" mys-delete-class
	 :help " `mys-delete-class'
Delete CLASS at point until beginning-of-line."]

	["Delete clause" mys-delete-clause
	 :help " `mys-delete-clause'
Delete CLAUSE at point until beginning-of-line."]

	["Delete comment" mys-delete-comment
	 :help " `mys-delete-comment'
Delete COMMENT at point."]

	["Delete def" mys-delete-def
	 :help " `mys-delete-def'
Delete DEF at point until beginning-of-line."]

	["Delete def or class" mys-delete-def-or-class
	 :help " `mys-delete-def-or-class'
Delete DEF-OR-CLASS at point until beginning-of-line."]

	["Delete expression" mys-delete-expression
	 :help " `mys-delete-expression'
Delete EXPRESSION at point."]

	["Delete except block" mys-delete-except-block
	 :help " `mys-delete-except-block'
Delete EXCEPT-BLOCK at point until beginning-of-line."]

	["Delete if block" mys-delete-if-block
	 :help " `mys-delete-if-block'
Delete IF-BLOCK at point until beginning-of-line."]

	["Delete indent" mys-delete-indent
	 :help " `mys-delete-indent'
Delete INDENT at point until beginning-of-line."]

	["Delete line" mys-delete-line
	 :help " `mys-delete-line'
Delete LINE at point."]

	["Delete minor block" mys-delete-minor-block
	 :help " `mys-delete-minor-block'
Delete MINOR-BLOCK at point until beginning-of-line."]

	["Delete partial expression" mys-delete-partial-expression
	 :help " `mys-delete-partial-expression'
Delete PARTIAL-EXPRESSION at point."]

	["Delete paragraph" mys-delete-paragraph
	 :help " `mys-delete-paragraph'
Delete PARAGRAPH at point."]

	["Delete section" mys-delete-section
	 :help " `mys-delete-section'
Delete SECTION at point."]

	["Delete statement" mys-delete-statement
	 :help " `mys-delete-statement'
Delete STATEMENT at point until beginning-of-line."]

	["Delete top level" mys-delete-top-level
	 :help " `mys-delete-top-level'
Delete TOP-LEVEL at point."]

	["Delete try block" mys-delete-try-block
	 :help " `mys-delete-try-block'
Delete TRY-BLOCK at point until beginning-of-line."])
       ("Comment"
	["Comment block" mys-comment-block
	 :help " `mys-comment-block'
Comments block at point."]

	["Comment block or clause" mys-comment-block-or-clause
	 :help " `mys-comment-block-or-clause'
Comments block-or-clause at point."]

	["Comment class" mys-comment-class
	 :help " `mys-comment-class'
Comments class at point."]

	["Comment clause" mys-comment-clause
	 :help " `mys-comment-clause'
Comments clause at point."]

	["Comment def" mys-comment-def
	 :help " `mys-comment-def'
Comments def at point."]

	["Comment def or class" mys-comment-def-or-class
	 :help " `mys-comment-def-or-class'
Comments def-or-class at point."]

	["Comment indent" mys-comment-indent
	 :help " `mys-comment-indent'
Comments indent at point."]

	["Comment minor block" mys-comment-minor-block
	 :help " `mys-comment-minor-block'
Comments minor-block at point."]

	["Comment section" mys-comment-section
	 :help " `mys-comment-section'
Comments section at point."]

	["Comment statement" mys-comment-statement
	 :help " `mys-comment-statement'
Comments statement at point."]

	["Comment top level" mys-comment-top-level
	 :help " `mys-comment-top-level'
Comments top-level at point."]))
      ("Move"
       ("Backward"

	["Backward def or class" mys-backward-def-or-class
	 :help " `mys-backward-def-or-class'
Go to beginning of def-or-class."]

	["Backward class" mys-backward-class
	 :help " `mys-backward-class'
Go to beginning of class."]

	["Backward def" mys-backward-def
	 :help " `mys-backward-def'
Go to beginning of def."]

	["Backward block" mys-backward-block
	 :help " `mys-backward-block'
Go to beginning of `block'."]

	["Backward statement" mys-backward-statement
	 :help " `mys-backward-statement'
Go to the initial line of a simple statement."]

	["Backward indent" mys-backward-indent
	 :help " `mys-backward-indent'
Go to the beginning of a section of equal indent."]

	["Backward top level" mys-backward-top-level
	 :help " `mys-backward-top-level'
Go up to beginning of statments until level of indentation is null."]

	("Other"
	 ["Backward section" mys-backward-section
	  :help " `mys-backward-section'
Go to next section start upward in buffer."]

	 ["Backward expression" mys-backward-expression
	  :help " `mys-backward-expression'"]

	 ["Backward partial expression" mys-backward-partial-expression
	  :help " `mys-backward-partial-expression'"]

	 ["Backward assignment" mys-backward-assignment
	  :help " `mys-backward-assignment'"]

	 ["Backward block or clause" mys-backward-block-or-clause
	  :help " `mys-backward-block-or-clause'
Go to beginning of `block-or-clause'."]

	 ["Backward clause" mys-backward-clause
	  :help " `mys-backward-clause'
Go to beginning of `clause'."]

	 ["Backward elif block" mys-backward-elif-block
	  :help " `mys-backward-elif-block'
Go to beginning of `elif-block'."]

	 ["Backward else block" mys-backward-else-block
	  :help " `mys-backward-else-block'
Go to beginning of `else-block'."]

	 ["Backward except block" mys-backward-except-block
	  :help " `mys-backward-except-block'
Go to beginning of `except-block'."]

	 ["Backward if block" mys-backward-if-block
	  :help " `mys-backward-if-block'
Go to beginning of `if-block'."]

	 ["Backward minor block" mys-backward-minor-block
	  :help " `mys-backward-minor-block'
Go to beginning of `minor-block'."]

	 ["Backward try block" mys-backward-try-block
	  :help " `mys-backward-try-block'
Go to beginning of `try-block'."]))
       ("Forward"
	["Forward def or class" mys-forward-def-or-class
	 :help " `mys-forward-def-or-class'
Go to end of def-or-class."]

	["Forward class" mys-forward-class
	 :help " `mys-forward-class'
Go to end of class."]

	["Forward def" mys-forward-def
	 :help " `mys-forward-def'
Go to end of def."]

	["Forward block" mys-forward-block
	 :help " `mys-forward-block'
Go to end of block."]

	["Forward statement" mys-forward-statement
	 :help " `mys-forward-statement'
Go to the last char of current statement."]

	["Forward indent" mys-forward-indent
	 :help " `mys-forward-indent'
Go to the end of a section of equal indentation."]

	["Forward top level" mys-forward-top-level
	 :help " `mys-forward-top-level'
Go to end of top-level form at point."]

	("Other"
	 ["Forward section" mys-forward-section
	  :help " `mys-forward-section'
Go to next section end downward in buffer."]

	 ["Forward expression" mys-forward-expression
	  :help " `mys-forward-expression'"]

	 ["Forward partial expression" mys-forward-partial-expression
	  :help " `mys-forward-partial-expression'"]

	 ["Forward assignment" mys-forward-assignment
	  :help " `mys-forward-assignment'"]

	 ["Forward block or clause" mys-forward-block-or-clause
	  :help " `mys-forward-block-or-clause'
Go to end of block-or-clause."]

	 ["Forward clause" mys-forward-clause
	  :help " `mys-forward-clause'
Go to end of clause."]

	 ["Forward for block" mys-forward-for-block
	 :help " `mys-forward-for-block'
Go to end of for-block."]

	 ["Forward elif block" mys-forward-elif-block
	  :help " `mys-forward-elif-block'
Go to end of elif-block."]

	 ["Forward else block" mys-forward-else-block
	  :help " `mys-forward-else-block'
Go to end of else-block."]

	 ["Forward except block" mys-forward-except-block
	  :help " `mys-forward-except-block'
Go to end of except-block."]

	 ["Forward if block" mys-forward-if-block
	  :help " `mys-forward-if-block'
Go to end of if-block."]

	 ["Forward minor block" mys-forward-minor-block
	  :help " `mys-forward-minor-block'
Go to end of minor-block."]
	 ["Forward try block" mys-forward-try-block
	  :help " `mys-forward-try-block'
Go to end of try-block."]))
       ("BOL-forms"
	("Backward"
	 ["Backward block bol" mys-backward-block-bol
	  :help " `mys-backward-block-bol'
Go to beginning of `block', go to BOL."]

	 ["Backward block or clause bol" mys-backward-block-or-clause-bol
	  :help " `mys-backward-block-or-clause-bol'
Go to beginning of `block-or-clause', go to BOL."]

	 ["Backward class bol" mys-backward-class-bol
	  :help " `mys-backward-class-bol'
Go to beginning of class, go to BOL."]

	 ["Backward clause bol" mys-backward-clause-bol
	  :help " `mys-backward-clause-bol'
Go to beginning of `clause', go to BOL."]

	 ["Backward def bol" mys-backward-def-bol
	  :help " `mys-backward-def-bol'
Go to beginning of def, go to BOL."]

	 ["Backward def or class bol" mys-backward-def-or-class-bol
	  :help " `mys-backward-def-or-class-bol'
Go to beginning of def-or-class, go to BOL."]

	 ["Backward elif block bol" mys-backward-elif-block-bol
	  :help " `mys-backward-elif-block-bol'
Go to beginning of `elif-block', go to BOL."]

	 ["Backward else block bol" mys-backward-else-block-bol
	  :help " `mys-backward-else-block-bol'
Go to beginning of `else-block', go to BOL."]

	 ["Backward except block bol" mys-backward-except-block-bol
	  :help " `mys-backward-except-block-bol'
Go to beginning of `except-block', go to BOL."]

	 ["Backward expression bol" mys-backward-expression-bol
	  :help " `mys-backward-expression-bol'"]

	 ["Backward for block bol" mys-backward-for-block-bol
	  :help " `mys-backward-for-block-bol'
Go to beginning of `for-block', go to BOL."]

	 ["Backward if block bol" mys-backward-if-block-bol
	  :help " `mys-backward-if-block-bol'
Go to beginning of `if-block', go to BOL."]

	 ["Backward indent bol" mys-backward-indent-bol
	  :help " `mys-backward-indent-bol'
Go to the beginning of line of a section of equal indent."]

	 ["Backward minor block bol" mys-backward-minor-block-bol
	  :help " `mys-backward-minor-block-bol'
Go to beginning of `minor-block', go to BOL."]

	 ["Backward partial expression bol" mys-backward-partial-expression-bol
	  :help " `mys-backward-partial-expression-bol'"]

	 ["Backward section bol" mys-backward-section-bol
	  :help " `mys-backward-section-bol'"]

	 ["Backward statement bol" mys-backward-statement-bol
	  :help " `mys-backward-statement-bol'
Goto beginning of line where statement starts."]

	 ["Backward try block bol" mys-backward-try-block-bol
	  :help " `mys-backward-try-block-bol'
Go to beginning of `try-block', go to BOL."])
	("Forward"
	 ["Forward block bol" mys-forward-block-bol
	  :help " `mys-forward-block-bol'
Goto beginning of line following end of block."]

	 ["Forward block or clause bol" mys-forward-block-or-clause-bol
	  :help " `mys-forward-block-or-clause-bol'
Goto beginning of line following end of block-or-clause."]

	 ["Forward class bol" mys-forward-class-bol
	  :help " `mys-forward-class-bol'
Goto beginning of line following end of class."]

	 ["Forward clause bol" mys-forward-clause-bol
	  :help " `mys-forward-clause-bol'
Goto beginning of line following end of clause."]

	 ["Forward def bol" mys-forward-def-bol
	  :help " `mys-forward-def-bol'
Goto beginning of line following end of def."]

	 ["Forward def or class bol" mys-forward-def-or-class-bol
	  :help " `mys-forward-def-or-class-bol'
Goto beginning of line following end of def-or-class."]

	 ["Forward elif block bol" mys-forward-elif-block-bol
	  :help " `mys-forward-elif-block-bol'
Goto beginning of line following end of elif-block."]

	 ["Forward else block bol" mys-forward-else-block-bol
	  :help " `mys-forward-else-block-bol'
Goto beginning of line following end of else-block."]

	 ["Forward except block bol" mys-forward-except-block-bol
	  :help " `mys-forward-except-block-bol'
Goto beginning of line following end of except-block."]

	 ["Forward expression bol" mys-forward-expression-bol
	  :help " `mys-forward-expression-bol'"]

	 ["Forward for block bol" mys-forward-for-block-bol
	  :help " `mys-forward-for-block-bol'
Goto beginning of line following end of for-block."]

	 ["Forward if block bol" mys-forward-if-block-bol
	  :help " `mys-forward-if-block-bol'
Goto beginning of line following end of if-block."]

	 ["Forward indent bol" mys-forward-indent-bol
	  :help " `mys-forward-indent-bol'
Go to beginning of line following of a section of equal indentation."]

	 ["Forward minor block bol" mys-forward-minor-block-bol
	  :help " `mys-forward-minor-block-bol'
Goto beginning of line following end of minor-block."]

	 ["Forward partial expression bol" mys-forward-partial-expression-bol
	  :help " `mys-forward-partial-expression-bol'"]

	 ["Forward section bol" mys-forward-section-bol
	  :help " `mys-forward-section-bol'"]

	 ["Forward statement bol" mys-forward-statement-bol
	  :help " `mys-forward-statement-bol'
Go to the beginning-of-line following current statement."]

	 ["Forward top level bol" mys-forward-top-level-bol
	  :help " `mys-forward-top-level-bol'
Go to end of top-level form at point, stop at next beginning-of-line."]

	 ["Forward try block bol" mys-forward-try-block-bol
	  :help " `mys-forward-try-block-bol'
Goto beginning of line following end of try-block."]))
       ("Up/Down"
	["Up" mys-up
	 :help " `mys-up'
Go up or to beginning of form if inside."]

	["Down" mys-down
	 :help " `mys-down'
Go to beginning one level below of compound statement or definition at point."]))
      ("Send"
       ["Execute block" mys-execute-block
	:help " `mys-execute-block'
Send block at point to interpreter."]

       ["Execute block or clause" mys-execute-block-or-clause
	:help " `mys-execute-block-or-clause'
Send block-or-clause at point to interpreter."]

       ["Execute buffer" mys-execute-buffer
	:help " `mys-execute-buffer'
:around advice: `ad-Advice-mys-execute-buffer'"]

       ["Execute class" mys-execute-class
	:help " `mys-execute-class'
Send class at point to interpreter."]

       ["Execute clause" mys-execute-clause
	:help " `mys-execute-clause'
Send clause at point to interpreter."]

       ["Execute def" mys-execute-def
	:help " `mys-execute-def'
Send def at point to interpreter."]

       ["Execute def or class" mys-execute-def-or-class
	:help " `mys-execute-def-or-class'
Send def-or-class at point to interpreter."]

       ["Execute expression" mys-execute-expression
	:help " `mys-execute-expression'
Send expression at point to interpreter."]

       ["Execute indent" mys-execute-indent
	:help " `mys-execute-indent'
Send indent at point to interpreter."]

       ["Execute line" mys-execute-line
	:help " `mys-execute-line'
Send line at point to interpreter."]

       ["Execute minor block" mys-execute-minor-block
	:help " `mys-execute-minor-block'
Send minor-block at point to interpreter."]

       ["Execute paragraph" mys-execute-paragraph
	:help " `mys-execute-paragraph'
Send paragraph at point to interpreter."]

       ["Execute partial expression" mys-execute-partial-expression
	:help " `mys-execute-partial-expression'
Send partial-expression at point to interpreter."]

       ["Execute region" mys-execute-region
	:help " `mys-execute-region'
Send region at point to interpreter."]

       ["Execute statement" mys-execute-statement
	:help " `mys-execute-statement'
Send statement at point to interpreter."]

       ["Execute top level" mys-execute-top-level
	:help " `mys-execute-top-level'
Send top-level at point to interpreter."]
       ("Other"
	("Imys"
	 ["Execute block imys" mys-execute-block-imys
	  :help " `mys-execute-block-imys'
Send block at point to Imys interpreter."]

	 ["Execute block or clause imys" mys-execute-block-or-clause-imys
	  :help " `mys-execute-block-or-clause-imys'
Send block-or-clause at point to Imys interpreter."]

	 ["Execute buffer imys" mys-execute-buffer-imys
	  :help " `mys-execute-buffer-imys'
Send buffer at point to Imys interpreter."]

	 ["Execute class imys" mys-execute-class-imys
	  :help " `mys-execute-class-imys'
Send class at point to Imys interpreter."]

	 ["Execute clause imys" mys-execute-clause-imys
	  :help " `mys-execute-clause-imys'
Send clause at point to Imys interpreter."]

	 ["Execute def imys" mys-execute-def-imys
	  :help " `mys-execute-def-imys'
Send def at point to Imys interpreter."]

	 ["Execute def or class imys" mys-execute-def-or-class-imys
	  :help " `mys-execute-def-or-class-imys'
Send def-or-class at point to Imys interpreter."]

	 ["Execute expression imys" mys-execute-expression-imys
	  :help " `mys-execute-expression-imys'
Send expression at point to Imys interpreter."]

	 ["Execute indent imys" mys-execute-indent-imys
	  :help " `mys-execute-indent-imys'
Send indent at point to Imys interpreter."]

	 ["Execute line imys" mys-execute-line-imys
	  :help " `mys-execute-line-imys'
Send line at point to Imys interpreter."]

	 ["Execute minor block imys" mys-execute-minor-block-imys
	  :help " `mys-execute-minor-block-imys'
Send minor-block at point to Imys interpreter."]

	 ["Execute paragraph imys" mys-execute-paragraph-imys
	  :help " `mys-execute-paragraph-imys'
Send paragraph at point to Imys interpreter."]

	 ["Execute partial expression imys" mys-execute-partial-expression-imys
	  :help " `mys-execute-partial-expression-imys'
Send partial-expression at point to Imys interpreter."]

	 ["Execute region imys" mys-execute-region-imys
	  :help " `mys-execute-region-imys'
Send region at point to Imys interpreter."]

	 ["Execute statement imys" mys-execute-statement-imys
	  :help " `mys-execute-statement-imys'
Send statement at point to Imys interpreter."]

	 ["Execute top level imys" mys-execute-top-level-imys
	  :help " `mys-execute-top-level-imys'
Send top-level at point to Imys interpreter."])
	("Imys2"
	 ["Execute block imys2" mys-execute-block-imys2
	  :help " `mys-execute-block-imys2'"]

	 ["Execute block or clause imys2" mys-execute-block-or-clause-imys2
	  :help " `mys-execute-block-or-clause-imys2'"]

	 ["Execute buffer imys2" mys-execute-buffer-imys2
	  :help " `mys-execute-buffer-imys2'"]

	 ["Execute class imys2" mys-execute-class-imys2
	  :help " `mys-execute-class-imys2'"]

	 ["Execute clause imys2" mys-execute-clause-imys2
	  :help " `mys-execute-clause-imys2'"]

	 ["Execute def imys2" mys-execute-def-imys2
	  :help " `mys-execute-def-imys2'"]

	 ["Execute def or class imys2" mys-execute-def-or-class-imys2
	  :help " `mys-execute-def-or-class-imys2'"]

	 ["Execute expression imys2" mys-execute-expression-imys2
	  :help " `mys-execute-expression-imys2'"]

	 ["Execute indent imys2" mys-execute-indent-imys2
	  :help " `mys-execute-indent-imys2'"]

	 ["Execute line imys2" mys-execute-line-imys2
	  :help " `mys-execute-line-imys2'"]

	 ["Execute minor block imys2" mys-execute-minor-block-imys2
	  :help " `mys-execute-minor-block-imys2'"]

	 ["Execute paragraph imys2" mys-execute-paragraph-imys2
	  :help " `mys-execute-paragraph-imys2'"]

	 ["Execute partial expression imys2" mys-execute-partial-expression-imys2
	  :help " `mys-execute-partial-expression-imys2'"]

	 ["Execute region imys2" mys-execute-region-imys2
	  :help " `mys-execute-region-imys2'"]

	 ["Execute statement imys2" mys-execute-statement-imys2
	  :help " `mys-execute-statement-imys2'"]

	 ["Execute top level imys2" mys-execute-top-level-imys2
	  :help " `mys-execute-top-level-imys2'"])
	("Imys3"
	 ["Execute block imys3" mys-execute-block-imys3
	  :help " `mys-execute-block-imys3'
Send block at point to Imys interpreter."]

	 ["Execute block or clause imys3" mys-execute-block-or-clause-imys3
	  :help " `mys-execute-block-or-clause-imys3'
Send block-or-clause at point to Imys interpreter."]

	 ["Execute buffer imys3" mys-execute-buffer-imys3
	  :help " `mys-execute-buffer-imys3'
Send buffer at point to Imys interpreter."]

	 ["Execute class imys3" mys-execute-class-imys3
	  :help " `mys-execute-class-imys3'
Send class at point to Imys interpreter."]

	 ["Execute clause imys3" mys-execute-clause-imys3
	  :help " `mys-execute-clause-imys3'
Send clause at point to Imys interpreter."]

	 ["Execute def imys3" mys-execute-def-imys3
	  :help " `mys-execute-def-imys3'
Send def at point to Imys interpreter."]

	 ["Execute def or class imys3" mys-execute-def-or-class-imys3
	  :help " `mys-execute-def-or-class-imys3'
Send def-or-class at point to Imys interpreter."]

	 ["Execute expression imys3" mys-execute-expression-imys3
	  :help " `mys-execute-expression-imys3'
Send expression at point to Imys interpreter."]

	 ["Execute indent imys3" mys-execute-indent-imys3
	  :help " `mys-execute-indent-imys3'
Send indent at point to Imys interpreter."]

	 ["Execute line imys3" mys-execute-line-imys3
	  :help " `mys-execute-line-imys3'
Send line at point to Imys interpreter."]

	 ["Execute minor block imys3" mys-execute-minor-block-imys3
	  :help " `mys-execute-minor-block-imys3'
Send minor-block at point to Imys interpreter."]

	 ["Execute paragraph imys3" mys-execute-paragraph-imys3
	  :help " `mys-execute-paragraph-imys3'
Send paragraph at point to Imys interpreter."]

	 ["Execute partial expression imys3" mys-execute-partial-expression-imys3
	  :help " `mys-execute-partial-expression-imys3'
Send partial-expression at point to Imys interpreter."]

	 ["Execute region imys3" mys-execute-region-imys3
	  :help " `mys-execute-region-imys3'
Send region at point to Imys interpreter."]

	 ["Execute statement imys3" mys-execute-statement-imys3
	  :help " `mys-execute-statement-imys3'
Send statement at point to Imys interpreter."]

	 ["Execute top level imys3" mys-execute-top-level-imys3
	  :help " `mys-execute-top-level-imys3'
Send top-level at point to Imys interpreter."])
	("Jython"
	 ["Execute block jython" mys-execute-block-jython
	  :help " `mys-execute-block-jython'
Send block at point to Jython interpreter."]

	 ["Execute block or clause jython" mys-execute-block-or-clause-jython
	  :help " `mys-execute-block-or-clause-jython'
Send block-or-clause at point to Jython interpreter."]

	 ["Execute buffer jython" mys-execute-buffer-jython
	  :help " `mys-execute-buffer-jython'
Send buffer at point to Jython interpreter."]

	 ["Execute class jython" mys-execute-class-jython
	  :help " `mys-execute-class-jython'
Send class at point to Jython interpreter."]

	 ["Execute clause jython" mys-execute-clause-jython
	  :help " `mys-execute-clause-jython'
Send clause at point to Jython interpreter."]

	 ["Execute def jython" mys-execute-def-jython
	  :help " `mys-execute-def-jython'
Send def at point to Jython interpreter."]

	 ["Execute def or class jython" mys-execute-def-or-class-jython
	  :help " `mys-execute-def-or-class-jython'
Send def-or-class at point to Jython interpreter."]

	 ["Execute expression jython" mys-execute-expression-jython
	  :help " `mys-execute-expression-jython'
Send expression at point to Jython interpreter."]

	 ["Execute indent jython" mys-execute-indent-jython
	  :help " `mys-execute-indent-jython'
Send indent at point to Jython interpreter."]

	 ["Execute line jython" mys-execute-line-jython
	  :help " `mys-execute-line-jython'
Send line at point to Jython interpreter."]

	 ["Execute minor block jython" mys-execute-minor-block-jython
	  :help " `mys-execute-minor-block-jython'
Send minor-block at point to Jython interpreter."]

	 ["Execute paragraph jython" mys-execute-paragraph-jython
	  :help " `mys-execute-paragraph-jython'
Send paragraph at point to Jython interpreter."]

	 ["Execute partial expression jython" mys-execute-partial-expression-jython
	  :help " `mys-execute-partial-expression-jython'
Send partial-expression at point to Jython interpreter."]

	 ["Execute region jython" mys-execute-region-jython
	  :help " `mys-execute-region-jython'
Send region at point to Jython interpreter."]

	 ["Execute statement jython" mys-execute-statement-jython
	  :help " `mys-execute-statement-jython'
Send statement at point to Jython interpreter."]

	 ["Execute top level jython" mys-execute-top-level-jython
	  :help " `mys-execute-top-level-jython'
Send top-level at point to Jython interpreter."])
	("Python"
	 ["Execute block python" mys-execute-block-python
	  :help " `mys-execute-block-python'
Send block at point to default interpreter."]

	 ["Execute block or clause python" mys-execute-block-or-clause-python
	  :help " `mys-execute-block-or-clause-python'
Send block-or-clause at point to default interpreter."]

	 ["Execute buffer python" mys-execute-buffer-python
	  :help " `mys-execute-buffer-python'
Send buffer at point to default interpreter."]

	 ["Execute class python" mys-execute-class-python
	  :help " `mys-execute-class-python'
Send class at point to default interpreter."]

	 ["Execute clause python" mys-execute-clause-python
	  :help " `mys-execute-clause-python'
Send clause at point to default interpreter."]

	 ["Execute def python" mys-execute-def-python
	  :help " `mys-execute-def-python'
Send def at point to default interpreter."]

	 ["Execute def or class python" mys-execute-def-or-class-python
	  :help " `mys-execute-def-or-class-python'
Send def-or-class at point to default interpreter."]

	 ["Execute expression python" mys-execute-expression-python
	  :help " `mys-execute-expression-python'
Send expression at point to default interpreter."]

	 ["Execute indent python" mys-execute-indent-python
	  :help " `mys-execute-indent-python'
Send indent at point to default interpreter."]

	 ["Execute line python" mys-execute-line-python
	  :help " `mys-execute-line-python'
Send line at point to default interpreter."]

	 ["Execute minor block python" mys-execute-minor-block-python
	  :help " `mys-execute-minor-block-python'
Send minor-block at point to default interpreter."]

	 ["Execute paragraph python" mys-execute-paragraph-python
	  :help " `mys-execute-paragraph-python'
Send paragraph at point to default interpreter."]

	 ["Execute partial expression python" mys-execute-partial-expression-python
	  :help " `mys-execute-partial-expression-python'
Send partial-expression at point to default interpreter."]

	 ["Execute region python" mys-execute-region-python
	  :help " `mys-execute-region-python'
Send region at point to default interpreter."]

	 ["Execute statement python" mys-execute-statement-python
	  :help " `mys-execute-statement-python'
Send statement at point to default interpreter."]

	 ["Execute top level python" mys-execute-top-level-python
	  :help " `mys-execute-top-level-python'
Send top-level at point to default interpreter."])
	("Python2"
	 ["Execute block python2" mys-execute-block-python2
	  :help " `mys-execute-block-python2'
Send block at point to Python2 interpreter."]

	 ["Execute block or clause python2" mys-execute-block-or-clause-python2
	  :help " `mys-execute-block-or-clause-python2'
Send block-or-clause at point to Python2 interpreter."]

	 ["Execute buffer python2" mys-execute-buffer-python2
	  :help " `mys-execute-buffer-python2'
Send buffer at point to Python2 interpreter."]

	 ["Execute class python2" mys-execute-class-python2
	  :help " `mys-execute-class-python2'
Send class at point to Python2 interpreter."]

	 ["Execute clause python2" mys-execute-clause-python2
	  :help " `mys-execute-clause-python2'
Send clause at point to Python2 interpreter."]

	 ["Execute def python2" mys-execute-def-python2
	  :help " `mys-execute-def-python2'
Send def at point to Python2 interpreter."]

	 ["Execute def or class python2" mys-execute-def-or-class-python2
	  :help " `mys-execute-def-or-class-python2'
Send def-or-class at point to Python2 interpreter."]

	 ["Execute expression python2" mys-execute-expression-python2
	  :help " `mys-execute-expression-python2'
Send expression at point to Python2 interpreter."]

	 ["Execute indent python2" mys-execute-indent-python2
	  :help " `mys-execute-indent-python2'
Send indent at point to Python2 interpreter."]

	 ["Execute line python2" mys-execute-line-python2
	  :help " `mys-execute-line-python2'
Send line at point to Python2 interpreter."]

	 ["Execute minor block python2" mys-execute-minor-block-python2
	  :help " `mys-execute-minor-block-python2'
Send minor-block at point to Python2 interpreter."]

	 ["Execute paragraph python2" mys-execute-paragraph-python2
	  :help " `mys-execute-paragraph-python2'
Send paragraph at point to Python2 interpreter."]

	 ["Execute partial expression python2" mys-execute-partial-expression-python2
	  :help " `mys-execute-partial-expression-python2'
Send partial-expression at point to Python2 interpreter."]

	 ["Execute region python2" mys-execute-region-python2
	  :help " `mys-execute-region-python2'
Send region at point to Python2 interpreter."]

	 ["Execute statement python2" mys-execute-statement-python2
	  :help " `mys-execute-statement-python2'
Send statement at point to Python2 interpreter."]

	 ["Execute top level python2" mys-execute-top-level-python2
	  :help " `mys-execute-top-level-python2'
Send top-level at point to Python2 interpreter."])
	("Python3"
	 ["Execute block python3" mys-execute-block-python3
	  :help " `mys-execute-block-python3'
Send block at point to Python3 interpreter."]

	 ["Execute block or clause python3" mys-execute-block-or-clause-python3
	  :help " `mys-execute-block-or-clause-python3'
Send block-or-clause at point to Python3 interpreter."]

	 ["Execute buffer python3" mys-execute-buffer-python3
	  :help " `mys-execute-buffer-python3'
Send buffer at point to Python3 interpreter."]

	 ["Execute class python3" mys-execute-class-python3
	  :help " `mys-execute-class-python3'
Send class at point to Python3 interpreter."]

	 ["Execute clause python3" mys-execute-clause-python3
	  :help " `mys-execute-clause-python3'
Send clause at point to Python3 interpreter."]

	 ["Execute def python3" mys-execute-def-python3
	  :help " `mys-execute-def-python3'
Send def at point to Python3 interpreter."]

	 ["Execute def or class python3" mys-execute-def-or-class-python3
	  :help " `mys-execute-def-or-class-python3'
Send def-or-class at point to Python3 interpreter."]

	 ["Execute expression python3" mys-execute-expression-python3
	  :help " `mys-execute-expression-python3'
Send expression at point to Python3 interpreter."]

	 ["Execute indent python3" mys-execute-indent-python3
	  :help " `mys-execute-indent-python3'
Send indent at point to Python3 interpreter."]

	 ["Execute line python3" mys-execute-line-python3
	  :help " `mys-execute-line-python3'
Send line at point to Python3 interpreter."]

	 ["Execute minor block python3" mys-execute-minor-block-python3
	  :help " `mys-execute-minor-block-python3'
Send minor-block at point to Python3 interpreter."]

	 ["Execute paragraph python3" mys-execute-paragraph-python3
	  :help " `mys-execute-paragraph-python3'
Send paragraph at point to Python3 interpreter."]

	 ["Execute partial expression python3" mys-execute-partial-expression-python3
	  :help " `mys-execute-partial-expression-python3'
Send partial-expression at point to Python3 interpreter."]

	 ["Execute region python3" mys-execute-region-python3
	  :help " `mys-execute-region-python3'
Send region at point to Python3 interpreter."]

	 ["Execute statement python3" mys-execute-statement-python3
	  :help " `mys-execute-statement-python3'
Send statement at point to Python3 interpreter."]

	 ["Execute top level python3" mys-execute-top-level-python3
	  :help " `mys-execute-top-level-python3'
Send top-level at point to Python3 interpreter."])
	("Ignoring defaults "
	 :help "`M-x mys-execute-statement- TAB' for example list commands ignoring defaults

 of `mys-switch-buffers-on-execute-p' and `mys-split-window-on-execute'")))
      ("Hide-Show"
       ("Hide"
	["Hide block" mys-hide-block
	 :help " `mys-hide-block'
Hide block at point."]

	["Hide top level" mys-hide-top-level
	 :help " `mys-hide-top-level'
Hide top-level at point."]

	["Hide def" mys-hide-def
	 :help " `mys-hide-def'
Hide def at point."]

	["Hide def or class" mys-hide-def-or-class
	 :help " `mys-hide-def-or-class'
Hide def-or-class at point."]

	["Hide statement" mys-hide-statement
	 :help " `mys-hide-statement'
Hide statement at point."]

	["Hide class" mys-hide-class
	 :help " `mys-hide-class'
Hide class at point."]

	["Hide clause" mys-hide-clause
	 :help " `mys-hide-clause'
Hide clause at point."]

	["Hide block or clause" mys-hide-block-or-clause
	 :help " `mys-hide-block-or-clause'
Hide block-or-clause at point."]

	["Hide comment" mys-hide-comment
	 :help " `mys-hide-comment'
Hide comment at point."]

	["Hide indent" mys-hide-indent
	 :help " `mys-hide-indent'
Hide indent at point."]

	["Hide expression" mys-hide-expression
	 :help " `mys-hide-expression'
Hide expression at point."]

	["Hide line" mys-hide-line
	 :help " `mys-hide-line'
Hide line at point."]

	["Hide for-block" mys-hide-for-block
	 :help " `mys-hide-for-block'
Hide for-block at point."]

	["Hide if-block" mys-hide-if-block
	 :help " `mys-hide-if-block'
Hide if-block at point."]

	["Hide elif-block" mys-hide-elif-block
	 :help " `mys-hide-elif-block'
Hide elif-block at point."]

	["Hide else-block" mys-hide-else-block
	 :help " `mys-hide-else-block'
Hide else-block at point."]

	["Hide except-block" mys-hide-except-block
	 :help " `mys-hide-except-block'
Hide except-block at point."]

	["Hide minor-block" mys-hide-minor-block
	 :help " `mys-hide-minor-block'
Hide minor-block at point."]

	["Hide paragraph" mys-hide-paragraph
	 :help " `mys-hide-paragraph'
Hide paragraph at point."]

	["Hide partial expression" mys-hide-partial-expression
	 :help " `mys-hide-partial-expression'
Hide partial-expression at point."]

	["Hide section" mys-hide-section
	 :help " `mys-hide-section'
Hide section at point."])
       ("Show"
	["Show all" mys-show-all
	 :help " `mys-show-all'
Show all in buffer."]

	["Show" mys-show
	 :help " `mys-show'
Show hidden code at point."]))
      ("Fast process"
       ["Execute block fast" mys-execute-block-fast
	:help " `mys-execute-block-fast'
Process block at point by a Python interpreter."]

       ["Execute block or clause fast" mys-execute-block-or-clause-fast
	:help " `mys-execute-block-or-clause-fast'
Process block-or-clause at point by a Python interpreter."]

       ["Execute class fast" mys-execute-class-fast
	:help " `mys-execute-class-fast'
Process class at point by a Python interpreter."]

       ["Execute clause fast" mys-execute-clause-fast
	:help " `mys-execute-clause-fast'
Process clause at point by a Python interpreter."]

       ["Execute def fast" mys-execute-def-fast
	:help " `mys-execute-def-fast'
Process def at point by a Python interpreter."]

       ["Execute def or class fast" mys-execute-def-or-class-fast
	:help " `mys-execute-def-or-class-fast'
Process def-or-class at point by a Python interpreter."]

       ["Execute expression fast" mys-execute-expression-fast
	:help " `mys-execute-expression-fast'
Process expression at point by a Python interpreter."]

       ["Execute partial expression fast" mys-execute-partial-expression-fast
	:help " `mys-execute-partial-expression-fast'
Process partial-expression at point by a Python interpreter."]

       ["Execute region fast" mys-execute-region-fast
	:help " `mys-execute-region-fast'"]

       ["Execute statement fast" mys-execute-statement-fast
	:help " `mys-execute-statement-fast'
Process statement at point by a Python interpreter."]

       ["Execute string fast" mys-execute-string-fast
	:help " `mys-execute-string-fast'"]

       ["Execute top level fast" mys-execute-top-level-fast
	:help " `mys-execute-top-level-fast'
Process top-level at point by a Python interpreter."])
      ("Virtualenv"
       ["Virtualenv activate" virtualenv-activate
	:help " `virtualenv-activate'
Activate the virtualenv located in DIR"]

       ["Virtualenv deactivate" virtualenv-deactivate
	:help " `virtualenv-deactivate'
Deactivate the current virtual enviroment"]

       ["Virtualenv p" virtualenv-p
	:help " `virtualenv-p'
Check if a directory is a virtualenv"]

       ["Virtualenv workon" virtualenv-workon
	:help " `virtualenv-workon'
Issue a virtualenvwrapper-like virtualenv-workon command"])

      ["Execute import or reload" mys-execute-import-or-reload
       :help " `mys-execute-import-or-reload'
Import the current buffer’s file in a Python interpreter."]
      ("Help"
       ["Find definition" mys-find-definition
	:help " `mys-find-definition'
Find source of definition of SYMBOL."]

       ["Help at point" mys-help-at-point
	:help " `mys-help-at-point'
Print help on symbol at point."]

       ["Info lookup symbol" mys-info-lookup-symbol
	:help " `mys-info-lookup-symbol'"]

       ["Symbol at point" mys-symbol-at-point
	:help " `mys-symbol-at-point'
Return the current Python symbol."])
      ("Debugger"
       ["Execute statement pdb" mys-execute-statement-pdb
	:help " `mys-execute-statement-pdb'
Execute statement running pdb."]

       ["Pdb" pdb
	:help " `pdb'
Run pdb on program FILE in buffer `*gud-FILE*'."])
      ("Checks"
       ["Pychecker run" mys-pychecker-run
	:help " `mys-pychecker-run'
*Run pychecker (default on the file currently visited)."]
       ("Pylint"
	["Pylint run" mys-pylint-run
	 :help " `mys-pylint-run'
*Run pylint (default on the file currently visited)."]

	["Pylint help" mys-pylint-help
	 :help " `mys-pylint-help'
Display Pylint command line help messages."]

	["Pylint flymake mode" pylint-flymake-mode
	 :help " `pylint-flymake-mode'
Toggle `pylint' `flymake-mode'."])
       ("Pep8"
	["Pep8 run" mys-pep8-run
	 :help " `mys-pep8-run'
*Run pep8, check formatting - default on the file currently visited."]

	["Pep8 help" mys-pep8-help
	 :help " `mys-pep8-help'
Display pep8 command line help messages."]

	["Pep8 flymake mode" pep8-flymake-mode
	 :help " `pep8-flymake-mode'
Toggle `pep8’ `flymake-mode'."])
       ("Pyflakes"
	["Pyflakes run" mys-pyflakes-run
	 :help " `mys-pyflakes-run'
*Run pyflakes (default on the file currently visited)."]

	["Pyflakes help" mys-pyflakes-help
	 :help " `mys-pyflakes-help'
Display Pyflakes command line help messages."]

	["Pyflakes flymake mode" pyflakes-flymake-mode
	 :help " `pyflakes-flymake-mode'
Toggle `pyflakes' `flymake-mode'."])
       ("Flake8"
	["Flake8 run" mys-flake8-run
	 :help " `mys-flake8-run'
Flake8 is a wrapper around these tools:"]

	["Flake8 help" mys-flake8-help
	 :help " `mys-flake8-help'
Display flake8 command line help messages."]
	("Pyflakes-pep8"
	 ["Pyflakes pep8 run" mys-pyflakes-pep8-run
	  :help " `mys-pyflakes-pep8-run'"]

	 ["Pyflakes pep8 help" mys-pyflakes-pep8-help
	  :help " `mys-pyflakes-pep8-help'"]

	 ["Pyflakes pep8 flymake mode" pyflakes-pep8-flymake-mode
	  :help " `pyflakes-pep8-flymake-mode'"])))
      ("Customize"

       ["Mys-mode customize group" (customize-group 'mys-mode)
	:help "Open the customization buffer for Python mode"]
       ("Switches"
	:help "Toggle useful modes"
	("Interpreter"

	 ["Shell prompt read only"
	  (setq mys-shell-prompt-read-only
		(not mys-shell-prompt-read-only))
	  :help "If non-nil, the python prompt is read only.  Setting this variable will only effect new shells.Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-shell-prompt-read-only]

	 ["Remove cwd from path"
	  (setq mys-remove-cwd-from-path
		(not mys-remove-cwd-from-path))
	  :help "Whether to allow loading of Python modules from the current directory.
If this is non-nil, Emacs removes '' from sys.path when starting
a Python process.  This is the default, for security
reasons, as it is easy for the Python process to be started
without the user's realization (e.g. to perform completion).Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-remove-cwd-from-path]

	 ["Honor IMYSDIR "
	  (setq mys-honor-IMYSDIR-p
		(not mys-honor-IMYSDIR-p))
	  :help "When non-nil imys-history file is constructed by \$IMYSDIR
followed by "/history". Default is nil.

Otherwise value of mys-imys-history is used. Use `M-x customize-variable' to set it permanently"
:style toggle :selected mys-honor-IMYSDIR-p]

	 ["Honor PYTHONHISTORY "
	  (setq mys-honor-PYTHONHISTORY-p
		(not mys-honor-PYTHONHISTORY-p))
	  :help "When non-nil mys-history file is set by \$PYTHONHISTORY
Default is nil.

Otherwise value of mys-mys-history is used. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-honor-PYTHONHISTORY-p]

	 ["Enforce mys-shell-name" force-mys-shell-name-p-on
	  :help "Enforce customized default `mys-shell-name' should upon execution. "]

	 ["Don't enforce default interpreter" force-mys-shell-name-p-off
	  :help "Make execute commands guess interpreter from environment"]
	 )

	("Execute"

	 ["Fast process" mys-fast-process-p
	  :help " `mys-fast-process-p'

Use `mys-fast-process'\.

Commands prefixed \"mys-fast-...\" suitable for large output

See: large output makes Emacs freeze, lp:1253907

Output-buffer is not in comint-mode"
	  :style toggle :selected mys-fast-process-p]

	 ["Python mode v5 behavior"
	  (setq mys-mode-v5-behavior-p
		(not mys-mode-v5-behavior-p))
	  :help "Execute region through `shell-command-on-region' as
v5 did it - lp:990079. This might fail with certain chars - see UnicodeEncodeError lp:550661

Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-mode-v5-behavior-p]

	 ["Force shell name "
	  (setq mys-force-mys-shell-name-p
		(not mys-force-mys-shell-name-p))
	  :help "When `t', execution with kind of Python specified in `mys-shell-name' is enforced, possibly shebang doesn't take precedence. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-force-mys-shell-name-p]

	 ["Execute \"if name == main\" blocks p"
	  (setq mys-if-name-main-permission-p
		(not mys-if-name-main-permission-p))
	  :help " `mys-if-name-main-permission-p'

Allow execution of code inside blocks delimited by
if __name__ == '__main__'

Default is non-nil. "
	  :style toggle :selected mys-if-name-main-permission-p]

	 ["Ask about save"
	  (setq mys-ask-about-save
		(not mys-ask-about-save))
	  :help "If not nil, ask about which buffers to save before executing some code.
Otherwise, all modified buffers are saved without asking.Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-ask-about-save]

	 ["Store result"
	  (setq mys-store-result-p
		(not mys-store-result-p))
	  :help " `mys-store-result-p'

When non-nil, put resulting string of `mys-execute-...' into kill-ring, so it might be yanked. "
	  :style toggle :selected mys-store-result-p]

	 ["Prompt on changed "
	  (setq mys-prompt-on-changed-p
		(not mys-prompt-on-changed-p))
	  :help "When called interactively, ask for save before a changed buffer is sent to interpreter.

Default is `t'Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-prompt-on-changed-p]

	 ["Dedicated process "
	  (setq mys-dedicated-process-p
		(not mys-dedicated-process-p))
	  :help "If commands executing code use a dedicated shell.

Default is nilUse `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-dedicated-process-p]

	 ["Execute without temporary file"
	  (setq mys-execute-no-temp-p
		(not mys-execute-no-temp-p))
	  :help " `mys-execute-no-temp-p'
Seems Emacs-24.3 provided a way executing stuff without temporary files.
In experimental state yet "
	  :style toggle :selected mys-execute-no-temp-p]

	 ["Warn tmp files left "
	  (setq mys--warn-tmp-files-left-p
		(not mys--warn-tmp-files-left-p))
	  :help "Messages a warning, when `mys-temp-directory' contains files susceptible being left by previous Mys-mode sessions. See also lp:987534 Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys--warn-tmp-files-left-p])

	("Edit"

	 ("Completion"

	  ["Set Pymacs-based complete keymap "
	   (setq mys-set-complete-keymap-p
		 (not mys-set-complete-keymap-p))
	   :help "If `mys-complete-initialize', which sets up enviroment for Pymacs based mys-complete, should load it's keys into `mys-mode-map'

Default is nil.
See also resp. edit `mys-complete-set-keymap' Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-set-complete-keymap-p]

	  ["Indent no completion "
	   (setq mys-indent-no-completion-p
		 (not mys-indent-no-completion-p))
	   :help "If completion function should indent when no completion found. Default is `t'

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-indent-no-completion-p]

	  ["Company pycomplete "
	   (setq mys-company-pycomplete-p
		 (not mys-company-pycomplete-p))
	   :help "Load company-pycomplete stuff. Default is nilUse `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-company-pycomplete-p])

	 ("Filling"

	  ("Docstring styles"
	   :help "Switch docstring-style"

	   ["Nil" mys-set-nil-docstring-style
	    :help " `mys-set-nil-docstring-style'

Set mys-docstring-style to nil, format string normally. "]

	   ["pep-257-nn" mys-set-pep-257-nn-docstring-style
	    :help " `mys-set-pep-257-nn-docstring-style'

Set mys-docstring-style to 'pep-257-nn "]

	   ["pep-257" mys-set-pep-257-docstring-style
	    :help " `mys-set-pep-257-docstring-style'

Set mys-docstring-style to 'pep-257 "]

	   ["django" mys-set-django-docstring-style
	    :help " `mys-set-django-docstring-style'

Set mys-docstring-style to 'django "]

	   ["onetwo" mys-set-onetwo-docstring-style
	    :help " `mys-set-onetwo-docstring-style'

Set mys-docstring-style to 'onetwo "]

	   ["symmetric" mys-set-symmetric-docstring-style
	    :help " `mys-set-symmetric-docstring-style'

Set mys-docstring-style to 'symmetric "])

	  ["Auto-fill mode"
	   (setq mys-auto-fill-mode
		 (not mys-auto-fill-mode))
	   :help "Fill according to `mys-docstring-fill-column' and `mys-comment-fill-column'

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-auto-fill-mode])

	 ["Use current dir when execute"
	  (setq mys-use-current-dir-when-execute-p
		(not mys-use-current-dir-when-execute-p))
	  :help " `mys-toggle-use-current-dir-when-execute-p'

Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-use-current-dir-when-execute-p]

	 ("Indent"
	  ("TAB related"

	   ["indent-tabs-mode"
	    (setq indent-tabs-mode
		  (not indent-tabs-mode))
	    :help "Indentation can insert tabs if this is non-nil.

Use `M-x customize-variable' to set it permanently"
	    :style toggle :selected indent-tabs-mode]

	   ["Tab indent"
	    (setq mys-tab-indent
		  (not mys-tab-indent))
	    :help "Non-nil means TAB in Python mode calls `mys-indent-line'.Use `M-x customize-variable' to set it permanently"
	    :style toggle :selected mys-tab-indent]

	   ["Tab shifts region "
	    (setq mys-tab-shifts-region-p
		  (not mys-tab-shifts-region-p))
	    :help "If `t', TAB will indent/cycle the region, not just the current line.

Default is nil
See also `mys-tab-indents-region-p'

Use `M-x customize-variable' to set it permanently"
	    :style toggle :selected mys-tab-shifts-region-p]

	   ["Tab indents region "
	    (setq mys-tab-indents-region-p
		  (not mys-tab-indents-region-p))
	    :help "When `t' and first TAB doesn't shift, indent-region is called.

Default is nil
See also `mys-tab-shifts-region-p'

Use `M-x customize-variable' to set it permanently"
	    :style toggle :selected mys-tab-indents-region-p])

	  ["Close at start column"
	   (setq mys-closing-list-dedents-bos
		 (not mys-closing-list-dedents-bos))
	   :help "When non-nil, indent list's closing delimiter like start-column.

It will be lined up under the first character of
 the line that starts the multi-line construct, as in:

my_list = \[
    1, 2, 3,
    4, 5, 6,]

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-closing-list-dedents-bos]

	  ["Closing list keeps space"
	   (setq mys-closing-list-keeps-space
		 (not mys-closing-list-keeps-space))
	   :help "If non-nil, closing parenthesis dedents onto column of opening plus `mys-closing-list-space', default is nil Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-closing-list-keeps-space]

	  ["Closing list space"
	   (setq mys-closing-list-space
		 (not mys-closing-list-space))
	   :help "Number of chars, closing parenthesis outdent from opening, default is 1 Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-closing-list-space]

	  ["Tab shifts region "
	   (setq mys-tab-shifts-region-p
		 (not mys-tab-shifts-region-p))
	   :help "If `t', TAB will indent/cycle the region, not just the current line.

Default is nil
See also `mys-tab-indents-region-p'Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-tab-shifts-region-p]

	  ["Lhs inbound indent"
	   (setq mys-lhs-inbound-indent
		 (not mys-lhs-inbound-indent))
	   :help "When line starts a multiline-assignment: How many colums indent should be more than opening bracket, brace or parenthesis. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-lhs-inbound-indent]

	  ["Continuation offset"
	   (setq mys-continuation-offset
		 (not mys-continuation-offset))
	   :help "With numeric ARG different from 1 mys-continuation-offset is set to that value; returns mys-continuation-offset. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-continuation-offset]

	  ["Electric colon"
	   (setq mys-electric-colon-active-p
		 (not mys-electric-colon-active-p))
	   :help " `mys-electric-colon-active-p'

`mys-electric-colon' feature.  Default is `nil'. See lp:837065 for discussions. "
	   :style toggle :selected mys-electric-colon-active-p]

	  ["Electric colon at beginning of block only"
	   (setq mys-electric-colon-bobl-only
		 (not mys-electric-colon-bobl-only))
	   :help "When inserting a colon, do not indent lines unless at beginning of block.

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-electric-colon-bobl-only]

	  ["Electric yank active "
	   (setq mys-electric-yank-active-p
		 (not mys-electric-yank-active-p))
	   :help " When non-nil, `yank' will be followed by an `indent-according-to-mode'.

Default is nilUse `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-electric-yank-active-p]



	  ["Trailing whitespace smart delete "
	   (setq mys-trailing-whitespace-smart-delete-p
		 (not mys-trailing-whitespace-smart-delete-p))
	   :help "Default is nil. When t, mys-mode calls
    (add-hook 'before-save-hook 'delete-trailing-whitespace nil 'local)

Also commands may delete trailing whitespace by the way.
When editing other peoples code, this may produce a larger diff than expected Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-trailing-whitespace-smart-delete-p]

	  ["Newline delete trailing whitespace "
	   (setq mys-newline-delete-trailing-whitespace-p
		 (not mys-newline-delete-trailing-whitespace-p))
	   :help "Delete trailing whitespace maybe left by `mys-newline-and-indent'.

Default is `t'. See lp:1100892 Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-newline-delete-trailing-whitespace-p]

	  ["Dedent keep relative column"
	   (setq mys-dedent-keep-relative-column
		 (not mys-dedent-keep-relative-column))
	   :help "If point should follow dedent or kind of electric move to end of line. Default is t - keep relative position. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-dedent-keep-relative-column]

	  ["Indent comment "
	   (setq mys-indent-comments
		 (not mys-indent-comments))
	   :help "If comments should be indented like code. Default is `nil'.

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-indent-comments]

	  ["Uncomment indents "
	   (setq mys-uncomment-indents-p
		 (not mys-uncomment-indents-p))
	   :help "When non-nil, after uncomment indent lines. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-uncomment-indents-p]

	  ["Indent honors inline comment"
	   (setq mys-indent-honors-inline-comment
		 (not mys-indent-honors-inline-comment))
	   :help "If non-nil, indents to column of inlined comment start.
Default is nil. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-indent-honors-inline-comment]

	  ["Kill empty line"
	   (setq mys-kill-empty-line
		 (not mys-kill-empty-line))
	   :help "If t, mys-indent-forward-line kills empty lines. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-kill-empty-line]

	  ("Smart indentation"
	   :help "Toggle mys-smart-indentation'

Use `M-x customize-variable' to set it permanently"

	   ["Toggle mys-smart-indentation" mys-toggle-smart-indentation
	    :help "Toggles mys-smart-indentation

Use `M-x customize-variable' to set it permanently"]

	   ["mys-smart-indentation on" mys-smart-indentation-on
	    :help "Switches mys-smart-indentation on

Use `M-x customize-variable' to set it permanently"]

	   ["mys-smart-indentation off" mys-smart-indentation-off
	    :help "Switches mys-smart-indentation off

Use `M-x customize-variable' to set it permanently"])

	  ["Beep if tab change"
	   (setq mys-beep-if-tab-change
		 (not mys-beep-if-tab-change))
	   :help "Ring the bell if `tab-width' is changed.
If a comment of the form

                           	# vi:set tabsize=<number>:

is found before the first code line when the file is entered, and the
current value of (the general Emacs variable) `tab-width' does not
equal <number>, `tab-width' is set to <number>, a message saying so is
displayed in the echo area, and if `mys-beep-if-tab-change' is non-nil
the Emacs bell is also rung as a warning.Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-beep-if-tab-change]

	  ["Electric comment "
	   (setq mys-electric-comment-p
		 (not mys-electric-comment-p))
	   :help "If \"#\" should call `mys-electric-comment'. Default is `nil'.

Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-electric-comment-p]

	  ["Electric comment add space "
	   (setq mys-electric-comment-add-space-p
		 (not mys-electric-comment-add-space-p))
	   :help "If mys-electric-comment should add a space.  Default is `nil'. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-electric-comment-add-space-p]

	  ["Empty line closes "
	   (setq mys-empty-line-closes-p
		 (not mys-empty-line-closes-p))
	   :help "When non-nil, dedent after empty line following block

if True:
    print(\"Part of the if-statement\")

print(\"Not part of the if-statement\")

Default is nil

If non-nil, a C-j from empty line dedents.
Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-empty-line-closes-p])
	 ["Defun use top level "
	  (setq mys-defun-use-top-level-p
		(not mys-defun-use-top-level-p))
	  :help "When non-nil, keys C-M-a, C-M-e address top-level form.

Beginning- end-of-defun forms use
commands `mys-backward-top-level', `mys-forward-top-level'

mark-defun marks top-level form at point etc. "
	  :style toggle :selected mys-defun-use-top-level-p]

	 ["Close provides newline"
	  (setq mys-close-provides-newline
		(not mys-close-provides-newline))
	  :help "If a newline is inserted, when line after block isn't empty. Default is non-nil. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-close-provides-newline]

	 ["Block comment prefix "
	  (setq mys-block-comment-prefix-p
		(not mys-block-comment-prefix-p))
	  :help "If mys-comment inserts mys-block-comment-prefix.

Default is tUse `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-block-comment-prefix-p])

	("Display"

	 ("Index"

	  ["Imenu create index "
	   (setq mys--imenu-create-index-p
		 (not mys--imenu-create-index-p))
	   :help "Non-nil means Python mode creates and displays an index menu of functions and global variables. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys--imenu-create-index-p]

	  ["Imenu show method args "
	   (setq mys-imenu-show-method-args-p
		 (not mys-imenu-show-method-args-p))
	   :help "Controls echoing of arguments of functions & methods in the Imenu buffer.
When non-nil, arguments are printed.Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-imenu-show-method-args-p]
	  ["Switch index-function" mys-switch-imenu-index-function
	   :help "`mys-switch-imenu-index-function'
Switch between `mys--imenu-create-index' from 5.1 series and `mys--imenu-create-index-new'."])

	 ("Fontification"

	  ["Mark decorators"
	   (setq mys-mark-decorators
		 (not mys-mark-decorators))
	   :help "If mys-mark-def-or-class functions should mark decorators too. Default is `nil'. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-mark-decorators]

	  ["Fontify shell buffer "
	   (setq mys-fontify-shell-buffer-p
		 (not mys-fontify-shell-buffer-p))
	   :help "If code in Python shell should be highlighted as in script buffer.

Default is nil.

If `t', related vars like `comment-start' will be set too.
Seems convenient when playing with stuff in Imys shell
Might not be TRT when a lot of output arrives Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-fontify-shell-buffer-p]

	  ["Use font lock doc face "
	   (setq mys-use-font-lock-doc-face-p
		 (not mys-use-font-lock-doc-face-p))
	   :help "If documention string inside of def or class get `font-lock-doc-face'.

`font-lock-doc-face' inherits `font-lock-string-face'.

Call M-x `customize-face' in order to have a visible effect. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-use-font-lock-doc-face-p])

	 ["Switch buffers on execute"
	  (setq mys-switch-buffers-on-execute-p
		(not mys-switch-buffers-on-execute-p))
	  :help "When non-nil switch to the Python output buffer.

Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-switch-buffers-on-execute-p]

	 ["Split windows on execute"
	  (setq mys-split-window-on-execute
		(not mys-split-window-on-execute))
	  :help "When non-nil split windows.

Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-split-window-on-execute]

	 ["Keep windows configuration"
	  (setq mys-keep-windows-configuration
		(not mys-keep-windows-configuration))
	  :help "If a windows is splitted displaying results, this is directed by variable `mys-split-window-on-execute'\. Also setting `mys-switch-buffers-on-execute-p' affects window-configuration\. While commonly a screen splitted into source and Mys-shell buffer is assumed, user may want to keep a different config\.

Setting `mys-keep-windows-configuration' to `t' will restore windows-config regardless of settings mentioned above\. However, if an error occurs, it's displayed\.

To suppres window-changes due to error-signaling also: M-x customize-variable RET. Set `mys-keep-4windows-configuration' onto 'force

Default is nil Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-keep-windows-configuration]

	 ["Which split windows on execute function"
	  (progn
	    (if (eq 'split-window-vertically mys-split-windows-on-execute-function)
		(setq mys-split-windows-on-execute-function'split-window-horizontally)
	      (setq mys-split-windows-on-execute-function 'split-window-vertically))
	    (message "mys-split-windows-on-execute-function set to: %s" mys-split-windows-on-execute-function))

	  :help "If `split-window-vertically' or `...-horizontally'. Use `M-x customize-variable' RET `mys-split-windows-on-execute-function' RET to set it permanently"
	  :style toggle :selected mys-split-windows-on-execute-function]

	 ["Modeline display full path "
	  (setq mys-modeline-display-full-path-p
		(not mys-modeline-display-full-path-p))
	  :help "If the full PATH/TO/PYTHON should be displayed in shell modeline.

Default is nil. Note: when `mys-shell-name' is specified with path, it's shown as an acronym in buffer-name already. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-modeline-display-full-path-p]

	 ["Modeline acronym display home "
	  (setq mys-modeline-acronym-display-home-p
		(not mys-modeline-acronym-display-home-p))
	  :help "If the modeline acronym should contain chars indicating the home-directory.

Default is nil Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-modeline-acronym-display-home-p]

	 ["Hide show hide docstrings"
	  (setq mys-hide-show-hide-docstrings
		(not mys-hide-show-hide-docstrings))
	  :help "Controls if doc strings can be hidden by hide-showUse `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-hide-show-hide-docstrings]

	 ["Hide comments when hiding all"
	  (setq mys-hide-comments-when-hiding-all
		(not mys-hide-comments-when-hiding-all))
	  :help "Hide the comments too when you do `hs-hide-all'. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-hide-comments-when-hiding-all]

	 ["Max help buffer "
	  (setq mys-max-help-buffer-p
		(not mys-max-help-buffer-p))
	  :help "If \"\*Mys-Help\*\"-buffer should appear as the only visible.

Default is nil. In help-buffer, \"q\" will close it.  Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-max-help-buffer-p]

	 ["Current defun show"
	  (setq mys-current-defun-show
		(not mys-current-defun-show))
	  :help "If `mys-current-defun' should jump to the definition, highlight it while waiting MYS-WHICH-FUNC-DELAY seconds, before returning to previous position.

Default is `t'.Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-current-defun-show]

	 ["Match paren mode"
	  (setq mys-match-paren-mode
		(not mys-match-paren-mode))
	  :help "Non-nil means, cursor will jump to beginning or end of a block.
This vice versa, to beginning first.
Sets `mys-match-paren-key' in mys-mode-map.
Customize `mys-match-paren-key' which key to use. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-match-paren-mode])

	("Debug"

	 ["mys-debug-p"
	  (setq mys-debug-p
		(not mys-debug-p))
	  :help "When non-nil, keep resp\. store information useful for debugging\.

Temporary files are not deleted\. Other functions might implement
some logging etc\. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-debug-p]

	 ["Pdbtrack do tracking "
	  (setq mys-pdbtrack-do-tracking-p
		(not mys-pdbtrack-do-tracking-p))
	  :help "Controls whether the pdbtrack feature is enabled or not.
When non-nil, pdbtrack is enabled in all comint-based buffers,
e.g. shell buffers and the \*Python\* buffer.  When using pdb to debug a
Python program, pdbtrack notices the pdb prompt and displays the
source file and line that the program is stopped at, much the same way
as gud-mode does for debugging C programs with gdb.Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-pdbtrack-do-tracking-p]

	 ["Jump on exception"
	  (setq mys-jump-on-exception
		(not mys-jump-on-exception))
	  :help "Jump to innermost exception frame in Python output buffer.
When this variable is non-nil and an exception occurs when running
Python code synchronously in a subprocess, jump immediately to the
source code of the innermost traceback frame.

Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-jump-on-exception]

	 ["Highlight error in source "
	  (setq mys-highlight-error-source-p
		(not mys-highlight-error-source-p))
	  :help "Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-highlight-error-source-p])

	("Other"

	 ("Directory"

	  ["Guess install directory "
	   (setq mys-guess-mys-install-directory-p
		 (not mys-guess-mys-install-directory-p))
	   :help "If in cases, `mys-install-directory' isn't set,  `mys-set-load-path'should guess it from `buffer-file-name'. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-guess-mys-install-directory-p]

	  ["Use local default"
	   (setq mys-use-local-default
		 (not mys-use-local-default))
	   :help "If `t', mys-shell will use `mys-shell-local-path' instead
of default Python.

Making switch between several virtualenv's easier,
                               `mys-mode' should deliver an installer, so named-shells pointing to virtualenv's will be available. Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-use-local-default]

	  ["Use current dir when execute "
	   (setq mys-use-current-dir-when-execute-p
		 (not mys-use-current-dir-when-execute-p))
	   :help "When `t', current directory is used by Mys-shell for output of `mys-execute-buffer' and related commands.

See also `mys-execute-directory'Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-use-current-dir-when-execute-p]

	  ["Keep shell dir when execute "
	   (setq mys-keep-shell-dir-when-execute-p
		 (not mys-keep-shell-dir-when-execute-p))
	   :help "Don't change Python shell's current working directory when sending code.

See also `mys-execute-directory'Use `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-keep-shell-dir-when-execute-p]

	  ["Fileless buffer use default directory "
	   (setq mys-fileless-buffer-use-default-directory-p
		 (not mys-fileless-buffer-use-default-directory-p))
	   :help "When `mys-use-current-dir-when-execute-p' is non-nil and no buffer-file exists, value of `default-directory' sets current working directory of Python output shellUse `M-x customize-variable' to set it permanently"
	   :style toggle :selected mys-fileless-buffer-use-default-directory-p])

	 ("Underscore word syntax"
	  :help "Toggle `mys-underscore-word-syntax-p'"

	  ["Toggle underscore word syntax" mys-toggle-underscore-word-syntax-p
	   :help " `mys-toggle-underscore-word-syntax-p'

If `mys-underscore-word-syntax-p' should be on or off.

  Returns value of `mys-underscore-word-syntax-p' switched to. .

Use `M-x customize-variable' to set it permanently"]

	  ["Underscore word syntax on" mys-underscore-word-syntax-p-on
	   :help " `mys-underscore-word-syntax-p-on'

Make sure, mys-underscore-word-syntax-p' is on.

Returns value of `mys-underscore-word-syntax-p'. .

Use `M-x customize-variable' to set it permanently"]

	  ["Underscore word syntax off" mys-underscore-word-syntax-p-off
	   :help " `mys-underscore-word-syntax-p-off'

Make sure, `mys-underscore-word-syntax-p' is off.

Returns value of `mys-underscore-word-syntax-p'. .

Use `M-x customize-variable' to set it permanently"])

	 ["Load pymacs "
	  (setq mys-load-pymacs-p
		(not mys-load-pymacs-p))
	  :help "If Pymacs related stuff should be loaded.

Default is nil.

Pymacs has been written by François Pinard and many others.
See original source: http://pymacs.progiciels-bpi.caUse `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-load-pymacs-p]

	 ["Verbose "
	  (setq mys-verbose-p
		(not mys-verbose-p))
	  :help "If functions should report results.

Default is nil. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-verbose-p]
	 ;; ["No session mode "
	 ;; 	  (setq mys-no-session-p
	 ;; 		(not mys-no-session-p))
	 ;; 	  :help "If shell should be in session-mode.

	 ;; Default is nil. Use `M-x customize-variable' to set it permanently"
	 ;; 	  :style toggle :selected mys-no-session-p]

	 ["Empty comment line separates paragraph "
	  (setq mys-empty-comment-line-separates-paragraph-p
		(not mys-empty-comment-line-separates-paragraph-p))
	  :help "Consider paragraph start/end lines with nothing inside but comment sign.

Default is non-nilUse `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-empty-comment-line-separates-paragraph-p]

	 ["Org cycle "
	  (setq mys-org-cycle-p
		(not mys-org-cycle-p))
	  :help "When non-nil, command `org-cycle' is available at shift-TAB, <backtab>

Default is nil. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-org-cycle-p]

	 ["Set pager cat"
	  (setq mys-set-pager-cat-p
		(not mys-set-pager-cat-p))
	  :help "If the shell environment variable \$PAGER should set to `cat'.

If `t', use `C-c C-r' to jump to beginning of output. Then scroll normally.

Avoids lp:783828, \"Terminal not fully functional\", for help('COMMAND') in mys-shell

When non-nil, imports module `os' Use `M-x customize-variable' to
set it permanently"
	  :style toggle :selected mys-set-pager-cat-p]

	 ["Edit only "
	  (setq mys-edit-only-p
		(not mys-edit-only-p))
	  :help "When `t' `mys-mode' will not take resort nor check for installed Python executables. Default is nil.

See bug report at launchpad, lp:944093. Use `M-x customize-variable' to set it permanently"
	  :style toggle :selected mys-edit-only-p])))
      ("Other"
       ["Boolswitch" mys-boolswitch
	:help " `mys-boolswitch'
Edit the assignment of a boolean variable, revert them."]

       ["Empty out list backward" mys-empty-out-list-backward
	:help " `mys-empty-out-list-backward'
Deletes all elements from list before point."]

       ["Kill buffer unconditional" mys-kill-buffer-unconditional
	:help " `mys-kill-buffer-unconditional'
Kill buffer unconditional, kill buffer-process if existing."]

       ["Remove overlays at point" mys-remove-overlays-at-point
	:help " `mys-remove-overlays-at-point'
Remove overlays as set when `mys-highlight-error-source-p' is non-nil."]
       ("Electric"
	["Complete electric comma" mys-complete-electric-comma
	 :help " `mys-complete-electric-comma'"]

	["Complete electric lparen" mys-complete-electric-lparen
	 :help " `mys-complete-electric-lparen'"]

	["Electric backspace" mys-electric-backspace
	 :help " `mys-electric-backspace'
Delete preceding character or level of indentation."]

	["Electric colon" mys-electric-colon
	 :help " `mys-electric-colon'
Insert a colon and indent accordingly."]

	["Electric comment" mys-electric-comment
	 :help " `mys-electric-comment'
Insert a comment. If starting a comment, indent accordingly."]

	["Electric delete" mys-electric-delete
	 :help " `mys-electric-delete'
Delete following character or levels of whitespace."]

	["Electric yank" mys-electric-yank
	 :help " `mys-electric-yank'
Perform command `yank' followed by an `indent-according-to-mode'"]

	["Hungry delete backwards" mys-hungry-delete-backwards
	 :help " `mys-hungry-delete-backwards'
Delete the preceding character or all preceding whitespace"]

	["Hungry delete forward" mys-hungry-delete-forward
	 :help " `mys-hungry-delete-forward'
Delete the following character or all following whitespace"])
       ("Filling"
	["Py docstring style" mys-docstring-style
	 :help " `mys-docstring-style'"]

	["Py fill comment" mys-fill-comment
	 :help " `mys-fill-comment'"]

	["Py fill paragraph" mys-fill-paragraph
	 :help " `mys-fill-paragraph'"]

	["Py fill string" mys-fill-string
	 :help " `mys-fill-string'"]

	["Py fill string django" mys-fill-string-django
	 :help " `mys-fill-string-django'"]

	["Py fill string onetwo" mys-fill-string-onetwo
	 :help " `mys-fill-string-onetwo'"]

	["Py fill string pep 257" mys-fill-string-pep-257
	 :help " `mys-fill-string-pep-257'"]

	["Py fill string pep 257 nn" mys-fill-string-pep-257-nn
	 :help " `mys-fill-string-pep-257-nn'"]

	["Py fill string symmetric" mys-fill-string-symmetric
	 :help " `mys-fill-string-symmetric'"])
       ("Abbrevs"	   :help "see also `mys-add-abbrev'"
	:filter (lambda (&rest junk)
		  (abbrev-table-menu mys-mode-abbrev-table)))

       ["Add abbrev" mys-add-abbrev
	:help " `mys-add-abbrev'
Defines mys-mode specific abbrev for last expressions before point."]
       ("Completion"
	["Py indent or complete" mys-indent-or-complete
	 :help " `mys-indent-or-complete'"]

	["Py shell complete" mys-shell-complete
	 :help " `mys-shell-complete'"]

	["Py complete" mys-complete
	 :help " `mys-complete'"])

       ["Find function" mys-find-function
	:help " `mys-find-function'
Find source of definition of SYMBOL."])))
  map)

;; mys-components-map

(defvar mys-use-menu-p t
  "If the menu should be loaded.

Default is t")

(defvar mys-menu nil
  "Make a dynamically bound variable `mys-menu'.")


(setq mys-mode-map
      (let ((map (make-sparse-keymap)))
        ;; electric keys
        (define-key map [(:)] 'mys-electric-colon)
        (define-key map [(\#)] 'mys-electric-comment)
        (define-key map [(delete)] 'mys-electric-delete)
        (define-key map [(backspace)] 'mys-electric-backspace)
        (define-key map [(control backspace)] 'mys-hungry-delete-backwards)
        (define-key map [(control c) (delete)] 'mys-hungry-delete-forward)
        ;; (define-key map [(control y)] 'mys-electric-yank)
        ;; moving point
        (define-key map [(control c) (control p)] 'mys-backward-statement)
        (define-key map [(control c) (control n)] 'mys-forward-statement)
        (define-key map [(control c) (control u)] 'mys-backward-block)
        (define-key map [(control c) (control q)] 'mys-forward-block)
        (define-key map [(control meta a)] 'mys-backward-def-or-class)
        (define-key map [(control meta e)] 'mys-forward-def-or-class)
        ;; (define-key map [(meta i)] 'mys-indent-forward-line)
        ;; (define-key map [(control j)] 'mys-newline-and-indent)
	(define-key map (kbd "C-j") 'newline)
        ;; Most Pythoneers expect RET `mys-newline-and-indent'
	;; which is default of var mys-return-key’
        (define-key map (kbd "RET") mys-return-key)
        ;; (define-key map (kbd "RET") 'newline)
        ;; (define-key map (kbd "RET") 'mys-newline-and-dedent)
        (define-key map [(super backspace)] 'mys-dedent)
        ;; (define-key map [(control return)] 'mys-newline-and-dedent)
        ;; indentation level modifiers
        (define-key map [(control c) (control l)] 'mys-shift-left)
        (define-key map [(control c) (control r)] 'mys-shift-right)
        (define-key map [(control c) (<)] 'mys-shift-left)
        (define-key map [(control c) (>)] 'mys-shift-right)
        ;; (define-key map [(control c) (tab)] 'mys-indent-region)
	(define-key map (kbd "C-c TAB") 'mys-indent-region)
        (define-key map [(control c) (:)] 'mys-guess-indent-offset)
        ;; subprocess commands
        (define-key map [(control c) (control c)] 'mys-execute-buffer)
        (define-key map [(control c) (control m)] 'mys-execute-import-or-reload)
        (define-key map [(control c) (control s)] 'mys-execute-string)
        (define-key map [(control c) (|)] 'mys-execute-region)
        (define-key map [(control meta x)] 'mys-execute-def-or-class)
        (define-key map [(control c) (!)] 'mys-shell)
        (define-key map [(control c) (control t)] 'mys-toggle-shell)
        (define-key map [(control meta h)] 'mys-mark-def-or-class)
        (define-key map [(control c) (control k)] 'mys-mark-block-or-clause)
        (define-key map [(control c) (.)] 'mys-expression)
        ;; Miscellaneous
        ;; (define-key map [(super q)] 'mys-comys-statement)
        (define-key map [(control c) (control d)] 'mys-pdbtrack-toggle-stack-tracking)
        (define-key map [(control c) (control f)] 'mys-sort-imports)
        (define-key map [(control c) (\#)] 'mys-comment-region)
        (define-key map [(control c) (\?)] 'mys-describe-mode)
        (define-key map [(control c) (control e)] 'mys-help-at-point)
        (define-key map [(control c) (-)] 'mys-up-exception)
        (define-key map [(control c) (=)] 'mys-down-exception)
        (define-key map [(control x) (n) (d)] 'mys-narrow-to-def-or-class)
        ;; information
        (define-key map [(control c) (control b)] 'mys-submit-bug-report)
        (define-key map [(control c) (control v)] 'mys-version)
        (define-key map [(control c) (control w)] 'mys-pychecker-run)
        ;; (define-key map (kbd "TAB") 'mys-indent-line)
        (define-key map (kbd "TAB") 'mys-indent-or-complete)
	;; (if mys-complete-function
        ;;     (progn
        ;;       (define-key map [(meta tab)] mys-complete-function)
        ;;       (define-key map [(esc) (tab)] mys-complete-function))
        ;;   (define-key map [(meta tab)] 'mys-shell-complete)
        ;;   (define-key map [(esc) (tab)] 'mys-shell-complete))
        (substitute-key-definition 'complete-symbol 'completion-at-point
                                   map global-map)
        (substitute-key-definition 'backward-up-list 'mys-up
                                   map global-map)
        (substitute-key-definition 'down-list 'mys-down
                                   map global-map)
	(when mys-use-menu-p
	  (setq map (mys-define-menu map)))
        map))

(defvar mys-mys-shell-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'comint-send-input)
    (define-key map [(control c)(-)] 'mys-up-exception)
    (define-key map [(control c)(=)] 'mys-down-exception)
    (define-key map (kbd "TAB") 'mys-indent-or-complete)
    (define-key map [(meta tab)] 'mys-shell-complete)
    (define-key map [(control c)(!)] 'mys-shell)
    (define-key map [(control c)(control t)] 'mys-toggle-shell)
    ;; electric keys
    ;; (define-key map [(:)] 'mys-electric-colon)
    ;; (define-key map [(\#)] 'mys-electric-comment)
    ;; (define-key map [(delete)] 'mys-electric-delete)
    ;; (define-key map [(backspace)] 'mys-electric-backspace)
    ;; (define-key map [(control backspace)] 'mys-hungry-delete-backwards)
    ;; (define-key map [(control c) (delete)] 'mys-hungry-delete-forward)
    ;; (define-key map [(control y)] 'mys-electric-yank)
    ;; moving point
    (define-key map [(control c)(control p)] 'mys-backward-statement)
    (define-key map [(control c)(control n)] 'mys-forward-statement)
    (define-key map [(control c)(control u)] 'mys-backward-block)
    (define-key map [(control c)(control q)] 'mys-forward-block)
    (define-key map [(control meta a)] 'mys-backward-def-or-class)
    (define-key map [(control meta e)] 'mys-forward-def-or-class)
    (define-key map [(control j)] 'mys-newline-and-indent)
    (define-key map [(super backspace)] 'mys-dedent)
    ;; (define-key map [(control return)] 'mys-newline-and-dedent)
    ;; indentation level modifiers
    (define-key map [(control c)(control l)] 'comint-dynamic-list-input-ring)
    (define-key map [(control c)(control r)] 'comint-previous-prompt)
    (define-key map [(control c)(<)] 'mys-shift-left)
    (define-key map [(control c)(>)] 'mys-shift-right)
    (define-key map [(control c)(tab)] 'mys-indent-region)
    (define-key map [(control c)(:)] 'mys-guess-indent-offset)
    ;; subprocess commands
    (define-key map [(control meta h)] 'mys-mark-def-or-class)
    (define-key map [(control c)(control k)] 'mys-mark-block-or-clause)
    (define-key map [(control c)(.)] 'mys-expression)
    ;; Miscellaneous
    ;; (define-key map [(super q)] 'mys-comys-statement)
    (define-key map [(control c)(control d)] 'mys-pdbtrack-toggle-stack-tracking)
    (define-key map [(control c)(\#)] 'mys-comment-region)
    (define-key map [(control c)(\?)] 'mys-describe-mode)
    (define-key map [(control c)(control e)] 'mys-help-at-point)
    (define-key map [(control x) (n) (d)] 'mys-narrow-to-def-or-class)
    ;; information
    (define-key map [(control c)(control b)] 'mys-submit-bug-report)
    (define-key map [(control c)(control v)] 'mys-version)
    (define-key map [(control c)(control w)] 'mys-pychecker-run)
    (substitute-key-definition 'complete-symbol 'completion-at-point
			       map global-map)
    (substitute-key-definition 'backward-up-list 'mys-up
			       map global-map)
    (substitute-key-definition 'down-list 'mys-down
			       map global-map)
    map)
  "Used inside a Mys-shell.")

(defvar mys-imys-shell-mode-map mys-mys-shell-mode-map
  "Copy `mys-mys-shell-mode-map' here.")

(defvar mys-shell-map mys-mys-shell-mode-map)

;; mys-components-shell-menu

(and (ignore-errors (require 'easymenu) t)
     ;; (easy-menu-define mys-menu map "Python Tools"
     ;;           `("PyTools"
     (easy-menu-define
       mys-shell-menu mys-mys-shell-mode-map "Mys-Shell Mode menu"
       `("Mys-Shell"
         ("Edit"
          ("Shift"
           ("Shift right"
	    ["Shift block right" mys-shift-block-right
	     :help " `mys-shift-block-right'
Indent block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift block or clause right" mys-shift-block-or-clause-right
	     :help " `mys-shift-block-or-clause-right'
Indent block-or-clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift class right" mys-shift-class-right
	     :help " `mys-shift-class-right'
Indent class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift clause right" mys-shift-clause-right
	     :help " `mys-shift-clause-right'
Indent clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift comment right" mys-shift-comment-right
	     :help " `mys-shift-comment-right'"]

	    ["Shift def right" mys-shift-def-right
	     :help " `mys-shift-def-right'
Indent def by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift def or class right" mys-shift-def-or-class-right
	     :help " `mys-shift-def-or-class-right'
Indent def-or-class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift minor block right" mys-shift-minor-block-right
	     :help " `mys-shift-minor-block-right'
Indent minor-block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached.
A minor block is started by a `for', `if', `try' or `with'."]

	    ["Shift paragraph right" mys-shift-paragraph-right
	     :help " `mys-shift-paragraph-right'
Indent paragraph by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift region right" mys-shift-region-right
	     :help " `mys-shift-region-right'
Indent region according to `mys-indent-offset' by COUNT times.

If no region is active, current line is indented.
Returns indentation reached."]

	    ["Shift statement right" mys-shift-statement-right
	     :help " `mys-shift-statement-right'
Indent statement by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift top level right" mys-shift-top-level-right
	     :help " `mys-shift-top-level-right'"]
            )
           ("Shift left"
	    ["Shift block left" mys-shift-block-left
	     :help " `mys-shift-block-left'
Dedent block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift block or clause left" mys-shift-block-or-clause-left
	     :help " `mys-shift-block-or-clause-left'
Dedent block-or-clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift class left" mys-shift-class-left
	     :help " `mys-shift-class-left'
Dedent class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift clause left" mys-shift-clause-left
	     :help " `mys-shift-clause-left'
Dedent clause by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift comment left" mys-shift-comment-left
	     :help " `mys-shift-comment-left'"]

	    ["Shift def left" mys-shift-def-left
	     :help " `mys-shift-def-left'
Dedent def by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift def or class left" mys-shift-def-or-class-left
	     :help " `mys-shift-def-or-class-left'
Dedent def-or-class by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift minor block left" mys-shift-minor-block-left
	     :help " `mys-shift-minor-block-left'
Dedent minor-block by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached.
A minor block is started by a `for', `if', `try' or `with'."]

	    ["Shift paragraph left" mys-shift-paragraph-left
	     :help " `mys-shift-paragraph-left'
Dedent paragraph by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]

	    ["Shift region left" mys-shift-region-left
	     :help " `mys-shift-region-left'
Dedent region according to `mys-indent-offset' by COUNT times.

If no region is active, current line is dedented.
Returns indentation reached."]

	    ["Shift statement left" mys-shift-statement-left
	     :help " `mys-shift-statement-left'
Dedent statement by COUNT spaces.

COUNT defaults to `mys-indent-offset',
use [universal-argument] to specify a different value.

Returns outmost indentation reached."]
            ))
          ("Mark"
	   ["Mark block" mys-mark-block
	    :help " `mys-mark-block'
Mark block at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark block or clause" mys-mark-block-or-clause
	    :help " `mys-mark-block-or-clause'
Mark block-or-clause at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark class" mys-mark-class
	    :help " `mys-mark-class'
Mark class at point.

With C-u or `mys-mark-decorators' set to `t', decorators are marked too.
Returns beginning and end positions of marked area, a cons."]

	   ["Mark clause" mys-mark-clause
	    :help " `mys-mark-clause'
Mark clause at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark comment" mys-mark-comment
	    :help " `mys-mark-comment'
Mark comment at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark def" mys-mark-def
	    :help " `mys-mark-def'
Mark def at point.

With C-u or `mys-mark-decorators' set to `t', decorators are marked too.
Returns beginning and end positions of marked area, a cons."]

	   ["Mark def or class" mys-mark-def-or-class
	    :help " `mys-mark-def-or-class'
Mark def-or-class at point.

With C-u or `mys-mark-decorators' set to `t', decorators are marked too.
Returns beginning and end positions of marked area, a cons."]

	   ["Mark expression" mys-mark-expression
	    :help " `mys-mark-expression'
Mark expression at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark line" mys-mark-line
	    :help " `mys-mark-line'
Mark line at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark minor block" mys-mark-minor-block
	    :help " `mys-mark-minor-block'
Mark minor-block at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark paragraph" mys-mark-paragraph
	    :help " `mys-mark-paragraph'
Mark paragraph at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark partial expression" mys-mark-partial-expression
	    :help " `mys-mark-partial-expression'
Mark partial-expression at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark statement" mys-mark-statement
	    :help " `mys-mark-statement'
Mark statement at point.

Returns beginning and end positions of marked area, a cons."]

	   ["Mark top level" mys-mark-top-level
	    :help " `mys-mark-top-level'
Mark top-level at point.

Returns beginning and end positions of marked area, a cons."]
           )
          ("Copy"
	   ["Copy block" mys-comys-block
	    :help " `mys-comys-block'
Copy block at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy block or clause" mys-comys-block-or-clause
	    :help " `mys-comys-block-or-clause'
Copy block-or-clause at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy class" mys-comys-class
	    :help " `mys-comys-class'
Copy class at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy clause" mys-comys-clause
	    :help " `mys-comys-clause'
Copy clause at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy comment" mys-comys-comment
	    :help " `mys-comys-comment'"]

	   ["Copy def" mys-comys-def
	    :help " `mys-comys-def'
Copy def at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy def or class" mys-comys-def-or-class
	    :help " `mys-comys-def-or-class'
Copy def-or-class at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy expression" mys-comys-expression
	    :help " `mys-comys-expression'
Copy expression at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy line" mys-comys-line
	    :help " `mys-comys-line'"]

	   ["Copy minor block" mys-comys-minor-block
	    :help " `mys-comys-minor-block'
Copy minor-block at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy paragraph" mys-comys-paragraph
	    :help " `mys-comys-paragraph'"]

	   ["Copy partial expression" mys-comys-partial-expression
	    :help " `mys-comys-partial-expression'
Copy partial-expression at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy statement" mys-comys-statement
	    :help " `mys-comys-statement'
Copy statement at point.

Store data in kill ring, so it might yanked back."]

	   ["Copy top level" mys-comys-top-level
	    :help " `mys-comys-top-level'
Copy top-level at point.

Store data in kill ring, so it might yanked back."]
           )
          ("Kill"
	   ["Kill block" mys-kill-block
	    :help " `mys-kill-block'
Delete `block' at point.

Stores data in kill ring"]

	   ["Kill block or clause" mys-kill-block-or-clause
	    :help " `mys-kill-block-or-clause'
Delete `block-or-clause' at point.

Stores data in kill ring"]

	   ["Kill class" mys-kill-class
	    :help " `mys-kill-class'
Delete `class' at point.

Stores data in kill ring"]

	   ["Kill clause" mys-kill-clause
	    :help " `mys-kill-clause'
Delete `clause' at point.

Stores data in kill ring"]

	   ["Kill comment" mys-kill-comment
	    :help " `mys-kill-comment'"]

	   ["Kill def" mys-kill-def
	    :help " `mys-kill-def'
Delete `def' at point.

Stores data in kill ring"]

	   ["Kill def or class" mys-kill-def-or-class
	    :help " `mys-kill-def-or-class'
Delete `def-or-class' at point.

Stores data in kill ring"]

	   ["Kill expression" mys-kill-expression
	    :help " `mys-kill-expression'
Delete `expression' at point.

Stores data in kill ring"]

	   ["Kill line" mys-kill-line
	    :help " `mys-kill-line'"]

	   ["Kill minor block" mys-kill-minor-block
	    :help " `mys-kill-minor-block'
Delete `minor-block' at point.

Stores data in kill ring"]

	   ["Kill paragraph" mys-kill-paragraph
	    :help " `mys-kill-paragraph'"]

	   ["Kill partial expression" mys-kill-partial-expression
	    :help " `mys-kill-partial-expression'
Delete `partial-expression' at point.

Stores data in kill ring"]

	   ["Kill statement" mys-kill-statement
	    :help " `mys-kill-statement'
Delete `statement' at point.

Stores data in kill ring"]

	   ["Kill top level" mys-kill-top-level
	    :help " `mys-kill-top-level'
Delete `top-level' at point.

Stores data in kill ring"]
           )
          ("Delete"
	   ["Delete block" mys-delete-block
	    :help " `mys-delete-block'
Delete BLOCK at point.

Don't store data in kill ring."]

	   ["Delete block or clause" mys-delete-block-or-clause
	    :help " `mys-delete-block-or-clause'
Delete BLOCK-OR-CLAUSE at point.

Don't store data in kill ring."]

	   ["Delete class" mys-delete-class
	    :help " `mys-delete-class'
Delete CLASS at point.

Don't store data in kill ring.
With C-u or `mys-mark-decorators' set to `t', `decorators' are included."]

	   ["Delete clause" mys-delete-clause
	    :help " `mys-delete-clause'
Delete CLAUSE at point.

Don't store data in kill ring."]

	   ["Delete comment" mys-delete-comment
	    :help " `mys-delete-comment'"]

	   ["Delete def" mys-delete-def
	    :help " `mys-delete-def'
Delete DEF at point.

Don't store data in kill ring.
With C-u or `mys-mark-decorators' set to `t', `decorators' are included."]

	   ["Delete def or class" mys-delete-def-or-class
	    :help " `mys-delete-def-or-class'
Delete DEF-OR-CLASS at point.

Don't store data in kill ring.
With C-u or `mys-mark-decorators' set to `t', `decorators' are included."]

	   ["Delete expression" mys-delete-expression
	    :help " `mys-delete-expression'
Delete EXPRESSION at point.

Don't store data in kill ring."]

	   ["Delete line" mys-delete-line
	    :help " `mys-delete-line'"]

	   ["Delete minor block" mys-delete-minor-block
	    :help " `mys-delete-minor-block'
Delete MINOR-BLOCK at point.

Don't store data in kill ring."]

	   ["Delete paragraph" mys-delete-paragraph
	    :help " `mys-delete-paragraph'"]

	   ["Delete partial expression" mys-delete-partial-expression
	    :help " `mys-delete-partial-expression'
Delete PARTIAL-EXPRESSION at point.

Don't store data in kill ring."]

	   ["Delete statement" mys-delete-statement
	    :help " `mys-delete-statement'
Delete STATEMENT at point.

Don't store data in kill ring."]

	   ["Delete top level" mys-delete-top-level
	    :help " `mys-delete-top-level'
Delete TOP-LEVEL at point.

Don't store data in kill ring."]
           )
          ("Comment"
	   ["Comment block" mys-comment-block
	    :help " `mys-comment-block'
Comments block at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment block or clause" mys-comment-block-or-clause
	    :help " `mys-comment-block-or-clause'
Comments block-or-clause at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment class" mys-comment-class
	    :help " `mys-comment-class'
Comments class at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment clause" mys-comment-clause
	    :help " `mys-comment-clause'
Comments clause at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment def" mys-comment-def
	    :help " `mys-comment-def'
Comments def at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment def or class" mys-comment-def-or-class
	    :help " `mys-comment-def-or-class'
Comments def-or-class at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]

	   ["Comment statement" mys-comment-statement
	    :help " `mys-comment-statement'
Comments statement at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  `t',
the default"]
           ))
         ("Move"
          ("Backward"
	   ["Beginning of block" mys-beginning-of-block
	    :help " `mys-beginning-of-block'
Go to beginning block, skip whitespace at BOL.

Returns beginning of block if successful, nil otherwise"]

	   ["Beginning of block or clause" mys-beginning-of-block-or-clause
	    :help " `mys-beginning-of-block-or-clause'
Go to beginning block-or-clause, skip whitespace at BOL.

Returns beginning of block-or-clause if successful, nil otherwise"]

	   ["Beginning of class" mys-beginning-of-class
	    :help " `mys-beginning-of-class'
Go to beginning class, skip whitespace at BOL.

Returns beginning of class if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	   ["Beginning of clause" mys-beginning-of-clause
	    :help " `mys-beginning-of-clause'
Go to beginning clause, skip whitespace at BOL.

Returns beginning of clause if successful, nil otherwise"]

	   ["Beginning of def" mys-beginning-of-def
	    :help " `mys-beginning-of-def'
Go to beginning def, skip whitespace at BOL.

Returns beginning of def if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	   ["Beginning of def or class" mys-backward-def-or-class
	    :help " `mys-backward-def-or-class'
Go to beginning def-or-class, skip whitespace at BOL.

Returns beginning of def-or-class if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	   ["Beginning of elif block" mys-beginning-of-elif-block
	    :help " `mys-beginning-of-elif-block'
Go to beginning elif-block, skip whitespace at BOL.

Returns beginning of elif-block if successful, nil otherwise"]

	   ["Beginning of else block" mys-beginning-of-else-block
	    :help " `mys-beginning-of-else-block'
Go to beginning else-block, skip whitespace at BOL.

Returns beginning of else-block if successful, nil otherwise"]

	   ["Beginning of except block" mys-beginning-of-except-block
	    :help " `mys-beginning-of-except-block'
Go to beginning except-block, skip whitespace at BOL.

Returns beginning of except-block if successful, nil otherwise"]

	   ["Beginning of expression" mys-beginning-of-expression
	    :help " `mys-beginning-of-expression'
Go to the beginning of a compound python expression.

With numeric ARG do it that many times.

A a compound python expression might be concatenated by \".\" operator, thus composed by minor python expressions.

If already at the beginning or before a expression, go to next expression in buffer upwards

Expression here is conceived as the syntactical component of a statement in Python. See http://docs.python.org/reference
Operators however are left aside resp. limit mys-expression designed for edit-purposes."]

	   ["Beginning of if block" mys-beginning-of-if-block
	    :help " `mys-beginning-of-if-block'
Go to beginning if-block, skip whitespace at BOL.

Returns beginning of if-block if successful, nil otherwise"]

	   ["Beginning of partial expression" mys-backward-partial-expression
	    :help " `mys-backward-partial-expression'"]

	   ["Beginning of statement" mys-backward-statement
	    :help " `mys-backward-statement'
Go to the initial line of a simple statement.

For beginning of compound statement use mys-beginning-of-block.
For beginning of clause mys-beginning-of-clause."]

	   ["Beginning of top level" mys-backward-top-level
	    :help " `mys-backward-top-level'
Go up to beginning of statments until level of indentation is null.

Returns position if successful, nil otherwise"]

	   ["Beginning of try block" mys-beginning-of-try-block
	    :help " `mys-beginning-of-try-block'
Go to beginning try-block, skip whitespace at BOL.

Returns beginning of try-block if successful, nil otherwise"]
           )
          ("Forward"
	   ["End of block" mys-forward-block
	    :help " `mys-forward-block'
Go to end of block.

Returns end of block if successful, nil otherwise"]

	   ["End of block or clause" mys-forward-block-or-clause
	    :help " `mys-forward-block-or-clause'
Go to end of block-or-clause.

Returns end of block-or-clause if successful, nil otherwise"]

	   ["End of class" mys-forward-class
	    :help " `mys-forward-class'
Go to end of class.

Returns end of class if successful, nil otherwise"]

	   ["End of clause" mys-forward-clause
	    :help " `mys-forward-clause'
Go to end of clause.

Returns end of clause if successful, nil otherwise"]

	   ["End of def" mys-forward-def
	    :help " `mys-forward-def'
Go to end of def.

Returns end of def if successful, nil otherwise"]

	   ["End of def or class" mys-forward-def-or-class
	    :help " `mys-forward-def-or-class'
Go to end of def-or-class.

Returns end of def-or-class if successful, nil otherwise"]

	   ["End of elif block" mys-forward-elif-block
	    :help " `mys-forward-elif-block'
Go to end of elif-block.

Returns end of elif-block if successful, nil otherwise"]

	   ["End of else block" mys-forward-else-block
	    :help " `mys-forward-else-block'
Go to end of else-block.

Returns end of else-block if successful, nil otherwise"]

	   ["End of except block" mys-forward-except-block
	    :help " `mys-forward-except-block'
Go to end of except-block.

Returns end of except-block if successful, nil otherwise"]

	   ["End of expression" mys-forward-expression
	    :help " `mys-forward-expression'
Go to the end of a compound python expression.

With numeric ARG do it that many times.

A a compound python expression might be concatenated by \".\" operator, thus composed by minor python expressions.

Expression here is conceived as the syntactical component of a statement in Python. See http://docs.python.org/reference

Operators however are left aside resp. limit mys-expression designed for edit-purposes."]

	   ["End of if block" mys-forward-if-block
	    :help " `mys-forward-if-block'
Go to end of if-block.

Returns end of if-block if successful, nil otherwise"]

	   ["End of partial expression" mys-forward-partial-expression
	    :help " `mys-forward-partial-expression'"]

	   ["End of statement" mys-forward-statement
	    :help " `mys-forward-statement'
Go to the last char of current statement.

Optional argument REPEAT, the number of loops done already, is checked for mys-max-specpdl-size error. Avoid eternal loops due to missing string delimters etc."]

	   ["End of top level" mys-forward-top-level
	    :help " `mys-forward-top-level'
Go to end of top-level form at point.

Returns position if successful, nil otherwise"]

	   ["End of try block" mys-forward-try-block
	    :help " `mys-forward-try-block'
Go to end of try-block.

Returns end of try-block if successful, nil otherwise"]
           )
          ("BOL-forms"
           ("Backward"
	    ["Beginning of block bol" mys-beginning-of-block-bol
	     :help " `mys-beginning-of-block-bol'
Go to beginning block, go to BOL.

Returns beginning of block if successful, nil otherwise"]

	    ["Beginning of block or clause bol" mys-beginning-of-block-or-clause-bol
	     :help " `mys-beginning-of-block-or-clause-bol'
Go to beginning block-or-clause, go to BOL.

Returns beginning of block-or-clause if successful, nil otherwise"]

	    ["Beginning of class bol" mys-beginning-of-class-bol
	     :help " `mys-beginning-of-class-bol'
Go to beginning class, go to BOL.

Returns beginning of class if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	    ["Beginning of clause bol" mys-beginning-of-clause-bol
	     :help " `mys-beginning-of-clause-bol'
Go to beginning clause, go to BOL.

Returns beginning of clause if successful, nil otherwise"]

	    ["Beginning of def bol" mys-beginning-of-def-bol
	     :help " `mys-beginning-of-def-bol'
Go to beginning def, go to BOL.

Returns beginning of def if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	    ["Beginning of def or class bol" mys-backward-def-or-class-bol
	     :help " `mys-backward-def-or-class-bol'
Go to beginning def-or-class, go to BOL.

Returns beginning of def-or-class if successful, nil otherwise

When `mys-mark-decorators' is non-nil, decorators are considered too."]

	    ["Beginning of elif block bol" mys-beginning-of-elif-block-bol
	     :help " `mys-beginning-of-elif-block-bol'
Go to beginning elif-block, go to BOL.

Returns beginning of elif-block if successful, nil otherwise"]

	    ["Beginning of else block bol" mys-beginning-of-else-block-bol
	     :help " `mys-beginning-of-else-block-bol'
Go to beginning else-block, go to BOL.

Returns beginning of else-block if successful, nil otherwise"]

	    ["Beginning of except block bol" mys-beginning-of-except-block-bol
	     :help " `mys-beginning-of-except-block-bol'
Go to beginning except-block, go to BOL.

Returns beginning of except-block if successful, nil otherwise"]

	    ["Beginning of expression bol" mys-beginning-of-expression-bol
	     :help " `mys-beginning-of-expression-bol'"]

	    ["Beginning of if block bol" mys-beginning-of-if-block-bol
	     :help " `mys-beginning-of-if-block-bol'
Go to beginning if-block, go to BOL.

Returns beginning of if-block if successful, nil otherwise"]

	    ["Beginning of partial expression bol" mys-backward-partial-expression-bol
	     :help " `mys-backward-partial-expression-bol'"]

	    ["Beginning of statement bol" mys-backward-statement-bol
	     :help " `mys-backward-statement-bol'
Goto beginning of line where statement starts.
  Returns position reached, if successful, nil otherwise.

See also `mys-up-statement': up from current definition to next beginning of statement above."]

	    ["Beginning of try block bol" mys-beginning-of-try-block-bol
	     :help " `mys-beginning-of-try-block-bol'
Go to beginning try-block, go to BOL.

Returns beginning of try-block if successful, nil otherwise"]
            )
           ("Forward"
	    ["End of block bol" mys-forward-block-bol
	     :help " `mys-forward-block-bol'
Goto beginning of line following end of block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-block': down from current definition to next beginning of block below."]

	    ["End of block or clause bol" mys-forward-block-or-clause-bol
	     :help " `mys-forward-block-or-clause-bol'
Goto beginning of line following end of block-or-clause.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-block-or-clause': down from current definition to next beginning of block-or-clause below."]

	    ["End of class bol" mys-forward-class-bol
	     :help " `mys-forward-class-bol'
Goto beginning of line following end of class.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-class': down from current definition to next beginning of class below."]

	    ["End of clause bol" mys-forward-clause-bol
	     :help " `mys-forward-clause-bol'
Goto beginning of line following end of clause.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-clause': down from current definition to next beginning of clause below."]

	    ["End of def bol" mys-forward-def-bol
	     :help " `mys-forward-def-bol'
Goto beginning of line following end of def.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-def': down from current definition to next beginning of def below."]

	    ["End of def or class bol" mys-forward-def-or-class-bol
	     :help " `mys-forward-def-or-class-bol'
Goto beginning of line following end of def-or-class.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-def-or-class': down from current definition to next beginning of def-or-class below."]

	    ["End of elif block bol" mys-forward-elif-block-bol
	     :help " `mys-forward-elif-block-bol'
Goto beginning of line following end of elif-block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-elif-block': down from current definition to next beginning of elif-block below."]

	    ["End of else block bol" mys-forward-else-block-bol
	     :help " `mys-forward-else-block-bol'
Goto beginning of line following end of else-block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-else-block': down from current definition to next beginning of else-block below."]

	    ["End of except block bol" mys-forward-except-block-bol
	     :help " `mys-forward-except-block-bol'
Goto beginning of line following end of except-block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-except-block': down from current definition to next beginning of except-block below."]

	    ["End of expression bol" mys-forward-expression-bol
	     :help " `mys-forward-expression-bol'"]

	    ["End of if block bol" mys-forward-if-block-bol
	     :help " `mys-forward-if-block-bol'
Goto beginning of line following end of if-block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-if-block': down from current definition to next beginning of if-block below."]

	    ["End of partial expression bol" mys-forward-partial-expression-bol
	     :help " `mys-forward-partial-expression-bol'"]

	    ["End of statement bol" mys-forward-statement-bol
	     :help " `mys-forward-statement-bol'
Go to the beginning-of-line following current statement."]

	    ["End of top level bol" mys-forward-top-level-bol
	     :help " `mys-forward-top-level-bol'
Go to end of top-level form at point, stop at next beginning-of-line.

Returns position successful, nil otherwise"]

	    ["End of try block bol" mys-forward-try-block-bol
	     :help " `mys-forward-try-block-bol'
Goto beginning of line following end of try-block.
  Returns position reached, if successful, nil otherwise.

See also `mys-down-try-block': down from current definition to next beginning of try-block below."]
            ))
          ("Up/Down"
	   ["Up" mys-up
	    :help " `mys-up'
Go up or to beginning of form if inside.

If inside a delimited form --string or list-- go to its beginning.
If not at beginning of a statement or block, go to its beginning.
If at beginning of a statement or block, go to beginning one level above of compound statement or definition at point."]

	   ["Down" mys-down
	    :help " `mys-down'
Go to beginning one level below of compound statement or definition at point.

If no statement or block below, but a delimited form --string or list-- go to its beginning. Repeated call from there will behave like down-list.

Returns position if successful, nil otherwise"]
           ))
         ("Hide-Show"
          ("Hide"
	   ["Hide region" mys-hide-region
	    :help " `mys-hide-region'
Hide active region."]

	   ["Hide statement" mys-hide-statement
	    :help " `mys-hide-statement'
Hide statement at point."]

	   ["Hide block" mys-hide-block
	    :help " `mys-hide-block'
Hide block at point."]

	   ["Hide clause" mys-hide-clause
	    :help " `mys-hide-clause'
Hide clause at point."]

	   ["Hide block or clause" mys-hide-block-or-clause
	    :help " `mys-hide-block-or-clause'
Hide block-or-clause at point."]

	   ["Hide def" mys-hide-def
	    :help " `mys-hide-def'
Hide def at point."]

	   ["Hide class" mys-hide-class
	    :help " `mys-hide-class'
Hide class at point."]

	   ["Hide expression" mys-hide-expression
	    :help " `mys-hide-expression'
Hide expression at point."]

	   ["Hide partial expression" mys-hide-partial-expression
	    :help " `mys-hide-partial-expression'
Hide partial-expression at point."]

	   ["Hide line" mys-hide-line
	    :help " `mys-hide-line'
Hide line at point."]

	   ["Hide top level" mys-hide-top-level
	    :help " `mys-hide-top-level'
Hide top-level at point."]
           )
          ("Show"
	   ["Show" mys-show
	    :help " `mys-show'
Un-hide at point."]

	   ["Show all" mys-show-all
	    :help " `mys-show-all'
Un-hide all in buffer."]
           ))
         ("Virtualenv"
          ["Virtualenv activate" virtualenv-activate
	   :help " `virtualenv-activate'
Activate the virtualenv located in DIR"]

          ["Virtualenv deactivate" virtualenv-deactivate
	   :help " `virtualenv-deactivate'
Deactivate the current virtual enviroment"]

          ["Virtualenv p" virtualenv-p
	   :help " `virtualenv-p'
Check if a directory is a virtualenv"]

          ["Virtualenv workon" virtualenv-workon
	   :help " `virtualenv-workon'
Issue a virtualenvwrapper-like virtualenv-workon command"]
          )
         ("Help"
          ["Find definition" mys-find-definition
	   :help " `mys-find-definition'
Find source of definition of SYMBOL.

Interactively, prompt for SYMBOL."]

          ["Help at point" mys-help-at-point
	   :help " `mys-help-at-point'
Print help on symbol at point.

If symbol is defined in current buffer, jump to it's definition
Optional C-u used for debugging, will prevent deletion of temp file."]

          ["Info lookup symbol" mys-info-lookup-symbol
	   :help " `mys-info-lookup-symbol'"]

          ["Symbol at point" mys-symbol-at-point
	   :help " `mys-symbol-at-point'
Return the current Python symbol."]
          )
         ("Customize"

	  ["Mys-mode customize group" (customize-group 'mys-mode)
	   :help "Open the customization buffer for Python mode"]
	  ("Switches"
	   :help "Toggle useful modes"
	   ("Interpreter"

	    ["Shell prompt read only"
	     (setq mys-shell-prompt-read-only
		   (not mys-shell-prompt-read-only))
	     :help "If non-nil, the python prompt is read only.  Setting this variable will only effect new shells.Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-shell-prompt-read-only]

	    ["Remove cwd from path"
	     (setq mys-remove-cwd-from-path
		   (not mys-remove-cwd-from-path))
	     :help "Whether to allow loading of Python modules from the current directory.
If this is non-nil, Emacs removes '' from sys.path when starting
a Python process.  This is the default, for security
reasons, as it is easy for the Python process to be started
without the user's realization (e.g. to perform completion).Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-remove-cwd-from-path]

	    ["Honor IMYSDIR "
	     (setq mys-honor-IMYSDIR-p
		   (not mys-honor-IMYSDIR-p))
	     :help "When non-nil imys-history file is constructed by \$IMYSDIR
followed by "/history". Default is nil.

Otherwise value of mys-imys-history is used. Use `M-x customize-variable' to set it permanently"
:style toggle :selected mys-honor-IMYSDIR-p]

	    ["Honor PYTHONHISTORY "
	     (setq mys-honor-PYTHONHISTORY-p
		   (not mys-honor-PYTHONHISTORY-p))
	     :help "When non-nil mys-history file is set by \$PYTHONHISTORY
Default is nil.

Otherwise value of mys-mys-history is used. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-honor-PYTHONHISTORY-p]

	    ["Enforce mys-shell-name" force-mys-shell-name-p-on
	     :help "Enforce customized default `mys-shell-name' should upon execution. "]

	    ["Don't enforce default interpreter" force-mys-shell-name-p-off
	     :help "Make execute commands guess interpreter from environment"]

	    )

	   ("Execute"

	    ["Fast process" mys-fast-process-p
	     :help " `mys-fast-process-p'

Use `mys-fast-process'\.

Commands prefixed \"mys-fast-...\" suitable for large output

See: large output makes Emacs freeze, lp:1253907

Output-buffer is not in comint-mode"
	     :style toggle :selected mys-fast-process-p]

	    ["Python mode v5 behavior"
	     (setq mys-mode-v5-behavior-p
		   (not mys-mode-v5-behavior-p))
	     :help "Execute region through `shell-command-on-region' as
v5 did it - lp:990079. This might fail with certain chars - see UnicodeEncodeError lp:550661

Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-mode-v5-behavior-p]

	    ["Force shell name "
	     (setq mys-force-mys-shell-name-p
		   (not mys-force-mys-shell-name-p))
	     :help "When `t', execution with kind of Python specified in `mys-shell-name' is enforced, possibly shebang doesn't take precedence. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-force-mys-shell-name-p]

	    ["Execute \"if name == main\" blocks p"
	     (setq mys-if-name-main-permission-p
		   (not mys-if-name-main-permission-p))
	     :help " `mys-if-name-main-permission-p'

Allow execution of code inside blocks delimited by
if __name__ == '__main__'

Default is non-nil. "
	     :style toggle :selected mys-if-name-main-permission-p]

	    ["Ask about save"
	     (setq mys-ask-about-save
		   (not mys-ask-about-save))
	     :help "If not nil, ask about which buffers to save before executing some code.
Otherwise, all modified buffers are saved without asking.Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-ask-about-save]

	    ["Store result"
	     (setq mys-store-result-p
		   (not mys-store-result-p))
	     :help " `mys-store-result-p'

When non-nil, put resulting string of `mys-execute-...' into kill-ring, so it might be yanked. "
	     :style toggle :selected mys-store-result-p]

	    ["Prompt on changed "
	     (setq mys-prompt-on-changed-p
		   (not mys-prompt-on-changed-p))
	     :help "When called interactively, ask for save before a changed buffer is sent to interpreter.

Default is `t'Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-prompt-on-changed-p]

	    ["Dedicated process "
	     (setq mys-dedicated-process-p
		   (not mys-dedicated-process-p))
	     :help "If commands executing code use a dedicated shell.

Default is nilUse `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-dedicated-process-p]

	    ["Execute without temporary file"
	     (setq mys-execute-no-temp-p
		   (not mys-execute-no-temp-p))
	     :help " `mys-execute-no-temp-p'
Seems Emacs-24.3 provided a way executing stuff without temporary files.
In experimental state yet "
	     :style toggle :selected mys-execute-no-temp-p]

	    ["Warn tmp files left "
	     (setq mys--warn-tmp-files-left-p
		   (not mys--warn-tmp-files-left-p))
	     :help "Messages a warning, when `mys-temp-directory' contains files susceptible being left by previous Mys-mode sessions. See also lp:987534 Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys--warn-tmp-files-left-p])

	   ("Edit"

	    ("Completion"

	     ["Set Pymacs-based complete keymap "
	      (setq mys-set-complete-keymap-p
		    (not mys-set-complete-keymap-p))
	      :help "If `mys-complete-initialize', which sets up enviroment for Pymacs based mys-complete, should load it's keys into `mys-mode-map'

Default is nil.
See also resp. edit `mys-complete-set-keymap' Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-set-complete-keymap-p]

	     ["Indent no completion "
	      (setq mys-indent-no-completion-p
		    (not mys-indent-no-completion-p))
	      :help "If completion function should indent when no completion found. Default is `t'

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-indent-no-completion-p]

	     ["Company pycomplete "
	      (setq mys-company-pycomplete-p
		    (not mys-company-pycomplete-p))
	      :help "Load company-pycomplete stuff. Default is nilUse `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-company-pycomplete-p])

	    ("Filling"

	     ("Docstring styles"
	      :help "Switch docstring-style"

	      ["Nil" mys-set-nil-docstring-style
	       :help " `mys-set-nil-docstring-style'

Set mys-docstring-style to nil, format string normally. "]

	      ["pep-257-nn" mys-set-pep-257-nn-docstring-style
	       :help " `mys-set-pep-257-nn-docstring-style'

Set mys-docstring-style to 'pep-257-nn "]

	      ["pep-257" mys-set-pep-257-docstring-style
	       :help " `mys-set-pep-257-docstring-style'

Set mys-docstring-style to 'pep-257 "]

	      ["django" mys-set-django-docstring-style
	       :help " `mys-set-django-docstring-style'

Set mys-docstring-style to 'django "]

	      ["onetwo" mys-set-onetwo-docstring-style
	       :help " `mys-set-onetwo-docstring-style'

Set mys-docstring-style to 'onetwo "]

	      ["symmetric" mys-set-symmetric-docstring-style
	       :help " `mys-set-symmetric-docstring-style'

Set mys-docstring-style to 'symmetric "])

	     ["Auto-fill mode"
	      (setq mys-auto-fill-mode
		    (not mys-auto-fill-mode))
	      :help "Fill according to `mys-docstring-fill-column' and `mys-comment-fill-column'

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-auto-fill-mode])

	    ["Use current dir when execute"
	     (setq mys-use-current-dir-when-execute-p
		   (not mys-use-current-dir-when-execute-p))
	     :help " `mys-toggle-use-current-dir-when-execute-p'

Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-use-current-dir-when-execute-p]

	    ("Indent"
	     ("TAB related"

	      ["indent-tabs-mode"
	       (setq indent-tabs-mode
		     (not indent-tabs-mode))
	       :help "Indentation can insert tabs if this is non-nil.

Use `M-x customize-variable' to set it permanently"
	       :style toggle :selected indent-tabs-mode]

	      ["Tab indent"
	       (setq mys-tab-indent
		     (not mys-tab-indent))
	       :help "Non-nil means TAB in Python mode calls `mys-indent-line'.Use `M-x customize-variable' to set it permanently"
	       :style toggle :selected mys-tab-indent]

	      ["Tab shifts region "
	       (setq mys-tab-shifts-region-p
		     (not mys-tab-shifts-region-p))
	       :help "If `t', TAB will indent/cycle the region, not just the current line.

Default is nil
See also `mys-tab-indents-region-p'

Use `M-x customize-variable' to set it permanently"
	       :style toggle :selected mys-tab-shifts-region-p]

	      ["Tab indents region "
	       (setq mys-tab-indents-region-p
		     (not mys-tab-indents-region-p))
	       :help "When `t' and first TAB doesn't shift, indent-region is called.

Default is nil
See also `mys-tab-shifts-region-p'

Use `M-x customize-variable' to set it permanently"
	       :style toggle :selected mys-tab-indents-region-p])

	     ["Close at start column"
	      (setq mys-closing-list-dedents-bos
		    (not mys-closing-list-dedents-bos))
	      :help "When non-nil, indent list's closing delimiter like start-column.

It will be lined up under the first character of
 the line that starts the multi-line construct, as in:

my_list = \[
    1, 2, 3,
    4, 5, 6,
]

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-closing-list-dedents-bos]

	     ["Closing list keeps space"
	      (setq mys-closing-list-keeps-space
		    (not mys-closing-list-keeps-space))
	      :help "If non-nil, closing parenthesis dedents onto column of opening plus `mys-closing-list-space', default is nil Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-closing-list-keeps-space]

	     ["Closing list space"
	      (setq mys-closing-list-space
		    (not mys-closing-list-space))
	      :help "Number of chars, closing parenthesis outdent from opening, default is 1 Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-closing-list-space]

	     ["Tab shifts region "
	      (setq mys-tab-shifts-region-p
		    (not mys-tab-shifts-region-p))
	      :help "If `t', TAB will indent/cycle the region, not just the current line.

Default is nil
See also `mys-tab-indents-region-p'Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-tab-shifts-region-p]

	     ["Lhs inbound indent"
	      (setq mys-lhs-inbound-indent
		    (not mys-lhs-inbound-indent))
	      :help "When line starts a multiline-assignment: How many colums indent should be more than opening bracket, brace or parenthesis. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-lhs-inbound-indent]

	     ["Continuation offset"
	      (setq mys-continuation-offset
		    (not mys-continuation-offset))
	      :help "With numeric ARG different from 1 mys-continuation-offset is set to that value; returns mys-continuation-offset. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-continuation-offset]

	     ["Electric colon"
	      (setq mys-electric-colon-active-p
		    (not mys-electric-colon-active-p))
	      :help " `mys-electric-colon-active-p'

`mys-electric-colon' feature.  Default is `nil'. See lp:837065 for discussions. "
	      :style toggle :selected mys-electric-colon-active-p]

	     ["Electric colon at beginning of block only"
	      (setq mys-electric-colon-bobl-only
		    (not mys-electric-colon-bobl-only))
	      :help "When inserting a colon, do not indent lines unless at beginning of block.

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-electric-colon-bobl-only]

	     ["Electric yank active "
	      (setq mys-electric-yank-active-p
		    (not mys-electric-yank-active-p))
	      :help " When non-nil, `yank' will be followed by an `indent-according-to-mode'.

Default is nilUse `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-electric-yank-active-p]

	     ["Trailing whitespace smart delete "
	      (setq mys-trailing-whitespace-smart-delete-p
		    (not mys-trailing-whitespace-smart-delete-p))
	      :help "Default is nil. When t, mys-mode calls
    (add-hook 'before-save-hook 'delete-trailing-whitespace nil 'local)

Also commands may delete trailing whitespace by the way.
When editing other peoples code, this may produce a larger diff than expected Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-trailing-whitespace-smart-delete-p]

	     ["Newline delete trailing whitespace "
	      (setq mys-newline-delete-trailing-whitespace-p
		    (not mys-newline-delete-trailing-whitespace-p))
	      :help "Delete trailing whitespace maybe left by `mys-newline-and-indent'.

Default is `t'. See lp:1100892 Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-newline-delete-trailing-whitespace-p]

	     ["Dedent keep relative column"
	      (setq mys-dedent-keep-relative-column
		    (not mys-dedent-keep-relative-column))
	      :help "If point should follow dedent or kind of electric move to end of line. Default is t - keep relative position. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-dedent-keep-relative-column]

;; 	     ["Indent paren spanned multilines "
;; 	      (setq mys-indent-paren-spanned-multilines-p
;; 		    (not mys-indent-paren-spanned-multilines-p))
;; 	      :help "If non-nil, indents elements of list a value of `mys-indent-offset' to first element:

;; def foo():
;;     if (foo &&
;;             baz):
;;         bar()

;; Default lines up with first element:

;; def foo():
;;     if (foo &&
;;         baz):
;;         bar()
;; Use `M-x customize-variable' to set it permanently"
;; 	      :style toggle :selected mys-indent-paren-spanned-multilines-p]

	     ;; ["Indent honors multiline listing"
	     ;;  (setq mys-indent-honors-multiline-listing
	     ;; 	    (not mys-indent-honors-multiline-listing))
	     ;;  :help "If `t', indents to 1\+ column of opening delimiter. If `nil', indent adds one level to the beginning of statement. Default is `nil'. Use `M-x customize-variable' to set it permanently"
	     ;;  :style toggle :selected mys-indent-honors-multiline-listing]

	     ["Indent comment "
	      (setq mys-indent-comments
		    (not mys-indent-comments))
	      :help "If comments should be indented like code. Default is `nil'.

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-indent-comments]

	     ["Uncomment indents "
	      (setq mys-uncomment-indents-p
		    (not mys-uncomment-indents-p))
	      :help "When non-nil, after uncomment indent lines. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-uncomment-indents-p]

	     ["Indent honors inline comment"
	      (setq mys-indent-honors-inline-comment
		    (not mys-indent-honors-inline-comment))
	      :help "If non-nil, indents to column of inlined comment start.
Default is nil. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-indent-honors-inline-comment]

	     ["Kill empty line"
	      (setq mys-kill-empty-line
		    (not mys-kill-empty-line))
	      :help "If t, mys-indent-forward-line kills empty lines. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-kill-empty-line]

	     ("Smart indentation"
	      :help "Toggle mys-smart-indentation'

Use `M-x customize-variable' to set it permanently"

	      ["Toggle mys-smart-indentation" mys-toggle-smart-indentation
	       :help "Toggles mys-smart-indentation

Use `M-x customize-variable' to set it permanently"]

	      ["mys-smart-indentation on" mys-smart-indentation-on
	       :help "Switches mys-smart-indentation on

Use `M-x customize-variable' to set it permanently"]

	      ["mys-smart-indentation off" mys-smart-indentation-off
	       :help "Switches mys-smart-indentation off

Use `M-x customize-variable' to set it permanently"])

	     ["Beep if tab change"
	      (setq mys-beep-if-tab-change
		    (not mys-beep-if-tab-change))
	      :help "Ring the bell if `tab-width' is changed.
If a comment of the form

                           	# vi:set tabsize=<number>:

is found before the first code line when the file is entered, and the
current value of (the general Emacs variable) `tab-width' does not
equal <number>, `tab-width' is set to <number>, a message saying so is
displayed in the echo area, and if `mys-beep-if-tab-change' is non-nil
the Emacs bell is also rung as a warning.Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-beep-if-tab-change]

	     ["Electric comment "
	      (setq mys-electric-comment-p
		    (not mys-electric-comment-p))
	      :help "If \"#\" should call `mys-electric-comment'. Default is `nil'.

Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-electric-comment-p]

	     ["Electric comment add space "
	      (setq mys-electric-comment-add-space-p
		    (not mys-electric-comment-add-space-p))
	      :help "If mys-electric-comment should add a space.  Default is `nil'. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-electric-comment-add-space-p]

	     ["Empty line closes "
	      (setq mys-empty-line-closes-p
		    (not mys-empty-line-closes-p))
	      :help "When non-nil, dedent after empty line following block

if True:
    print(\"Part of the if-statement\")

print(\"Not part of the if-statement\")

Default is nil

If non-nil, a C-j from empty line dedents.
Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-empty-line-closes-p])
	    ["Defun use top level "
	     (setq mys-defun-use-top-level-p
		   (not mys-defun-use-top-level-p))
	     :help "When non-nil, keys C-M-a, C-M-e address top-level form.

Beginning- end-of-defun forms use
commands `mys-backward-top-level', `mys-forward-top-level'

mark-defun marks top-level form at point etc. "
	     :style toggle :selected mys-defun-use-top-level-p]

	    ["Close provides newline"
	     (setq mys-close-provides-newline
		   (not mys-close-provides-newline))
	     :help "If a newline is inserted, when line after block isn't empty. Default is non-nil. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-close-provides-newline]

	    ["Block comment prefix "
	     (setq mys-block-comment-prefix-p
		   (not mys-block-comment-prefix-p))
	     :help "If mys-comment inserts mys-block-comment-prefix.

Default is tUse `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-block-comment-prefix-p])

	   ("Display"

	    ("Index"

	     ["Imenu create index "
	      (setq mys--imenu-create-index-p
		    (not mys--imenu-create-index-p))
	      :help "Non-nil means Python mode creates and displays an index menu of functions and global variables. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys--imenu-create-index-p]

	     ["Imenu show method args "
	      (setq mys-imenu-show-method-args-p
		    (not mys-imenu-show-method-args-p))
	      :help "Controls echoing of arguments of functions & methods in the Imenu buffer.
When non-nil, arguments are printed.Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-imenu-show-method-args-p]
	     ["Switch index-function" mys-switch-imenu-index-function
	      :help "`mys-switch-imenu-index-function'
Switch between `mys--imenu-create-index' from 5.1 series and `mys--imenu-create-index-new'."])

	    ("Fontification"

	     ["Mark decorators"
	      (setq mys-mark-decorators
		    (not mys-mark-decorators))
	      :help "If mys-mark-def-or-class functions should mark decorators too. Default is `nil'. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-mark-decorators]

	     ["Fontify shell buffer "
	      (setq mys-fontify-shell-buffer-p
		    (not mys-fontify-shell-buffer-p))
	      :help "If code in Python shell should be highlighted as in script buffer.

Default is nil.

If `t', related vars like `comment-start' will be set too.
Seems convenient when playing with stuff in Imys shell
Might not be TRT when a lot of output arrives Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-fontify-shell-buffer-p]

	     ["Use font lock doc face "
	      (setq mys-use-font-lock-doc-face-p
		    (not mys-use-font-lock-doc-face-p))
	      :help "If documention string inside of def or class get `font-lock-doc-face'.

`font-lock-doc-face' inherits `font-lock-string-face'.

Call M-x `customize-face' in order to have a visible effect. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-use-font-lock-doc-face-p])

	    ["Switch buffers on execute"
	     (setq mys-switch-buffers-on-execute-p
		   (not mys-switch-buffers-on-execute-p))
	     :help "When non-nil switch to the Python output buffer.

Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-switch-buffers-on-execute-p]

	    ["Split windows on execute"
	     (setq mys-split-window-on-execute
		   (not mys-split-window-on-execute))
	     :help "When non-nil split windows.

Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-split-window-on-execute]

	    ["Keep windows configuration"
	     (setq mys-keep-windows-configuration
		   (not mys-keep-windows-configuration))
	     :help "If a windows is splitted displaying results, this is directed by variable `mys-split-window-on-execute'\. Also setting `mys-switch-buffers-on-execute-p' affects window-configuration\. While commonly a screen splitted into source and Mys-shell buffer is assumed, user may want to keep a different config\.

Setting `mys-keep-windows-configuration' to `t' will restore windows-config regardless of settings mentioned above\. However, if an error occurs, it's displayed\.

To suppres window-changes due to error-signaling also: M-x customize-variable RET. Set `mys-keep-4windows-configuration' onto 'force

Default is nil Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-keep-windows-configuration]

	    ["Which split windows on execute function"
	     (progn
	       (if (eq 'split-window-vertically mys-split-windows-on-execute-function)
		   (setq mys-split-windows-on-execute-function'split-window-horizontally)
		 (setq mys-split-windows-on-execute-function 'split-window-vertically))
	       (message "mys-split-windows-on-execute-function set to: %s" mys-split-windows-on-execute-function))

	     :help "If `split-window-vertically' or `...-horizontally'. Use `M-x customize-variable' RET `mys-split-windows-on-execute-function' RET to set it permanently"
	     :style toggle :selected mys-split-windows-on-execute-function]

	    ["Modeline display full path "
	     (setq mys-modeline-display-full-path-p
		   (not mys-modeline-display-full-path-p))
	     :help "If the full PATH/TO/PYTHON should be displayed in shell modeline.

Default is nil. Note: when `mys-shell-name' is specified with path, it's shown as an acronym in buffer-name already. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-modeline-display-full-path-p]

	    ["Modeline acronym display home "
	     (setq mys-modeline-acronym-display-home-p
		   (not mys-modeline-acronym-display-home-p))
	     :help "If the modeline acronym should contain chars indicating the home-directory.

Default is nil Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-modeline-acronym-display-home-p]

	    ["Hide show hide docstrings"
	     (setq mys-hide-show-hide-docstrings
		   (not mys-hide-show-hide-docstrings))
	     :help "Controls if doc strings can be hidden by hide-showUse `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-hide-show-hide-docstrings]

	    ["Hide comments when hiding all"
	     (setq mys-hide-comments-when-hiding-all
		   (not mys-hide-comments-when-hiding-all))
	     :help "Hide the comments too when you do `hs-hide-all'. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-hide-comments-when-hiding-all]

	    ["Max help buffer "
	     (setq mys-max-help-buffer-p
		   (not mys-max-help-buffer-p))
	     :help "If \"\*Mys-Help\*\"-buffer should appear as the only visible.

Default is nil. In help-buffer, \"q\" will close it.  Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-max-help-buffer-p]

	    ["Current defun show"
	     (setq mys-current-defun-show
		   (not mys-current-defun-show))
	     :help "If `mys-current-defun' should jump to the definition, highlight it while waiting MYS-WHICH-FUNC-DELAY seconds, before returning to previous position.

Default is `t'.Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-current-defun-show]

	    ["Match paren mode"
	     (setq mys-match-paren-mode
		   (not mys-match-paren-mode))
	     :help "Non-nil means, cursor will jump to beginning or end of a block.
This vice versa, to beginning first.
Sets `mys-match-paren-key' in mys-mode-map.
Customize `mys-match-paren-key' which key to use. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-match-paren-mode])

	   ("Debug"

	    ["mys-debug-p"
	     (setq mys-debug-p
		   (not mys-debug-p))
	     :help "When non-nil, keep resp\. store information useful for debugging\.

Temporary files are not deleted\. Other functions might implement
some logging etc\. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-debug-p]

	    ["Pdbtrack do tracking "
	     (setq mys-pdbtrack-do-tracking-p
		   (not mys-pdbtrack-do-tracking-p))
	     :help "Controls whether the pdbtrack feature is enabled or not.
When non-nil, pdbtrack is enabled in all comint-based buffers,
e.g. shell buffers and the \*Python\* buffer.  When using pdb to debug a
Python program, pdbtrack notices the pdb prompt and displays the
source file and line that the program is stopped at, much the same way
as gud-mode does for debugging C programs with gdb.Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-pdbtrack-do-tracking-p]

	    ["Jump on exception"
	     (setq mys-jump-on-exception
		   (not mys-jump-on-exception))
	     :help "Jump to innermost exception frame in Python output buffer.
When this variable is non-nil and an exception occurs when running
Python code synchronously in a subprocess, jump immediately to the
source code of the innermost traceback frame.

Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-jump-on-exception]

	    ["Highlight error in source "
	     (setq mys-highlight-error-source-p
		   (not mys-highlight-error-source-p))
	     :help "Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-highlight-error-source-p])

	   ("Other"

	    ("Directory"

	     ["Guess install directory "
	      (setq mys-guess-mys-install-directory-p
		    (not mys-guess-mys-install-directory-p))
	      :help "If in cases, `mys-install-directory' isn't set,  `mys-set-load-path'should guess it from `buffer-file-name'. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-guess-mys-install-directory-p]

	     ["Use local default"
	      (setq mys-use-local-default
		    (not mys-use-local-default))
	      :help "If `t', mys-shell will use `mys-shell-local-path' instead
of default Python.

Making switch between several virtualenv's easier,
                               `mys-mode' should deliver an installer, so named-shells pointing to virtualenv's will be available. Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-use-local-default]

	     ["Use current dir when execute "
	      (setq mys-use-current-dir-when-execute-p
		    (not mys-use-current-dir-when-execute-p))
	      :help "When `t', current directory is used by Mys-shell for output of `mys-execute-buffer' and related commands.

See also `mys-execute-directory'Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-use-current-dir-when-execute-p]

	     ["Keep shell dir when execute "
	      (setq mys-keep-shell-dir-when-execute-p
		    (not mys-keep-shell-dir-when-execute-p))
	      :help "Don't change Python shell's current working directory when sending code.

See also `mys-execute-directory'Use `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-keep-shell-dir-when-execute-p]

	     ["Fileless buffer use default directory "
	      (setq mys-fileless-buffer-use-default-directory-p
		    (not mys-fileless-buffer-use-default-directory-p))
	      :help "When `mys-use-current-dir-when-execute-p' is non-nil and no buffer-file exists, value of `default-directory' sets current working directory of Python output shellUse `M-x customize-variable' to set it permanently"
	      :style toggle :selected mys-fileless-buffer-use-default-directory-p])

	    ("Underscore word syntax"
	     :help "Toggle `mys-underscore-word-syntax-p'"

	     ["Toggle underscore word syntax" mys-toggle-underscore-word-syntax-p
	      :help " `mys-toggle-underscore-word-syntax-p'

If `mys-underscore-word-syntax-p' should be on or off.

  Returns value of `mys-underscore-word-syntax-p' switched to. .

Use `M-x customize-variable' to set it permanently"]

	     ["Underscore word syntax on" mys-underscore-word-syntax-p-on
	      :help " `mys-underscore-word-syntax-p-on'

Make sure, mys-underscore-word-syntax-p' is on.

Returns value of `mys-underscore-word-syntax-p'. .

Use `M-x customize-variable' to set it permanently"]

	     ["Underscore word syntax off" mys-underscore-word-syntax-p-off
	      :help " `mys-underscore-word-syntax-p-off'

Make sure, `mys-underscore-word-syntax-p' is off.

Returns value of `mys-underscore-word-syntax-p'. .

Use `M-x customize-variable' to set it permanently"])

	    ["Load pymacs "
	     (setq mys-load-pymacs-p
		   (not mys-load-pymacs-p))
	     :help "If Pymacs related stuff should be loaded.

Default is nil.

Pymacs has been written by François Pinard and many others.
See original source: http://pymacs.progiciels-bpi.caUse `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-load-pymacs-p]

	    ["Verbose "
	     (setq mys-verbose-p
		   (not mys-verbose-p))
	     :help "If functions should report results.

Default is nil. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-verbose-p]

	    ["Empty comment line separates paragraph "
	     (setq mys-empty-comment-line-separates-paragraph-p
		   (not mys-empty-comment-line-separates-paragraph-p))
	     :help "Consider paragraph start/end lines with nothing inside but comment sign.

Default is non-nilUse `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-empty-comment-line-separates-paragraph-p]

	    ["Org cycle "
	     (setq mys-org-cycle-p
		   (not mys-org-cycle-p))
	     :help "When non-nil, command `org-cycle' is available at shift-TAB, <backtab>

Default is nil. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-org-cycle-p]

	    ["Set pager cat"
	     (setq mys-set-pager-cat-p
		   (not mys-set-pager-cat-p))
	     :help "If the shell environment variable \$PAGER should set to `cat'.

If `t', use `C-c C-r' to jump to beginning of output. Then scroll normally.

Avoids lp:783828, \"Terminal not fully functional\", for help('COMMAND') in mys-shell

When non-nil, imports module `os' Use `M-x customize-variable' to
set it permanently"
	     :style toggle :selected mys-set-pager-cat-p]

	    ["Edit only "
	     (setq mys-edit-only-p
		   (not mys-edit-only-p))
	     :help "When `t' `mys-mode' will not take resort nor check for installed Python executables. Default is nil.

See bug report at launchpad, lp:944093. Use `M-x customize-variable' to set it permanently"
	     :style toggle :selected mys-edit-only-p])))
         ("Other"
          ["Boolswitch" mys-boolswitch
	   :help " `mys-boolswitch'
Edit the assignment of a boolean variable, revert them.

I.e. switch it from \"True\" to \"False\" and vice versa"]

          ["Empty out list backward" mys-empty-out-list-backward
	   :help " `mys-empty-out-list-backward'
Deletes all elements from list before point."]

          ["Kill buffer unconditional" mys-kill-buffer-unconditional
	   :help " `mys-kill-buffer-unconditional'
Kill buffer unconditional, kill buffer-process if existing."]

          ["Remove overlays at point" mys-remove-overlays-at-point
	   :help " `mys-remove-overlays-at-point'
Remove overlays as set when `mys-highlight-error-source-p' is non-nil."]
          ("Electric"
	   ["Complete electric comma" mys-complete-electric-comma
	    :help " `mys-complete-electric-comma'"]

	   ["Complete electric lparen" mys-complete-electric-lparen
	    :help " `mys-complete-electric-lparen'"]

	   ["Electric backspace" mys-electric-backspace
	    :help " `mys-electric-backspace'
Delete preceding character or level of indentation.

With ARG do that ARG times.
Returns column reached."]

	   ["Electric colon" mys-electric-colon
	    :help " `mys-electric-colon'
Insert a colon and indent accordingly.

If a numeric argument ARG is provided, that many colons are inserted
non-electrically.

Electric behavior is inhibited inside a string or
comment or by universal prefix C-u.

Switched by `mys-electric-colon-active-p', default is nil
See also `mys-electric-colon-greedy-p'"]

	   ["Electric comment" mys-electric-comment
	    :help " `mys-electric-comment'
Insert a comment. If starting a comment, indent accordingly.

If a numeric argument ARG is provided, that many \"#\" are inserted
non-electrically.
With C-u \"#\" electric behavior is inhibited inside a string or comment."]

	   ["Electric delete" mys-electric-delete
	    :help " `mys-electric-delete'
Delete following character or levels of whitespace.

With ARG do that ARG times."]

	   ["Electric yank" mys-electric-yank
	    :help " `mys-electric-yank'
Perform command `yank' followed by an `indent-according-to-mode'"]

	   ["Hungry delete backwards" mys-hungry-delete-backwards
	    :help " `mys-hungry-delete-backwards'
Delete the preceding character or all preceding whitespace
back to the previous non-whitespace character.
See also C-c <delete>."]

	   ["Hungry delete forward" mys-hungry-delete-forward
	    :help " `mys-hungry-delete-forward'
Delete the following character or all following whitespace
up to the next non-whitespace character.
See also C-c <C-backspace>."]
            )
          ("Abbrevs"	   :help "see also `mys-add-abbrev'"
	   :filter (lambda (&rest junk)
		     (abbrev-table-menu mys-mode-abbrev-table))            )

          ["Add abbrev" mys-add-abbrev
	   :help " `mys-add-abbrev'
Defines mys-mode specific abbrev for last expressions before point.
Argument is how many `mys-partial-expression's form the expansion; or zero means the region is the expansion.

Reads the abbreviation in the minibuffer; with numeric arg it displays a proposal for an abbrev.
Proposal is composed from the initial character(s) of the
expansion.

Don't use this function in a Lisp program; use `define-abbrev' instead."]
          ("Completion"
	   ["Py indent or complete" mys-indent-or-complete
	    :help " `mys-indent-or-complete'"]

	   ["Py shell complete" mys-shell-complete
	    :help " `mys-shell-complete'"]

	   ["Py complete" mys-complete
	    :help " `mys-complete'"]
            )))))

;; mys-components-complete

(defun mys--shell-completion-get-completions (input process completion-code)
  "Retrieve available completions for INPUT using PROCESS.
Argument COMPLETION-CODE is the python code used to get
completions on the current context."
  (let ((erg
	 (mys-send-string-no-output (format completion-code input) process)))
    (if (and erg (> (length erg) 2))
	(setq erg (split-string erg "^'\\|^\"\\|;\\|'$\\|\"$" t))
      (and mys-verbose-p (message "mys--shell-completion-get-completions: %s" "Don't see a completion")))
    erg))

;; post-command-hook
;; caused insert-file-contents error lp:1293172
(defun mys--after-change-function (end)
  "Restore window-confiuration after completion.

Takes END"
  (when
      (and (or
            (eq this-command 'completion-at-point)
            (eq this-command 'choose-completion)
            (eq this-command 'choose-completion)
            (eq this-command 'mys-shell-complete)
            (and (or
                  (eq last-command 'completion-at-point)
                  (eq last-command 'choose-completion)
                  (eq last-command 'choose-completion)
                  (eq last-command 'mys-shell-complete))
                 (eq this-command 'self-insert-command))))
    (mys-restore-window-configuration)
    )

  (goto-char end))

(defun mys--shell-insert-completion-maybe (completion input)
  (cond ((eq completion t)
	 (and mys-verbose-p (message "mys--shell-do-completion-at-point %s" "`t' is returned, not completion. Might be a bug.")))
	((null completion)
	 (and mys-verbose-p (message "mys--shell-do-completion-at-point %s" "Don't see a completion")))
	((and completion
	      (or (and (listp completion)
		       (string= input (car completion)))
		  (and (stringp completion)
		       (string= input completion)))))
	((and completion (stringp completion)(or (string= input completion) (string= "''" completion))))
	((and completion (stringp completion))
	 (progn (delete-char (- (length input)))
		(insert completion)))
	(t (mys--try-completion input completion)))
  )

(defun mys--shell-do-completion-at-point (process imports input exception-buffer code)
  "Do completion at point for PROCESS.

Takes PROCESS IMPORTS INPUT EXCEPTION-BUFFER CODE"
  (when imports
    (mys-execute-string imports process))
  (sit-for 0.1 t)
  (let* ((completion
	  (mys--shell-completion-get-completions
	   input process code)))
    (set-buffer exception-buffer)
    (when completion
      (mys--shell-insert-completion-maybe completion input))))

(defun mys--complete-base (shell word imports buffer)
  (let* ((proc (or
		;; completing inside a shell
		(get-buffer-process buffer)
		(and (comint-check-proc shell)
		     (get-process shell))
		(prog1
		    (get-buffer-process (mys-shell nil nil nil shell))
		  (sit-for mys-new-shell-delay t))))
	 ;; (buffer (process-buffer proc))
	 (code (if (string-match "[Ii][Pp]ython*" shell)
		   (mys-set-imys-completion-command-string shell)
		 mys-shell-module-completion-code)))
    (mys--shell-do-completion-at-point proc imports word buffer code)))

(defun mys--try-completion-intern (input completion buffer)
  (with-current-buffer buffer
    (let ((erg nil))
      (and (setq erg (try-completion input completion))
	   (sit-for 0.1)
	   (looking-back input (line-beginning-position))
	   (not (string= input erg))
	   (setq erg (completion-in-region (match-beginning 0) (match-end 0) completion)))))
  ;; (set-window-configuration mys-last-window-configuration)
  )

(defun mys--try-completion (input completion)
  "Repeat `try-completion' as long as match are found.

Interal used. Takes INPUT COMPLETION"
  (let ((erg nil)
	(newlist nil))
    (unless (mys--try-completion-intern input completion (current-buffer))
      (dolist (elt completion)
	(unless (string= erg elt)
	  (push elt newlist)))
      (if (< 1 (length newlist))
	  (with-output-to-temp-buffer mys-mys-completions
	    (display-completion-list
	     (all-completions input (or newlist completion))))))))

(defun mys--fast-completion-get-completions (input process completion-code buffer)
  "Retrieve available completions for INPUT using PROCESS.
Argument COMPLETION-CODE is the python code used to get
completions on the current context."
  (let ((completions
	 (mys-fast-send-string
	  (format completion-code input) process buffer t)))
    (when (> (length completions) 2)
      (split-string completions "^'\\|^\"\\|;\\|'$\\|\"$" t))))

(defun mys--fast--do-completion-at-point (process imports input code buffer)
  "Do completion at point for PROCESS."
  ;; send setup-code
  (let (mys-store-result-p)
    (when imports
      ;; (message "%s" imports)
      (mys-fast-send-string imports process buffer nil t)))
  (let* ((completion
	  (mys--fast-completion-get-completions input process code buffer)))
    (sit-for 0.1)
    (cond ((eq completion t)
	   (and mys-verbose-p (message "mys--fast--do-completion-at-point %s" "`t' is returned, not completion. Might be a bug.")))
	  ((null completion)
	   (and mys-verbose-p (message "mys--fast--do-completion-at-point %s" "Don't see a completion"))
	   (set-window-configuration mys-last-window-configuration))
	  ((and completion
		(or (and (listp completion)
			 (string= input (car completion)))
		    (and (stringp completion)
			 (string= input completion))))
	   (set-window-configuration mys-last-window-configuration))
	  ((and completion (stringp completion) (not (string= input completion)))
	   (progn (delete-char (- (length input)))
		  (insert completion)
		  ;; (move-marker orig (point))
		  ;; minibuffer.el expects a list
		  ))
	  (t (mys--try-completion input completion)))))

(defun mys--fast-complete-base (shell word imports)
  (let* (mys-split-window-on-execute mys-switch-buffers-on-execute-p
	 (shell (or shell mys-shell-name))
	 (buffer (mys-shell nil nil nil shell nil t))
 	 (proc (get-buffer-process buffer))
	 (code (if (string-match "[Ii][Pp]ython*" shell)
		   (mys-set-imys-completion-command-string shell)
		 mys-shell-module-completion-code)))
    (mys--mys-send-completion-setup-code buffer)
    (mys--fast--do-completion-at-point proc imports word code buffer)))

(defun mys-shell-complete (&optional shell beg end word fast imports)
  (interactive)
  (let* ((exception-buffer (current-buffer))
	 (pps (parse-partial-sexp
	       (or
		(ignore-errors (cdr-safe comint-last-prompt))
		(ignore-errors comint-last-prompt)
		(line-beginning-position))
	       (point)))
	 (in-string (when (nth 3 pps) (nth 8 pps)))
         (beg
	  (save-excursion
	    (or beg
	 	(and in-string
	 	     ;; possible completion of filenames
	 	     (progn
	 	       (goto-char in-string)
	 	       (and
	 		(save-excursion
	 		  (skip-chars-backward "^ \t\r\n\f") (looking-at "open")))

	 	       (skip-chars-forward "\"'") (point)))
	 	(progn (and (eq (char-before) ?\()(forward-char -1))
	 	       (skip-chars-backward "a-zA-Z0-9_.'") (point)))))
         (end (or end (point)))
	 (word (or word (buffer-substring-no-properties beg end)))
	 (ausdruck (and (string-match "^/" word) (setq word (substring-no-properties word 1))(concat "\"" word "*\"")))
	 ;; when in string, assume looking for filename
	 (filenames (and in-string ausdruck
			 (list (replace-regexp-in-string "\n" "" (shell-command-to-string (concat "find / -maxdepth 1 -name " ausdruck))))))
         (imports (or imports (mys-find-imports)))
         mys-fontify-shell-buffer-p erg)
    (cond (fast (mys--fast-complete-base shell word imports))
	  ((and in-string filenames)
	   (when (setq erg (try-completion (concat "/" word) filenames))
	     (delete-region beg end)
	     (insert erg)))
	  (t (mys--complete-base shell word imports exception-buffer)))
    nil))

(defun mys-fast-complete (&optional shell word imports)
  "Complete word before point, if any.

Use `mys-fast-process' "
  (interactive "*")
  (window-configuration-to-register mys--windows-config-register)
  (setq mys-last-window-configuration
  	(current-window-configuration))
  (mys-shell-complete shell nil nil word 1 imports)
  (mys-restore-window-configuration)
  )

(defun mys-indent-or-complete ()
  "Complete or indent depending on the context.

If cursor is at end of a symbol, try to complete
Otherwise call `mys-indent-line'

If `(use-region-p)' returns t, indent region.
Use `C-q TAB' to insert a literally TAB-character

In `mys-mode' `mys-complete-function' is called,
in (I)Python shell-modes `mys-shell-complete'"
  (interactive "*")
  (window-configuration-to-register mys--windows-config-register)
  ;; (setq mys-last-window-configuration
  ;;       (current-window-configuration))
  (cond ((use-region-p)
	 (when mys-debug-p (message "mys-indent-or-complete: %s" "calling `use-region-p'-clause"))
	 (mys-indent-region (region-beginning) (region-end)))
	((or (bolp)
	     (member (char-before) (list 9 10 12 13 32 ?: ?\) ?\] ?\}))
	     (not (looking-at "[ \t]*$")))
	 (mys-indent-line))
	((comint-check-proc (current-buffer))
	 ;; (let* ((shell (process-name (get-buffer-process (current-buffer)))))
	 (ignore-errors (completion-at-point)))
	(t
	 (when mys-debug-p (message "mys-indent-or-complete: %s" "calling `t'-clause"))
	 ;; (mys-fast-complete)
	 (completion-at-point))))

;; mys-components-pdb

(defun mys-execute-statement-pdb ()
  "Execute statement running pdb."
  (interactive)
  (let ((mys-mys-command-args "-i -m pdb"))
    (mys-execute-statement)))

(defun mys-execute-region-pdb (beg end)
  "Takes region between BEG END."
  (interactive "r")
  (let ((mys-mys-command-args "-i -m pdb"))
    (mys-execute-region beg end)))

(defun mys-pdb-execute-statement ()
  "Execute statement running pdb."
  (interactive)
  (let ((stm (progn (mys-statement) (car kill-ring))))
    (mys-execute-string (concat "import pdb;pdb.run('" stm "')"))))

(defun mys-pdb-help ()
  "Print generic pdb.help() message."
  (interactive)
  (mys-execute-string "import pdb;pdb.help()"))

;; https://stackoverflow.com/questions/6980749/simpler-way-to-put-pdb-breakpoints-in-mys-code
;; breakpoint at line 3
;; avoid inserting pdb.set_trace()

;; python -m pdb -c "b 3" -c c your_script.py

(defun mys-pdb-break-at-current-line (&optional line)
  "Set breakpoint at current line.

Optional LINE FILE CONDITION"
  (interactive "p")
  (let ((line (number-to-string (or line (mys-count-lines)))))
    (mys-execute-string (concat "import pdb;pdb.break('" line "')"))))

(defun mys--pdb-versioned ()
  "Guess existing pdb version from `mys-shell-name'.

Return \"pdb[VERSION]\" if executable found, just \"pdb\" otherwise"
  (interactive)
  (let ((erg (when (string-match "[23]" mys-shell-name)
	       ;; versions-part
	       (substring mys-shell-name (string-match "[23]" mys-shell-name)))))
    (if erg
	(cond ((executable-find (concat "pdb" erg))
	       (concat "pdb" erg))
	      ((and (string-match "\\." erg)
		    (executable-find (concat "pdb" (substring erg 0 (string-match "\\." erg)))))
	       (concat "pdb" (substring erg 0 (string-match "\\." erg)))))
      "pdb")))

(defun mys-pdb (command-line)
  "Run pdb on program FILE in buffer `*gud-FILE*'.
The directory containing FILE becomes the initial working directory
and source-file directory for your debugger.

At GNU Linux required pdb version should be detected by `mys--pdb-version'
at Windows configure `mys-mys-ms-pdb-command'

lp:963253
Argument COMMAND-LINE TBD."
  (interactive
   (progn
     (require 'gud)
     (list (gud-query-cmdline
	    (if (or (eq system-type 'ms-dos)(eq system-type 'windows-nt))
		(car (read-from-string mys-mys-ms-pdb-command))
	      ;; sys.version_info[0]
	      ;; (car (read-from-string (mys--pdb-version)))
	      'pdb)
	    (mys--buffer-filename-remote-maybe)))))
  (pdb command-line))

(defun mys--pdb-current-executable ()
  "When `mys-pdb-executable' is set, return it.

Otherwise return resuslt from `executable-find'"
  (or mys-pdb-executable
      (executable-find "pdb")))

(defun mys-update-gud-pdb-history ()
  "Put pdb file name at the head of `gud-pdb-history'.

If pdb is called at a Python buffer."
  (interactive)
  (let* (;; PATH/TO/pdb
	 (first (cond ((and gud-pdb-history (ignore-errors (car gud-pdb-history)))
		       (replace-regexp-in-string "^\\([^ ]+\\) +.+$" "\\1" (car gud-pdb-history)))
		      (mys-pdb-executable
		       mys-pdb-executable)
		      ((or (eq system-type 'ms-dos)(eq system-type 'windows-nt))
		       ;; lp:963253
		       "c:/python27/python\ -i\ c:/python27/Lib/pdb.py")
		      (t
		       (mys--pdb-current-executable))))
	 ;; file to debug
         (second (cond ((not (ignore-errors
			       (mys--buffer-filename-remote-maybe)))
			(error "%s" "Buffer must be saved first."))
		       ((mys--buffer-filename-remote-maybe))
		       (t (and gud-pdb-history (stringp (car gud-pdb-history)) (replace-regexp-in-string "^\\([^ ]+\\) +\\(.+\\)$" "\\2" (car gud-pdb-history))))))
         (erg (and first second (concat first " " second))))
    (when erg
      (push erg gud-pdb-history))))

(defadvice pdb (before gud-query-cmdline activate)
  "Provide a better default command line when called interactively."
  (interactive
   (list (gud-query-cmdline mys-pdb-path
                            ;; (file-name-nondirectory buffer-file-name)
			    (file-name-nondirectory (mys--buffer-filename-remote-maybe)) ))))

;; tbreak [ ([filename:]lineno | function) [, condition] ]
;;         Same arguments as break, but sets a temporary breakpoint: it
;;         is automatically deleted when first hit.

;; python -m pdb -c "b 3" -c c your_script.py

(defun mys-pdb-tbreak ()
  "Insert a temporary break."
  (interactive)
  (let (
	(mys-mys-command-args '("-i -c \"b 30\" -c c \"eyp.py\""))
	(mys-python3-command-args '("-i -c \"b 30\" -c c \"eyp.py\""))
	)
    (mys-execute-buffer)))



(defun mys--pdbtrack-overlay-arrow (activation)
  "Activate or de arrow at beginning-of-line in current buffer."
  ;; This was derived/simplified from edebug-overlay-arrow
  (cond (activation
         (setq overlay-arrow-position (make-marker))
         (setq overlay-arrow-string "=>")
         (set-marker overlay-arrow-position (line-beginning-position) (current-buffer))
         (setq mys-pdbtrack-is-tracking-p t))
        (overlay-arrow-position
         (setq overlay-arrow-position nil)
         (setq mys-pdbtrack-is-tracking-p nil))))

(defun mys--pdbtrack-track-stack-file (text)
  "Show the file indicated by the pdb stack entry line, in a separate window.

Activity is disabled if the buffer-local variable
`mys-pdbtrack-do-tracking-p' is nil.

We depend on the pdb input prompt matching `mys-pdbtrack-input-prompt'
at the beginning of the line.

If the traceback target file path is invalid, we look for the most
recently visited mys-mode buffer which either has the name of the
current function \(or class) or which defines the function \(or
class).  This is to provide for remote scripts, eg, Zope's 'Script
\(Python)' - put a _copy_ of the script in a buffer named for the
script, and set to mys-mode, and pdbtrack will find it.)"
  ;; Instead of trying to piece things together from partial text
  ;; (which can be almost useless depending on Emacs version), we
  ;; monitor to the point where we have the next pdb prompt, and then
  ;; check all text from comint-last-input-end to process-mark.
  ;;
  ;; Also, we're very conservative about clearing the overlay arrow,
  ;; to minimize residue.  This means, for instance, that executing
  ;; other pdb commands wipe out the highlight.  You can always do a
  ;; 'where' (aka 'w') command to reveal the overlay arrow.
  (let* ((origbuf (current-buffer))
         (currproc (get-buffer-process origbuf)))

    (if (not (and currproc mys-pdbtrack-do-tracking-p))
        (mys--pdbtrack-overlay-arrow nil)

      (let* ((procmark (process-mark currproc))
             (block (buffer-substring (max comint-last-input-end
                                           (- procmark
                                              mys-pdbtrack-track-range))
                                      procmark))
             target target_fname target_lineno target_buffer)

        (if (not (string-match (concat mys-pdbtrack-input-prompt "$") block))
            (mys--pdbtrack-overlay-arrow nil)

          (setq target (mys--pdbtrack-get-source-buffer block))

          (if (stringp target)
              (message "pdbtrack: %s" target)

            (setq target_lineno (car target))
            (setq target_buffer (cadr target))
            (setq target_fname
		  (mys--buffer-filename-remote-maybe target_buffer))
            (switch-to-buffer-other-window target_buffer)
            (goto-char (point-min))
            (forward-line (1- target_lineno))
            (message "pdbtrack: line %s, file %s" target_lineno target_fname)
            (mys--pdbtrack-overlay-arrow t)
            (pop-to-buffer origbuf t)))))))

(defun mys--pdbtrack-map-filename (filename)

  (let
      ((replacement-val (assoc-default
                         filename mys-pdbtrack-filename-mapping
                         (lambda (mapkey path)
                           (string-match
                            (concat "^" (regexp-quote mapkey))
                            path)))
                        ))
    (if (not (eq replacement-val nil))
        (replace-match replacement-val 't 't filename)
      filename)))

(defun mys--pdbtrack-get-source-buffer (block)
  "Return line number and buffer of code indicated by block's traceback text.

We look first to visit the file indicated in the trace.

Failing that, we look for the most recently visited mys-mode buffer
with the same name or having the named function.

If we're unable find the source code we return a string describing the
problem as best as we can determine."

  (if (and (not (string-match mys-pdbtrack-stack-entry-regexp block))
           ;; pydb integration still to be done
           ;; (not (string-match mys-pydbtrack-stack-entry-regexp block))
	   )
      (prog1
	  "Traceback cue not found"
	(message "Block: %s" block))
    (let* ((remote-prefix (or (file-remote-p default-directory) ""))
           (filename (concat remote-prefix
                             (match-string
                              mys-pdbtrack-marker-regexp-file-group block)))
           (lineno (string-to-number (match-string
                                      mys-pdbtrack-marker-regexp-line-group
                                      block)))
           (funcname (match-string mys-pdbtrack-marker-regexp-funcname-group
                                   block))
           funcbuffer)

      (cond ((string= filename "")
             (format "(Skipping empty filename)"))

            ((file-exists-p filename)
             (list lineno (find-file-noselect filename)))

            ((file-exists-p (mys--pdbtrack-map-filename filename))
             (list lineno (find-file-noselect (mys--pdbtrack-map-filename filename))))

            ((setq funcbuffer (mys--pdbtrack-grub-for-buffer funcname lineno))
             (if (string-match "/Script (Python)$" filename)
                 ;; Add in number of lines for leading '##' comments:
                 (setq lineno
                       (+ lineno
                          (save-excursion
                            (with-current-buffer funcbuffer
			      (count-lines
			       (point-min)
			       (max (point-min)
				    (string-match "^\\([^#]\\|#[^#]\\|#$\\)"
						  (buffer-substring (point-min)
								    (point-max))))))))))
             (list lineno funcbuffer))

            ((= (elt filename 0) ?\<)
             (format "(Non-file source: '%s')" filename))

            (t (format "Not found: %s(), %s" funcname filename))))))

(defun mys--pdbtrack-grub-for-buffer (funcname lineno)
  "Find most recent buffer itself named or having function funcname.

We walk the buffer-list history for mys-mode buffers that are
named for funcname or define a function funcname."
  (let ((buffers (buffer-list))
        buf
        got)
    (while (and buffers (not got))
      (setq buf (car buffers)
            buffers (cdr buffers))
      (if (and (save-excursion
		 (with-current-buffer buf
		   (string= major-mode "mys-mode")))
               (or (string-match funcname (buffer-name buf))
                   (string-match (concat "^\\s-*\\(def\\|class\\)\\s-+"
                                         funcname "\\s-*(")
                                 (save-excursion
                                   (with-current-buffer  buf
                                   (buffer-substring (point-min)
                                                     (point-max)))))))
          (setq got buf)))
    got))

;; pdbtrack functions
(defun mys-pdbtrack-set-tracked-buffer (file-name)
  "Set the buffer for FILE-NAME as the tracked buffer.
Internally it uses the `mys-pdbtrack-tracked-buffer' variable.
Returns the tracked buffer."
  (let* ((file-name-prospect (concat (file-remote-p default-directory)
                              file-name))
         (file-buffer (get-file-buffer file-name-prospect)))
    (if file-buffer
        (setq mys-pdbtrack-tracked-buffer file-buffer)
      (cond
       ((file-exists-p file-name-prospect)
        (setq file-buffer (find-file-noselect file-name-prospect)))
       ((and (not (equal file-name file-name-prospect))
             (file-exists-p file-name))
        ;; Fallback to a locally available copy of the file.
        (setq file-buffer (find-file-noselect file-name-prospect))))
      (when (not (member file-buffer mys-pdbtrack-buffers-to-kill))
        (add-to-list 'mys-pdbtrack-buffers-to-kill file-buffer)))
    file-buffer))

(defun mys-pdbtrack-toggle-stack-tracking (arg)
  "Set variable `mys-pdbtrack-do-tracking-p'. "
  (interactive "P")
  ;; (if (not (get-buffer-process (current-buffer)))
  ;; (error "No process associated with buffer '%s'" (current-buffer)))

  ;; missing or 0 is toggle, >0 turn on, <0 turn off
  (cond ((not arg)
         (setq mys-pdbtrack-do-tracking-p (not mys-pdbtrack-do-tracking-p)))
        ((zerop (prefix-numeric-value arg))
         (setq mys-pdbtrack-do-tracking-p nil))
        ((> (prefix-numeric-value arg) 0)
         (setq mys-pdbtrack-do-tracking-p t)))
  ;; (if mys-pdbtrack-do-tracking-p
  ;;     (progn
  ;;       (add-hook 'comint-output-filter-functions 'mys--pdbtrack-track-stack-file t)
  ;;       (remove-hook 'comint-output-filter-functions 'mys-pdbtrack-track-stack-file t))
  ;;   (remove-hook 'comint-output-filter-functions 'mys--pdbtrack-track-stack-file t)
  ;;   )
  (message "%sabled Python's pdbtrack"
           (if mys-pdbtrack-do-tracking-p "En" "Dis")))

(defun turn-on-pdbtrack ()
  (interactive)
  (mys-pdbtrack-toggle-stack-tracking 1))

(defun turn-off-pdbtrack ()
  (interactive)
  (mys-pdbtrack-toggle-stack-tracking 0))



(if pdb-track-stack-from-shell-p
    (add-hook 'comint-output-filter-functions 'mys--pdbtrack-track-stack-file t)
  (remove-hook 'comint-output-filter-functions 'mys--pdbtrack-track-stack-file t))


(defun mys-pdbtrack-comint-output-filter-function (output)
  "Move overlay arrow to current pdb line in tracked buffer.
Argument OUTPUT is a string with the output from the comint process."
  (when (and pdb-track-stack-from-shell-p (not (string= output "")))
    (let* ((full-output (ansi-color-filter-apply
                         (buffer-substring comint-last-input-end (point-max))))
           (line-number)
           (file-name
            (with-temp-buffer
              (insert full-output)
              ;; When the debugger encounters a pdb.set_trace()
              ;; command, it prints a single stack frame.  Sometimes
              ;; it prints a bit of extra information about the
              ;; arguments of the present function.  When ipdb
              ;; encounters an exception, it prints the _entire_ stack
              ;; trace.  To handle all of these cases, we want to find
              ;; the _last_ stack frame printed in the most recent
              ;; batch of output, then jump to the corresponding
              ;; file/line number.
              (goto-char (point-max))
              (when (re-search-backward mys-pdbtrack-stacktrace-info-regexp nil t)
                (setq line-number (string-to-number
                                   (match-string-no-properties 2)))
                (match-string-no-properties 1)))))
      (if (and file-name line-number)
          (let* ((tracked-buffer
                  (mys-pdbtrack-set-tracked-buffer file-name))
                 (shell-buffer (current-buffer))
                 (tracked-buffer-window (get-buffer-window tracked-buffer))
                 (tracked-buffer-line-pos))
            (with-current-buffer tracked-buffer
              (set (make-local-variable 'overlay-arrow-string) "=>")
              (set (make-local-variable 'overlay-arrow-position) (make-marker))
              (setq tracked-buffer-line-pos (progn
                                              (goto-char (point-min))
                                              (forward-line (1- line-number))
                                              (point-marker)))
              (when tracked-buffer-window
                (set-window-point
                 tracked-buffer-window tracked-buffer-line-pos))
              (set-marker overlay-arrow-position tracked-buffer-line-pos))
            (pop-to-buffer tracked-buffer)
            (switch-to-buffer-other-window shell-buffer))
        (when mys-pdbtrack-tracked-buffer
          (with-current-buffer mys-pdbtrack-tracked-buffer
            (set-marker overlay-arrow-position nil))
          (mapc #'(lambda (buffer)
                    (ignore-errors (kill-buffer buffer)))
                mys-pdbtrack-buffers-to-kill)
          (setq mys-pdbtrack-tracked-buffer nil
                mys-pdbtrack-buffers-to-kill nil)))))
  output)

;; mys-components-pdbtrack


;; mys-components-help

;;  Info-look functionality.
(require 'info-look)
(eval-when-compile (require 'info))

(defun mys-info-lookup-symbol ()
  "Call `info-lookup-symbol'.

Sends help if stuff is missing."
  (interactive)
  (if (functionp 'pydoc-info-add-help)
      (call-interactively 'info-lookup-symbol)
    (message "pydoc-info-add-help not found. Please check INSTALL-INFO-FILES")))

(info-lookup-add-help
 :mode 'mys-mode
 :regexp "[[:alnum:]_]+"
 :doc-spec
'(("(python)Index" nil "")))

(defun mys-after-info-look ()
  "Set up info-look for Python.

Tries to take account of versioned Python Info files, e.g. Debian's
python2.5-ref.info.gz.
Used with `eval-after-load'."
  (let* ((version (let ((s (shell-command-to-string (concat mys-mys-command
							    " -V"))))
		    (string-match "^Python \\([0-9]+\\.[0-9]+\\>\\)" s)
		    (match-string 1 s)))
	 ;; Whether info files have a Python version suffix, e.g. in Debian.
	 (versioned
	  (with-temp-buffer
	    (Info-mode)
	    ;; First look for Info files corresponding to the version
	    ;; of the interpreter we're running.
	    (condition-case ()
		;; Don't use `info' because it would pop-up a *info* buffer.
		(progn
		  (Info-goto-node (format "(python%s-lib)Miscellaneous Index"
					  version))
		  t)
	      (error
	       ;; Otherwise see if we actually have an un-versioned one.
	       (condition-case ()
		   (progn
		     (Info-goto-node
		      (format "(python%s-lib)Miscellaneous Index" version))
		     nil)
		 (error
		  ;; Otherwise look for any versioned Info file.
		  (condition-case ()
		      (let (found)
			(dolist (dir (or Info-directory-list
					 Info-default-directory-list))
			  (unless found
			    (let ((file (car (file-expand-wildcards
					      (expand-file-name "python*-lib*"
								dir)))))
			      (if (and file
				       (string-match
					"\\<python\\([0-9]+\\.[0-9]+\\>\\)-"
					file))
				  (setq version (match-string 1 file)
					found t)))))
			found)
		    (error)))))))))
    (info-lookup-maybe-add-help
     :mode 'mys-mode
     :regexp "[[:alnum:]_]+"
     :doc-spec
     ;; Fixme: Can this reasonably be made specific to indices with
     ;; different rules?  Is the order of indices optimal?
     ;; (Miscellaneous in -ref first prefers lookup of keywords, for
     ;; instance.)
     (if versioned
	 ;; The empty prefix just gets us highlighted terms.
	 `((,(concat "(python" version "-ref)Miscellaneous Index"))
	   (,(concat "(python" version "-ref)Module Index"))
	   (,(concat "(python" version "-ref)Function-Method-Variable Index"))
	   (,(concat "(python" version "-ref)Class-Exception-Object Index"))
	   (,(concat "(python" version "-lib)Module Index"))
	   (,(concat "(python" version "-lib)Class-Exception-Object Index"))
	   (,(concat "(python" version "-lib)Function-Method-Variable Index"))
	   (,(concat "(python" version "-lib)Miscellaneous Index")))
       '(("(mys-ref)Miscellaneous Index")
	 ("(mys-ref)Module Index")
	 ("(mys-ref)Function-Method-Variable Index")
	 ("(mys-ref)Class-Exception-Object Index")
	 ("(mys-lib)Module Index")
	 ("(mys-lib)Class-Exception-Object Index")
	 ("(mys-lib)Function-Method-Variable Index")
	 ("(mys-lib)Miscellaneous Index"))))))

;;  (if (featurep 'info-look)
;;      (mys-after-info-look))

;;  (eval-after-load "info-look" '(mys-after-info-look))

;; ;

(defun mys-fetch-docu ()
  "Lookup in current buffer for the doku for the symbol at point.

Useful for newly defined symbol, not known to python yet."
  (interactive)
  (let* ((symb (prin1-to-string (symbol-at-point)))
         erg)
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward (concat mys-def-or-class-re " *" symb) nil (quote move) 1)
        (forward-line 1)
        (when (looking-at "[ \t]*\"\"\"\\|[ \t]*'''\\|[ \t]*'[^]+\\|[ \t]*\"[^\"]+")
          (goto-char (match-end 0))
          (setq erg (buffer-substring-no-properties (match-beginning 0) (re-search-forward "\"\"\"\\|'''" nil 'move)))
          (when erg
            (set-buffer (get-buffer-create "*Mys-Help*"))
            (erase-buffer)
            ;; (when (called-interactively-p 'interactive)
            ;;   (switch-to-buffer (current-buffer)))
            (insert erg)))))))

(defun mys-info-current-defun (&optional include-type)
  "Return name of surrounding function.

Use Python compatible dotted expression syntax
Optional argument INCLUDE-TYPE indicates to include the type of the defun.
This function is compatible to be used as
`add-log-current-defun-function' since it returns nil if point is
not inside a defun."
  (interactive)
  (let ((names '())
        (min-indent)
        (first-run t))
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (line-end-position))
        (forward-comment -9999)
        (setq min-indent (current-indentation))
        (while (mys-backward-def-or-class)
          (when (or (< (current-indentation) min-indent)
                    first-run)
            (setq first-run nil)
            (setq min-indent (current-indentation))
            (looking-at mys-def-or-class-re)
            (setq names (cons
                         (if (not include-type)
                             (match-string-no-properties 1)
                           (mapconcat 'identity
                                      (split-string
                                       (match-string-no-properties 0)) " "))
                         names))))))
    (when names
      (mapconcat (lambda (strg) strg) names "."))))

(defalias 'mys-describe-symbol 'mys-help-at-point)
(defun mys--help-at-point-intern (sym orig)
  (let* ((origfile (mys--buffer-filename-remote-maybe))
	 (cmd (mys-find-imports))
	 (oldbuf (current-buffer))
	 )
    (when (not mys-remove-cwd-from-path)
      (setq cmd (concat cmd "import sys\n"
			"sys.path.insert(0, '"
			(file-name-directory origfile) "')\n")))
    ;; (setq cmd (concat cmd "pydoc.help('" sym "')\n"))
    (mys-execute-string (concat cmd "help('" sym "')\n") nil t nil orig nil nil nil nil nil nil oldbuf t)
    (display-buffer oldbuf)))
    ;; (with-help-window "Hilfe" (insert mys-result))))

(defun mys-help-at-point ()
  "Print help on symbol at point.

If symbol is defined in current buffer, jump to it's definition"
  (interactive)
  (let* ((orig (point))
	 (beg (and (use-region-p) (region-beginning)))
	 (end (and (use-region-p) (region-end)))
	 (symbol
	  (or (and beg end
		   (buffer-substring-no-properties beg end))
	      ;; (thing-at-point 'symbol t)
	      (mys-symbol-at-point))))
    (and symbol (unless (string= "" symbol)
		  (mys--help-at-point-intern symbol orig))
	 ;; (mys--shell-manage-windows buffer exception-buffer split (or interactivep switch))
	 )))

(defun mys--dump-help-string (str)
  (with-output-to-temp-buffer "*Help*"
    (let ((locals (buffer-local-variables))
          funckind funcname func funcdoc
          (start 0) mstart end
          keys)
      (while (string-match "^%\\([vc]\\):\\(.+\\)\n" str start)
        (setq mstart (match-beginning 0) end (match-end 0)
              funckind (substring str (match-beginning 1) (match-end 1))
              funcname (substring str (match-beginning 2) (match-end 2))
              func (intern funcname))
        (princ (substitute-command-keys (substring str start mstart)))
        (cond
         ((equal funckind "c")          ; command
          (setq funcdoc (documentation func)
                keys (concat
                      "Key(s): "
                      (mapconcat 'key-description
                                 (where-is-internal func mys-mode-map)
                                 ", "))))
         ((equal funckind "v")          ; variable
          (setq funcdoc (documentation-property func 'variable-documentation)
                keys (if (assq func locals)
                         (concat
                          "Local/Global values: "
                          (prin1-to-string (symbol-value func))
                          " / "
                          (prin1-to-string (default-value func)))
                       (concat
                        "Value: "
                        (prin1-to-string (symbol-value func))))))
         (t                             ; unexpected
          (error "Error in mys--dump-help-string, tag %s" funckind)))
        (princ (format "\n-> %s:\t%s\t%s\n\n"
                       (if (equal funckind "c") "Command" "Variable")
                       funcname keys))
        (princ funcdoc)
        (terpri)
        (setq start end))
      (princ (substitute-command-keys (substring str start)))
      ;; (and comint-vars-p (mys-report-comint-variable-setting))
      )
    (if (featurep 'xemacs) (print-help-return-message)
      (help-print-return-message))))

(defun mys-describe-mode ()
  "Dump long form of `mys-mode' docs."
  (interactive)
  (mys--dump-help-string "Major mode for editing Python files.
Knows about Python indentation, tokens, comments and continuation lines.
Paragraphs are separated by blank lines only.

Major sections below begin with the string `@'; specific function and
variable docs begin with ->.

@EXECUTING PYTHON CODE

\\[mys-execute-import-or-reload]\timports or reloads the file in the Python interpreter
\\[mys-execute-buffer]\tsends the entire buffer to the Python interpreter
\\[mys-execute-region]\tsends the current region
\\[mys-execute-def-or-class]\tsends the current function or class definition
\\[mys-execute-string]\tsends an arbitrary string
\\[mys-shell]\tstarts a Python interpreter window; this will be used by
\tsubsequent Python execution commands
%c:mys-execute-import-or-reload
%c:mys-execute-buffer
%c:mys-execute-region
%c:mys-execute-def-or-class
%c:mys-execute-string
%c:mys-shell

@VARIABLES

mys-install-directory\twherefrom `mys-mode' looks for extensions
mys-indent-offset\tindentation increment
mys-block-comment-prefix\tcomment string used by comment-region

mys-shell-name\tshell command to invoke Python interpreter
mys-temp-directory\tdirectory used for temp files (if needed)

mys-beep-if-tab-change\tring the bell if tab-width is changed
%v:mys-install-directory
%v:mys-indent-offset
%v:mys-block-comment-prefix
%v:mys-shell-name
%v:mys-temp-directory
%v:mys-beep-if-tab-change

@KINDS OF LINES

Each physical line in the file is either a `continuation line' (the
preceding line ends with a backslash that's not part of a comment, or
the paren/bracket/brace nesting level at the start of the line is
non-zero, or both) or an `initial line' (everything else).

An initial line is in turn a `blank line' (contains nothing except
possibly blanks or tabs), a `comment line' (leftmost non-blank
character is `#’), or a ‘code line' (everything else).

Comment Lines

Although all comment lines are treated alike by Python, Python mode
recognizes two kinds that act differently with respect to indentation.

An `indenting comment line' is a comment line with a blank, tab or
nothing after the initial `#'.  The indentation commands (see below)
treat these exactly as if they were code lines: a line following an
indenting comment line will be indented like the comment line.  All
other comment lines (those with a non-whitespace character immediately
following the initial `#’) are ‘non-indenting comment lines', and
their indentation is ignored by the indentation commands.

Indenting comment lines are by far the usual case, and should be used
whenever possible.  Non-indenting comment lines are useful in cases
like these:

\ta = b # a very wordy single-line comment that ends up being
\t #... continued onto another line

\tif a == b:
##\t\tprint 'panic!' # old code we've `commented out'
\t\treturn a

Since the `#...’ and ‘##' comment lines have a non-whitespace
character following the initial `#', Python mode ignores them when
computing the proper indentation for the next line.

Continuation Lines and Statements

The `mys-mode' commands generally work on statements instead of on
individual lines, where a `statement' is a comment or blank line, or a
code line and all of its following continuation lines (if any)
considered as a single logical unit.  The commands in this mode
generally (when it makes sense) automatically move to the start of the
statement containing point, even if point happens to be in the middle
of some continuation line.

@INDENTATION

Primarily for entering new code:
\t\\[indent-for-tab-command]\t indent line appropriately
\t\\[mys-newline-and-indent]\t insert newline, then indent
\t\\[mys-electric-backspace]\t reduce indentation, or delete single character

Primarily for reindenting existing code:
\t\\[mys-guess-indent-offset]\t guess mys-indent-offset from file content; change locally
\t\\[universal-argument] \\[mys-guess-indent-offset]\t ditto, but change globally

\t\\[mys-indent-region]\t reindent region to match its context
\t\\[mys-shift-left]\t shift line or region left by mys-indent-offset
\t\\[mys-shift-right]\t shift line or region right by mys-indent-offset

Unlike most programming languages, Python uses indentation, and only
indentation, to specify block structure.  Hence the indentation supplied
automatically by `mys-mode' is just an educated guess:  only you know
the block structure you intend, so only you can supply correct
indentation.

The \\[indent-for-tab-command] and \\[mys-newline-and-indent] keys try to suggest plausible indentation, based on
the indentation of preceding statements.  E.g., assuming
mys-indent-offset is 4, after you enter
\tif a > 0: \\[mys-newline-and-indent]
the cursor will be moved to the position of the `_' (_ is not a
character in the file, it's just used here to indicate the location of
the cursor):
\tif a > 0:
\t _
If you then enter `c = d' \\[mys-newline-and-indent], the cursor will move
to
\tif a > 0:
\t c = d
\t _
`mys-mode' cannot know whether that's what you intended, or whether
\tif a > 0:
\t c = d
\t_
was your intent.  In general, `mys-mode' either reproduces the
indentation of the (closest code or indenting-comment) preceding
statement, or adds an extra mys-indent-offset blanks if the preceding
statement has `:' as its last significant (non-whitespace and non-
comment) character.  If the suggested indentation is too much, use
\\[mys-electric-backspace] to reduce it.

Continuation lines are given extra indentation.  If you don't like the
suggested indentation, change it to something you do like, and Mys-
mode will strive to indent later lines of the statement in the same way.

If a line is a continuation line by virtue of being in an unclosed
paren/bracket/brace structure (`list', for short), the suggested
indentation depends on whether the current line contains the first item
in the list.  If it does, it's indented mys-indent-offset columns beyond
the indentation of the line containing the open bracket.  If you don't
like that, change it by hand.  The remaining items in the list will mimic
whatever indentation you give to the first item.

If a line is a continuation line because the line preceding it ends with
a backslash, the third and following lines of the statement inherit their
indentation from the line preceding them.  The indentation of the second
line in the statement depends on the form of the first (base) line:  if
the base line is an assignment statement with anything more interesting
than the backslash following the leftmost assigning `=', the second line
is indented two columns beyond that `='.  Else it's indented to two
columns beyond the leftmost solid chunk of non-whitespace characters on
the base line.

Warning:  indent-region should not normally be used!  It calls \\[indent-for-tab-command]
repeatedly, and as explained above, \\[indent-for-tab-command] can't guess the block
structure you intend.
%c:indent-for-tab-command
%c:mys-newline-and-indent
%c:mys-electric-backspace

The next function may be handy when editing code you didn't write:
%c:mys-guess-indent-offset

The remaining `indent' functions apply to a region of Python code.  They
assume the block structure (equals indentation, in Python) of the region
is correct, and alter the indentation in various ways while preserving
the block structure:
%c:mys-indent-region
%c:mys-shift-left
%c:mys-shift-right

@MARKING & MANIPULATING REGIONS OF CODE

\\[mys-mark-block]\t mark block of lines
\\[mys-mark-def-or-class]\t mark smallest enclosing def
\\[universal-argument] \\[mys-mark-def-or-class]\t mark smallest enclosing class
\\[comment-region]\t comment out region of code
\\[universal-argument] \\[comment-region]\t uncomment region of code
%c:mys-mark-block
%c:mys-mark-def-or-class
%c:comment-region

@MOVING POINT

\\[mys-previous-statement]\t move to statement preceding point
\\[mys-next-statement]\t move to statement following point
\\[mys-goto-block-up]\t move up to start of current block
\\[mys-backward-def-or-class]\t move to start of def
\\[universal-argument] \\[mys-backward-def-or-class]\t move to start of class
\\[mys-forward-def-or-class]\t move to end of def
\\[universal-argument] \\[mys-forward-def-or-class]\t move to end of class

The first two move to one statement beyond the statement that contains
point.  A numeric prefix argument tells them to move that many
statements instead.  Blank lines, comment lines, and continuation lines
do not count as `statements' for these commands.  So, e.g., you can go
to the first code statement in a file by entering
\t\\[beginning-of-buffer]\t to move to the top of the file
\t\\[mys-next-statement]\t to skip over initial comments and blank lines
Or do \\[mys-previous-statement] with a huge prefix argument.
%c:mys-previous-statement
%c:mys-next-statement
%c:mys-goto-block-up
%c:mys-backward-def-or-class
%c:mys-forward-def-or-class

@LITTLE-KNOWN EMACS COMMANDS PARTICULARLY USEFUL IN PYTHON MODE

\\[indent-new-comment-line] is handy for entering a multi-line comment.

\\[set-selective-display] with a `small' prefix arg is ideally suited for viewing the
overall class and def structure of a module.

`\\[back-to-indentation]' moves point to a line's first non-blank character.

`\\[indent-relative]' is handy for creating odd indentation.

@OTHER EMACS HINTS

If you don't like the default value of a variable, change its value to
whatever you do like by putting a `setq' line in your .emacs file.
E.g., to set the indentation increment to 4, put this line in your
.emacs:
\t(setq mys-indent-offset 4)
To see the value of a variable, do `\\[describe-variable]' and enter the variable
name at the prompt.

When entering a key sequence like `C-c C-n', it is not necessary to
release the CONTROL key after doing the `C-c' part -- it suffices to
press the CONTROL key, press and release `c' (while still holding down
CONTROL), press and release `n' (while still holding down CONTROL), &
then release CONTROL.

Entering Python mode calls with no arguments the value of the variable
`mys-mode-hook', if that value exists and is not nil; for backward
compatibility it also tries `mys-mode-hook'; see the ‘Hooks' section of
the Elisp manual for details.

Obscure:  When mys-mode is first loaded, it looks for all bindings
to newline-and-indent in the global keymap, and shadows them with
local bindings to mys-newline-and-indent."))

;;  (require 'info-look)
;;  The info-look package does not always provide this function (it
;;  appears this is the case with XEmacs 21.1)
(when (fboundp 'info-lookup-maybe-add-help)
  (info-lookup-maybe-add-help
   :mode 'mys-mode
   :regexp "[a-zA-Z0-9_]+"
   :doc-spec '(("(mys-lib)Module Index")
               ("(mys-lib)Class-Exception-Object Index")
               ("(mys-lib)Function-Method-Variable Index")
               ("(mys-lib)Miscellaneous Index"))))

(defun mys--find-definition-in-source (sourcefile symbol)
  (called-interactively-p 'any) (message "sourcefile: %s" sourcefile)
  (when (find-file sourcefile)
    (goto-char (point-min))
    (when
	(or (re-search-forward (concat mys-def-or-class-re symbol) nil t 1)
	    (progn
	      ;; maybe a variable definition?
	      (goto-char (point-min))
	      (re-search-forward (concat "^.+ " symbol) nil t 1)))
      (push-mark)
      (goto-char (match-beginning 0))
      (exchange-point-and-mark))))

;;  Find function stuff, lifted from python.el
(defalias 'mys-find-function 'mys-find-definition)
(defun mys--find-definition-question-type (symbol imports)
  (let (erg)
    (cond ((setq erg (mys-execute-string (concat "import inspect;inspect.isbuiltin(\"" symbol "\")"))))
	  (t (setq erg (mys-execute-string (concat imports "import inspect;inspect.getmodule(\"" symbol "\")")))))
    erg))

(defun mys-find-definition (&optional symbol)
  "Find source of definition of SYMBOL.

Interactively, prompt for SYMBOL."
  (interactive)
  ;; (set-register 98888888 (list (current-window-configuration) (point-marker)))
  (let* (;; end
	 ;; (last-window-configuration
         ;;  (current-window-configuration))
	 (orig (point))
         ;; (exception-buffer (current-buffer))
         (imports (mys-find-imports))
         (symbol-raw (or symbol (with-syntax-table mys-dotted-expression-syntax-table
				  (current-word))))
         ;; (enable-recursive-minibuffers t)
         (symbol (if (called-interactively-p 'interactive)
		     (read-string (format "Find location of (default %s): " symbol-raw)
		                  symbol-raw nil symbol-raw)
		   symbol-raw))
         (local (progn (goto-char (point-min)) (re-search-forward (concat "^[ \t]*" "\\(def\\|class\\)" "[ \t]" symbol) orig t))))
    ;; ismethod(), isclass(), isfunction() or isbuiltin()
    ;; ismethod isclass isfunction isbuiltin)
    (if local
        (progn
	  (goto-char orig)
	  (split-window-vertically)
	  (other-buffer)
	  (goto-char local)
	  (beginning-of-line)
          (push-mark)
	  (message "%s" (current-buffer))
	  (exchange-point-and-mark))
      (with-help-window (help-buffer)
	(princ (mys--find-definition-question-type symbol imports))))))

(defun mys-update-imports ()
  "Return imports.

Imports done are displayed in message buffer."
  (interactive)
  (save-excursion
    (let ((orig (point))
          (erg (mys-find-imports)))
      (goto-char orig)
      erg)))

;;  Code-Checker
;;  pep8
(defalias 'pep8 'mys-pep8-run)
(defun mys-pep8-run (command)
  "*Run pep8 using COMMAND, check formatting.
Default on the file currently visited."
  (interactive
   (let ((default
           (if (mys--buffer-filename-remote-maybe)
               (format "%s %s %s" mys-pep8-command
                       (mapconcat 'identity mys-pep8-command-args " ")
                       (mys--buffer-filename-remote-maybe))
             (format "%s %s" mys-pep8-command
                     (mapconcat 'identity mys-pep8-command-args " "))))
         (last (when mys-pep8-history
                 (let* ((lastcmd (car mys-pep8-history))
                        (cmd (cdr (reverse (split-string lastcmd))))
                        (newcmd (reverse (cons (mys--buffer-filename-remote-maybe) cmd))))
                   (mapconcat 'identity newcmd " ")))))

     (list
      (if (fboundp 'read-shell-command)
          (read-shell-command "Run pep8 like this: "
                              (if last
                                  last
                                default)
                              'mys-pep8-history)
        (read-string "Run pep8 like this: "
                     (if last
                         last
                       default)
                     'mys-pep8-history)))))
  (save-some-buffers (not mys-ask-about-save) nil)
  (if (fboundp 'compilation-start)
      ;; Emacs.
      (compilation-start command)
    ;; XEmacs.
    (when (featurep 'xemacs)
      (compile-internal command "No more errors"))))

(defun mys-pep8-help ()
  "Display pep8 command line help messages."
  (interactive)
  (set-buffer (get-buffer-create "*pep8-Help*"))
  (erase-buffer)
  (shell-command "pep8 --help" "*pep8-Help*"))

;;  Pylint
(defalias 'pylint 'mys-pylint-run)
(defun mys-pylint-run (command)
  "Run pylint from COMMAND.

Default on the file currently visited.

For help see \\[pylint-help] resp. \\[pylint-long-help].
Home-page: http://www.logilab.org/project/pylint"
  (interactive
   (let ((default (format "%s %s %s" mys-pylint-command
			  (mapconcat 'identity mys-pylint-command-args " ")
			  (mys--buffer-filename-remote-maybe)))
         (last (and mys-pylint-history (car mys-pylint-history))))
     (list (funcall (if (fboundp 'read-shell-command)
			'read-shell-command 'read-string)
		    "Run pylint like this: "
		    (or default last)
		    'mys-pylint-history))))
    (save-some-buffers (not mys-ask-about-save))
  (set-buffer (get-buffer-create "*Pylint*"))
  (erase-buffer)
  (unless (file-readable-p (car (cddr (split-string command))))
    (message "Warning: %s" "pylint needs a file"))
  (shell-command command "*Pylint*"))

(defalias 'pylint-help 'mys-pylint-help)
(defun mys-pylint-help ()
  "Display Pylint command line help messages.

Let's have this until more Emacs-like help is prepared"
  (interactive)
  (set-buffer (get-buffer-create "*Pylint-Help*"))
  (erase-buffer)
  (shell-command "pylint --long-help" "*Pylint-Help*"))

(defalias 'pylint-doku 'mys-pylint-doku)
(defun mys-pylint-doku ()
  "Display Pylint Documentation.

Calls `pylint --full-documentation'"
  (interactive)
  (set-buffer (get-buffer-create "*Pylint-Documentation*"))
  (erase-buffer)
  (shell-command "pylint --full-documentation" "*Pylint-Documentation*"))

;;  Pyflakes
(defalias 'pyflakes 'mys-pyflakes-run)
(defun mys-pyflakes-run (command)
  "*Run pyflakes on COMMAND.

Default on the file currently visited.

For help see \\[pyflakes-help] resp. \\[pyflakes-long-help].
Home-page: http://www.logilab.org/project/pyflakes"
  (interactive
   (let ((default
           (if (mys--buffer-filename-remote-maybe)
               (format "%s %s %s" mys-pyflakes-command
                       (mapconcat 'identity mys-pyflakes-command-args " ")
                       (mys--buffer-filename-remote-maybe))
             (format "%s %s" mys-pyflakes-command
                     (mapconcat 'identity mys-pyflakes-command-args " "))))
         (last (when mys-pyflakes-history
                 (let* ((lastcmd (car mys-pyflakes-history))
                        (cmd (cdr (reverse (split-string lastcmd))))
                        (newcmd (reverse (cons (mys--buffer-filename-remote-maybe) cmd))))
                   (mapconcat 'identity newcmd " ")))))

     (list
      (if (fboundp 'read-shell-command)
          (read-shell-command "Run pyflakes like this: "
                              (if last
                                  last
                                default)
                              'mys-pyflakes-history)
        (read-string "Run pyflakes like this: "
                     (if last
                         last
                       default)
                     'mys-pyflakes-history)))))
  (save-some-buffers (not mys-ask-about-save) nil)
  (if (fboundp 'compilation-start)
      ;; Emacs.
      (compilation-start command)
    ;; XEmacs.
    (when (featurep 'xemacs)
      (compile-internal command "No more errors"))))

(defalias 'pyflakes-help 'mys-pyflakes-help)
(defun mys-pyflakes-help ()
  "Display Pyflakes command line help messages."
  (interactive)
  ;; (set-buffer (get-buffer-create "*Pyflakes-Help*"))
  ;; (erase-buffer)
  (with-help-window "*Pyflakes-Help*"
    (with-current-buffer standard-output
      (insert "       pyflakes [file-or-directory ...]

       Pyflakes is a simple program which checks Python
       source files for errors. It is similar to
       PyChecker in scope, but differs in that it does
       not execute the modules to check them. This is
       both safer and faster, although it does not
       perform as many checks. Unlike PyLint, Pyflakes
       checks only for logical errors in programs; it
       does not perform any checks on style.

       All commandline arguments are checked, which
       have to be either regular files or directories.
       If a directory is given, every .py file within
       will be checked.

       When no commandline arguments are given, data
       will be read from standard input.

       The exit status is 0 when no warnings or errors
       are found. When errors are found the exit status
       is 2. When warnings (but no errors) are found
       the exit status is 1.

Extracted from http://manpages.ubuntu.com/manpages/natty/man1/pyflakes.1.html"))))

;;  Pyflakes-pep8
(defalias 'pyflakespep8 'mys-pyflakespep8-run)
(defun mys-pyflakespep8-run (command)
  "*Run COMMAND pyflakespep8, check formatting.

Default on the file currently visited."
  (interactive
   (let ((default
           (if (mys--buffer-filename-remote-maybe)
               (format "%s %s %s" mys-pyflakespep8-command
                       (mapconcat 'identity mys-pyflakespep8-command-args " ")
                       (mys--buffer-filename-remote-maybe))
             (format "%s %s" mys-pyflakespep8-command
                     (mapconcat 'identity mys-pyflakespep8-command-args " "))))
         (last (when mys-pyflakespep8-history
                 (let* ((lastcmd (car mys-pyflakespep8-history))
                        (cmd (cdr (reverse (split-string lastcmd))))
                        (newcmd (reverse (cons (mys--buffer-filename-remote-maybe) cmd))))
                   (mapconcat 'identity newcmd " ")))))

     (list
      (if (fboundp 'read-shell-command)
          (read-shell-command "Run pyflakespep8 like this: "
                              (if last
                                  last
                                default)
                              'mys-pyflakespep8-history)
        (read-string "Run pyflakespep8 like this: "
                     (if last
                         last
                       default)
                     'mys-pyflakespep8-history)))))
  (save-some-buffers (not mys-ask-about-save) nil)
  (if (fboundp 'compilation-start)
      ;; Emacs.
      (compilation-start command)
    ;; XEmacs.
    (when (featurep 'xemacs)
      (compile-internal command "No more errors"))))

(defun mys-pyflakespep8-help ()
  "Display pyflakespep8 command line help messages."
  (interactive)
  (set-buffer (get-buffer-create "*pyflakespep8-Help*"))
  (erase-buffer)
  (shell-command "pyflakespep8 --help" "*pyflakespep8-Help*"))

;;  Pychecker
;;  hack for GNU Emacs
;;  (unless (fboundp 'read-shell-command)
;;  (defalias 'read-shell-command 'read-string))

(defun mys-pychecker-run (command)
  "Run COMMAND pychecker (default on the file currently visited)."
  (interactive
   (let ((default
           (if (mys--buffer-filename-remote-maybe)
               (format "%s %s %s" mys-pychecker-command
		       mys-pychecker-command-args
		       (mys--buffer-filename-remote-maybe))
             (format "%s %s" mys-pychecker-command mys-pychecker-command-args)))
         (last (when mys-pychecker-history
                 (let* ((lastcmd (car mys-pychecker-history))
                        (cmd (cdr (reverse (split-string lastcmd))))
                        (newcmd (reverse (cons (mys--buffer-filename-remote-maybe) cmd))))
                   (mapconcat 'identity newcmd " ")))))

     (list
      (if (fboundp 'read-shell-command)
          (read-shell-command "Run pychecker like this: "
                              (if last
                                  last
                                default)
                              'mys-pychecker-history)
        (read-string "Run pychecker like this: "
                     (if last
                         last
                       default)
                     'mys-pychecker-history)))))
  (save-some-buffers (not mys-ask-about-save) nil)
  (if (fboundp 'compilation-start)
      ;; Emacs.
      (compilation-start command)
    ;; XEmacs.
    (when (featurep 'xemacs)
      (compile-internal command "No more errors"))))

;;  After `sgml-validate-command'.
(defun mys-check-command (command)
  "Check a Python file (default current buffer's file).
Runs COMMAND, a shell command, as if by `compile'.
See `mys-check-command' for the default."
  (interactive
   (list (read-string "Checker command: "
                      (concat mys-check-command " "
                              (let ((name (mys--buffer-filename-remote-maybe)))
                                (if name
                                    (file-name-nondirectory name)))))))
  (require 'compile)                    ;To define compilation-* variables.
  (save-some-buffers (not compilation-ask-about-save) nil)
  (let ((compilation-error-regexp-alist mys-compilation-regexp-alist)
	;; (cons '("(\\([^,]+\\), line \\([0-9]+\\))" 1)
	;; compilation-error-regexp-alist)
	)
    (compilation-start command)))

;;  flake8
(defalias 'flake8 'mys-flake8-run)
(defun mys-flake8-run (command)
  "COMMAND Flake8 is a wrapper around these tools:
- PyFlakes
        - pep8
        - Ned Batchelder's McCabe script

        It also adds features:
        - files that contain this line are skipped::
            # flake8: noqa
        - no-warn lines that contain a `# noqa`` comment at the end.
        - a Git and a Mercurial hook.
        - a McCabe complexity checker.
        - extendable through ``flake8.extension`` entry points."
  (interactive
   (let* ((mys-flake8-command
           (if (string= "" mys-flake8-command)
               (or (executable-find "flake8")
                   (error "Don't see \"flake8\" on your system.
Consider \"pip install flake8\" resp. visit \"pypi.python.org\""))
             mys-flake8-command))
          (default
            (if (mys--buffer-filename-remote-maybe)
                (format "%s %s %s" mys-flake8-command
                        mys-flake8-command-args
                        (mys--buffer-filename-remote-maybe))
              (format "%s %s" mys-flake8-command
                      mys-flake8-command-args)))
          (last
           (when mys-flake8-history
             (let* ((lastcmd (car mys-flake8-history))
                    (cmd (cdr (reverse (split-string lastcmd))))
                    (newcmd (reverse (cons (mys--buffer-filename-remote-maybe) cmd))))
               (mapconcat 'identity newcmd " ")))))
     (list
      (if (fboundp 'read-shell-command)
          (read-shell-command "Run flake8 like this: "
                              ;; (if last
                              ;; last
                              default
                              'mys-flake8-history1)
        (read-string "Run flake8 like this: "
                     (if last
                         last
                       default)
                     'mys-flake8-history)))))
  (save-some-buffers (not mys-ask-about-save) nil)
  (if (fboundp 'compilation-start)
      ;; Emacs.
      (compilation-start command)
    ;; XEmacs.
    (when (featurep 'xemacs)
      (compile-internal command "No more errors"))))

(defun mys-flake8-help ()
  "Display flake8 command line help messages."
  (interactive)
  (set-buffer (get-buffer-create "*flake8-Help*"))
  (erase-buffer)
  (shell-command "flake8 --help" "*flake8-Help*"))

;;  from string-strip.el --- Strip CHARS from STRING

(defun mys-nesting-level (&optional pps)
  "Accepts the output of `parse-partial-sexp' - PPS."
  (interactive)
  (let* ((pps (or (ignore-errors (nth 0 pps))
                  (if (featurep 'xemacs)
                      (parse-partial-sexp (point-min) (point))
                    (parse-partial-sexp (point-min) (point)))))
         (erg (nth 0 pps)))
    (when (and mys-verbose-p (called-interactively-p 'any)) (message "%s" erg))
    erg))

;;  Flymake
(defun mys-toggle-flymake-intern (name command)
  "Clear flymake allowed file-name masks.

Takes NAME COMMAND"
  (unless (string-match "pyflakespep8" name)
    (unless (executable-find name)
      (when mys-verbose-p (message "Don't see %s. Use `easy_install' %s? " name name))))
  (if (mys--buffer-filename-remote-maybe)
      (let* ((temp-file (if (functionp 'flymake-proc-init-create-temp-buffer-copy)
			    (flymake-proc-init-create-temp-buffer-copy 'flymake-create-temp-inplace)
			  (flymake-proc-init-create-temp-buffer-copy 'flymake-create-temp-inplace)
			  ))
             (local-file (file-relative-name
                          temp-file
                          (file-name-directory (mys--buffer-filename-remote-maybe)))))
	(if (boundp 'flymake-proc-allowed-file-name-masks)
            (push (car (read-from-string (concat "(\"\\.py\\'\" flymake-" name ")"))) flymake-proc-allowed-file-name-masks)
	  (push (car (read-from-string (concat "(\"\\.py\\'\" flymake-" name ")"))) flymake-proc-allowed-file-name-masks))
        (list command (list local-file)))
    (message "%s" "flymake needs a `file-name'. Please save before calling.")))

(defun pylint-flymake-mode ()
  "Toggle `pylint' `flymake-mode'."
  (interactive)
  (if flymake-mode
      ;; switch off
      (flymake-mode 0)
    (mys-toggle-flymake-intern "pylint" "pylint")
    (flymake-mode 1)))

(defun pyflakes-flymake-mode ()
  "Toggle `pyflakes' `flymake-mode'."
  (interactive)
  (if flymake-mode
      ;; switch off
      (flymake-mode)
    (mys-toggle-flymake-intern "pyflakes" "pyflakes")
    (flymake-mode)))

(defun pychecker-flymake-mode ()
  "Toggle `pychecker' `flymake-mode'."
  (interactive)
  (if flymake-mode
      ;; switch off
      (flymake-mode)
    (mys-toggle-flymake-intern "pychecker" "pychecker")
    (flymake-mode)))

(defun pep8-flymake-mode ()
  "Toggle `pep8’ `flymake-mode'."
  (interactive)
  (if flymake-mode
      ;; switch off
      (flymake-mode)
    (mys-toggle-flymake-intern "pep8" "pep8")
    (flymake-mode)))

(defun pyflakespep8-flymake-mode ()
  "Toggle `pyflakespep8’ `flymake-mode'.

Joint call to pyflakes and pep8 as proposed by
Keegan Carruthers-Smith"
  (interactive)
  (if flymake-mode
      ;; switch off
      (flymake-mode)
    (mys-toggle-flymake-intern "pyflakespep8" "pyflakespep8")
    (flymake-mode)))

(defun mys-display-state-of-variables ()
  "Read the state of `mys-mode' variables.

Assumes vars are defined in current source buffer"
  (interactive)
  (save-restriction
    (let (variableslist)
      (goto-char (point-min))
      ;; (eval-buffer)
      (while (and (not (eobp))(re-search-forward "^(defvar [[:alpha:]]\\|^(defcustom [[:alpha:]]\\|^(defconst [[:alpha:]]" nil t 1))
        (let* ((name (symbol-at-point))
               (state
                (unless
                    (or (eq name 'mys-menu)
                        (eq name 'mys-mode-map)
                        (string-match "syntax-table" (prin1-to-string name)))

                  (prin1-to-string (symbol-value name)))))
          (if state
              (push (cons (prin1-to-string name) state) variableslist)
            (message "don't see a state for %s" (prin1-to-string name))))
        (forward-line 1))
      (setq variableslist (nreverse variableslist))
      (set-buffer (get-buffer-create "State-of-Mys-mode-variables.org"))
      (erase-buffer)
      ;; org
      (insert "State of mys-mode variables\n\n")
      (switch-to-buffer (current-buffer))
      (dolist (ele variableslist)
        (if (string-match "^;;; " (car ele))
            (unless (or (string-match "^;;; Constants\\|^;;; Commentary\\|^;;; Code\\|^;;; Macro definitions\\|^;;; Customization" (car ele)))

              (insert (concat (replace-regexp-in-string "^;;; " "* " (car ele)) "\n")))
          (insert (concat "\n** "(car ele) "\n"))
          (insert (concat "   " (cdr ele) "\n\n")))
        ;; (richten)
        (sit-for 0.01 t))
      (sit-for 0.01 t))))

;; common typo
(defalias 'iypthon 'imys)
(defalias 'pyhton 'python)

;; mys-components-extensions

(defun mys-indent-forward-line (&optional arg)
  "Indent and move line forward to next indentation.
Returns column of line reached.

If `mys-kill-empty-line' is non-nil, delete an empty line.

With \\[universal argument] just indent.
"
  (interactive "*P")
  (let ((orig (point))
        erg)
    (unless (eobp)
      (if (and (mys--in-comment-p)(not mys-indent-comments))
          (forward-line 1)
        (mys-indent-line-outmost)
        (unless (eq 4 (prefix-numeric-value arg))
          (if (eobp) (newline)
            (progn (forward-line 1))
            (when (and mys-kill-empty-line (mys-empty-line-p) (not (looking-at "[ \t]*\n[[:alpha:]]")) (not (eobp)))
              (delete-region (line-beginning-position) (line-end-position)))))))
    (back-to-indentation)
    (when (or (eq 4 (prefix-numeric-value arg)) (< orig (point))) (setq erg (current-column)))
    erg))

(defun mys-dedent-forward-line (&optional arg)
  "Dedent line and move one line forward. "
  (interactive "*p")
  (mys-dedent arg)
  (if (eobp)
      (newline 1)
    (forward-line 1))
  (end-of-line))

(defun mys-dedent (&optional arg)
  "Dedent line according to `mys-indent-offset'.

With arg, do it that many times.
If point is between indent levels, dedent to next level.
Return indentation reached, if dedent done, nil otherwise.

Affected by `mys-dedent-keep-relative-column'. "
  (interactive "*p")
  (or arg (setq arg 1))
  (let ((orig (comys-marker (point)))
        erg)
    (dotimes (_ arg)
      (let* ((cui (current-indentation))
             (remain (% cui mys-indent-offset))
             (indent (* mys-indent-offset (/ cui mys-indent-offset))))
        (beginning-of-line)
        (fixup-whitespace)
        (if (< 0 remain)
            (indent-to-column indent)
          (indent-to-column (- cui mys-indent-offset)))))
    (when (< (point) orig)
      (setq erg (current-column)))
    (when mys-dedent-keep-relative-column (goto-char orig))
    erg))

(defun mys-class-at-point ()
  "Return class definition as string. "
  (interactive)
  (save-excursion
    (let* ((beg (mys-backward-class))
	   (end (mys-forward-class))
	   (res (when (and (numberp beg)(numberp end)(< beg end)) (buffer-substring-no-properties beg end))))
      res)))

(defun mys-backward-function ()
  "Jump to the beginning of defun.

Returns position. "
  (interactive "p")
  (mys-backward-def-or-class))

(defun mys-forward-function ()
  "Jump to the end of function.

Returns position."
  (interactive "p")
  (mys-forward-def-or-class))

(defun mys-function-at-point ()
  "Return functions definition as string. "
  (interactive)
  (save-excursion
    (let* ((beg (mys-backward-function))
	   (end (mys-forward-function)))
      (when (and (numberp beg)(numberp end)(< beg end)) (buffer-substring-no-properties beg end)))))

;; Functions for marking regions

(defun mys-line-at-point ()
  "Return line as string. "
  (interactive)
  (let* ((beg (line-beginning-position))
	 (end (line-end-position)))
    (when (and (numberp beg)(numberp end)(< beg end)) (buffer-substring-no-properties beg end))))

(defun mys-match-paren-mode (&optional arg)
  "mys-match-paren-mode nil oder t"
  (interactive "P")
  (if (or arg (not mys-match-paren-mode))
      (progn
	(setq mys-match-paren-mode t)
        (setq mys-match-paren-mode nil))))

(defun mys--match-end-finish (cui)
  (let (skipped)
    (unless (eq (current-column) cui)
      (when (< (current-column) cui)
	(setq skipped (skip-chars-forward " \t" (line-end-position)))
	(setq cui (- cui skipped))
	;; may current-column greater as needed indent?
	(if (< 0 cui)
	    (progn
	      (unless (mys-empty-line-p) (split-line))
	      (indent-to cui))
	  (forward-char cui))
	(unless (eq (char-before) 32)(insert 32)(forward-char -1))))))

(defun mys--match-paren-forward ()
  (setq mys--match-paren-forward-p t)
  (let ((cui (current-indentation)))
    (cond
     ((mys--beginning-of-top-level-p)
      (mys-forward-top-level-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-class-p)
      (mys-forward-class-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-def-p)
      (mys-forward-def-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-if-block-p)
      (mys-forward-if-block-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-try-block-p)
      (mys-forward-try-block-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-for-block-p)
      (mys-forward-for-block-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-block-p)
      (mys-forward-block-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-clause-p)
      (mys-forward-clause-bol)
      (mys--match-end-finish cui))
     ((mys--beginning-of-statement-p)
      (mys-forward-statement-bol)
      (mys--match-end-finish cui))
     (t (mys-forward-statement)
	(mys--match-end-finish cui)))))

(defun mys--match-paren-backward ()
  (setq mys--match-paren-forward-p nil)
  (let* ((cui (current-indentation))
	 (cuc (current-column))
	 (cui (min cuc cui)))
    (if (eq 0 cui)
	(mys-backward-top-level)
      (when (mys-empty-line-p) (delete-region (line-beginning-position) (point)))
      (mys-backward-statement)
      (unless (< (current-column) cuc)
      (while (and (not (bobp))
		  (< cui (current-column))
		  (mys-backward-statement)))))))

(defun mys--match-paren-blocks ()
  (cond
   ((and (looking-back "^[ \t]*" (line-beginning-position))(if (eq last-command 'mys-match-paren)(not mys--match-paren-forward-p)t)
	 ;; (looking-at mys-extended-block-or-clause-re)
	 (looking-at "[[:alpha:]_]"))
    ;; from beginning of top-level, block, clause, statement
    (mys--match-paren-forward))
   (t
    (mys--match-paren-backward))))

(defun mys-match-paren (&optional arg)
  "If at a beginning, jump to end and vice versa.

When called from within, go to the start.
Matches lists, but also block, statement, string and comment. "
  (interactive "*P")
  (if (eq 4 (prefix-numeric-value arg))
      (insert "%")
    (let ((pps (parse-partial-sexp (point-min) (point))))
      (cond
       ;; if inside string, go to beginning
       ((nth 3 pps)
	(goto-char (nth 8 pps)))
       ;; if inside comment, go to beginning
       ((nth 4 pps)
	(mys-backward-comment))
       ;; at comment start, go to end of commented section
       ((and
	 ;; unless comment starts where jumped to some end
	 (not mys--match-paren-forward-p)
	 (eq 11 (car-safe (syntax-after (point)))))
	(mys-forward-comment))
       ;; at string start, go to end
       ((or (eq 15 (car-safe (syntax-after (point))))
	    (eq 7 (car (syntax-after (point)))))
	(goto-char (scan-sexps (point) 1))
	(forward-char -1))
       ;; open paren
       ((eq 4 (car (syntax-after (point))))
	(goto-char (scan-sexps (point) 1))
	(forward-char -1))
       ((eq 5 (car (syntax-after (point))))
	(goto-char (scan-sexps (1+ (point)) -1)))
       ((nth 1 pps)
	(goto-char (nth 1 pps)))
       (t
	;; Python specific blocks
	(mys--match-paren-blocks))))))

(unless (functionp 'in-string-p)
  (defun in-string-p (&optional pos)
    (interactive)
    (let ((orig (or pos (point))))
      (save-excursion
        (save-restriction
          (widen)
          (beginning-of-defun)
          (numberp
           (progn
             (if (featurep 'xemacs)
                 (nth 3 (parse-partial-sexp (point) orig)
                      (nth 3 (parse-partial-sexp (point-min) (point))))))))))))

(defun mys-documentation (w)
  "Launch PyDOC on the Word at Point"
  (interactive
   (list (let* ((word (mys-symbol-at-point))
                (input (read-string
                        (format "pydoc entry%s: "
                                (if (not word) "" (format " (default %s)" word))))))
           (if (string= input "")
               (if (not word) (error "No pydoc args given")
                 word) ;sinon word
             input)))) ;sinon input
  (shell-command (concat mys-shell-name " -c \"from pydoc import help;help(\'" w "\')\"") "*PYDOCS*")
  (view-buffer-other-window "*PYDOCS*" t 'kill-buffer-and-window))

(defun pst-here ()
  "Kill previous \"pdb.set_trace()\" and insert it at point. "
  (interactive "*")
  (let ((orig (comys-marker (point))))
    (search-backward "pdb.set_trace()")
    (replace-match "")
    (when (mys-empty-line-p)
      (delete-region (line-beginning-position) (line-end-position)))
    (goto-char orig)
    (insert "pdb.set_trace()")))

(defun mys-printform-insert (&optional arg strg)
  "Inserts a print statement from `(car kill-ring)'.

With optional \\[universal-argument] print as string"
  (interactive "*P")
  (let* ((name (mys--string-strip (or strg (car kill-ring))))
         ;; guess if doublequotes or parentheses are needed
         (numbered (not (eq 4 (prefix-numeric-value arg))))
         (form (if numbered
		   (concat "print(\"" name ": %s \" % (" name "))")
		 (concat "print(\"" name ": %s \" % \"" name "\")"))))
    (insert form)))

(defun mys-print-formatform-insert (&optional strg)
  "Inserts a print statement out of current `(car kill-ring)' by default.

print(\"\\nfoo: {}\"\.format(foo))"
  (interactive "*")
  (let ((name (mys--string-strip (or strg (car kill-ring)))))
    (insert (concat "print(\"" name ": {}\".format(" name "))"))))

(defun mys-line-to-printform-python2 ()
  "Transforms the item on current in a print statement. "
  (interactive "*")
  (let* ((name (mys-symbol-at-point))
         (form (concat "print(\"" name ": %s \" % " name ")")))
    (delete-region (line-beginning-position) (line-end-position))
    (insert form))
  (forward-line 1)
  (back-to-indentation))

(defun mys-boolswitch ()
  "Edit the assignment of a boolean variable, revert them.

I.e. switch it from \"True\" to \"False\" and vice versa"
  (interactive "*")
  (save-excursion
    (unless (mys--end-of-statement-p)
      (mys-forward-statement))
    (backward-word)
    (cond ((looking-at "True")
           (replace-match "False"))
          ((looking-at "False")
           (replace-match "True"))
          (t (message "%s" "Can't see \"True or False\" here")))))

;; mys-components-imenu
;; Imenu definitions

(defvar mys-imenu-class-regexp
  (concat                               ; <<classes>>
   "\\("                                ;
   "^[ \t]*"                            ; newline and maybe whitespace
   "\\(class[ \t]+[a-zA-Z0-9_]+\\)"     ; class name
                                        ; possibly multiple superclasses
   "\\([ \t]*\\((\\([a-zA-Z0-9_,. \t\n]\\)*)\\)?\\)"
   "[ \t]*:"                            ; and the final :
   "\\)"                                ; >>classes<<
   )
  "Regexp for Python classes for use with the Imenu package."
  )

;; (defvar mys-imenu-method-regexp
;;   (concat                               ; <<methods and functions>>
;;    "\\("                                ;
;;    "^[ \t]*"                            ; new line and maybe whitespace
;;    "\\(def[ \t]+"                       ; function definitions start with def
;;    "\\([a-zA-Z0-9_]+\\)"                ;   name is here
;;                                         ;   function arguments...
;;    ;;   "[ \t]*(\\([-+/a-zA-Z0-9_=,\* \t\n.()\"'#]*\\))"
;;    "[ \t]*(\\([^:#]*\\))"
;;    "\\)"                                ; end of def
;;    "[ \t]*:"                            ; and then the :
;;    "\\)"                                ; >>methods and functions<<
;;    )
;;   "Regexp for Python methods/functions for use with the Imenu package."
;;   )

(defvar mys-imenu-method-regexp
  (concat                               ; <<methods and functions>>
   "\\("                                ;
   "^[ \t]*"                            ; new line and maybe whitespace
   "\\(def[ \t]+"                       ; function definitions start with def
   "\\([a-zA-Z0-9_]+\\)"                ;   name is here
                                        ;   function arguments...
   ;;   "[ \t]*(\\([-+/a-zA-Z0-9_=,\* \t\n.()\"'#]*\\))"
   "[ \t]*(\\(.*\\))"
   "\\)"                                ; end of def
   "[ \t]*:"                            ; and then the :
   "\\)"                                ; >>methods and functions<<
   )
  "Regexp for Python methods/functions for use with the Imenu package.")





(defvar mys-imenu-method-no-arg-parens '(2 8)
  "Indices into groups of the Python regexp for use with Imenu.

Using these values will result in smaller Imenu lists, as arguments to
functions are not listed.

See the variable `mys-imenu-show-method-args-p' for more
information.")

(defvar mys-imenu-method-arg-parens '(2 7)
  "Indices into groups of the Python regexp for use with imenu.
Using these values will result in large Imenu lists, as arguments to
functions are listed.

See the variable `mys-imenu-show-method-args-p' for more
information.")

;; Note that in this format, this variable can still be used with the
;; imenu--generic-function. Otherwise, there is no real reason to have
;; it.
(defvar mys-imenu-generic-expression
  (cons
   (concat
    mys-imenu-class-regexp
    "\\|"                               ; or...
    mys-imenu-method-regexp
    )
   mys-imenu-method-no-arg-parens)
  "Generic Python expression which may be used directly with Imenu.
Used by setting the variable `imenu-generic-expression' to this value.
Also, see the function \\[mys--imenu-create-index] for a better
alternative for finding the index.")


(defvar mys-imenu-generic-regexp nil)
(defvar mys-imenu-generic-parens nil)


(defun mys--imenu-create-index ()
  "Python interface function for the Imenu package.
Finds all Python classes and functions/methods. Calls function
\\[mys--imenu-create-index-engine].  See that function for the details
of how this works."
  (save-excursion
    (setq mys-imenu-generic-regexp (car mys-imenu-generic-expression)
	  mys-imenu-generic-parens (if mys-imenu-show-method-args-p
				      mys-imenu-method-arg-parens
				    mys-imenu-method-no-arg-parens))
    (goto-char (point-min))
    ;; Warning: When the buffer has no classes or functions, this will
    ;; return nil, which seems proper according to the Imenu API, but
    ;; causes an error in the XEmacs port of Imenu.  Sigh.
    (setq index-alist (cdr (mys--imenu-create-index-engine nil)))))

(defun mys--imenu-create-index-engine (&optional start-indent)
  "Function for finding Imenu definitions in Python.

Finds all definitions (classes, methods, or functions) in a Python
file for the Imenu package.

Returns a possibly nested alist of the form

        (INDEX-NAME . INDEX-POSITION)

The second element of the alist may be an alist, producing a nested
list as in

        (INDEX-NAME . INDEX-ALIST)

This function should not be called directly, as it calls itself
recursively and requires some setup.  Rather this is the engine for
the function \\[mys--imenu-create-index-function].

It works recursively by looking for all definitions at the current
indention level.  When it finds one, it adds it to the alist.  If it
finds a definition at a greater indentation level, it removes the
previous definition from the alist. In its place it adds all
definitions found at the next indentation level.  When it finds a
definition that is less indented then the current level, it returns
the alist it has created thus far.

The optional argument START-INDENT indicates the starting indentation
at which to continue looking for Python classes, methods, or
functions.  If this is not supplied, the function uses the indentation
of the first definition found."
  (let (index-alist
        sub-method-alist
        looking-p
        def-name prev-name
        cur-indent def-pos
        (class-paren (first mys-imenu-generic-parens))
        (def-paren (second mys-imenu-generic-parens)))
    ;; (switch-to-buffer (current-buffer))
    (setq looking-p
          (re-search-forward mys-imenu-generic-regexp (point-max) t))
    (while looking-p
      (save-excursion
        ;; used to set def-name to this value but generic-extract-name
        ;; is new to imenu-1.14. this way it still works with
        ;; imenu-1.11
        ;;(imenu--generic-extract-name mys-imenu-generic-parens))
        (let ((cur-paren (if (match-beginning class-paren)
                             class-paren def-paren)))
          (setq def-name
                (buffer-substring-no-properties (match-beginning cur-paren)
                                                (match-end cur-paren))))
        (save-match-data
          (mys-backward-def-or-class))
        (beginning-of-line)
        (setq cur-indent (current-indentation)))
      ;; HACK: want to go to the next correct definition location.  We
      ;; explicitly list them here but it would be better to have them
      ;; in a list.
      (setq def-pos
            (or (match-beginning class-paren)
                (match-beginning def-paren)))
      ;; if we don't have a starting indent level, take this one
      (or start-indent
          (setq start-indent cur-indent))
      ;; if we don't have class name yet, take this one
      (or prev-name
          (setq prev-name def-name))
      ;; what level is the next definition on?  must be same, deeper
      ;; or shallower indentation
      (cond
       ;; Skip code in comments and strings
       ((mys--in-literal))
       ;; at the same indent level, add it to the list...
       ((= start-indent cur-indent)
        (push (cons def-name def-pos) index-alist))
       ;; deeper indented expression, recurse
       ((< start-indent cur-indent)
        ;; the point is currently on the expression we're supposed to
        ;; start on, so go back to the last expression. The recursive
        ;; call will find this place again and add it to the correct
        ;; list
        (re-search-backward mys-imenu-generic-regexp (point-min) 'move)
        (setq sub-method-alist (mys--imenu-create-index-engine cur-indent))
        (if sub-method-alist
            ;; we put the last element on the index-alist on the start
            ;; of the submethod alist so the user can still get to it.
            (let* ((save-elmt (pop index-alist))
                   (classname (and (string-match "^class " (car save-elmt))(replace-regexp-in-string "^class " "" (car save-elmt)))))
              (if (and classname (not (string-match "^class " (caar sub-method-alist))))
                  (setcar (car sub-method-alist) (concat classname "." (caar sub-method-alist))))
              (push (cons prev-name
                          (cons save-elmt sub-method-alist))
                    index-alist))))
       (t
        (setq looking-p nil)
        (re-search-backward mys-imenu-generic-regexp (point-min) t)))
      ;; end-cond
      (setq prev-name def-name)
      (and looking-p
           (setq looking-p
                 (re-search-forward mys-imenu-generic-regexp
                                    (point-max) 'move))))
    (nreverse index-alist)))

(defun mys--imenu-create-index-new (&optional beg end)
  "`imenu-create-index-function' for Python. "
  (interactive)
  (set (make-local-variable 'imenu-max-items) mys-imenu-max-items)
  (let ((orig (point))
        (beg (or beg (point-min)))
        (end (or end (point-max)))
        index-alist vars thisend sublist classname pos name)
    (goto-char beg)
    (while (and (re-search-forward "^[ \t]*\\(def\\|class\\)[ \t]+\\(\\sw+\\)" end t 1)(not (nth 8 (parse-partial-sexp (point-min) (point)))))
      (if (save-match-data (string= "class" (match-string-no-properties 1)))
          (progn
            (setq pos (match-beginning 0)
                  name (match-string-no-properties 2)
                  classname (concat "class " name)
                  thisend (save-match-data (mys--end-of-def-or-class-position))
                  sublist '())
            (while (and (re-search-forward "^[ \t]*\\(def\\|class\\)[ \t]+\\(\\sw+\\)" (or thisend end) t 1)(not (nth 8 (parse-partial-sexp (point-min) (point)))))
              (let* ((pos (match-beginning 0))
                     (name (match-string-no-properties 2)))
		(push (cons (concat " " name) pos) sublist)))
            (if classname
                (progn
                  (setq sublist (nreverse sublist))
                  (push (cons classname pos) sublist)
                  (push (cons classname sublist) index-alist))
              (push sublist index-alist)))

        (let ((pos (match-beginning 0))
              (name (match-string-no-properties 2)))
          (push (cons name pos) index-alist))))
    ;; Look for module variables.
    (goto-char (point-min))
    (while (re-search-forward "^\\(\\sw+\\)[ \t]*=" end t)
      (unless (nth 8 (parse-partial-sexp (point-min) (point)))
        (let ((pos (match-beginning 1))
              (name (match-string-no-properties 1)))
          (push (cons name pos) vars))))
    (setq index-alist (nreverse index-alist))
    (when vars
      (push (cons "Module variables"
                  (nreverse vars))
            index-alist))
    (goto-char orig)
    index-alist))

;; A modified slice from python.el
(defvar mys-imenu-format-item-label-function
  'mys-imenu-format-item-label
  "Imenu function used to format an item label.
It must be a function with two arguments: TYPE and NAME.")

(defvar mys-imenu-format-parent-item-label-function
  'mys-imenu-format-parent-item-label
  "Imenu function used to format a parent item label.
It must be a function with two arguments: TYPE and NAME.")

(defvar mys-imenu-format-parent-item-jump-label-function
  'mys-imenu-format-parent-item-jump-label
  "Imenu function used to format a parent jump item label.
It must be a function with two arguments: TYPE and NAME.")

(defun mys-imenu-format-item-label (type name)
  "Return Imenu label for single node using TYPE and NAME."
  (format "%s (%s)" name type))

(defun mys-imenu-format-parent-item-label (type name)
  "Return Imenu label for parent node using TYPE and NAME."
  (format "%s..." (mys-imenu-format-item-label type name)))

;; overengineering?
(defun mys-imenu-format-parent-item-jump-label (type _name)
  "Return Imenu label for parent node jump using TYPE and NAME."
  (if (string= type "class")
      "*class definition*"
    "*function definition*"))

(defun mys-imenu--put-parent (type name pos tree)
  "Add the parent with TYPE, NAME and POS to TREE."
  (let* ((label
         (funcall mys-imenu-format-item-label-function type name))
        ;; (jump-label
	;; (funcall mys-imenu-format-parent-item-jump-label-function type name))
	(jump-label label
         ;; (funcall mys-imenu-format-parent-item-jump-label-function type name)
	 )
	)
    (if (not tree)
        (cons label pos)
      (cons label (cons (cons jump-label pos) tree)))))

(defun mys-imenu--build-tree (&optional min-indent prev-indent tree)
  "Recursively build the tree of nested definitions of a node.
Arguments MIN-INDENT, PREV-INDENT and TREE are internal and should
not be passed explicitly unless you know what you are doing."
  (setq min-indent (or min-indent 0)
        prev-indent (or prev-indent mys-indent-offset))
  (save-restriction
    (narrow-to-region (point-min) (point))
    (let* ((pos
	    (progn
	      ;; finds a top-level class
	      (mys-backward-def-or-class)
	      ;; stops behind the indented form at EOL
	      (mys-forward-def-or-class)
	      ;; may find an inner def-or-class
	      (mys-backward-def-or-class)))
	   type
	   (name (when (and pos (looking-at mys-def-or-class-re))
		   (let ((split (split-string (match-string-no-properties 0))))
		     (setq type (car split))
		     (cadr split))))
	   (label (when name
		    (funcall mys-imenu-format-item-label-function type name)))
	   (indent (current-indentation))
	   (children-indent-limit (+ mys-indent-offset min-indent)))
      (cond ((not pos)
	     ;; Nothing found, probably near to bobp.
	     nil)
	    ((<= indent min-indent)
	     ;; The current indentation points that this is a parent
	     ;; node, add it to the tree and stop recursing.
	     (mys-imenu--put-parent type name pos tree))
	    (t
	     (mys-imenu--build-tree
	      min-indent
	      indent
	      (if (<= indent children-indent-limit)
		  (cons (cons label pos) tree)
		(cons
		 (mys-imenu--build-tree
		  prev-indent indent (list (cons label pos)))
		 tree))))))))

(defun mys--imenu-index ()
  "Return tree Imenu alist for the current Python buffer. "
  (save-excursion
    (goto-char (point-max))
    (let ((index)
	  (tree))
      (while (setq tree (mys-imenu--build-tree))
	(setq index (cons tree index)))
      index)))

;; mys-components-electric
(defun mys-electric-colon (arg)
  "Insert a colon and indent accordingly.

If a numeric argument ARG is provided, that many colons are inserted
non-electrically.

Electric behavior is inhibited inside a string or
comment or by universal prefix \\[universal-argument].

Switched by `mys-electric-colon-active-p', default is nil
See also `mys-electric-colon-greedy-p'"
  (interactive "*P")
  (cond
   ((not mys-electric-colon-active-p)
    (self-insert-command (prefix-numeric-value arg)))
   ;;
   ((and mys-electric-colon-bobl-only
         (save-excursion
           (mys-backward-statement)
           (not (mys--beginning-of-block-p))))
    (self-insert-command (prefix-numeric-value arg)))
   ;;
   ((eq 4 (prefix-numeric-value arg))
    (self-insert-command 1))
   ;;
   (t
    (insert ":")
    (unless (mys-in-string-or-comment-p)
      (let ((orig (comys-marker (point)))
            (indent (mys-compute-indentation)))
        (unless (or (eq (current-indentation) indent)
                    (and mys-electric-colon-greedy-p
                         (eq indent
                             (save-excursion
                               (mys-backward-statement)
                               (current-indentation))))
                    (and (looking-at mys-def-or-class-re)
                         (< (current-indentation) indent)))
          (beginning-of-line)
          (delete-horizontal-space)
          (indent-to indent))
        (goto-char orig))
      (when mys-electric-colon-newline-and-indent-p
        (mys-newline-and-indent))))))

;; TODO: PRouleau: I would like to better understand this.
;;                 I don't understand the docstring.
;;                 What was the completion bug this is reacting to?
(defun mys-electric-close (arg)
  "Close completion buffer when no longer needed.

It is it's sure, it's no longer needed, i.e. when inserting a space.

Works around a bug in `choose-completion'."

  (interactive "*P")
  (cond
   ((not mys-electric-close-active-p)
    (self-insert-command (prefix-numeric-value arg)))
   ;;
   ((eq 4 (prefix-numeric-value arg))
    (self-insert-command 1))
   ;;
   (t (if (called-interactively-p 'any)
          (self-insert-command (prefix-numeric-value arg))
        ;; used from dont-indent-code-unnecessarily-lp-1048778-test
        (insert " ")))))

;; TODO: PRouleau: describe the electric behavior of '#'.
;;       This description should be in docstring of the
;;       `mys-electric-comment-p' user option and be referred to here.
;;       I currently don't understand what it should be and prefer not
;;       having to infer it from code.
;;       - From what I saw, the intent is to align the comment being
;;         typed to the one on line above or at the indentation level.
;;         - Is there more to it it than that?
;;         - I would like to see the following added (possibly via options):
;;           - When inserting the '#' follow it with a space, such that
;;             comment text is separated from the leading '#' by one space, as
;;             recommended in PEP-8
;;             URL https://www.python.org/dev/peps/pep-0008/#inline-comments
(defun mys-electric-comment (arg)
  "Insert a comment.  If starting a comment, indent accordingly.

If a numeric argument ARG is provided, that many \"#\" are inserted
non-electrically.
With \\[universal-argument] \"#\" electric behavior is inhibited inside a
string or comment."
  (interactive "*P")
  (if (and mys-indent-comments mys-electric-comment-p)
      (if (ignore-errors (eq 4 (car-safe arg)))
          (insert "#")
        (when (and (eq last-command 'mys-electric-comment)
                   (looking-back " " (line-beginning-position)))
          (forward-char -1))
        (if (called-interactively-p 'any)
            (self-insert-command (prefix-numeric-value arg))
          (insert "#"))
        (let ((orig (comys-marker (point)))
              (indent (mys-compute-indentation)))
          (unless (eq (current-indentation) indent)
            (goto-char orig)
            (beginning-of-line)
            (delete-horizontal-space)
            (indent-to indent)
            (goto-char orig))
          (when mys-electric-comment-add-space-p
            (unless (looking-at "[ \t]")
              (insert " "))))
        (setq last-command this-command))
    (self-insert-command (prefix-numeric-value arg))))

;; Electric deletion
(defun mys-empty-out-list-backward ()
  "Deletes all elements from list before point."
  (interactive "*")
  (and (member (char-before) (list ?\) ?\] ?\}))
       (let ((orig (point))
             (thischar (char-before))
             pps cn)
         (forward-char -1)
         (setq pps (parse-partial-sexp (point-min) (point)))
         (if (and (not (nth 8 pps)) (nth 1 pps))
             (progn
               (goto-char (nth 1 pps))
               (forward-char 1))
           (cond ((or (eq thischar 41)(eq thischar ?\)))
                  (setq cn "("))
                 ((or (eq thischar 125) (eq thischar ?\}))
                  (setq cn "{"))
                 ((or (eq thischar 93)(eq thischar ?\]))
                  (setq cn "[")))
           (skip-chars-backward (concat "^" cn)))
         (delete-region (point) orig)
         (insert-char thischar 1)
         (forward-char -1))))

;; TODO: PRouleau Question: [...]

;;       - Also, the mapping for [backspace] in mys-mode-map only works in
;;         graphics mode, it does not work when Emacs runs in terminal mode.
;;         It would be nice to have a binding that works in terminal mode too.
;; keep-one handed over form `mys-electric-delete' maybe
(defun mys-electric-backspace (&optional arg)
  "Delete one or more of whitespace chars left from point.
Honor indentation.

If called at whitespace below max indentation,

Delete region when both variable `delete-active-region' and `use-region-p'
are non-nil.

With \\[universal-argument], deactivate electric-behavior this time,
delete just one character before point.

At no-whitespace character, delete one before point.

"
  (interactive "*P")
  (unless (bobp)
    (let ((backward-delete-char-untabify-method 'untabify)
	  indent
	  done)
      (cond
       ;; electric-pair-mode
       ((and electric-pair-mode
             (or
              (and
               (ignore-errors (eq 5 (car (syntax-after (point)))))
               (ignore-errors (eq 4 (car (syntax-after (1- (point)))))))
              (and
               (ignore-errors (eq 7 (car (syntax-after (point)))))
               (ignore-errors (eq 7 (car (syntax-after (1- (point)))))))))
      (delete-char 1)
      (backward-delete-char-untabify 1))
       ((eq 4 (prefix-numeric-value arg))
	(backward-delete-char-untabify 1))
       ((use-region-p)
        ;; Emacs23 doesn't know that var
        (if (boundp 'delete-active-region)
	    (delete-active-region)
	  (delete-region (region-beginning) (region-end))))
       ((looking-back "[[:graph:]]" (line-beginning-position))
	(backward-delete-char-untabify 1))
       ;; before code
       ((looking-back "^[ \t]+" (line-beginning-position))
        (setq indent (mys-compute-indentation))
	(cond ((< indent (current-indentation))
	       (back-to-indentation)
	       (delete-region (line-beginning-position) (point))
	       (indent-to indent))
	      ((<=  (current-column) mys-indent-offset)
	       (delete-region (line-beginning-position) (point)))
	      ((eq 0 (% (current-column) mys-indent-offset))
	       (delete-region (point) (progn (backward-char mys-indent-offset) (point))))
	      (t (delete-region
		  (point)
		  (progn
		    ;; go backward the remainder
		    (backward-char (% (current-column) mys-indent-offset))
		    (point))))))
       ((looking-back "[[:graph:]][ \t]+" (line-beginning-position))
	;; in the middle fixup-whitespace
	(setq done (line-end-position))
	(fixup-whitespace)
	;; if just one whitespace at point, delete that one
	(or (< (line-end-position) done) (delete-char 1)))

       ;; (if (< 1 (abs (skip-chars-backward " \t")))
       ;; 		 (delete-region (point) (progn (skip-chars-forward " \t") (point)))
       ;; 	       (delete-char 1))

       ((bolp)
	(backward-delete-char 1))
       (t
	(mys-indent-line nil t))))))

(defun mys-electric-delete (&optional arg)
  "Delete one or more of whitespace chars right from point.
Honor indentation.

Delete region when both variable `delete-active-region' and `use-region-p'
are non-nil.

With \\[universal-argument], deactivate electric-behavior this time,
delete just one character at point.

At spaces in line of code, call fixup-whitespace.
At no-whitespace char, delete one char at point.
"
  (interactive "P*")
  (unless (eobp)
    (let* (;; mys-ert-deletes-too-much-lp:1300270-dMegYd
	   ;; x = {'abc':'def',
           ;;     'ghi':'jkl'}
	   (backward-delete-char-untabify-method 'untabify)
	   (indent (mys-compute-indentation))
	   ;; (delpos (+ (line-beginning-position) indent))
	   ;; (line-end-pos (line-end-position))
	   ;; (orig (point))
	   done)
      (cond
       ((eq 4 (prefix-numeric-value arg))
	(delete-char 1))
       ;; delete active region if one is active
       ((use-region-p)
	;; Emacs23 doesn't know that var
	(if (boundp 'delete-active-region)
            (delete-active-region)
	  (delete-region (region-beginning) (region-end))))
       ((looking-at "[[:graph:]]")
	(delete-char 1))
       ((or (eolp) (looking-at "[ \t]+$"))
	(cond
	 ((eolp) (delete-char 1))
	 ((< (+ indent (line-beginning-position)) (line-end-position))
	  (end-of-line)
	  (while (and (member (char-before) (list 9 32 ?\r))
		      (< indent (current-column)))
	    (backward-delete-char-untabify 1)))))
       (;; before code
	(looking-at "[ \t]+[[:graph:]]")
	;; before indent
	(if (looking-back "^[ \t]*" (line-beginning-position))
	    (cond ((< indent (current-indentation))
		   (back-to-indentation)
		   (delete-region (line-beginning-position) (point))
		   (indent-to indent))
		  ((< 0 (% (current-indentation) mys-indent-offset))
		   (back-to-indentation)
		   (delete-region (point) (progn (backward-char (% (current-indentation) mys-indent-offset)) (point))))
		  ((eq 0 (% (current-indentation) mys-indent-offset))
		   (back-to-indentation)
		   (delete-region (point) (progn (backward-char mys-indent-offset) (point))))
		  (t
		   (skip-chars-forward " \t")
		   (delete-region (line-beginning-position) (point))))
	  ;; in the middle fixup-whitespace
	  (setq done (line-end-position))
	  (fixup-whitespace)
	  ;; if just one whitespace at point, delete that one
	  (or (< (line-end-position) done) (delete-char 1))))
       (t (delete-char 1))))))

;; TODO: PRouleau: the electric yank mechanism is currently commented out.
;;       Is this a feature to keep?  Was it used?  I can see a benefit for it.
;;       Why is it currently disabled?
(defun mys-electric-yank (&optional arg)
  "Perform command `yank' followed by an `indent-according-to-mode'.
Pass ARG to the command `yank'."
  (interactive "P")
  (cond
   (mys-electric-yank-active-p
    (yank arg)
    ;; (mys-indent-line)
    )
   (t
    (yank arg))))

(defun mys-toggle-mys-electric-colon-active ()
  "Toggle use of electric colon for Python code."
  (interactive)
  (setq mys-electric-colon-active-p (not mys-electric-colon-active-p))
  (when (and mys-verbose-p (called-interactively-p 'interactive)) (message "mys-electric-colon-active-p: %s" mys-electric-colon-active-p)))

;; TODO: PRouleau: It might be beneficial to have toggle commands for all
;;       the electric behaviours, not just the electric colon.

;; required for pending-del and delsel modes
(put 'mys-electric-colon 'delete-selection t) ;delsel
(put 'mys-electric-colon 'pending-delete t) ;pending-del
(put 'mys-electric-backspace 'delete-selection 'supersede) ;delsel
(put 'mys-electric-backspace 'pending-delete 'supersede) ;pending-del
(put 'mys-electric-delete 'delete-selection 'supersede) ;delsel
(put 'mys-electric-delete 'pending-delete 'supersede) ;pending-del

;; mys-components-virtualenv

(defvar virtualenv-workon-home nil)

(defvar virtualenv-name nil)

(defvar virtualenv-old-path nil)

(defvar virtualenv-old-exec-path nil)

(if (getenv "WORKON_HOME")
    (setq virtualenv-workon-home (getenv "WORKON_HOME"))
  (setq virtualenv-workon-home "~/.virtualenvs"))

;;TODO: Move to a generic UTILITY or TOOL package
(defun virtualenv-filter (predicate sequence)
  "Return a list of each SEQUENCE element for which the PREDICATE is non-nil.
The order of elements in SEQUENCE is retained."
  (let ((retlist '()))
    (dolist (element sequence (nreverse retlist))
      (when (funcall predicate element)
        (push element retlist)))))

(defun virtualenv-append-path (dir var)
  "Append DIR to a path-like variable VAR.

For example:
>>> (virtualenv-append-path \"/usr/bin:/bin\" \"/home/test/bin\")
\"/home/test/bin:/usr/bin:/bin\""
  (concat (expand-file-name dir)
          path-separator
          var))

(defun virtualenv-add-to-path (dir)
  "Add the specified DIR path element to the Emacs PATH."
  (setenv "PATH"
          (virtualenv-append-path dir
                                  (getenv "PATH"))))

(defun virtualenv-current ()
  "Display the current activated virtualenv."
  (interactive)
  (message virtualenv-name))

(defun virtualenv-activate (dir)
  "Activate the virtualenv located in specified DIR."
  (interactive "DVirtualenv Directory: ")
  ;; Eventually deactivate previous virtualenv
  (when virtualenv-name
    (virtualenv-deactivate))
  (let ((cmd (concat "source " dir "/bin/activate\n")))
    (comint-send-string (get-process (get-buffer-process "*shell*")) cmd)
    ;; Storing old variables
    (setq virtualenv-old-path (getenv "PATH"))
    (setq virtualenv-old-exec-path exec-path)

    (setenv "VIRTUAL_ENV" dir)
    (virtualenv-add-to-path (concat (mys--normalize-directory dir) "bin"))
    (push (concat (mys--normalize-directory dir) "bin")  exec-path)

    (setq virtualenv-name dir)))

(defun virtualenv-deactivate ()
  "Deactivate the current virtual environment."
  (interactive)
  ;; Restoring old variables
  (setenv "PATH" virtualenv-old-path)
  (setq exec-path virtualenv-old-exec-path)
  (message (concat "Virtualenv '" virtualenv-name "' deactivated."))
  (setq virtualenv-name nil))

(defun virtualenv-p (dir)
  "Check if a directory DIR is a virtualenv."
  (file-exists-p (concat dir "/bin/activate")))

(defun virtualenv-workon-complete ()
  "Return available completions for `virtualenv-workon'."
  (let
      ;;Varlist
      ((filelist (directory-files virtualenv-workon-home t)))
    ;; Get only the basename from the list of the virtual environments
    ;; paths
    (mapcar
     'file-name-nondirectory
     ;; Filter the directories and then the virtual environments
     (virtualenv-filter 'virtualenv-p
                        (virtualenv-filter 'file-directory-p filelist)))))

(defun virtualenv-workon (name)
  "Issue a virtualenvwrapper-like virtualenv-workon NAME command."
  (interactive (list (completing-read "Virtualenv: "
                                      (virtualenv-workon-complete))))
  (if (getenv "WORKON_HOME")
      (virtualenv-activate (concat (mys--normalize-directory
                                    (getenv "WORKON_HOME")) name))
    (virtualenv-activate (concat
                          (mys--normalize-directory virtualenv-workon-home)
                          name))))

;; mys-abbrev-propose

(defun mys-edit-abbrevs ()
  "Jumps to `mys-mode-abbrev-table'."
  (interactive)
  (save-excursion
    (let ((mat (abbrev-table-name local-abbrev-table)))
      (prepare-abbrev-list-buffer)
      (set-buffer "*Abbrevs*")
      (switch-to-buffer (current-buffer))
      (goto-char (point-min))
      (search-forward (concat "(" (format "%s" mat))))))

(defun mys--add-abbrev-propose (table type arg &optional dont-ask)
  (save-excursion
    (let ((orig (point))
          proposal exp name)
      (while (< 0 arg)
        (mys-backward-partial-expression)
        (when (looking-at "[[:alpha:]]")
          (setq proposal (concat (downcase (match-string-no-properties 0)) proposal)))
        (setq arg (1- arg)))
      (setq exp (buffer-substring-no-properties (point) orig))
      (setq name
            ;; ask only when interactive
            (if dont-ask
                proposal
              (read-string (format (if exp "%s abbrev for \"%s\": "
                                     "Undefine %s abbrev: ")
                                   type exp) proposal)))
      (set-text-properties 0 (length name) nil name)
      (when (or (null exp)
                (not (abbrev-expansion name table))
                (y-or-n-p (format "%s expands to \"%s\"; redefine? "
                                  name (abbrev-expansion name table))))
        (define-abbrev table (downcase name) exp)))))

(defun mys-add-abbrev (arg)
  "Defines mys-mode specific abbrev."
  (interactive "p")
  (save-excursion
    (mys--add-abbrev-propose
     (if only-global-abbrevs
         global-abbrev-table
       (or local-abbrev-table
           (error "No per-mode abbrev table")))
     "Mode" arg)))

;; mys-components-paragraph

(defun mys-fill-paren (&optional justify)
  "Paren fill function for `mys-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'."
  (interactive "*P")
  (save-restriction
    (save-excursion
      (let ((pps (parse-partial-sexp (point-min) (point))))
	(if (nth 1 pps)
	    (let* ((beg (comys-marker (nth 1 pps)))
		   (end (and beg (save-excursion (goto-char (nth 1 pps))
						 (forward-list))))
		   (paragraph-start "\f\\|[ \t]*$")
		   (paragraph-separate ","))
	      (when (and beg end (narrow-to-region beg end))
		(fill-region beg end justify)
		(while (not (eobp))
		  (forward-line 1)
		  (mys-indent-line)
		  (goto-char (line-end-position))))))))))

(defun mys-fill-string-django (&optional justify)
  "Fill docstring according to Django's coding standards style.

    \"\"\"
    Process foo, return bar.
    \"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

See available styles at `mys-fill-paragraph' or var `mys-docstring-style'
"
  (interactive "*P")
  (mys-fill-string justify 'django t))

(defun mys-fill-string-onetwo (&optional justify)
  "One newline and start and Two at end style.

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

See available styles at `mys-fill-paragraph' or var `mys-docstring-style'
"
  (interactive "*P")
  (mys-fill-string justify 'onetwo t))

(defun mys-fill-string-pep-257 (&optional justify)
  "PEP-257 with 2 newlines at end of string.

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

See available styles at `mys-fill-paragraph' or var `mys-docstring-style'
"
  (interactive "*P")
  (mys-fill-string justify 'pep-257 t))

(defun mys-fill-string-pep-257-nn (&optional justify)
  "PEP-257 with 1 newline at end of string.

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

See available styles at `mys-fill-paragraph' or var `mys-docstring-style'
"
  (interactive "*P")
  (mys-fill-string justify 'pep-257-nn t))

(defun mys-fill-string-symmetric (&optional justify)
  "Symmetric style.

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

See available styles at `mys-fill-paragraph' or var `mys-docstring-style'
"
  (interactive "*P")
  (mys-fill-string justify 'symmetric t))

(defun mys-set-nil-docstring-style ()
  "Set mys-docstring-style to \\='nil"
  (interactive)
  (setq mys-docstring-style 'nil)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-set-pep-257-nn-docstring-style ()
  "Set mys-docstring-style to \\='pep-257-nn"
  (interactive)
  (setq mys-docstring-style 'pep-257-nn)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-set-pep-257-docstring-style ()
  "Set mys-docstring-style to \\='pep-257"
  (interactive)
  (setq mys-docstring-style 'pep-257)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-set-django-docstring-style ()
  "Set mys-docstring-style to \\='django"
  (interactive)
  (setq mys-docstring-style 'django)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-set-symmetric-docstring-style ()
  "Set mys-docstring-style to \\='symmetric"
  (interactive)
  (setq mys-docstring-style 'symmetric)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-set-onetwo-docstring-style ()
  "Set mys-docstring-style to \\='onetwo"
  (interactive)
  (setq mys-docstring-style 'onetwo)
  (when (and (called-interactively-p 'any) mys-verbose-p)
    (message "docstring-style set to:  %s" mys-docstring-style)))

(defun mys-fill-comment (&optional justify)
  "Fill the comment paragraph at point"
  (interactive "*P")
  (let (;; Non-nil if the current line contains a comment.
        has-comment

        ;; If has-comment, the appropriate fill-prefix (format "%s" r the comment.
        comment-fill-prefix)

    ;; Figure out what kind of comment we are looking at.
    (save-excursion
      (beginning-of-line)
      (cond
       ;; A line with nothing but a comment on it?
       ((looking-at "[ \t]*#[# \t]*")
        (setq has-comment t
              comment-fill-prefix (buffer-substring (match-beginning 0)
                                                    (match-end 0))))

       ;; A line with some code, followed by a comment? Remember that the hash
       ;; which starts the comment shouldn't be part of a string or character.
       ((progn
          (while (not (looking-at "#\\|$"))
            (skip-chars-forward "^#\n\"'\\")
            (cond
             ((eq (char-after (point)) ?\\) (forward-char 2))
             ((memq (char-after (point)) '(?\" ?')) (forward-sexp 1))))
          (looking-at "#+[\t ]*"))
        (setq has-comment t)
        (setq comment-fill-prefix
              (concat (make-string (current-column) ? )
                      (buffer-substring (match-beginning 0) (match-end 0)))))))

    (if (not has-comment)
        (fill-paragraph justify)

      ;; Narrow to include only the comment, and then fill the region.
      (save-restriction
        (narrow-to-region

         ;; Find the first line we should include in the region to fill.
         (save-excursion
           (while (and (zerop (forward-line -1))
                       (looking-at "^[ \t]*#")))

           ;; We may have gone to far.  Go forward again.
           (or (looking-at "^[ \t]*#")
               (forward-line 1))
           (point))

         ;; Find the beginning of the first line past the region to fill.
         (save-excursion
           (while (progn (forward-line 1)
                         (looking-at "^[ \t]*#")))
           (point)))

        ;; Lines with only hashes on them can be paragraph boundaries.
        (let ((paragraph-start (concat paragraph-start "\\|[ \t#]*$"))
              (paragraph-separate (concat paragraph-separate "\\|[ \t#]*$"))
              (fill-prefix comment-fill-prefix))
          (fill-paragraph justify))))
    t))

(defun mys-fill-labelled-string (beg end)
  "Fill string or paragraph containing lines starting with label

See lp:1066489 "
  (interactive "r*")
  (let ((end (comys-marker end))
        (last (comys-marker (point)))
        this-beg)
    (save-excursion
      (save-restriction
        ;; (narrow-to-region beg end)
        (goto-char beg)
        (skip-chars-forward " \t\r\n\f")
        (if (looking-at mys-labelled-re)
            (progn
              (setq this-beg (line-beginning-position))
              (goto-char (match-end 0))
              (while (and (not (eobp)) (re-search-forward mys-labelled-re end t 1)(< last (match-beginning 0))(setq last (match-beginning 0)))
                (save-match-data (fill-region this-beg (1- (line-beginning-position))))
                (setq this-beg (line-beginning-position))
                (goto-char (match-end 0)))))))))

(defun mys--in-or-behind-or-before-a-docstring (pps)
  (interactive "*")
  (save-excursion
    (let* ((strg-start-pos (when (nth 3 pps) (nth 8 pps)))
	   (n8pps (or strg-start-pos
		      (when
			  (equal (string-to-syntax "|")
				 (syntax-after (point)))
			(and
			 (< 0 (skip-chars-forward "\"'"))
			 (nth 3 (parse-partial-sexp (point-min) (point))))))))
      (and n8pps (mys--docstring-p n8pps)))))

(defun mys--string-fence-delete-spaces (&optional start)
  "Delete spaces following or preceding delimiters of string at point. "
  (interactive "*")
  (let ((beg (or start (nth 8 (parse-partial-sexp (point-min) (point))))))
    (save-excursion
      (goto-char beg)
      (skip-chars-forward "\"'rRuU")
      (delete-region (point) (progn (skip-chars-forward " \t\r\n\f")(point)))
      (goto-char beg)
      (forward-char 1)
      (skip-syntax-forward "^|")
      (skip-chars-backward "\"'rRuU")
      ;; (delete-region (point) (progn (skip-chars-backward " \t\r\n\f")(point)))
)))

(defun mys--skip-raw-string-front-fence ()
  "Skip forward chars u, U, r, R followed by string-delimiters. "
  (when (member (char-after) (list ?u ?U ?r ?R))
    (forward-char 1))
  (skip-chars-forward "\'\""))

(defun mys--fill-fix-end (thisend orig delimiters-style)
  ;; Add the number of newlines indicated by the selected style
  ;; at the end.
  ;; (widen)
  (goto-char thisend)
  (skip-chars-backward "\"'\n ")
  (delete-region (point) (progn (skip-chars-forward " \t\r\n\f") (point)))
  (unless (eq (char-after) 10)
    (and
     (cdr delimiters-style)
     (or (newline (cdr delimiters-style)) t)))
  (mys-indent-line nil t)
  (goto-char orig))

(defun mys--fill-docstring-last-line (thisend beg end multi-line-p)
  (widen)
  ;; (narrow-to-region thisbeg thisend)
  (goto-char thisend)
  (skip-chars-backward "\"'")
  (delete-region (point) (progn (skip-chars-backward " \t\r\n\f")(point)))
  ;; (narrow-to-region beg end)
  (fill-region beg end)
  (setq multi-line-p (string-match "\n" (buffer-substring-no-properties beg end)))
  (when multi-line-p
    ;; adjust the region to fill according to style
    (goto-char end)))

(defun mys--fill-docstring-base (thisbeg thisend style multi-line-p beg end mys-current-indent orig)
  ;; (widen)
  ;; fill-paragraph causes wrong indent, lp:1397936
  ;; (narrow-to-region thisbeg thisend)
  (let ((delimiters-style
	 (pcase style
	   ;; delimiters-style is a cons cell with the form
	   ;; (START-NEWLINES .  END-NEWLINES). When any of the sexps
	   ;; is NIL means to not add any newlines for start or end
	   ;; of docstring.  See `mys-docstring-style' for a
	   ;; graphic idea of each style.
	   (`django (cons 1 1))
	   (`onetwo (and multi-line-p (cons 1 2)))
	   (`pep-257 (and multi-line-p (cons nil 2)))
	   (`pep-257-nn (and multi-line-p (cons nil 1)))
	   (`symmetric (and multi-line-p (cons 1 1))))))
    ;;  (save-excursion
    (when style
      ;; Add the number of newlines indicated by the selected style
      ;; at the start.
      (goto-char thisbeg)
      (mys--skip-raw-string-front-fence)
      (skip-chars-forward "'\"")
      (when
	  (car delimiters-style)
	(unless (or (mys-empty-line-p)(eolp))
	  (newline (car delimiters-style))))
      (indent-region beg end mys-current-indent))
    (when multi-line-p
      (goto-char thisbeg)
      (mys--skip-raw-string-front-fence)
      (skip-chars-forward " \t\r\n\f")
      (forward-line 1)
      (beginning-of-line)
      (unless (mys-empty-line-p) (newline 1)))
    (mys--fill-fix-end thisend orig delimiters-style)))

(defun mys--fill-docstring-first-line (beg end)
  "Refill first line after newline maybe. "
  (fill-region-as-paragraph beg (line-end-position) nil t t)
  (save-excursion
    (end-of-line)
    (unless (eobp)
      (forward-line 1)
      (back-to-indentation)
      (unless (or (< end (point)) (mys-empty-line-p))
	(newline 1)
	))))

(defun mys--fill-paragraph-in-docstring (beg)
  ;; (goto-char innerbeg)
  (let* ((fill-column (- fill-column (current-indentation)))
	 (parabeg (max beg (mys--beginning-of-paragraph-position)))
	 (paraend (comys-marker (mys--end-of-paragraph-position))))
    ;; if paragraph is a substring, take it
    (goto-char parabeg)
    (mys--fill-docstring-first-line parabeg paraend)
    (unless (or (< paraend (point))(eobp))
      (mys--fill-paragraph-in-docstring (point)))))

(defun mys--fill-docstring (justify style docstring orig mys-current-indent &optional beg end)
  ;; Delete spaces after/before string fencge
  (mys--string-fence-delete-spaces beg)
  (let* ((beg (or beg docstring))
	 (innerbeg (comys-marker (progn (goto-char beg) (mys--skip-raw-string-front-fence) (point))))
         (end (comys-marker
	       (or end
                   (progn
		     (goto-char innerbeg)
		     ;; (mys--skip-raw-string-front-fence)
		     (skip-syntax-forward "^|")
		     (1+ (point))))))
	 (innerend (comys-marker (progn (goto-char end)(skip-chars-backward "\\'\"") (point))))
	 (multi-line-p (string-match "\n" (buffer-substring-no-properties innerbeg innerend))))
    (save-restriction
      (narrow-to-region (point-min) end)

      (when (string-match (concat "^" mys-labelled-re) (buffer-substring-no-properties beg end))
	(mys-fill-labelled-string beg end))
      ;; (first-line-p (<= (line-beginning-position) beg)
      (goto-char innerbeg)
      (mys--fill-paragraph-in-docstring beg))
    (mys--fill-docstring-base innerbeg innerend style multi-line-p beg end mys-current-indent orig)))

(defun mys-fill-string (&optional justify style docstring pps)
  "String fill function for `mys-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'.

Fill according to `mys-docstring-style' "
  (interactive "*")
  (let* ((justify (or justify (if current-prefix-arg 'full t)))
	 (style (or style mys-docstring-style))
	 (pps (or pps (parse-partial-sexp (point-min) (point))))
	 (indent
	  ;; set inside tqs
	  ;; (save-excursion (and (nth 3 pps) (goto-char (nth 8 pps)) (current-indentation)))
	  nil)
	 (orig (comys-marker (point)))
	 ;; (docstring (or docstring (mys--in-or-behind-or-before-a-docstring pps)))
	 (docstring (cond (docstring
			   (if (not (number-or-marker-p docstring))
			       (mys--in-or-behind-or-before-a-docstring pps))
			   docstring)
			  (t (mys--in-or-behind-or-before-a-docstring pps))))
	 (beg (and (nth 3 pps) (nth 8 pps)))
	 (tqs (progn (and beg (goto-char beg) (looking-at "\"\"\"\\|'''") (setq indent (current-column)))))
	 (end (comys-marker (if tqs
			       (or
				(progn (ignore-errors (forward-sexp))(and (< orig (point)) (point)))
				(goto-char orig)
				(line-end-position))
			     (or (progn (goto-char beg) (ignore-errors (forward-sexp))(and (< orig (point)) (point)))
				 (goto-char orig)
				 (line-end-position))))))
    (goto-char orig)
    (when beg
      (if docstring
	  (mys--fill-docstring justify style docstring orig indent beg end)
	(save-restriction
	  (if (not tqs)
	      (if (mys-preceding-line-backslashed-p)
		  (progn
		    (setq end (comys-marker (line-end-position)))
		    (narrow-to-region (line-beginning-position) end)
		    (fill-region (line-beginning-position) end justify t)
		    (when (< 1 (mys-count-lines))
		      (mys--continue-lines-region (point-min) end)))
		(narrow-to-region beg end)
		(fill-region beg end justify t)
		(when
		    ;; counting in narrowed buffer
		    (< 1 (mys-count-lines))
		  (mys--continue-lines-region beg end)))
	    (fill-region beg end justify)))))))

(defun mys--continue-lines-region (beg end)
  (save-excursion
    (goto-char beg)
    (while (< (line-end-position) end)
      (end-of-line)
      (unless (mys-escaped-p) (insert-and-inherit 32) (insert-and-inherit 92))
      (ignore-errors (forward-line 1)))))

(defun mys-fill-paragraph (&optional justify pps beg end tqs)
  (interactive "*")
  (save-excursion
    (save-restriction
      (window-configuration-to-register mys--windows-config-register)
      (let* ((pps (or pps (parse-partial-sexp (point-min) (point))))
	     (docstring (unless (not mys-docstring-style) (mys--in-or-behind-or-before-a-docstring pps)))
	     (fill-column mys-comment-fill-column)
	     (in-string (nth 3 pps)))
	(cond ((or (nth 4 pps)
		   (and (bolp) (looking-at "[ \t]*#[# \t]*")))
	       (mys-fill-comment))
	      (docstring
	       (setq fill-column mys-docstring-fill-column)
	       (mys--fill-docstring justify mys-docstring-style docstring (point)
				   ;; current indentation
				   (save-excursion (and (nth 3 pps) (goto-char (nth 8 pps)) (current-indentation)))))
	      (t
	       (let* ((beg (or beg (save-excursion
				     (if (looking-at paragraph-start)
					 (point)
				       (backward-paragraph)
				       (when (looking-at paragraph-start)
					 (point))))
			       (and (nth 3 pps) (nth 8 pps))))
		      (end (or end
			       (when beg
				 (save-excursion
				   (or
				    (and in-string
					 (progn
					   (goto-char (nth 8 pps))
					   (setq tqs (looking-at "\"\"\"\\|'''"))
					   (forward-sexp) (point)))
				    (progn
				      (forward-paragraph)
				      (when (looking-at paragraph-separate)
					(point)))))))))
		 (and beg end (fill-region beg end))
		 (when (and in-string (not tqs))
		   (mys--continue-lines-region beg end))))))
      (jump-to-register mys--windows-config-register))))

(defun mys-fill-string-or-comment ()
  "Serve auto-fill-mode"
  (unless (< (current-column) fill-column)
  (let ((pps (parse-partial-sexp (point-min) (point))))
    (if (nth 3 pps)
	(mys-fill-string nil nil nil pps)
      ;; (mys-fill-comment pps)
      (do-auto-fill)
      ))))

;; mys-components-section-forms

(defun mys-execute-section ()
  "Execute section at point."
  (interactive)
  (mys-execute-section-prepare))

(defun mys-execute-section-python ()
  "Execute section at point using python interpreter."
  (interactive)
  (mys-execute-section-prepare "python"))

(defun mys-execute-section-python2 ()
  "Execute section at point using python2 interpreter."
  (interactive)
  (mys-execute-section-prepare "python2"))

(defun mys-execute-section-python3 ()
  "Execute section at point using python3 interpreter."
  (interactive)
  (mys-execute-section-prepare "python3"))

(defun mys-execute-section-imys ()
  "Execute section at point using imys interpreter."
  (interactive)
  (mys-execute-section-prepare "imys"))

(defun mys-execute-section-imys2.7 ()
  "Execute section at point using imys2.7 interpreter."
  (interactive)
  (mys-execute-section-prepare "imys2.7"))

(defun mys-execute-section-imys3 ()
  "Execute section at point using imys3 interpreter."
  (interactive)
  (mys-execute-section-prepare "imys3"))

(defun mys-execute-section-jython ()
  "Execute section at point using jython interpreter."
  (interactive)
  (mys-execute-section-prepare "jython"))

;; mys-components-comment


(defun mys-comment-region (beg end &optional arg)
  "Like `comment-region’ but uses double hash (`#') comment starter."
  (interactive "r\nP")
  (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start)))
    (comment-region beg end arg)))

(defun mys-comment-block (&optional beg end arg)
  "Comments block at point.

Uses double hash (`#') comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-block-position)))
          (end (or end (mys--end-of-block-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-block-or-clause (&optional beg end arg)
  "Comments block-or-clause at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-block-or-clause-position)))
          (end (or end (mys--end-of-block-or-clause-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-class (&optional beg end arg)
  "Comments class at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-class-position)))
          (end (or end (mys--end-of-class-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-clause (&optional beg end arg)
  "Comments clause at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-clause-position)))
          (end (or end (mys--end-of-clause-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-def (&optional beg end arg)
  "Comments def at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-def-position)))
          (end (or end (mys--end-of-def-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-def-or-class (&optional beg end arg)
  "Comments def-or-class at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-def-or-class-position)))
          (end (or end (mys--end-of-def-or-class-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-indent (&optional beg end arg)
  "Comments indent at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-indent-position)))
          (end (or end (mys--end-of-indent-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-minor-block (&optional beg end arg)
  "Comments minor-block at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-minor-block-position)))
          (end (or end (mys--end-of-minor-block-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-section (&optional beg end arg)
  "Comments section at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-section-position)))
          (end (or end (mys--end-of-section-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-statement (&optional beg end arg)
  "Comments statement at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-statement-position)))
          (end (or end (mys--end-of-statement-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))

(defun mys-comment-top-level (&optional beg end arg)
  "Comments top-level at point.

Uses double hash (`#’) comment starter when `mys-block-comment-prefix-p' is  t,
the default"
  (interactive "*")
  (save-excursion
    (let ((comment-start (if mys-block-comment-prefix-p
                             mys-block-comment-prefix
                           comment-start))
          (beg (or beg (mys--beginning-of-top-level-position)))
          (end (or end (mys--end-of-top-level-position))))
      (goto-char beg)
      (push-mark)
      (goto-char end)
      (comment-region beg end arg))))


;; mys-components-comment ends here
;; mys-components-fast-forms

;; Process forms fast

(defun mys-execute-buffer-fast (&optional shell dedicated split switch proc)
  "Send accessible part of buffer to a Python interpreter.

Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SPLIT: split buffers after executing
Optional SWITCH: switch to output buffer after executing
Optional PROC: select an already running process for executing"
  (interactive)
  (mys-execute-buffer shell dedicated t split switch proc))

(defun mys-execute-region-fast (beg end &optional shell dedicated split switch proc)
  "Send region to a Python interpreter.

Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SPLIT: split buffers after executing
Optional SWITCH: switch to output buffer after executing
Optional PROC: select an already running process for executing"
  (interactive "r")
  (let ((mys-fast-process-p t))
    (mys-execute-region beg end shell dedicated t split switch proc)))

(defun mys-execute-block-fast (&optional shell dedicated switch beg end file)
  "Process block at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'block shell dedicated switch beg end file t))

(defun mys-execute-block-or-clause-fast (&optional shell dedicated switch beg end file)
  "Process block-or-clause at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'block-or-clause shell dedicated switch beg end file t))

(defun mys-execute-class-fast (&optional shell dedicated switch beg end file)
  "Process class at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'class shell dedicated switch beg end file t))

(defun mys-execute-clause-fast (&optional shell dedicated switch beg end file)
  "Process clause at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'clause shell dedicated switch beg end file t))

(defun mys-execute-def-fast (&optional shell dedicated switch beg end file)
  "Process def at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'def shell dedicated switch beg end file t))

(defun mys-execute-def-or-class-fast (&optional shell dedicated switch beg end file)
  "Process def-or-class at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'def-or-class shell dedicated switch beg end file t))

(defun mys-execute-expression-fast (&optional shell dedicated switch beg end file)
  "Process expression at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'expression shell dedicated switch beg end file t))

(defun mys-execute-partial-expression-fast (&optional shell dedicated switch beg end file)
  "Process partial-expression at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'partial-expression shell dedicated switch beg end file t))

(defun mys-execute-section-fast (&optional shell dedicated switch beg end file)
  "Process section at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'section shell dedicated switch beg end file t))

(defun mys-execute-statement-fast (&optional shell dedicated switch beg end file)
  "Process statement at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'statement shell dedicated switch beg end file t))

(defun mys-execute-top-level-fast (&optional shell dedicated switch beg end file)
  "Process top-level at point by a Python interpreter.

Output buffer not in comint-mode, displays \"Fast\"  by default
Optional SHELL: Selecte a Mys-shell(VERSION) as mys-shell-name
Optional DEDICATED: run in a dedicated process
Optional SWITCH: switch to output buffer after executing
Optional File: execute through running a temp-file"
  (interactive)
  (mys--execute-prepare 'top-level shell dedicated switch beg end file t))

;; mys-components-narrow

(defun mys-narrow-to-block ()
  "Narrow to block at point."
  (interactive)
  (mys--narrow-prepare "block"))

(defun mys-narrow-to-block-or-clause ()
  "Narrow to block-or-clause at point."
  (interactive)
  (mys--narrow-prepare "block-or-clause"))

(defun mys-narrow-to-class ()
  "Narrow to class at point."
  (interactive)
  (mys--narrow-prepare "class"))

(defun mys-narrow-to-clause ()
  "Narrow to clause at point."
  (interactive)
  (mys--narrow-prepare "clause"))

(defun mys-narrow-to-def ()
  "Narrow to def at point."
  (interactive)
  (mys--narrow-prepare "def"))

(defun mys-narrow-to-def-or-class ()
  "Narrow to def-or-class at point."
  (interactive)
  (mys--narrow-prepare "def-or-class"))

(defun mys-narrow-to-statement ()
  "Narrow to statement at point."
  (interactive)
  (mys--narrow-prepare "statement"))

;; mys-components-hide-show

;; (setq hs-block-start-regexp 'mys-extended-block-or-clause-re)
;; (setq hs-forward-sexp-func 'mys-forward-block)

(defun mys-hide-base (form &optional beg end)
  "Hide visibility of existing form at point."
  (hs-minor-mode 1)
  (save-excursion
    (let* ((form (prin1-to-string form))
           (beg (or beg (or (funcall (intern-soft (concat "mys--beginning-of-" form "-p")))
                            (funcall (intern-soft (concat "mys-backward-" form))))))
           (end (or end (funcall (intern-soft (concat "mys-forward-" form)))))
           (modified (buffer-modified-p))
           (inhibit-read-only t))
      (if (and beg end)
          (progn
            (hs-make-overlay beg end 'code)
            (set-buffer-modified-p modified))
        (error (concat "No " (format "%s" form) " at point"))))))

(defun mys-hide-show (&optional form beg end)
  "Toggle visibility of existing forms at point."
  (interactive)
  (save-excursion
    (let* ((form (prin1-to-string form))
           (beg (or beg (or (funcall (intern-soft (concat "mys--beginning-of-" form "-p")))
                            (funcall (intern-soft (concat "mys-backward-" form))))))
           (end (or end (funcall (intern-soft (concat "mys-forward-" form)))))
           (modified (buffer-modified-p))
           (inhibit-read-only t))
      (if (and beg end)
          (if (overlays-in beg end)
              (hs-discard-overlays beg end)
            (hs-make-overlay beg end 'code))
        (error (concat "No " (format "%s" form) " at point")))
      (set-buffer-modified-p modified))))

(defun mys-show ()
  "Remove invisibility of existing form at point."
  (interactive)
  (with-silent-modifications
    (save-excursion
      (back-to-indentation)
      (let ((end (next-overlay-change (point))))
	(hs-discard-overlays (point) end)))))

(defun mys-show-all ()
  "Remove invisibility of hidden forms in buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let (end)
      (while (and (not (eobp))  (setq end (next-overlay-change (point))))
	(hs-discard-overlays (point) end)
	(goto-char end)))))

(defun mys-hide-region (beg end)
  "Hide active region."
  (interactive
   (list
    (and (use-region-p) (region-beginning))(and (use-region-p) (region-end))))
  (mys-hide-base 'region beg end))

(defun mys-show-region (beg end)
  "Un-hide active region."
  (interactive
   (list
    (and (use-region-p) (region-beginning))(and (use-region-p) (region-end))))
  (hs-discard-overlays beg end))

(defun mys-hide-block ()
  "Hide block at point."
  (interactive)
  (mys-hide-base 'block))

(defun mys-hide-block-or-clause ()
  "Hide block-or-clause at point."
  (interactive)
  (mys-hide-base 'block-or-clause))

(defun mys-hide-class ()
  "Hide class at point."
  (interactive)
  (mys-hide-base 'class))

(defun mys-hide-clause ()
  "Hide clause at point."
  (interactive)
  (mys-hide-base 'clause))

(defun mys-hide-comment ()
  "Hide comment at point."
  (interactive)
  (mys-hide-base 'comment))

(defun mys-hide-def ()
  "Hide def at point."
  (interactive)
  (mys-hide-base 'def))

(defun mys-hide-def-or-class ()
  "Hide def-or-class at point."
  (interactive)
  (mys-hide-base 'def-or-class))

(defun mys-hide-elif-block ()
  "Hide elif-block at point."
  (interactive)
  (mys-hide-base 'elif-block))

(defun mys-hide-else-block ()
  "Hide else-block at point."
  (interactive)
  (mys-hide-base 'else-block))

(defun mys-hide-except-block ()
  "Hide except-block at point."
  (interactive)
  (mys-hide-base 'except-block))

(defun mys-hide-expression ()
  "Hide expression at point."
  (interactive)
  (mys-hide-base 'expression))

(defun mys-hide-for-block ()
  "Hide for-block at point."
  (interactive)
  (mys-hide-base 'for-block))

(defun mys-hide-if-block ()
  "Hide if-block at point."
  (interactive)
  (mys-hide-base 'if-block))

(defun mys-hide-indent ()
  "Hide indent at point."
  (interactive)
  (mys-hide-base 'indent))

(defun mys-hide-line ()
  "Hide line at point."
  (interactive)
  (mys-hide-base 'line))

(defun mys-hide-minor-block ()
  "Hide minor-block at point."
  (interactive)
  (mys-hide-base 'minor-block))

(defun mys-hide-paragraph ()
  "Hide paragraph at point."
  (interactive)
  (mys-hide-base 'paragraph))

(defun mys-hide-partial-expression ()
  "Hide partial-expression at point."
  (interactive)
  (mys-hide-base 'partial-expression))

(defun mys-hide-section ()
  "Hide section at point."
  (interactive)
  (mys-hide-base 'section))

(defun mys-hide-statement ()
  "Hide statement at point."
  (interactive)
  (mys-hide-base 'statement))

(defun mys-hide-top-level ()
  "Hide top-level at point."
  (interactive)
  (mys-hide-base 'top-level))

(defun mys-dynamically-hide-indent ()
  (interactive)
  (mys-show)
  (mys-hide-indent))

(defun mys-dynamically-hide-further-indent (&optional arg)
  (interactive "P")
  (if (eq 4  (prefix-numeric-value arg))
      (mys-show)
  (mys-show)
  (mys-forward-indent)
  (mys-hide-indent)))

;; mys-components-hide-show.el ends here
;; mys-components-foot

(defun mys-shell-fontify ()
  "Fontifies input in shell buffer. "
  ;; causes delay in fontification until next trigger
  ;; (unless (or (member (char-before) (list 32 ?: ?\)))
  ;; (unless (and (eq last-command 'self-insert-command) (eq (char-before) 32))
  ;; (< (abs (save-excursion (skip-chars-backward "^ \t\r\n\f"))) 2))
  (let* ((pps (parse-partial-sexp (line-beginning-position) (point)))
	 (start (if (and (nth 8 pps) (nth 1 pps))
		    (max (nth 1 pps) (nth 8 pps))
		  (or (nth 1 pps) (nth 8 pps)))))
    (when (or start
	      (setq start (ignore-errors (cdr comint-last-prompt))))
      (let* ((input (buffer-substring-no-properties
		     start (point-max)))
	     (buffer-undo-list t)
	     (replacement
	      (save-current-buffer
		(set-buffer mys-shell--font-lock-buffer)
		(erase-buffer)
		(insert input)
		;; Ensure buffer is fontified, keeping it
		;; compatible with Emacs < 24.4.
		(if (fboundp 'font-lock-ensure)
		    (funcall 'font-lock-ensure)
		  (font-lock-default-fontify-buffer))
		(buffer-substring (point-min) (point-max))))
	     (replacement-length (length replacement))
	     (i 0))
	;; Inject text properties to get input fontified.
	(while (not (= i replacement-length))
	  (let* ((plist (text-properties-at i replacement))
		 (next-change (or (next-property-change i replacement)
				  replacement-length))
		 (plist (let ((face (plist-get plist 'face)))
			  (if (not face)
			      plist
			    ;; Replace FACE text properties with
			    ;; FONT-LOCK-FACE so input is fontified.
			    (plist-put plist 'face nil)
			    (plist-put plist 'font-lock-face face)))))
	    (set-text-properties
	     (+ start i) (+ start next-change) plist)
	    (setq i next-change)))))))

(defun mys-message-which-mys-mode ()
  (if (buffer-file-name)
      (if (string= "mys-mode-el" (buffer-file-name))
	  (message "%s" "mys-mode loaded from mys-mode-el")
	(message "%s" "mys-mode loaded from mys-components-mode"))
    (message "mys-mode loaded from: %s" mys-mode-message-string)))

(defalias 'mys-next-statement 'mys-forward-statement)
;; #134, cython-mode compatibility
(defalias 'mys-end-of-statement 'mys-forward-statement)
(defalias 'mys-beginning-of-statement 'mys-backward-statement)
(defalias 'mys-beginning-of-block 'mys-backward-block)
(defalias 'mys-end-of-block 'mys-forward-block)
(defalias 'mys-previous-statement 'mys-backward-statement)
(defalias 'mys-markup-region-as-section 'mys-sectionize-region)

(define-derived-mode mys-auto-completion-mode mys-mode "Pac"
  "Run auto-completion"
  ;; disable company
  ;; (when company-mode (company-mode))
  (if mys-auto-completion-mode-p
      (progn
	(setq mys-auto-completion-mode-p nil
	      mys-auto-completion-buffer nil)
	(when (timerp mys--auto-complete-timer)(cancel-timer mys--auto-complete-timer)))
    (setq mys-auto-completion-mode-p t
	  mys-auto-completion-buffer (current-buffer))
    (setq mys--auto-complete-timer
	  (run-with-idle-timer
	   mys--auto-complete-timer-delay
	   ;; 1
	   t
	   #'mys-complete-auto)))
  (force-mode-line-update))

(autoload 'mys-mode "mys-mode" "Python Mode." t)

(defun all-mode-setting ()
  (set (make-local-variable 'indent-tabs-mode) mys-indent-tabs-mode)
  )

(define-derived-mode mys-mode prog-mode mys-mode-modeline-display
  "Major mode for editing Python files.

To submit a report, enter `\\[mys-submit-bug-report]'
from a`mys-mode' buffer.
Do `\\[mys-describe-mode]' for detailed documentation.
To see what version of `mys-mode' you are running,
enter `\\[mys-version]'.

This mode knows about Python indentation,
tokens, comments (and continuation lines.
Paragraphs are separated by blank lines only.

COMMANDS

`mys-shell'\tStart an interactive Python interpreter in another window
`mys-execute-statement'\tSend statement at point to Python default interpreter
`mys-backward-statement'\tGo to the initial line of a simple statement

etc.

See available commands listed in files commands-mys-mode at directory doc

VARIABLES

`mys-indent-offset'	indentation increment
`mys-shell-name'		shell command to invoke Python interpreter
`mys-split-window-on-execute'		When non-nil split windows
`mys-switch-buffers-on-execute-p'	When non-nil switch to the Python output buffer

\\{mys-mode-map}"
  :group 'mys-mode
  ;; load known shell listed in
  ;; Local vars
  (all-mode-setting)
  (set (make-local-variable 'electric-indent-inhibit) nil)
  (set (make-local-variable 'outline-regexp)
       (concat (mapconcat 'identity
                          (mapcar #'(lambda (x) (concat "^\\s-*" x "\\_>"))
                                  mys-outline-mode-keywords)
                          "\\|")))
  (when mys-font-lock-defaults-p
    (if mys-use-font-lock-doc-face-p
	(set (make-local-variable 'font-lock-defaults)
             '(mys-font-lock-keywords nil nil nil nil
					 (font-lock-syntactic-keywords
					  . mys-font-lock-syntactic-keywords)
					 (font-lock-syntactic-face-function
					  . mys--font-lock-syntactic-face-function)))
      (set (make-local-variable 'font-lock-defaults)
           '(mys-font-lock-keywords nil nil nil nil
				       (font-lock-syntactic-keywords
					. mys-font-lock-syntactic-keywords)))))
  ;; avoid to run mys-choose-shell again from `mys--fix-start'
  (cond ((string-match "ython3" mys-mys-edit-version)
	 (font-lock-add-keywords 'mys-mode
				 '(("\\<print\\>" . 'mys-builtins-face)
				   ("\\<file\\>" . nil))))
	(t (font-lock-add-keywords 'mys-mode
				   '(("\\<print\\>" . 'font-lock-keyword-face)
				     ("\\<file\\>" . 'mys-builtins-face)))))
  (set (make-local-variable 'which-func-functions) 'mys-which-def-or-class)
  (set (make-local-variable 'parse-sexp-lookup-properties) t)
  (set (make-local-variable 'comment-use-syntax) t)
  (set (make-local-variable 'comment-start) "#")
  (set (make-local-variable 'comment-start-skip) "^[ \t]*#+ *")

  (if mys-empty-comment-line-separates-paragraph-p
      (progn
        (set (make-local-variable 'paragraph-separate) (concat "\f\\|^[\t]*$\\|^[ \t]*" comment-start "[ \t]*$\\|^[\t\f]*:[[:alpha:]]+ [[:alpha:]]+:.+$"))
        (set (make-local-variable 'paragraph-start)
	     (concat "\f\\|^[ \t]*$\\|^[ \t]*" comment-start "[ \t]*$\\|^[ \t\f]*:[[:alpha:]]+ [[:alpha:]]+:.+$"))
	(set (make-local-variable 'paragraph-separate)
	     (concat "\f\\|^[ \t]*$\\|^[ \t]*" comment-start "[ \t]*$\\|^[ \t\f]*:[[:alpha:]]+ [[:alpha:]]+:.+$")))
    (set (make-local-variable 'paragraph-separate) "\f\\|^[ \t]*$\\|^[\t]*#[ \t]*$\\|^[ \t\f]*:[[:alpha:]]+ [[:alpha:]]+:.+$")
    (set (make-local-variable 'paragraph-start) "\f\\|^[ \t]*$\\|^[\t]*#[ \t]*$\\|^[ \t\f]*:[[:alpha:]]+ [[:alpha:]]+:.+$"))
  (set (make-local-variable 'comment-column) 40)
  (set (make-local-variable 'comment-indent-function) #'mys--comment-indent-function)
  (set (make-local-variable 'indent-region-function) 'mys-indent-region)
  (set (make-local-variable 'indent-line-function) 'mys-indent-line)
  ;; introduced to silence compiler warning, no real setting
  ;; (set (make-local-variable 'hs-hide-comments-when-hiding-all) 'mys-hide-comments-when-hiding-all)
  (set (make-local-variable 'outline-heading-end-regexp) ":[^\n]*\n")
  (set (make-local-variable 'open-paren-in-column-0-is-defun-start) nil)
  (set (make-local-variable 'add-log-current-defun-function) 'mys-current-defun)
  (set (make-local-variable 'fill-paragraph-function) 'mys-fill-paragraph)
  (set (make-local-variable 'normal-auto-fill-function) 'mys-fill-string-or-comment)
  (set (make-local-variable 'require-final-newline) mode-require-final-newline)
  (set (make-local-variable 'tab-width) mys-indent-offset)
  (set (make-local-variable 'electric-indent-mode) nil)
  (and mys-load-skeletons-p (mys-load-skeletons))
  (and mys-guess-mys-install-directory-p (mys-set-load-path))
  (and mys-autopair-mode
       (load-library "autopair")
       (add-hook 'mys-mode-hook
                 #'(lambda ()
                     (setq autopair-handle-action-fns
                           (list #'autopair-default-handle-action
                                 #'autopair-mys-triple-quote-action))))
       (mys-autopair-mode-on))
  (when (and mys--imenu-create-index-p
             (fboundp 'imenu-add-to-menubar)
             (ignore-errors (require 'imenu)))
    (setq imenu-create-index-function 'mys--imenu-create-index-function)
    (setq imenu--index-alist (funcall mys--imenu-create-index-function))
    ;; fallback
    (unless imenu--index-alist
      (setq imenu--index-alist (mys--imenu-create-index-new)))
    ;; (message "imenu--index-alist: %s" imenu--index-alist)
    (imenu-add-to-menubar "PyIndex"))
  (when mys-trailing-whitespace-smart-delete-p
    (add-hook 'before-save-hook 'delete-trailing-whitespace nil 'local))
  ;; this should go into interactive modes
  ;; (when mys-pdbtrack-do-tracking-p
  ;;   (add-hook 'comint-output-filter-functions 'mys--pdbtrack-track-stack-file))
  (mys-shell-prompt-set-calculated-regexps)
  (setq comint-prompt-regexp mys-shell--prompt-calculated-input-regexp)
  (cond
   (mys-complete-function
    (add-hook 'completion-at-point-functions
              mys-complete-function))
   (mys-load-pymacs-p
    (add-hook 'completion-at-point-functions
              'mys-complete-completion-at-point nil 'local))
   (t
    (add-hook 'completion-at-point-functions
              'mys-shell-complete nil 'local)))
  ;; #'mys-shell-completion-at-point nil 'local)))
  ;; (if mys-auto-complete-p
  ;; (add-hook 'mys-mode-hook 'mys--run-completion-timer)
  ;; (remove-hook 'mys-mode-hook 'mys--run-completion-timer))
  ;; (when mys-auto-complete-p
  ;; (add-hook 'mys-mode-hook
  ;; (lambda ()
  ;; (run-with-idle-timer 1 t 'mys-shell-complete))))
  (if mys-auto-fill-mode
      (add-hook 'mys-mode-hook 'mys--run-auto-fill-timer)
    (remove-hook 'mys-mode-hook 'mys--run-auto-fill-timer))
  (add-hook 'mys-mode-hook
            (lambda ()
              (setq imenu-create-index-function mys--imenu-create-index-function)))
  ;; caused insert-file-contents error lp:1293172
  ;;  (add-hook 'after-change-functions 'mys--after-change-function nil t)
  (if mys-defun-use-top-level-p
      (progn
        (set (make-local-variable 'beginning-of-defun-function) 'mys-backward-top-level)
        (set (make-local-variable 'end-of-defun-function) 'mys-forward-top-level)
        (define-key mys-mode-map [(control meta a)] 'mys-backward-top-level)
        (define-key mys-mode-map [(control meta e)] 'mys-forward-top-level))
    (set (make-local-variable 'beginning-of-defun-function) 'mys-backward-def-or-class)
    (set (make-local-variable 'end-of-defun-function) 'mys-forward-def-or-class)
    (define-key mys-mode-map [(control meta a)] 'mys-backward-def-or-class)
    (define-key mys-mode-map [(control meta e)] 'mys-forward-def-or-class))
  (when mys-sexp-use-expression-p
    (define-key mys-mode-map [(control meta f)] 'mys-forward-expression)
    (define-key mys-mode-map [(control meta b)] 'mys-backward-expression))

  (when mys-hide-show-minor-mode-p (hs-minor-mode 1))
  (when mys-outline-minor-mode-p (outline-minor-mode 1))
  (when (and mys-debug-p (called-interactively-p 'any))
    (mys-message-which-mys-mode))
  (force-mode-line-update))

(define-derived-mode mys-shell-mode comint-mode mys-modeline-display
  "Major mode for Python shell process.

Variables
`mys-shell-prompt-regexp',
`mys-shell-prompt-output-regexp',
`mys-shell-input-prompt-2-regexp',
`mys-shell-fontify-p',
`mys-completion-setup-code',
`mys-shell-completion-string-code',
can customize this mode for different Python interpreters.

This mode resets `comint-output-filter-functions' locally, so you
may want to re-add custom functions to it using the
`mys-shell-mode-hook'.

\(Type \\[describe-mode] in the process buffer for a list of commands.)"
  (setq mode-line-process '(":%s"))
  (all-mode-setting)
  ;; (set (make-local-variable 'indent-tabs-mode) nil)
  (set (make-local-variable 'mys-shell--prompt-calculated-input-regexp) nil)
  (set (make-local-variable 'mys-shell--block-prompt) nil)
  (set (make-local-variable 'mys-shell--prompt-calculated-output-regexp) nil)
  (mys-shell-prompt-set-calculated-regexps)
  (set (make-local-variable 'comint-prompt-read-only) t)
  (set (make-local-variable 'comint-output-filter-functions)
       '(ansi-color-process-output
         mys-comint-watch-for-first-prompt-output-filter
         mys-pdbtrack-comint-output-filter-function
         mys-comint-postoutput-scroll-to-bottom
         comint-watch-for-password-prompt))
  (set (make-local-variable 'compilation-error-regexp-alist)
       mys-shell-compilation-regexp-alist)
  (compilation-shell-minor-mode 1)
  (add-hook 'completion-at-point-functions
	    #'mys-shell-completion-at-point nil 'local)
  (cond
   ((string-match "^[Jj]" (process-name (get-buffer-process (current-buffer))))
    'indent-for-tab-command)
   (t
    (define-key mys-shell-mode-map "\t"
		'mys-indent-or-complete)))
  (make-local-variable 'mys-pdbtrack-buffers-to-kill)
  (make-local-variable 'mys-shell-fast-last-output)
  (set (make-local-variable 'mys-shell--block-prompt) nil)
  (set (make-local-variable 'mys-shell--prompt-calculated-output-regexp) nil)
  (mys-shell-prompt-set-calculated-regexps)
  (if mys-shell-fontify-p
      (progn
  	(mys-shell-font-lock-turn-on))
    (mys-shell-font-lock-turn-off)))

(make-obsolete 'jmys-mode 'jython-mode nil)

;; (push "*Python*"  same-window-buffer-names)
;; (push "*Imys*"  same-window-buffer-names)

;; Python Macro File
(unless (member '("\\.py\\'" . mys-mode) auto-mode-alist)
  (push (cons "\\.py\\'"  'mys-mode)  auto-mode-alist))

(unless (member '("\\.pym\\'" . mys-mode) auto-mode-alist)
  (push (cons "\\.pym\\'"  'mys-mode)  auto-mode-alist))

(unless (member '("\\.pyc\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pyc\\'"  'mys-mode)  auto-mode-alist))

;; Pyrex Source
(unless (member '("\\.pyx\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pyx\\'"  'mys-mode) auto-mode-alist))

;; Python Optimized Code
(unless (member '("\\.pyo\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pyo\\'"  'mys-mode) auto-mode-alist))

;; Pyrex Definition File
(unless (member '("\\.pxd\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pxd\\'"  'mys-mode) auto-mode-alist))

;; Python Repository
(unless (member '("\\.pyr\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pyr\\'"  'mys-mode)  auto-mode-alist))

;; Python Stub file
;; https://www.python.org/dev/peps/pep-0484/#stub-files
(unless (member '("\\.pyi\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pyi\\'"  'mys-mode)  auto-mode-alist))

;; Python Path Configuration
(unless (member '("\\.pth\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.pth\\'"  'mys-mode)  auto-mode-alist))

;; Python Wheels
(unless (member '("\\.whl\\'" . mys-mode)  auto-mode-alist)
  (push (cons "\\.whl\\'"  'mys-mode)  auto-mode-alist))

(unless (member '("!#[          ]*/.*[jp]ython[0-9.]*" . mys-mode) magic-mode-alist)
  (push '("!#[ \\t]*/.*[jp]ython[0-9.]*" . mys-mode) magic-mode-alist))

;;  lp:1355458, what about using `magic-mode-alist'?

(defalias 'mys-hungry-delete-forward 'c-hungry-delete-forward)
(defalias 'mys-hungry-delete-backwards 'c-hungry-delete-backwards)

;;;
(provide 'mys-mode)
;;; mys-mode.el ends here
