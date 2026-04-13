#!/usr/bin/env bash
# lib/common.sh — Shared helpers for generate-setup.sh modules
# Sourced by the orchestrator; do not execute directly.

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}--- $1 ---${NC}\n"; }
info()   { echo -e "  ${GREEN}+${NC} $1"; }
warn()   { echo -e "  ${YELLOW}>${NC} $1"; }
err()    { echo -e "  ${RED}!${NC} $1" >&2; }

# ── Global State ────────────────────────────────────────────────────────────
# These are set by the orchestrator before sourcing scan modules.
# SCRIPT_FILE  — path to the generated install script
# CONFIGS_DIR  — path to migration-configs/ directory
# SECRETS_TEMP — path to temp file collecting secrets
# SELECTIVE_ZSHRC — true/false
# DRY_RUN      — true/false

SECRET_REF=0
SECRET_PATTERN='TOKEN|KEY|SECRET|PASSWORD|PASS|API_KEY|CREDENTIAL|AUTH'

# ── Section Flags ───────────────────────────────────────────────────────────
# Populated by parse_args. ONLY_SECTIONS is an array (empty = all enabled).
# SKIP_SECTIONS tracks skipped sections as a space-delimited string (bash 3.2 compatible).
declare -a ONLY_SECTIONS=()
SKIP_SECTIONS=""

VALID_SECTIONS="brew apps shell claude cursor xcode git ssh infra repos macos version-managers tools"

validate_section_name() {
  local name="$1"
  local valid
  for valid in $VALID_SECTIONS; do
    [[ "$valid" == "$name" ]] && return 0
  done
  err "Unknown section: $name"
  err "Valid sections: $VALID_SECTIONS"
  exit 1
}

