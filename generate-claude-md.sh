#!/bin/bash
# generate-claude-md.sh — runs on every container start.
# Regenerates the "Detected Environment" section of CLAUDE.md while
# preserving the base rules and any user customizations below "## Custom".
#
# Paths can be overridden through the environment so the script can be
# exercised outside the container (see tests/run.sh).
set -euo pipefail

DEST="${CLAUDE_MD_DEST:-/workspace/CLAUDE.md}"
SHARE="${CLAUDE_MD_SHARE:-/usr/local/share/claude-unraid-manager}"
BASE="$SHARE/claude-md/base.md"
SNIP="$SHARE/claude-md/snippets"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
MARKER_START="## Detected Environment"
MARKER_CUSTOM="## Custom"

# ── Preserve user's custom section if it exists ──────────────────────────────
CUSTOM_SECTION=""
if [ -f "$DEST" ] && grep -q "^$MARKER_CUSTOM" "$DEST"; then
  CUSTOM_SECTION=$(sed -n "/^$MARKER_CUSTOM/,\$p" "$DEST")
fi

# ── Write the base rules ────────────────────────────────────────────────────
cp "$BASE" "$DEST"

# ── Language setting ─────────────────────────────────────────────────────────
if [ -n "${CLAUDE_LANG:-}" ]; then
  cat >> "$DEST" <<EOF

## Language

Respond in ${CLAUDE_LANG}. Use English for technical terms (Docker, ZFS, container names, CLI commands).

EOF
fi

# ── Host scan script ─────────────────────────────────────────────────────────
# Runs on the Unraid host through the `host` wrapper (nsenter into PID 1), so
# every command below is the host's own binary (GNU grep, zpool, mdcmd, ...).
# One ::KEY::value line per item. Values that span several lines are joined
# with "|" so the whole value stays on its ::KEY:: line; lists use ",".
read -r -d '' SCAN_SCRIPT <<'EOF' || true
echo "::VERSION::$(grep -oP "(?<=version=\")[^\"]+" /etc/unraid-version 2>/dev/null)"
echo "::HOSTNAME::$(hostname)"
echo "::CPU::$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)"
echo "::RAM::$(free -h 2>/dev/null | awk "/Mem:/{print \$2}")"
echo "::UPTIME::$(uptime -p 2>/dev/null || uptime | sed "s/.*up /up /" | sed "s/,.*load.*//")"
echo "::NETNS::$(readlink /proc/self/ns/net 2>/dev/null)"

if command -v zpool >/dev/null 2>&1; then
  echo "::ZFS_POOLS::$(zpool list -Ho name,size,alloc,free,health 2>/dev/null | tr "\n" "|")"
  echo "::ZFS_DATASETS::$(zfs list -Ho name,used,avail,mountpoint 2>/dev/null | head -30 | tr "\n" "|")"
  echo "::ZFS_ENCRYPTED::$(zfs get -Ho name,value encryption 2>/dev/null | grep -v "off$" | awk "{print \$1}" | tr "\n" ",")"
fi
if command -v btrfs >/dev/null 2>&1; then
  echo "::BTRFS::$(btrfs filesystem show 2>/dev/null | grep -E "Label|Total" | tr "\n" "|")"
fi
echo "::ARRAY_STATE::$(mdcmd status 2>/dev/null | grep -E "^mdState=|^mdNumDisks=|^mdNumParity=" | tr "\n" "|")"
echo "::SHARES::$(ls /mnt/user/ 2>/dev/null | tr "\n" ",")"
echo "::POOLS::$(ls /boot/config/pools/*.cfg 2>/dev/null | xargs -r -I{} basename {} .cfg | tr "\n" ",")"

if command -v virsh >/dev/null 2>&1; then
  echo "::VMS::$(virsh list --all --name 2>/dev/null | grep -v "^$" | tr "\n" ",")"
fi

