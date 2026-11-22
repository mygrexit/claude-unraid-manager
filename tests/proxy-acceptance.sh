#!/bin/bash
# tests/proxy-acceptance.sh <manager-image>
#
# Starts the socket proxy exactly as unraid-template-socket-proxy.xml
# configures it (image, network, extra parameters, every variable) and checks
# the acceptance criteria against a real Docker daemon:
#   - container list, inspect, logs, stats, start, stop, restart work
#   - exec, run (privileged or not), create, volumes, networks, pull, build,
#     cp, export, rm, kill, update, prune are refused, and nothing changed
#   - the manager image reaches the proxy through a read-only mount, reports
#     proxy mode, refuses `host`, and writes a proxy-mode CLAUDE.md
# Needs Docker and python3 (template parsing). Used by CI; safe on a dev box:
# it only creates and removes containers named cum-acc-*.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${1:?usage: proxy-acceptance.sh <manager-image>}
TPL="$ROOT/unraid-template-socket-proxy.xml"
RAW=/var/run/docker.sock
PROXY=cum-acc-proxy
TARGET=cum-acc-target
SOCKDIR=$(mktemp -d)
# The proxy runs as uid 0 without capabilities, so it cannot write into a
# directory another user owns. On Unraid dockerd creates the bind directory
# as root; here it belongs to the CI user.
chmod 777 "$SOCKDIR"

FAIL=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }
raw() { env -u DOCKER_HOST docker "$@"; }
# Client side: the manager image's own Docker CLI, as root (the filtered
# socket is 0600 root), through the same read-only mount the template uses.
proxy() {
  raw run --rm -i -v "$SOCKDIR:/run/docker-proxy:ro" \
    -e DOCKER_HOST=unix:///run/docker-proxy/docker.sock --entrypoint docker "$IMAGE" "$@"
}

cleanup() {
  raw rm -f "$PROXY" "$TARGET" >/dev/null 2>&1
  raw volume rm cum-acc-vol >/dev/null 2>&1
  raw network rm cum-acc-net >/dev/null 2>&1
  rm -rf "$SOCKDIR"
}
trap cleanup EXIT

# ── Proxy, as the template defines it ────────────────────────────────────────
mapfile -t spec < <(python3 -I - "$TPL" <<'EOF'
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
print("repo\t" + t.findtext("Repository"))
print("network\t" + t.findtext("Network"))
print("extra\t" + (t.findtext("ExtraParams") or ""))
for c in t.findall("Config"):
    value = c.text if c.text is not None else (c.get("Default") or "")
    if c.get("Type") == "Variable":
        print("env\t%s=%s" % (c.get("Target"), value))
    elif c.get("Type") == "Path":
        print("path\t%s\t%s\t%s" % (value, c.get("Target"), c.get("Mode")))
EOF
)
args=(run -d --name "$PROXY")
for line in "${spec[@]}"; do
  IFS=$'\t' read -r kind a b c <<< "$line"
  case "$kind" in
    repo) repo=$a ;;
    network) args+=(--network "$a") ;;
    # Word splitting is intended: ExtraParams is a flat list of flags.
    # shellcheck disable=SC2206
    extra) args+=($a) ;;
    env) args+=(-e "$a") ;;
    path)
      # The socket directory goes to a temporary directory instead of the
      # host path the template names; everything else is used as is.
      [ "$b" = /socket ] && a=$SOCKDIR
      args+=(-v "$a:$b:$c") ;;
  esac
done
echo "proxy: docker ${args[*]} $repo"
if ! raw "${args[@]}" "$repo" >/dev/null; then
  echo "could not start the proxy"; exit 1
fi
for _ in $(seq 30); do [ -S "$SOCKDIR/docker.sock" ] && break; sleep 1; done
if [ -S "$SOCKDIR/docker.sock" ]; then pass "proxy socket created"; else fail "proxy socket missing"; raw logs "$PROXY"; exit 1; fi
net=$(raw inspect -f '{{.HostConfig.NetworkMode}}' "$PROXY")
if [ "$net" = none ]; then pass "proxy has no network"; else fail "proxy network mode: $net"; fi

raw run -d --name "$TARGET" alpine:3.21 sh -c 'echo hello-from-target; exec sleep 600' >/dev/null
sleep 1
before_containers=$(raw ps -aq | sort | tr '\n' ' ')
before_volumes=$(raw volume ls -q | sort | tr '\n' ' ')
before_networks=$(raw network ls -q | sort | tr '\n' ' ')
before_images=$(raw images -q | sort -u | tr '\n' ' ')

# ── Allowed ──────────────────────────────────────────────────────────────────
echo "proxy: allowed"
allowed() {
  local label=$1; shift
  if out=$("$@" 2>&1); then pass "$label"; else fail "$label: $out"; fi
}
allowed "docker version" proxy version
allowed "docker info" proxy info
allowed "docker ps -a" proxy ps -a
case "$(proxy ps -a --format '{{.Names}}')" in *"$TARGET"*) pass "ps lists the target" ;; *) fail "ps does not list the target" ;; esac
allowed "docker inspect" proxy inspect "$TARGET"
allowed "docker image inspect" proxy image inspect alpine:3.21
allowed "docker images" proxy images
allowed "docker logs" proxy logs "$TARGET"
case "$(proxy logs "$TARGET" 2>&1)" in *hello-from-target*) pass "logs content" ;; *) fail "logs content" ;; esac
allowed "docker stats --no-stream" proxy stats --no-stream "$TARGET"
allowed "docker top" proxy top "$TARGET"
allowed "docker events (bounded)" proxy events --since 1m --until 0s
allowed "docker restart" proxy restart -t 1 "$TARGET"
allowed "docker stop" proxy stop -t 1 "$TARGET"
allowed "docker start" proxy start "$TARGET"
state=$(raw inspect -f '{{.State.Running}}' "$TARGET")
if [ "$state" = true ]; then pass "target running after stop/start"; else fail "target state: $state"; fi

