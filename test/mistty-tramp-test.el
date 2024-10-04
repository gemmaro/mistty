;;; Tests MisTTY's TRAMP integration -*- lexical-binding: t -*-

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; `http://www.gnu.org/licenses/'.

(require 'ert)
(require 'ert-x)
(require 'tramp)
(eval-when-compile
  (require 'cl-lib))

(require 'mistty)
(require 'mistty-testing)

(ert-deftest mistty-tramp-test-shell-start ()
  (let* ((sg-prefix (mistty-tramp-test-prefix))
         (home (file-name-directory (getenv "HOME")))
         (default-directory (concat sg-prefix home))
         ;; Disable directory tracking for this test; it doesn't work
         ;; properly with TRAMP yet.
         (term-command-function (lambda (str))))
    (mistty-with-test-buffer ()
      (should (equal (concat sg-prefix home)
                     (buffer-local-value 'default-directory (current-buffer))))
      (should (equal mistty-test-bash-exe (mistty-tramp-test-remote-command)))

      ;; This just makes sure the shell is functional.
      (mistty-send-text "echo hello")
      (should (equal "hello" (mistty-send-and-capture-command-output)))

      ;; TRAMP sets INSIDE_EMACS and reports its version.
      (mistty-send-string "echo $INSIDE_EMACS")
      (should (equal (format "%s,term:%s,tramp:%s" emacs-version term-protocol-version tramp-version)
                     (mistty-send-and-capture-command-output))))))

(ert-deftest mistty-tramp-test-connection-local ()
  (skip-unless mistty-test-zsh-exe)
  (let* ((sg-prefix (mistty-tramp-test-prefix))
         (default-directory (concat sg-prefix "/"))
         (connection-local-profile-alist nil)
         (connection-local-criteria-alist nil)
         (explicit-shell-file-name "/bin/sh")
         buf)

    (connection-local-set-profile-variables
     'test-profile
     `((explicit-shell-file-name . ,mistty-test-zsh-exe)))
    (connection-local-set-profiles '(:method "sg") 'test-profile)

    ;; This makes sure the connection-local setup above works.
    (should (equal mistty-test-zsh-exe
                   (with-connection-local-variables explicit-shell-file-name)))

    (unwind-protect
        (progn
          (setq buf (mistty-create))
          (should (process-get mistty-proc 'remote-command))
          ;; This makes sure that the connection-local value of
          ;; explicit-shell-file-name is the one that's used, and not
          ;; the global value.
          (should (equal mistty-test-zsh-exe (mistty-tramp-test-remote-command))))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))))))

(ert-deftest mistty-tramp-test-termcap ()
  (let* ((sg-prefix (mistty-tramp-test-prefix))
         (default-directory (concat sg-prefix "/"))
         (term-term-name "eterm-test"))
    (mistty-with-test-buffer ()

      ;; TERMINFO shouldn't be set in remote shells.
      (mistty-send-text "echo TERMINFO=${TERMINFO}.")
      (should (equal "TERMINFO=." (mistty-send-and-capture-command-output)))

      ;; TERMCAP should be set.
      (mistty-send-text "if [ -n \"$TERMCAP\" ]; then echo set; else echo unset; fi")
      (should (equal "set" (mistty-send-and-capture-command-output)))

      ;; captoinfo reads and processes the TERMCAP env variable. This
      ;; makes sure that the content of TERMCAP is valid.
      (mistty-send-text "captoinfo")
      (should (string-match "eterm-test,\n +am, mir.*" (mistty-send-and-capture-command-output))))))

(defun mistty-tramp-test-prefix ()
  "Build a TRAMP file prefix for a remote file for testing."
  (let* ((groups (split-string (shell-command-to-string "groups") " " 'omit-nulls))
         (host (system-name))
         (group (or (nth 2 groups) (car groups))))
    (format "/sg:%s@%s:" group host)))

(defun mistty-tramp-test-remote-command ()
  "Return the remote command, as reported by TRAMP or nil."
  ;; tramp-handle-make-process sets remote-command on the processes
  ;; it starts.
  (pcase-let ((`("/bin/sh" "-c" ,_ ".." ,command . _)
               (process-get mistty-proc 'remote-command)))
    command))
