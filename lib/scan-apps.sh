#!/usr/bin/env bash
# lib/scan-apps.sh — Scans /Applications/ and resolves install methods
# Sourced by generate-setup.sh; do not execute directly.

scan_apps() {
  banner "Scanning: Applications"

  # Skip system/Apple apps
  local SKIP_APPS="Automator|Books|Calculator|Calendar|Chess|Clock|Contacts|Dictionary|FaceTime|FindMy|Font Book|Freeform|Home|Image Capture|Launchpad|Mail|Maps|Messages|Migration Assistant|Mission Control|Music|News|Notes|Photo Booth|Photos|Podcasts|Preview|QuickTime Player|Reminders|Safari|Shortcuts|Siri|Stickies|Stocks|System Preferences|System Settings|TextEdit|Time Machine|Tips|TV|Utilities|Voice Memos|Weather|Code42|Code42-AAT"

  # Known overrides
  local CASK_OVERRIDES="
zoom.us=zoom
GitHub Desktop=github-desktop
logioptionsplus=logi-options-plus
Logi Options+=logi-options-plus
Google Chrome=google-chrome
Cloudflare WARP=cloudflare-warp
Visual Studio Code=visual-studio-code
DB Browser for SQLite=db-browser-for-sqlite
Copilot for Xcode=copilot-for-xcode
JetBrains Toolbox=jetbrains-toolbox
Okta Verify=okta-verify
Colour Contrast Analyser=colour-contrast-analyser
Android Studio=android-studio
Final Draft 13=final-draft
"

  local MAS_OVERRIDES="
Xcode=497799835
Bear=1091189122
Magnet=441258766
GarageBand=682658836
iMovie=408981434
Keynote=409183694
Pages=409201541
Numbers=409203825
"

  # Install mas if needed
  if ! command -v mas &>/dev/null && command -v brew &>/dev/null; then
    warn "Installing mas (Mac App Store CLI) for App Store lookups..."
    brew install mas 2>/dev/null && info "Installed mas" || warn "Could not install mas"
  fi

  # Build app list
  local APP_LIST=()
  for app_path in /Applications/*.app; do
    [[ -d "$app_path" ]] || continue
    local app_name
    app_name=$(basename "$app_path" .app)
    if echo "$app_name" | grep -qE "^($SKIP_APPS)$"; then
      continue
    fi
    APP_LIST+=("$app_name")
  done

  local DETECTED_CASKS=() DETECTED_MAS=() MANUAL_APPS=()
  local app_count=${#APP_LIST[@]}
  local app_idx=0

  BREW_CACHE_DIR=$(mktemp -d)
  MAS_CACHE_DIR=$(mktemp -d)

  # ── Phase 1: Brew cask lookups with progress ──
  for app_name in "${APP_LIST[@]}"; do
    ((app_idx++))
    printf "\r  Scanning apps... [%d/%d] %-40s" "$app_idx" "$app_count" "$app_name"

    # Check cask overrides first
    local override_cask
    override_cask=$(echo "$CASK_OVERRIDES" | grep "^${app_name}=" 2>/dev/null | head -1 | cut -d= -f2- || true)
    if [[ -n "$override_cask" ]]; then
      echo "cask:${override_cask}:$app_name" > "$BREW_CACHE_DIR/$app_name"
      continue
    fi

    # Check MAS overrides
    local override_mas
    override_mas=$(echo "$MAS_OVERRIDES" | grep "^${app_name}=" 2>/dev/null | head -1 | cut -d= -f2- || true)
    if [[ -n "$override_mas" ]]; then
      echo "none::$app_name" > "$BREW_CACHE_DIR/$app_name"
      continue
    fi

    # Dynamic brew lookup
    local search_name found_cask=""
    search_name=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/\.//g')

    /opt/homebrew/bin/brew info --cask "$search_name" >/dev/null 2>&1 && found_cask="$search_name" || true

    if [[ -z "$found_cask" ]]; then
      for alt in \
        "$(echo "$search_name" | sed 's/-app$//; s/-desktop$//; s/-for-mac$//')" \
        "$(echo "$search_name" | sed 's/us$//')" \
        "$(echo "$search_name" | sed 's/[0-9]*$//' | sed 's/-$//')" \
      ; do
        [[ "$alt" == "$search_name" ]] && continue
        [[ -z "$alt" ]] && continue
        /opt/homebrew/bin/brew info --cask "$alt" >/dev/null 2>&1 && found_cask="$alt" || true
        [[ -n "$found_cask" ]] && break
      done
    fi

    if [[ -n "$found_cask" ]]; then
      echo "cask:$found_cask:$app_name" > "$BREW_CACHE_DIR/$app_name"
    else
      echo "none::$app_name" > "$BREW_CACHE_DIR/$app_name"
    fi
  done
  printf "\r  Scanning apps... done.%-50s\n" ""

  # ── Phase 2: MAS lookups for unmatched apps ──
  for app_name in "${APP_LIST[@]}"; do
    local result_file="$BREW_CACHE_DIR/$app_name"
    if [[ -f "$result_file" ]] && grep -q "^none:" "$result_file"; then
      local override_mas
      override_mas=$(echo "$MAS_OVERRIDES" | grep "^${app_name}=" 2>/dev/null | head -1 | cut -d= -f2- || true)
      if [[ -n "$override_mas" ]]; then
        echo "mas:${override_mas}:$app_name" > "$MAS_CACHE_DIR/$app_name"
        continue
      fi
      if command -v mas &>/dev/null; then
        (
          local mas_result
          mas_result=$(mas search "$app_name" 2>/dev/null | head -5 | grep -i "$app_name" | head -1)
          if [[ -n "$mas_result" ]]; then
            local mas_id
            mas_id=$(echo "$mas_result" | awk '{print $1}')
            if [[ -n "$mas_id" && "$mas_id" =~ ^[0-9]+$ ]]; then
              echo "mas:$mas_id:$app_name" > "$MAS_CACHE_DIR/$app_name"
            fi
          fi
        ) &
      fi
    fi
  done
  wait

  # ── Collect results ──
  for app_name in "${APP_LIST[@]}"; do
    local brew_result="$BREW_CACHE_DIR/$app_name"
    local mas_result="$MAS_CACHE_DIR/$app_name"

    if [[ -f "$brew_result" ]] && grep -q "^cask:" "$brew_result"; then
      local cask
      cask=$(cut -d: -f2 < "$brew_result")
      DETECTED_CASKS+=("$cask:$app_name")
      info "Found app: $app_name -> brew install --cask $cask"
    elif [[ -f "$mas_result" ]] && grep -q "^mas:" "$mas_result"; then
      local mas_id
      mas_id=$(cut -d: -f2 < "$mas_result")
      DETECTED_MAS+=("$mas_id:$app_name")
      info "Found app: $app_name -> mas install $mas_id"
    else
      MANUAL_APPS+=("$app_name")
      warn "Found app: $app_name -> no auto-install method found"
    fi
  done

  rm -rf "$BREW_CACHE_DIR" "$MAS_CACHE_DIR"
  # Clear these so cleanup trap doesn't double-free
  BREW_CACHE_DIR=""
  MAS_CACHE_DIR=""

  info "Summary: ${#DETECTED_CASKS[@]} via brew cask, ${#DETECTED_MAS[@]} via App Store, ${#MANUAL_APPS[@]} manual"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  # ── Emit casks to install script ──
  if [[ ${#DETECTED_CASKS[@]} -gt 0 ]]; then
    cat >> "$SCRIPT_FILE" << 'APPS_START'

###############################################################################
# Applications via Homebrew Cask
###############################################################################
banner "Applications via Homebrew Cask"

APP_CASKS=(
APPS_START

    for entry in "${DETECTED_CASKS[@]}"; do
      echo "  \"$entry\"" >> "$SCRIPT_FILE"
    done

    cat >> "$SCRIPT_FILE" << 'APPS_LOOP'
)

for entry in "${APP_CASKS[@]}"; do
  cask="${entry%%:*}"
  name="${entry##*:}"
  if brew list --cask 2>/dev/null | grep -q "^${cask}$"; then
    skip "$name (already installed)"
  elif prompt_yn "$name ($cask)"; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would install $name"
    else
      brew install --cask "$cask" 2>/dev/null && success "$name" || fail "$name"
    fi
  else
    skip "$name"
  fi
done
APPS_LOOP
  fi

  # ── Emit MAS apps ──
  if [[ ${#DETECTED_MAS[@]} -gt 0 ]]; then
    cat >> "$SCRIPT_FILE" << 'MAS_START'

###############################################################################
# Mac App Store Apps
###############################################################################
banner "Mac App Store Apps"

if ! command -v mas &>/dev/null; then
  if prompt_yn "mas (Mac App Store CLI)"; then
    brew install mas && success "mas CLI" || fail "mas CLI"
  else
    skip "mas CLI"
  fi
fi

if command -v mas &>/dev/null; then
  echo -e "  ${YELLOW}You may need to sign into the App Store first.${NC}"
  echo ""
  MAS_APPS=(
MAS_START

    for entry in "${DETECTED_MAS[@]}"; do
      echo "    \"$entry\"" >> "$SCRIPT_FILE"
    done

    cat >> "$SCRIPT_FILE" << 'MAS_LOOP'
  )

  for entry in "${MAS_APPS[@]}"; do
    app_id="${entry%%:*}"
    name="${entry##*:}"
    if mas list 2>/dev/null | grep -q "^${app_id} "; then
      skip "$name (already installed)"
    elif prompt_yn "$name (App Store)"; then
      if [[ "$DRY_RUN" == true ]]; then
        dry "Would install $name"
      else
        mas install "$app_id" 2>/dev/null && success "$name" || fail "$name"
      fi
    else
      skip "$name"
    fi
  done
fi
MAS_LOOP
  fi

  # ── Emit manual apps ──
  if [[ ${#MANUAL_APPS[@]} -gt 0 ]]; then
    cat >> "$SCRIPT_FILE" << 'MANUAL_START'

###############################################################################
# Apps Requiring Manual Download
###############################################################################
banner "Apps Requiring Manual Download"

echo -e "${BOLD}These apps couldn't be auto-installed:${NC}"
echo ""
MANUAL_START

    for app_name in "${MANUAL_APPS[@]}"; do
      echo "echo -e \"  \${CYAN}$app_name\${NC}\"" >> "$SCRIPT_FILE"
    done

    cat >> "$SCRIPT_FILE" << 'MANUAL_END'

echo ""
echo -e "${YELLOW}Check the Mac App Store, vendor website, or Self Service.app.${NC}"
MANUAL_END
  fi
}
