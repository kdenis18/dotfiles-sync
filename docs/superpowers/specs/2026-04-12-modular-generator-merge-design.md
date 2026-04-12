# Modular Generator Merge — Design Spec

**Date:** 2026-04-12
**Status:** Approved
**Author:** Kevin Denis + Claude

## Goal

Merge `generate-install.sh` and `generate-setup.sh` into a single modular generator that produces a Mac migration bundle for Hinge engineers. The merged tool must be production-ready for team-wide onboarding use.

## Context

Two scripts exist today with significant overlap:

- **`generate-install.sh` (~950 lines):** Claude-centric. Covers MCPs, zsh (per-line append), RTK, plugins, settings, manifest-driven version managers and tool configs, optionally brew. Supports `--dry-run`. Single self-contained output script with base64-encoded configs.
- **`generate-setup.sh` (~1600 lines):** Full Mac migration. Covers brew (taps/formulae/casks), apps (cask + mas), shell files (full replacement), git, SSH, AWS, Claude, Cursor, Xcode, infra, keychain, repos, macOS prefs. Outputs a directory bundle with a separate secrets file.

The merged tool takes generate-setup.sh as the superset, backports missing features from generate-install.sh (dry-run, selective zshrc, manifest-driven tools/version managers, `@@HOME@@` rewriting), splits into testable modules, and hardens security.

## Target Users

iOS, Android, and Backend engineers at Hinge. Each engineer runs the generator on their existing Mac, transfers the output bundle to a new Mac, and runs the install script.

## File Structure

```
dotfiles-sync/
  generate-setup.sh                 # Main entry point: arg parsing, orchestration
  dotfiles-manifest.json            # Tool & version manager definitions (existing, extended)
  lib/
    common.sh                       # Shared: colors, emit helpers, secret detection/redaction,
                                    #   @@HOME@@ rewriting, add_secret(), assert_no_secrets()
    emit-preamble.sh                # Writes install script header, helper functions, arg parsing
    emit-secrets.sh                 # Generates SECRETS_FOR_PASSWORD_MANAGER.md from $SECRETS_TEMP
    emit-footer.sh                  # Writes summary tally to install script
    scan-brew.sh                    # Homebrew taps, formulae, casks
    scan-shell.sh                   # .zshrc, .zprofile, .zshenv, .bash_profile
                                    #   Two modes: full replacement (default) or selective
    scan-apps.sh                    # /Applications/ discovery -> cask/mas/manual
                                    #   Includes progress counter
    scan-claude.sh                  # MCPs, plugins, settings, CLAUDE.md, hooks
    scan-cursor.sh                  # Cursor settings, keybindings, MCP, rules
    scan-xcode.sh                   # Themes, snippets, keybindings
    scan-git.sh                     # .gitconfig, .gitignore_global
    scan-ssh.sh                     # SSH keys + config
    scan-infra.sh                   # AWS, ArgoCD, Opal, GH CLI, keychain
    scan-repos.sh                   # Git repos to clone
    scan-version-managers.sh        # Manifest-driven (rbenv, nvm, pyenv)
    scan-tools.sh                   # Manifest-driven (oh-my-zsh, iTerm2, Ghostty)
    scan-macos.sh                   # macOS preferences (Finder settings, etc.)
  tests/
    run-tests.sh                    # Test runner (all tests or --update-golden)
    test-shellcheck.sh              # ShellCheck all .sh files including generated output
    test-generator-syntax.sh        # Generate against fixtures, bash -n the output
    test-golden.sh                  # Diff generated output against committed golden files
    test-no-secrets.sh              # assert_no_secrets() on generated output
    fixtures/                       # Mock $HOME configs for testing
      home/
        .zshrc
        .zprofile
        .claude.json
        .claude/settings.json
        .gitconfig
        ...
      golden/
        setup-new-mac.golden.sh     # Expected output for fixture inputs
  README.md                         # Updated with new usage
```

