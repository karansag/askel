;;; askel-test.el --- Tests for askel.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run: emacs -batch -L . -l test/askel-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'askel)

;;; askel--command-list: preset wiring -------------------------------------

(ert-deftest askel-command-list-pi ()
  "The pi preset passes its GLM model and appends the prompt last."
  (let ((askel-agent 'pi) (askel-model nil))
    (should (equal (askel--command-list "PROMPT")
                   '("pi" "--tools" "read,bash,grep,find,ls"
                     "--thinking" "low" "--no-context-files" "-p"
                     "--model" "z-ai/glm-5.2" "PROMPT")))))

(ert-deftest askel-command-list-opencode ()
  "The opencode preset runs `run' with its provider/model."
  (let ((askel-agent 'opencode) (askel-model nil))
    (should (equal (askel--command-list "PROMPT")
                   '("opencode" "run" "--model" "openrouter/z-ai/glm-5.2"
                     "PROMPT")))))

(ert-deftest askel-agent-label ()
  "The agent label combines agent and effective model."
  (let ((askel-agent 'claude) (askel-model nil))
    (should (equal (askel--agent-label) "claude/sonnet")))
  (let ((askel-agent 'claude) (askel-model "haiku"))
    (should (equal (askel--agent-label) "claude/haiku")))
  (let ((askel-agent 'custom) (askel-custom-command '("x")))
    (should (equal (askel--agent-label) "custom"))))

(ert-deftest askel-command-list-claude ()
  "The claude preset injects its default model via --model."
  (let ((askel-agent 'claude) (askel-model nil))
    (should (equal (askel--command-list "PROMPT")
                   '("claude" "-p" "--model" "sonnet" "PROMPT")))))

(ert-deftest askel-command-list-codex ()
  "The codex preset runs `exec' with low reasoning effort and a model."
  (let ((askel-agent 'codex) (askel-model nil))
    (should (equal (askel--command-list "PROMPT")
                   '("codex" "exec" "--skip-git-repo-check"
                     "-c" "model_reasoning_effort=low"
                     "--model" "gpt-5.4" "PROMPT")))))

(ert-deftest askel-command-list-codex-output-file ()
  "Codex inserts its :output-file-flag when an output file is supplied."
  (let ((askel-agent 'codex) (askel-model nil))
    (should (equal (askel--command-list "PROMPT" "/tmp/out")
                   '("codex" "exec" "--skip-git-repo-check"
                     "-c" "model_reasoning_effort=low"
                     "--model" "gpt-5.4"
                     "--output-last-message" "/tmp/out" "PROMPT")))
    ;; pi has no :output-file-flag, so the file is ignored.
    (let ((askel-agent 'pi))
      (should-not (member "/tmp/out" (askel--command-list "PROMPT" "/tmp/out"))))))

(ert-deftest askel-command-list-model-override ()
  "`askel-model' overrides the preset's default model."
  (let ((askel-agent 'claude) (askel-model "haiku"))
    (should (equal (askel--command-list "PROMPT")
                   '("claude" "-p" "--model" "haiku" "PROMPT")))))

(ert-deftest askel-command-list-custom ()
  "Custom agent uses `askel-custom-command' verbatim plus the prompt."
  (let ((askel-agent 'custom) (askel-custom-command '("my-agent" "--flag")))
    (should (equal (askel--command-list "PROMPT")
                   '("my-agent" "--flag" "PROMPT")))))

(ert-deftest askel-command-list-unknown-agent-errors ()
  "An unknown agent key signals a `user-error'."
  (let ((askel-agent 'nope))
    (should-error (askel--command-list "PROMPT") :type 'user-error)))

(ert-deftest askel-command-list-custom-unset-errors ()
  "Custom agent without `askel-custom-command' signals a `user-error'."
  (let ((askel-agent 'custom) (askel-custom-command nil))
    (should-error (askel--command-list "PROMPT") :type 'user-error)))

;;; openrouter HTTP preset --------------------------------------------------

(ert-deftest askel-default-agent-is-http ()
  "The default agent is the direct-HTTP openrouter preset."
  (should (eq (default-value 'askel-agent) 'openrouter))
  (let ((askel-agent 'openrouter))
    (should (askel--http-preset-p)))
  (let ((askel-agent 'pi))
    (should-not (askel--http-preset-p)))
  (let ((askel-agent 'custom))
    (should-not (askel--http-preset-p))))

(ert-deftest askel-http-body-openrouter ()
  "The openrouter body carries model, prompt, and fast-provider routing."
  (let* ((askel-agent 'openrouter) (askel-model nil)
         (body (askel--json-object-alist
                (askel--http-body (askel--preset) "PROMPT"))))
    (should (equal (alist-get 'model body) "z-ai/glm-5.2"))
    (should (equal (alist-get 'content (car (alist-get 'messages body)))
                   "PROMPT"))
    (should (equal (alist-get 'sort (alist-get 'provider body)) "throughput"))
    (should (null (alist-get 'enabled (alist-get 'reasoning body))))))

(ert-deftest askel-http-body-local ()
  "The local preset omits model, auth, and OpenRouter-only fields."
  (let* ((askel-agent 'local) (askel-model nil)
         (preset (askel--preset))
         (body (askel--json-object-alist (askel--http-body preset "PROMPT"))))
    (should-not (assq 'model body))
    (should-not (assq 'provider body))
    (should (equal (alist-get 'content (car (alist-get 'messages body)))
                   "PROMPT"))
    (should (null (askel--http-key preset))))
  ;; askel-model still applies, e.g. for Ollama
  (let* ((askel-agent 'local) (askel-model "qwen3:8b")
         (body (askel--json-object-alist
                (askel--http-body (askel--preset) "PROMPT"))))
    (should (equal (alist-get 'model body) "qwen3:8b"))))

(ert-deftest askel-http-key-forms ()
  "A :key may be a literal string, a function, or absent."
  (should (equal (askel--http-key '(:key "sk-lit")) "sk-lit"))
  (should (equal (askel--http-key `(:key ,(lambda () "sk-fn"))) "sk-fn"))
  (should (null (askel--http-key '(:url "x")))))

(ert-deftest askel-http-response-content ()
  "Message text is read from choices[0].message.content."
  (let ((data (askel--json-object-alist
               "{\"choices\":[{\"message\":{\"content\":\"hi\"}}],\"provider\":\"Wafer\"}")))
    (should (equal (askel--http-response-content data) "hi"))
    (should (equal (alist-get 'provider data) "Wafer"))))

(ert-deftest askel-openrouter-key-sources ()
  "The key comes from the defcustom first, then a CLI auth file."
  (let ((askel-openrouter-api-key "sk-custom"))
    (should (equal (askel--openrouter-key) "sk-custom")))
  (let ((file (make-temp-file "askel-auth" nil ".json"
                              "{\"openrouter\":{\"type\":\"api_key\",\"key\":\"sk-file\"}}")))
    (unwind-protect
        (should (equal (askel--auth-file-openrouter-key file) "sk-file"))
      (delete-file file)))
  (should (null (askel--auth-file-openrouter-key "/nonexistent/auth.json"))))

;;; persistent agent (RPC) ---------------------------------------------------

(ert-deftest askel-rpc-preset-selection ()
  "Persistent mode applies only to presets with :rpc-command, when enabled."
  (let ((askel-persistent-agent t))
    (let ((askel-agent 'pi)) (should (askel--rpc-preset-p)))
    (let ((askel-agent 'openrouter)) (should-not (askel--rpc-preset-p)))
    (let ((askel-agent 'custom)) (should-not (askel--rpc-preset-p))))
  (let ((askel-persistent-agent nil) (askel-agent 'pi))
    (should-not (askel--rpc-preset-p))))

(ert-deftest askel-rpc-command-pi ()
  "The pi persistent command runs RPC mode with the preset's model."
  (let ((askel-agent 'pi) (askel-model nil))
    (should (equal (askel--rpc-command)
                   '("pi" "--mode" "rpc" "--no-session" "--no-context-files"
                     "--tools" "read,bash,grep,find,ls" "--thinking" "low"
                     "--model" "z-ai/glm-5.2")))))

(ert-deftest askel-rpc-pi-event-flow ()
  "agent_end triggers a text request; its response reaches the callback."
  (let* ((askel--rpc-protocol 'pi-rpc)
         (sent nil)
         (got nil)
         (askel--rpc-callback (lambda (text) (setq got text))))
    (cl-letf (((symbol-function 'askel--rpc-send)
               (lambda (obj) (setq sent obj))))
      (askel--rpc-handle-event '((type . "agent_end")))
      (should (equal sent '((type . "get_last_assistant_text"))))
      (askel--rpc-handle-event
       '((type . "response")
         (command . "get_last_assistant_text")
         (data . ((text . "{\"answer\":\"ok\"}")))))
      (should (equal got "{\"answer\":\"ok\"}"))
      ;; the callback is consumed; a duplicate response is ignored
      (should (null askel--rpc-callback)))))

(ert-deftest askel-rpc-claude-event-flow ()
  "The claude result event delivers its text; errors deliver nil."
  (let* ((askel--rpc-protocol 'claude-stream-json)
         (got :untouched)
         (askel--rpc-callback (lambda (text) (setq got text))))
    (askel--rpc-handle-event '((type . "system") (subtype . "init")))
    (should (eq got :untouched))
    (askel--rpc-handle-event '((type . "result") (result . "{\"answer\":\"ok\"}")))
    (should (equal got "{\"answer\":\"ok\"}")))
  (let* ((askel--rpc-protocol 'claude-stream-json)
         (got :untouched)
         (askel--rpc-callback (lambda (text) (setq got text))))
    (askel--rpc-handle-event '((type . "result") (is_error . t) (result . "boom")))
    (should (null got))))

(ert-deftest askel-rpc-filter-reassembles-lines ()
  "The filter handles JSON lines split across chunks and skips non-JSON."
  (let ((askel--rpc-line-buffer "")
        (events nil))
    (cl-letf (((symbol-function 'askel--rpc-handle-event)
               (lambda (ev) (push ev events))))
      (askel--rpc-filter nil "noise\n{\"type\":\"agent")
      (askel--rpc-filter nil "_start\"}\n{\"type\":\"agent_end\"}\n")
      (should (equal (nreverse events)
                     '(((type . "agent_start")) ((type . "agent_end"))))))))

;;; askel--extract-json / parse --------------------------------------------

(ert-deftest askel-extract-json-plain ()
  (should (equal (askel--extract-json "{\"a\": 1}") "{\"a\": 1}")))

(ert-deftest askel-extract-json-fenced ()
  (should (equal (askel--extract-json "```json\n{\"a\": 1}\n```")
                 "{\"a\": 1}")))

(ert-deftest askel-extract-json-with-prefix ()
  (should (equal (askel--extract-json "Here you go:\n{\"a\": 1}")
                 "{\"a\": 1}")))

(ert-deftest askel-parse-response-roundtrip ()
  (let ((parsed (askel--parse-response "{\"answer\": \"hi\"}")))
    (should (equal (askel--alist-get 'answer parsed) "hi"))))

(ert-deftest askel-parse-response-garbage-is-nil ()
  (should (null (askel--parse-response "not json at all"))))

;;; askel--log ------------------------------------------------------------

(ert-deftest askel-log-appends-entry ()
  "`askel--log' appends the question and command code to the log buffer."
  (let ((askel-log-buffer "*askel-log-test*")
        (askel--last-timing "claude/sonnet · 1.0s"))
    (unwind-protect
        (progn
          (askel--log "make the font bigger"
                      '(:language "elisp" :code "(text-scale-increase 2)"))
          (with-current-buffer askel-log-buffer
            (let ((s (buffer-string)))
              (should (string-match-p "make the font bigger" s))
              (should (string-match-p "(text-scale-increase 2)" s))
              (should (string-match-p "claude/sonnet" s)))))
      (when (get-buffer "*askel-log-test*")
        (kill-buffer "*askel-log-test*")))))

(ert-deftest askel-log-disabled-is-noop ()
  "Logging is a no-op when `askel-log-buffer' is nil."
  (let ((askel-log-buffer nil))
    (should (null (askel--log "q" nil)))))

(provide 'askel-test)
;;; askel-test.el ends here
