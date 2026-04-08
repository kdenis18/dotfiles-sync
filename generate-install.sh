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

# ─── Preamble (embedded in generated script) ────────────────────────────

cat > "$OUTPUT" << 'PREAMBLE'
#!/usr/bin/env bash
set -uo pipefail

# Auto-generated install script
# Transfer this to another machine and run it.
# Each item prompts before installing.
# Use --dry-run to preview what would be installed without making changes.

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo "  --dry-run  Preview what would be installed without making changes"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'
INSTALLED=0
SKIPPED=0
PRESENT=0

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${BLUE}=== DRY RUN MODE — no changes will be made ===${NC}"
  echo ""
fi

prompt_yn() {
  local msg="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GRAY}[dry-run]${NC} $msg"
    return 0
  fi
  printf "${BLUE}%s${NC} [y/N] " "$msg"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

mark_installed() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${GRAY}Would install: ${1:-item}${NC}"
    INSTALLED=$((INSTALLED + 1))
    return
  fi
  echo -e "  ${GREEN}${1:-Installed}${NC}"
  INSTALLED=$((INSTALLED + 1))
}

mark_skipped() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${GRAY}Skip: ${1:-already present}${NC}"
    SKIPPED=$((SKIPPED + 1))
    return
  fi
  echo -e "  ${YELLOW}${1:-Skipped}${NC}"
  SKIPPED=$((SKIPPED + 1))
}

mark_present() {
  echo -e "  ${GREEN}${1:-Already installed}${NC}"
  PRESENT=$((PRESENT + 1))
}

append_to_zshrc() {
  local line="$1"
  if [[ "$DRY_RUN" == true ]]; then
    if ! grep -qF "$line" ~/.zshrc 2>/dev/null; then
      mark_installed "Added"
    else
      mark_skipped "Already exists, skipped"
    fi
    return
  fi
  if ! grep -qF "$line" ~/.zshrc 2>/dev/null; then
    echo "$line" >> ~/.zshrc
    mark_installed "Added"
  else
    mark_skipped "Already exists, skipped"
  fi
}

install_brew_formula() {
  local formula="$1" check_path="${2:-}"
  if [[ -n "$check_path" && -e "$check_path" ]]; then
    mark_skipped "Already installed, skipped"
  elif [[ "$DRY_RUN" == true ]]; then
    mark_installed "brew install $formula"
  elif command -v brew &>/dev/null; then
    brew install $formula
    mark_installed
  else
    mark_skipped "Homebrew not found — install brew first, then: brew install $formula"
  fi
}

