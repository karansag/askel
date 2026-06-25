;;; askel.el --- Natural-language Emacs command helper -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Karan Sagar
;; Author: Karan Sagar <karan@karansag.org>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.  There is NO WARRANTY.

;;; Commentary:

;; Ask in natural language; get an executable Emacs Lisp or shell command back.
;;
;; Requires the `pi' CLI on your PATH (see `askel-agent-command').  Without it,
;; `askel-now' will fail with "pi: command not found"; point that variable at
;; your own agent command if you use a different one.
;;
;; Privacy: each askel sends a prefix of your `~/.emacs.el', the current buffer,
;; and any active region to the agent as context.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup askel nil
  "Ask an external agent for executable Emacs commands."
  :group 'tools)

(defcustom askel-agent-command "pi"
  "Program used by `askel-now'."
  :type 'string)

(defcustom askel-agent-arguments
  '("--tools" "read,bash,grep,find,ls" "--thinking" "low" "--no-context-files" "-p")
  "Arguments passed to `askel-agent-command' before the prompt.

Keep this read-only unless you explicitly want the agent to edit files.
The final prompt is appended as one argument."
  :type '(repeat string))

(defcustom askel-agent-model nil
  "Optional model passed to the agent with --model.
Leave nil to use the agent's configured default."
  :type '(choice (const :tag "Agent default" nil) string))

(defcustom askel-config-file (expand-file-name "~/.emacs.el")
  "Emacs config file included in askel context."
  :type 'file)

(defcustom askel-context-max-config-chars 24000
  "Maximum number of config characters included in each request."
  :type 'integer)

(defcustom askel-context-max-buffer-chars 4000
  "Maximum number of current-buffer characters included in each request."
  :type 'integer)

(defcustom askel-display-mode 'minibuffer
  "How `askel-now' presents responses.
When set to `minibuffer', ask whether to execute the returned command
from the minibuffer.  When set to `buffer', show the full `*askel*'
buffer."
  :type '(choice (const :tag "Minibuffer prompt" minibuffer)
                 (const :tag "Askel buffer" buffer)))

(defvar askel--history nil)
(defvar askel--last-process nil)
(defvar askel--last-prompt nil)
(defvar askel--last-response nil)
(defvar askel--last-command-language nil)
(defvar askel--last-command-code nil)
(defvar askel--last-command-description nil)

(defvar askel-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))

(define-key askel-mode-map (kbd "RET") #'askel-run-last-command)
(define-key askel-mode-map (kbd "<return>") #'askel-run-last-command)
(define-key askel-mode-map (kbd "e") #'askel-edit-last-command)
(define-key askel-mode-map (kbd "b") #'askel-show-last-response)
(define-key askel-mode-map (kbd "g") #'askel-retry)
(define-key askel-mode-map (kbd "r") #'askel-reply)
(define-key askel-mode-map (kbd "q") #'quit-window)

(define-derived-mode askel-mode special-mode "Askel"
  "Mode for natural-language Emacs command responses."
  (setq-local truncate-lines nil))

(defun askel--buffer ()
  (let ((buf (get-buffer-create "*askel*")))
    (with-current-buffer buf
      (askel-mode))
    buf))

(defun askel--read-file-prefix (file max-chars)
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 max-chars)
      (buffer-string))))

(defun askel--buffer-prefix ()
  (let ((end (min (point-max) (+ (point-min) askel-context-max-buffer-chars))))
    (buffer-substring-no-properties (point-min) end)))

(defun askel--safe-symbol-value (symbol)
  (condition-case nil
      (prin1-to-string (symbol-value symbol))
    (error "<unavailable>")))

(defun askel--emacs-context ()
  (let* ((buf (current-buffer))
         (config (askel--read-file-prefix askel-config-file
                                          askel-context-max-config-chars))
         (region (when (use-region-p)
                   (buffer-substring-no-properties
                    (region-beginning)
                    (min (region-end)
                         (+ (region-beginning) askel-context-max-buffer-chars))))))
    (format
     "Running Emacs context:
- emacs-version: %s
- system-type: %S
- daemonp: %S
- selected-frame-font: %S
- current-buffer: %S
- major-mode: %S
- buffer-file-name: %S
- default-directory: %S
- point: %S
- mark-active: %S
- recent command: %S

Relevant live variables:
- default face: %S
- mode-line face: %S
- browse-url-browser-function: %s
- markdown-command: %s
- counsel-rg-base-command: %s

Current buffer prefix:
```text
%s
```

Active region prefix:
```text
%s
```

Emacs config file `%s` prefix:
```elisp
%s
```"
     emacs-version
     system-type
     (daemonp)
     (face-attribute 'default :font nil 'default)
     (buffer-name buf)
     major-mode
     buffer-file-name
     default-directory
     (point)
     (use-region-p)
     last-command
     (face-all-attributes 'default nil)
     (face-all-attributes 'mode-line nil)
     (askel--safe-symbol-value 'browse-url-browser-function)
     (askel--safe-symbol-value 'markdown-command)
     (askel--safe-symbol-value 'counsel-rg-base-command)
     (askel--buffer-prefix)
     (or region "")
     askel-config-file
     (or config ""))))

(defun askel--system-instructions ()
  "Return instructions for the external agent."
  "You are helping control a running Emacs instance.

Return ONLY a JSON object, no Markdown fences and no prose outside JSON.
The JSON shape is:
{
  \"answer\": \"short natural-language explanation\",
  \"command\": {
    \"language\": \"elisp\" | \"shell\",
    \"code\": \"single executable command\",
    \"description\": \"what the command does\"
  } | null,
  \"follow_up\": \"optional question if you need more information, otherwise empty string\"
}

Prefer Emacs Lisp commands for Emacs changes. Do not edit files directly.
If persistent config edits are needed, return an Emacs Lisp command that opens
or modifies the user's Emacs config deliberately. If you need live Emacs state
not present in the prompt, you may suggest a read-only emacsclient --eval shell
command, but do not execute destructive operations.")

(defun askel--history-context ()
  (if askel--history
      (mapconcat
       (lambda (entry)
         (format "User: %s\nAssistant JSON: %s"
                 (plist-get entry :prompt)
                 (plist-get entry :response)))
       (reverse (cl-subseq askel--history 0 (min 4 (length askel--history))))
       "\n\n")
    ""))

(defun askel--build-prompt (question)
  (format "%s

Conversation so far:
%s

%s

User request:
%s"
          (askel--system-instructions)
          (askel--history-context)
          (askel--emacs-context)
          question))

(defun askel--command-list (prompt)
  (append (list askel-agent-command)
          (when askel-agent-model
            (list "--model" askel-agent-model))
          askel-agent-arguments
          (list prompt)))

(defun askel--json-object-alist (json)
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol)
        (json-false nil))
    (json-read-from-string json)))

(defun askel--extract-json (text)
  (let ((trimmed (string-trim text)))
    (cond
     ((string-prefix-p "{" trimmed) trimmed)
     ((and (string-match "```json[[:space:]\n]*\\({\\(?:.\\|\n\\)*?}\\)[[:space:]\n]*```" trimmed)
           (match-string 1 trimmed)))
     ((string-match "{" trimmed)
      (let ((start (match-beginning 0)))
        (if (string-match "}[[:space:]\n]*\\'" trimmed start)
            (substring trimmed start (match-end 0))
          trimmed)))
     (t trimmed))))

(defun askel--parse-response (text)
  (condition-case nil
      (askel--json-object-alist (askel--extract-json text))
    (error nil)))

(defun askel--alist-get (key alist)
  (alist-get key alist nil nil #'eq))

(defun askel--parsed-command (parsed)
  (let ((command (and parsed (askel--alist-get 'command parsed))))
    (when (and command (listp command))
      (let ((code (askel--alist-get 'code command)))
        (when (and code (not (string-empty-p code)))
          (list :language (or (askel--alist-get 'language command) "elisp")
                :code code
                :description (askel--alist-get 'description command)))))))

(defun askel--remember-command (command)
  (setq askel--last-command-language (plist-get command :language))
  (setq askel--last-command-code (plist-get command :code))
  (setq askel--last-command-description (plist-get command :description)))

(defun askel--insert-command-button (language code description)
  (insert "\n")
  (let ((start (point)))
    (insert-text-button
     (format "Execute %s command: %s"
             language
             (or description code))
     'follow-link t
     'help-echo "RET or mouse-1 executes this command"
     'askel-command-language language
     'askel-command-code code
     'action (lambda (button)
               (askel-execute-command
                (button-get button 'askel-command-language)
                (button-get button 'askel-command-code))))
    start))

(defun askel--render (prompt raw)
  (let* ((parsed (askel--parse-response raw))
         (answer (and parsed (askel--alist-get 'answer parsed)))
         (command (askel--parsed-command parsed))
         (follow-up (and parsed (askel--alist-get 'follow_up parsed))))
    (setq askel--last-response raw)
    (setq askel--last-command-language nil
          askel--last-command-code nil
          askel--last-command-description nil)
    (when command
      (askel--remember-command command))
    (push (list :prompt prompt :response raw) askel--history)
    (with-current-buffer (askel--buffer)
      (let ((inhibit-read-only t)
            command-button)
        (erase-buffer)
        (insert (propertize "Askel\n" 'face '(:height 1.2 :weight bold)))
        (insert "\n")
        (insert (propertize "Request:\n" 'face 'bold))
        (insert prompt "\n\n")
        (insert (propertize "Response:\n" 'face 'bold))
        (if parsed
            (progn
              (insert (or answer ""))
              (when command
                (setq command-button
                      (askel--insert-command-button
                       (plist-get command :language)
                       (plist-get command :code)
                       (plist-get command :description)))
                (insert "\n\n")
                (insert (propertize "Command:\n" 'face 'bold))
                (insert "```" (plist-get command :language) "\n"
                        (plist-get command :code) "\n```\n"))
              (when (and follow-up (not (string-empty-p follow-up)))
                (insert "\nFollow-up: " follow-up "\n")))
          (insert raw "\n\nCould not parse a JSON command from the agent response.\n"))
        (insert "\nKeys: RET executes, e edits command, r replies, g retries, q quits.\n")
        (goto-char (or command-button (point-min)))))
    (pop-to-buffer (askel--buffer))))

(defun askel--show-buffer (prompt raw)
  (askel--render prompt raw))

(defun askel--handle-response (prompt raw)
  (let* ((parsed (askel--parse-response raw))
         (answer (and parsed (askel--alist-get 'answer parsed)))
         (command (askel--parsed-command parsed)))
    (setq askel--last-response raw)
    (setq askel--last-command-language nil
          askel--last-command-code nil
          askel--last-command-description nil)
    (when command
      (askel--remember-command command))
    (push (list :prompt prompt :response raw) askel--history)
    (if (eq askel-display-mode 'buffer)
        (askel--show-buffer prompt raw)
      (if parsed
          (askel--prompt-from-minibuffer prompt raw answer command)
        (askel--show-buffer prompt raw)))))

(defun askel--prompt-from-minibuffer (prompt raw answer command)
  (if command
      (run-at-time
       0 nil
       (lambda ()
         (let* ((code (plist-get command :code))
                (language (or (plist-get command :language) "elisp"))
                (description (plist-get command :description))
                (choice (read-char-choice
                         (format "%s%s\nRun (%s): %s\n[y] run  [e] edit  [b] buffer  [n] no: "
                                 (or answer "Agent returned a command.")
                                 (if (and description (not (string-empty-p description)))
                                     (concat "\n" description)
                                   "")
                                 language
                                 code)
                         '(?y ?e ?b ?n))))
           (pcase choice
             (?y (askel-run-last-command))
             (?e (askel-edit-last-command))
             (?b (askel--show-buffer prompt raw))
             (?n (message "Askel command skipped."))))))
    (message "%s" (or answer "Askel completed without a command."))))

(defun askel--show-started (question)
  (if (eq askel-display-mode 'buffer)
      (with-current-buffer (askel--buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Asking agent...\n\n")
          (insert question "\n"))
        (pop-to-buffer (current-buffer)))
    (message "Askel: asking agent...")))

;;;###autoload
(defun askel-now (question)
  "Ask QUESTION and display an executable response from the configured agent."
  (interactive (list (read-string "Askel: ")))
  (setq askel--last-prompt question)
  (let* ((prompt (askel--build-prompt question))
         (output "")
         (command (askel--command-list prompt)))
    (when (process-live-p askel--last-process)
      (delete-process askel--last-process))
    (askel--show-started question)
    (setq askel--last-process
          (make-process
           :name "askel-agent"
           :buffer nil
           :command command
           :noquery t
           :filter (lambda (_proc chunk)
                     (setq output (concat output chunk)))
           :sentinel (lambda (proc _event)
                       (when (memq (process-status proc) '(exit signal))
                         (if (= (process-exit-status proc) 0)
                             (askel--handle-response question output)
                           (with-current-buffer (askel--buffer)
                             (let ((inhibit-read-only t))
                               (erase-buffer)
                               (insert "Agent failed.\n\n")
                               (insert "Command: "
                                       (mapconcat #'identity command " ")
                                       "\n\n")
                               (insert output))))))))))

;;;###autoload
(defun askel-reply (question)
  "Ask a follow-up QUESTION about the previous askel response."
  (interactive (list (read-string "Reply: ")))
  (askel-now question))

;;;###autoload
(defun askel-retry ()
  "Retry the last request."
  (interactive)
  (unless askel--last-prompt
    (user-error "No previous request"))
  (askel-now askel--last-prompt))

;;;###autoload
(defun askel-show-last-response ()
  "Show the last full askel response in `*askel*'."
  (interactive)
  (unless askel--last-response
    (user-error "No askel response yet"))
  (askel--show-buffer (or askel--last-prompt "") askel--last-response))

;;;###autoload
(defun askel-run-last-command ()
  "Run the command from the last askel response."
  (interactive)
  (unless askel--last-command-code
    (user-error "No askel command to execute"))
  (askel-execute-command askel--last-command-language askel--last-command-code t))

;;;###autoload
(defun askel-edit-last-command ()
  "Edit and run the command from the last askel response."
  (interactive)
  (unless askel--last-command-code
    (user-error "No askel command to edit"))
  (let ((code (read-string "Edit command: " askel--last-command-code)))
    (askel-execute-command askel--last-command-language code)))

;;;###autoload
(defun askel-execute-command (language code &optional confirmed)
  "Execute CODE in LANGUAGE."
  (interactive
   (list (completing-read "Language: " '("elisp" "shell") nil t nil nil "elisp")
         (read-string "Command: ")))
  (pcase (downcase language)
    ("elisp"
     (let ((form (read code)))
       (when (or confirmed
                 (yes-or-no-p (format "Evaluate Emacs Lisp? %S " form)))
         (message "askel: %S" (eval form t)))))
    ("shell"
     (when (or confirmed
               (yes-or-no-p (format "Run shell command? %s " code)))
       (async-shell-command code "*askel-shell*")))
    (_
     (user-error "Unknown askel command language: %s" language))))

(provide 'askel)
;;; askel.el ends here
