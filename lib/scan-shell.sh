#!/usr/bin/env bash
# lib/scan-shell.sh — Scans shell config files (.zshrc, .zprofile, .zshenv, .bash_profile)
# Supports two modes: full replacement (default) and selective (--selective-zshrc).
# Sourced by generate-setup.sh; do not execute directly.

scan_shell() {
  banner "Scanning: Shell Configuration"

  # Detect secrets across shell files
  local shell_secrets=()
  _detect_shell_secrets() {
    local file="$1"
    [[ -f "$file" ]] || return
    while IFS= read -r line; do
      if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        local varname="${BASH_REMATCH[1]}"
        if detect_secret_env_name "$varname"; then
          local value
          value=$(echo "$line" | sed -E 's/^export [A-Za-z_][A-Za-z0-9_]*="?([^"]*)"?\s*$/\1/' | sed 's/^"//' | sed 's/"$//')
          if [[ -n "$value" ]] && ! echo "$value" | grep -q '^\$(' ; then
            add_secret "$varname" "$file" "$value"
            shell_secrets+=("$varname")
          fi
        fi
      fi
    done < "$file"
  }

  _detect_shell_secrets "$HOME/.zshrc"
  _detect_shell_secrets "$HOME/.zprofile"
  info "Found ${#shell_secrets[@]} secret env vars"

  local zshrc_redacted zprofile_redacted zshenv_content bashprofile_content
  zshrc_redacted=$(redact_shell_file "$HOME/.zshrc")
  zprofile_redacted=$(redact_shell_file "$HOME/.zprofile")
  [[ -f "$HOME/.zshenv" ]] && zshenv_content=$(cat "$HOME/.zshenv" | sed "s|$HOME|\$HOME|g")
  [[ -f "$HOME/.bash_profile" ]] && bashprofile_content=$(cat "$HOME/.bash_profile" | sed "s|$HOME|\$HOME|g")

  info "Scanned ~/.zshrc, ~/.zprofile, ~/.zshenv, ~/.bash_profile"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  # ── Phase header ──
  cat >> "$SCRIPT_FILE" << 'SHELL_HEADER'

###############################################################################
# Shell Configuration
###############################################################################
banner "Shell Configuration"
SHELL_HEADER

  if [[ "$SELECTIVE_ZSHRC" == true ]]; then
    _emit_selective_zshrc
  else
    _emit_full_replacement_zshrc "$zshrc_redacted"
  fi

  # Other shell files are always full replacement
  _emit_shell_file ".zprofile" "$zprofile_redacted"
  _emit_shell_file ".zshenv" "${zshenv_content:-}"
  _emit_shell_file ".bash_profile" "${bashprofile_content:-}"

  # ── Secret injection phase (emitted near end of install script) ──
  # This is handled by emit-footer.sh via a separate function.
  # We store the secret var names for later use.
  _emit_secret_injection_phase
}

_emit_full_replacement_zshrc() {
  local content="$1"
  [[ -z "$content" ]] && return
  cat >> "$SCRIPT_FILE" << ZSHRC_BLOCK

if prompt_yn "~/.zshrc (full replacement)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.zshrc"
  else
    cat > "\$HOME/.zshrc" << 'ZSHRC_EOF'
$content
ZSHRC_EOF
    success "~/.zshrc"
  fi
else
  skip "~/.zshrc"
fi
ZSHRC_BLOCK
}

_emit_shell_file() {
  local filename="$1" content="$2"
  [[ -z "$content" ]] && return
  cat >> "$SCRIPT_FILE" << SHELLFILE_BLOCK

if prompt_yn "~/$filename"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/$filename"
  else
    cat > "\$HOME/$filename" << 'SHELLFILE_EOF'
$content
SHELLFILE_EOF
    success "~/$filename"
  fi
else
  skip "~/$filename"
fi
SHELLFILE_BLOCK
}

