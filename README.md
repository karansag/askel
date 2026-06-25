# askel.el

Ask Emacs for things in natural language; get back an executable Emacs Lisp or
shell command that you confirm before it runs.

`M-x askel-now`, type a request (e.g. *"split the window and open my init file"*),
and the agent returns a command. From the minibuffer you can run it (`y`), edit
it first (`e`), open the full `*askel*` buffer (`b`), or skip (`n`).

## Requirements

- An agent CLI on your `PATH`. By default this is the [`pi`](https://example.invalid)
  command (`askel-agent-command`); point that variable at your own agent if you
  use a different one.

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
