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
