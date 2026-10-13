#!/bin/bash
# Exercises generate-claude-md.sh and claude-guard without Docker or Unraid.
# A fake `docker` on PATH answers the host scan and `docker ps`.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }
expect_contains()     { if grep -qF -- "$2" "$1"; then pass "contains: $2"; else fail "missing: $2"; fi; }
expect_not_contains() { if grep -qF -- "$2" "$1"; then fail "unexpected: $2"; else pass "absent: $2"; fi; }

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/share"
cp -r "$ROOT/claude-md" "$TMP/share/"
cp "$ROOT/host" "$TMP/bin/host"
chmod +x "$TMP/bin/host"

cat > "$TMP/bin/docker" <<'EOF'
#!/bin/bash
# Fake docker: `run` answers the host scan, `ps` lists two containers.
case "${1:-}" in
  run)
    [ "${FAKE_SCAN_FAIL:-0}" = 1 ] && exit 125
    cat "$FAKE_SCAN"
    ;;
  ps)
    printf -- '- plex (plexinc/pms-docker, Up 3 days)\n- nginx (nginx:alpine, Exited (0))\n'
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# [ -S ] needs a real socket inode; bind() leaves one behind.
python3 -I - "$TMP/docker.sock" <<'EOF'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
EOF

OWN_NETNS=$(readlink /proc/self/ns/net)

# Values arrive "|"-joined; mdNumDisks is listed before mdState on purpose.
write_scan() {
  local netns="$1"
  cat > "$TMP/scan.txt" <<EOF
::VERSION::7.0.1
::HOSTNAME::tower
::CPU::Intel(R) Core(TM) i5-12400
::RAM::62Gi
::UPTIME::up 3 days, 4 hours
::NETNS::${netns}
::ZFS_POOLS::tank 10.9T 4.2T 6.7T ONLINE|nvme 1.8T 900G 900G ONLINE|
::ZFS_DATASETS::tank/media 3T 6.7T /mnt/tank/media|nvme/appdata 50G 900G /mnt/nvme/appdata|
::ZFS_ENCRYPTED::nvme/secrets,
::BTRFS::Label: none  uuid: 79cc1003-f05f-4e01-babc-1e6ebe37e682|	Total devices 1 FS bytes used 1.17MiB|	devid    1 size 1.00GiB used 126.38MiB path /dev/loop3||Label: 'cache2'  uuid: 1111-2222|	Total devices 2 FS bytes used 100.00GiB|	devid    1 size 1.00TiB used 50.00GiB path /dev/sdc1|	devid    2 size 1.00TiB used 50.00GiB path /dev/sdd1||
::ARRAY_STATE::mdNumDisks=5|mdState=STARTED|
::SHARES::appdata,media,
::POOLS::cache,nvme,
::VMS::win11:shut off|Home Assistant:running|
::PLUGINS::dynamix.system.temp,unassigned.devices,
::USERSCRIPTS::zfs-snapshot:ZFS Snapshot:Daily snapshots of tank/media|cleanup-tmp:cleanup-tmp:|lock dataset:Lock Dataset:|
::NETWORK::eth0 UP 192.168.1.10/24,bond0 UP ,br0 UP 192.168.1.10/24,tunl0@NONE DOWN ,docker0 DOWN 172.17.0.1/16,br-79c60d7ee5a9 UP 172.18.0.1/16,virbr0 DOWN 192.168.122.1/24,veth1a2b3c UP fe80::1/64,vnet0 UNKNOWN fe80::2/64,shim-br0@br0 UP 192.168.1.10/24,tailscale1 UNKNOWN 100.110.244.19/32,
EOF
}

# Fake User Scripts schedule, keyed by script path like the plugin does.
cat > "$TMP/schedule.json" <<'EOF'
{
  "/boot/config/plugins/user.scripts/scripts/zfs-snapshot/script": { "frequency": "custom", "custom": "0 3 * * *", "id": "1" },
  "/boot/config/plugins/user.scripts/scripts/cleanup-tmp/script": { "frequency": "disabled", "id": "2" }
}
EOF

# Fake mountinfo: only /host/boot is a bind mount; /media must stay unlisted
# even though the directory exists in the base image.
cat > "$TMP/mountinfo" <<'EOF'
100 90 0:50 / / rw,relatime - overlay overlay rw
101 100 8:1 /boot /host/boot ro,relatime - vfat /dev/sda1 ro
102 100 0:5 / /proc rw,nosuid - proc proc rw
EOF

