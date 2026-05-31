#!/bin/bash
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "==> Installing Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "==> Installing packages..."
brew install tmux starship gh zsh-autosuggestions
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
# Zsh
ln -sf "$DOTFILES/.zshrc" "$HOME/.zshrc"

# Config files
mkdir -p "$HOME/.config"
ln -sf "$DOTFILES/.config/starship.toml" "$HOME/.config/starship.toml"
ln -sf "$DOTFILES/.config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
ln -sf "$DOTFILES/.config/neofetch/config.conf" "$HOME/.config/neofetch/config.conf"
ln -sf "$DOTFILES/.config/neofetch/custom-ascii.txt" "$HOME/.config/neofetch/custom-ascii.txt"

# Wezterm
mkdir -p "$HOME/.config/wezterm/startup"
ln -sf "$DOTFILES/.config/wezterm/wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"
ln -sf "$DOTFILES/.config/wezterm/startup/init.lua" "$HOME/.config/wezterm/startup/init.lua"

echo "==> Setting up tmux..."
TPM_PATH="$HOME/.config/tmux/plugins/tpm"
if [ ! -d "$TPM_PATH" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_PATH"
fi
"$TPM_PATH/bin/install_plugins" &>/dev/null || true

echo "Done! Restart your shell."
