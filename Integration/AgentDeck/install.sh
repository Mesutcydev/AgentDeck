#!/usr/bin/env bash
# Reversible AgentDeck integration installer (§19).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${HOME}/.agentdeck-integration-backup-$(date +%Y%m%d%H%M%S)"
BACKUP_KEEP=5

usage() {
  echo "Usage: $0 install|remove"
}

install_integration() {
  mkdir -p "$BACKUP_DIR"
  if [[ -f "${HOME}/.claude/settings.json" ]]; then
    cp -a "${HOME}/.claude/settings.json" "$BACKUP_DIR/claude-settings.json"
  fi
  mkdir -p "${HOME}/.claude/hooks"
  cp "$ROOT/claude/hooks/agentdeck-pretooluse.sh" "${HOME}/.claude/hooks/agentdeck-pretooluse.sh"
  chmod +x "${HOME}/.claude/hooks/agentdeck-pretooluse.sh"
  mkdir -p "${HOME}/.claude/skills/agentdeck"
  cp "$ROOT/claude/skills/agentdeck/SKILL.md" "${HOME}/.claude/skills/agentdeck/SKILL.md"
  if [[ -d "${HOME}/.codex" ]]; then
    cp "$ROOT/codex/instructions.md" "${HOME}/.codex/agentdeck-instructions.md"
  fi
  mkdir -p "${HOME}/.kimi/skills/agentdeck"
  cp "$ROOT/kimi/skills/agentdeck/SKILL.md" "${HOME}/.kimi/skills/agentdeck/SKILL.md"
  mkdir -p "${HOME}/.agentdeck"
  cp "$ROOT/generic/AGENTS.md" "${HOME}/.agentdeck/AGENTS.md"
  prune_backups
  echo "Installed. Backup at $BACKUP_DIR"
}

# Keep only the newest BACKUP_KEEP timestamped backup directories.
prune_backups() {
  ls -1dt "${HOME}"/.agentdeck-integration-backup-* 2>/dev/null \
    | tail -n "+$((BACKUP_KEEP + 1))" \
    | while IFS= read -r old; do rm -rf -- "$old"; done || true
}

remove_integration() {
  rm -f "${HOME}/.claude/hooks/agentdeck-pretooluse.sh"
  rm -f "${HOME}/.claude/skills/agentdeck/SKILL.md"
  rm -f "${HOME}/.codex/agentdeck-instructions.md"
  rm -f "${HOME}/.kimi/skills/agentdeck/SKILL.md"
  rm -f "${HOME}/.agentdeck/AGENTS.md"
  echo "Removed AgentDeck integration files."
}

case "${1:-}" in
  install) install_integration ;;
  remove) remove_integration ;;
  *) usage; exit 1 ;;
esac
