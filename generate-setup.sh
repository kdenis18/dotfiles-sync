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

# Helpers to wrap generated sections with skip guards
_guard()     { [[ "$DRY_RUN" != true ]] && printf '\nif section_active "%s"; then\n' "$1" >> "$SCRIPT_FILE" || true; }
_guard_end() { [[ "$DRY_RUN" != true ]] && printf '\nfi  # end section: %s\n' "$1" >> "$SCRIPT_FILE" || true; }

# Run each enabled section
if section_enabled "brew";             then _guard "brew";             scan_brew;             _guard_end "brew";            fi
if section_enabled "shell";            then _guard "shell";            scan_shell;            _guard_end "shell";           fi
if section_enabled "apps";             then _guard "apps";             scan_apps;             _guard_end "apps";            fi
if section_enabled "claude";           then _guard "claude";           scan_claude;           _guard_end "claude";          fi
if section_enabled "cursor";           then _guard "cursor";           scan_cursor;           _guard_end "cursor";          fi
if section_enabled "xcode";            then _guard "xcode";            scan_xcode;            _guard_end "xcode";           fi
if section_enabled "git";              then _guard "git";              scan_git;              _guard_end "git";             fi
if section_enabled "ssh";              then _guard "ssh";              scan_ssh;              _guard_end "ssh";             fi
if section_enabled "infra";            then _guard "infra";            scan_infra;            _guard_end "infra";           fi
if section_enabled "repos";            then _guard "repos";            scan_repos;            _guard_end "repos";           fi
if section_enabled "version-managers"; then _guard "version-managers"; scan_version_managers; _guard_end "version-managers"; fi
if section_enabled "tools";            then _guard "tools";            scan_tools;            _guard_end "tools";           fi
if section_enabled "macos";            then _guard "macos";            scan_macos;            _guard_end "macos";           fi

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
