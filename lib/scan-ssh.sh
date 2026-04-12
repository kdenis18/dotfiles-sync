#!/usr/bin/env bash
# lib/scan-ssh.sh — Scans SSH keys and config
# Sourced by generate-setup.sh; do not execute directly.

scan_ssh() {
  banner "Scanning: SSH"

  local ssh_config="" SSH_KEYS=()

  if [[ -f "$HOME/.ssh/config" ]]; then
    ssh_config=$(cat "$HOME/.ssh/config" | sed "s|$HOME|~|g")
    info "Found ~/.ssh/config"
  fi

  if [[ -d "$HOME/.ssh" ]]; then
    for key in "$HOME/.ssh"/*; do
      local local_name
      local_name=$(basename "$key")
      case "$local_name" in
        config|known_hosts|known_hosts.old|*.pub|authorized_keys) continue ;;
      esac
      if [[ -f "$key" ]] && head -1 "$key" 2>/dev/null | grep -q "PRIVATE KEY"; then
        SSH_KEYS+=("$local_name")
        local privkey pubkey=""
        privkey=$(cat "$key")
        [[ -f "${key}.pub" ]] && pubkey=$(cat "${key}.pub")
        add_secret "SSH Key: $local_name" "~/.ssh/$local_name" "$privkey" "Private key — save entire contents including BEGIN/END lines"
        if [[ -n "$pubkey" ]]; then
          ((SECRET_REF++))
          {
            echo "### Ref $SECRET_REF: SSH Public Key: ${local_name}.pub"
            echo "- **Location**: \`~/.ssh/${local_name}.pub\`"
            echo "- **Note**: Public key (for reference, not secret)"
            echo '- **Value**:'
            echo '```'
            echo "$pubkey"
            echo '```'
            echo ""
          } >> "$SECRETS_TEMP"
        fi
        info "Found SSH key: $local_name"
      fi
    done
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  cat >> "$SCRIPT_FILE" << 'SSH_HEADER'

###############################################################################
# SSH
###############################################################################
banner "SSH Keys"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_HEADER

  if [[ -n "$ssh_config" ]]; then
    cat >> "$SCRIPT_FILE" << SSHCONFIG_BLOCK

if prompt_yn "~/.ssh/config"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.ssh/config"
  else
    cat > "\$HOME/.ssh/config" << 'SSHCONFIG_EOF'
$ssh_config
SSHCONFIG_EOF
    chmod 600 "\$HOME/.ssh/config"
    success "~/.ssh/config"
  fi
else
  skip "~/.ssh/config"
fi
SSHCONFIG_BLOCK
  fi

  for key_name in "${SSH_KEYS[@]}"; do
    cat >> "$SCRIPT_FILE" << SSHKEY_BLOCK

if [[ ! -f "\$HOME/.ssh/$key_name" ]]; then
  if prompt_yn "SSH key $key_name (paste from password manager)"; then
    if [[ "\$DRY_RUN" == true ]]; then
      dry "Would create SSH key: $key_name"
    else
      echo -e "\${YELLOW}Paste your $key_name private key, then press Ctrl-D:\${NC}"
      cat > "\$HOME/.ssh/$key_name"
      chmod 600 "\$HOME/.ssh/$key_name"
      echo -e "\${YELLOW}Paste your ${key_name}.pub public key, then press Ctrl-D:\${NC}"
      cat > "\$HOME/.ssh/${key_name}.pub"
      chmod 644 "\$HOME/.ssh/${key_name}.pub"
      ssh-add --apple-use-keychain "\$HOME/.ssh/$key_name" 2>/dev/null || true
      success "SSH $key_name"
    fi
  else
    skip "SSH $key_name"
  fi
else
  skip "SSH $key_name (already exists)"
fi
SSHKEY_BLOCK
  done
}
