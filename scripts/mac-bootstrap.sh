#!/bin/bash

# Re-exec under real bash when another shell started us: `sh scripts/mac-bootstrap.sh`
# runs macOS /bin/sh — bash in POSIX mode — which rejects the process substitution
# below at parse time. Keep this block POSIX-clean; the invoking shell parses it.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH##*/}" != bash ]; then
  exec /bin/bash "$0" "$@"
fi
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "==> Installing Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "==> Installing packages..."
# Install only what's missing — safe to re-run. (`brew install --cask` on an
# already-installed cask exits non-zero, which would abort the script under `set -e`.)
brew_ensure()      { for p in "$@"; do brew list --versions "$p"  >/dev/null 2>&1 || brew install "$p";        done; }
brew_ensure_cask() { for p in "$@"; do brew list --cask "$p"      >/dev/null 2>&1 || brew install --cask "$p"; done; }
brew_ensure tmux starship gh zsh-autosuggestions pyenv jq fastfetch
brew_ensure_cask wezterm font-jetbrains-mono

echo "==> Linking dotfiles..."
# Symlink helper: if the target is an existing real file (not already the
# correct symlink), move it to <target>.backup.<timestamp> before linking.
link_with_backup() {
  local src=$1 dest=$2
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    local backup="${dest}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "  -> Backing up existing $dest to $backup"
    mv "$dest" "$backup"
  fi
  ln -sf "$src" "$dest"
}

# Everything under home/ mirrors $HOME — symlink each file in, recreating parent
# dirs. Add a new config by dropping it into home/; no edit here is needed.
# .claude is handled separately below (CLI guard, settings.json merge), so skip it.
DOTHOME="$DOTFILES/home"
while IFS= read -r -d '' src; do
  dest="$HOME/${src#"$DOTHOME"/}"
  mkdir -p "$(dirname "$dest")"
  link_with_backup "$src" "$dest"
done < <(find "$DOTHOME" -type f -not -path "$DOTHOME/.claude/*" -print0)

# Claude Code statusline, themes, settings — only when the claude CLI is present.
# The script is symlinked; the statusLine *setting* is merged into settings.json
# (not symlinked) because Claude Code owns and rewrites that file at runtime.
if command -v claude >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  link_with_backup "$DOTHOME/.claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"

  # Custom themes are plain files Claude Code only ever reads, so they are symlinked
  # like any other dotfile. (The *selection* lives in settings.json — merged below.)
  if [ -d "$DOTHOME/.claude/themes" ]; then
    mkdir -p "$HOME/.claude/themes"
    for theme in "$DOTHOME"/.claude/themes/*.json; do
      [ -f "$theme" ] || continue   # unmatched glob when the dir holds no .json files
      link_with_backup "$theme" "$HOME/.claude/themes/$(basename "$theme")"
    done
  fi

  settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"

  # Merge one top-level key, no-op when it already holds the wanted value (so a second
  # run changes nothing and leaves no extra backup). $2 is raw JSON, not a bare string.
  claude_backed_up=""
  claude_set() {
    local key=$1 val=$2 tmp
    if [ "$(jq --arg k "$key" --argjson v "$val" '.[$k] == $v' "$settings")" = "true" ]; then
      return 0
    fi
    if [ -z "$claude_backed_up" ]; then
      cp "$settings" "$settings.backup.$(date +%Y%m%d-%H%M%S)"
      claude_backed_up=1
    fi
    tmp=$(mktemp)
    jq --arg k "$key" --argjson v "$val" '.[$k] = $v' "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "  -> set $key in settings.json"
  }

  if ! command -v jq &>/dev/null; then
    echo "  -> jq missing; configure $settings manually"
  elif ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  -> $settings is not valid JSON; leaving it untouched"
  else
    # statusLine: set once, then left alone (the command embeds $HOME).
    if [ "$(jq 'has("statusLine")' "$settings")" = "true" ]; then
      echo "  -> statusLine already configured; leaving it as-is"
    else
      claude_set statusLine \
        "$(jq -n --arg cmd "bash $HOME/.claude/statusline-command.sh" '{type: "command", command: $cmd}')"
    fi

    # Repo conventions, re-asserted on every run: Dracula everywhere, and a terminal bell
    # because Claude Code only sends desktop notifications on Ghostty/Kitty/iTerm2.
    claude_set theme '"custom:dracula"'
    claude_set preferredNotifChannel '"terminal_bell"'
  fi
else
  echo "  -> Skipping Claude statusline (claude CLI not found)"
fi

echo "==> Setting up tmux..."
TPM_PATH="$HOME/.config/tmux/plugins/tpm"
if [ ! -d "$TPM_PATH" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_PATH"
fi
"$TPM_PATH/bin/install_plugins" &>/dev/null || true

echo "==> Setting wallpaper..."
WALLPAPER="$DOTFILES/assets/wallpapers/macos.png"
if [ -f "$WALLPAPER" ]; then
  # Best-effort: the first run triggers an Automation permission prompt (terminal
  # → System Events). Never fail the bootstrap over a cosmetic step.
  if osascript -e "tell application \"System Events\" to set picture of every desktop to \"$WALLPAPER\"" 2>/dev/null; then
    echo "  -> set to assets/wallpapers/macos.png"
  else
    echo "  -> skipped — grant Automation permission and re-run, or set it in System Settings → Wallpaper"
  fi
fi

echo "Done! Restart your shell."
