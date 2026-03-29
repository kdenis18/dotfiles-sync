#!/usr/bin/env bash
set -euo pipefail

# generate-install.sh
# Reads current machine config and outputs a portable install script.
# Usage: generate-install.sh [--with-brew] [--output FILE]

WITH_BREW=false
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-brew) WITH_BREW=true; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: generate-install.sh [--with-brew] [--output FILE]"
      echo "  --with-brew   Include Homebrew packages"
      echo "  --output FILE Write to FILE instead of default name"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

HOSTNAME="$(hostname -s)"
DATE="$(date +%Y%m%d)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="install-${HOSTNAME}-${DATE}.sh"
fi

echo "Generating install script: $OUTPUT"
echo "Source machine: $HOSTNAME"
echo ""

cat > "$OUTPUT" << 'PREAMBLE'
#!/usr/bin/env bash
set -uo pipefail

# Auto-generated install script
# Transfer this to another machine and run it.
# Each item prompts before installing.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
INSTALLED=0
SKIPPED=0

prompt_yn() {
  local msg="$1"
  printf "${BLUE}%s${NC} [y/N] " "$msg"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

append_to_zshrc() {
  local line="$1"
  if ! grep -qF "$line" ~/.zshrc 2>/dev/null; then
    echo "$line" >> ~/.zshrc
    echo -e "  ${GREEN}Added${NC}"
    INSTALLED=$((INSTALLED + 1))
  else
    echo -e "  ${YELLOW}Already exists, skipped${NC}"
    SKIPPED=$((SKIPPED + 1))
  fi
}

PREAMBLE

# Add metadata
cat >> "$OUTPUT" << EOF
# Generated from: $HOSTNAME
# Generated on: $(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "=========================================="
echo "  Install script from: $HOSTNAME"
echo "  Generated: $(date +%Y-%m-%d)"
echo "=========================================="
echo ""

EOF

# ─── Section: MCP Servers ────────────────────────────────────────────────

echo "Scanning MCP servers..."

{
  echo 'echo "=== MCP Servers ==="'
  echo 'echo ""'
} >> "$OUTPUT"

# Local MCPs — Claude Code stores them in ~/.claude.json (not ~/.claude/settings.json)
SETTINGS_FILE="$HOME/.claude/settings.json"
MCP_FILE="$HOME/.claude.json"
# Fall back to settings.json if ~/.claude.json has no mcpServers
if ! { [[ -f "$MCP_FILE" ]] && command -v jq &>/dev/null && jq -e '(.mcpServers // {}) | length > 0' "$MCP_FILE" &>/dev/null; }; then
  MCP_FILE="$SETTINGS_FILE"
fi
HAS_LOCAL_MCPS=false
if [[ -f "$MCP_FILE" ]] && command -v jq &>/dev/null; then
  MCP_KEYS=$(jq -r '.mcpServers // {} | keys[]' "$MCP_FILE" 2>/dev/null || true)
  if [[ -n "$MCP_KEYS" ]]; then
    HAS_LOCAL_MCPS=true
    while IFS= read -r name; do
      server_json=$(jq -c ".mcpServers[\"$name\"]" "$MCP_FILE")

      # Find env keys that look like secrets
      secret_env_keys=""
      while IFS= read -r env_key; do
        if echo "$env_key" | grep -qE '(TOKEN|KEY|SECRET|PASSWORD|PASS|API)'; then
          secret_env_keys="$secret_env_keys $env_key"
        fi
      done < <(echo "$server_json" | jq -r '.env // {} | keys[]' 2>/dev/null || true)

      if [[ -n "$secret_env_keys" ]]; then
        # Redact secret env values before embedding
        server_json=$(echo "$server_json" | jq -c 'if .env then .env |= with_entries(if (.key | test("TOKEN|KEY|SECRET|PASSWORD|PASS|API"; "i")) then .value = "CHANGEME" else . end) else . end')
        safe_json_var="_mcp_$(echo "$name" | tr '-' '_')_json"
        escaped_json=$(printf '%s' "$server_json" | sed "s/'/'\\\\''/g")
        cat >> "$OUTPUT" << MCPEOF
# SECRETS REQUIRED for $name:$secret_env_keys
# Edit $safe_json_var below to fill in the real values before running
$safe_json_var='$escaped_json'
if prompt_yn "Install MCP server: $name [SECRETS — edit $safe_json_var above first]"; then
  if echo "\$$safe_json_var" | grep -q '"CHANGEME"'; then
    echo -e "  \${YELLOW}Skipped: fill in secret values in $safe_json_var first\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  elif claude mcp list 2>/dev/null | grep -q "$name"; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    claude mcp add-json '$name' "\$$safe_json_var" -s user
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi
echo ""

MCPEOF
      else
        escaped_json=$(printf '%s' "$server_json" | sed "s/'/'\\\\''/g")
        cat >> "$OUTPUT" << MCPEOF
if prompt_yn "Install MCP server: $name"; then
  if claude mcp list 2>/dev/null | grep -q "$name"; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    claude mcp add-json '$name' '$escaped_json' -s user
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi
echo ""

MCPEOF
      fi
    done <<< "$MCP_KEYS"
  fi
fi

# Cloud MCPs from `claude mcp list` (claude.ai prefix = account-level)
CLOUD_MCPS=()
while IFS= read -r line; do
  if [[ "$line" =~ ^claude\.ai\ (.+):\ (.+)\ -\ (.*)$ ]]; then
    mcp_name="${BASH_REMATCH[1]}"
    mcp_url="${BASH_REMATCH[2]}"
    mcp_status="${BASH_REMATCH[3]}"
    CLOUD_MCPS+=("$mcp_name|$mcp_url|$mcp_status")
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
  } >> "$OUTPUT"
