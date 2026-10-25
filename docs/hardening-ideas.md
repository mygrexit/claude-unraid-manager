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

Research (2026-10-25) points to a better default than a proxy: the Unraid API, see 1a. A proxy stays
an option only for what the API does not return.

| Proxy | Filters | Notes |
|---|---|---|
| `tecnativa/docker-socket-proxy` | method and path prefix | "Read" still allows `archive`, `export` and Env in `inspect` |
| `wollomatic/socket-proxy` | regex allowlist per method, per-client labels, bind mount sources | Mature and maintained. Its own docs say privileged containers, host namespaces and capabilities are not filtered, so never allow `create`. Env in `inspect` stays visible |
| `CodesWhat/sockguard` | request bodies, Env redaction in responses, exec command allowlist | Closest to what we want, but created 2026-03 with very few users and fast release churn. Watch, do not depend on it |
| OPA `docker-authz` | Rego on the full request | Needs `daemon.json` changes (RAM root fs on Unraid) and affects every Docker client, dockerMan included |

Body filtering is fragile: CVE-2026-34040 (fixed in Docker Engine 29.3.1) let request bodies over
1 MB bypass AuthZ plugins. Not offering `create` at all is more robust than filtering it.

## 1a. Unraid API with a scoped key as the default tier

Unraid 7.2+ ships a GraphQL API (`https://<host>:<port>/graphql`, header `x-api-key`) whose keys carry
permissions per resource (`DOCKER`, `VMS`, `ARRAY`, `DISK`, `SHARE`, `LOGS`, ...) and action
(`READ_ANY`, `UPDATE_ANY`, `DELETE_ANY`, ...). The server enforces them. There is no "create a
container with arbitrary config" mutation, so the path to root that proxies struggle with does not
exist. Users pick the permissions in Unraid's own UI (Settings → Management Access → API Keys).

Sketch of tiers:

| Tier | Access |
|---|---|
| observe (default) | API key with `READ_ANY` on chosen resources, no Docker socket |
| operate | + `DOCKER:UPDATE_ANY`, `VMS:UPDATE_ANY` |
| full | Docker socket + `host`, as today; explicit opt-in |

Tested on one server (Unraid 7.3.3, unraid-api 4.37.6, Docker 29.8.2) with a `DOCKER:READ_ANY` key:

- `stop` on a made-up container id returns 403, not "not found": the permission check runs before the
  lookup. `array`, `vars`, `disks`, `vms` and `logFiles` return 403 as well. A wrong key is rejected.
- `DockerContainer` has no Env field; `hostConfig` only carries `networkMode`. `command` shows the full
  command line, `mounts` all host paths. `docker { logs(id) }` works, so secrets an app writes to its
  log are readable.
- Without a key only `{ __typename }` answers; other queries need a CSRF token, introspection is off.
  With `x-api-key` no CSRF token is needed and introspection is on (the schema is public anyway).
- Reachable from a bridge container via the LAN IP. With SSL enabled the certificate is self-signed:
  pin it rather than skipping verification.

Points the design and docs must reflect:

- Never recommend the `VIEWER` role: it grants `READ_ANY` on every resource except `API_KEY`,
  including `FLASH`, `CONFIG` and `VARS`. Recommend an explicit permission list.
- `DOCKER:UPDATE_ANY` covers start/stop/restart and also `updateContainer`, `updateAllContainers` and
  the autostart order. Start/stop alone cannot be granted.
- The API runs as root on the host. A key with write permissions is not limited by our read-only
  `/boot` mount. An `ADMIN` key is root: `installPlugin(url)` runs a `.plg` from any URL, and
  `apiKey.create` can mint further keys.
- The API does not cover shell commands, User Scripts, ZFS details, new containers, template edits,
  VM XML or network config. That stays in the full tier.
- Not yet checked: what `ARRAY`, `DISK`, `VMS` and `LOGS` return with a read key, and which name the
  certificate is issued for.

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
