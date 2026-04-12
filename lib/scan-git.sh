#!/usr/bin/env bash
# lib/scan-git.sh — Scans .gitconfig and .gitignore_global
# Sourced by generate-setup.sh; do not execute directly.

scan_git() {
  banner "Scanning: Git Configuration"

  local gitconfig_content="" gitignore_content=""

  if [[ -f "$HOME/.gitconfig" ]]; then
    gitconfig_content=$(cat "$HOME/.gitconfig" | sed "s|$HOME|~|g")
    info "Found ~/.gitconfig"
  fi

  if [[ -f "$HOME/.gitignore_global" ]]; then
    gitignore_content=$(cat "$HOME/.gitignore_global")
    info "Found ~/.gitignore_global"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ -z "$gitconfig_content" && -z "$gitignore_content" ]] && return

  cat >> "$SCRIPT_FILE" << 'GIT_HEADER'

###############################################################################
# Git Configuration
###############################################################################
banner "Git Configuration"
GIT_HEADER

  if [[ -n "$gitconfig_content" ]]; then
    cat >> "$SCRIPT_FILE" << GITCONFIG_BLOCK

if prompt_yn "~/.gitconfig"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.gitconfig"
  else
    cat > "\$HOME/.gitconfig" << 'GITCONFIG_EOF'
$gitconfig_content
GITCONFIG_EOF
    success "~/.gitconfig"
  fi
else
  skip "~/.gitconfig"
fi
GITCONFIG_BLOCK
  fi

  if [[ -n "$gitignore_content" ]]; then
    cat >> "$SCRIPT_FILE" << GITIGNORE_BLOCK

if prompt_yn "~/.gitignore_global"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.gitignore_global"
  else
    cat > "\$HOME/.gitignore_global" << 'GITIGNORE_EOF'
$gitignore_content
GITIGNORE_EOF
    success "~/.gitignore_global"
  fi
else
  skip "~/.gitignore_global"
fi
GITIGNORE_BLOCK
  fi
}
