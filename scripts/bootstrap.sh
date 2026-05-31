#!/bin/bash
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "Linking dotfiles..."

# .zshrc
ln -sf "$DOTFILES/.zshrc" "$HOME/.zshrc"

# .config files
ln -sf "$DOTFILES/.config/starship.toml" "$HOME/.config/starship.toml"
ln -sf "$DOTFILES/.config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"

# Tmux Plugin Manager
TPM_PATH="$HOME/.config/tmux/plugins/tpm"
if [ ! -d "$TPM_PATH" ]; then
  echo "Installing tpm..."
  git clone https://github.com/tmux-plugins/tpm "$TPM_PATH"
fi
"$TPM_PATH/bin/install_plugins" &>/dev/null || true

# Wezterm
mkdir -p "$HOME/.config/wezterm/startup"
ln -sf "$DOTFILES/.config/wezterm/wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"
ln -sf "$DOTFILES/.config/wezterm/startup/init.lua" "$HOME/.config/wezterm/startup/init.lua"

# Neofetch
mkdir -p "$HOME/.config/neofetch"
ln -sf "$DOTFILES/.config/neofetch/config.conf" "$HOME/.config/neofetch/config.conf"
ln -sf "$DOTFILES/.config/neofetch/custom-ascii.txt" "$HOME/.config/neofetch/custom-ascii.txt"

echo "Done! Restart your shell for changes to take effect."
