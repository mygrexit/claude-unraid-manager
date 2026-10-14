#!/bin/bash
set -euo pipefail

SESSION="${TMUX_SESSION:-main}"
RC_NAME="${REMOTE_CONTROL_NAME:-$(hostname)}"
CONTINUE="${CONTINUE:-true}"
export HOST_HELPER_IMAGE="${HOST_HELPER_IMAGE:-alpine:3.21}"

# ── Seed dotfiles into the persisted home on first run ───────────────────────
[ -f /root/.tmux.conf ] || cp /usr/local/share/claude-unraid-manager/tmux.conf /root/.tmux.conf

# Seed default settings (manual permission mode, read-only allow list, deny
# list, guard hook). First run: copy. Later runs: keep the user's file; when
# the shipped settings gained keys since the install was last brought up to
# date (version stamp), merge them underneath the user's keys once. A key the
# user removes afterwards stays removed.
SETTINGS_DEFAULT=/usr/local/share/claude-unraid-manager/settings.json
SETTINGS=/root/.claude/settings.json
SETTINGS_STAMP=/root/.claude/.claude-unraid-manager-settings-version
SETTINGS_VERSION=3   # bump whenever settings.json gains keys existing installs should receive
mkdir -p /root/.claude
stamp=$(cat "$SETTINGS_STAMP" 2>/dev/null || true)
case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
if [ ! -f "$SETTINGS" ]; then
  cp "$SETTINGS_DEFAULT" "$SETTINGS"
  echo "$SETTINGS_VERSION" > "$SETTINGS_STAMP"
elif [ "$stamp" -lt "$SETTINGS_VERSION" ]; then
  if claude-settings-merge "$SETTINGS_DEFAULT" "$SETTINGS" > "$SETTINGS.merged" 2>/dev/null; then
    cp "$SETTINGS" "$SETTINGS.bak"
    mv "$SETTINGS.merged" "$SETTINGS"
    echo "$SETTINGS_VERSION" > "$SETTINGS_STAMP"
    echo "settings.json: merged in the shipped defaults (guard hook, permission mode, deny list) underneath your settings (backup: settings.json.bak)."
    missing=$(claude-settings-merge --missing-allow "$SETTINGS_DEFAULT" "$SETTINGS" 2>/dev/null | tr '\n' ' ')
    [ -z "$missing" ] || echo "settings.json: your allow list was left as is; shipped read-only entries it does not have: $missing"
  else
    rm -f "$SETTINGS.merged"
    echo "Warning: settings.json is not valid JSON; the shipped defaults (guard hook, permission mode) were not merged in."
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
# "=" makes tmux match the session name exactly instead of by prefix. For
# pane targets (send-keys) the session must end with ":" or tmux reads the
# whole string as a pane name.
if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c /workspace
  # Small delay so tmux is fully ready before sending keys
  sleep 0.3
  # claude-session restarts claude if it exits; %q keeps names with spaces intact.
  tmux send-keys -t "=$SESSION:" "clear; $(printf '%q ' claude-session "${ARGS[@]}")" C-m
fi

echo "Claude Unraid Manager is running."
echo "  Attach: docker exec -it \$(hostname) tmux attach -t $SESSION"
if [ "$REMOTE_CONTROL" = true ]; then
  echo "  Remote: open the Claude app and look for '$RC_NAME'"
else
  echo "  Remote: Remote Control is disabled"
fi
# A claude.ai login leaves .credentials.json and an oauthAccount entry in .claude.json.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ ! -f /root/.claude/.credentials.json ] \
   && ! grep -qs oauthAccount /root/.claude.json; then
  echo "  Login:  not logged in yet — attach and complete the login once"
fi

# Keep the container alive without burning CPU. On stop, end the tmux server
# first so Claude shuts down cleanly instead of being killed with the container.
shutdown() {
  tmux kill-server 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT
tail -f /dev/null &
wait $!
