# dotfiles — agent & contributor guide

Personal terminal dotfiles. This file is the source of truth for how to work in
this repo; `CLAUDE.md` is a symlink to it, so [Claude Code](https://claude.com/claude-code)
and other agent tools read the same rules. Human setup instructions live in
[README.md](README.md).

## Commits

- **No `Co-Authored-By` trailer.** This is a personal repo — commits are authored
  solely by the owner. Do not append agent/co-author trailers.

## Testing = running the bootstrap

There is no unit suite. The test is `scripts/mac-bootstrap.sh` run end-to-end:

- It must stay **idempotent** — safe to run any number of times. A second run must
  finish with no errors and repeat no work (no reinstalls, no clobbered configs,
  no duplicate symlinks).
- After changing the bootstrap or anything under `home/`, run it **twice** and
  confirm the second run is clean.
- Preserve the existing guards when adding steps: `brew_ensure` / `brew_ensure_cask`
  (skip already-installed packages), back up a real file before symlinking over it,
  and *merge* into files an app owns at runtime (e.g. `~/.claude/settings.json`)
  rather than overwriting them.

## Conventions

- **Theme: Dracula, everywhere.** Match the Dracula palette in any new tool config.
  See [draculatheme.com](https://draculatheme.com/).
- **Adding a dotfile:** drop it under `home/` (which mirrors `$HOME`) — the bootstrap
  auto-discovers and symlinks it, no bootstrap edit needed. `.claude/` is
  special-cased (statusline links only when the `claude` CLI exists; its setting is
  merged into `settings.json`, not symlinked). Details in the README.

## Workflow this setup is built around

Session-centric and minimal: WezTerm is a bare window and tmux does the
multiplexing — one session per context, mostly a single window each, switched via
`prefix + s` (prefix is remapped to `Ctrl-a`). Sessions auto-save and restore across
reboots. Full keymap in the README.