fi

# Stdio/custom MCPs from project .mcp.json files in home dir (not marketplace ones)
# Skip these -- they're project-specific

if [[ "$HAS_LOCAL_MCPS" == false && ${#CLOUD_MCPS[@]} -eq 0 ]]; then
  echo 'echo "  No MCP servers found."' >> "$OUTPUT"
  echo 'echo ""' >> "$OUTPUT"
fi

# ─── Section: Zsh Config ─────────────────────────────────────────────────

echo "Scanning zsh config..."

{
  echo 'echo "=== Zsh Config ==="'
  echo 'echo ""'
  echo 'touch ~/.zshrc'
  echo ''
} >> "$OUTPUT"

ZSHRC="$HOME/.zshrc"
ZSH_ITEMS=0

if [[ -f "$ZSHRC" ]]; then
  # Helper: emit a prompted append block
  emit_zsh_item() {
    local label="$1"
    local line="$2"
    local sq_escaped
    local display
    sq_escaped=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")
    display=$(printf '%s' "$line" | sed 's/"/\\"/g')
    cat >> "$OUTPUT" << ITEMEOF
if prompt_yn "Add: $display"; then
  append_to_zshrc '$sq_escaped'
fi

ITEMEOF
    ZSH_ITEMS=$((ZSH_ITEMS + 1))
  }

  # Extract aliases
  while IFS= read -r line; do
    emit_zsh_item "alias" "$line"
  done < <(grep -E '^alias ' "$ZSHRC" || true)

  # Helper: emit a secret export block — value redacted to CHANGEME, skipped at runtime if not set
  emit_secret_export() {
    local var_name="$1"
    local safe_var="_secret_$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    cat >> "$OUTPUT" << SECRETEOF
# SECRET: fill in the real value for $var_name before running this script
$safe_var='CHANGEME'
if prompt_yn "Add: export $var_name [SECRET — edit \$${safe_var} above first]"; then
  if [[ "\$$safe_var" == "CHANGEME" ]]; then
    echo -e "  \${YELLOW}Skipped: value is still CHANGEME — set it before running\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    append_to_zshrc "export $var_name=\$$safe_var"
  fi
fi
echo ""

SECRETEOF
    ZSH_ITEMS=$((ZSH_ITEMS + 1))
  }

  # Extract exports (non-PATH), redacting secrets
  while IFS= read -r line; do
    var_name=$(echo "$line" | sed -E 's/^export ([A-Z_][A-Z0-9_]*)=.*/\1/')
    if echo "$var_name" | grep -qE '(TOKEN|KEY|SECRET|PASSWORD|PASS|API)'; then
      emit_secret_export "$var_name"
    else
      emit_zsh_item "export" "$line"
    fi
  done < <(grep -E '^export ' "$ZSHRC" | grep -v 'PATH=' || true)

  # Extract PATH entries
  while IFS= read -r line; do
    emit_zsh_item "path" "$line"
  done < <(grep -E '(^export PATH=|^path\+=)' "$ZSHRC" || true)

  # Extract functions (name() { ... })
  in_func=false
  func_name=""
  func_body=""
  while IFS= read -r line; do
    if [[ "$in_func" == false && "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\ *\{ ]]; then
      in_func=true
      func_name="${BASH_REMATCH[1]}"
      func_body="$line"
    elif [[ "$in_func" == true ]]; then
      func_body="$func_body
$line"
      if [[ "$line" == "}" ]]; then
        in_func=false
        # Write function as a block
        escaped_name=$(printf '%s' "$func_name" | sed "s/'/'\\\\''/g")
        escaped_body=$(printf '%s' "$func_body" | sed "s/'/'\\\\''/g")
        cat >> "$OUTPUT" << FUNCEOF
if prompt_yn "Add function: $escaped_name()"; then
  if ! grep -qF '${escaped_name}()' ~/.zshrc 2>/dev/null; then
    cat >> ~/.zshrc << 'ZSHFUNC'
$func_body
ZSHFUNC
    echo -e "  \${GREEN}Added\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  else
    echo -e "  \${YELLOW}Already exists, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  fi
fi

FUNCEOF
        ((ZSH_ITEMS++))
        func_body=""
        func_name=""
      fi
    fi
  done < "$ZSHRC"

  # Extract source lines
  while IFS= read -r line; do
    escaped=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")
    cat >> "$OUTPUT" << SRCEOF
if prompt_yn "Add: $escaped"; then
  append_to_zshrc '$escaped'
fi

SRCEOF
    ((ZSH_ITEMS++))
  done < <(grep -E '^source ' "$ZSHRC" || true)
fi

if [[ "$ZSH_ITEMS" -eq 0 ]]; then
  echo 'echo "  No zsh config entries found."' >> "$OUTPUT"
fi
echo 'echo ""' >> "$OUTPUT"

# ─── Section: RTK ────────────────────────────────────────────────────────────

echo "Scanning RTK..."

{
  echo 'echo "=== RTK (token optimizer) ==="'
  echo 'echo ""'
} >> "$OUTPUT"

if command -v rtk &>/dev/null; then
  RTK_VERSION=$(rtk --version 2>/dev/null | awk '{print $NF}')
  cat >> "$OUTPUT" << RTKEOF
if prompt_yn "Install rtk $RTK_VERSION (brew install rtk)"; then
  if command -v rtk &>/dev/null; then
    echo -e "  \${YELLOW}Already installed (\$(rtk --version 2>/dev/null)), skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  elif command -v brew &>/dev/null; then
    brew install rtk
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  else
    echo -e "  \${YELLOW}Homebrew not found — install brew first, then: brew install rtk\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  fi
fi
echo ""

RTKEOF
else
  echo 'echo "  rtk not found on source machine, skipping."' >> "$OUTPUT"
  echo 'echo ""' >> "$OUTPUT"
fi

# ─── Section: Claude Plugins ─────────────────────────────────────────────────

echo "Scanning Claude plugins..."

{
  echo 'echo "=== Claude Code Plugins ==="'
  echo 'echo ""'
} >> "$OUTPUT"

INSTALLED_PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"
MARKETPLACES_FILE="$HOME/.claude/plugins/known_marketplaces.json"

# Emit marketplace install first (plugins depend on it)
if [[ -f "$MARKETPLACES_FILE" ]] && command -v jq &>/dev/null; then
  MARKETPLACE_NAMES=$(jq -r 'keys[]' "$MARKETPLACES_FILE" 2>/dev/null || true)
  if [[ -n "$MARKETPLACE_NAMES" ]]; then
    while IFS= read -r mkt_name; do
      source_repo=$(jq -r ".\"$mkt_name\".source.repo" "$MARKETPLACES_FILE")
      cat >> "$OUTPUT" << MKTEOF
if prompt_yn "Add plugin marketplace: $mkt_name (github:$source_repo)"; then
  if [[ -d "\$HOME/.claude/plugins/marketplaces/$mkt_name" ]]; then
    echo -e "  \${YELLOW}Already added, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    claude plugins marketplace add "github:$source_repo"
    echo -e "  \${GREEN}Added\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi
echo ""

MKTEOF
    done <<< "$MARKETPLACE_NAMES"
  fi
fi

# Emit each installed plugin
if [[ -f "$INSTALLED_PLUGINS_FILE" ]] && command -v jq &>/dev/null; then
  PLUGIN_KEYS=$(jq -r '.plugins | keys[]' "$INSTALLED_PLUGINS_FILE" 2>/dev/null || true)
  if [[ -n "$PLUGIN_KEYS" ]]; then
    while IFS= read -r plugin_key; do
      plugin_version=$(jq -r ".plugins[\"$plugin_key\"][0].version" "$INSTALLED_PLUGINS_FILE")
      cat >> "$OUTPUT" << PLUGINEOF
if prompt_yn "Install Claude plugin: $plugin_key@$plugin_version"; then
  if claude plugins list 2>/dev/null | grep -q "$plugin_key"; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    claude plugins install "$plugin_key" -s user
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi
echo ""

PLUGINEOF
    done <<< "$PLUGIN_KEYS"
  fi
fi

# Claude global settings (non-MCP parts)
echo 'echo "=== Claude Code Settings ==="' >> "$OUTPUT"
echo 'echo ""' >> "$OUTPUT"
if [[ -f "$SETTINGS_FILE" ]] && command -v jq &>/dev/null; then
  # Extract non-MCP settings
  settings_no_mcp=$(jq -c 'del(.mcpServers)' "$SETTINGS_FILE" 2>/dev/null || true)
  if [[ -n "$settings_no_mcp" && "$settings_no_mcp" != "{}" ]]; then
    escaped_settings=$(printf '%s' "$settings_no_mcp" | sed "s/'/'\\\\''/g")
    cat >> "$OUTPUT" << SETTINGSEOF
echo "  Current source machine settings.json (excluding MCPs):"
echo '  $escaped_settings'
echo ""
if prompt_yn "Merge these settings into ~/.claude/settings.json"; then
  if command -v jq &>/dev/null; then
    if [[ -f "\$HOME/.claude/settings.json" ]]; then
      jq -s '.[0] * .[1]' "\$HOME/.claude/settings.json" <(echo '$escaped_settings') > "\$HOME/.claude/settings.json.tmp"
      mv "\$HOME/.claude/settings.json.tmp" "\$HOME/.claude/settings.json"
    else
      mkdir -p "\$HOME/.claude"
      echo '$escaped_settings' | jq '.' > "\$HOME/.claude/settings.json"
    fi
    echo -e "  \${GREEN}Merged\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  else
    echo -e "  \${YELLOW}jq not found, skipping settings merge\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  fi
fi
echo ""

SETTINGSEOF
  fi
fi

# ─── Section: Homebrew (optional) ─────────────────────────────────────────

if [[ "$WITH_BREW" == true ]]; then
  echo "Scanning Homebrew packages..."

  {
    echo 'echo "=== Homebrew Packages ==="'
    echo 'echo ""'
  } >> "$OUTPUT"

  if command -v brew &>/dev/null; then
    while IFS= read -r pkg; do
      cat >> "$OUTPUT" << BREWEOF
if prompt_yn "Install brew package: $pkg"; then
  if brew list --formula 2>/dev/null | grep -q "^${pkg}\$"; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    brew install "$pkg"
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi

BREWEOF
    done < <(brew list --formula 2>/dev/null || true)

    # Also capture casks
    echo 'echo ""' >> "$OUTPUT"
    echo 'echo "--- Homebrew Casks ---"' >> "$OUTPUT"
    echo 'echo ""' >> "$OUTPUT"
    while IFS= read -r cask; do
      cat >> "$OUTPUT" << CASKEOF
if prompt_yn "Install brew cask: $cask"; then
  if brew list --cask 2>/dev/null | grep -q "^${cask}\$"; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    brew install --cask "$cask"
    echo -e "  \${GREEN}Installed\${NC}"
    INSTALLED=\$((INSTALLED + 1))
  fi
fi

CASKEOF
    done < <(brew list --cask 2>/dev/null || true)
  else
    echo 'echo "  Homebrew not found on source machine."' >> "$OUTPUT"
  fi

  echo 'echo ""' >> "$OUTPUT"
fi

# ─── Footer ──────────────────────────────────────────────────────────────

cat >> "$OUTPUT" << 'FOOTER'
echo ""
echo "=========================================="
echo -e "  ${GREEN}Installed: $INSTALLED${NC}"
echo -e "  ${YELLOW}Skipped:   $SKIPPED${NC}"
echo "=========================================="
echo ""
echo "Done! You may want to run: source ~/.zshrc"
FOOTER

chmod +x "$OUTPUT"

echo ""
echo "Generated: $OUTPUT ($(wc -l < "$OUTPUT" | tr -d ' ') lines)"
echo "Transfer to your other machine and run: ./$OUTPUT"