## CLI Interface

### Generator

```
Usage: generate-setup.sh [OPTIONS]

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
  --only SECTIONS           Comma-separated list of sections to include (inverse of --skip)
                            Valid: brew,apps,shell,claude,cursor,xcode,git,ssh,infra,
                                   repos,macos,version-managers,tools

Shell options:
  --selective-zshrc         Generate per-line zshrc prompts instead of full replacement

Other:
  --dry-run                 Preview what would be scanned without generating output
  -h, --help                Show help
```

`--only` and `--skip-*` are mutually exclusive. If `--only` is provided, all unlisted sections are skipped.

### Generated Install Script

```
Usage: setup-new-mac.sh [OPTIONS]

Options:
  --dry-run     Preview what would be installed without making changes
  -h, --help    Show help
```

The install script's zshrc behavior (full replacement vs. selective) is baked in at generation time based on whether `--selective-zshrc` was passed to the generator.

## Orchestration Flow

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/emit-preamble.sh"
source "$SCRIPT_DIR/lib/emit-secrets.sh"
source "$SCRIPT_DIR/lib/emit-footer.sh"
# Source all scan modules
for mod in "$SCRIPT_DIR"/lib/scan-*.sh; do
  source "$mod"
done

parse_args "$@"
setup_output_dirs
setup_cleanup_trap

emit_preamble

# Each scan function appends to $SCRIPT_FILE, $CONFIGS_DIR, $SECRETS_TEMP
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

emit_secrets
emit_footer

chmod +x "$SCRIPT_FILE"
print_summary
```

`section_enabled()` checks the parsed skip/only flags and returns 0 (enabled) or 1 (disabled).

## Shared Helpers (`lib/common.sh`)

### Colors and Output

```bash
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}--- $1 ---${NC}\n"; }
info()   { echo -e "  ${GREEN}+${NC} $1"; }
warn()   { echo -e "  ${YELLOW}>${NC} $1"; }
err()    { echo -e "  ${RED}!${NC} $1" >&2; }
```

### Secret Detection

```bash
SECRET_PATTERN='TOKEN|KEY|SECRET|PASSWORD|PASS|API_KEY|CREDENTIAL|AUTH'

add_secret() {
  local name="$1" location="$2" value="$3" note="${4:-}"
  ((SECRET_REF++))
  # Append to $SECRETS_TEMP in markdown format
}

detect_secret_env_name() {
  local varname="$1"
  echo "$varname" | grep -qiE "$SECRET_PATTERN"
}

redact_shell_file() {
  local file="$1"
  # Read file, replace secret export values with CHANGEME, replace $HOME
  # Returns redacted content on stdout
}

