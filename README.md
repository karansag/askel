# askel.el

Ask Emacs for things in plain English; get back an executable Emacs Lisp or
shell command that you read and confirm before it runs.

![askel demo](demo.gif)

```
M-x askel-now RET  split the window and open my init file RET

  openrouter/z-ai/glm-5.2 · 1.8s (Wafer)
  Splits the window and opens your Emacs init file.
  Run (elisp): (progn (split-window-right) (find-file user-init-file))
  [y] run  [e] edit  [b] buffer  [n] no:
```

## Features

- **Natural language → a real command**, shown before it runs.
- **Three kinds of backend.** A hosted API (OpenRouter, the default), any
  local OpenAI-compatible server (llama-server, Ollama), or a CLI agent
  (`pi`, `claude`, `codex`, `opencode`, or your own).
- **Persistent CLI agents.** `pi` and `claude` keep one process alive between
  queries, so a flat-rate subscription (e.g. a Claude account) is fast too —
  no API key needed.
- **Confirm-before-run.** Run, edit-then-run, inspect, or skip every command.
- **Follow-ups with history**, per-query timing, and a running query log.

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

## Pick a backend

askel can talk to a hosted API, a local model server, or a CLI agent. Pick
whichever matches what you already have:

**Have an [OpenRouter](https://openrouter.ai) key** (or use the `pi`/`opencode`
CLIs, whose stored key is reused)? You're done — `openrouter` is the default:

```elisp
;; key comes from askel-openrouter-api-key, $OPENROUTER_API_KEY,
;; ~/.pi/agent/auth.json, or ~/.local/share/opencode/auth.json
(setq askel-openrouter-api-key "sk-or-...")            ; if none of the above
(setq askel-model "google/gemini-2.5-flash")           ; optional: fastest tested
```

**Have a CLI agent subscription** (e.g. a Claude account) and no API credits?
Use a persistent CLI agent — askel keeps one process alive between queries:

```elisp
(setq askel-agent 'claude          ; or 'pi
      askel-model "haiku")         ; optional; preset default is sonnet
```

**Run models locally?** Point the `local` preset at any OpenAI-compatible
server:

```elisp
(setq askel-agent 'local)
;; llama-server on localhost:8080 works as is; for Ollama:
(setf (alist-get 'local askel-agents)
      '(:type http :url "http://localhost:11434/v1/chat/completions"))
(setq askel-model "qwen3:8b")      ; Ollama requires a model name
```

| Preset | `askel-agent` | Default model | Notes |
|--------|---------------|---------------|-------|
| OpenRouter (default) | `openrouter` | `z-ai/glm-5.2` | direct HTTP; needs an API key |
| Local server | `local` | (server's model) | direct HTTP to `localhost:8080`; no key |
| Pi | `pi` | `z-ai/glm-5.2` | persistent process; `pi --list-models` |
| Claude | `claude` | `sonnet` | persistent process; `haiku` is faster |
| Codex | `codex` | `gpt-5.4` | `codex exec`, one-shot |
| OpenCode | `opencode` | `openrouter/z-ai/glm-5.2` | `opencode run`, one-shot |

CLI presets need their command installed and on Emacs's `exec-path`
(e.g. `(add-to-list 'exec-path (expand-file-name "~/.opencode/bin"))`).

### Latency

Measured with a realistic askel prompt (~23.5k chars): one-shot CLI calls
cost 20-26s, dominated by process boot and session setup, not the model.
The two fixes, in numbers:

- **Direct HTTP** (`openrouter`): 1.4-10s depending on the upstream provider.
  The request pins `provider: {sort: "throughput"}` because OpenRouter's
  default routing can pick a provider that takes 10-20s just to prefill.
  `google/gemini-2.5-flash` and `anthropic/claude-haiku-4.5` were the most
  consistent (1.4-2.5s).
- **Persistent CLI agents** (`pi`, `claude`): the first query pays boot plus
  full prompt prefill (6-8s); warm queries skip both and hit the provider's
  prompt cache — `claude`/haiku answered warm queries in ~4s (vs 26.4s
  one-shot), `pi`/GLM-5.2 in 2-13s (vs 20.3s).

### Persistent agent details

Persistence is on by default (`askel-persistent-agent`); set it to nil for
one-shot calls. Since each query appends its full prompt to the live session,
askel starts a fresh session every `askel-rpc-reset-after` (default 10)
queries; the next query then pays full cost once. Switching agent or model
restarts the process automatically, `M-x askel-stop-agent` stops it, and a
query issued while another is in flight kills and respawns it (correctness
over warmth).

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
- `M-x askel-stop-agent` — stop the persistent CLI agent process, if any.

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
(setq askel-agent 'claude)   ; openrouter | local | pi | claude | codex | opencode | custom
(setq askel-model "haiku")   ; nil = use the active preset's default model
```

For any other CLI, use the `custom` agent and give the full command — the prompt
is appended as the final argument:

```elisp
(setq askel-agent 'custom
      askel-custom-command '("my-agent" "--model" "foo" "-p"))
```

Add or edit presets directly in `askel-agents`. HTTP presets (`:type http`)
take `:url`, `:model` (nil to omit it from the request), `:key` (a string, a
function returning one, or nil for no auth), and `:body-extra` (extra
request-body fields). CLI presets take `:command`, `:args`, `:model`,
`:model-flag`, and optionally `:output-file-flag` (for agents whose stdout is
too noisy to parse) plus `:rpc-command`/`:rpc-protocol` for those that support
a persistent process (`pi`, `claude`).

| Variable | Default | Purpose |
|----------|---------|---------|
| `askel-agent` | `openrouter` | active agent preset, or `custom` |
| `askel-model` | `nil` | model override for the active agent |
| `askel-openrouter-api-key` | `nil` | API key for the `openrouter` preset; auto-discovered when nil |
| `askel-agents` | (6 presets) | the preset definitions |
| `askel-custom-command` | `nil` | command list for the `custom` agent |
| `askel-persistent-agent` | `t` | keep `pi`/`claude` alive as a persistent process between queries |
| `askel-rpc-reset-after` | `10` | queries before the persistent agent's session is reset |
| `askel-display-mode` | `minibuffer` | `minibuffer` or `buffer` |
| `askel-log-buffer` | `*askel-log*` | running query log; nil to disable |
| `askel-config-file` | `~/.emacs.el` | config file sent as context |
| `askel-context-max-config-chars` | `24000` | cap on config chars sent (0 to disable) |
| `askel-context-max-buffer-chars` | `4000` | cap on current-buffer chars sent |

## How it works

askel builds a prompt (your request + Emacs context) and sends it to the
active backend — an HTTP call for `openrouter`/`local`, a subprocess for the
CLI presets — asking for a JSON reply describing a single command. askel
parses that, shows you the command, and runs it only when you confirm.

## Safety

`askel-now` runs model-generated **Emacs Lisp and shell** code. Every command is
shown and confirmed before it executes — read it before you accept.

## Privacy

Each query sends a prefix of your `~/.emacs.el`, the current buffer, and any
active region as context. With the default `openrouter` preset this goes to
OpenRouter's API; with a CLI preset, to that CLI's upstream provider; with the
`local` preset it never leaves your machine. Lower or zero out
`askel-context-max-config-chars` / `askel-context-max-buffer-chars` to bound
or disable this.

## License

GPL-3.0-or-later.
