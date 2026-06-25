;;; query.el --- Natural-language Emacs command helper -*- lexical-binding: t; -*-

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
;; Requires the `pi' CLI on your PATH (see `query-agent-command').  Without it,
;; `query-now' will fail with "pi: command not found"; point that variable at
;; your own agent command if you use a different one.
;;
;; Privacy: each query sends a prefix of your `~/.emacs.el', the current buffer,
;; and any active region to the agent as context.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup query nil
  "Ask an external agent for executable Emacs commands."
  :group 'tools)

(defcustom query-agent-command "pi"
  "Program used by `query-now'."
  :type 'string)

(defcustom query-agent-arguments
  '("--tools" "read,bash,grep,find,ls" "--thinking" "low" "--no-context-files" "-p")
  "Arguments passed to `query-agent-command' before the prompt.

Keep this read-only unless you explicitly want the agent to edit files.
The final prompt is appended as one argument."
  :type '(repeat string))

(defcustom query-agent-model nil
  "Optional model passed to the agent with --model.
Leave nil to use the agent's configured default."
  :type '(choice (const :tag "Agent default" nil) string))

(defcustom query-config-file (expand-file-name "~/.emacs.el")
  "Emacs config file included in query context."
  :type 'file)

(defcustom query-context-max-config-chars 24000
  "Maximum number of config characters included in each request."
  :type 'integer)

(defcustom query-context-max-buffer-chars 4000
  "Maximum number of current-buffer characters included in each request."
  :type 'integer)

(defcustom query-display-mode 'minibuffer
  "How `query-now' presents responses.
When set to `minibuffer', ask whether to execute the returned command
from the minibuffer.  When set to `buffer', show the full `*query*'
buffer."
  :type '(choice (const :tag "Minibuffer prompt" minibuffer)
                 (const :tag "Query buffer" buffer)))

(defvar query--history nil)
(defvar query--last-process nil)
(defvar query--last-prompt nil)
(defvar query--last-response nil)
(defvar query--last-command-language nil)
(defvar query--last-command-code nil)
(defvar query--last-command-description nil)

(defvar query-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))

(define-key query-mode-map (kbd "RET") #'query-run-last-command)
(define-key query-mode-map (kbd "<return>") #'query-run-last-command)
(define-key query-mode-map (kbd "e") #'query-edit-last-command)
(define-key query-mode-map (kbd "b") #'query-show-last-response)
(define-key query-mode-map (kbd "g") #'query-retry)
(define-key query-mode-map (kbd "r") #'query-reply)
(define-key query-mode-map (kbd "q") #'quit-window)

(define-derived-mode query-mode special-mode "Query"
  "Mode for natural-language Emacs command responses."
  (setq-local truncate-lines nil))

(defun query--buffer ()
  (let ((buf (get-buffer-create "*query*")))
    (with-current-buffer buf
      (query-mode))
    buf))

(defun query--read-file-prefix (file max-chars)
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 max-chars)
      (buffer-string))))

(defun query--buffer-prefix ()
  (let ((end (min (point-max) (+ (point-min) query-context-max-buffer-chars))))
    (buffer-substring-no-properties (point-min) end)))

(defun query--safe-symbol-value (symbol)
  (condition-case nil
      (prin1-to-string (symbol-value symbol))
    (error "<unavailable>")))

(defun query--emacs-context ()
  (let* ((buf (current-buffer))
         (config (query--read-file-prefix query-config-file
                                          query-context-max-config-chars))
         (region (when (use-region-p)
                   (buffer-substring-no-properties
                    (region-beginning)
                    (min (region-end)
                         (+ (region-beginning) query-context-max-buffer-chars))))))
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
     (query--safe-symbol-value 'browse-url-browser-function)
     (query--safe-symbol-value 'markdown-command)
     (query--safe-symbol-value 'counsel-rg-base-command)
     (query--buffer-prefix)
     (or region "")
     query-config-file
     (or config ""))))

(defun query--system-instructions ()
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

(defun query--history-context ()
  (if query--history
      (mapconcat
       (lambda (entry)
         (format "User: %s\nAssistant JSON: %s"
                 (plist-get entry :prompt)
                 (plist-get entry :response)))
       (reverse (cl-subseq query--history 0 (min 4 (length query--history))))
       "\n\n")
    ""))

(defun query--build-prompt (question)
  (format "%s

Conversation so far:
%s

%s

User request:
%s"
          (query--system-instructions)
          (query--history-context)
          (query--emacs-context)
          question))

(defun query--command-list (prompt)
  (append (list query-agent-command)
          (when query-agent-model
            (list "--model" query-agent-model))
          query-agent-arguments
          (list prompt)))

(defun query--json-object-alist (json)
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol)
        (json-false nil))
    (json-read-from-string json)))

(defun query--extract-json (text)
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

(defun query--parse-response (text)
  (condition-case nil
      (query--json-object-alist (query--extract-json text))
    (error nil)))

(defun query--alist-get (key alist)
  (alist-get key alist nil nil #'eq))

(defun query--parsed-command (parsed)
  (let ((command (and parsed (query--alist-get 'command parsed))))
    (when (and command (listp command))
      (let ((code (query--alist-get 'code command)))
        (when (and code (not (string-empty-p code)))
          (list :language (or (query--alist-get 'language command) "elisp")
                :code code
                :description (query--alist-get 'description command)))))))

(defun query--remember-command (command)
  (setq query--last-command-language (plist-get command :language))
  (setq query--last-command-code (plist-get command :code))
  (setq query--last-command-description (plist-get command :description)))

(defun query--insert-command-button (language code description)
  (insert "\n")
  (let ((start (point)))
    (insert-text-button
     (format "Execute %s command: %s"
             language
             (or description code))
     'follow-link t
     'help-echo "RET or mouse-1 executes this command"
     'query-command-language language
     'query-command-code code
     'action (lambda (button)
               (query-execute-command
                (button-get button 'query-command-language)
                (button-get button 'query-command-code))))
    start))

(defun query--render (prompt raw)
  (let* ((parsed (query--parse-response raw))
         (answer (and parsed (query--alist-get 'answer parsed)))
         (command (query--parsed-command parsed))
         (follow-up (and parsed (query--alist-get 'follow_up parsed))))
    (setq query--last-response raw)
    (setq query--last-command-language nil
          query--last-command-code nil
          query--last-command-description nil)
    (when command
      (query--remember-command command))
    (push (list :prompt prompt :response raw) query--history)
    (with-current-buffer (query--buffer)
      (let ((inhibit-read-only t)
            command-button)
        (erase-buffer)
        (insert (propertize "Query\n" 'face '(:height 1.2 :weight bold)))
        (insert "\n")
        (insert (propertize "Request:\n" 'face 'bold))
        (insert prompt "\n\n")
        (insert (propertize "Response:\n" 'face 'bold))
        (if parsed
            (progn
              (insert (or answer ""))
              (when command
                (setq command-button
                      (query--insert-command-button
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
    (pop-to-buffer (query--buffer))))

(defun query--show-buffer (prompt raw)
  (query--render prompt raw))

(defun query--handle-response (prompt raw)
  (let* ((parsed (query--parse-response raw))
         (answer (and parsed (query--alist-get 'answer parsed)))
         (command (query--parsed-command parsed)))
    (setq query--last-response raw)
    (setq query--last-command-language nil
          query--last-command-code nil
          query--last-command-description nil)
    (when command
      (query--remember-command command))
    (push (list :prompt prompt :response raw) query--history)
    (if (eq query-display-mode 'buffer)
        (query--show-buffer prompt raw)
      (if parsed
          (query--prompt-from-minibuffer prompt raw answer command)
        (query--show-buffer prompt raw)))))

(defun query--prompt-from-minibuffer (prompt raw answer command)
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
             (?y (query-run-last-command))
             (?e (query-edit-last-command))
             (?b (query--show-buffer prompt raw))
             (?n (message "Query command skipped."))))))
    (message "%s" (or answer "Query completed without a command."))))

(defun query--show-started (question)
  (if (eq query-display-mode 'buffer)
      (with-current-buffer (query--buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Asking agent...\n\n")
          (insert question "\n"))
        (pop-to-buffer (current-buffer)))
    (message "Query: asking agent...")))

;;;###autoload
(defun query-now (question)
  "Ask QUESTION and display an executable response from the configured agent."
  (interactive (list (read-string "Query: ")))
  (setq query--last-prompt question)
  (let* ((prompt (query--build-prompt question))
         (output "")
         (command (query--command-list prompt)))
    (when (process-live-p query--last-process)
      (delete-process query--last-process))
    (query--show-started question)
    (setq query--last-process
          (make-process
           :name "query-agent"
           :buffer nil
           :command command
           :noquery t
           :filter (lambda (_proc chunk)
                     (setq output (concat output chunk)))
           :sentinel (lambda (proc _event)
                       (when (memq (process-status proc) '(exit signal))
                         (if (= (process-exit-status proc) 0)
                             (query--handle-response question output)
                           (with-current-buffer (query--buffer)
                             (let ((inhibit-read-only t))
                               (erase-buffer)
                               (insert "Agent failed.\n\n")
                               (insert "Command: "
                                       (mapconcat #'identity command " ")
                                       "\n\n")
                               (insert output))))))))))

;;;###autoload
(defun query-reply (question)
  "Ask a follow-up QUESTION about the previous query response."
  (interactive (list (read-string "Reply: ")))
  (query-now question))

;;;###autoload
(defun query-retry ()
  "Retry the last query."
  (interactive)
  (unless query--last-prompt
    (user-error "No previous query"))
  (query-now query--last-prompt))

;;;###autoload
(defun query-show-last-response ()
  "Show the last full query response in `*query*'."
  (interactive)
  (unless query--last-response
    (user-error "No query response yet"))
  (query--show-buffer (or query--last-prompt "") query--last-response))

;;;###autoload
(defun query-run-last-command ()
  "Run the command from the last query response."
  (interactive)
  (unless query--last-command-code
    (user-error "No query command to execute"))
  (query-execute-command query--last-command-language query--last-command-code t))

;;;###autoload
(defun query-edit-last-command ()
  "Edit and run the command from the last query response."
  (interactive)
  (unless query--last-command-code
    (user-error "No query command to edit"))
  (let ((code (read-string "Edit command: " query--last-command-code)))
    (query-execute-command query--last-command-language code)))

;;;###autoload
(defun query-execute-command (language code &optional confirmed)
  "Execute CODE in LANGUAGE."
  (interactive
   (list (completing-read "Language: " '("elisp" "shell") nil t nil nil "elisp")
         (read-string "Command: ")))
  (pcase (downcase language)
    ("elisp"
     (let ((form (read code)))
       (when (or confirmed
                 (yes-or-no-p (format "Evaluate Emacs Lisp? %S " form)))
         (message "query: %S" (eval form t)))))
    ("shell"
     (when (or confirmed
               (yes-or-no-p (format "Run shell command? %s " code)))
       (async-shell-command code "*query-shell*")))
    (_
     (user-error "Unknown query command language: %s" language))))

(provide 'query)
;;; query.el ends here
