
eval "$(starship init zsh)"
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"

export EDITOR="code --wait"   # VS Code
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Java
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-22.jdk/Contents/Home

# uv
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

# Netskope SSL cert — applied only on machines where the cert is present
NS_CERT="/Library/Application Support/ns_cert/nscacert_combined.pem"
if [ -f "$NS_CERT" ]; then
  export AWS_CA_BUNDLE="$NS_CERT"
  export CURL_CA_BUNDLE="$NS_CERT"
  export SSL_CERT_FILE="$NS_CERT"
  export GIT_SSL_CAPATH="$NS_CERT"
  export REQUESTS_CA_BUNDLE="$NS_CERT"
  export NODE_EXTRA_CA_CERTS="$NS_CERT"
fi
unset NS_CERT

# Aliases
alias vc='vcluster platform connect vcluster'
alias ap='argopm install . -n default -f -c .'