run_generator() {
  PATH="$TMP/bin:$PATH" \
  DOCKER_SOCK="$TMP/docker.sock" \
  CLAUDE_MD_SHARE="$TMP/share" \
  CLAUDE_MD_DEST="$TMP/CLAUDE.md" \
  FAKE_SCAN="$TMP/scan.txt" \
  MOUNTINFO="$TMP/mountinfo" \
  USERSCRIPTS_SCHEDULE="$TMP/schedule.json" \
  bash "$ROOT/generate-claude-md.sh" >/dev/null
}

# ── Scanner: full scan, host networking ──────────────────────────────────────
echo "scanner: full scan in host network mode"
rm -f "$TMP/CLAUDE.md"
write_scan "$OWN_NETNS"
run_generator
expect_contains "$TMP/CLAUDE.md" "Unraid 7.0.1"
expect_contains "$TMP/CLAUDE.md" "tank 10.9T 4.2T 6.7T ONLINE"
expect_contains "$TMP/CLAUDE.md" "nvme 1.8T 900G 900G ONLINE"
expect_contains "$TMP/CLAUDE.md" "nvme/appdata 50G 900G /mnt/nvme/appdata"
expect_contains "$TMP/CLAUDE.md" "Encrypted datasets: nvme/secrets"
expect_contains "$TMP/CLAUDE.md" "**Unraid array:** STARTED (mdNumDisks=5)"
expect_contains "$TMP/CLAUDE.md" "cache, nvme"
expect_contains "$TMP/CLAUDE.md" "**Shares:** appdata, media"
expect_contains "$TMP/CLAUDE.md" "- win11 (shut off)"
expect_contains "$TMP/CLAUDE.md" "- Home Assistant (running)"
expect_contains "$TMP/CLAUDE.md" "Label: 'cache2'  uuid: 1111-2222"
expect_contains "$TMP/CLAUDE.md" "Total devices 2 FS bytes used 100.00GiB"
expect_not_contains "$TMP/CLAUDE.md" "79cc1003-f05f-4e01-babc-1e6ebe37e682"
expect_not_contains "$TMP/CLAUDE.md" "/dev/sdc1"
expect_contains "$TMP/CLAUDE.md" "- unassigned.devices"
expect_contains "$TMP/CLAUDE.md" "- ZFS Snapshot — Daily snapshots of tank/media [custom 0 3 * * *]"
expect_contains "$TMP/CLAUDE.md" "- cleanup-tmp [disabled]"
expect_contains "$TMP/CLAUDE.md" "- Lock Dataset"
expect_not_contains "$TMP/CLAUDE.md" "- Lock Dataset —"
expect_contains "$TMP/CLAUDE.md" "- plex (plexinc/pms-docker, Up 3 days)"
expect_contains "$TMP/CLAUDE.md" "### Containers (2 total)"
expect_not_contains "$TMP/CLAUDE.md" "list truncated"
expect_contains "$TMP/CLAUDE.md" "Running in **host** network mode"
expect_contains "$TMP/CLAUDE.md" "## Custom"
expect_not_contains "$TMP/CLAUDE.md" "0 data disks"
expect_contains "$TMP/CLAUDE.md" "- eth0 UP 192.168.1.10/24"
expect_contains "$TMP/CLAUDE.md" "- bond0 UP"
expect_contains "$TMP/CLAUDE.md" "- br0 UP 192.168.1.10/24"
expect_contains "$TMP/CLAUDE.md" "- tailscale1 UNKNOWN 100.110.244.19/32"
for junk in veth1a2b3c vnet0 shim-br0 tunl0 docker0 br-79c60d7ee5a9 virbr0; do
  expect_not_contains "$TMP/CLAUDE.md" "$junk"
done
expect_not_contains "$TMP/CLAUDE.md" "| \`/media\` |"
expect_not_contains "$TMP/CLAUDE.md" "Boot Configuration (not mounted)"

# ── Scanner: bridge networking, custom section preserved ─────────────────────
echo "scanner: bridge network mode, custom section kept"
printf '## Custom\n\nkeep-me-across-restarts\n' > "$TMP/CLAUDE.md"
write_scan "net:[1]"
run_generator
expect_contains "$TMP/CLAUDE.md" "Running in **bridge** (or custom) network mode"
expect_contains "$TMP/CLAUDE.md" "keep-me-across-restarts"
if [ "$(grep -c '^## Custom' "$TMP/CLAUDE.md")" = 1 ]; then
  pass "single Custom section"
