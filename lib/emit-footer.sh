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
  echo -e "${BOLD}Done!${NC}"
  echo ""
  echo -e "${YELLOW}Restart your terminal (Ghostty, iTerm2, Terminal) to pick up shell and PATH changes.${NC}"
fi
FOOTER
}
