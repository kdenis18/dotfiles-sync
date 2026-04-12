# Modular Generator Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge generate-install.sh and generate-setup.sh into a single modular generator with per-section skip/only flags, selective zshrc mode, security hardening, and a test harness.

**Architecture:** An orchestrator (`generate-setup.sh`) sources shared helpers from `lib/common.sh` and calls per-section scan modules (`lib/scan-*.sh`). Each module appends to shared output files (`$SCRIPT_FILE`, `$CONFIGS_DIR`, `$SECRETS_TEMP`). The generated install script is a monolithic bash file that runs on the target Mac. Tests validate the generator via ShellCheck, syntax checks, golden files, and secret leak detection.

**Tech Stack:** Bash 5+, jq, ShellCheck, macOS defaults/security CLI tools.

**Spec:** `docs/superpowers/specs/2026-04-12-modular-generator-merge-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|----------------|
| `lib/common.sh` | Colors, output helpers, secret detection/redaction, `@@HOME@@` rewriting, emit helpers, section flag checking, cleanup trap |
| `lib/emit-preamble.sh` | Writes install script header: arg parsing, helper functions, sudo keepalive, version stamp |
| `lib/emit-secrets.sh` | Generates `SECRETS_FOR_PASSWORD_MANAGER.md` from `$SECRETS_TEMP` |
| `lib/emit-footer.sh` | Writes summary tally and secret injection phase to install script |
| `lib/scan-brew.sh` | Scans Homebrew taps, formulae, casks |
| `lib/scan-shell.sh` | Scans .zshrc/.zprofile/.zshenv/.bash_profile; two modes (full replacement, selective) |
| `lib/scan-apps.sh` | Scans /Applications/, resolves to cask/mas/manual with progress counter |
| `lib/scan-claude.sh` | Scans MCPs, plugins, settings, CLAUDE.md, hooks |
| `lib/scan-cursor.sh` | Scans Cursor settings, keybindings, MCP, rules |
| `lib/scan-xcode.sh` | Scans Xcode themes, snippets, keybindings |
| `lib/scan-git.sh` | Scans .gitconfig, .gitignore_global |
| `lib/scan-ssh.sh` | Scans SSH keys and config |
| `lib/scan-infra.sh` | Scans AWS, ArgoCD, Opal, GH CLI, keychain |
| `lib/scan-repos.sh` | Scans git repos to clone |
| `lib/scan-version-managers.sh` | Manifest-driven version manager scanning |
| `lib/scan-tools.sh` | Manifest-driven tool config scanning |
| `lib/scan-macos.sh` | Scans macOS preferences |
| `tests/run-tests.sh` | Test runner |
| `tests/test-shellcheck.sh` | ShellCheck validation |
| `tests/test-generator-syntax.sh` | Syntax validation via bash -n |
| `tests/test-golden.sh` | Golden file regression tests |
| `tests/test-no-secrets.sh` | Secret leak detection |
| `tests/fixtures/home/.zshrc` | Fixture: sample zshrc with aliases, exports, secrets, functions |
| `tests/fixtures/home/.zprofile` | Fixture: sample zprofile |
| `tests/fixtures/home/.claude.json` | Fixture: sample MCP config |
| `tests/fixtures/home/.claude/settings.json` | Fixture: sample Claude settings |
| `tests/fixtures/home/.gitconfig` | Fixture: sample gitconfig |

### Modified Files

| File | Changes |
|------|---------|
| `generate-setup.sh` | Complete rewrite: becomes thin orchestrator that sources lib modules |
| `README.md` | Updated usage docs, migration path from generate-install.sh |
| `.gitignore` | Add `new-mac-setup/`, `SECRETS_FOR_PASSWORD_MANAGER.md` |

### Deleted Files

| File | Reason |
|------|--------|
| `generate-install.sh` | Functionality merged into modular generator |

---

## Task 1: Create `lib/common.sh` — Shared Helpers

**Files:**
- Create: `lib/common.sh`

This is the foundation everything else depends on. No tests yet — we test it indirectly via the golden file tests in Task 19.

- [ ] **Step 1: Create lib directory and common.sh with colors and output helpers**

```bash
mkdir -p lib
```

Write `lib/common.sh`:

```bash
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
# SKIP_SECTIONS is an associative array of section_name -> true.
declare -a ONLY_SECTIONS=()
declare -A SKIP_SECTIONS=()

VALID_SECTIONS="brew apps shell claude cursor xcode git ssh infra repos macos version-managers tools"

validate_section_name() {
  local name="$1"
  if ! echo "$VALID_SECTIONS" | grep -qw "$name"; then
    err "Unknown section: $name"
    err "Valid sections: $VALID_SECTIONS"
    exit 1
  fi
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
  [[ "${SKIP_SECTIONS[$name]:-}" != "true" ]]
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
        SKIP_SECTIONS["$section_name"]=true
        shift ;;
      --only)
        if [[ ${#SKIP_SECTIONS[@]} -gt 0 ]]; then
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
  ((SECRET_REF++))
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
# Also replaces $HOME with @@HOME@@.
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
  for varname in "${secret_vars[@]}"; do
    content=$(printf '%s' "$content" | sed -E "s|(export ${varname}=)\"[^\"]*\"|\1\"CHANGEME\"|g")
    content=$(printf '%s' "$content" | sed -E "s|(export ${varname}=)([^\"][^ ]*)([ \t]*)$|\1CHANGEME\3|g")
  done

  # Replace absolute home path with @@HOME@@
  content=$(printf '%s' "$content" | sed "s|$HOME|\$HOME|g")
  printf '%s' "$content"
}

# Redact secret env values in a JSON string. Outputs redacted JSON on stdout.
redact_json_secrets() {
  local json="$1"
  echo "$json" | jq -c 'if .env then .env |= with_entries(
    if (.key | test("TOKEN|KEY|SECRET|PASSWORD|PASS|API"; "i"))
    then .value = "CHANGEME" else . end
  ) else . end'
}

# Replace $HOME with @@HOME@@ in a string
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
  if ! printf '%s' "$cmd" | grep -qE '^[a-zA-Z0-9_./ |&>"\047{}\$\-]+$'; then
    err "Manifest command contains suspicious characters: $cmd"
    return 1
  fi
}
```

- [ ] **Step 2: Verify the file is syntactically valid**

Run: `bash -n lib/common.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "feat: add lib/common.sh with shared helpers for modular generator

Colors, output functions, argument parsing, section flag checking,
secret detection/redaction, emit helpers, and manifest validation."
```

---

## Task 2: Create `lib/emit-preamble.sh` — Install Script Header

**Files:**
- Create: `lib/emit-preamble.sh`

This writes the top of the generated install script — arg parsing, helper functions, sudo keepalive, version stamp. Merges the best of both existing preambles.

- [ ] **Step 1: Write emit-preamble.sh**

```bash
#!/usr/bin/env bash
# lib/emit-preamble.sh — Writes the install script header
# Sourced by generate-setup.sh; do not execute directly.

emit_preamble() {
  local gen_version gen_date gen_host
  gen_version=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  gen_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gen_host=$(hostname -s)

  umask 077

  cat > "$SCRIPT_FILE" << 'PREAMBLE'
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup-new-mac.sh
# Auto-generated migration script
#
# HOW TO TRANSFER:
#  1. Upload the entire new-mac-setup/ folder to Google Drive
#  2. On the new Mac, download it from Drive to ~/Desktop/
#  3. Run:
#       cd ~/Desktop/new-mac-setup
#       chmod +x setup-new-mac.sh
#       ./setup-new-mac.sh
#
#  NOTE: Do NOT upload SECRETS_FOR_PASSWORD_MANAGER.md to Google Drive.
#        Save those to 1Password first, then delete the file.
###############################################################################

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

# ── Sudo Keepalive ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" != true ]]; then
  echo "This script needs your password once to avoid repeated prompts."
  sudo -v
  while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

# ── Colors & Counters ──────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; GRAY='\033[0;90m'; NC='\033[0m'
INSTALLED=0; SKIPPED=0; FAILED=0

banner()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }
success() { echo -e "  ${GREEN}+${NC} $1"; ((INSTALLED++)); }
skip()    { echo -e "  ${YELLOW}>${NC} $1"; ((SKIPPED++)); }
fail()    { echo -e "  ${RED}!${NC} $1"; ((FAILED++)); }
dry()     { echo -e "  ${GRAY}[dry-run]${NC} $1"; ((INSTALLED++)); }