install_brew_cask() {
  local cask="$1" check_path="${2:-}"
  if [[ -n "$check_path" && -e "$check_path" ]]; then
    mark_skipped "Already installed, skipped"
  elif [[ "$DRY_RUN" == true ]]; then
    mark_installed "brew install --cask $cask"
  elif command -v brew &>/dev/null; then
    brew install --cask "$cask"
    mark_installed
  else
    mark_skipped "Homebrew not found — install brew first, then: brew install --cask $cask"
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

# ─── Generator Helpers ──────────────────────────────────────────────────

emit_section_header() {
  local label="$1"
  {
    echo ""
    echo "echo \"=== $label ===\""
    echo 'echo ""'
  } >> "$OUTPUT"
}

emit_brew_cask() {
  local label="$1" cask="$2" check_path="$3"
  cat >> "$OUTPUT" << EMITEOF
if [[ -n "$check_path" && -e "$check_path" ]]; then
  mark_present "$label — already installed"
elif prompt_yn "Install $label (brew install --cask $cask)"; then
  install_brew_cask "$cask" "$check_path"
fi
echo ""

EMITEOF
}

emit_brew_formula() {
  local label="$1" formula="$2" check_path="$3"
  cat >> "$OUTPUT" << EMITEOF
if [[ -n "$check_path" && -e "$check_path" ]]; then
  mark_present "$label — already installed"
elif prompt_yn "Install $label (brew install $formula)"; then
  install_brew_formula "$formula" "$check_path"
fi
echo ""

EMITEOF
}

emit_install_cmd() {
  local label="$1" cmd="$2" check_path="$3"
  cat >> "$OUTPUT" << EMITEOF
if [[ -e "$check_path" ]]; then
  mark_present "$label — already installed"
elif prompt_yn "Install $label"; then
  if [[ "\$DRY_RUN" != true ]]; then
    $cmd
  fi
  mark_installed
fi
echo ""

EMITEOF
}

emit_install_hint() {
  local label="$1" hint="$2" check_path="$3"
  cat >> "$OUTPUT" << EMITEOF
if [[ ! -e "$check_path" ]]; then
  mark_skipped "$label not found — $hint"
  echo ""
fi

EMITEOF
}

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

      # Detect and replace absolute $HOME paths with @@HOME@@ placeholder
      has_abs_path=false
      if echo "$server_json" | grep -q "$HOME"; then
        server_json=$(echo "$server_json" | sed "s|$HOME|@@HOME@@|g")
        has_abs_path=true
        echo "  WARNING: $name MCP contains absolute paths — will be rewritten to use \$HOME on target"
      fi

      # Find env keys that look like secrets
      secret_env_keys=""
      while IFS= read -r env_key; do
        if echo "$env_key" | grep -qE '(TOKEN|KEY|SECRET|PASSWORD|PASS|API)'; then
          secret_env_keys="$secret_env_keys $env_key"
        fi
      done < <(echo "$server_json" | jq -r '.env // {} | keys[]' 2>/dev/null || true)

      safe_json_var="_mcp_$(echo "$name" | tr '-' '_')_json"

      if [[ -n "$secret_env_keys" ]]; then
        # Redact secret env values before embedding
        server_json=$(echo "$server_json" | jq -c 'if .env then .env |= with_entries(if (.key | test("TOKEN|KEY|SECRET|PASSWORD|PASS|API"; "i")) then .value = "CHANGEME" else . end) else . end')
        escaped_json=$(printf '%s' "$server_json" | sed "s/'/'\\\\''/g")
        # Build secret keys list for the for loop
        secret_keys_list=$(echo "$secret_env_keys" | tr -s ' ' | sed 's/^ //')
        cat >> "$OUTPUT" << MCPEOF
# SECRETS REQUIRED for $name:$secret_env_keys
# Edit $safe_json_var below, or the script will prompt at runtime
$safe_json_var='$escaped_json'
MCPEOF
        if [[ "$has_abs_path" == true ]]; then
          cat >> "$OUTPUT" << MCPEOF
# PATH NOTE: @@HOME@@ will be replaced with your actual \$HOME
$safe_json_var="\${${safe_json_var}//@@HOME@@/\$HOME}"
MCPEOF
        fi
        cat >> "$OUTPUT" << MCPEOF
if claude mcp list 2>/dev/null | grep -q "$name"; then
  mark_present "MCP server: $name — already installed"
elif prompt_yn "Install MCP server: $name"; then
  _json="\$$safe_json_var"
  _skip=false
  for _key in $secret_keys_list; do
    if echo "\$_json" | grep -q "\"\$_key\":\"CHANGEME\""; then
      printf "  Enter value for %s (Enter to skip): " "\$_key"
      read -r _val
      if [[ -z "\$_val" ]]; then
        mark_skipped "Skipped: \$_key not provided"
        _skip=true
        break
      fi
      _json="\${_json/\"\$_key\":\"CHANGEME\"/\"\$_key\":\"\$_val\"}"
    fi
  done
  if [[ "\$_skip" != true ]]; then
    claude mcp add-json '$name' "\$_json" -s user
    mark_installed
  fi
fi
echo ""

MCPEOF
      else
        escaped_json=$(printf '%s' "$server_json" | sed "s/'/'\\\\''/g")
        cat >> "$OUTPUT" << MCPEOF
$safe_json_var='$escaped_json'
MCPEOF
        if [[ "$has_abs_path" == true ]]; then
          cat >> "$OUTPUT" << MCPEOF
# PATH NOTE: @@HOME@@ will be replaced with your actual \$HOME
$safe_json_var="\${${safe_json_var}//@@HOME@@/\$HOME}"
MCPEOF
        fi
        cat >> "$OUTPUT" << MCPEOF
if claude mcp list 2>/dev/null | grep -q "$name"; then
  mark_present "MCP server: $name — already installed"
elif prompt_yn "Install MCP server: $name"; then
  claude mcp add-json '$name' "\$$safe_json_var" -s user
  mark_installed
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
if grep -qF '$sq_escaped' ~/.zshrc 2>/dev/null; then
  mark_present "Already in .zshrc: $display"
elif prompt_yn "Add: $display"; then
  append_to_zshrc '$sq_escaped'
fi

ITEMEOF
    ZSH_ITEMS=$((ZSH_ITEMS + 1))
  }

  # Extract aliases
  while IFS= read -r line; do
    emit_zsh_item "alias" "$line"
  done < <(grep -E '^alias ' "$ZSHRC" || true)

  # Helper: emit a secret export block — value redacted to CHANGEME, prompts at runtime if still CHANGEME
  emit_secret_export() {
    local var_name="$1"
    local safe_var="_secret_$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    cat >> "$OUTPUT" << SECRETEOF
# SECRET: fill in the real value for $var_name, or enter it when prompted
$safe_var='CHANGEME'
if grep -qF "export $var_name=" ~/.zshrc 2>/dev/null; then
  mark_present "Already in .zshrc: export $var_name"
elif prompt_yn "Add: export $var_name [SECRET]"; then
  if [[ "\$$safe_var" == "CHANGEME" ]]; then
    printf "  Enter value for $var_name (Enter to skip): "
    read -r _input_val
    if [[ -z "\$_input_val" ]]; then
      mark_skipped
    else
      append_to_zshrc "export $var_name=\$_input_val"
    fi
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
if grep -qF '${escaped_name}()' ~/.zshrc 2>/dev/null; then
  mark_present "Already in .zshrc: ${escaped_name}()"
elif prompt_yn "Add function: $escaped_name()"; then
  cat >> ~/.zshrc << 'ZSHFUNC'
$func_body
ZSHFUNC
  mark_installed "Added"
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
if grep -qF '$escaped' ~/.zshrc 2>/dev/null; then
  mark_present "Already in .zshrc: $escaped"
elif prompt_yn "Add: $escaped"; then
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

emit_section_header "RTK (token optimizer)"

if command -v rtk &>/dev/null; then
  RTK_VERSION=$(rtk --version 2>/dev/null | awk '{print $NF}')
  cat >> "$OUTPUT" << RTKEOF
if command -v rtk &>/dev/null; then
  mark_present "rtk — already installed (\$(rtk --version 2>/dev/null))"
elif prompt_yn "Install rtk $RTK_VERSION (brew install rtk)"; then
  if command -v brew &>/dev/null; then
    brew install rtk
    mark_installed
  else
    mark_skipped "Homebrew not found — install brew first, then: brew install rtk"
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
if [[ -d "\$HOME/.claude/plugins/marketplaces/$mkt_name" ]]; then
  mark_present "Plugin marketplace: $mkt_name — already added"
elif prompt_yn "Add plugin marketplace: $mkt_name (github:$source_repo)"; then
  claude plugins marketplace add "github:$source_repo"
  mark_installed "Added"
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
if claude plugins list 2>/dev/null | grep -q "$plugin_key"; then
  mark_present "Claude plugin: $plugin_key — already installed"
elif prompt_yn "Install Claude plugin: $plugin_key@$plugin_version"; then
  claude plugins install "$plugin_key" -s user
  mark_installed
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
  # Replace hardcoded home path with @@HOME@@ so it resolves correctly on the target machine
  settings_no_mcp=$(echo "$settings_no_mcp" | sed "s|$HOME|@@HOME@@|g")
  if [[ -n "$settings_no_mcp" && "$settings_no_mcp" != "{}" ]]; then
    escaped_settings=$(printf '%s' "$settings_no_mcp" | sed "s/'/'\\\\''/g")
    cat >> "$OUTPUT" << SETTINGSEOF
_settings_json='$escaped_settings'
_settings_json="\${_settings_json//@@HOME@@/\$HOME}"
echo "  Current source machine settings.json (excluding MCPs):"
echo "  \$_settings_json"
echo ""
if prompt_yn "Merge these settings into ~/.claude/settings.json"; then
  if command -v jq &>/dev/null; then
    if [[ -f "\$HOME/.claude/settings.json" ]]; then
      jq -s '.[0] * .[1]' "\$HOME/.claude/settings.json" <(echo "\$_settings_json") > "\$HOME/.claude/settings.json.tmp"
      mv "\$HOME/.claude/settings.json.tmp" "\$HOME/.claude/settings.json"
    else
      mkdir -p "\$HOME/.claude"
      echo "\$_settings_json" | jq '.' > "\$HOME/.claude/settings.json"
    fi
    mark_installed "Merged"
  else
    mark_skipped "jq not found, skipping settings merge"
  fi
fi
echo ""

SETTINGSEOF
  fi
fi

# ─── Section: Version Managers (manifest-driven) ────────────────────────────

MANIFEST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dotfiles-manifest.json"

echo "Scanning version managers..."

{
  echo 'echo "=== Version Managers ==="'
  echo 'echo ""'
} >> "$OUTPUT"

_vm_found=false

if [[ -f "$MANIFEST_FILE" ]] && command -v jq &>/dev/null; then
  VM_COUNT=$(jq '.version_managers | length // 0' "$MANIFEST_FILE" 2>/dev/null || echo 0)

  for vi in $(seq 0 $((VM_COUNT - 1))); do
    vm_name=$(jq -r ".version_managers[$vi].name" "$MANIFEST_FILE")
    vm_label=$(jq -r ".version_managers[$vi].label // .version_managers[$vi].name" "$MANIFEST_FILE")
    vm_check_cmd=$(jq -r ".version_managers[$vi].check_cmd // empty" "$MANIFEST_FILE")
    vm_check_dir=$(jq -r ".version_managers[$vi].check_dir // empty" "$MANIFEST_FILE")
    vm_brew_formula=$(jq -r ".version_managers[$vi].brew_formula // empty" "$MANIFEST_FILE")
    vm_install_cmd=$(jq -r ".version_managers[$vi].install_cmd // empty" "$MANIFEST_FILE")
    vm_install_cmd_fallback=$(jq -r ".version_managers[$vi].install_cmd_fallback // empty" "$MANIFEST_FILE")
    vm_install_msg=$(jq -r ".version_managers[$vi].install_msg // empty" "$MANIFEST_FILE")
    vm_tv_file=$(jq -r ".version_managers[$vi].tool_version_file // empty" "$MANIFEST_FILE")
    vm_tv_pattern=$(jq -r ".version_managers[$vi].tool_version_pattern // empty" "$MANIFEST_FILE")
    vm_managed_lang=$(jq -r ".version_managers[$vi].managed_lang // empty" "$MANIFEST_FILE")
    vm_version_file=$(jq -r ".version_managers[$vi].version_file // empty" "$MANIFEST_FILE")
    vm_version_cmd=$(jq -r ".version_managers[$vi].version_cmd // empty" "$MANIFEST_FILE")
    vm_requires_check=$(jq -r ".version_managers[$vi].requires_check // empty" "$MANIFEST_FILE")
    vm_pre_use_cmd=$(jq -r ".version_managers[$vi].pre_use_cmd // empty" "$MANIFEST_FILE")
    vm_check_version_cmd=$(jq -r ".version_managers[$vi].check_version_cmd // empty" "$MANIFEST_FILE")
    vm_install_version_cmd=$(jq -r ".version_managers[$vi].install_version_cmd // empty" "$MANIFEST_FILE")
    vm_install_version_msg=$(jq -r ".version_managers[$vi].install_version_msg // \"Installed and set as global\"" "$MANIFEST_FILE")

    # Expand $HOME for source-machine detection
    vm_check_dir_expanded="${vm_check_dir/\$HOME/$HOME}"

    # Detect on source machine
    is_present=false
    if [[ -n "$vm_check_cmd" ]] && command -v "$vm_check_cmd" &>/dev/null; then
      is_present=true
    elif [[ -n "$vm_check_dir" && -d "$vm_check_dir_expanded" ]]; then
      is_present=true
    fi
    [[ "$is_present" == true ]] || continue
    _vm_found=true

    # Get tool version
    tool_version=""
    if [[ -n "$vm_check_cmd" ]]; then
      tool_version=$("$vm_check_cmd" --version 2>/dev/null | awk '{print $2}' || echo "")
    fi
    if [[ -z "$tool_version" && -n "$vm_tv_file" && -n "$vm_tv_pattern" ]]; then
      vm_tv_file_expanded="${vm_tv_file/\$HOME/$HOME}"
      tool_version=$(grep "$vm_tv_pattern" "$vm_tv_file_expanded" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    fi

    echo "  Found: $vm_label $tool_version"

    # ── Emit: install version manager itself ──
    if [[ -n "$vm_brew_formula" ]]; then
      cat >> "$OUTPUT" << VMEOF
if command -v $vm_check_cmd &>/dev/null; then
  mark_present "$vm_label — already installed (\$($vm_check_cmd --version 2>/dev/null))"
elif prompt_yn "Install $vm_label (brew install $vm_brew_formula)"; then
  if command -v brew &>/dev/null; then
    brew install $vm_brew_formula
    mark_installed
  else
    mark_skipped "Homebrew not found — install brew first"
  fi
fi
echo ""

VMEOF
    elif [[ -n "$vm_install_cmd" ]]; then
      # Custom install (e.g. curl for nvm)
      if [[ -n "$tool_version" ]]; then
        resolved_vm_cmd="${vm_install_cmd//\{tool_version\}/$tool_version}"
      elif [[ -n "$vm_install_cmd_fallback" ]]; then
        resolved_vm_cmd="$vm_install_cmd_fallback"
      else
        resolved_vm_cmd="${vm_install_cmd//\{tool_version\}/latest}"
      fi
      local_install_msg="${vm_install_msg:-Installed}"

      if [[ -n "$vm_check_dir" ]]; then
        cat >> "$OUTPUT" << VMEOF
if [[ -d "$vm_check_dir" ]]; then
  mark_present "$vm_label — already installed"
elif prompt_yn "Install $vm_label via curl"; then
  $resolved_vm_cmd
  mark_installed "$local_install_msg"
fi
echo ""

VMEOF
      fi
    fi

    # ── Emit: install managed language version ──
    vm_version_file_expanded="${vm_version_file/\$HOME/$HOME}"
    lang_version=""
    if [[ -n "$vm_version_file" ]]; then
      lang_version=$(cat "$vm_version_file_expanded" 2>/dev/null || echo "")
    fi
    if [[ -z "$lang_version" && -n "$vm_version_cmd" ]]; then
      lang_version=$(eval "$vm_version_cmd" 2>/dev/null || echo "")
    fi

    if [[ -n "$lang_version" && -n "$vm_install_version_cmd" ]]; then
      resolved_install="${vm_install_version_cmd//\{version\}/$lang_version}"
      resolved_check="${vm_check_version_cmd//\{version\}/$lang_version}"

      # Determine requires check for target machine
      if [[ -n "$vm_requires_check" ]]; then
        requires_check="$vm_requires_check"
      elif [[ -n "$vm_check_cmd" ]]; then
        requires_check="command -v $vm_check_cmd &>/dev/null"
      fi

      # Build the managed version block using echo to handle optional pre_use_cmd
      {
        echo "if $requires_check; then"
        if [[ -n "$vm_pre_use_cmd" ]]; then
          echo "  $vm_pre_use_cmd"
        fi
        echo "  if $resolved_check; then"
        echo "    mark_present \"$vm_managed_lang $lang_version — already installed via $vm_label\""
        echo "  elif prompt_yn \"Install $vm_managed_lang $lang_version via $vm_label ($resolved_install)\"; then"
        echo '    if [[ "$DRY_RUN" != true ]]; then'
        echo "      $resolved_install"
        echo "    fi"
        echo "    mark_installed \"$vm_install_version_msg\""
        echo "  fi"
        echo "else"
        echo "  mark_skipped \"$vm_label not installed — install $vm_label first to set up $vm_managed_lang $lang_version\""
        echo "fi"
        echo 'echo ""'
        echo ""
      } >> "$OUTPUT"
    fi
  done
fi

if [[ "$_vm_found" == false ]]; then
  echo 'echo "  No version managers found."' >> "$OUTPUT"
  echo 'echo ""' >> "$OUTPUT"
fi

# ─── Section: Tool Configs (manifest-driven) ─────────────────────────────────

MANIFEST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dotfiles-manifest.json"

if [[ -f "$MANIFEST_FILE" ]] && command -v jq &>/dev/null; then
  echo "Scanning tools from dotfiles-manifest.json..."
  TOOL_COUNT=$(jq '.tools | length' "$MANIFEST_FILE")

  for i in $(seq 0 $((TOOL_COUNT - 1))); do
    tool_name=$(jq -r ".tools[$i].name" "$MANIFEST_FILE")
    tool_label=$(jq -r ".tools[$i].label // .tools[$i].name" "$MANIFEST_FILE")
    check_path=$(jq -r ".tools[$i].check_path // empty" "$MANIFEST_FILE")
    install_cmd=$(jq -r ".tools[$i].install_cmd // empty" "$MANIFEST_FILE")
    install_hint=$(jq -r ".tools[$i].install_hint // empty" "$MANIFEST_FILE")
    brew_formula=$(jq -r ".tools[$i].brew_formula // empty" "$MANIFEST_FILE")
    brew_cask=$(jq -r ".tools[$i].brew_cask // empty" "$MANIFEST_FILE")
    prefs_plist=$(jq -r ".tools[$i].prefs_plist // empty" "$MANIFEST_FILE")
    # Expand $HOME for generation-time filesystem checks only
    check_path_expanded="${check_path/\$HOME/$HOME}"

    echo "  Found: $tool_label"
    emit_section_header "$tool_label"

    # App install step
    if [[ -n "$install_cmd" ]]; then
      emit_install_cmd "$tool_label" "$install_cmd" "$check_path"
    elif [[ -n "$brew_cask" ]]; then
      emit_brew_cask "$tool_label" "$brew_cask" "$check_path"
    elif [[ -n "$brew_formula" ]]; then
      emit_brew_formula "$tool_label" "$brew_formula" "$check_path"
    elif [[ -n "$install_hint" ]]; then
      emit_install_hint "$tool_label" "$install_hint" "$check_path"
    fi

    # macOS plist prefs step (base64-embedded)
    if [[ -n "$prefs_plist" ]]; then
      plist_b64=$(defaults export "$prefs_plist" - 2>/dev/null | base64 | tr -d '\n') || true
      if [[ -n "$plist_b64" ]]; then
        prefs_marker="PREFS_$(echo "$tool_name" | tr '[:lower:]a-z-' '[:upper:]A-Z_')"
        cat >> "$OUTPUT" << PREFSEOF
if prompt_yn "Import $tool_label preferences"; then
  if [[ -n "$check_path" && ! -e "$check_path" ]]; then
    mark_skipped "$tool_label not installed — skipping prefs"
  elif [[ "\$DRY_RUN" == true ]]; then
    mark_installed "Would import $tool_label preferences"
  else
    base64 -d << '$prefs_marker' | defaults import $prefs_plist - && \
      mark_installed "Imported (restart $tool_label to apply)" || \
      mark_skipped "Import failed"
$plist_b64
$prefs_marker
  fi
fi
echo ""

PREFSEOF
      fi
    fi

    # Config dirs (e.g. custom themes/plugins)
    config_dir_count=$(jq ".tools[$i].config_dirs | length // 0" "$MANIFEST_FILE" 2>/dev/null || echo 0)
    for j in $(seq 0 $((config_dir_count - 1))); do
      src_dir=$(jq -r ".tools[$i].config_dirs[$j].src" "$MANIFEST_FILE")
      dest_dir=$(jq -r ".tools[$i].config_dirs[$j].dest" "$MANIFEST_FILE")
      src_dir_expanded="${src_dir/\$HOME/$HOME}"

      [[ -d "$src_dir_expanded" ]] || continue

      # Build find exclusion args
      find_args=("$src_dir_expanded" -type f)
      while IFS= read -r excl; do
        find_args+=(! -name "$excl" ! -path "*/$excl/*")
      done < <(jq -r ".tools[$i].config_dirs[$j].exclude[]?" "$MANIFEST_FILE" 2>/dev/null || true)

      while IFS= read -r filepath; do
        rel_path="${filepath#$src_dir_expanded/}"
        dest_path="$dest_dir/$rel_path"
        file_b64=$(base64 < "$filepath" | tr -d '\n')
        file_marker="FILE_$(echo "$tool_name" | tr '[:lower:]a-z-' '[:upper:]A-Z_')_$(echo "$rel_path" | tr '/.-' '___')"
        cat >> "$OUTPUT" << FILEEOF
if prompt_yn "Restore $tool_label config: $rel_path"; then
  mkdir -p "\$(dirname "$dest_path")"
  base64 -d << '$file_marker' > "$dest_path"
$file_b64
$file_marker
  mark_installed "Restored"
fi
echo ""

FILEEOF
      done < <(find "${find_args[@]}" 2>/dev/null || true)
    done
  done
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
if brew list --formula 2>/dev/null | grep -q "^${pkg}\$"; then
  mark_present "$pkg — already installed"
elif prompt_yn "Install brew package: $pkg"; then
  brew install "$pkg"
  mark_installed
fi

BREWEOF
    done < <(brew list --formula 2>/dev/null || true)

    # Also capture casks
    echo 'echo ""' >> "$OUTPUT"
    echo 'echo "--- Homebrew Casks ---"' >> "$OUTPUT"
    echo 'echo ""' >> "$OUTPUT"
    while IFS= read -r cask; do
      cat >> "$OUTPUT" << CASKEOF
if brew list --cask 2>/dev/null | grep -q "^${cask}\$"; then
  mark_present "$cask — already installed"
elif prompt_yn "Install brew cask: $cask"; then
  brew install --cask "$cask"
  mark_installed
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
if [[ "$DRY_RUN" == true ]]; then
  echo -e "  ${BLUE}DRY RUN SUMMARY${NC}"
  echo -e "  ${GREEN}Would install:  $INSTALLED${NC}"
  echo -e "  ${GREEN}Already present: $PRESENT${NC}"
  echo -e "  ${YELLOW}Would skip:     $SKIPPED${NC}"
  echo ""
  echo "  Run without --dry-run to apply changes."
else
  echo -e "  ${GREEN}Installed:       $INSTALLED${NC}"
  echo -e "  ${GREEN}Already present: $PRESENT${NC}"
  echo -e "  ${YELLOW}Skipped:         $SKIPPED${NC}"
fi
echo "=========================================="
echo ""
if [[ "$DRY_RUN" != true ]]; then
  echo "Done! You may want to run: source ~/.zshrc"
fi
FOOTER

chmod +x "$OUTPUT"

echo ""
echo "Generated: $OUTPUT ($(wc -l < "$OUTPUT" | tr -d ' ') lines)"
echo "Transfer to your other machine and run: ./$OUTPUT"
