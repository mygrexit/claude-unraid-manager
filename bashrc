# shellcheck shell=bash
# Appended to /etc/bash.bashrc in the image by claude-unraid-manager.
#
# Every interactive bash in this container (Unraid's Console button, or
# `docker exec -it claude-unraid-manager bash`) attaches straight to the
# Claude session. Ctrl-b then d detaches and lands back in this shell.
# Non-interactive shells (`bash -c`, the healthcheck) do not read this file.
# Living in the image rather than in the persisted home, it applies to every
# install and survives a user's own ~/.bashrc.

if [ -z "${TMUX:-}" ] && [ -t 0 ] && tmux has-session -t "=${TMUX_SESSION:-main}" 2>/dev/null; then
  tmux attach -t "=${TMUX_SESSION:-main}"
  echo
  if tmux has-session -t "=${TMUX_SESSION:-main}" 2>/dev/null; then
    echo "Detached from the Claude session (it keeps running)."
    echo "  back in:  tmux attach -t ${TMUX_SESSION:-main}"
    echo "  leave:    exit"
  else
    echo "The Claude session has ended (container stopping, or Claude exited and is restarting)."
  fi
fi