redact_json_secrets() {
  local json="$1"
  # Uses jq to replace env values matching SECRET_PATTERN with CHANGEME
  # Returns redacted JSON on stdout
}
```

### Emit Helpers

Carried over from generate-install.sh, used by scan modules to write to `$SCRIPT_FILE`:

```bash
emit_section_header()  # echo "=== Label ===" in generated script
emit_brew_cask()       # Idempotent brew cask install block
emit_brew_formula()    # Idempotent brew formula install block
emit_install_cmd()     # Custom install command with check_path guard
emit_install_hint()    # Info-only message when no auto-install method
```

### @@HOME@@ Rewriting

```bash
rewrite_home_paths() {
  local content="$1"
  echo "$content" | sed "s|$HOME|@@HOME@@|g"
}
```

Applied at generation time. The install script preamble includes a one-liner to resolve `@@HOME@@` back to `$HOME` on the target machine.

### Secret Leak Validation

```bash
assert_no_secrets() {
  local file="$1"
  # Grep for high-entropy strings, known key prefixes (sk-, ghp_, AKIA, etc.)
  # Returns 1 if suspicious content found
  # Used by test harness, not by the generator at runtime
}
```

### Cleanup Trap

```bash
setup_cleanup_trap() {
  trap 'rm -f "$SECRETS_TEMP"; rm -rf "${BREW_CACHE_DIR:-}" "${MAS_CACHE_DIR:-}"' EXIT
}
```

## Zsh Handling: Two Modes

### Default Mode (full replacement)

`scan_shell()` reads each shell file, runs `redact_shell_file()`, and emits a `cat > ~/.zshrc` block behind a single `[y/N]` prompt. Other shell files (`.zprofile`, `.zshenv`, `.bash_profile`) are always full-replacement.

A dedicated secret injection phase at the end of the install script prompts for each CHANGEME value and uses parameter expansion (not `sed`) to replace them.

### Selective Mode (`--selective-zshrc`)

`scan_shell()` parses `~/.zshrc` into individual items:

1. **Preamble block** — comments, blank lines, oh-my-zsh config, anything before the first alias/export/function/source. Offered as a single block.
2. **Aliases** — `alias foo='bar'` — each prompted individually
3. **Exports** — `export FOO=bar` — each prompted individually. Secrets get CHANGEME + runtime prompt.
4. **PATH entries** — `export PATH=...` or `path+=...` — each prompted individually
5. **Functions** — `funcname() { ... }` — each prompted as a block
6. **Source lines** — `source ...` — each prompted individually

Each item has an idempotency guard (`grep -qF` before appending).

**Colored diff for changed lines:** When an item already exists in the target `~/.zshrc` but with a different value (e.g. `alias gs='git status'` vs `alias gs='git status --short'`), the install script shows:

```
  alias gs exists but differs:
    - alias gs='git status --short'   (current)
    + alias gs='git status'           (source)
  Replace? [y/N]
