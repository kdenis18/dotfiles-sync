# dotfiles-sync

Generate portable install scripts to sync your dev environment between machines.

Reads your current machine's config (Claude Code MCPs, zsh aliases, plugins, tool configs, version managers, Homebrew packages) and outputs a self-contained install script you can run on another machine. Every item prompts `[y/N]` before installing.

## Setup

```bash
# Clone this repo
git clone git@github.com:kdenis18/dotfiles-sync.git
cd dotfiles-sync

# Copy the generator to your PATH
cp generate-install.sh ~/.local/bin/
chmod +x ~/.local/bin/generate-install.sh
```

## Usage

```bash
# Generate install script (MCPs + zsh + plugins + tools + settings)
generate-install.sh

# Include Homebrew packages
generate-install.sh --with-brew

# Custom output path
generate-install.sh --output ~/Desktop/setup-for-work.sh
```

This produces a file like `install-Kevins-Mac-mini-20260328.sh`.

Transfer it to your other machine (airdrop, git, email, USB) and run:

```bash
chmod +x install-Kevins-Mac-mini-20260328.sh
./install-Kevins-Mac-mini-20260328.sh

# Preview what would be installed without making changes
./install-Kevins-Mac-mini-20260328.sh --dry-run
```

## What it captures

| Section | Source | Prompted action |
|---------|--------|-----------------|
| MCP Servers | `claude mcp list` + `~/.claude.json` | `claude mcp add-json` per server |
| Cloud MCPs | `claude mcp list` (claude.ai prefix) | Info only (account-level) |
| Zsh Config | `~/.zshrc` aliases, exports, PATH, functions | Idempotent append to `~/.zshrc` |
| RTK | `rtk --version` | `brew install rtk` |
| Plugins | `~/.claude/plugins/known_marketplaces.json` | Marketplace + plugin install |
| Settings | `~/.claude/settings.json` | `jq` merge into target settings |
| Version Managers | `dotfiles-manifest.json` (rbenv, nvm, pyenv) | Install manager + language version |
| Tool Configs | `dotfiles-manifest.json` (oh-my-zsh, iTerm2, Ghostty) | Install app + restore configs/prefs |
| Homebrew | `brew list` (with `--with-brew`) | `brew install` per package |

## Manifest

`dotfiles-manifest.json` drives tool and version manager discovery. Add new entries to extend what the generator captures without editing bash.

### Tools

```json
{
  "name": "ghostty",
  "label": "Ghostty",
  "check_path": "/Applications/Ghostty.app",
  "brew_cask": "ghostty",
  "config_dirs": [
    { "src": "$HOME/.config/ghostty", "dest": "$HOME/.config/ghostty", "exclude": [] }
  ]
}
```

Supported fields: `check_path`, `install_cmd`, `brew_cask`, `brew_formula`, `install_hint`, `prefs_plist`, `config_dirs`.

### Version Managers

```json
{
  "name": "pyenv",
  "label": "pyenv",
  "check_cmd": "pyenv",
  "brew_formula": "pyenv",
  "managed_lang": "Python",
  "version_file": "$HOME/.pyenv/version",
  "check_version_cmd": "pyenv versions 2>/dev/null | grep -q \"{version}\"",
  "install_version_cmd": "pyenv install {version} && pyenv global {version}"
}
```

Supported fields: `check_cmd`, `check_dir`, `brew_formula`, `install_cmd` (with `{tool_version}` placeholder), `install_cmd_fallback`, `install_msg`, `tool_version_file`, `tool_version_pattern`, `managed_lang`, `version_file`, `version_cmd`, `requires_check`, `pre_use_cmd`, `check_version_cmd` (with `{version}`), `install_version_cmd` (with `{version}`), `install_version_msg`.

## Requirements

- macOS with zsh
- `claude` CLI (for MCP operations)
- `jq` (for JSON parsing -- `brew install jq`)
- `brew` (optional, for Homebrew package sync)

## How it works

The generator reads your current config and writes a bash script where each item is wrapped in a `[y/N]` prompt with an idempotency check (won't re-add things that already exist). Safe to re-run.

Generated scripts support `--dry-run` to preview all items without making changes.

## Workflow

1. Set up something new on machine A (MCP, alias, brew package, tool)
2. Run `generate-install.sh` on machine A
3. Commit the output to this repo (or transfer however you like)
4. On machine B: pull and run the install script
5. Pick what you want installed
