;;; askel-test.el --- Tests for askel.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run: emacs -batch -L . -l test/askel-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'askel)

;;; askel--command-list: preset wiring -------------------------------------

(ert-deftest askel-command-list-pi ()
  "The pi preset passes no model flag and appends the prompt last."
  (let ((askel-agent 'pi) (askel-model nil))
    (should (equal (askel--command-list "PROMPT")
                   '("pi" "--tools" "read,bash,grep,find,ls"
                     "--thinking" "low" "--no-context-files" "-p" "PROMPT")))))

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

(provide 'askel-test)
;;; askel-test.el ends here
