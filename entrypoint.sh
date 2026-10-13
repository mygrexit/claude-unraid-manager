#!/bin/bash
set -euo pipefail

SESSION="${TMUX_SESSION:-main}"
RC_NAME="${REMOTE_CONTROL_NAME:-$(hostname)}"
CONTINUE="${CONTINUE:-true}"
export HOST_HELPER_IMAGE="${HOST_HELPER_IMAGE:-alpine:3.21}"

# ── Seed dotfiles into the persisted home on first run ───────────────────────
[ -f /root/.tmux.conf ] || cp /usr/local/share/claude-unraid-manager/tmux.conf /root/.tmux.conf

# Seed default settings (read-only allow list, deny list, guard hook).
# First run: copy. Later runs: keep the user's file, but if it predates the
# guard hook, merge the shipped defaults underneath it (user keys win) so an
# upgraded install is not left without the hook.
SETTINGS_DEFAULT=/usr/local/share/claude-unraid-manager/settings.json
SETTINGS=/root/.claude/settings.json
mkdir -p /root/.claude
if [ ! -f "$SETTINGS" ]; then
  cp "$SETTINGS_DEFAULT" "$SETTINGS"
elif ! grep -q claude-guard "$SETTINGS"; then
  if claude-settings-merge "$SETTINGS_DEFAULT" "$SETTINGS" > "$SETTINGS.merged" 2>/dev/null; then
    cp "$SETTINGS" "$SETTINGS.bak"
    mv "$SETTINGS.merged" "$SETTINGS"
    echo "settings.json: merged in the guard hook and default permissions (backup: settings.json.bak)."
  else
    rm -f "$SETTINGS.merged"
    echo "Warning: settings.json is not valid JSON; guard hook not installed."
  fi
fi

# Fix SSH key permissions (bind-mount may loosen them)
if [ -d /root/.ssh ]; then
  chmod 700 /root/.ssh 2>/dev/null || true
  find /root/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
  chmod 644 /root/.ssh/*.pub 2>/dev/null || true
  chmod 600 /root/.ssh/config /root/.ssh/known_hosts 2>/dev/null || true
fi

# ── Make sure the host helper image is available ─────────────────────────────
# `host` (and the scan below) start a tiny helper container; pull it now so
# the first host command does not stall or fail on a cold cache.
if [ -S /var/run/docker.sock ]; then
  if ! docker image inspect "$HOST_HELPER_IMAGE" >/dev/null 2>&1; then
    timeout 60 docker pull -q "$HOST_HELPER_IMAGE" >/dev/null 2>&1 \
      || echo "Warning: could not pull $HOST_HELPER_IMAGE within 60 s — the first host command will pull it instead."
  fi
fi

# ── Generate / refresh CLAUDE.md ─────────────────────────────────────────────
/usr/local/bin/generate-claude-md.sh

# ── Build the claude launch arguments ────────────────────────────────────────
ARGS=()
[ "$CONTINUE" = "true" ] && ARGS+=(--continue)
# Remote Control needs a claude.ai login; with an API key it cannot start.
# REMOTE_CONTROL_NAME=off disables it explicitly.
REMOTE_CONTROL=false
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is set: Remote Control disabled (requires a claude.ai login)."
elif [ -n "$RC_NAME" ] && [ "$RC_NAME" != "off" ]; then
  ARGS+=(--remote-control "$RC_NAME")
  REMOTE_CONTROL=true
fi

# ── Start tmux with Claude inside ────────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c /workspace
  # Small delay so tmux is fully ready before sending keys
  sleep 0.3
  # claude-session restarts claude if it exits; %q keeps names with spaces intact.
  tmux send-keys -t "$SESSION" "clear; $(printf '%q ' claude-session "${ARGS[@]}")" C-m
fi

echo "Claude Unraid Manager is running."
echo "  Attach: docker exec -it \$(hostname) tmux attach -t $SESSION"
if [ "$REMOTE_CONTROL" = true ]; then
  echo "  Remote: open the Claude app and look for '$RC_NAME'"
else
  echo "  Remote: Remote Control is disabled"
fi

# Keep the container alive without burning CPU.
exec tail -f /dev/null