# ── Refused ──────────────────────────────────────────────────────────────────
echo "proxy: refused"
refused() {
  local label=$1; shift
  if out=$("$@" 2>&1 </dev/null); then
    fail "$label was allowed: $out"
  elif printf '%s' "$out" | grep -qiE 'forbidden|method not allowed'; then
    pass "$label refused by the proxy"
  else
    fail "$label failed, but not with a proxy refusal: $out"
  fi
}
refused "docker exec" proxy exec "$TARGET" true
refused "docker run --privileged" proxy run --rm --privileged alpine:3.21 true
refused "docker run" proxy run --rm alpine:3.21 true
refused "docker run -v /:/host" proxy run --rm -v /:/host alpine:3.21 true
refused "docker create" proxy create alpine:3.21
refused "docker volume create" proxy volume create cum-acc-vol
refused "docker volume ls" proxy volume ls
refused "docker network create" proxy network create cum-acc-net
refused "docker network ls" proxy network ls
refused "docker pull" proxy pull busybox:latest
refused "docker cp out of a container" proxy cp "$TARGET:/etc/passwd" -
refused "docker export" proxy export "$TARGET"
refused "docker rm" proxy rm -f "$TARGET"
refused "docker kill" proxy kill "$TARGET"
refused "docker update" proxy update --memory 64m "$TARGET"
refused "docker rename" proxy rename "$TARGET" cum-acc-renamed
refused "docker commit" proxy commit "$TARGET"
refused "docker container prune" proxy container prune -f
refused "docker image rm" proxy image rm alpine:3.21
refused "docker swarm init" proxy swarm init
# BuildKit may fail before it reaches the daemon (no buildx); either way no
# image may appear, which the state check below covers.
if printf 'FROM alpine:3.21\n' | proxy build -q -t cum-acc-built - >/dev/null 2>&1; then
  fail "docker build was allowed"
else
  pass "docker build fails"
fi

echo "proxy: nothing changed"
[ "$(raw ps -aq | sort | tr '\n' ' ')" = "$before_containers" ] && pass "containers unchanged" || fail "containers changed"
[ "$(raw volume ls -q | sort | tr '\n' ' ')" = "$before_volumes" ] && pass "volumes unchanged" || fail "volumes changed"
[ "$(raw network ls -q | sort | tr '\n' ' ')" = "$before_networks" ] && pass "networks unchanged" || fail "networks changed"
[ "$(raw images -q | sort -u | tr '\n' ' ')" = "$before_images" ] && pass "images unchanged" || fail "images changed"
[ "$(raw inspect -f '{{.Name}}' "$TARGET")" = "/$TARGET" ] && pass "target not renamed" || fail "target renamed"

# ── Manager image behind the proxy ───────────────────────────────────────────
echo "manager image behind the proxy"
mgr() {
  raw run --rm -v "$SOCKDIR:/run/docker-proxy:ro" \
    -e DOCKER_HOST=unix:///run/docker-proxy/docker.sock "$IMAGE" bash -c "$1"
}
if out=$(mgr 'docker ps -a --format "{{.Names}}"' 2>&1) && printf '%s' "$out" | grep -q "$TARGET"; then
  pass "docker ps through a read-only socket mount"
else
  fail "docker ps from the manager: $out"
fi
if [ "$(mgr docker-mode)" = proxy ]; then pass "docker-mode: proxy"; else fail "docker-mode in the manager"; fi
out=$(mgr 'host uptime; echo "status=$?"' 2>&1)
case "$out" in *"status=69"*) pass "host refused with 69" ;; *) fail "host: $out" ;; esac
if out=$(mgr 'generate-claude-md.sh >/dev/null && cat /workspace/CLAUDE.md' 2>&1); then
  printf '%s' "$out" | grep -q 'through the socket proxy' && pass "CLAUDE.md: proxy section" || fail "CLAUDE.md: no proxy section"
  printf '%s' "$out" | grep -q "$TARGET" && pass "CLAUDE.md: lists containers" || fail "CLAUDE.md: no containers"
  printf '%s' "$out" | grep -q '/run/docker-proxy' && fail "CLAUDE.md lists the proxy mount as a path" || pass "CLAUDE.md: proxy mount not listed as a path"
else
  fail "generate-claude-md.sh in the manager: $out"
fi
# With the raw socket mounted as well, the proxy is no boundary; say so.
out=$(raw run --rm -v "$RAW:/var/run/docker.sock" -v "$SOCKDIR:/run/docker-proxy:ro" \
  -e DOCKER_HOST=unix:///run/docker-proxy/docker.sock "$IMAGE" docker-mode)
if [ "$out" = full ]; then pass "raw socket plus proxy reports full"; else fail "raw+proxy reports: $out"; fi

echo "proxy log (refused requests):"
raw logs "$PROXY" 2>&1 | grep -iE 'blocked|not allowed' | head -5 | sed 's/^/  /'

if [ "$FAIL" -ne 0 ]; then
  echo "proxy acceptance: FAILED"
  exit 1
fi
echo "proxy acceptance: all passed"
