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
