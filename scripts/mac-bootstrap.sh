#!/bin/bash
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "==> Installing Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "==> Installing packages..."
brew install tmux starship gh zsh-autosuggestions pyenv
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

# Zsh
link_with_backup "$DOTFILES/.zshrc" "$HOME/.zshrc"

# Config files
mkdir -p "$HOME/.config"
link_with_backup "$DOTFILES/.config/starship.toml" "$HOME/.config/starship.toml"
link_with_backup "$DOTFILES/.config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
link_with_backup "$DOTFILES/.config/neofetch/config.conf" "$HOME/.config/neofetch/config.conf"
link_with_backup "$DOTFILES/.config/neofetch/custom-ascii.txt" "$HOME/.config/neofetch/custom-ascii.txt"

# Wezterm
mkdir -p "$HOME/.config/wezterm/startup"
link_with_backup "$DOTFILES/.config/wezterm/wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"
link_with_backup "$DOTFILES/.config/wezterm/startup/init.lua" "$HOME/.config/wezterm/startup/init.lua"

echo "==> Setting up tmux..."
TPM_PATH="$HOME/.config/tmux/plugins/tpm"
if [ ! -d "$TPM_PATH" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_PATH"
fi
"$TPM_PATH/bin/install_plugins" &>/dev/null || true

echo "Done! Restart your shell."