else
  fail "duplicate Custom section"
fi

# ── Scanner: pool-only setup (Unraid 7 without an array) ─────────────────────
echo "scanner: pool-only setup"
rm -f "$TMP/CLAUDE.md"
write_scan "net:[1]"
# Observed on a real Unraid 7 pool-only box: the array service is STARTED with no disks.
sed -i 's/^::ARRAY_STATE::.*/::ARRAY_STATE::mdNumDisks=0|mdState=STARTED|/' "$TMP/scan.txt"
run_generator
expect_contains "$TMP/CLAUDE.md" "**Unraid array:** STARTED with 0 data disks"

# ── Scanner: host scan fails ─────────────────────────────────────────────────
echo "scanner: host scan failure"
rm -f "$TMP/CLAUDE.md"
FAKE_SCAN_FAIL=1 run_generator
expect_contains "$TMP/CLAUDE.md" "Host scan failed"
expect_contains "$TMP/CLAUDE.md" "- plex (plexinc/pms-docker, Up 3 days)"
expect_contains "$TMP/CLAUDE.md" "Network mode unknown"
expect_not_contains "$TMP/CLAUDE.md" "0 data disks"
expect_not_contains "$TMP/CLAUDE.md" "Unraid unknown"

# ── Guard hook ───────────────────────────────────────────────────────────────
echo "guard: blocked commands"
guard() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$ROOT/claude-guard" 2>/dev/null
}
expect_blocked() { if guard "$1"; then fail "not blocked: $1"; else pass "blocked: $1"; fi; }
expect_allowed() { if guard "$1"; then pass "allowed: $1"; else fail "wrongly blocked: $1"; fi; }

expect_blocked 'mkfs.ext4 /dev/sdb1'
expect_blocked 'host mkfs.xfs -f /dev/sdc1'
expect_blocked "sh -c 'wipefs -a /dev/sdb'"
expect_blocked 'docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -i -n -p -- shred -n1 /dev/sdb'
expect_blocked 'dd if=/dev/zero of=/dev/sda bs=1M'
expect_blocked 'host dd of=/dev/nvme0n1 if=image.img'
expect_blocked 'host sgdisk --zap-all /dev/sdb'
expect_blocked 'host sgdisk -Z /dev/sdb'
expect_blocked 'host zpool destroy tank'
expect_blocked 'rm -rf /'
expect_blocked 'rm -rf /*'
expect_blocked 'rm -rf -- /mnt/user'
expect_blocked 'host rm -rf /mnt/cache/*'
expect_blocked 'rm -rf "/mnt/user"'
expect_blocked 'cd /tmp && rm -rf /host/boot'
expect_blocked 'rm -r /appdata'
# Bypass attempts found in review: absolute paths, trailing slashes,
# a harmless first argument, operators glued to the last argument.
expect_blocked 'host /sbin/mkfs.ext4 /dev/sdb'
expect_blocked 'host /bin/rm -rf /mnt/user'
expect_blocked './wipefs -a /dev/sdb'
expect_blocked 'host /usr/sbin/zpool destroy tank'
expect_blocked 'rm -rf /mnt/user/'
expect_blocked 'rm -rf /mnt/'
expect_blocked 'rm -rf /boot/'
expect_blocked 'rm -rf //'
expect_blocked 'rm -rf /workspace/tmp /mnt/user'
expect_blocked 'rm -rf ./x /boot'
expect_blocked 'host rm -rf /mnt/user>/dev/null 2>&1'
expect_blocked 'mkfs.ext4 /dev/sdb;'
expect_blocked 'wipefs;'
expect_blocked 'rm -rf /mnt/cache|true'
# Second review: path normalisation, appdata on the host side, other disk writers,
# simple quoting tricks.
expect_blocked 'host rm -rf /mnt/user/appdata'
expect_blocked 'host rm -rf /mnt/cache/appdata/'
expect_blocked 'rm -rf /mnt//user'
expect_blocked 'rm -rf /mnt/./user'
expect_blocked 'rm -rf /mnt/user/..'
expect_blocked 'rm -rf /mnt/user/Media/../..'
expect_blocked 'rm -rf /mnt/user/*/'
expect_blocked 'host cat image.img > /dev/sda'
expect_blocked 'host cat image.img >/dev/nvme0n1'
expect_blocked 'host cp image.img /dev/sdb'
expect_blocked 'host tee /dev/sdc < image.img'
expect_blocked "host sh -c 'mk''fs.ext4 /dev/sdb'"
expect_blocked 'host mk\fs.ext4 /dev/sdb'
expect_blocked "rm -rf '/mnt/user'"