```

Implementation: for aliases and exports, extract the variable/alias name, grep for it in `~/.zshrc`. If found but the full line differs, show the diff. For functions, compare by function name.

## Secret Handling

### Hard Rule

**No secret values ever appear in any generated file except `SECRETS_FOR_PASSWORD_MANAGER.md`.**

This applies to:
- `setup-new-mac.sh` — only CHANGEME placeholders
- `migration-configs/*` — all configs scrubbed before copying
- Generator stdout — never prints secret values

### Three Layers

**Layer 1 — Detection** (`common.sh`): `add_secret()` collects secrets into `$SECRETS_TEMP`. Each scan module calls it for secrets it discovers (shell env vars, MCP tokens, SSH keys, AWS creds, ArgoCD tokens, keychain entries).

**Layer 2 — Redaction** (each scan module): Every module runs content through redaction before writing to `$SCRIPT_FILE` or `$CONFIGS_DIR`. Shell files use `redact_shell_file()`. JSON uses `redact_json_secrets()`. Binary configs with embedded secrets must be scrubbed or excluded.

**Layer 3 — Output** (`emit-secrets.sh`): Writes `SECRETS_FOR_PASSWORD_MANAGER.md` from `$SECRETS_TEMP`. The install script's injection phase prompts for each CHANGEME and replaces using parameter expansion.

### Secret Injection in Install Script

```bash
# Phase 14: Inject Secrets
echo -e "Paste the value from your password manager. Press Enter to skip."

echo -e "SOME_API_KEY"
read -rsp "  Value (hidden): " _val
echo
if [ -n "$_val" ]; then
  for _f in "$HOME/.zshrc" "$HOME/.zprofile"; do
    [ -f "$_f" ] && _content=$(cat "$_f") && \
      printf '%s\n' "${_content//export SOME_API_KEY=\"CHANGEME\"/export SOME_API_KEY=\"$_val\"}" > "$_f"
  done
  success "Injected SOME_API_KEY"
fi
```

Uses bash parameter expansion (`${var//pattern/replacement}`) instead of `sed` to avoid injection from values containing `/`, `&`, or other sed metacharacters.

## Security Hardening

### 1. No `curl | bash`

Both scripts currently pipe curl directly to bash for oh-my-zsh, nvm, Homebrew, and rustup. The merged tool downloads to a temp file first:

```bash
# Before (unsafe):
sh -c "$(curl -fsSL https://raw.githubusercontent.com/.../install.sh)"

# After (safe):
_tmpfile=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/.../install.sh -o "$_tmpfile"
echo "  Downloaded installer to $_tmpfile — inspect if desired"
bash "$_tmpfile"
rm -f "$_tmpfile"
```

### 2. No `eval` on Manifest Content

`generate-install.sh:739` uses `eval "$vm_version_cmd"`. Replace with direct command execution. For manifest commands that require shell features (pipes, redirects), use `bash -c "$cmd"` with the command string validated against an allowlist of safe patterns.

Note: manifest commands are embedded verbatim into the generated install script (not executed by the generator at runtime except for source-machine detection). The risk is that a malicious manifest entry could inject arbitrary code into the generated script. Mitigation: validate manifest command strings contain only expected characters (`[a-zA-Z0-9_./ |&>-]`) before embedding.

### 3. Consistent Quoting

All variable expansions in generated heredocs must be quoted. Audit every `$variable` in emitted code for word-splitting risk. Use `printf '%s'` instead of `echo` for user-controlled content.

### 4. Trap-Based Cleanup

```bash
setup_cleanup_trap() {
  trap 'rm -f "$SECRETS_TEMP"; rm -rf "${BREW_CACHE_DIR:-}" "${MAS_CACHE_DIR:-}"' EXIT
}
```

Called at the top of the generator. Ensures temp files containing secret data are always cleaned up.

### 5. No `sed` for Secret Injection

Secret values can contain any characters. `sed` replacement strings treat `/`, `&`, and `\` as special. Use bash parameter expansion instead:

```bash
# Instead of: sed "s|CHANGEME|$secret_value|"
# Use:        ${content//CHANGEME/$secret_value}
```

### 6. Restrictive File Permissions

```bash
umask 077  # At the top of the generator
# Generated files: setup-new-mac.sh (700), SECRETS_FOR_PASSWORD_MANAGER.md (600)
# migration-configs/ (700)
```

## Additional Features

### 1. Progress Counter for App Scanning

```bash
app_count=${#APP_LIST[@]}
app_idx=0
for app_name in "${APP_LIST[@]}"; do
  ((app_idx++))
  printf "\r  Scanning apps... [%d/%d] %s " "$app_idx" "$app_count" "$app_name"
  # ... lookup logic
done
printf "\r  Scanning apps... done.                              \n"
```

### 2. `--only` Flag

```bash
# In parse_args():
--only)
  IFS=',' read -ra ONLY_SECTIONS <<< "$2"
  for s in "${ONLY_SECTIONS[@]}"; do
    validate_section_name "$s"  # exits if invalid
  done
  shift 2
  ;;
```

`section_enabled()` checks: if `ONLY_SECTIONS` is set, return true only if the section is in the list. Otherwise, return true unless `SKIP_<section>` is set.

### 3. Version Stamp

```bash
# In emit-preamble.sh:
GEN_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GEN_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GEN_HOST=$(hostname -s)

cat >> "$SCRIPT_FILE" << EOF
# Generated by dotfiles-sync ($GEN_VERSION)
# Source machine: $GEN_HOST
# Generated: $GEN_DATE
EOF
```

### 4. Colored Diff for Selective Zshrc

In the generated install script, when `--selective-zshrc` mode is active:

```bash
# For aliases: extract alias name, check if it exists with different value
_alias_name="gs"
_new_line="alias gs='git status'"
_existing=$(grep "^alias ${_alias_name}=" ~/.zshrc 2>/dev/null | head -1)
if [ -n "$_existing" ]; then
  if [ "$_existing" = "$_new_line" ]; then
    mark_present "Already in .zshrc: $_new_line"
  else
    echo -e "  ${YELLOW}$_alias_name exists but differs:${NC}"
    echo -e "    ${RED}- $_existing${NC}  (current)"
    echo -e "    ${GREEN}+ $_new_line${NC}  (source)"
    if prompt_yn "Replace"; then
      # Remove old, append new
      _content=$(grep -vF "$_existing" ~/.zshrc)
      printf '%s\n' "$_content" > ~/.zshrc
      echo "$_new_line" >> ~/.zshrc
      mark_installed "Replaced"
    fi
  fi
elif prompt_yn "Add: $_new_line"; then
  append_to_zshrc "$_new_line"
fi
```

Same pattern for exports (match on `export VARNAME=`) and functions (match on `funcname()`).

## Testing

### Test Runner

```bash
#!/usr/bin/env bash
# tests/run-tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

run_test() {
  local name="$1" script="$2"
  printf "  %-40s" "$name"
  if bash "$script" "$@" 2>&1; then
    echo "PASS"
  else
    echo "FAIL"
    ((FAILURES++))
  fi
}

run_test "ShellCheck"         "$TESTS_DIR/test-shellcheck.sh"
run_test "Generator syntax"   "$TESTS_DIR/test-generator-syntax.sh"
run_test "Golden files"       "$TESTS_DIR/test-golden.sh" "${1:-}"
run_test "No secret leaks"   "$TESTS_DIR/test-no-secrets.sh"

exit $FAILURES
```

### ShellCheck Test

Runs `shellcheck -s bash` on:
- `generate-setup.sh`
- All `lib/*.sh` files
- The generated `setup-new-mac.sh` output (from fixtures)

### Syntax Validation Test

1. Sets `HOME` to `tests/fixtures/home/`
2. Runs `generate-setup.sh --output /tmp/test-output/`
3. Runs `bash -n /tmp/test-output/setup-new-mac.sh`
4. Verifies exit code 0

### Golden File Test

1. Runs generator against fixtures
2. Diffs output against `tests/fixtures/golden/setup-new-mac.golden.sh`
3. Strips timestamps and hostnames before diffing (these change every run)
4. With `--update-golden`: overwrites the golden file instead of diffing

### Secret Leak Test

1. Plants known fake secrets in fixture configs (e.g. `export API_KEY="sk-test-12345"`)
2. Runs generator against fixtures
3. Greps generated install script + migration-configs for:
   - The literal fake secret values
   - Known key prefixes: `sk-`, `ghp_`, `gho_`, `AKIA`, `-----BEGIN`
   - High-entropy strings (optional, may be noisy)
4. Verifies `SECRETS_FOR_PASSWORD_MANAGER.md` does contain the values (they should be there)
5. Verifies no other generated file contains them

## Phase Ordering in Generated Install Script

The install script runs phases in dependency order:

1. Homebrew (everything else depends on brew)
2. Oh-My-Zsh (before shell config, since .zshrc references it)
3. Language runtimes / version managers
4. Shell configuration (.zshrc, .zprofile, etc.)
5. Git configuration
6. SSH keys
7. AWS configuration
8. Claude Code configuration
9. Cursor configuration
10. Xcode configuration
11. Infrastructure (ArgoCD, Opal, GH CLI)
12. macOS preferences
13. Keychain entries
14. Secret injection (replaces CHANGEME in previously written files)
15. Applications (brew cask + mas)
16. Git repos to clone
17. Summary

Phases are only included if the corresponding section was scanned. The secret injection phase is always last before apps/repos because it patches files written by earlier phases.

## What Gets Deleted

- `generate-install.sh` — functionality merged into the new modular generator
- `install-*.sh` — already gitignored, generated output
- `setup-new-mac.sh` — already gitignored, generated output

## Migration

Existing users of `generate-install.sh` get the same functionality via:
- `generate-setup.sh --only claude,shell,version-managers,tools` (equivalent scope)
- `generate-setup.sh --selective-zshrc` (equivalent zshrc behavior)

The README will document the migration path.
