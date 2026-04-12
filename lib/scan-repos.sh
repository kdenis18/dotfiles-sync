#!/usr/bin/env bash
# lib/scan-repos.sh — Scans git repos to clone
# Sourced by generate-setup.sh; do not execute directly.

scan_repos() {
  banner "Scanning: Git Repos"

  local REPOS_TO_CLONE=()

  for dir in "$HOME/Hinge"/* "$HOME/workspace"/* "$HOME/Projects"/*; do
    if [[ -d "$dir/.git" ]]; then
      local remote
      remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
      if [[ -n "$remote" ]]; then
        local rel_path="${dir#$HOME/}"
        REPOS_TO_CLONE+=("$remote|~/$rel_path")
        info "Found repo: ~/$rel_path -> $remote"
      fi
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ ${#REPOS_TO_CLONE[@]} -eq 0 ]] && return

  cat >> "$SCRIPT_FILE" << 'REPOS_HEADER'

###############################################################################
# Clone Repos
###############################################################################
banner "Clone Repos"
REPOS_HEADER

  for repo_entry in "${REPOS_TO_CLONE[@]}"; do
    local remote="${repo_entry%%|*}"
    local local_path="${repo_entry##*|}"
    local expanded_path
    expanded_path=$(echo "$local_path" | sed "s|~|\$HOME|")
    cat >> "$SCRIPT_FILE" << REPO_BLOCK

if [[ ! -d "$expanded_path" ]]; then
  if prompt_yn "Clone $local_path"; then
    if [[ "\$DRY_RUN" == true ]]; then
      dry "Would clone $local_path"
    else
      mkdir -p "\$(dirname "$expanded_path")"
      git clone "$remote" "$expanded_path" && success "$local_path" || fail "$local_path"
    fi
  else
    skip "$local_path"
  fi
else
  skip "$local_path (already exists)"
fi
REPO_BLOCK
  done
}
