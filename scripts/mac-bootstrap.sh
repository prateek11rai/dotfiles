#!/bin/bash
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "==> Installing Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "==> Installing packages..."
brew install tmux starship gh zsh-autosuggestions pyenv jq
brew install --cask wezterm font-jetbrains-mono

# Neofetch is archived and disabled in Homebrew — install from source
if ! command -v neofetch &>/dev/null; then
  brew install neofetch 2>/dev/null || {
    echo "  -> Installing neofetch from GitHub..."
    curl -sSL https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch \
      -o /usr/local/bin/neofetch
    chmod +x /usr/local/bin/neofetch
  }
fi

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
# .claude is handled separately below (CLI guard + settings.json merge), so skip it.
DOTHOME="$DOTFILES/home"
while IFS= read -r -d '' src; do
  dest="$HOME/${src#"$DOTHOME"/}"
  mkdir -p "$(dirname "$dest")"
  link_with_backup "$src" "$dest"
done < <(find "$DOTHOME" -type f -not -path "$DOTHOME/.claude/*" -print0)

# Claude Code statusline — only when the claude CLI is present.
# The script is symlinked; the statusLine *setting* is merged into settings.json
# (not symlinked) because Claude Code owns and rewrites that file at runtime.
if command -v claude >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  link_with_backup "$DOTHOME/.claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"

  settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  if ! command -v jq &>/dev/null; then
    echo "  -> jq missing; add the statusLine block to $settings manually"
  elif ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  -> $settings is not valid JSON; leaving it untouched"
  elif [ "$(jq 'has("statusLine")' "$settings")" = "true" ]; then
    echo "  -> statusLine already configured; leaving it as-is"
  else
    cp "$settings" "$settings.backup.$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp)
    jq --arg cmd "bash $HOME/.claude/statusline-command.sh" \
       '.statusLine = {type: "command", command: $cmd}' "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "  -> added statusLine to settings.json"
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
