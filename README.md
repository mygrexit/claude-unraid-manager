# Claude Unraid Manager

An always-on [Claude Code](https://claude.com/claude-code) container purpose-built for **Unraid system administration**.

Unlike generic Claude Code containers, this one understands Unraid: it auto-discovers your storage pools (ZFS, btrfs, XFS, or parity array), running containers, VMs, plugins, shares, and network — and generates a tailored `CLAUDE.md` so Claude knows exactly what it can and cannot do on *your* server.

> ⚠️ **This gives an AI model root-equivalent access to your server** through the
> Docker socket. The defaults are conservative and there are guard rails, but
> none of them is a security boundary. Read [Security Model](#security-model)
> and the [Disclaimer](#disclaimer) before installing, and keep backups.

## What This Is For

An **interactive admin assistant** that acts on your server, with you in the
loop: "Plex won't start, find out why", "the cache pool is filling up, what is
taking the space", "set up a container for X so it shows in the Docker tab",
"why did the parity check slow down" — from the Unraid terminal or from your
phone via Remote Control. Claude has the context (your pools, shares,
containers, plugins) and the tools (`docker`, `host zpool …`, `host virsh …`)
to investigate and, after you confirm, to fix things.

**What it is not:**

- *Not a monitoring or inventory tool.* The `CLAUDE.md` scan exists so Claude
  knows your system; it is not a report for you. If all you want is a regular
  overview or alerts, a read-only scheduled job (`claude -p` with no write
  permissions, or just a script and Unraid notifications) is simpler and has a
  far smaller blast radius than an always-on agent with the Docker socket.
- *Not an autonomous operator.* It is meant to be used with permission prompts
  on and a human reading them. Nothing here is designed for unattended
  changes.
- *Not a security boundary.* See [Security Model](#security-model): with the
  Docker socket mounted, the container is root-equivalent on the host. The
  guard rails lower the chance of an accident; they do not contain a
  determined attacker or a prompt-injected session.

## Features

- **Auto-discovery** — on every start, scans your Unraid server and writes a `CLAUDE.md` with your storage topology, containers, VMs, plugins, and network config
- **Safe defaults** — boot drive read-only, no shares mounted, bridge networking. The user opts in to more access
- **Guard hook** — a small set of catastrophic commands (`mkfs`, `wipefs`, writing to a disk, `zpool destroy`, `rm -rf` on a mount root) is blocked whichever wrapper is used (`host`, `sh -c`, absolute paths)
- **Remote Control** — reach your Claude session from phone or tablet via the Claude app
- **Persistent sessions** — tmux keeps the session alive across disconnects; Claude restarts automatically if it exits; `--continue` resumes the last conversation
- **GUI-compatible** — Claude knows to create proper dockerMan templates, respect Unraid's persistence model, and keep changes manageable through the web UI
- **Multi-filesystem** — works with ZFS pools, btrfs pools, XFS, and the classic Unraid parity array

## Quick Start

Not in Community Applications yet, and no image has been published yet, so
build it on the server and install the template by hand:

```bash
# On the Unraid terminal. Uses the appdata location configured under
# Settings → Docker, so no new share is created on systems that keep it elsewhere.
APPDATA=$(sed -n 's/^DOCKER_APP_CONFIG_PATH="\(.*\)"$/\1/p' /boot/config/docker.cfg)
APPDATA=${APPDATA%/}; APPDATA=${APPDATA:-/mnt/user/appdata}
cd "$APPDATA" && git clone https://github.com/mygrexit/claude-unraid-manager.git claude-unraid-manager-src
docker build -t claude-unraid-manager:local claude-unraid-manager-src
sed 's#<Repository>.*</Repository>#<Repository>claude-unraid-manager:local</Repository>#' \
  claude-unraid-manager-src/unraid-template.xml \
  > /boot/config/plugins/dockerMan/templates-user/my-claude-unraid-manager.xml
```

The template's two appdata mounts default to `/mnt/user/appdata/…` like every
Unraid template. If your appdata lives elsewhere (for example
`/mnt/cache/appdata`), change them when adding the container: touching a path
under `/mnt/user` that does not exist makes Unraid create a new share there.

Then in the Unraid web UI open **Docker → Add Container**, pick
`claude-unraid-manager` from the template dropdown, review the mounts (boot
drive read-only, no shares by default), apply, and attach to the session (see
below) to log in.

Once a release is tagged the image is published at
`ghcr.io/mygrexit/claude-unraid-manager:latest`, which is what the template
points to by default; the build and `sed` steps above then go away.

## How It Works

The container uses the Docker socket to manage containers and to run host-level commands (like `zpool status` or `virsh list`) through a `host` wrapper. `host <command>` starts a short-lived privileged helper container (`alpine`) that enters the host's namespaces and runs the command there. The main container itself does **not** need privileged mode.

On every start, a discovery script scans the host and generates a `CLAUDE.md` in the workspace with:
- System info (Unraid version, CPU, RAM)
- Storage topology (pools, datasets, array state, shares, encrypted datasets)
- Running containers and their status
- VMs, plugins, User Scripts (name and description), host network interfaces
- Which paths are mounted and whether they're read-only or read-write
- Whether the container runs in host or bridge networking, and what that means

Claude reads this file and adapts its behavior accordingly. The scan is a snapshot from container start; Claude is told to use live commands for the current state.

## Security Model

**The Docker socket is equivalent to root access on the host.** Any container
with the socket can start a privileged container that reaches the entire
filesystem, all processes, and all data — regardless of what mounts this
template configures. This is not specific to this project; it applies equally
to Portainer, Dockge, Yacht, and every other Docker management tool.

The mount restrictions below are **behavioral guardrails**: they control what
Claude naturally discovers and works with. They are not security boundaries.
If you need a hard boundary, do not mount the Docker socket — but then Claude
cannot manage containers or run host commands, which is the entire point.

## Access Control

| Mount | Default | What it enables |
|-------|---------|----------------|
| Docker socket | mounted (rw) | Container management, host command execution |
| `/host/boot` | **read-only** | View Unraid config, plugins, templates |
| `/host/boot` (rw) | opt-in | Modify config, install plugins, edit templates |
| `/appdata` | not mounted | Inspect container app data |
| Other shares | not mounted | Access to media, downloads, personal files |
| Host networking | off (bridge) | Only needed if something must reach this container directly; outbound SSH to VMs and LAN hosts works in bridge mode |

Every optional mount has a description in the Docker template explaining what it does.

### Defense in Depth

Three independent layers, in order of how much you should rely on them:

1. **Permission prompts** (interactive) — Claude Code asks before every shell
   command and file write by default. A small allow list in the shipped
   `settings.json` lets read-only commands (`docker ps`, `docker logs`,
   `host zpool status`, …) run without a prompt so the prompts you do see are
   the ones that matter. Accept-edits mode auto-approves file edits only; shell
   commands still prompt. `--dangerously-skip-permissions` is disabled in the
   shipped settings (`disableBypassPermissionsMode`).

2. **Guard hook** (hard block for a short list) — `claude-guard` is a
   `PreToolUse` hook that inspects the *entire* command string before it runs
   and blocks `mkfs`, `wipefs`, `shred`, writing to a block device (`dd`,
   `cp`, `tee`, `>` redirection), `sgdisk --zap`, `zpool destroy`/`labelclear`,
   and `rm` on `/`, `/mnt/*`, `/mnt/*/appdata`, `/boot`, `/host/boot` or
   `/appdata`. Because it sees the whole string, wrapping the command in
   `host …`, `sh -c '…'` or `docker run … nsenter …`, using absolute paths,
   trailing slashes or `..` does not get around it. Claude Code's own `deny`
   rules are also present, but they only match the outermost command, so on
   their own they would not stop `host mkfs.ext4 /dev/sdb`.

   This list is deliberately short: it covers operations that should never be
   done from this container. Everything else that is risky (`zfs destroy`,
   `docker rm`, editing `/boot/config`) goes through the rules in layer 3 and
   your confirmation in layer 1. The guard matches text: a command built from
   shell variables, written to a script first, or obfuscated beyond simple
   quoting is outside its reach. It catches mistakes, not a determined
   bypass.

3. **CLAUDE.md rules** (behavioral) — Claude reads these on every start.
   "Always confirm before destructive operations" means Claude asks *you* in
   the chat before proposing the command.

All of this lives in `~/.claude/settings.json` inside the persisted home
directory and can be edited. It protects against mistakes, not against a
determined adversary with socket access. The file is seeded on first start;
on later starts, an existing file that predates the guard hook gets the
shipped defaults merged in underneath its own keys (a `settings.json.bak` is
kept).

## Attaching to the Session

```bash
# From the Unraid terminal
docker exec -it claude-unraid-manager tmux attach -t main

# Or add this shortcut to /boot/config/go:
cat > /usr/local/bin/claude << 'EOF'
#!/bin/bash
docker exec -it claude-unraid-manager tmux attach -t main
EOF
chmod +x /usr/local/bin/claude
```

On first start, attach and complete the login (claude.ai subscription or
Console account). Inside a container the browser cannot open on its own:
press `c` to copy the login URL, open it on any device, and paste the code it
shows back into the terminal when asked.

If Claude exits for any reason, it restarts after 5 seconds; press Ctrl-C
during that pause to get a shell instead. If it keeps exiting right away, the
wrapper first drops `--continue` (in case the previous conversation is what
fails) and gives up after five fast exits in a row, leaving the output on
screen.

From phone/tablet: open the Claude app and look for the Remote Control session name (defaults to the container hostname). Remote Control requires a claude.ai login; it is not available with an API key alone.

## Customizing CLAUDE.md

The `## Custom` section at the bottom of the generated `CLAUDE.md` is yours. Add project-specific instructions, safety overrides, or preferred workflows there — the discovery script preserves this section across restarts.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `UTC` | Timezone |
| `TMUX_SESSION` | `main` | tmux session name |
| `REMOTE_CONTROL_NAME` | hostname | Name shown in the Claude app; `off` disables Remote Control |
| `CONTINUE` | `true` | Resume last conversation on start |
| `CLAUDE_LANG` | *(empty)* | Response language (e.g. `de`, `fr`, `es`). Empty = English |
| `ANTHROPIC_API_KEY` | *(empty)* | Optional. Bill usage to a Claude Console API key instead of logging in. Disables Remote Control |
| `HOST_HELPER_IMAGE` | `alpine:3.21` | Image for the helper container behind `host`. Pulled on start |

### A note on appdata

`/root` holds Claude's login, settings and conversation history, which means
many small writes. The default path is on `/mnt/user/appdata` and works, but a
cache-only (exclusive) appdata share avoids the FUSE overhead of user shares
and is the usual recommendation on Unraid.

## Disclaimer

**This tool gives an AI model access to your Unraid server.** While defaults are
conservative (boot drive read-only, no shares mounted, no privileged mode), the
Docker socket alone grants the ability to start privileged containers that can
reach the entire host.

**You are responsible for what Claude does on your system.**

- Review every action Claude proposes before confirming it.
- Start with read-only access and only expand permissions when you understand
  what they allow.
- Keep backups. Always.
- This project is not affiliated with or endorsed by Lime Technology (Unraid)
  or Anthropic.

The author provides this software as-is, without warranty of any kind. See the
[MIT license](LICENSE) for the full terms. **No liability is accepted for data
loss, misconfiguration, downtime, or any other damage resulting from the use of
this tool.**

## Building and Testing Locally

```bash
docker build -t claude-unraid-manager .

# Scanner and guard tests run without Docker or Unraid:
bash tests/run.sh
shellcheck -s bash entrypoint.sh generate-claude-md.sh host claude-guard claude-session claude-settings-merge tests/run.sh
```

## License

[MIT](LICENSE)
