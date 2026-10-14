# shellcheck shell=bash
# Seeded into /root/.bashrc by claude-unraid-manager on first start.
#
# An interactive shell in this container (Unraid's Console button, or
# `docker exec -it claude-unraid-manager bash`) attaches straight to the
# Claude session. Ctrl-b then d detaches and lands back in this shell.
# Non-interactive shells (`bash -c`, the healthcheck) are not affected.

if [ -z "${TMUX:-}" ] && [ -t 0 ] && tmux has-session -t "${TMUX_SESSION:-main}" 2>/dev/null; then
  tmux attach -t "${TMUX_SESSION:-main}"
  echo
  echo "Detached from the Claude session (it keeps running)."
  echo "  back in:  tmux attach -t ${TMUX_SESSION:-main}"
  echo "  leave:    exit"
fi
