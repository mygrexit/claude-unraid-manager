# ── build: fetch the Claude Code native binary via npm ───────────────────────
# The npm package's postinstall copies the platform binary over bin/claude.exe;
# `claude` then execs it directly and no Node.js process stays resident. Only
# that one file is carried into the runtime image.
FROM node:22-bookworm-slim AS build

# Pin the Claude Code version so every image is reproducible.
# Bump this (and rebuild) to update Claude Code.
ARG CLAUDE_CODE_VERSION=2.1.296

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && cp -L "$(readlink -f /usr/local/bin/claude)" /claude \
    && chmod 0755 /claude \
    && /claude --version

# ── runtime ──────────────────────────────────────────────────────────────────
# No Node.js in the runtime image: Claude Code runs natively. MCP servers that
# are started through `npx` therefore do not work inside this container.
FROM debian:bookworm-slim

COPY --from=build /claude /usr/local/bin/claude

# Docker CLI only (Debian's docker.io would pull in dockerd, containerd, runc).
COPY --from=docker:28-cli /usr/local/bin/docker /usr/local/bin/docker

RUN apt-get update && apt-get install -y --no-install-recommends \
      tini tmux git curl ca-certificates openssh-client \
      ripgrep jq procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ship the base CLAUDE.md, snippets, generator and helpers inside the image.
COPY claude-md/            /usr/local/share/claude-unraid-manager/claude-md/
COPY tmux.conf             /usr/local/share/claude-unraid-manager/tmux.conf
# Interactive shells (Console button, docker exec -it ... bash) attach to the
# Claude session. System-wide so it applies regardless of the persisted home.
COPY bashrc                /usr/local/share/claude-unraid-manager/bashrc
RUN printf '\n' >> /etc/bash.bashrc && cat /usr/local/share/claude-unraid-manager/bashrc >> /etc/bash.bashrc
COPY settings.json         /usr/local/share/claude-unraid-manager/settings.json
COPY entrypoint.sh generate-claude-md.sh host logs claude-guard claude-session claude-settings-merge /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/generate-claude-md.sh \
             /usr/local/bin/host /usr/local/bin/logs /usr/local/bin/claude-guard \
             /usr/local/bin/claude-session /usr/local/bin/claude-settings-merge

# IS_SANDBOX is deliberately not set: it only serves to allow
# --dangerously-skip-permissions as root, which this image does not support.
ENV DISABLE_AUTOUPDATER=1 \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

WORKDIR /workspace

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD pgrep -x claude >/dev/null || exit 1

LABEL org.opencontainers.image.source="https://github.com/mygrexit/claude-unraid-manager" \
      org.opencontainers.image.description="Claude Code as an Unraid system manager" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
