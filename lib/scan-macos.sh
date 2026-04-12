#!/usr/bin/env bash
# lib/scan-macos.sh — Scans macOS preferences
# Sourced by generate-setup.sh; do not execute directly.

scan_macos() {
  banner "Scanning: macOS Preferences"

  info "Will include common macOS preferences"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  cat >> "$SCRIPT_FILE" << 'MACOS_BLOCK'

###############################################################################
# macOS Preferences
###############################################################################
banner "macOS Preferences"

if prompt_yn "Show all file extensions in Finder"; then
  if [[ "$DRY_RUN" == true ]]; then
    dry "Would set AppleShowAllExtensions"
  else
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    success "AppleShowAllExtensions"
  fi
else
  skip "AppleShowAllExtensions"
fi
MACOS_BLOCK
}
