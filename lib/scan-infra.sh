#!/usr/bin/env bash
# lib/scan-infra.sh — Scans AWS, ArgoCD, Opal, GH CLI, keychain
# Sourced by generate-setup.sh; do not execute directly.

scan_infra() {
  banner "Scanning: Infrastructure"

  local argocd_config="" opal_config="" gh_config="" gh_hosts=""
  local KEYCHAIN_ENTRIES=()

  # ArgoCD
  if [[ -f "$HOME/.config/argocd/config" ]]; then
    local argo_content
    argo_content=$(cat "$HOME/.config/argocd/config")
    local argo_token
    argo_token=$(echo "$argo_content" | grep 'auth-token:' | sed 's/.*auth-token: *//')
    if [[ -n "$argo_token" ]]; then
      add_secret "ArgoCD auth-token" "~/.config/argocd/config" "$argo_token" "JWT — will expire. Re-login with argocd login"
      argo_content=$(printf '%s' "$argo_content" | sed "s|auth-token: .*|auth-token: CHANGEME|")
    fi
    argocd_config="$argo_content"
    info "Found ArgoCD config"
  fi

  # Opal
  if [[ -f "$HOME/.config/opal-security/config.json" ]]; then
    opal_config=$(cat "$HOME/.config/opal-security/config.json")
    info "Found Opal Security config"
  fi

  # GH CLI
  if [[ -f "$HOME/.config/gh/config.yml" ]]; then
    gh_config=$(cat "$HOME/.config/gh/config.yml")
    info "Found GitHub CLI config"
  fi
  if [[ -f "$HOME/.config/gh/hosts.yml" ]]; then
    gh_hosts=$(cat "$HOME/.config/gh/hosts.yml")
    info "Found GitHub CLI hosts"
  fi

  # Keychain
  for svc in "MGC_JFROG_USERNAME" "MGC_JFROG_PASSWORD"; do
    if security find-generic-password -s "$svc" 2>/dev/null | grep -q 'svce'; then
      local kc_value
      kc_value=$(security find-generic-password -w -s "$svc" -a "$USER" 2>/dev/null || echo "")
      if [[ -n "$kc_value" ]]; then
        KEYCHAIN_ENTRIES+=("$svc")
        add_secret "Keychain: $svc" "macOS Keychain (service: $svc)" "$kc_value"
        info "Found keychain entry: $svc"
      fi
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  cat >> "$SCRIPT_FILE" << 'INFRA_HEADER'

###############################################################################
# Infrastructure
###############################################################################
banner "Infrastructure"
INFRA_HEADER

  if [[ -n "$argocd_config" ]]; then
    cat >> "$SCRIPT_FILE" << ARGO_BLOCK

if prompt_yn "ArgoCD config"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ArgoCD config"
  else
    mkdir -p "\$HOME/.config/argocd"
    cat > "\$HOME/.config/argocd/config" << 'ARGO_EOF'
$argocd_config
ARGO_EOF
    success "ArgoCD config"
  fi
else
  skip "ArgoCD config"
fi
ARGO_BLOCK
  fi

  if [[ -n "$opal_config" ]]; then
    cat >> "$SCRIPT_FILE" << OPAL_BLOCK

if prompt_yn "Opal Security config"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write Opal Security config"
  else
    mkdir -p "\$HOME/.config/opal-security"
    cat > "\$HOME/.config/opal-security/config.json" << 'OPAL_EOF'
$opal_config
OPAL_EOF
    success "Opal Security config"
  fi
else
  skip "Opal Security config"
fi
OPAL_BLOCK
  fi

  if [[ -n "$gh_config" ]]; then
    cat >> "$SCRIPT_FILE" << GH_BLOCK

if prompt_yn "GitHub CLI config"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write GitHub CLI config"
  else
    mkdir -p "\$HOME/.config/gh"
    cat > "\$HOME/.config/gh/config.yml" << 'GH_EOF'
$gh_config
GH_EOF
GH_BLOCK

    if [[ -n "$gh_hosts" ]]; then
      cat >> "$SCRIPT_FILE" << GHHOSTS_BLOCK
    cat > "\$HOME/.config/gh/hosts.yml" << 'GHHOSTS_EOF'
$gh_hosts
GHHOSTS_EOF
GHHOSTS_BLOCK
    fi

    cat >> "$SCRIPT_FILE" << 'GH_END'
    success "GitHub CLI config"
    echo -e "  ${YELLOW}> Run 'gh auth login' to authenticate${NC}"
  fi
else
  skip "GitHub CLI config"
fi
GH_END
  fi

  # Keychain entries
  if [[ ${#KEYCHAIN_ENTRIES[@]} -gt 0 ]]; then
    cat >> "$SCRIPT_FILE" << 'KC_HEADER'

banner "macOS Keychain Entries"
KC_HEADER

    for kc_svc in "${KEYCHAIN_ENTRIES[@]}"; do
      cat >> "$SCRIPT_FILE" << KC_BLOCK

echo -e "\${YELLOW}Enter $kc_svc value (from password manager):\${NC}"
read -rs KC_VAL
if [[ -n "\$KC_VAL" ]]; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would set keychain entry: $kc_svc"
  else
    security add-generic-password -a "\$USER" -s "$kc_svc" -D "environment variable" -w "\$KC_VAL" 2>/dev/null || \
    (security delete-generic-password -a "\$USER" -s "$kc_svc" 2>/dev/null && \
     security add-generic-password -a "\$USER" -s "$kc_svc" -D "environment variable" -w "\$KC_VAL")
    success "$kc_svc in Keychain"
  fi
else
  skip "$kc_svc"
fi
KC_BLOCK
    done
  fi
}
