# askel.el

Ask Emacs for things in natural language; get back an executable Emacs Lisp or
shell command that you confirm before it runs.

`M-x askel-now`, type a request (e.g. *"split the window and open my init file"*),
and the agent returns a command. From the minibuffer you can run it (`y`), edit
it first (`e`), open the full `*askel*` buffer (`b`), or skip (`n`).

## Requirements

An agent CLI on your `PATH`. askel ships presets for three:

| Agent | `askel-agent` | Default model | Notes |
|-------|---------------|---------------|-------|
| pi (default) | `pi` | `z-ai/glm-5.2` | tool-enabled agent; `pi --list-models` shows others |
| Claude | `claude` | `sonnet` | set `askel-model` to `haiku` for lower latency |
| Codex | `codex` | `gpt-5.4` | `codex exec`, low reasoning; reads the clean reply via `--output-last-message` |
| OpenCode | `opencode` | `openrouter/z-ai/glm-5.2` | `opencode run`; needs the `opencode` CLI on `PATH` |

All four presets — `pi`, `claude`, `codex`, `opencode` — are verified working
end-to-end. After each query, the `*askel*` buffer and minibuffer prompt show a
timing line (e.g. `claude/haiku · 6.6s`) so you can compare agents and models.

Whichever preset is active, that CLI must be installed. Switch interactively
with `M-x askel-set-agent` and `M-x askel-set-model`, or set the variables:

```elisp
(setq askel-agent 'claude)   ; pi | claude | codex | custom
(setq askel-model "haiku")   ; nil = use the preset's default model
```

For anything else, set `askel-agent` to `custom` and give the full command in
`askel-custom-command` (the prompt is appended as the last argument):

```elisp
(setq askel-agent 'custom
      askel-custom-command '("my-agent" "--model" "foo" "-p"))
```

Add or edit presets in `askel-agents`.

## Install

```elisp
(add-to-list 'load-path "/path/to/askel")
(require 'askel)
```

## Privacy

Each askel sends a prefix of your `~/.emacs.el`, the current buffer, and any
active region to the agent as context. See `askel-context-max-config-chars` and
`askel-context-max-buffer-chars` to bound or disable this.

## Safety

`askel-now` runs model-generated **elisp and shell** code. Every command is shown
and confirmed before it executes — read it before you accept.

## License

GPL-3.0-or-later.
