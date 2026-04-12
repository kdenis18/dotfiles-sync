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
