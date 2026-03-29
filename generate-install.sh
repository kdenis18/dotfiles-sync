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

# Local MCPs from settings.json (user-scoped, added via `claude mcp add`)
SETTINGS_FILE="$HOME/.claude/settings.json"
HAS_LOCAL_MCPS=false
if [[ -f "$SETTINGS_FILE" ]] && command -v jq &>/dev/null; then
  MCP_KEYS=$(jq -r '.mcpServers // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null || true)
  if [[ -n "$MCP_KEYS" ]]; then
    HAS_LOCAL_MCPS=true
    while IFS= read -r name; do
      server_json=$(jq -c ".mcpServers[\"$name\"]" "$SETTINGS_FILE")
      # Escape for embedding in script
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

  # Extract exports (non-PATH)
  while IFS= read -r line; do
    emit_zsh_item "export" "$line"
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

# ─── Section: Claude Plugins/Marketplaces ─────────────────────────────────

echo "Scanning Claude plugins..."

{
  echo 'echo "=== Claude Code Plugins ==="'
  echo 'echo ""'
} >> "$OUTPUT"

MARKETPLACES_FILE="$HOME/.claude/plugins/known_marketplaces.json"
if [[ -f "$MARKETPLACES_FILE" ]] && command -v jq &>/dev/null; then
  MARKETPLACE_NAMES=$(jq -r 'keys[]' "$MARKETPLACES_FILE" 2>/dev/null || true)
  if [[ -n "$MARKETPLACE_NAMES" ]]; then
    while IFS= read -r mkt_name; do
      source_type=$(jq -r ".\"$mkt_name\".source.source" "$MARKETPLACES_FILE")
      source_repo=$(jq -r ".\"$mkt_name\".source.repo" "$MARKETPLACES_FILE")
      cat >> "$OUTPUT" << MKTEOF
if prompt_yn "Install plugin marketplace: $mkt_name ($source_repo)"; then
  if [[ -d "\$HOME/.claude/plugins/marketplaces/$mkt_name" ]]; then
    echo -e "  \${YELLOW}Already installed, skipped\${NC}"
    SKIPPED=\$((SKIPPED + 1))
  else
    echo "  Installing $mkt_name from $source_repo..."
    echo "  (Use Claude Code's plugin manager to add this marketplace)"
    echo -e "  \${YELLOW}Manual step required\${NC}"
  fi
fi
echo ""

MKTEOF
    done <<< "$MARKETPLACE_NAMES"
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
