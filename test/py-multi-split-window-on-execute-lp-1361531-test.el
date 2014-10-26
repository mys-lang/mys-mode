;;; py-multi-split-window-on-execute-lp-1361531-test.el --- Test splitting

;; Copyright (C) 2011-2014  Andreas Roehler
;; Author: Andreas Roehler <andreas.roehler@online.de>
;; Keywords: languages, convenience

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

;; This file is generated by function from python-mode-utils.el - see in
;; directory devel. Edits here might not be persistent.

;;; Code:

 
(defun py-multi-split-window-on-execute-lp-1361531-python-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env python
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-python-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-python-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-python-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-python-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-python-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-python-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))
 
(defun py-multi-split-window-on-execute-lp-1361531-ipython-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env ipython
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-ipython-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-ipython-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-ipython-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-ipython-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-ipython-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-ipython-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))
 
(defun py-multi-split-window-on-execute-lp-1361531-python2-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env python2
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-python2-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-python2-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-python2-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-python2-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-python2-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-python2-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))
 
(defun py-multi-split-window-on-execute-lp-1361531-jython-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env jython
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-jython-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-jython-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-jython-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-jython-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-jython-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-jython-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))
 
(defun py-multi-split-window-on-execute-lp-1361531-python3-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env python3
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-python3-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-python3-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-python3-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-python3-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-python3-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-python3-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))
 
(defun py-multi-split-window-on-execute-lp-1361531-bpython-test (&optional arg)
  (interactive "p")
  (let ((py-split-window-on-execute-p 'always)
        (teststring "#! /usr/bin/env bpython
# -*- coding: utf-8 -*-
print(\"I'm the py-multi-split-window-on-execute-lp-1361531-bpython-test\")"))
    (py-bug-tests-intern 'py-multi-split-window-on-execute-lp-1361531-bpython-base arg teststring)))

(defun py-multi-split-window-on-execute-lp-1361531-bpython-base ()
  (when py-debug-p (message "py-split-window-on-execute-p: %s" py-split-window-on-execute-p))
  (delete-other-windows)

  (let ((erg1 (progn (py-execute-statement-bpython-dedicated) py-buffer-name))
        (erg2 (progn (py-execute-statement-bpython-dedicated) py-buffer-name)))
  (sit-for 1 t)
  (when py-debug-p (message "(count-windows) %s" (count-windows))) 
  (assert (eq 3 (count-windows)) nil "py-multi-split-window-on-execute-lp-1361531-bpython-test failed")
  (py-kill-buffer-unconditional erg1)
  (py-kill-buffer-unconditional erg2)
  (py-restore-window-configuration)))

(provide 'py-multi-split-window-on-execute-lp-1361531-test)
;;; py-multi-split-window-on-execute-lp-1361531-test.el here
 