section_enabled() {
  local name="$1"
  if [[ ${#ONLY_SECTIONS[@]} -gt 0 ]]; then
    local s
    for s in "${ONLY_SECTIONS[@]}"; do
      [[ "$s" == "$name" ]] && return 0
    done
    return 1
  fi
  [[ " $SKIP_SECTIONS " != *" $name "* ]]
}

# ── Argument Parsing ────────────────────────────────────────────────────────
parse_args() {
  OUT_DIR="$HOME/Desktop/new-mac-setup"
  SELECTIVE_ZSHRC=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        OUT_DIR="$2"; shift 2 ;;
      --skip-brew|--skip-apps|--skip-shell|--skip-claude|--skip-cursor|\
      --skip-xcode|--skip-git|--skip-ssh|--skip-infra|--skip-repos|\
      --skip-macos|--skip-version-managers|--skip-tools)
        local section_name="${1#--skip-}"
        validate_section_name "$section_name"
        if [[ ${#ONLY_SECTIONS[@]} -gt 0 ]]; then
          err "--only and --skip-* are mutually exclusive"
          exit 1
        fi
        SKIP_SECTIONS="$SKIP_SECTIONS $section_name"
        shift ;;
      --only)
        if [[ -n "$SKIP_SECTIONS" ]]; then
          err "--only and --skip-* are mutually exclusive"
          exit 1
        fi
        IFS=',' read -ra ONLY_SECTIONS <<< "$2"
        local s
        for s in "${ONLY_SECTIONS[@]}"; do
          validate_section_name "$s"
        done
        shift 2 ;;
      --selective-zshrc)
        SELECTIVE_ZSHRC=true; shift ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      -h|--help)
        echo "Usage: generate-setup.sh [OPTIONS]"
        echo ""
        echo "Output:"
        echo "  --output DIR              Output directory (default: ~/Desktop/new-mac-setup/)"
        echo ""
        echo "Section control:"
        echo "  --skip-brew               Skip Homebrew scanning"
        echo "  --skip-apps               Skip /Applications/ discovery"
        echo "  --skip-shell              Skip shell config scanning"
        echo "  --skip-claude             Skip Claude Code config"
        echo "  --skip-cursor             Skip Cursor config"
        echo "  --skip-xcode              Skip Xcode config"
        echo "  --skip-ssh                Skip SSH keys/config"
        echo "  --skip-git                Skip git config"
        echo "  --skip-infra              Skip infrastructure (AWS, ArgoCD, Opal, GH CLI, keychain)"
        echo "  --skip-repos              Skip git repo discovery"
        echo "  --skip-macos              Skip macOS preferences"
        echo "  --skip-version-managers   Skip version managers"
        echo "  --skip-tools              Skip manifest-driven tools"
        echo "  --only SECTIONS           Comma-separated sections to include (inverse of --skip)"
        echo "                            Valid: $VALID_SECTIONS"
        echo ""
        echo "Shell options:"
        echo "  --selective-zshrc         Per-line zshrc prompts instead of full replacement"
        echo ""
        echo "Other:"
        echo "  --dry-run                 Preview what would be scanned"
        echo "  -h, --help                Show help"
        exit 0 ;;
      *)
        err "Unknown option: $1"
        exit 1 ;;
    esac
  done

  # Also reject --skip after --only was already set (order-independent)
  if [[ ${#ONLY_SECTIONS[@]} -gt 0 && -n "$SKIP_SECTIONS" ]]; then
    err "--only and --skip-* are mutually exclusive"
    exit 1
  fi
}

# ── Output Directory Setup ──────────────────────────────────────────────────
setup_output_dirs() {
  CONFIGS_DIR="$OUT_DIR/migration-configs"
  SCRIPT_FILE="$OUT_DIR/setup-new-mac.sh"
  SECRETS_FILE="$HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"
  SECRETS_TEMP=$(mktemp)

  if [[ "$DRY_RUN" == true ]]; then
    banner "DRY RUN — scanning only, no files will be written"
    return
  fi

  mkdir -p "$CONFIGS_DIR"
}

# ── Cleanup Trap ────────────────────────────────────────────────────────────
setup_cleanup_trap() {
  trap '_cleanup' EXIT
}

_cleanup() {
  rm -f "${SECRETS_TEMP:-}"
  rm -rf "${BREW_CACHE_DIR:-}" "${MAS_CACHE_DIR:-}"
}

# ── Secret Handling ─────────────────────────────────────────────────────────
add_secret() {
  local name="$1" location="$2" value="$3" note="${4:-}"
  SECRET_REF=$((SECRET_REF + 1))
  {
    echo "### Ref $SECRET_REF: $name"
    echo "- **Location**: \`$location\`"
    [[ -n "$note" ]] && echo "- **Note**: $note"
    echo '- **Value**:'
    echo '```'
    echo "$value"
    echo '```'
    echo ""
  } >> "$SECRETS_TEMP"
}

detect_secret_env_name() {
  local varname="$1"
  echo "$varname" | grep -qiE "$SECRET_PATTERN"
}

# Redact secret exports in a shell file. Outputs redacted content on stdout.
# Also replaces $HOME with $HOME literal (for shell files that use $HOME natively).
redact_shell_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  local content
  content=$(cat "$file")

  # Collect secret var names
  local secret_vars=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      local varname="${BASH_REMATCH[1]}"
      if detect_secret_env_name "$varname"; then
        secret_vars+=("$varname")
        # Extract value for the secrets file
        local value
        value=$(echo "$line" | sed -E 's/^export [A-Za-z_][A-Za-z0-9_]*="?([^"]*)"?\s*$/\1/' | sed 's/^"//' | sed 's/"$//')
        if [[ -n "$value" ]] && ! echo "$value" | grep -q '^\$(' ; then
          add_secret "$varname" "$file" "$value"
        fi
      fi
    fi
  done < "$file"

  # Redact each secret var's value to CHANGEME
  for varname in ${secret_vars[@]+"${secret_vars[@]}"}; do
    content=$(printf '%s' "$content" | sed -E "s|(export ${varname}=)\"[^\"]*\"|\1\"CHANGEME\"|g")
    content=$(printf '%s' "$content" | sed -E "s|(export ${varname}=)([^\"][^ ]*)([ \t]*)$|\1CHANGEME\3|g")
  done

  # Replace absolute home path with $HOME
  content=$(printf '%s' "$content" | sed "s|$HOME|\$HOME|g")
  printf '%s' "$content"
}

# Redact secret env values in a JSON string. Outputs redacted JSON on stdout.
redact_json_secrets() {
  local json="$1"
  echo "$json" | jq -c 'if .env then .env |= with_entries(
    if (.key | test("TOKEN|KEY|SECRET|PASSWORD|PASS|API_KEY|CREDENTIAL|AUTH"; "i"))
    then .value = "CHANGEME" else . end
  ) else . end'
}

# Replace $HOME with @@HOME@@ in a string (for non-shell config files).
rewrite_home_paths() {
  local content="$1"
  printf '%s' "$content" | sed "s|$HOME|@@HOME@@|g"
}

# ── Emit Helpers (write to $SCRIPT_FILE) ────────────────────────────────────
emit_section_header() {
  local label="$1"
  {
    echo ""
    echo "echo \"=== $label ===\""
    echo 'echo ""'
  } >> "$SCRIPT_FILE"
}

emit_brew_cask() {
  local label="$1" cask="$2" check_path="$3"
  cat >> "$SCRIPT_FILE" << EMITEOF
if [[ -e "$check_path" ]]; then
  skip "$label (already installed)"
elif prompt_yn "$label (brew install --cask $cask)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install: brew install --cask $cask"
  elif command -v brew &>/dev/null; then
    brew install --cask "$cask" && success "$label" || fail "$label"
  else
    fail "Homebrew not found — install brew first, then: brew install --cask $cask"
  fi
else
  skip "$label"
fi
echo ""

EMITEOF
}

emit_brew_formula() {
  local label="$1" formula="$2" check_path="$3"
  cat >> "$SCRIPT_FILE" << EMITEOF
if command -v $formula &>/dev/null || [[ -n "$check_path" && -e "$check_path" ]]; then
  skip "$label (already installed)"
elif prompt_yn "$label (brew install $formula)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install: brew install $formula"
  elif command -v brew &>/dev/null; then
    brew install $formula && success "$label" || fail "$label"
  else
    fail "Homebrew not found — install brew first, then: brew install $formula"
  fi
else
  skip "$label"
fi
echo ""

EMITEOF
}

emit_install_cmd() {
  local label="$1" cmd="$2" check_path="$3"
  cat >> "$SCRIPT_FILE" << EMITEOF
if [[ -e "$check_path" ]]; then
  skip "$label (already installed)"
elif prompt_yn "$label"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install $label"
  else
    _tmpfile=\$(mktemp)
    $cmd
    rm -f "\$_tmpfile"
    success "$label"
  fi
else
  skip "$label"
fi
echo ""

EMITEOF
}

emit_install_hint() {
  local label="$1" hint="$2" check_path="$3"
  cat >> "$SCRIPT_FILE" << EMITEOF
if [[ ! -e "$check_path" ]]; then
  echo -e "  \${YELLOW}$label not found — $hint\${NC}"
  echo ""
fi

EMITEOF
}

# ── Manifest Command Validation ─────────────────────────────────────────────
validate_manifest_cmd() {
  local cmd="$1"
  if ! printf '%s' "$cmd" | grep -qE '^[a-zA-Z0-9_./:=~#() |&>"\047{}\$\-]+$'; then
    warn "Manifest command contains unusual characters (review before running): $cmd"
    return 0  # warn but don't block — the command may be intentional
  fi
}
