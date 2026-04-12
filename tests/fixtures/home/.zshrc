# Oh-My-Zsh configuration
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source $ZSH/oh-my-zsh.sh

# Aliases
alias gs='git status'
alias ll='ls -la'

# Exports
export EDITOR=vim
export API_KEY="sk-test-fixture-secret-12345"
export GOPATH="$HOME/go"

# PATH
export PATH="$HOME/.local/bin:$PATH"

# Functions
greet() {
  echo "Hello, $1"
}