_emit_selective_zshrc() {
  local zshrc="$HOME/.zshrc"
  [[ -f "$zshrc" ]] || return

  echo 'touch "$HOME/.zshrc"' >> "$SCRIPT_FILE"
  echo '' >> "$SCRIPT_FILE"

  local zsh_items=0

  # ── Helper: emit a single-line item with diff support ──
  _emit_selective_item() {
    local label="$1" line="$2" match_pattern="$3"
    local sq_escaped display
    sq_escaped=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")
    display=$(printf '%s' "$line" | sed -e 's/\$/\\$/g' -e 's/"/\\"/g')

    # Check if it's a secret export
    local is_secret=false
    if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      local varname="${BASH_REMATCH[1]}"
      if detect_secret_env_name "$varname"; then
        is_secret=true
      fi
    fi

    if [[ "$is_secret" == true ]]; then
      local varname
      varname=$(echo "$line" | sed -E 's/^export ([A-Z_][A-Z0-9_]*)=.*/\1/')
      local safe_var="_secret_$(echo "$varname" | tr '[:upper:]' '[:lower:]')"
      cat >> "$SCRIPT_FILE" << SECRETEOF
# SECRET: fill in the real value for $varname, or enter it when prompted
$safe_var='CHANGEME'
if grep -qF "export $varname=" "\$HOME/.zshrc" 2>/dev/null; then
  skip "Already in .zshrc: export $varname"
elif prompt_yn "Add: export $varname [SECRET]"; then
  if [[ "\$$safe_var" == "CHANGEME" ]]; then
    printf "  Enter value for $varname (Enter to skip): "
    read -r _input_val
    if [[ -z "\$_input_val" ]]; then
      skip "$varname not provided"
    else
      append_to_zshrc "export $varname=\$_input_val"
      success "Added export $varname"
    fi
  else
    append_to_zshrc "export $varname=\$$safe_var"
    success "Added export $varname"
  fi
fi
echo ""

SECRETEOF
    elif [[ -n "$match_pattern" ]]; then
      # Item with diff support (aliases, exports with known name)
      cat >> "$SCRIPT_FILE" << DIFFEOF
_new_line='$sq_escaped'
_existing=\$(grep "^${match_pattern}" "\$HOME/.zshrc" 2>/dev/null | head -1 || true)
if [[ -n "\$_existing" ]]; then
  if [[ "\$_existing" == "\$_new_line" ]]; then
    skip "Already in .zshrc: $display"
  else
    echo -e "  \${YELLOW}${label} exists but differs:\${NC}"
    echo -e "    \${RED}- \$_existing\${NC}  (current)"
    echo -e "    \${GREEN}+ \$_new_line\${NC}  (source)"
    if prompt_yn "Replace"; then
      if [[ "\$DRY_RUN" == true ]]; then
        dry "Would replace in .zshrc"
      else
        _content=\$(grep -vF "\$_existing" "\$HOME/.zshrc")
        printf '%s\n' "\$_content" > "\$HOME/.zshrc"
        echo "\$_new_line" >> "\$HOME/.zshrc"
        success "Replaced"
      fi
    else
      skip "Kept current"
    fi
  fi
elif prompt_yn "Add: $display"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would add to .zshrc: $display"
  else
    append_to_zshrc '$sq_escaped'
    success "Added"
  fi
fi
echo ""

DIFFEOF
    else
      # Simple item without diff (source lines, PATH, etc.)
      cat >> "$SCRIPT_FILE" << ITEMEOF
if grep -qF '$sq_escaped' "\$HOME/.zshrc" 2>/dev/null; then
  skip "Already in .zshrc: $display"
elif prompt_yn "Add: $display"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would add to .zshrc: $display"
  else
    append_to_zshrc '$sq_escaped'
    success "Added"
  fi
fi
echo ""

ITEMEOF
    fi

    zsh_items=$((zsh_items + 1))
  }

  # ── Parse and emit aliases ──
  while IFS= read -r line; do
    local alias_name
    alias_name=$(echo "$line" | sed -E 's/^alias ([a-zA-Z0-9_.-]+)=.*/\1/')
    _emit_selective_item "alias $alias_name" "$line" "alias ${alias_name}="
  done < <(grep -E '^alias ' "$zshrc" || true)

  # ── Parse and emit exports (non-PATH) ──
  while IFS= read -r line; do
    local var_name
    var_name=$(echo "$line" | sed -E 's/^export ([A-Z_][A-Z0-9_]*)=.*/\1/')
    _emit_selective_item "export $var_name" "$line" "export ${var_name}="
  done < <(grep -E '^export ' "$zshrc" | grep -v 'PATH=' || true)

  # ── Parse and emit PATH entries ──
  while IFS= read -r line; do
    _emit_selective_item "path" "$line" ""
  done < <(grep -E '(^export PATH=|^path\+=)' "$zshrc" || true)

  # ── Parse and emit functions ──
  local in_func=false func_name="" func_body=""
  while IFS= read -r line; do
    if [[ "$in_func" == false && "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\ *\{ ]]; then
      func_name="${BASH_REMATCH[1]}"
      func_body="$line"
      if [[ "$line" =~ \}[[:space:]]*$ ]]; then
        # One-liner function — body is complete, fall through to emit
        :
      else
        in_func=true
        continue
      fi
    elif [[ "$in_func" == true ]]; then
      func_body="$func_body
$line"
      if [[ "$line" == "}" ]]; then
        in_func=false
        # Multi-line function complete, fall through to emit
      else
        continue
      fi
    else
      continue
    fi

    # Emit the function block (reached from either one-liner or multi-line)
    local escaped_name escaped_body
    escaped_name=$(printf '%s' "$func_name" | sed "s/'/'\\\\''/g")
    escaped_body=$(printf '%s' "$func_body" | sed "s/'/'\\\\''/g")
    cat >> "$SCRIPT_FILE" << FUNCEOF
_existing_func=\$(grep -c "${escaped_name}()" "\$HOME/.zshrc" 2>/dev/null || echo "0")
if [[ "\$_existing_func" -gt 0 ]]; then
  skip "Already in .zshrc: ${escaped_name}()"
elif prompt_yn "Add function: $escaped_name()"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would add function ${escaped_name}()"
  else
    cat >> "\$HOME/.zshrc" << 'ZSHFUNC'
$func_body
ZSHFUNC
    success "Added ${escaped_name}()"
  fi
fi
echo ""

FUNCEOF
    zsh_items=$((zsh_items + 1))
    func_body=""
    func_name=""
  done < "$zshrc"

  # ── Parse and emit source lines ──
  while IFS= read -r line; do
    _emit_selective_item "source" "$line" ""
  done < <(grep -E '^source ' "$zshrc" || true)

  if [[ "$zsh_items" -eq 0 ]]; then
    echo 'echo "  No zsh config entries found."' >> "$SCRIPT_FILE"
  fi
  echo 'echo ""' >> "$SCRIPT_FILE"
}

_emit_secret_injection_phase() {
  # Collect secret var names from the current secrets temp
  # This emits the Phase 14 block into the install script
  local secret_vars=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      local varname="${BASH_REMATCH[1]}"
      if detect_secret_env_name "$varname"; then
        secret_vars+=("$varname")
      fi
    fi
  done < <(cat "$HOME/.zshrc" "$HOME/.zprofile" 2>/dev/null || true)

  [[ ${#secret_vars[@]} -eq 0 ]] && return

  cat >> "$SCRIPT_FILE" << 'INJECT_HEADER'

###############################################################################
# Inject Secrets from Password Manager
###############################################################################
banner "Inject Secrets from Password Manager"

echo -e "${BOLD}For each prompt below, paste the value from your password manager.${NC}"
echo -e "${BOLD}Press Enter to skip any item.${NC}"
echo ""
INJECT_HEADER

  for varname in "${secret_vars[@]}"; do
    cat >> "$SCRIPT_FILE" << INJECT_BLOCK

echo -e "\${CYAN}$varname\${NC}"
if [[ "\$DRY_RUN" == true ]]; then
  dry "Would prompt for $varname"
elif [[ "\$ACCEPT_ALL" == true ]]; then
  skip "$varname (auto-yes cannot fill secrets — enter manually later)"
else
  read -rsp "  Value (hidden): " _val
  echo
fi
if [[ "\$DRY_RUN" != true && "\$ACCEPT_ALL" != true && -n "\${_val:-}" ]]; then
  for _f in "\$HOME/.zshrc" "\$HOME/.zprofile"; do
    if [[ -f "\$_f" ]]; then
      _content=\$(cat "\$_f")
      printf '%s\n' "\${_content//export ${varname}=\"CHANGEME\"/export ${varname}=\"\$_val\"}" > "\$_f"
      _content=\$(cat "\$_f")
      printf '%s\n' "\${_content//export ${varname}=CHANGEME/export ${varname}=\$_val}" > "\$_f"
    fi
  done
  success "Injected $varname"
else
  skip "$varname"
fi
INJECT_BLOCK
  done

  cat >> "$SCRIPT_FILE" << 'MCP_NOTE'

echo ""
echo -e "${YELLOW}For MCP server tokens (Claude Code + Cursor), edit these files manually:${NC}"
echo -e "  ${CYAN}~/.claude/.mcp.json${NC}"
echo -e "  ${CYAN}~/.cursor/mcp.json${NC}"
echo -e "${YELLOW}Replace any remaining 'CHANGEME' values with your actual tokens.${NC}"
echo ""
MCP_NOTE
}
