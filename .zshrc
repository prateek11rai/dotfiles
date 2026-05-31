
eval "$(starship init zsh)"
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"

export EDITOR="code --wait"   # VS Code
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
