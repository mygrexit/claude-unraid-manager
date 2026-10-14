# Getting Started

A step-by-step walk from an empty Docker tab to a working Claude session on
your Unraid server, including the phone. Read the
[README](../README.md) first for what this is and what it is not; this page
only covers the how.

Everything below was done on the author's two Unraid 7.3.3 servers. Other
versions and setups should behave the same, but have not been watched doing so.

## 1. What you need

- Unraid 7.x with Docker enabled.
- An Anthropic account. For the full experience, including Remote Control from
  your phone, a **claude.ai subscription** (Pro, Max, Team or Enterprise). A
  Claude Console API key also works, but then there is no Remote Control.
- About ten minutes, a browser on any device for the login, and a terminal
  (the Unraid web UI's console is enough).
- The willingness to read what Claude proposes before you approve it. If you
  would not do the same work yourself on the command line, stop here.

## 2. Install from Community Applications

Web UI → **Apps** → search for *claude-unraid-manager* → **Install**. It is
marked as beta. Unraid stores the template on the flash drive, as it does for
every container; nothing else is written there.

## 3. Fill in the template

Settings worth a look; leave everything else at its default:

| Field | What to do |
|---|---|
| **Data** and **Workspace** | Default is `/mnt/user/appdata/claude-unraid-manager/...`. If your appdata share lives somewhere else (for example `/mnt/cache/appdata`), change both paths now. Pointing at a path under `/mnt/user` that does not exist makes Unraid create a new share. |
| **Timezone** | Your timezone, e.g. `Europe/Berlin`. |
| **Language** | Leave empty for English, or `de`, `fr`, ... for answers in that language. |
| **Anthropic API Key** | Leave empty if you will log in with a claude.ai subscription (recommended). Fill it only for API-key billing; Remote Control is then disabled. |
| **Unraid Boot Config** | Leave read-only for now. |

Do **not** enable Privileged. It is not needed; host commands run through a
helper container.

Click **Apply**. Unraid pulls the image (about 500 MB) and starts the
container. Wait until the Docker tab shows it as started, then click the
container icon → **Logs**. You should see:

```
CLAUDE.md generated at /workspace/CLAUDE.md
Claude Unraid Manager is running.
  Attach: docker exec -it claude-unraid-manager tmux attach -t main
  Remote: open the Claude app and look for 'claude-unraid-manager'
  Login:  not logged in yet — attach and complete the login once
```

## 4. Open the session

Claude runs inside a `tmux` session in the container. Any interactive shell
in the container attaches to it automatically, so:

- **From the web UI:** Docker tab → click the container icon → **Console**.
  You are in the Claude session.
- **From your computer over SSH**, one line:
  ```
  ssh -t root@<unraid-ip> docker exec -it claude-unraid-manager bash
  ```
  Put it in an alias (`alias unraid-claude='ssh -t root@... docker exec -it claude-unraid-manager bash'`)
  and it is one word away. Works over Tailscale too.

**Leaving the session without stopping Claude:** press `Ctrl-b`, release, then
`d`. That detaches; Claude keeps running, and you land in a plain shell that
tells you how to get back (`tmux attach -t main`) or leave (`exit`). Simply
closing the console window has the same effect. Do not type `/exit` in Claude
unless you mean it; Claude would quit and the wrapper restarts it a few
seconds later.

## 5. Log in (once)

On the very first start Claude Code shows its setup:

1. **Theme picker** – pick one with the arrow keys, `Enter`.
2. **Login method** – choose the claude.ai subscription (or the Console
   account if you use an API key).
3. **Browser login** – inside a container the browser cannot open by itself.
   Claude Code shows a URL; press `c` to copy it, or type it into any browser,
   on your phone if you like. Sign in there.
4. The browser shows a **code**. Paste it into the terminal where it says
   *Paste code here if prompted*, then `Enter`.
5. `Login successful` → `Enter`.
6. If Claude Code asks whether to make **auto mode** its default, say no:
   this container is set up to ask you before it acts (Manual mode), and auto
   mode stays one `Shift+Tab` away if you ever want it for a session. Note
   that a conversation switched to auto mode comes back in auto mode after a
   container restart, since the last conversation is resumed; switch back or
   start a fresh one with `/clear`.

The login is stored in the **Data** folder and survives restarts and image
updates. You will not be asked again.

## 6. First questions

Claude has already read the generated `CLAUDE.md` with your pools, shares,
containers, VMs and plugins. Good first prompts:

- *What do you know about this server?*
- *Which containers are not running, and why?*
- *How full are my pools, and what is taking the space?*

Read-only commands (`docker ps`, `docker logs`, `host zpool status`, ...) run
without asking. Anything else shows a **permission prompt** first: the exact
command, and the choice to allow once, allow always, or deny. That prompt is
your main safety control. Read it. The footer of the screen shows the current
mode; it should say *manual*. `Shift+Tab` cycles modes, and *auto mode* hands
those decisions to a classifier instead of you.

A few commands (formatting disks, `rm -rf` on a share root, writing to a block
device) are blocked by a guard hook even if you say yes; if you really want one
of those, do it yourself from the Unraid terminal. Some prompts carry an
extra line starting with `claude-guard:` (for example *downloads and runs
code from the network*). That is the guard telling you why this command
deserves a second look; it appears in every permission mode. If a command
like that came out of a container log or a file Claude just read, be
suspicious: that is exactly how an attacker would try to use Claude.

## 7. Give Claude more access (optional, later)

By default Claude sees the flash drive read-only and no shares. To extend
that: Docker tab → container → **Edit**:

- **Unraid Boot Config** → change `Read Only` to `Read/Write` to let Claude
  install plugins or edit templates. Claude is told to show you the change
  before writing.
- **Container App Data** (advanced view) → set to `/mnt/user/appdata` (or
  your path) read-only, so Claude can inspect other containers' configs.
- **Any share** → *Add another Path* at the bottom of the edit page: Host path
  `/mnt/user/<share>`, Container path `/<share>` (any name you like, outside
  `/root`), Access Mode read-only unless Claude should change files. The template's "Example:
  a share for Claude" entry is the same thing with `/media` pre-filled as the
  container path. You do not have to plan this ahead: Claude sees the names of
  all your shares and will tell you these steps when a question needs one of
  them.

**Apply** restarts the container; `CLAUDE.md` is regenerated and now lists
the new paths. Your own notes under `## Custom` at the end of `CLAUDE.md`
survive this.

## 8. From your phone

1. Make sure the session is logged in (step 5) and the container is running.
2. The first time, Claude Code may show a one-time dialog **Enable Remote
   Control** in the terminal; confirm it.
3. On your phone open the **Claude app**, tap **Code** in the navigation. The
   session appears in the list under the container's name
   (`claude-unraid-manager`, or what you set as *Remote Control Name*) with a
   computer icon and a green dot while online. The same list is at
   [claude.ai/code](https://claude.ai/code) in any browser.
4. Tap it and chat. Permission prompts appear on the phone too.

If it is missing: Remote Control needs a claude.ai subscription login; with an
API key or a token from `claude setup-token` it is not available, and Claude
Code says so in the terminal shortly after start.

## 9. Updating, stopping, removing

- **Update:** Docker tab → container → **Force Update** when a new image is
  out. Your login, settings and history live in the Data folder and are kept.
  If the new image brings new default settings, they are merged in underneath
  yours; a `settings.json.bak` is left next to the file.
- **Stop/Start:** as any container. `CLAUDE.md` is rebuilt on every start; the
  last conversation is resumed.
- **Remove:** remove the container, then delete the two appdata folders. The
  flash drive only holds the template Unraid saved when you installed it.

## 10. If something looks wrong

- Container log says `Host scan failed`: the helper image could not be pulled.
  Check internet access, restart the container.
- `Claude exited ... Restarting in 5 s` keeps repeating: attach and read the
  message above it; after five quick exits the wrapper stops and leaves the
  output on screen.
- Health shows *unhealthy*: the `claude` process is gone. Restart the
  container; if it repeats, open an issue with the log.
- Anything else: [issues](https://github.com/mygrexit/claude-unraid-manager/issues),
  with the container log and the `## Detected Environment` part of your
  `CLAUDE.md` (check it for anything you do not want to share first).
