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
