#!/bin/bash
set -euo pipefail

DOTFILES="$HOME/github/prateek11rai/dotfiles"

echo "Linking dotfiles..."

# .zshrc
ln -sf "$DOTFILES/.zshrc" "$HOME/.zshrc"

# .config files
ln -sf "$DOTFILES/.config/starship.toml" "$HOME/.config/starship.toml"
ln -sf "$DOTFILES/.config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"

# Wezterm
mkdir -p "$HOME/.config/wezterm/startup"
ln -sf "$DOTFILES/.config/wezterm/wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"
ln -sf "$DOTFILES/.config/wezterm/startup/init.lua" "$HOME/.config/wezterm/startup/init.lua"

echo "Done! Restart your shell for changes to take effect."
