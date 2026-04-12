#!/usr/bin/env bash
# lib/scan-xcode.sh — Scans Xcode themes, snippets, keybindings
# Sourced by generate-setup.sh; do not execute directly.

scan_xcode() {
  banner "Scanning: Xcode"

  local XCODE_USERDATA="$HOME/Library/Developer/Xcode/UserData"
  local XCODE_THEMES=() XCODE_SNIPPETS=()
  local XCODE_KEYBINDINGS=""

  if [[ -d "$XCODE_USERDATA/FontAndColorThemes" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-themes"
    for theme in "$XCODE_USERDATA/FontAndColorThemes"/*.xccolortheme; do
      [[ -f "$theme" ]] || continue
      cp "$theme" "$CONFIGS_DIR/xcode-themes/"
      XCODE_THEMES+=("$(basename "$theme")")
    done
    info "Found ${#XCODE_THEMES[@]} Xcode themes"
  fi

  if [[ -d "$XCODE_USERDATA/CodeSnippets" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-snippets"
    for snippet in "$XCODE_USERDATA/CodeSnippets"/*.codesnippet; do
      [[ -f "$snippet" ]] || continue
      cp "$snippet" "$CONFIGS_DIR/xcode-snippets/"
      XCODE_SNIPPETS+=("$(basename "$snippet")")
    done
    info "Found ${#XCODE_SNIPPETS[@]} Xcode snippets"
  fi

  if [[ -d "$XCODE_USERDATA/KeyBindings" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-keybindings"
    for kb in "$XCODE_USERDATA/KeyBindings"/*.idekeybindings; do
      [[ -f "$kb" ]] || continue
      cp "$kb" "$CONFIGS_DIR/xcode-keybindings/"
      XCODE_KEYBINDINGS="yes"
    done
    [[ -n "$XCODE_KEYBINDINGS" ]] && info "Found Xcode keybindings"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ ${#XCODE_THEMES[@]} -eq 0 && ${#XCODE_SNIPPETS[@]} -eq 0 && -z "$XCODE_KEYBINDINGS" ]] && return

  cat >> "$SCRIPT_FILE" << 'XCODE_HEADER'

###############################################################################
# Xcode Configuration
###############################################################################
banner "Xcode Configuration"

XCODE_USERDATA="$HOME/Library/Developer/Xcode/UserData"
XCODE_HEADER

  if [[ ${#XCODE_THEMES[@]} -gt 0 ]]; then
    local theme_count=${#XCODE_THEMES[@]}
    cat >> "$SCRIPT_FILE" << XCODETHEMES_BLOCK

if prompt_yn "Xcode color themes ($theme_count themes)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would copy $theme_count Xcode themes"
  else
    mkdir -p "\$XCODE_USERDATA/FontAndColorThemes"
    cp "\$CONFIGS_DIR/xcode-themes/"*.xccolortheme "\$XCODE_USERDATA/FontAndColorThemes/" 2>/dev/null
    success "Xcode color themes"
  fi
else
  skip "Xcode color themes"
fi
XCODETHEMES_BLOCK
  fi

  if [[ -n "$XCODE_KEYBINDINGS" ]]; then
    cat >> "$SCRIPT_FILE" << 'XCODEKB_BLOCK'

if prompt_yn "Xcode keybindings"; then
  if [[ "$DRY_RUN" == true ]]; then
    dry "Would copy Xcode keybindings"
  else
    mkdir -p "$XCODE_USERDATA/KeyBindings"
    cp "$CONFIGS_DIR/xcode-keybindings/"*.idekeybindings "$XCODE_USERDATA/KeyBindings/" 2>/dev/null
    success "Xcode keybindings"
  fi
else
  skip "Xcode keybindings"
fi
XCODEKB_BLOCK
  fi

  if [[ ${#XCODE_SNIPPETS[@]} -gt 0 ]]; then
    local snippet_count=${#XCODE_SNIPPETS[@]}
    cat >> "$SCRIPT_FILE" << XCODESNIPPETS_BLOCK

if prompt_yn "Xcode code snippets ($snippet_count snippets)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would copy $snippet_count Xcode snippets"
  else
    mkdir -p "\$XCODE_USERDATA/CodeSnippets"
    cp "\$CONFIGS_DIR/xcode-snippets/"*.codesnippet "\$XCODE_USERDATA/CodeSnippets/" 2>/dev/null
    success "Xcode code snippets"
  fi
else
  skip "Xcode code snippets"
fi
XCODESNIPPETS_BLOCK
  fi
}