echo "guard: allowed commands"
expect_allowed 'host zpool status'
expect_allowed 'host zfs destroy tank/media@autosnap-2024'
expect_allowed 'docker ps -a'
expect_allowed 'dd if=/dev/zero of=/tmp/test.img bs=1M count=10'
expect_allowed 'dd if=/dev/urandom of=/dev/null bs=1M count=10'
expect_allowed 'rm -rf /workspace/tmp'
expect_allowed 'rm -rf /mnt/user/Media/old-season'
expect_allowed 'rm -f /appdata/plex/logs/old.log'
expect_allowed 'echo "/mnt/user is the share root"'
expect_allowed 'ls --mkfs'
expect_allowed 'rm -rf /mnt/user/Media/'
expect_allowed 'rm -rf /tmp/a /mnt/user/Media/old'
expect_allowed 'ls /mnt/user/'
expect_allowed 'du -sh /mnt/user/* | sort -h'
expect_allowed 'cat /host/boot/config/go'
expect_allowed 'host sgdisk -p /dev/disk/by-id/ata-Samsung-baz'
expect_allowed 'host cat /proc/mdstat > /tmp/mdstat.txt'
expect_allowed 'host cp /mnt/user/appdata/plex/config.xml /tmp/'
expect_allowed 'rm -rf /mnt/user/appdata/plex/Cache'
expect_allowed 'curl -s https://example.com//path'

echo "guard: unparsable hook input fails closed"
if echo 'not json' | bash "$ROOT/claude-guard" 2>/dev/null; then
  fail "guard allowed unparsable input"
else
  pass "guard exits non-zero on unparsable input"
fi

# ── Settings merge ───────────────────────────────────────────────────────────
echo "settings merge"
DEFAULTS="$ROOT/settings.json"
merge() { bash "$ROOT/claude-settings-merge" "$DEFAULTS" "$1"; }
has_guard() { jq -e '[.hooks.PreToolUse[].hooks[].command] | index("/usr/local/bin/claude-guard") != null' "$1" >/dev/null; }

# Initial-release file: permissions only, no hooks.
cat > "$TMP/old.json" <<'EOF'
{ "permissions": { "deny": ["Bash(rm -rf /)", "Bash(mdcmd delete*)"] } }
EOF
merge "$TMP/old.json" > "$TMP/merged1.json"
if has_guard "$TMP/merged1.json"; then pass "guard added to hook-less file"; else fail "guard missing after merge"; fi
if jq -e '.permissions.deny | index("Bash(mdcmd delete*)") != null' "$TMP/merged1.json" >/dev/null; then pass "user deny list kept"; else fail "user deny list lost"; fi
if jq -e '.permissions.disableBypassPermissionsMode == "disable"' "$TMP/merged1.json" >/dev/null; then pass "bypass disabled added"; else fail "bypass setting missing"; fi

# User already has their own PreToolUse hook: it must survive, guard appended.
cat > "$TMP/own-hook.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/notify" } ] } ] } }
EOF
merge "$TMP/own-hook.json" > "$TMP/merged2.json"
if has_guard "$TMP/merged2.json"; then pass "guard appended next to user hook"; else fail "guard missing with user hook"; fi
if jq -e '[.hooks.PreToolUse[].hooks[].command] | index("/usr/local/bin/notify") != null' "$TMP/merged2.json" >/dev/null; then pass "user hook kept"; else fail "user hook lost"; fi

# Idempotent: merging the output again changes nothing.
merge "$TMP/merged2.json" > "$TMP/merged3.json"
if [ "$(jq -S . "$TMP/merged2.json")" = "$(jq -S . "$TMP/merged3.json")" ]; then pass "merge is idempotent"; else fail "merge not idempotent"; fi

if [ "$FAIL" = 0 ]; then
  echo "all tests passed"
else
  echo "TESTS FAILED"
  exit 1
fi
