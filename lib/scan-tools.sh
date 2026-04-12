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
