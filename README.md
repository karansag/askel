# askel.el

Ask Emacs for things in plain English; get back an executable Emacs Lisp or
shell command that you read and confirm before it runs.

![askel demo](demo.gif)

```
M-x askel-now RET  split the window and open my init file RET

  claude/sonnet · 4.9s
  Splits the window and opens your Emacs init file.
  Run (elisp): (progn (split-window-right) (find-file user-init-file))
  [y] run  [e] edit  [b] buffer  [n] no:
```

## Features

- **Natural language → a real command**, shown before it runs.
- **Pluggable agents.** Built-in presets for `pi`, `claude`, `codex`, and
  `opencode`; switch agent and model on the fly, or plug in your own CLI.
- **Follow-ups with history.** Ask a follow-up and the previous exchange is
  included as context.
- **Confirm-before-run.** Run, edit-then-run, inspect, or skip every command.
- **Per-query timing** (`agent/model · N.Ns`) so you can compare agents.

## Install

askel is a single file. Put it on your `load-path` and require it:

```elisp
(add-to-list 'load-path "/path/to/askel")
(require 'askel)

;; Optional: a global key for the main entry point.
(global-set-key (kbd "C-c a") #'askel-now)
```

With `use-package`:

```elisp
(use-package askel
  :load-path "/path/to/askel"
  :bind ("C-c a" . askel-now))
```

## Agents

askel shells out to a CLI agent. Whichever preset is active, that CLI must be
installed and on Emacs's `exec-path`.

| Agent | `askel-agent` | Default model | Notes |
|-------|---------------|---------------|-------|
| Pi (default) | `pi` | `z-ai/glm-5.2` | tool-enabled agent; `pi --list-models` lists others |
| Claude | `claude` | `sonnet` | set `askel-model` to `haiku` for lower latency |
| Codex | `codex` | `gpt-5.4` | `codex exec`, low reasoning; reads the reply via `--output-last-message` |
| OpenCode | `opencode` | `openrouter/z-ai/glm-5.2` | `opencode run`; `opencode models` lists others |

All four presets are verified working end-to-end.

If an agent lives outside your default `PATH` (e.g. OpenCode under
`~/.opencode/bin`), add it to `exec-path`:

```elisp
(add-to-list 'exec-path (expand-file-name "~/.opencode/bin"))
```

## Usage

`M-x askel-now`, type a request, and the agent replies with a command. How the
reply is presented depends on `askel-display-mode`:

- `minibuffer` (default) — a one-line prompt with the command and these keys:

  | Key | Action |
  |-----|--------|
  | `y` | run the command |
  | `e` | edit it first, then run |
  | `b` | open the full `*askel*` buffer |
  | `n` | skip |

- `buffer` — always show the `*askel*` buffer, which has its own keys:

  | Key | Command | Action |
  |-----|---------|--------|
  | `RET` | `askel-run-last-command` | run the command |
  | `e` | `askel-edit-last-command` | edit, then run |
  | `r` | `askel-reply` | ask a follow-up (keeps history) |
  | `g` | `askel-retry` | re-run the last request |
  | `b` | `askel-show-last-response` | redisplay the last response |
  | `q` | `quit-window` | close the buffer |

Other commands:

- `M-x askel-reply` — ask a follow-up about the previous response.
- `M-x askel-retry` — re-run the last request.
- `M-x askel-set-agent` / `M-x askel-set-model` — switch agent / model.
- `M-x askel-show-log` — open the running log of past queries.

### Log buffer

Every query appends an entry to `*askel-log*` (timestamp, agent/model, timing,
the question, and the resulting command), so you have a persistent record and
can compare agents over time:

```
[2026-06-25 21:30:14] claude/sonnet · 4.9s
  Q: make the font bigger
  → (text-scale-increase 2)
```

Open it with `M-x askel-show-log`. Set `askel-log-buffer` to nil to disable
logging, or to another name to relocate it.

## Configuration

Switch agent and model interactively (`askel-set-agent` / `askel-set-model`) or
set the variables in your init:

```elisp
(setq askel-agent 'claude)   ; pi | claude | codex | opencode | custom
(setq askel-model "haiku")   ; nil = use the active preset's default model
```

For any other CLI, use the `custom` agent and give the full command — the prompt
is appended as the final argument:

```elisp
(setq askel-agent 'custom
      askel-custom-command '("my-agent" "--model" "foo" "-p"))
```

Add or edit presets directly in `askel-agents`. Each preset is a plist with
`:command`, `:args`, `:model`, `:model-flag`, and optionally `:output-file-flag`
(for agents whose stdout is too noisy to parse — the final message is read from
a file instead).

| Variable | Default | Purpose |
|----------|---------|---------|
| `askel-agent` | `pi` | active agent preset, or `custom` |
| `askel-model` | `nil` | model override for the active agent |
| `askel-agents` | (4 presets) | the preset definitions |
| `askel-custom-command` | `nil` | command list for the `custom` agent |
| `askel-display-mode` | `minibuffer` | `minibuffer` or `buffer` |
| `askel-log-buffer` | `*askel-log*` | running query log; nil to disable |
| `askel-config-file` | `~/.emacs.el` | config file sent as context |
| `askel-context-max-config-chars` | `24000` | cap on config chars sent (0 to disable) |
| `askel-context-max-buffer-chars` | `4000` | cap on current-buffer chars sent |

## How it works

askel builds a prompt (your request + Emacs context), runs the agent CLI with
it, and asks the agent to reply as JSON describing a single command. It parses
that, shows you the command, and runs it only when you confirm.

## Safety

`askel-now` runs model-generated **Emacs Lisp and shell** code. Every command is
shown and confirmed before it executes — read it before you accept.

## Privacy

Each query sends a prefix of your `~/.emacs.el`, the current buffer, and any
active region to the agent as context. Lower or zero out
`askel-context-max-config-chars` / `askel-context-max-buffer-chars` to bound or
disable this.

## License

GPL-3.0-or-later.
