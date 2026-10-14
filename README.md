# Claude Unraid Manager

[Claude Code](https://claude.com/claude-code) set up as an **Unraid
administrator**, not as a coding tool: an always-on container in which Claude
manages your containers, storage, VMs, plugins and configuration. It is meant
to ask you before it acts; how much of that holds depends on you keeping the
permission prompts on and reading them.

> ⚠️ **For experienced Unraid users only.** This gives an AI model
> root-equivalent access to your server through the Docker socket. The
> defaults are conservative and there are guard rails, but none of them is a
> security boundary, and you are the one approving what Claude runs. If you
> would not be comfortable doing the same work yourself on the Unraid command
> line, this is not for you. Read [Security Model](#security-model) and the
> [Disclaimer](#disclaimer) before installing, and keep backups.

Unlike generic Claude Code containers, this one is set up for Unraid: on every start it scans your storage pools (ZFS, btrfs, XFS, or parity array), containers, VMs, plugins, shares, and network and writes a `CLAUDE.md` so Claude starts with a picture of *your* server and the rules for working on it.

**Status: beta.** Everything here was tested on the author's two Unraid
7.3.3 servers, both ZFS pool-only (array started with no data disks), not on
a range of different setups. Not yet seen in action: arrays with data disks
and parity, btrfs and XFS pools, systems without ZFS. The scanner has code
paths for those, nobody has watched them run. And it is an AI agent: the
rules in `CLAUDE.md` shape what Claude does, they do not guarantee it. Expect
rough edges and report them in the
[issues](https://github.com/mygrexit/claude-unraid-manager/issues).

## What This Is For

An **interactive admin assistant** that acts on your server, with you in the
loop: "Plex won't start, find out why", "the cache pool is filling up, what is
taking the space", "set up a container for X so it shows in the Docker tab",
"why did the parity check slow down" — from the Unraid terminal or from your
phone via Remote Control. Claude has the context (your pools, shares,
containers, plugins) and the tools (`docker`, `host zpool …`, `host virsh …`)
to investigate and, ideally after you confirm, to fix things.

**What it is not:**

- *Not a monitoring or inventory tool.* The `CLAUDE.md` scan exists so Claude
  knows your system; it is not a report for you. If all you want is a regular
  overview or alerts, a read-only scheduled job (`claude -p` with no write
  permissions, or just a script and Unraid notifications) is simpler and has a
  far smaller blast radius than an always-on agent with the Docker socket.
- *Not an autonomous operator.* It is meant to be used with permission prompts
  on and a human reading them. Nothing here is designed for unattended
  changes.
- *Not a development environment.* It can edit files in `/workspace`, but
  everything about it (context, permissions, guard rails) is built for
  administration. For coding, use a normal Claude Code install.
- *Not a security boundary.* See [Security Model](#security-model): with the
  Docker socket mounted, the container is root-equivalent on the host. The
  guard rails lower the chance of an accident; they do not contain a
  determined attacker or a prompt-injected session.

## Features

- **Auto-discovery** — on every start, scans your Unraid server and writes a `CLAUDE.md` with your storage topology, containers, VMs, plugins, User Scripts and network config
- **Safe defaults** — boot drive read-only, no shares mounted, bridge networking. The user opts in to more access
- **Guard hook** — a short list of catastrophic commands (`mkfs`, `wipefs`, writing to a disk, `zpool destroy`, `rm -rf` on a mount root) is blocked by a text match on the whole command, whichever wrapper is used (`host`, `sh -c`, absolute paths). A safety net, not a wall; see [Defense in Depth](#defense-in-depth)
- **Remote Control** — reach your Claude session from phone or tablet via the Claude app
- **Persistent sessions** — tmux keeps the session alive across disconnects; Claude is restarted if it exits; `--continue` resumes the last conversation
- **GUI-aware** — Claude is instructed to create dockerMan templates for new containers, respect Unraid's persistence model, and keep changes manageable through the web UI. Instructions, not guarantees
- **Multi-filesystem** — detects ZFS pools, btrfs pools, XFS, and the classic Unraid parity array; only ZFS pool-only setups have been verified so far

## Quick Start

Step by step, including console, login and phone:
**[docs/getting-started.md](docs/getting-started.md)**. The short version:

1. Unraid web UI → **Apps** → search for *claude-unraid-manager* → **Install**
   (it is marked as beta).
2. Review the mounts (boot drive read-only, no shares by default) and apply.
   The two appdata paths default to `/mnt/user/appdata/…` like every Unraid
   template; if your appdata lives elsewhere (for example
   `/mnt/cache/appdata`), change them here: touching a path under `/mnt/user`
   that does not exist makes Unraid create a new share there.
3. Docker tab → click the container → **Console** and complete the login once
   (see [Attaching to the Session](#attaching-to-the-session)).

The image is `ghcr.io/mygrexit/claude-unraid-manager:beta`.

To build the image yourself instead, see
[Building and Testing Locally](#building-and-testing-locally).

## How It Works

The container uses the Docker socket to manage containers and to run host-level commands (like `zpool status` or `virsh list`) through a `host` wrapper. `host <command>` starts a short-lived privileged helper container (`alpine`) that enters the host's namespaces and runs the command there. The main container itself does **not** need privileged mode.

On every start, a discovery script scans the host and generates a `CLAUDE.md` in the workspace with:
- System info (Unraid version, CPU, RAM)
- Storage topology (pools, datasets, array state, shares, encrypted datasets)
- Running containers and their status
- VMs with their state, plugins, User Scripts (name, description, schedule), host network interfaces
- Which paths are mounted and whether they're read-only or read-write
- Whether the container runs in host or bridge networking, and what that means

Claude reads this file at the start of a session and should work from it. The scan is a snapshot from container start; Claude is told to use live commands for the current state.

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
| `/appdata` | not mounted | Inspect other containers' configs and logs |
| Any share | not mounted | Add it with *Add another Path* in the template (any container path outside `/root`, read-only unless Claude should change files). Claude knows which shares exist and tells you how to add one when it matters |
| Host networking | off (bridge) | Only needed if something must reach this container directly; outbound SSH to VMs and LAN hosts works in bridge mode |

Every bind mount you add shows up in Claude's `CLAUDE.md` with its access mode after the next start.

### Defense in Depth

Three independent layers, in order of how much you should rely on them:

1. **Permission prompts** (interactive) — the shipped `settings.json` starts
   every session in Manual mode (`defaultMode: default`), so Claude Code asks
   before shell commands and file writes. This matters because Claude Code
   itself now starts in auto mode by default, where a classifier approves
   actions instead of you; on a root-equivalent container that is your call,
   not a default, so it is one Shift+Tab away rather than on. A small allow
   list lets read-only commands (`docker ps`, `docker logs`,
   `host zpool status`, …) run without a prompt so the prompts you do see are
   the ones that matter. `--dangerously-skip-permissions` is disabled
   (`disableBypassPermissionsMode`).

2. **Guard hook** (hard block for a short list) — `claude-guard` is a
   `PreToolUse` hook that inspects the *entire* command string before it runs
   and blocks `mkfs`, `wipefs`, `shred`, writing to a block device (`dd`,
   `cp`, `tee`, `>` redirection), `sgdisk --zap`, `zpool destroy`/`labelclear`,
   and `rm` on `/`, `/mnt/*`, `/mnt/*/appdata`, `/boot`, `/host/boot` or
   `/appdata`. Because it sees the whole string, wrapping the command in
   `host …`, `sh -c '…'` or `docker run … nsenter …`, using absolute paths,
   trailing slashes or `..` should not get around it; the test suite covers
   those cases, and two review passes looked for more. Claude Code's own
   `deny` rules are also present, but they only match the outermost command,
   so on their own they would not stop `host mkfs.ext4 /dev/sdb`.

   This list is deliberately short: it covers operations that should never be
   done from this container. Everything else that is risky (`zfs destroy`,
   `docker rm`, editing `/boot/config`) goes through the rules in layer 3 and
   your confirmation in layer 1. The guard matches text: a command built from
   shell variables, written to a script first, or obfuscated beyond simple
   quoting is outside its reach. It catches mistakes, not a determined
   bypass.

3. **CLAUDE.md rules** (behavioral) — Claude reads these on every start.
   "Always confirm before destructive operations" means Claude is told to ask
   *you* in the chat before proposing the command. Like any instruction to a
   language model, this holds most of the time, not all of the time; that is
   why it is the layer to rely on least.

All of this lives in `~/.claude/settings.json` inside the persisted home
directory and can be edited. It protects against mistakes, not against a
determined adversary with socket access. The file is seeded on first start;
on later starts, an existing file that predates the guard hook gets the
shipped defaults merged in underneath its own keys (a `settings.json.bak` is
kept).

## Attaching to the Session

Three ways in, all ending in the same terminal:

1. **Unraid web UI:** Docker tab → click the container → **Console**. The
   shell that opens attaches to the Claude session by itself.
2. **SSH from your computer**, one line (worth an alias):
   ```bash
   ssh -t root@<unraid-ip> docker exec -it claude-unraid-manager bash
   ```
3. **Phone or browser:** Remote Control, see below.

`Ctrl-b` then `d` detaches and leaves Claude running; closing the window does
the same. From the detached shell, `tmux attach -t main` goes back in.

On first start, attach and complete the login (claude.ai subscription or
Console account). Inside a container the browser cannot open on its own:
press `c` to copy the login URL, open it on any device, and paste the code it
shows back into the terminal when asked. If Claude Code asks whether to switch
its default to auto mode, answer no to keep the permission prompts.

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

The image is Debian slim plus the Claude Code native binary, the Docker CLI,
tmux, git, ssh, ripgrep and jq. Node.js is not included — Claude Code does not
need it — so MCP servers that are started through `npx` do not work inside
this container.

```bash
# On the Unraid terminal. Uses the appdata location configured under
# Settings → Docker, so no new share is created on systems that keep it elsewhere.
APPDATA=$(sed -n 's/^DOCKER_APP_CONFIG_PATH="\(.*\)"$/\1/p' /boot/config/docker.cfg)
APPDATA=${APPDATA%/}; APPDATA=${APPDATA:-/mnt/user/appdata}
cd "$APPDATA" && git clone https://github.com/mygrexit/claude-unraid-manager.git claude-unraid-manager-src
docker build -t claude-unraid-manager:local claude-unraid-manager-src
# Point the template at the local image instead of GHCR:
sed 's#<Repository>.*</Repository>#<Repository>claude-unraid-manager:local</Repository>#' \
  claude-unraid-manager-src/unraid-template.xml \
  > /boot/config/plugins/dockerMan/templates-user/my-claude-unraid-manager.xml

# Scanner and guard tests run without Docker or Unraid:
bash tests/run.sh
shellcheck -s bash entrypoint.sh generate-claude-md.sh host claude-guard claude-session claude-settings-merge tests/run.sh
```

## License

[MIT](LICENSE)
