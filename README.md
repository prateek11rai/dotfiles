# dotfiles

Personal dotfiles for macOS terminal setup.

## Quick start

```sh
git clone git@github.com:prateek11rai/dotfiles.git ~/github/prateek11rai/dotfiles
~/github/prateek11rai/dotfiles/scripts/mac-bootstrap.sh
```

## What's included

| Tool | Config | Bootstrapped |
|------|--------|--------------|
| WezTerm | `~/.config/wezterm/wezterm.lua` | `brew install --cask wezterm` |
| Tmux | `~/.config/tmux/tmux.conf` | `brew install tmux` + tpm & plugins |
| Starship | `~/.config/starship.toml` | `brew install starship` |
| Neofetch | `~/.config/neofetch/` | Installed from source (archived in brew) |
| Zsh | `~/.zshrc` | Comes with macOS |
| zsh-autosuggestions | sourced in `.zshrc` | `brew install zsh-autosuggestions` |
| pyenv | sourced in `.zshrc` | `brew install pyenv` |
| JetBrains Mono | — | `brew install --cask font-jetbrains-mono` |
| gh (GitHub CLI) | — | `brew install gh` |

## Theme

We use **Dracula** everywhere. Visit [draculatheme.com](https://draculatheme.com/) for manual setup in apps like Firefox, VS Code, YouTube, etc.

If you find something that can be automated (config file, brew install, script), add it to the bootstrap or dotfiles here for future use.