prompt_yn() {
  local msg="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GRAY}[dry-run]${NC} $msg"
    return 0
  fi
  read -rp "  Install $msg? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

append_to_zshrc() {
  local line="$1"
  if ! grep -qF "$line" "$HOME/.zshrc" 2>/dev/null; then
    echo "$line" >> "$HOME/.zshrc"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/migration-configs"

if [[ "$DRY_RUN" != true ]] && [ ! -d "$CONFIGS_DIR" ]; then
  echo -e "${RED}ERROR: migration-configs/ directory not found next to this script.${NC}"
  echo "Expected at: $CONFIGS_DIR"
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${GRAY}=== DRY RUN MODE — no changes will be made ===${NC}"
  echo ""
fi
PREAMBLE

  # Append version stamp (these expand at generation time)
  cat >> "$SCRIPT_FILE" << EOF

# Generated by dotfiles-sync ($gen_version)
# Source machine: $gen_host
# Generated: $gen_date

echo ""
echo "=========================================="
echo "  Migration script from: $gen_host"
echo "  Generated: $(date +%Y-%m-%d)"
echo "  Generator version: $gen_version"
echo "=========================================="
echo ""
EOF
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/emit-preamble.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/emit-preamble.sh
git commit -m "feat: add lib/emit-preamble.sh — generated install script header

Includes sudo keepalive, dry-run support, helper functions, and version stamp."
```

---

## Task 3: Create `lib/emit-secrets.sh` and `lib/emit-footer.sh`

**Files:**
- Create: `lib/emit-secrets.sh`
- Create: `lib/emit-footer.sh`

- [ ] **Step 1: Write emit-secrets.sh**

```bash
#!/usr/bin/env bash
# lib/emit-secrets.sh — Generates SECRETS_FOR_PASSWORD_MANAGER.md
# Sourced by generate-setup.sh; do not execute directly.

emit_secrets() {
  if [[ "$DRY_RUN" == true ]]; then
    info "Would write SECRETS_FOR_PASSWORD_MANAGER.md ($SECRET_REF secrets found)"
    return
  fi

  cat > "$SECRETS_FILE" << 'HEADER'
# Secrets for Password Manager

Save each entry below to your password manager (e.g., 1Password).
The install script will prompt you to paste each one by its **Ref #**.

> **WARNING**: Delete this file after saving to your password manager.
> Do NOT transfer this file to the new computer.

---

HEADER

  cat "$SECRETS_TEMP" >> "$SECRETS_FILE"

  cat >> "$SECRETS_FILE" << 'FOOTER'
---

## Tokens That Auto-Renew (No Action Needed)

These will be re-created by authenticating on the new machine:

- **GitHub CLI** -- Run `gh auth login`
- **Notion OAuth** -- Re-authorize on first use
- **AWS STS tokens** -- Run your normal auth flow (e.g., Opal)
- **ArgoCD JWT** -- Run `argocd login`
- **Vault token** -- Run `vault login`
FOOTER

  chmod 600 "$SECRETS_FILE"
  info "Written to $SECRETS_FILE ($SECRET_REF secrets found)"
}
```

- [ ] **Step 2: Write emit-footer.sh**

```bash
#!/usr/bin/env bash
# lib/emit-footer.sh — Writes summary tally to install script
# Sourced by generate-setup.sh; do not execute directly.

emit_footer() {
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  cat >> "$SCRIPT_FILE" << 'FOOTER'

###############################################################################
# Summary
###############################################################################
banner "Summary"

echo ""
echo "=========================================="
if [[ "$DRY_RUN" == true ]]; then
  echo -e "  ${GRAY}DRY RUN SUMMARY${NC}"
  echo -e "  ${GREEN}Would install:  $INSTALLED${NC}"
  echo -e "  ${YELLOW}Would skip:     $SKIPPED${NC}"
  echo -e "  ${RED}Would fail:     $FAILED${NC}"
  echo ""
  echo "  Run without --dry-run to apply changes."
else
  echo -e "  ${GREEN}Installed: $INSTALLED${NC}"
  echo -e "  ${YELLOW}Skipped:   $SKIPPED${NC}"
  echo -e "  ${RED}Failed:    $FAILED${NC}"
fi
echo "=========================================="
echo ""
if [[ "$DRY_RUN" != true ]]; then
  echo -e "${BOLD}Done! Restart your terminal to pick up shell changes.${NC}"
fi
FOOTER
}
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n lib/emit-secrets.sh && bash -n lib/emit-footer.sh`
Expected: no output, exit 0

- [ ] **Step 4: Commit**

```bash
git add lib/emit-secrets.sh lib/emit-footer.sh
git commit -m "feat: add emit-secrets.sh and emit-footer.sh

Secrets file generation and install script summary tally."
```

---

## Task 4: Create `lib/scan-brew.sh` — Homebrew Scanning

**Files:**
- Create: `lib/scan-brew.sh`

Extracts the Homebrew scanning logic from generate-setup.sh lines 60-76 (generator side) and lines 733-830 (emitted install script).

- [ ] **Step 1: Write scan-brew.sh**

```bash
#!/usr/bin/env bash
# lib/scan-brew.sh — Scans Homebrew taps, formulae, and casks
# Sourced by generate-setup.sh; do not execute directly.

scan_brew() {
  banner "Scanning: Homebrew"

  local brew_taps="" brew_formulae="" brew_casks=""

  if ! command -v brew &>/dev/null; then
    warn "Homebrew not found"
    return
  fi

  brew_taps=$(brew tap 2>/dev/null | sort)
  brew_formulae=$(brew list --formula 2>/dev/null | sort | tr '\n' ' ')
  brew_casks=$(brew list --cask 2>/dev/null | sort | tr '\n' ' ')
  info "Found $(echo "$brew_taps" | wc -l | tr -d ' ') taps"
  info "Found $(echo "$brew_formulae" | wc -w) formulae"
  info "Found $(echo "$brew_casks" | wc -w) casks"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  # ── Phase 1: Homebrew in install script ──
  cat >> "$SCRIPT_FILE" << 'BREW_HEADER'

###############################################################################
# PHASE 1: Homebrew
###############################################################################
banner "Phase 1: Homebrew"

if ! command -v brew &>/dev/null; then
  if prompt_yn "Homebrew"; then
    _tmpfile=$(mktemp)
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$_tmpfile"
    /bin/bash "$_tmpfile"
    rm -f "$_tmpfile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    success "Homebrew"
  else
    skip "Homebrew"
  fi
else
  skip "Homebrew (already installed)"
fi
BREW_HEADER

  # Taps
  if [[ -n "$brew_taps" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Taps" >> "$SCRIPT_FILE"
    echo "TAPS=(" >> "$SCRIPT_FILE"
    while IFS= read -r tap; do
      [[ -n "$tap" ]] && echo "  \"$tap\"" >> "$SCRIPT_FILE"
    done <<< "$brew_taps"
    cat >> "$SCRIPT_FILE" << 'TAPS_LOOP'
)
for tap in "${TAPS[@]}"; do
  if brew tap 2>/dev/null | grep -q "^${tap}$"; then
    skip "tap $tap (already tapped)"
  elif prompt_yn "brew tap $tap"; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would tap $tap"
    else
      brew tap "$tap" && success "tap $tap" || fail "tap $tap"
    fi
  else
    skip "tap $tap"
  fi
done
TAPS_LOOP
  fi

  # Formulae
  if [[ -n "$brew_formulae" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Formulae" >> "$SCRIPT_FILE"
    echo -n "FORMULAE=(" >> "$SCRIPT_FILE"
    echo "$brew_formulae" | fold -s -w 78 | while IFS= read -r line; do
      echo "" >> "$SCRIPT_FILE"
      echo -n "  $line" >> "$SCRIPT_FILE"
    done
    echo "" >> "$SCRIPT_FILE"
    local formula_count
    formula_count=$(echo "$brew_formulae" | wc -w | tr -d ' ')
    cat >> "$SCRIPT_FILE" << FORMULAE_LOOP
)

if prompt_yn "all Homebrew formulae ($formula_count packages)"; then
  for formula in "\${FORMULAE[@]}"; do
    if brew list --formula 2>/dev/null | grep -q "^\${formula}\$"; then
      skip "\$formula (already installed)"
    elif [[ "\$DRY_RUN" == true ]]; then
      dry "Would install \$formula"
    else
      brew install "\$formula" 2>/dev/null && success "\$formula" || fail "\$formula"
    fi
  done
else
  skip "Homebrew formulae"
fi
FORMULAE_LOOP
  fi

  # Casks
  if [[ -n "$brew_casks" ]]; then
    echo "" >> "$SCRIPT_FILE"
    echo "# Casks (from brew list)" >> "$SCRIPT_FILE"
    echo -n "DEV_CASKS=(" >> "$SCRIPT_FILE"
    echo "$brew_casks" | fold -s -w 78 | while IFS= read -r line; do
      echo "" >> "$SCRIPT_FILE"
      echo -n "  $line" >> "$SCRIPT_FILE"
    done
    echo "" >> "$SCRIPT_FILE"
    local cask_count
    cask_count=$(echo "$brew_casks" | wc -w | tr -d ' ')
    cat >> "$SCRIPT_FILE" << CASKS_LOOP
)

if prompt_yn "Homebrew casks ($cask_count packages)"; then
  for cask in "\${DEV_CASKS[@]}"; do
    if brew list --cask 2>/dev/null | grep -q "^\${cask}\$"; then
      skip "\$cask (already installed)"
    elif [[ "\$DRY_RUN" == true ]]; then
      dry "Would install cask \$cask"
    else
      brew install --cask "\$cask" 2>/dev/null && success "cask \$cask" || fail "cask \$cask"
    fi
  done
else
  skip "Homebrew casks"
fi
CASKS_LOOP
  fi
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/scan-brew.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/scan-brew.sh
git commit -m "feat: add lib/scan-brew.sh — Homebrew taps, formulae, casks

Extracted from generate-setup.sh. Downloads installer to temp file
instead of piping curl to bash."
```

---

## Task 5: Create `lib/scan-shell.sh` — Shell Config (Both Modes)

**Files:**
- Create: `lib/scan-shell.sh`

This is the most complex module — supports both full replacement and selective modes with colored diffs.

- [ ] **Step 1: Write scan-shell.sh**

```bash
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
    display=$(printf '%s' "$line" | sed 's/"/\\"/g')

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
_existing=\$(grep "^${match_pattern}" "\$HOME/.zshrc" 2>/dev/null | head -1)
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

    ((zsh_items++))
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
      in_func=true
      func_name="${BASH_REMATCH[1]}"
      func_body="$line"
    elif [[ "$in_func" == true ]]; then
      func_body="$func_body
$line"
      if [[ "$line" == "}" ]]; then
        in_func=false
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
        ((zsh_items++))
        func_body=""
        func_name=""
      fi
    fi
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
read -rsp "  Value (hidden): " _val
echo
if [[ -n "\$_val" ]]; then
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/scan-shell.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/scan-shell.sh
git commit -m "feat: add lib/scan-shell.sh — full replacement and selective zshrc modes

Supports colored diffs for changed lines, secret redaction with
parameter expansion injection, and per-line idempotency guards."
```

---

## Task 6: Create `lib/scan-apps.sh` — Application Discovery

**Files:**
- Create: `lib/scan-apps.sh`

Extracted from generate-setup.sh lines 446-611. Includes the progress counter improvement.

- [ ] **Step 1: Write scan-apps.sh**

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/scan-apps.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/scan-apps.sh
git commit -m "feat: add lib/scan-apps.sh — /Applications/ discovery with progress counter

Resolves apps to brew cask, Mac App Store, or manual install.
Shows [N/M] progress during brew cask lookups."
```

---

## Task 7: Create `lib/scan-claude.sh` — Claude Code Config

**Files:**
- Create: `lib/scan-claude.sh`

Merges MCP scanning from generate-install.sh (lines 233-375) with Claude settings/CLAUDE.md/hooks from generate-setup.sh (lines 220-285).

- [ ] **Step 1: Write scan-claude.sh**

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/scan-claude.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/scan-claude.sh
git commit -m "feat: add lib/scan-claude.sh — MCPs, plugins, settings, CLAUDE.md, hooks

Merges MCP scanning from generate-install.sh with Claude config
scanning from generate-setup.sh. Redacts secrets before embedding."
```

---

## Task 8: Create `lib/scan-cursor.sh` — Cursor Config

**Files:**
- Create: `lib/scan-cursor.sh`

Extracted from generate-setup.sh lines 288-348 (scanning) and 1140-1211 (emitting).

- [ ] **Step 1: Write scan-cursor.sh**

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/scan-cursor.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add lib/scan-cursor.sh
git commit -m "feat: add lib/scan-cursor.sh — settings, keybindings, MCP, rules

Redacts MCP secrets before embedding. Copies rule files to migration-configs."
```

---

## Task 9: Create remaining scan modules

**Files:**
- Create: `lib/scan-xcode.sh`
- Create: `lib/scan-git.sh`
- Create: `lib/scan-ssh.sh`
- Create: `lib/scan-infra.sh`
- Create: `lib/scan-repos.sh`
- Create: `lib/scan-version-managers.sh`
- Create: `lib/scan-tools.sh`
- Create: `lib/scan-macos.sh`

These are all straightforward extractions from generate-setup.sh and generate-install.sh. I'll list each one with its source and key logic.

- [ ] **Step 1: Write lib/scan-xcode.sh**

Extract from generate-setup.sh lines 350-388 (scanning) and 1213-1265 (emitting). Scans `~/Library/Developer/Xcode/UserData/` for FontAndColorThemes, CodeSnippets, KeyBindings. Copies files to `$CONFIGS_DIR/xcode-themes/`, `xcode-snippets/`, `xcode-keybindings/`. Emits `cp` commands in install script behind `prompt_yn`.

```bash
#!/usr/bin/env bash
# lib/scan-xcode.sh — Scans Xcode themes, snippets, keybindings
# Sourced by generate-setup.sh; do not execute directly.

scan_xcode() {
  banner "Scanning: Xcode"

  local XCODE_USERDATA="$HOME/Library/Developer/Xcode/UserData"
  local XCODE_THEMES=() XCODE_SNIPPETS=()
  local XCODE_KEYBINDINGS=""

  if [[ -d "$XCODE_USERDATA/FontAndColorThemes" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-themes"
    for theme in "$XCODE_USERDATA/FontAndColorThemes"/*.xccolortheme; do
      [[ -f "$theme" ]] || continue
      cp "$theme" "$CONFIGS_DIR/xcode-themes/"
      XCODE_THEMES+=("$(basename "$theme")")
    done
    info "Found ${#XCODE_THEMES[@]} Xcode themes"
  fi

  if [[ -d "$XCODE_USERDATA/CodeSnippets" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-snippets"
    for snippet in "$XCODE_USERDATA/CodeSnippets"/*.codesnippet; do
      [[ -f "$snippet" ]] || continue
      cp "$snippet" "$CONFIGS_DIR/xcode-snippets/"
      XCODE_SNIPPETS+=("$(basename "$snippet")")
    done
    info "Found ${#XCODE_SNIPPETS[@]} Xcode snippets"
  fi

  if [[ -d "$XCODE_USERDATA/KeyBindings" ]]; then
    mkdir -p "$CONFIGS_DIR/xcode-keybindings"
    for kb in "$XCODE_USERDATA/KeyBindings"/*.idekeybindings; do
      [[ -f "$kb" ]] || continue
      cp "$kb" "$CONFIGS_DIR/xcode-keybindings/"
      XCODE_KEYBINDINGS="yes"
    done
    [[ -n "$XCODE_KEYBINDINGS" ]] && info "Found Xcode keybindings"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ ${#XCODE_THEMES[@]} -eq 0 && ${#XCODE_SNIPPETS[@]} -eq 0 && -z "$XCODE_KEYBINDINGS" ]] && return

  cat >> "$SCRIPT_FILE" << 'XCODE_HEADER'

###############################################################################
# Xcode Configuration
###############################################################################
banner "Xcode Configuration"

XCODE_USERDATA="$HOME/Library/Developer/Xcode/UserData"
XCODE_HEADER

  if [[ ${#XCODE_THEMES[@]} -gt 0 ]]; then
    local theme_count=${#XCODE_THEMES[@]}
    cat >> "$SCRIPT_FILE" << XCODETHEMES_BLOCK

if prompt_yn "Xcode color themes ($theme_count themes)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would copy $theme_count Xcode themes"
  else
    mkdir -p "\$XCODE_USERDATA/FontAndColorThemes"
    cp "\$CONFIGS_DIR/xcode-themes/"*.xccolortheme "\$XCODE_USERDATA/FontAndColorThemes/" 2>/dev/null
    success "Xcode color themes"
  fi
else
  skip "Xcode color themes"
fi
XCODETHEMES_BLOCK
  fi

  if [[ -n "$XCODE_KEYBINDINGS" ]]; then
    cat >> "$SCRIPT_FILE" << 'XCODEKB_BLOCK'

if prompt_yn "Xcode keybindings"; then
  if [[ "$DRY_RUN" == true ]]; then
    dry "Would copy Xcode keybindings"
  else
    mkdir -p "$XCODE_USERDATA/KeyBindings"
    cp "$CONFIGS_DIR/xcode-keybindings/"*.idekeybindings "$XCODE_USERDATA/KeyBindings/" 2>/dev/null
    success "Xcode keybindings"
  fi
else
  skip "Xcode keybindings"
fi
XCODEKB_BLOCK
  fi

  if [[ ${#XCODE_SNIPPETS[@]} -gt 0 ]]; then
    local snippet_count=${#XCODE_SNIPPETS[@]}
    cat >> "$SCRIPT_FILE" << XCODESNIPPETS_BLOCK

if prompt_yn "Xcode code snippets ($snippet_count snippets)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would copy $snippet_count Xcode snippets"
  else
    mkdir -p "\$XCODE_USERDATA/CodeSnippets"
    cp "\$CONFIGS_DIR/xcode-snippets/"*.codesnippet "\$XCODE_USERDATA/CodeSnippets/" 2>/dev/null
    success "Xcode code snippets"
  fi
else
  skip "Xcode code snippets"
fi
XCODESNIPPETS_BLOCK
  fi
}
```

- [ ] **Step 2: Write lib/scan-git.sh**

Extract from generate-setup.sh lines 138-153 (scanning) and 934-971 (emitting).

```bash
#!/usr/bin/env bash
# lib/scan-git.sh — Scans .gitconfig and .gitignore_global
# Sourced by generate-setup.sh; do not execute directly.

scan_git() {
  banner "Scanning: Git Configuration"

  local gitconfig_content="" gitignore_content=""

  if [[ -f "$HOME/.gitconfig" ]]; then
    gitconfig_content=$(cat "$HOME/.gitconfig" | sed "s|$HOME|~|g")
    info "Found ~/.gitconfig"
  fi

  if [[ -f "$HOME/.gitignore_global" ]]; then
    gitignore_content=$(cat "$HOME/.gitignore_global")
    info "Found ~/.gitignore_global"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ -z "$gitconfig_content" && -z "$gitignore_content" ]] && return

  cat >> "$SCRIPT_FILE" << 'GIT_HEADER'

###############################################################################
# Git Configuration
###############################################################################
banner "Git Configuration"
GIT_HEADER

  if [[ -n "$gitconfig_content" ]]; then
    cat >> "$SCRIPT_FILE" << GITCONFIG_BLOCK

if prompt_yn "~/.gitconfig"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.gitconfig"
  else
    cat > "\$HOME/.gitconfig" << 'GITCONFIG_EOF'
$gitconfig_content
GITCONFIG_EOF
    success "~/.gitconfig"
  fi
else
  skip "~/.gitconfig"
fi
GITCONFIG_BLOCK
  fi

  if [[ -n "$gitignore_content" ]]; then
    cat >> "$SCRIPT_FILE" << GITIGNORE_BLOCK

if prompt_yn "~/.gitignore_global"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would write ~/.gitignore_global"
  else
    cat > "\$HOME/.gitignore_global" << 'GITIGNORE_EOF'
$gitignore_content
GITIGNORE_EOF
    success "~/.gitignore_global"
  fi
else
  skip "~/.gitignore_global"
fi
GITIGNORE_BLOCK
  fi
}
```

- [ ] **Step 3: Write lib/scan-ssh.sh**

Extract from generate-setup.sh lines 155-195 (scanning) and 973-1020 (emitting).

```bash
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
```

- [ ] **Step 4: Write lib/scan-infra.sh**

Extract from generate-setup.sh lines 390-442 (scanning) and 1267-1373 (emitting). Covers AWS, ArgoCD, Opal, GH CLI, keychain.

```bash
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
```

- [ ] **Step 5: Write lib/scan-repos.sh**

Extract from generate-setup.sh lines 614-630 and 1543-1571.

```bash
#!/usr/bin/env bash
# lib/scan-repos.sh — Scans git repos to clone
# Sourced by generate-setup.sh; do not execute directly.

scan_repos() {
  banner "Scanning: Git Repos"

  local REPOS_TO_CLONE=()

  for dir in "$HOME/Hinge"/* "$HOME/workspace"/* "$HOME/Projects"/*; do
    if [[ -d "$dir/.git" ]]; then
      local remote
      remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
      if [[ -n "$remote" ]]; then
        local rel_path="${dir#$HOME/}"
        REPOS_TO_CLONE+=("$remote|~/$rel_path")
        info "Found repo: ~/$rel_path -> $remote"
      fi
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  [[ ${#REPOS_TO_CLONE[@]} -eq 0 ]] && return

  cat >> "$SCRIPT_FILE" << 'REPOS_HEADER'

###############################################################################
# Clone Repos
###############################################################################
banner "Clone Repos"
REPOS_HEADER

  for repo_entry in "${REPOS_TO_CLONE[@]}"; do
    local remote="${repo_entry%%|*}"
    local local_path="${repo_entry##*|}"
    local expanded_path
    expanded_path=$(echo "$local_path" | sed "s|~|\$HOME|")
    cat >> "$SCRIPT_FILE" << REPO_BLOCK

if [[ ! -d "$expanded_path" ]]; then
  if prompt_yn "Clone $local_path"; then
    if [[ "\$DRY_RUN" == true ]]; then
      dry "Would clone $local_path"
    else
      mkdir -p "\$(dirname "$expanded_path")"
      git clone "$remote" "$expanded_path" && success "$local_path" || fail "$local_path"
    fi
  else
    skip "$local_path"
  fi
else
  skip "$local_path (already exists)"
fi
REPO_BLOCK
  done
}
```

- [ ] **Step 6: Write lib/scan-version-managers.sh**

Extract from generate-install.sh lines 629-774. Manifest-driven.

```bash
#!/usr/bin/env bash
# lib/scan-version-managers.sh — Manifest-driven version manager scanning
# Sourced by generate-setup.sh; do not execute directly.

scan_version_managers() {
  banner "Scanning: Version Managers"

  local MANIFEST_FILE="$SCRIPT_DIR/dotfiles-manifest.json"
  local vm_found=false

  if [[ ! -f "$MANIFEST_FILE" ]] || ! command -v jq &>/dev/null; then
    warn "Manifest not found or jq not available"
    return
  fi

  local VM_COUNT
  VM_COUNT=$(jq '.version_managers | length // 0' "$MANIFEST_FILE" 2>/dev/null || echo 0)

  if [[ "$DRY_RUN" != true ]]; then
    emit_section_header "Version Managers"
  fi

  for vi in $(seq 0 $((VM_COUNT - 1))); do
    local vm_name vm_label vm_check_cmd vm_check_dir vm_brew_formula vm_install_cmd
    local vm_install_cmd_fallback vm_install_msg vm_tv_file vm_tv_pattern
    local vm_managed_lang vm_version_file vm_version_cmd vm_requires_check
    local vm_pre_use_cmd vm_check_version_cmd vm_install_version_cmd vm_install_version_msg

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

    # Validate manifest commands
    [[ -n "$vm_install_cmd" ]] && validate_manifest_cmd "$vm_install_cmd"
    [[ -n "$vm_install_version_cmd" ]] && validate_manifest_cmd "$vm_install_version_cmd"

    # Detect on source machine
    local vm_check_dir_expanded="${vm_check_dir/\$HOME/$HOME}"
    local is_present=false
    if [[ -n "$vm_check_cmd" ]] && command -v "$vm_check_cmd" &>/dev/null; then
      is_present=true
    elif [[ -n "$vm_check_dir" && -d "$vm_check_dir_expanded" ]]; then
      is_present=true
    fi
    [[ "$is_present" == true ]] || continue
    vm_found=true

    # Get tool version
    local tool_version=""
    if [[ -n "$vm_check_cmd" ]]; then
      tool_version=$("$vm_check_cmd" --version 2>/dev/null | awk '{print $2}' || echo "")
    fi
    if [[ -z "$tool_version" && -n "$vm_tv_file" && -n "$vm_tv_pattern" ]]; then
      local vm_tv_file_expanded="${vm_tv_file/\$HOME/$HOME}"
      tool_version=$(grep "$vm_tv_pattern" "$vm_tv_file_expanded" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    fi

    info "Found: $vm_label $tool_version"

    if [[ "$DRY_RUN" == true ]]; then
      continue
    fi

    # ── Emit: install version manager ──
    if [[ -n "$vm_brew_formula" ]]; then
      cat >> "$SCRIPT_FILE" << VMEOF
if command -v $vm_check_cmd &>/dev/null; then
  skip "$vm_label (already installed)"
elif prompt_yn "$vm_label (brew install $vm_brew_formula)"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install $vm_label"
  elif command -v brew &>/dev/null; then
    brew install $vm_brew_formula && success "$vm_label" || fail "$vm_label"
  else
    fail "Homebrew not found — install brew first"
  fi
fi
echo ""

VMEOF
    elif [[ -n "$vm_install_cmd" ]]; then
      local resolved_vm_cmd
      if [[ -n "$tool_version" ]]; then
        resolved_vm_cmd="${vm_install_cmd//\{tool_version\}/$tool_version}"
      elif [[ -n "$vm_install_cmd_fallback" ]]; then
        resolved_vm_cmd="$vm_install_cmd_fallback"
      else
        resolved_vm_cmd="${vm_install_cmd//\{tool_version\}/latest}"
      fi
      local local_install_msg="${vm_install_msg:-Installed}"

      if [[ -n "$vm_check_dir" ]]; then
        cat >> "$SCRIPT_FILE" << VMEOF
if [[ -d "$vm_check_dir" ]]; then
  skip "$vm_label (already installed)"
elif prompt_yn "$vm_label"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would install $vm_label"
  else
    _tmpfile=\$(mktemp)
    curl -fsSL "$(echo "$resolved_vm_cmd" | grep -oE 'https?://[^ ]*' | head -1)" -o "\$_tmpfile"
    bash "\$_tmpfile"
    rm -f "\$_tmpfile"
    success "$local_install_msg"
  fi
fi
echo ""

VMEOF
      fi
    fi

    # ── Emit: install managed language version ──
    local vm_version_file_expanded="${vm_version_file/\$HOME/$HOME}"
    local lang_version=""
    if [[ -n "$vm_version_file" ]]; then
      lang_version=$(cat "$vm_version_file_expanded" 2>/dev/null || echo "")
    fi
    if [[ -z "$lang_version" && -n "$vm_version_cmd" ]]; then
      lang_version=$(bash -c "$vm_version_cmd" 2>/dev/null || echo "")
    fi

    if [[ -n "$lang_version" && -n "$vm_install_version_cmd" ]]; then
      local resolved_install="${vm_install_version_cmd//\{version\}/$lang_version}"
      local resolved_check="${vm_check_version_cmd//\{version\}/$lang_version}"

      local requires_check
      if [[ -n "$vm_requires_check" ]]; then
        requires_check="$vm_requires_check"
      elif [[ -n "$vm_check_cmd" ]]; then
        requires_check="command -v $vm_check_cmd &>/dev/null"
      fi

      {
        echo "if $requires_check; then"
        [[ -n "$vm_pre_use_cmd" ]] && echo "  $vm_pre_use_cmd"
        echo "  if $resolved_check; then"
        echo "    skip \"$vm_managed_lang $lang_version (already installed via $vm_label)\""
        echo "  elif prompt_yn \"$vm_managed_lang $lang_version via $vm_label\"; then"
        echo '    if [[ "$DRY_RUN" == true ]]; then'
        echo "      dry \"Would install $vm_managed_lang $lang_version\""
        echo "    else"
        echo "      $resolved_install"
        echo "      success \"$vm_install_version_msg\""
        echo "    fi"
        echo "  fi"
        echo "else"
        echo "  skip \"$vm_label not installed — install $vm_label first to set up $vm_managed_lang $lang_version\""
        echo "fi"
        echo 'echo ""'
        echo ""
      } >> "$SCRIPT_FILE"
    fi
  done

  if [[ "$vm_found" == false && "$DRY_RUN" != true ]]; then
    echo 'echo "  No version managers found."' >> "$SCRIPT_FILE"
    echo 'echo ""' >> "$SCRIPT_FILE"
  fi
}
```

- [ ] **Step 7: Write lib/scan-tools.sh**

Extract from generate-install.sh lines 781-874. Manifest-driven tool configs.

```bash
#!/usr/bin/env bash
# lib/scan-tools.sh — Manifest-driven tool config scanning
# Sourced by generate-setup.sh; do not execute directly.

scan_tools() {
  banner "Scanning: Tools (manifest)"

  local MANIFEST_FILE="$SCRIPT_DIR/dotfiles-manifest.json"

  if [[ ! -f "$MANIFEST_FILE" ]] || ! command -v jq &>/dev/null; then
    warn "Manifest not found or jq not available"
    return
  fi

  local TOOL_COUNT
  TOOL_COUNT=$(jq '.tools | length' "$MANIFEST_FILE")

  for i in $(seq 0 $((TOOL_COUNT - 1))); do
    local tool_name tool_label check_path install_cmd install_hint
    local brew_formula brew_cask prefs_plist

    tool_name=$(jq -r ".tools[$i].name" "$MANIFEST_FILE")
    tool_label=$(jq -r ".tools[$i].label // .tools[$i].name" "$MANIFEST_FILE")
    check_path=$(jq -r ".tools[$i].check_path // empty" "$MANIFEST_FILE")
    install_cmd=$(jq -r ".tools[$i].install_cmd // empty" "$MANIFEST_FILE")
    install_hint=$(jq -r ".tools[$i].install_hint // empty" "$MANIFEST_FILE")
    brew_formula=$(jq -r ".tools[$i].brew_formula // empty" "$MANIFEST_FILE")
    brew_cask=$(jq -r ".tools[$i].brew_cask // empty" "$MANIFEST_FILE")
    prefs_plist=$(jq -r ".tools[$i].prefs_plist // empty" "$MANIFEST_FILE")

    local check_path_expanded="${check_path/\$HOME/$HOME}"

    info "Found: $tool_label"

    if [[ "$DRY_RUN" == true ]]; then
      continue
    fi

    emit_section_header "$tool_label"

    # App install step
    if [[ -n "$install_cmd" ]]; then
      [[ -n "$install_cmd" ]] && validate_manifest_cmd "$install_cmd"
      emit_install_cmd "$tool_label" "$install_cmd" "$check_path"
    elif [[ -n "$brew_cask" ]]; then
      emit_brew_cask "$tool_label" "$brew_cask" "$check_path"
    elif [[ -n "$brew_formula" ]]; then
      emit_brew_formula "$tool_label" "$brew_formula" "$check_path"
    elif [[ -n "$install_hint" ]]; then
      emit_install_hint "$tool_label" "$install_hint" "$check_path"
    fi

    # macOS plist prefs (base64-encoded)
    if [[ -n "$prefs_plist" ]]; then
      local plist_b64
      plist_b64=$(defaults export "$prefs_plist" - 2>/dev/null | base64 | tr -d '\n') || true
      if [[ -n "$plist_b64" ]]; then
        local prefs_marker="PREFS_$(echo "$tool_name" | tr '[:lower:]a-z-' '[:upper:]A-Z_')"
        cat >> "$SCRIPT_FILE" << PREFSEOF
if prompt_yn "Import $tool_label preferences"; then
  if [[ -n "$check_path" && ! -e "$check_path" ]]; then
    skip "$tool_label not installed — skipping prefs"
  elif [[ "\$DRY_RUN" == true ]]; then
    dry "Would import $tool_label preferences"
  else
    base64 -d << '$prefs_marker' | defaults import $prefs_plist - && \
      success "Imported $tool_label prefs (restart $tool_label to apply)" || \
      fail "Import failed"
$plist_b64
$prefs_marker
  fi
fi
echo ""

PREFSEOF
      fi
    fi

    # Config dirs
    local config_dir_count
    config_dir_count=$(jq ".tools[$i].config_dirs | length // 0" "$MANIFEST_FILE" 2>/dev/null || echo 0)
    for j in $(seq 0 $((config_dir_count - 1))); do
      local src_dir dest_dir
      src_dir=$(jq -r ".tools[$i].config_dirs[$j].src" "$MANIFEST_FILE")
      dest_dir=$(jq -r ".tools[$i].config_dirs[$j].dest" "$MANIFEST_FILE")
      local src_dir_expanded="${src_dir/\$HOME/$HOME}"

      [[ -d "$src_dir_expanded" ]] || continue

      # Build find exclusion args
      local find_args=("$src_dir_expanded" -type f)
      while IFS= read -r excl; do
        find_args+=(! -name "$excl" ! -path "*/$excl/*")
      done < <(jq -r ".tools[$i].config_dirs[$j].exclude[]?" "$MANIFEST_FILE" 2>/dev/null || true)

      while IFS= read -r filepath; do
        local rel_path="${filepath#$src_dir_expanded/}"
        local dest_path="$dest_dir/$rel_path"
        local file_b64
        file_b64=$(base64 < "$filepath" | tr -d '\n')
        local file_marker="FILE_$(echo "$tool_name" | tr '[:lower:]a-z-' '[:upper:]A-Z_')_$(echo "$rel_path" | tr '/.-' '___')"
        cat >> "$SCRIPT_FILE" << FILEEOF
if prompt_yn "Restore $tool_label config: $rel_path"; then
  if [[ "\$DRY_RUN" == true ]]; then
    dry "Would restore $tool_label config: $rel_path"
  else
    mkdir -p "\$(dirname "$dest_path")"
    base64 -d << '$file_marker' > "$dest_path"
$file_b64
$file_marker
    success "Restored $rel_path"
  fi
fi
echo ""

FILEEOF
      done < <(find "${find_args[@]}" 2>/dev/null || true)
    done
  done
}
```

- [ ] **Step 8: Write lib/scan-macos.sh**

Extract from generate-setup.sh lines 1333-1347.

```bash
#!/usr/bin/env bash
# lib/scan-macos.sh — Scans macOS preferences
# Sourced by generate-setup.sh; do not execute directly.

scan_macos() {
  banner "Scanning: macOS Preferences"

  info "Will include common macOS preferences"

  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  cat >> "$SCRIPT_FILE" << 'MACOS_BLOCK'

###############################################################################
# macOS Preferences
###############################################################################
banner "macOS Preferences"

if prompt_yn "Show all file extensions in Finder"; then
  if [[ "$DRY_RUN" == true ]]; then
    dry "Would set AppleShowAllExtensions"
  else
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    success "AppleShowAllExtensions"
  fi
else
  skip "AppleShowAllExtensions"
fi
MACOS_BLOCK
}
```

- [ ] **Step 9: Verify all new files have valid syntax**

Run: `for f in lib/scan-xcode.sh lib/scan-git.sh lib/scan-ssh.sh lib/scan-infra.sh lib/scan-repos.sh lib/scan-version-managers.sh lib/scan-tools.sh lib/scan-macos.sh; do echo -n "$f: "; bash -n "$f" && echo "OK" || echo "FAIL"; done`
Expected: all OK

- [ ] **Step 10: Commit**

```bash
git add lib/scan-xcode.sh lib/scan-git.sh lib/scan-ssh.sh lib/scan-infra.sh \
        lib/scan-repos.sh lib/scan-version-managers.sh lib/scan-tools.sh lib/scan-macos.sh
git commit -m "feat: add remaining scan modules

scan-xcode, scan-git, scan-ssh, scan-infra, scan-repos,
scan-version-managers, scan-tools, scan-macos."
```

---

## Task 10: Rewrite `generate-setup.sh` as Orchestrator

**Files:**
- Modify: `generate-setup.sh` (complete rewrite)

- [ ] **Step 1: Rewrite generate-setup.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# generate-setup.sh
# Scans the current Mac and produces a personalized migration bundle:
#   - setup-new-mac.sh              (interactive install script)
#   - migration-configs/            (binary/large config files)
#   - SECRETS_FOR_PASSWORD_MANAGER.md (secrets — save to 1Password, then delete)
#
# Usage:
#   ./generate-setup.sh [--output DIR] [--only SECTIONS] [--skip-*] [--selective-zshrc]
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/emit-preamble.sh"
source "$SCRIPT_DIR/lib/emit-secrets.sh"
source "$SCRIPT_DIR/lib/emit-footer.sh"
for mod in "$SCRIPT_DIR"/lib/scan-*.sh; do
  source "$mod"
done

# Parse arguments and set up output directories
parse_args "$@"
setup_output_dirs
setup_cleanup_trap

if [[ "$DRY_RUN" == true ]]; then
  banner "DRY RUN — scanning only"
else
  banner "Generating migration bundle"
  echo "  Output: $OUT_DIR"
  echo "  Secrets: $SECRETS_FILE"
  echo ""

  emit_preamble
fi

# Run each enabled section
section_enabled "brew"              && scan_brew
section_enabled "shell"             && scan_shell
section_enabled "apps"              && scan_apps
section_enabled "claude"            && scan_claude
section_enabled "cursor"            && scan_cursor
section_enabled "xcode"             && scan_xcode
section_enabled "git"               && scan_git
section_enabled "ssh"               && scan_ssh
section_enabled "infra"             && scan_infra
section_enabled "repos"             && scan_repos
section_enabled "version-managers"  && scan_version_managers
section_enabled "tools"             && scan_tools
section_enabled "macos"             && scan_macos

if [[ "$DRY_RUN" != true ]]; then
  emit_secrets
  emit_footer
  chmod +x "$SCRIPT_FILE"
fi

# Print summary
banner "Done!"

if [[ "$DRY_RUN" == true ]]; then
  echo -e "  Dry run complete. No files were written."
else
  echo -e "  ${GREEN}Generated files:${NC}"
  echo -e "    ${BOLD}$SCRIPT_FILE${NC} — install script"
  echo -e "    ${BOLD}$CONFIGS_DIR/${NC} — binary config files"
  echo -e "    ${BOLD}$SECRETS_FILE${NC} — secrets ($SECRET_REF found)"
  echo ""
  echo -e "  ${YELLOW}Next steps:${NC}"
  echo -e "    1. Save secrets from $SECRETS_FILE to 1Password"
  echo -e "    2. Delete $SECRETS_FILE"
  echo -e "    3. Upload $OUT_DIR/ to Google Drive"
  echo -e "    4. On the new Mac: download, chmod +x, and run setup-new-mac.sh"
fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n generate-setup.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add generate-setup.sh
git commit -m "feat: rewrite generate-setup.sh as thin orchestrator

Sources lib modules, parses args, calls section_enabled for each
scan module. Supports --skip-*, --only, --selective-zshrc, --dry-run."
```

---

## Task 11: Update `.gitignore` and Delete `generate-install.sh`

**Files:**
- Modify: `.gitignore`
- Delete: `generate-install.sh`

- [ ] **Step 1: Update .gitignore**

```
# Generated install scripts contain secrets — never commit these
install-*.sh
new-mac-setup/
SECRETS_FOR_PASSWORD_MANAGER.md
```

- [ ] **Step 2: Delete generate-install.sh**

Run: `git rm generate-install.sh`

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: delete generate-install.sh, update .gitignore

generate-install.sh functionality is now part of the modular generator.
Added new-mac-setup/ and SECRETS_FOR_PASSWORD_MANAGER.md to .gitignore."
```

---

## Task 12: Create Test Fixtures

**Files:**
- Create: `tests/fixtures/home/.zshrc`
- Create: `tests/fixtures/home/.zprofile`
- Create: `tests/fixtures/home/.claude.json`
- Create: `tests/fixtures/home/.claude/settings.json`
- Create: `tests/fixtures/home/.gitconfig`

- [ ] **Step 1: Create fixture directory structure**

Run: `mkdir -p tests/fixtures/home/.claude tests/fixtures/golden`

- [ ] **Step 2: Write fixture .zshrc**

```bash
# Oh-My-Zsh configuration
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source $ZSH/oh-my-zsh.sh

# Aliases
alias gs='git status'
alias ll='ls -la'

# Exports
export EDITOR=vim
export API_KEY="sk-test-fixture-secret-12345"
export GOPATH="$HOME/go"

# PATH
export PATH="$HOME/.local/bin:$PATH"

# Functions
greet() {
  echo "Hello, $1"
}
```

- [ ] **Step 3: Write fixture .zprofile**

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_NO_ANALYTICS=1
```

- [ ] **Step 4: Write fixture .claude.json**

```json
{
  "mcpServers": {
    "test-mcp": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "test-mcp-server"],
      "env": {
        "TEST_API_KEY": "sk-test-mcp-secret-67890"
      }
    },
    "local-mcp": {
      "type": "stdio",
      "command": "/Users/testuser/.local/bin/mcp-server",
      "args": [],
      "env": {}
    }
  }
}
```

- [ ] **Step 5: Write fixture .claude/settings.json**

```json
{
  "permissions": {
    "allow": ["Read", "Edit"],
    "deny": []
  },
  "hooks": {}
}
```

- [ ] **Step 6: Write fixture .gitconfig**

```ini
[user]
	name = Test User
	email = test@example.com
[core]
	editor = vim
```

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/
git commit -m "feat: add test fixtures for generator validation

Sample .zshrc with secrets, .claude.json with MCP secrets,
.gitconfig, .zprofile, and Claude settings."
```

---

## Task 13: Create Test Harness

**Files:**
- Create: `tests/run-tests.sh`
- Create: `tests/test-shellcheck.sh`
- Create: `tests/test-generator-syntax.sh`
- Create: `tests/test-golden.sh`
- Create: `tests/test-no-secrets.sh`

- [ ] **Step 1: Write tests/run-tests.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
PASSED=0

run_test() {
  local name="$1" script="$2"
  shift 2
  printf "  %-40s " "$name"
  if bash "$script" "$@" > /dev/null 2>&1; then
    echo "PASS"
    ((PASSED++))
  else
    echo "FAIL"
    ((FAILURES++))
    # Re-run with output for debugging
    echo "    --- output ---"
    bash "$script" "$@" 2>&1 | sed 's/^/    /'
    echo "    --- end ---"
  fi
}

echo ""
echo "Running dotfiles-sync tests..."
echo ""

run_test "ShellCheck"         "$TESTS_DIR/test-shellcheck.sh"
run_test "Generator syntax"   "$TESTS_DIR/test-generator-syntax.sh"
run_test "No secret leaks"    "$TESTS_DIR/test-no-secrets.sh"

# Golden tests only if golden files exist
if [[ -f "$TESTS_DIR/fixtures/golden/setup-new-mac.golden.sh" ]]; then
  run_test "Golden files"     "$TESTS_DIR/test-golden.sh" "${1:-}"
else
  echo "  Golden files                           SKIP (run with --update-golden first)"
fi

echo ""
echo "Results: $PASSED passed, $FAILURES failed"
exit $FAILURES
```

- [ ] **Step 2: Write tests/test-shellcheck.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck &>/dev/null; then
  echo "shellcheck not installed — install with: brew install shellcheck"
  exit 1
fi

ERRORS=0

for f in "$REPO_DIR/generate-setup.sh" "$REPO_DIR"/lib/*.sh "$REPO_DIR"/tests/*.sh; do
  [[ -f "$f" ]] || continue
  if ! shellcheck -s bash -e SC1090,SC1091,SC2034 "$f"; then
    ((ERRORS++))
  fi
done

exit $ERRORS
```

- [ ] **Step 3: Write tests/test-generator-syntax.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"' EXIT

# Run generator with fixtures as HOME, skipping sections that need live tools
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,git \
  2>/dev/null || {
    echo "Generator failed to run"
    exit 1
  }

# Check generated script exists
if [[ ! -f "$TEST_OUTPUT/setup-new-mac.sh" ]]; then
  echo "setup-new-mac.sh was not generated"
  exit 1
fi

# Syntax check the generated script
if ! bash -n "$TEST_OUTPUT/setup-new-mac.sh"; then
  echo "Generated script has syntax errors"
  exit 1
fi

echo "Generator syntax: OK"
```

- [ ] **Step 4: Write tests/test-no-secrets.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"' EXIT

# Run generator with fixtures
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,claude,git \
  2>/dev/null || true

SCRIPT="$TEST_OUTPUT/setup-new-mac.sh"
[[ -f "$SCRIPT" ]] || { echo "No script generated"; exit 1; }

LEAKED=0

# Check for known fixture secrets in the install script
for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
  if grep -q "$secret" "$SCRIPT"; then
    echo "LEAKED: $secret found in setup-new-mac.sh"
    ((LEAKED++))
  fi
done

# Check migration-configs too
if [[ -d "$TEST_OUTPUT/migration-configs" ]]; then
  for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
    if grep -rq "$secret" "$TEST_OUTPUT/migration-configs/"; then
      echo "LEAKED: $secret found in migration-configs/"
      ((LEAKED++))
    fi
  done
fi

# Check for common secret prefixes (that shouldn't appear in install scripts)
for prefix in "sk-test-" "ghp_" "gho_" "AKIA" "-----BEGIN.*PRIVATE KEY"; do
  if grep -qE "$prefix" "$SCRIPT"; then
    echo "SUSPICIOUS: pattern '$prefix' found in setup-new-mac.sh"
    ((LEAKED++))
  fi
done

# Verify secrets DO appear in the secrets file
SECRETS_FILE="$FIXTURE_HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"
if [[ -f "$SECRETS_FILE" ]]; then
  for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
    if ! grep -q "$secret" "$SECRETS_FILE"; then
      echo "MISSING: $secret not found in SECRETS_FOR_PASSWORD_MANAGER.md"
      ((LEAKED++))
    fi
  done
fi

if [[ $LEAKED -gt 0 ]]; then
  echo "Secret leak check: FAILED ($LEAKED issues)"
  exit 1
fi

echo "Secret leak check: OK"
```

- [ ] **Step 5: Write tests/test-golden.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
GOLDEN_DIR="$REPO_DIR/tests/fixtures/golden"
GOLDEN_FILE="$GOLDEN_DIR/setup-new-mac.golden.sh"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"' EXIT

# Run generator with fixtures
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,git \
  2>/dev/null || true

SCRIPT="$TEST_OUTPUT/setup-new-mac.sh"
[[ -f "$SCRIPT" ]] || { echo "No script generated"; exit 1; }

# Strip dynamic content (timestamps, hostnames, git SHAs) before comparing
_normalize() {
  sed -E \
    -e 's/Generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]*/Generated: TIMESTAMP/' \
    -e 's/Generated: [0-9]{4}-[0-9]{2}-[0-9]{2}/Generated: DATE/' \
    -e 's/Source machine: [^ ]*/Source machine: HOST/' \
    -e 's/Generator version: [a-f0-9]+/Generator version: SHA/' \
    -e 's/dotfiles-sync \([a-f0-9]+\)/dotfiles-sync (SHA)/' \
    -e 's/Migration script from: [^ ]*/Migration script from: HOST/' \
    "$1"
}

if [[ "${1:-}" == "--update-golden" ]]; then
  mkdir -p "$GOLDEN_DIR"
  _normalize "$SCRIPT" > "$GOLDEN_FILE"
  echo "Golden file updated: $GOLDEN_FILE"
  exit 0
fi

if [[ ! -f "$GOLDEN_FILE" ]]; then
  echo "No golden file found. Run with --update-golden first."
  exit 1
fi

# Compare
ACTUAL=$(mktemp)
_normalize "$SCRIPT" > "$ACTUAL"

if diff -u "$GOLDEN_FILE" "$ACTUAL"; then
  echo "Golden file check: OK"
else
  echo ""
  echo "Golden file check: FAILED"
  echo "Run './tests/run-tests.sh --update-golden' to update"
  rm -f "$ACTUAL"
  exit 1
fi

rm -f "$ACTUAL"
```

- [ ] **Step 6: Verify all test scripts have valid syntax**

Run: `for f in tests/run-tests.sh tests/test-shellcheck.sh tests/test-generator-syntax.sh tests/test-golden.sh tests/test-no-secrets.sh; do echo -n "$f: "; bash -n "$f" && echo "OK" || echo "FAIL"; done`
Expected: all OK

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "feat: add test harness — shellcheck, syntax, golden files, secret leak detection

Four test levels: ShellCheck all .sh files, bash -n on generated output,
golden file regression, and secret leak grep."
```

---

## Task 14: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README with new usage**

Rewrite `README.md` to document:
- The modular architecture
- New CLI flags (`--skip-*`, `--only`, `--selective-zshrc`, `--dry-run`)
- Migration path from `generate-install.sh`
- How to run tests
- How to add new sections

```markdown
# dotfiles-sync

Generate portable migration bundles to sync your dev environment between Macs.

Scans your current machine's config (Homebrew, shell, apps, Claude Code, Cursor, Xcode, SSH, git, infrastructure, version managers, tool configs) and outputs a self-contained migration bundle you can run on another machine.

## Quick Start

```bash
# Generate migration bundle
./generate-setup.sh

# Output: ~/Desktop/new-mac-setup/
#   setup-new-mac.sh              — interactive install script
#   migration-configs/            — binary config files
#   SECRETS_FOR_PASSWORD_MANAGER.md — save to 1Password, then delete

# On the new Mac:
cd ~/Desktop/new-mac-setup
chmod +x setup-new-mac.sh
./setup-new-mac.sh

# Preview without making changes:
./setup-new-mac.sh --dry-run
```

## Generator Options

```
./generate-setup.sh [OPTIONS]

Output:
  --output DIR              Output directory (default: ~/Desktop/new-mac-setup/)

Section control:
  --skip-brew               Skip Homebrew scanning
  --skip-apps               Skip /Applications/ discovery
  --skip-shell              Skip shell config scanning
  --skip-claude             Skip Claude Code config
  --skip-cursor             Skip Cursor config
  --skip-xcode              Skip Xcode config
  --skip-ssh                Skip SSH keys/config
  --skip-git                Skip git config
  --skip-infra              Skip infrastructure (AWS, ArgoCD, Opal, GH CLI, keychain)
  --skip-repos              Skip git repo discovery
  --skip-macos              Skip macOS preferences
  --skip-version-managers   Skip version managers
  --skip-tools              Skip manifest-driven tools
  --only SECTIONS           Comma-separated sections to include (inverse of --skip)

Shell options:
  --selective-zshrc         Per-line zshrc prompts instead of full replacement

Other:
  --dry-run                 Preview what would be scanned
```

### Examples

```bash
# Only generate Claude and shell config (equivalent to old generate-install.sh)
./generate-setup.sh --only claude,shell,version-managers,tools --selective-zshrc

# Skip slow app scanning
./generate-setup.sh --skip-apps

# Preview what would be scanned
./generate-setup.sh --dry-run
```

## What It Captures

| Section | Source | Install Action |
|---------|--------|----------------|
| Homebrew | `brew list`, `brew tap` | Install taps, formulae, casks |
| Shell Config | ~/.zshrc, ~/.zprofile, ~/.zshenv | Full replacement or per-line append |
| Applications | /Applications/ scan | `brew install --cask` or `mas install` |
| Claude Code | MCPs, plugins, settings, CLAUDE.md, hooks | `claude mcp add-json`, file writes |
| Cursor | Settings, keybindings, MCP, rules | File writes |
| Xcode | Themes, snippets, keybindings | Copy to UserData |
| Git | ~/.gitconfig, ~/.gitignore_global | File writes |
| SSH | Keys, config | Paste from password manager |
| Infrastructure | AWS, ArgoCD, Opal, GH CLI, keychain | File writes, keychain entries |
| Git Repos | ~/Hinge/*, ~/workspace/* | `git clone` |
| Version Managers | dotfiles-manifest.json (rbenv, nvm, pyenv) | Install manager + language version |
| Tool Configs | dotfiles-manifest.json (oh-my-zsh, iTerm2, Ghostty) | Install app + restore configs |
| macOS Prefs | Finder settings | `defaults write` |

## Manifest

`dotfiles-manifest.json` drives tool and version manager discovery. See the spec for field documentation.

## Architecture

```
generate-setup.sh          — orchestrator (arg parsing, calls modules)
lib/
  common.sh                — shared helpers, secret handling, emit functions
  emit-preamble.sh         — install script header
  emit-secrets.sh          — SECRETS_FOR_PASSWORD_MANAGER.md
  emit-footer.sh           — install script summary
  scan-*.sh                — one module per section
tests/
  run-tests.sh             — test runner
  test-shellcheck.sh       — lint all bash
  test-generator-syntax.sh — bash -n on generated output
  test-golden.sh           — regression tests
  test-no-secrets.sh       — secret leak detection
```

## Testing

```bash
# Run all tests
./tests/run-tests.sh

# Update golden files after intentional changes
./tests/run-tests.sh --update-golden
```

Requires: `shellcheck` (`brew install shellcheck`)

## Requirements

- macOS with zsh
- `jq` (`brew install jq`)
- `shellcheck` (for tests only)
- `brew` (optional, for Homebrew sync)
- `claude` CLI (for Claude Code operations)

## Migration from generate-install.sh

`generate-install.sh` has been merged into `generate-setup.sh`. Equivalent usage:

```bash
# Old:
generate-install.sh --with-brew

# New:
./generate-setup.sh --only brew,claude,shell,version-managers,tools --selective-zshrc
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for modular generator

New CLI flags, architecture overview, testing, migration path."
```

---

## Task 15: Integration Test — Run the Generator

- [ ] **Step 1: Run the generator in dry-run mode**

Run: `./generate-setup.sh --dry-run --only shell,git`
Expected: Scans shell and git sections, prints what it finds, does not write files.

- [ ] **Step 2: Run the generator for real with limited scope**

Run: `./generate-setup.sh --only shell,git --output /tmp/test-migration`
Expected: Creates `/tmp/test-migration/setup-new-mac.sh` and `/tmp/test-migration/migration-configs/`. No secret values in setup-new-mac.sh.

- [ ] **Step 3: Syntax-check the generated script**

Run: `bash -n /tmp/test-migration/setup-new-mac.sh`
Expected: no output, exit 0

- [ ] **Step 4: Run the test harness**

Run: `./tests/run-tests.sh`
Expected: All tests pass (except golden which needs initial generation).

- [ ] **Step 5: Generate golden files**

Run: `./tests/run-tests.sh --update-golden`
Expected: Golden file created.

- [ ] **Step 6: Run tests again**

Run: `./tests/run-tests.sh`
Expected: All tests pass including golden.

- [ ] **Step 7: Fix any issues found and commit**

```bash
git add -A
git commit -m "fix: integration test fixes

Resolve any issues found during end-to-end generator testing."
```

---

## Task 16: Run Full Generator and Verify

- [ ] **Step 1: Run the generator with all sections**

Run: `./generate-setup.sh --output /tmp/full-migration`
Expected: Completes all phases, generates full migration bundle.

- [ ] **Step 2: Verify no secrets leaked**

Run: `grep -rE 'sk-|ghp_|gho_|AKIA|PRIVATE KEY' /tmp/full-migration/setup-new-mac.sh /tmp/full-migration/migration-configs/ || echo "No leaks found"`
Expected: No leaks found.

- [ ] **Step 3: Verify the selective zshrc mode**

Run: `./generate-setup.sh --output /tmp/selective-test --only shell --selective-zshrc`
Expected: Generated script contains per-line `prompt_yn` blocks instead of `cat > ~/.zshrc`.

- [ ] **Step 4: Clean up and commit test results**

Run: `rm -rf /tmp/test-migration /tmp/full-migration /tmp/selective-test`

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: modular generator merge complete

Merged generate-install.sh and generate-setup.sh into a modular
generator with per-section skip/only flags, selective zshrc mode,
security hardening, and a test harness."
```
