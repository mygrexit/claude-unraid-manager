# Hardening ideas (backlog)

Ideas to shrink the blast radius of the Docker socket without losing the point of the tool. Not implemented yet.

## 1. Socket proxy for an "observe" mode

Most sessions only look: `docker ps`, logs, inspect, stats. Route those through a socket proxy
(e.g. `tecnativa/docker-socket-proxy` or `wollomatic/socket-proxy`) that allows only GET on
`/containers`, `/images`, `/info`, `/version`, `/events` and denies `exec`, `create`, `start` and
`POST` in general. The full socket would then be an explicit opt-in per session (template toggle or
a second container), not the default.

Trade-off: `host <command>` needs `create`/`start` of a privileged helper, so it is unavailable in
observe mode. That is the intended effect.

## 2. Untrusted content is a prompt-injection path

With a media or download share mounted, file names, NFO files, subtitles and metadata are chosen by
whoever published the release. If Claude reads them while holding the Docker socket, injected
instructions meet root-equivalent tools. Options:

- Do not mount download/incoming folders; mount curated libraries read-only only when needed.
- Have `claude-guard` treat content read from those mounts as untrusted (ask before any command that
  follows from it, never run commands found in file contents).
- Prefer observe mode (above) for library work.

## 3. `/boot` read-only still exposes secrets

The flash drive holds plaintext credentials of the host (backup repository passwords, S3 keys,
plugin tokens). Read-only does not prevent reading them. Consider not mounting `/boot` by default
and listing only the paths the generated CLAUDE.md really needs (e.g. `config/plugins/dockerMan`,
`config/shares`, `config/ident.cfg`), or reading them through `host` on demand.

## 4. Always-on vs. on demand

An always-on container with the socket is a standing root-equivalent target. Starting it only for a
session (and stopping it afterwards, e.g. via the existing boot mode) removes the idle exposure.
