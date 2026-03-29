# dotfiles-sync

Generate portable install scripts to sync your dev environment between machines.

Reads your current machine's config (Claude Code MCPs, zsh aliases, plugins, Homebrew packages) and outputs a self-contained install script you can run on another machine. Every item prompts `[y/N]` before installing.

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
# Generate install script (MCPs + zsh + plugins + settings)
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
```

## What it captures

| Section | Source | Prompted action |
|---------|--------|-----------------|
| MCP Servers | `claude mcp list` + `~/.claude/settings.json` | `claude mcp add-json` per server |
| Cloud MCPs | `claude mcp list` (claude.ai prefix) | Info only (account-level) |
| Zsh Config | `~/.zshrc` aliases, exports, PATH, functions | Idempotent append to `~/.zshrc` |
| Plugins | `~/.claude/plugins/known_marketplaces.json` | Marketplace install instructions |
| Settings | `~/.claude/settings.json` | `jq` merge into target settings |
| Homebrew | `brew list` (with `--with-brew`) | `brew install` per package |

## Requirements

- macOS with zsh
- `claude` CLI (for MCP operations)
- `jq` (for JSON parsing -- `brew install jq`)
- `brew` (optional, for Homebrew package sync)

## How it works

The generator reads your current config and writes a bash script where each item is wrapped in a `[y/N]` prompt with an idempotency check (won't re-add things that already exist). Safe to re-run.

## Workflow

1. Set up something new on machine A (MCP, alias, brew package)
2. Run `generate-install.sh` on machine A
3. Commit the output to this repo (or transfer however you like)
4. On machine B: pull and run the install script
5. Pick what you want installed
