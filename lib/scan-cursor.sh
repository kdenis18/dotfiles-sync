#!/usr/bin/env bash
# lib/scan-cursor.sh — Scans Cursor settings, keybindings, MCP, rules
# Sourced by generate-setup.sh; do not execute directly.

scan_cursor() {
  banner "Scanning: Cursor"

  local CURSOR_USER_DIR="$HOME/Library/Application Support/Cursor/User"
  local cursor_settings="" cursor_keybindings="" cursor_mcp=""
  local CURSOR_RULES=()

  if [[ -f "$CURSOR_USER_DIR/settings.json" ]]; then
    cursor_settings=$(cat "$CURSOR_USER_DIR/settings.json")
    info "Found Cursor settings.json"
  fi

  if [[ -f "$CURSOR_USER_DIR/keybindings.json" ]]; then
    cursor_keybindings=$(cat "$CURSOR_USER_DIR/keybindings.json")
    info "Found Cursor keybindings.json"
  fi

  if [[ -f "$HOME/.cursor/mcp.json" ]] && command -v jq &>/dev/null; then
    local cursor_mcp_content
    cursor_mcp_content=$(cat "$HOME/.cursor/mcp.json")

    # Detect and redact secrets using python3
    for secret_key in $(echo "$cursor_mcp_content" | python3 -c "
import json, sys
def find_secrets(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and any(w in k.upper() for w in ['TOKEN','KEY','SECRET','PASSWORD','AUTH','APIKEY']) and v and v != 'CHANGEME':
                print(f'{path}.{k}|||{v}')
            elif isinstance(v, (dict, list)):
                find_secrets(v, f'{path}.{k}')
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            find_secrets(v, f'{path}[{i}]')
try:
    data = json.load(sys.stdin)
    find_secrets(data)
except: pass
" 2>/dev/null); do
      local key_path="${secret_key%%|||*}"
      local key_value="${secret_key##*|||}"
      local key_name
      key_name=$(echo "$key_path" | sed 's/.*\.//')
      add_secret "Cursor MCP: $key_name ($key_path)" "~/.cursor/mcp.json" "$key_value"
      cursor_mcp_content=$(printf '%s' "$cursor_mcp_content" | sed "s|$key_value|CHANGEME|g")
    done
    cursor_mcp_content=$(rewrite_home_paths "$cursor_mcp_content")
    cursor_mcp="$cursor_mcp_content"
    info "Found ~/.cursor/mcp.json"
  fi

  if [[ -d "$HOME/.cursor/rules" ]]; then
    mkdir -p "$CONFIGS_DIR/cursor-rules"
    for rule in "$HOME/.cursor/rules"/*.mdc; do
      [[ -f "$rule" ]] || continue
      cp "$rule" "$CONFIGS_DIR/cursor-rules/"
      CURSOR_RULES+=("$(basename "$rule")")
    done
    info "Found ${#CURSOR_RULES[@]} Cursor rules"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  # ── Emit to install script ──
  cat >> "$SCRIPT_FILE" << 'CURSOR_HEADER'

###############################################################################
# Cursor Configuration
###############################################################################
banner "Cursor Configuration"

CURSOR_USER_DIR="$HOME/Library/Application Support/Cursor/User"
mkdir -p "$CURSOR_USER_DIR"
mkdir -p "$HOME/.cursor/rules"
CURSOR_HEADER

  if [[ -n "$cursor_settings" ]]; then
    cat >> "$SCRIPT_FILE" << CURSORSETTINGS_BLOCK

if prompt_yn "Cursor settings.json"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write Cursor settings.json"
  else
    cat > "\$CURSOR_USER_DIR/settings.json" << 'CURSORSETTINGS_EOF'
$cursor_settings
CURSORSETTINGS_EOF
    success "Cursor settings.json"
  fi
else
  skip "Cursor settings.json"
fi
CURSORSETTINGS_BLOCK
  fi

  if [[ -n "$cursor_keybindings" ]]; then
    cat >> "$SCRIPT_FILE" << CURSORKEYS_BLOCK

if prompt_yn "Cursor keybindings.json"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write Cursor keybindings.json"
  else
    cat > "\$CURSOR_USER_DIR/keybindings.json" << 'CURSORKEYS_EOF'
$cursor_keybindings
CURSORKEYS_EOF
    success "Cursor keybindings.json"
  fi
else
  skip "Cursor keybindings.json"
fi
CURSORKEYS_BLOCK
  fi

  if [[ -n "$cursor_mcp" ]]; then
    cat >> "$SCRIPT_FILE" << CURSORMCP_BLOCK

if prompt_yn "Cursor MCP servers (~/.cursor/mcp.json)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write Cursor mcp.json"
  else
    cat > "\$HOME/.cursor/mcp.json" << 'CURSORMCP_EOF'
$cursor_mcp
CURSORMCP_EOF
    sed -i '' "s|@@HOME@@|\$HOME|g" "\$HOME/.cursor/mcp.json"
    success "Cursor mcp.json"
  fi
else
  skip "Cursor mcp.json"
fi
CURSORMCP_BLOCK
  fi

  if [[ ${#CURSOR_RULES[@]} -gt 0 ]]; then
    local rule_count=${#CURSOR_RULES[@]}
    cat >> "$SCRIPT_FILE" << CURSORRULES_BLOCK

if prompt_yn "Cursor rules ($rule_count .mdc files)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would copy $rule_count Cursor rules"
  elif [[ -d "\$CONFIGS_DIR/cursor-rules" ]]; then
    cp "\$CONFIGS_DIR/cursor-rules/"*.mdc "\$HOME/.cursor/rules/" 2>/dev/null
    success "Cursor rules ($rule_count files)"
  else
    fail "Cursor rules — migration-configs/cursor-rules/ not found"
  fi
else
  skip "Cursor rules"
fi
CURSORRULES_BLOCK
  fi
}