echo "::PLUGINS::$(ls /boot/config/plugins/*.plg 2>/dev/null | xargs -r -I{} basename {} .plg | tr "\n" ",")"
# User Scripts plugin: one folder per script, optional description file.
echo "::USERSCRIPTS::$(for d in /boot/config/plugins/user.scripts/scripts/*/; do [ -d "$d" ] || continue; printf "%s:%s\n" "$(basename "$d")" "$(head -c 120 "$d/description" 2>/dev/null | tr "\n|" "  ")"; done | tr "\n" "|")"
echo "::NETWORK::$(ip -br addr show 2>/dev/null | grep -v "^lo " | awk "{print \$1,\$3}" | tr "\n" ",")"
EOF

SCAN=""
# First line of a ::KEY:: entry (values never contain newlines, see above).
get()   { printf '%s\n' "$SCAN" | sed -n "s/^::${1}:://p" | head -1; }
# A "|"-joined value as separate lines.
lines() { get "$1" | tr '|' '\n' | sed '/^$/d'; }
# A ","-joined value as "a, b, c".
csv()   { get "$1" | sed 's/,$//; s/,/, /g'; }

# ── Discovery scan ───────────────────────────────────────────────────────────
{
  echo ""
  echo "$MARKER_START"
  echo ""
  echo "_Auto-generated on $(date '+%Y-%m-%d %H:%M'). Do not edit — this section is refreshed on every container start._"
  echo ""

  if [ -S "$DOCKER_SOCK" ]; then
    cat "$SNIP/docker-socket.md"

    SCAN=$(host sh -c "$SCAN_SCRIPT" 2>/dev/null) || SCAN=""

    if [ -z "$SCAN" ]; then
      echo ""
      echo "_Host scan failed (helper image not available or Docker unreachable), so system, storage, VM and plugin details are missing. Restart the container to retry, or run \`host uptime\` to check._"
      echo ""
    else
      VERSION=$(get VERSION)
      HOST=$(get HOSTNAME)
      CPU=$(get CPU)
      RAM=$(get RAM)
      UPTIME=$(get UPTIME)

      echo ""
      echo "### System"
      echo ""
      echo "- **Unraid ${VERSION:-unknown}** | ${CPU:-unknown CPU} | ${RAM:-?} RAM | Hostname: ${HOST:-unknown}"
      echo "- ${UPTIME:-uptime unknown}"
      echo ""

      # ── Storage ────────────────────────────────────────────────────────────
      echo "### Storage"
      echo ""

      ZFS_POOLS=$(lines ZFS_POOLS)
      ZFS_DATASETS=$(lines ZFS_DATASETS)
      ZFS_ENCRYPTED=$(csv ZFS_ENCRYPTED)
      BTRFS=$(lines BTRFS)
      ARRAY_STATE=$(get ARRAY_STATE)
      POOLS=$(csv POOLS)

      if [ -n "$ZFS_POOLS" ]; then
        echo "**ZFS pools:**"
        echo ""
        echo '```'
        echo "NAME    SIZE   ALLOC  FREE   HEALTH"
        echo "$ZFS_POOLS"
        echo '```'
        echo ""
        if [ -n "$ZFS_DATASETS" ]; then
          echo "Datasets (name, used, avail, mountpoint; first 30):"
          echo ""
          echo '```'
          echo "$ZFS_DATASETS"
          echo '```'
          echo ""
        fi
        if [ -n "$ZFS_ENCRYPTED" ]; then
          echo "Encrypted datasets: ${ZFS_ENCRYPTED}"
          echo ""
        fi
        echo "Commands: \`host zpool status\`, \`host zfs list\`, \`host zpool scrub <pool>\`"
        echo ""
      fi

      if [ -n "$BTRFS" ]; then
        echo "**btrfs volumes:**"
        echo ""
        echo "$BTRFS" | awk '{print "  " $0}'
        echo ""
        echo "Commands: \`host btrfs filesystem show\`, \`host btrfs scrub status <mount>\`, \`host btrfs filesystem usage <mount>\`"
        echo ""
      fi

      ARRAY_MDSTATE=$(printf '%s' "$ARRAY_STATE" | grep -oP '(?<=mdState=)\w+' || true)
      ARRAY_DISKS=$(printf '%s' "$ARRAY_STATE" | grep -oP '(?<=mdNumDisks=)\d+' || true)
      if [ -n "$ARRAY_MDSTATE" ] && [ "${ARRAY_DISKS:-0}" != "0" ]; then
        echo "**Unraid array:** ${ARRAY_MDSTATE} (mdNumDisks=${ARRAY_DISKS})"
        echo ""
        echo "Commands: \`host mdcmd status\`"
        echo ""
      elif [ -n "$ARRAY_MDSTATE" ]; then
        # Unraid 7 can run the array service with no data disks at all.
        echo "**Unraid array:** ${ARRAY_MDSTATE} with 0 data disks (pool-only setup; all data lives on pools)."
        echo ""
      else
        echo "**Unraid array:** state unknown (\`mdcmd status\` returned nothing)."
        echo ""
      fi

      if [ -n "$POOLS" ]; then
        echo "**Pools** (from \`/boot/config/pools/\`): ${POOLS} — mounted at \`/mnt/<name>\`"
        echo ""
      fi

      if [ -z "$ZFS_POOLS" ] && [ -z "$BTRFS" ]; then
        echo "No ZFS or btrfs detected. Pools may use XFS (single-device)."
        echo ""
      fi

      SHARES=$(csv SHARES)
      if [ -n "$SHARES" ]; then
        echo "**Shares:** ${SHARES}"
        echo ""
      fi
    fi

    # ── Docker containers ────────────────────────────────────────────────────
    CONTAINERS=$(docker ps -a --format '- {{.Names}} ({{.Image}}, {{.Status}})' 2>/dev/null || true)
    CONTAINER_COUNT=$(printf '%s' "$CONTAINERS" | grep -c . || true)
    echo "### Containers (${CONTAINER_COUNT} total)"
    echo ""
    printf '%s\n' "$CONTAINERS" | head -40
    if [ "$CONTAINER_COUNT" -gt 40 ]; then
      echo "- … and $((CONTAINER_COUNT - 40)) more (list truncated; use \`docker ps -a\` for all)"
    fi
    echo ""
    echo "_Snapshot from container start: names, images and status only. Use \`docker ps -a\`, \`docker inspect <name>\` and \`docker logs <name>\` for current state and details._"
    echo ""

    if [ -n "$SCAN" ]; then
      # ── VMs ────────────────────────────────────────────────────────────────
      VMS=$(get VMS)
      if [ -n "$VMS" ]; then
        echo "### Virtual Machines"
        echo ""
        echo "$VMS" | tr ',' '\n' | sed '/^$/d' | sed 's/^/- /'
        echo ""
        echo "Commands: \`host virsh list --all\`, \`host virsh dominfo <vm>\`"
        echo ""
      fi

      # ── Plugins ────────────────────────────────────────────────────────────
      PLUGINS=$(get PLUGINS)
      if [ -n "$PLUGINS" ]; then
        echo "### Installed Plugins"
        echo ""
        echo "$PLUGINS" | tr ',' '\n' | sed '/^$/d' | sed 's/^/- /'
        echo ""
      fi

      # ── Network ────────────────────────────────────────────────────────────
      # ── User Scripts ───────────────────────────────────────────────────────
      USERSCRIPTS=$(lines USERSCRIPTS)
      if [ -n "$USERSCRIPTS" ]; then
        echo "### User Scripts"
        echo ""
        # "name:description" → "- name — description" (or just "- name")
        echo "$USERSCRIPTS" | awk -F: '{ name=$1; sub(/^[^:]*:/, ""); gsub(/^ +| +$/, ""); print ($0 == "") ? "- " name : "- " name " — " $0 }'
        echo ""
        echo "Scripts live in \`/host/boot/config/plugins/user.scripts/scripts/<name>/script\`; the schedule is in \`/host/boot/config/plugins/user.scripts/schedule.json\`."
        echo ""
      fi

      # Skip per-container (veth), per-VM (vnet) and macvlan shim interfaces;
      # they change constantly and say nothing about the host's network.
      NETWORK=$(get NETWORK | tr ',' '\n' | sed '/^$/d' | grep -vE '^(veth|vnet|shim-)' || true)
      if [ -n "$NETWORK" ]; then
        echo "### Host Network Interfaces"
        echo ""
        echo "$NETWORK" | awk '{print "- " $0}'
        echo ""
      fi
    fi

  else
    echo "**No Docker socket mounted.** Cannot manage containers or scan the host."
    echo "Add a Path mount for \`/var/run/docker.sock\` in the Docker template."
    echo ""
  fi

  # ── Mount analysis ──────────────────────────────────────────────────────────
  # Only bind mounts count: /media exists in the base image on its own.
  is_mounted() { awk -v d="$1" '$5 == d { found = 1 } END { exit !found }' "${MOUNTINFO:-/proc/self/mountinfo}"; }
  echo "### Available Paths"
  echo ""
  echo "| Path | Access | Contents |"
  echo "|------|--------|----------|"
  for d in /host/boot /appdata /media /downloads /user /vms /backup; do
    if is_mounted "$d"; then
      if [ -w "$d" ]; then mode="read-write"; else mode="read-only"; fi
      items=$( (find "$d" -mindepth 1 -maxdepth 1 2>/dev/null || true) | wc -l)
      echo "| \`$d\` | $mode | $items entries |"
    fi
  done
  echo ""
  echo "Paths not listed above are not mounted. The user can add them in the Docker template."

  # ── Boot access ────────────────────────────────────────────────────────────
  echo ""
  if is_mounted /host/boot && [ -w /host/boot ]; then
    cat "$SNIP/boot-rw.md"
  elif is_mounted /host/boot; then
    cat "$SNIP/boot-ro.md"
  else
    cat "$SNIP/no-boot.md"
  fi

  # ── Network mode ───────────────────────────────────────────────────────────
  # Host networking means this container shares the host's network namespace;
  # compare namespace identities instead of guessing from interface names
  # (Unraid uses eth0, bond0 or br0 on the host depending on its settings).
  echo ""
  echo "### Network Mode"
  echo ""
  LOCAL_NETNS=$(readlink /proc/self/ns/net 2>/dev/null || true)
  HOST_NETNS=$(get NETNS)
  if [ -n "$HOST_NETNS" ] && [ "$HOST_NETNS" = "$LOCAL_NETNS" ]; then
    echo "Running in **host** network mode. This container shares the host's network stack:"
    echo "all LAN services, VMs and other containers are reachable directly, and the host's ports are this container's ports."
  elif [ -n "$HOST_NETNS" ]; then
    echo "Running in **bridge** (or custom) network mode."
    echo ""
    echo "- Outbound connections work normally: the LAN, VMs, other containers' published ports and the internet are reachable (\`ssh user@<vm-ip>\` is fine)."
    echo "- Nothing can connect *into* this container unless a port is published."
    echo "- Containers on macvlan/ipvlan custom networks (e.g. \`br0\`) may be unreachable unless \"Host access to custom networks\" is enabled in Unraid's Docker settings."
    echo ""
    echo "Host networking is only needed when something must reach this container directly."
  else
    echo "Network mode unknown (host scan unavailable)."
  fi

} >> "$DEST"

# ── Append user's custom section (or create an empty one) ────────────────────
echo "" >> "$DEST"
if [ -n "$CUSTOM_SECTION" ]; then
  echo "$CUSTOM_SECTION" >> "$DEST"
else
  cat >> "$DEST" <<'EOF'
## Custom

Add your own instructions below this line.
They will be preserved when the container restarts.

EOF
fi

echo "CLAUDE.md generated at $DEST"
