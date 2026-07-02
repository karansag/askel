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
;; Choose a backend with `askel-agent'.  The default preset, `openrouter',
;; calls the OpenRouter HTTP API directly -- roughly 10x faster than shelling
;; out to an agent CLI, which pays for process startup, session setup, and (on
;; OpenRouter's default routing) a slow upstream provider on every query.  The
;; CLI presets `pi', `claude', `codex', and `opencode' remain available, or set
;; `askel-agent' to `custom' and provide `askel-custom-command'.  Override the
;; model with `askel-model'.  Switch interactively with M-x `askel-set-agent'
;; and `askel-set-model'.
;;
;; The `pi' and `claude' presets keep one agent process alive between queries
;; (see `askel-persistent-agent'), cutting per-query time from 20-26s to a few
;; seconds after the first; `askel-stop-agent' shuts the process down.
;;
;; The `openrouter' preset needs an API key: `askel-openrouter-api-key', the
;; OPENROUTER_API_KEY environment variable, or a key already stored by the pi
;; or opencode CLIs.  CLI presets need their command on `exec-path'.
;;
;; Privacy: each askel sends a prefix of your `~/.emacs.el', the current buffer,
;; and any active region to the agent as context.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup askel nil
  "Ask an external agent for executable Emacs commands."
  :group 'tools)

(defcustom askel-agents
  '((openrouter
     :type http
     :url "https://openrouter.ai/api/v1/chat/completions"
     :model "z-ai/glm-5.2")           ; https://openrouter.ai/models
    (pi
     :command "pi"
     :args ("--tools" "read,bash,grep,find,ls" "--thinking" "low" "--no-context-files" "-p")
     :model "z-ai/glm-5.2"         ; `pi --list-models' shows others
     :model-flag "--model"
     ;; Long-lived `pi --mode rpc' process; saves ~10-18s/query over one-shot.
     :rpc-command ("pi" "--mode" "rpc" "--no-session" "--no-context-files"
                   "--tools" "read,bash,grep,find,ls" "--thinking" "low")
     :rpc-protocol pi-rpc)
    (claude
     :command "claude"
     :args ("-p")
     :model "sonnet"               ; "haiku" is faster/cheaper
     :model-flag "--model"
     ;; Long-lived stream-json session; --verbose is mandatory with
     ;; --output-format stream-json in print mode.
     :rpc-command ("claude" "-p" "--input-format" "stream-json"
                   "--output-format" "stream-json" "--verbose")
     :rpc-protocol claude-stream-json)
    (codex
     :command "codex"
     :args ("exec" "--skip-git-repo-check" "-c" "model_reasoning_effort=low")
     :model "gpt-5.4"              ; "gpt-5.4-mini" is smaller/faster
     :model-flag "--model"
     ;; `codex exec' floods stdout with session logs; read the clean final
     ;; message from a file instead.  See `askel--output-file-flag'.
     :output-file-flag "--output-last-message")
    (opencode
     :command "opencode"
     :args ("run")
     :model "openrouter/z-ai/glm-5.2"   ; `opencode models' lists the rest
     :model-flag "--model"))
  "Built-in agent presets for `askel-now'.

An alist mapping a preset key (symbol) to a plist.  HTTP presets
(:type `http') call an OpenAI-compatible chat-completions endpoint
directly and take:
  :url         endpoint URL
  :model       model string sent in the request
CLI presets shell out to an agent binary and take:
  :command      program to run (must be on `exec-path')
  :args         fixed arguments placed before the prompt
  :model        default model string, or nil for the agent's own default
  :model-flag   flag used to pass the model (e.g. \"--model\")
  :rpc-command  optional command list for a persistent agent process
  :rpc-protocol wire protocol of that process (see `askel--rpc-handle-event')
For CLI presets the prompt is appended as the final argument.  Select
the active preset with `askel-agent'."
  :type '(alist :key-type symbol :value-type plist))

(defcustom askel-agent 'openrouter
  "Active agent for `askel-now'.
Either a key in `askel-agents', or `custom' to use `askel-custom-command'."
  :type 'symbol)

(defcustom askel-persistent-agent t
  "When non-nil, keep CLI agents that support it alive between queries.
Applies to presets with an :rpc-command (currently `pi' and `claude').
The first query pays the usual startup cost; later ones skip process
boot and benefit from the provider's prompt cache, typically answering
in a few seconds instead of 20+.  Stop the process with
`askel-stop-agent'."
  :type 'boolean)

(defcustom askel-rpc-reset-after 10
  "Start a fresh agent session after this many persistent-agent queries.
Each query appends its full prompt to the live session, so an unbounded
session grows slow and expensive; resetting bounds that.  The query
after a reset re-pays the full prompt cost once."
  :type 'integer)

(defcustom askel-openrouter-api-key nil
  "API key for the `openrouter' preset.
When nil, fall back to the OPENROUTER_API_KEY environment variable and
then to keys stored by the pi and opencode CLIs (~/.pi/agent/auth.json,
~/.local/share/opencode/auth.json)."
  :type '(choice (const :tag "Auto-discover" nil) string))

(defcustom askel-model nil
  "Model override for the active agent.
When nil, use the active preset's :model.  Set to a string (e.g. \"haiku\")
to override it without editing `askel-agents'."
  :type '(choice (const :tag "Preset default" nil) string))

(defcustom askel-custom-command nil
  "Command list used when `askel-agent' is `custom'.
A list of strings; the prompt is appended as the final argument.
Example: (\"my-agent\" \"--model\" \"foo\" \"-p\")."
  :type '(repeat string))

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

(defcustom askel-log-buffer "*askel-log*"
  "Name of the buffer that accumulates askel queries, timings, and commands.
Each `askel-now' response appends one entry here; view it with
`askel-show-log'.  Set to nil to disable logging."
  :type '(choice (const :tag "Disabled" nil) string))

(defvar askel--history nil)
(defvar askel--last-process nil)
(defvar askel--last-url-buffer nil
  "Buffer of the in-flight HTTP request, or nil.")
(defvar askel--rpc-process nil
  "Long-lived agent process, or nil.")
(defvar askel--rpc-key nil
  "(AGENT MODEL) the persistent process was started for.")
(defvar askel--rpc-protocol nil
  "Wire protocol of the running persistent process.")
(defvar askel--rpc-line-buffer "")
(defvar askel--rpc-callback nil
  "Function awaiting the persistent agent's reply text, or nil when idle.")
(defvar askel--rpc-turns 0
  "Queries answered in the persistent agent's current session.")
(defvar askel--last-prompt nil)
(defvar askel--last-response nil)
(defvar askel--last-timing nil
  "Timing string for the most recent response, e.g. \"claude/sonnet · 5.8s\".")
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

(defun askel--preset ()
  "Return the plist for the active agent preset.
Signal a `user-error' if `askel-agent' names no known preset."
  (or (cdr (assq askel-agent askel-agents))
      (user-error "Unknown askel agent: %S (not in `askel-agents')" askel-agent)))

(defun askel--agent-label ()
  "Return a short \"agent/model\" label for the active agent."
  (let ((model (or askel-model
                   (and (not (eq askel-agent 'custom))
                        (plist-get (askel--preset) :model)))))
    (if model (format "%s/%s" askel-agent model) (format "%s" askel-agent))))

(defun askel--output-file-flag ()
  "Return the active preset's :output-file-flag, or nil.
Agents whose stdout is too noisy to parse (e.g. `codex exec') write their
final message to this file instead."
  (and (not (eq askel-agent 'custom))
       (plist-get (askel--preset) :output-file-flag)))

(defun askel--read-file (file)
  "Return the contents of FILE as a string, or nil if unreadable."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun askel--command-list (prompt &optional output-file)
  "Build the command list (program, args, model, PROMPT) for `askel-agent'.
When the active preset has an :output-file-flag and OUTPUT-FILE is non-nil,
insert that flag so the agent writes its final message to OUTPUT-FILE."
  (if (eq askel-agent 'custom)
      (progn
        (unless askel-custom-command
          (user-error "`askel-agent' is `custom' but `askel-custom-command' is unset"))
        (append askel-custom-command (list prompt)))
    (let* ((preset (askel--preset))
           (model (or askel-model (plist-get preset :model)))
           (model-flag (plist-get preset :model-flag))
           (out-flag (plist-get preset :output-file-flag)))
      (append (list (plist-get preset :command))
              (plist-get preset :args)
              (when (and model model-flag) (list model-flag model))
              (when (and out-flag output-file) (list out-flag output-file))
              (list prompt)))))

(defun askel--http-preset-p ()
  "Return non-nil when the active agent is an HTTP preset."
  (and (not (eq askel-agent 'custom))
       (eq (plist-get (askel--preset) :type) 'http)))

(defun askel--auth-file-openrouter-key (file)
  "Return the OpenRouter API key stored in FILE (a CLI auth.json), or nil."
  (ignore-errors
    (alist-get 'key
               (alist-get 'openrouter
                          (askel--json-object-alist
                           (askel--read-file (expand-file-name file)))))))

(defun askel--openrouter-key ()
  "Return the OpenRouter API key, or signal a `user-error'."
  (or askel-openrouter-api-key
      (getenv "OPENROUTER_API_KEY")
      (askel--auth-file-openrouter-key "~/.pi/agent/auth.json")
      (askel--auth-file-openrouter-key "~/.local/share/opencode/auth.json")
      (user-error
       "No OpenRouter API key; set `askel-openrouter-api-key' or OPENROUTER_API_KEY")))

(defun askel--http-body (model prompt)
  "Return the JSON request body asking MODEL to answer PROMPT."
  (json-encode
   `((model . ,model)
     (messages . [((role . "user") (content . ,prompt))])
     ;; OpenRouter's default routing can land on providers that take 10-20s
     ;; to prefill an askel-sized prompt; throughput-sorted routing answers
     ;; the same prompt in 1-2s.
     (provider . ((sort . "throughput")))
     (reasoning . ((enabled . :json-false)))
     (max_tokens . 1024))))

(defun askel--http-response-content (data)
  "Extract the message text from chat-completions response DATA."
  (alist-get 'content
             (alist-get 'message (car (alist-get 'choices data)))))

(defun askel--http-request (url body callback)
  "POST BODY (a JSON string) to URL; call CALLBACK with (CONTENT PROVIDER ERR).
CONTENT is the model's reply or nil, PROVIDER the upstream provider name
when reported, ERR a message describing the failure when CONTENT is nil.
Return the buffer of the in-flight request."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("Authorization" . ,(concat "Bearer " (askel--openrouter-key)))))
        (url-request-data (encode-coding-string body 'utf-8)))
    (url-retrieve
     url
     (lambda (status)
       (let* ((data (ignore-errors
                      (progn
                        (goto-char (or (and (boundp 'url-http-end-of-headers)
                                            url-http-end-of-headers)
                                       (point-min)))
                        (askel--json-object-alist
                         (decode-coding-string
                          (buffer-substring-no-properties (point) (point-max))
                          'utf-8)))))
              (content (and data (askel--http-response-content data)))
              (provider (and data (alist-get 'provider data)))
              (err (unless content
                     (or (alist-get 'message (alist-get 'error data))
                         (and (plist-get status :error)
                              (format "%S" (plist-get status :error)))
                         "empty response"))))
         (kill-buffer (current-buffer))
         (funcall callback content provider err)))
     nil t)))

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
        (when askel--last-timing
          (insert (propertize (concat askel--last-timing "\n") 'face 'shadow)))
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

(defun askel--log (question command)
  "Append a record of QUESTION and its COMMAND to `askel-log-buffer'.
COMMAND is the parsed command plist, or nil.  No-op when logging is disabled."
  (when askel-log-buffer
    (with-current-buffer (get-buffer-create askel-log-buffer)
      (special-mode)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
                (or askel--last-timing "")
                "\n  Q: " (string-trim question) "\n")
        (when command
          (insert "  → " (or (plist-get command :code) "") "\n"))
        (insert "\n")))))

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
    (askel--log prompt command)
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
                         (format "%s%s%s\nRun (%s): %s\n[y] run  [e] edit  [b] buffer  [n] no: "
                                 (if askel--last-timing
                                     (concat askel--last-timing "\n")
                                   "")
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
    (message "%s%s"
             (if askel--last-timing (concat askel--last-timing "  ") "")
             (or answer "Askel completed without a command."))))

(defun askel--show-started (question)
  (if (eq askel-display-mode 'buffer)
      (with-current-buffer (askel--buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Asking agent...\n\n")
          (insert question "\n"))
        (pop-to-buffer (current-buffer)))
    (message "Askel: asking agent...")))

(defun askel--abort-pending ()
  "Cancel any in-flight agent request.
An idle persistent agent is left running; a busy one is killed and will
be respawned by the next query."
  (when (process-live-p askel--last-process)
    (delete-process askel--last-process))
  (when askel--rpc-callback
    (askel--rpc-kill))
  (when (buffer-live-p askel--last-url-buffer)
    (let ((proc (get-buffer-process askel--last-url-buffer)))
      (when proc (delete-process proc)))
    (kill-buffer askel--last-url-buffer))
  (setq askel--last-url-buffer nil))

(defun askel--show-failure (headline detail)
  "Show HEADLINE and DETAIL in the `*askel*' buffer."
  (with-current-buffer (askel--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert headline "\n\n" detail))
    (pop-to-buffer (current-buffer))))

(defun askel--finish (question label start raw &optional provider)
  "Record timing for QUESTION and display RAW, the agent's reply."
  (setq askel--last-timing
        (format "%s · %.1fs%s" label (- (float-time) start)
                (if provider (format " (%s)" provider) "")))
  (askel--handle-response question raw))

(defun askel--ask-http (question prompt label start)
  "Ask QUESTION (expanded to PROMPT) via the active HTTP preset."
  (let ((preset (askel--preset)))
    (setq askel--last-url-buffer
          (askel--http-request
           (plist-get preset :url)
           (askel--http-body (or askel-model (plist-get preset :model)) prompt)
           (lambda (content provider err)
             (if content
                 (askel--finish question label start content provider)
               (askel--show-failure "Agent failed." err)))))))

(defun askel--rpc-preset-p ()
  "Return non-nil when the active agent should run as a persistent process."
  (and askel-persistent-agent
       (not (eq askel-agent 'custom))
       (plist-get (askel--preset) :rpc-command)))

(defun askel--rpc-command ()
  "Build the command list that starts the persistent agent."
  (let* ((preset (askel--preset))
         (model (or askel-model (plist-get preset :model)))
         (model-flag (plist-get preset :model-flag)))
    (append (plist-get preset :rpc-command)
            (when (and model model-flag) (list model-flag model)))))

(defun askel--rpc-send (obj)
  "Send OBJ to the persistent agent as one JSON line."
  (process-send-string askel--rpc-process (concat (json-encode obj) "\n")))

(defun askel--rpc-kill ()
  "Stop the persistent agent process, dropping any pending reply."
  (setq askel--rpc-callback nil)
  (when (process-live-p askel--rpc-process)
    (delete-process askel--rpc-process))
  (setq askel--rpc-process nil
        askel--rpc-key nil
        askel--rpc-line-buffer ""
        askel--rpc-turns 0))

(defun askel--rpc-deliver (text)
  "Hand TEXT to the pending reply callback, consuming it."
  (when askel--rpc-callback
    (let ((cb askel--rpc-callback))
      (setq askel--rpc-callback nil)
      (funcall cb text))))

(defun askel--rpc-handle-event (event)
  "Dispatch EVENT from the persistent agent per `askel--rpc-protocol'.

pi-rpc (see pi's docs/rpc.md): on \"agent_end\" ask for the final text
with \"get_last_assistant_text\" and deliver its response.
claude-stream-json: the \"result\" event carries the reply directly."
  (pcase askel--rpc-protocol
    ('pi-rpc
     (pcase (alist-get 'type event)
       ("agent_end"
        (askel--rpc-send '((type . "get_last_assistant_text"))))
       ("response"
        (when (equal (alist-get 'command event) "get_last_assistant_text")
          (askel--rpc-deliver (alist-get 'text (alist-get 'data event)))))))
    ('claude-stream-json
     (when (equal (alist-get 'type event) "result")
       (askel--rpc-deliver (and (not (alist-get 'is_error event))
                                (alist-get 'result event)))))))

(defun askel--rpc-filter (_proc chunk)
  (setq askel--rpc-line-buffer (concat askel--rpc-line-buffer chunk))
  (while (string-match "\n" askel--rpc-line-buffer)
    (let ((line (substring askel--rpc-line-buffer 0 (match-beginning 0))))
      (setq askel--rpc-line-buffer
            (substring askel--rpc-line-buffer (match-end 0)))
      (let ((event (ignore-errors (askel--json-object-alist line))))
        (when event (askel--rpc-handle-event event))))))

(defun askel--rpc-sentinel (proc _event)
  (when (memq (process-status proc) '(exit signal))
    (let ((cb askel--rpc-callback))
      (askel--rpc-kill)
      (when cb
        (askel--show-failure "Persistent agent exited." "")))))

(defun askel--rpc-ensure-process ()
  "Return a live, idle persistent agent process, (re)starting if needed.
Restart when the agent or model changed, or when a previous query is
still in flight (correctness over warmth)."
  (let ((key (list askel-agent (or askel-model
                                   (plist-get (askel--preset) :model)))))
    (unless (and (process-live-p askel--rpc-process)
                 (equal key askel--rpc-key)
                 (null askel--rpc-callback))
      (askel--rpc-kill)
      (setq askel--rpc-key key
            askel--rpc-protocol (plist-get (askel--preset) :rpc-protocol)
            askel--rpc-process
            (make-process
             :name "askel-rpc"
             :buffer nil
             :command (askel--rpc-command)
             :noquery t
             :coding 'utf-8-unix
             ;; A pty truncates our multi-kilobyte JSON lines at the tty
             ;; line-buffer limit (4096 bytes); JSONL needs a pipe.
             :connection-type 'pipe
             :filter #'askel--rpc-filter
             :sentinel #'askel--rpc-sentinel))))
  askel--rpc-process)

(defun askel--rpc-maybe-reset ()
  "Bound session growth per `askel-rpc-reset-after'.
Protocols without an in-band reset get a process restart instead."
  (when (and (>= askel--rpc-turns askel-rpc-reset-after)
             (process-live-p askel--rpc-process))
    (setq askel--rpc-turns 0)
    (if (eq askel--rpc-protocol 'pi-rpc)
        (askel--rpc-send '((type . "new_session")))
      (askel--rpc-kill))))

(defun askel--ask-rpc (question prompt label start)
  "Ask QUESTION (expanded to PROMPT) via the persistent agent process."
  (askel--rpc-maybe-reset)
  (askel--rpc-ensure-process)
  (cl-incf askel--rpc-turns)
  (setq askel--rpc-callback
        (lambda (text)
          (if (and text (not (string-empty-p text)))
              (askel--finish question label start text)
            (askel--show-failure "Agent failed."
                                 "Empty reply from persistent agent."))))
  (pcase askel--rpc-protocol
    ('pi-rpc
     (askel--rpc-send `((type . "prompt") (message . ,prompt))))
    ('claude-stream-json
     (askel--rpc-send
      `((type . "user")
        (message . ((role . "user")
                    (content . [((type . "text") (text . ,prompt))]))))))))

;;;###autoload
(defun askel-stop-agent ()
  "Stop the persistent agent process, if any."
  (interactive)
  (if askel--rpc-process
      (progn (askel--rpc-kill) (message "Askel: persistent agent stopped."))
    (message "Askel: no persistent agent running.")))

(defun askel--ask-cli (question prompt label start)
  "Ask QUESTION (expanded to PROMPT) via the active CLI preset."
  (let* ((output "")
         (out-file (and (askel--output-file-flag) (make-temp-file "askel-out")))
         (command (askel--command-list prompt out-file)))
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
                         (unwind-protect
                             (if (= (process-exit-status proc) 0)
                                 (askel--finish
                                  question label start
                                  (or (and out-file (askel--read-file out-file))
                                      output))
                               (askel--show-failure
                                "Agent failed."
                                (concat "Command: "
                                        (mapconcat #'identity command " ")
                                        "\n\n" output)))
                           (when out-file (ignore-errors (delete-file out-file))))))))))

;;;###autoload
(defun askel-now (question)
  "Ask QUESTION and display an executable response from the configured agent."
  (interactive (list (read-string "Askel: ")))
  (setq askel--last-prompt question)
  (let ((prompt (askel--build-prompt question))
        (label (askel--agent-label))
        (start (float-time)))
    (askel--abort-pending)
    (askel--show-started question)
    (cond
     ((askel--http-preset-p) (askel--ask-http question prompt label start))
     ((askel--rpc-preset-p) (askel--ask-rpc question prompt label start))
     (t (askel--ask-cli question prompt label start)))))

;;;###autoload
(defun askel-set-agent (agent)
  "Switch the active AGENT (a key in `askel-agents', or `custom').
Resets `askel-model' so the new preset's default model is used."
  (interactive
   (list (intern
          (completing-read
           "Askel agent: "
           (append (mapcar (lambda (e) (symbol-name (car e))) askel-agents)
                   '("custom"))
           nil t))))
  (setq askel-agent agent
        askel-model nil)
  (message "Askel agent: %s (model: %s)"
           agent
           (or (and (not (eq agent 'custom)) (plist-get (askel--preset) :model))
               "default")))

;;;###autoload
(defun askel-set-model (model)
  "Override the MODEL for the active agent.
Blank input restores the preset default."
  (interactive (list (read-string "Askel model (blank = preset default): "
                                  (or askel-model ""))))
  (setq askel-model (let ((m (string-trim model)))
                      (unless (string-empty-p m) m)))
  (message "Askel model: %s" (or askel-model "preset default")))

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
(defun askel-show-log ()
  "Show `askel-log-buffer', the running log of askel queries and timings."
  (interactive)
  (unless askel-log-buffer
    (user-error "Logging is disabled (`askel-log-buffer' is nil)"))
  (let ((buf (get-buffer askel-log-buffer)))
    (unless buf
      (user-error "No askel queries logged yet"))
    (with-current-buffer buf (goto-char (point-max)))
    (pop-to-buffer buf)))

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
