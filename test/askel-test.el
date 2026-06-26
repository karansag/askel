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
