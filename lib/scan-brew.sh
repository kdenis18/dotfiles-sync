#!/usr/bin/env bash
# lib/scan-brew.sh — Scans Homebrew taps, formulae, and casks
# Sourced by generate-setup.sh; do not execute directly.

scan_brew() {
  banner "Scanning: Homebrew"

  local brew_taps="" brew_formulae="" brew_casks=""

  if ! command -v brew &>/dev/null; then
    warn "Homebrew not found"
    return
  fi

  brew_taps=$(brew tap 2>/dev/null | sort)
  brew_formulae=$(brew list --formula 2>/dev/null | sort | tr '\n' ' ')
  brew_casks=$(brew list --cask 2>/dev/null | sort | tr '\n' ' ')
  info "Found $(echo "$brew_taps" | wc -l | tr -d ' ') taps"
  info "Found $(echo "$brew_formulae" | wc -w) formulae"
  info "Found $(echo "$brew_casks" | wc -w) casks"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  # ── Phase 1: Homebrew in install script ──
  cat >> "$SCRIPT_FILE" << 'BREW_HEADER'

###############################################################################
# PHASE 1: Homebrew
###############################################################################
banner "Phase 1: Homebrew"

if ! command -v brew &>/dev/null; then
  if prompt_yn "Homebrew"; then
    _tmpfile=$(mktemp)
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$_tmpfile"
    /bin/bash "$_tmpfile"
    rm -f "$_tmpfile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    success "Homebrew"
  else
    skip "Homebrew"
  fi
else
  skip "Homebrew (already installed)"
fi
BREW_HEADER

  # Taps
  if [[ -n "$brew_taps" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Taps" >> "$SCRIPT_FILE"
    echo "TAPS=(" >> "$SCRIPT_FILE"
    while IFS= read -r tap; do
      [[ -n "$tap" ]] && echo "  \"$tap\"" >> "$SCRIPT_FILE"
    done <<< "$brew_taps"
    cat >> "$SCRIPT_FILE" << 'TAPS_LOOP'
)
for tap in "${TAPS[@]}"; do
  if brew tap 2>/dev/null | grep -q "^${tap}$"; then
    skip "tap $tap (already tapped)"
  elif prompt_yn "brew tap $tap"; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would tap $tap"
    else
      brew tap "$tap" && success "tap $tap" || fail "tap $tap"
    fi
  else
    skip "tap $tap"
  fi
done
TAPS_LOOP
  fi

  # Formulae
  if [[ -n "$brew_formulae" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Formulae" >> "$SCRIPT_FILE"
    echo -n "FORMULAE=(" >> "$SCRIPT_FILE"
    echo "$brew_formulae" | fold -s -w 78 | while IFS= read -r line; do
      echo "" >> "$SCRIPT_FILE"
      echo -n "  $line" >> "$SCRIPT_FILE"
    done
    echo "" >> "$SCRIPT_FILE"
    local formula_count
    formula_count=$(echo "$brew_formulae" | wc -w | tr -d ' ')
    cat >> "$SCRIPT_FILE" << FORMULAE_LOOP
)

if prompt_yn "all Homebrew formulae ($formula_count packages)"; then
  for formula in "\${FORMULAE[@]}"; do
    if brew list --formula 2>/dev/null | grep -q "^\${formula}\$"; then
      skip "\$formula (already installed)"
    elif [[ "\$DRY_RUN" == true ]]; then
      dry "Would install \$formula"
    else
      brew install "\$formula" 2>/dev/null && success "\$formula" || fail "\$formula"
    fi
  done
else
  skip "Homebrew formulae"
fi
FORMULAE_LOOP
  fi

  # Casks
  if [[ -n "$brew_casks" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Casks (from brew list)" >> "$SCRIPT_FILE"
    echo -n "DEV_CASKS=(" >> "$SCRIPT_FILE"
    echo "$brew_casks" | fold -s -w 78 | while IFS= read -r line; do
      echo "" >> "$SCRIPT_FILE"
      echo -n "  $line" >> "$SCRIPT_FILE"
    done
    echo "" >> "$SCRIPT_FILE"
    local cask_count
    cask_count=$(echo "$brew_casks" | wc -w | tr -d ' ')
    cat >> "$SCRIPT_FILE" << CASKS_LOOP
)

if prompt_yn "Homebrew casks ($cask_count packages)"; then
  for cask in "\${DEV_CASKS[@]}"; do
    if brew list --cask 2>/dev/null | grep -q "^\${cask}\$"; then
      skip "\$cask (already installed)"
    elif [[ "\$DRY_RUN" == true ]]; then
      dry "Would install cask \$cask"
    else
      brew install --cask "\$cask" 2>/dev/null && success "cask \$cask" || fail "cask \$cask"
    fi
  done
else
  skip "Homebrew casks"
fi
CASKS_LOOP
  fi
}
