#!/usr/bin/env bash
# lib/scan-claude.sh — Scans Claude Code MCPs, plugins, settings, CLAUDE.md, hooks
# Sourced by generate-setup.sh; do not execute directly.

scan_claude() {
  banner "Scanning: Claude Code"

  local MCP_FILE="$HOME/.claude.json"
  local SETTINGS_FILE="$HOME/.claude/settings.json"

  # Fall back to settings.json if .claude.json has no mcpServers
  if ! { [[ -f "$MCP_FILE" ]] && command -v jq &>/dev/null && jq -e '(.mcpServers // {}) | length > 0' "$MCP_FILE" &>/dev/null; }; then
    MCP_FILE="$SETTINGS_FILE"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    [[ -f "$MCP_FILE" ]] && info "Would scan MCPs from $MCP_FILE"
    [[ -f "$SETTINGS_FILE" ]] && info "Would scan settings from $SETTINGS_FILE"
    [[ -f "$HOME/.claude/CLAUDE.md" ]] && info "Would scan CLAUDE.md"
    return
  fi

  # ── MCPs ──
  emit_section_header "Claude Code MCP Servers"

  local HAS_LOCAL_MCPS=false

  if [[ -f "$MCP_FILE" ]] && command -v jq &>/dev/null; then
    local MCP_KEYS
    MCP_KEYS=$(jq -r '.mcpServers // {} | keys[]' "$MCP_FILE" 2>/dev/null || true)
    if [[ -n "$MCP_KEYS" ]]; then
      HAS_LOCAL_MCPS=true
      while IFS= read -r name; do
        local server_json
        server_json=$(jq -c ".mcpServers[\"$name\"]" "$MCP_FILE")

        # Replace absolute $HOME paths with @@HOME@@
        local has_abs_path=false
        if echo "$server_json" | grep -q "$HOME"; then
          server_json=$(echo "$server_json" | sed "s|$HOME|@@HOME@@|g")
          has_abs_path=true
          warn "$name MCP contains absolute paths — will be rewritten to use \$HOME on target"
        fi

        # Find and redact secret env keys
        local secret_env_keys=""
        while IFS= read -r env_key; do
          if echo "$env_key" | grep -qE '(TOKEN|KEY|SECRET|PASSWORD|PASS|API)'; then
            secret_env_keys="$secret_env_keys $env_key"
            # Extract and store the original value
            local orig_value
            orig_value=$(jq -c ".mcpServers[\"$name\"]" "$MCP_FILE" | jq -r ".env[\"$env_key\"] // empty")
            if [[ -n "$orig_value" && "$orig_value" != "CHANGEME" ]]; then
              add_secret "MCP $name: $env_key" "$MCP_FILE" "$orig_value"
            fi
          fi
        done < <(echo "$server_json" | jq -r '.env // {} | keys[]' 2>/dev/null || true)

        # Redact secrets in the JSON
        if [[ -n "$secret_env_keys" ]]; then
          server_json=$(redact_json_secrets "$server_json")
        fi

        local safe_json_var="_mcp_$(echo "$name" | tr '-' '_')_json"
        local escaped_json
        escaped_json=$(printf '%s' "$server_json" | sed "s/'/'\\\\''/g")

        if [[ -n "$secret_env_keys" ]]; then
          local secret_keys_list
          secret_keys_list=$(echo "$secret_env_keys" | tr -s ' ' | sed 's/^ //')
          cat >> "$SCRIPT_FILE" << MCPEOF
# SECRETS REQUIRED for $name:$secret_env_keys
$safe_json_var='$escaped_json'
MCPEOF
          if [[ "$has_abs_path" == true ]]; then
            cat >> "$SCRIPT_FILE" << MCPEOF
$safe_json_var="\${${safe_json_var}//@@HOME@@/\$HOME}"
MCPEOF
          fi
          cat >> "$SCRIPT_FILE" << MCPEOF
if claude mcp list 2>/dev/null | grep -q "$name"; then
  skip "MCP server: $name (already installed)"
elif prompt_yn "MCP server: $name"; then
  _json="\$$safe_json_var"
  _skip=false
  for _key in $secret_keys_list; do
    if echo "\$_json" | grep -q "\"\$_key\":\"CHANGEME\""; then
      printf "  Enter value for %s (Enter to skip): " "\$_key"
      read -r _val
      if [[ -z "\$_val" ]]; then
        skip "\$_key not provided"
        _skip=true
        break
      fi
      _json="\${_json//\"\$_key\":\"CHANGEME\"/\"\$_key\":\"\$_val\"}"
    fi
  done
  if [[ "\$_skip" != true ]]; then
    if [[ "\$DRY_RUN" == true ]]; then
      dry "Would install MCP server: $name"
    else
      claude mcp add-json '$name' "\$_json" -s user
      success "MCP server: $name"
    fi
  fi
fi
echo ""

MCPEOF
        else
          cat >> "$SCRIPT_FILE" << MCPEOF
$safe_json_var='$escaped_json'
MCPEOF
          if [[ "$has_abs_path" == true ]]; then
            cat >> "$SCRIPT_FILE" << MCPEOF
$safe_json_var="\${${safe_json_var}//@@HOME@@/\$HOME}"
MCPEOF
          fi
          cat >> "$SCRIPT_FILE" << MCPEOF
if claude mcp list 2>/dev/null | grep -q "$name"; then
  skip "MCP server: $name (already installed)"
elif prompt_yn "MCP server: $name"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install MCP server: $name"
  else
    claude mcp add-json '$name' "\$$safe_json_var" -s user
    success "MCP server: $name"
  fi
fi
echo ""

MCPEOF
        fi
      done <<< "$MCP_KEYS"
    fi
  fi

  # Cloud MCPs
  local CLOUD_MCPS=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^claude\.ai\ (.+):\ (.+)\ -\ (.*)$ ]]; then
      CLOUD_MCPS+=("${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}")
    fi
  done < <(claude mcp list 2>&1 | grep -v "^Checking" || true)

  if [[ ${#CLOUD_MCPS[@]} -gt 0 ]]; then
    {
      echo 'echo "  Cloud MCPs (account-level, auto-configured):"'
      for entry in "${CLOUD_MCPS[@]}"; do
        IFS='|' read -r name url status <<< "$entry"
        echo "echo \"    - $name: $url ($status)\""
      done
      echo 'echo ""'
      echo 'echo "  These are tied to your claude.ai account."'
      echo 'echo "  If they do not appear on the new machine, enable them at claude.ai/settings."'
      echo 'echo ""'
    } >> "$SCRIPT_FILE"
  fi

  if [[ "$HAS_LOCAL_MCPS" == false && ${#CLOUD_MCPS[@]} -eq 0 ]]; then
    echo 'echo "  No MCP servers found."' >> "$SCRIPT_FILE"
    echo 'echo ""' >> "$SCRIPT_FILE"
  fi

  # ── Plugins ──
  emit_section_header "Claude Code Plugins"

  local INSTALLED_PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"
  local MARKETPLACES_FILE="$HOME/.claude/plugins/known_marketplaces.json"

  if [[ -f "$MARKETPLACES_FILE" ]] && command -v jq &>/dev/null; then
    local MARKETPLACE_NAMES
    MARKETPLACE_NAMES=$(jq -r 'keys[]' "$MARKETPLACES_FILE" 2>/dev/null || true)
    if [[ -n "$MARKETPLACE_NAMES" ]]; then
      while IFS= read -r mkt_name; do
        local source_repo
        source_repo=$(jq -r ".\"$mkt_name\".source.repo" "$MARKETPLACES_FILE")
        cat >> "$SCRIPT_FILE" << MKTEOF
if [[ -d "\$HOME/.claude/plugins/marketplaces/$mkt_name" ]]; then
  skip "Plugin marketplace: $mkt_name (already added)"
elif prompt_yn "Add plugin marketplace: $mkt_name (github:$source_repo)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would add marketplace: $mkt_name"
  else
    claude plugins marketplace add "github:$source_repo"
    success "Marketplace: $mkt_name"
  fi
fi
echo ""

MKTEOF
      done <<< "$MARKETPLACE_NAMES"
    fi
  fi

  if [[ -f "$INSTALLED_PLUGINS_FILE" ]] && command -v jq &>/dev/null; then
    local PLUGIN_KEYS
    PLUGIN_KEYS=$(jq -r '.plugins | keys[]' "$INSTALLED_PLUGINS_FILE" 2>/dev/null || true)
    if [[ -n "$PLUGIN_KEYS" ]]; then
      while IFS= read -r plugin_key; do
        local plugin_version
        plugin_version=$(jq -r ".plugins[\"$plugin_key\"][0].version" "$INSTALLED_PLUGINS_FILE")
        cat >> "$SCRIPT_FILE" << PLUGINEOF
if claude plugins list 2>/dev/null | grep -q "$plugin_key"; then
  skip "Claude plugin: $plugin_key (already installed)"
elif prompt_yn "Claude plugin: $plugin_key@$plugin_version"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install plugin: $plugin_key"
  else
    claude plugins install "$plugin_key" -s user
    success "Plugin: $plugin_key"
  fi
fi
echo ""

PLUGINEOF
      done <<< "$PLUGIN_KEYS"
    fi
  fi

  # ── Settings (non-MCP) ──
  emit_section_header "Claude Code Settings"

  if [[ -f "$SETTINGS_FILE" ]] && command -v jq &>/dev/null; then
    local settings_no_mcp
    settings_no_mcp=$(jq -c 'del(.mcpServers)' "$SETTINGS_FILE" 2>/dev/null || true)
    settings_no_mcp=$(rewrite_home_paths "$settings_no_mcp")
    if [[ -n "$settings_no_mcp" && "$settings_no_mcp" != "{}" ]]; then
      local escaped_settings
      escaped_settings=$(printf '%s' "$settings_no_mcp" | sed "s/'/'\\\\''/g")
      cat >> "$SCRIPT_FILE" << SETTINGSEOF
_settings_json='$escaped_settings'
_settings_json="\${_settings_json//@@HOME@@/\$HOME}"
echo "  Current source machine settings.json (excluding MCPs):"
echo "  \$_settings_json"
echo ""
if prompt_yn "Merge these settings into ~/.claude/settings.json"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would merge Claude settings"
  elif command -v jq &>/dev/null; then
    if [[ -f "\$HOME/.claude/settings.json" ]]; then
      jq -s '.[0] * .[1]' "\$HOME/.claude/settings.json" <(echo "\$_settings_json") > "\$HOME/.claude/settings.json.tmp"
      mv "\$HOME/.claude/settings.json.tmp" "\$HOME/.claude/settings.json"
    else
      mkdir -p "\$HOME/.claude"
      echo "\$_settings_json" | jq '.' > "\$HOME/.claude/settings.json"
    fi
    success "Claude settings merged"
  else
    fail "jq not found, skipping settings merge"
  fi
fi
echo ""

SETTINGSEOF
    fi
  fi

  # ── CLAUDE.md + referenced files ──
  if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    local claude_md
    claude_md=$(cat "$HOME/.claude/CLAUDE.md")
    info "Found ~/.claude/CLAUDE.md"

    cat >> "$SCRIPT_FILE" << CLAUDEMD_BLOCK

if prompt_yn "~/.claude/CLAUDE.md"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.claude/CLAUDE.md"
  else
    mkdir -p "\$HOME/.claude"
    cat > "\$HOME/.claude/CLAUDE.md" << 'CLAUDEMD_EOF'
$claude_md
CLAUDEMD_EOF
CLAUDEMD_BLOCK

    # Write referenced files
    while IFS= read -r ref; do
      ref=$(echo "$ref" | sed 's/^@//')
      if [[ -f "$HOME/.claude/$ref" ]]; then
        local ref_content
        ref_content=$(cat "$HOME/.claude/$ref")
        cat >> "$SCRIPT_FILE" << CLAUDEREF_BLOCK
    cat > "\$HOME/.claude/$ref" << 'CLAUDEREF_EOF'
$ref_content
CLAUDEREF_EOF
CLAUDEREF_BLOCK
      fi
    done < <(grep '^@' "$HOME/.claude/CLAUDE.md" 2>/dev/null || true)

    cat >> "$SCRIPT_FILE" << 'CLAUDEMD_END'
    success "~/.claude/CLAUDE.md"
  fi
else
  skip "~/.claude/CLAUDE.md"
fi
CLAUDEMD_END
  fi

  # ── Hooks ──
  if [[ -d "$HOME/.claude/hooks" ]]; then
    for hook in "$HOME/.claude/hooks"/*.sh; do
      [[ -f "$hook" ]] || continue
      local hook_name hook_content
      hook_name=$(basename "$hook")
      hook_content=$(cat "$hook")
      info "Found hook: $hook_name"
      cat >> "$SCRIPT_FILE" << HOOK_BLOCK

if prompt_yn "Claude hook: $hook_name"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install hook: $hook_name"
  else
    mkdir -p "\$HOME/.claude/hooks"
    cat > "\$HOME/.claude/hooks/$hook_name" << 'HOOK_EOF'
$hook_content
HOOK_EOF
    chmod +x "\$HOME/.claude/hooks/$hook_name"
    success "Hook: $hook_name"
  fi
else
  skip "Hook: $hook_name"
fi
HOOK_BLOCK
    done
  fi
}
