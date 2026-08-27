#!/usr/bin/env bash
#
# Smoke test for the DeepSeek Harness container: boots the image the way
# `pnpm dsh web` would, exercises the harness-home and workspace volumes
# (including persistence across a restart), and verifies the environment →
# `dsh web` flag mapping (port, bind, optional /api identities).
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/smoke-test.sh
# Exits nonzero if any check failed.
set -uo pipefail

IMAGE="${DSH_IMAGE:-dsh:dev}"
PREFIX="dsh-smoke-$$"
PORT=$(( ( RANDOM % 20000 ) + 20000 ))
FAILED=0

volumes=()
containers=()
cleanup() {
  for v in "${volumes[@]:-}"; do docker volume rm "$v" >/dev/null 2>&1 || true; done
  for c in "${containers[@]:-}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

HVOL="dsh-home-$PREFIX"
WVOL="dsh-workspace-$PREFIX"
HVOL2="dsh-home2-$PREFIX"
docker volume create "$HVOL" >/dev/null
docker volume create "$WVOL" >/dev/null
docker volume create "$HVOL2" >/dev/null
volumes=("$HVOL" "$WVOL" "$HVOL2")

pass()  { echo "PASS: $*"; }
fail()  { echo "FAIL: $*"; FAILED=1; }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
wait_ready() { # wait_ready <container>  → waits for the "dsh web: http" line
  local cid="$1" i
  for i in $(seq 1 90); do
    docker logs "$cid" 2>&1 | grep -q "dsh web: http" && return 0
    sleep 1
  done
  return 1
}

echo "== image sanity =="
check "image exists" docker image inspect "$IMAGE" >/dev/null

echo "== CLI modes (no server) =="
check "dsh --version prints a version" docker run --rm "$IMAGE" --version
check "dsh web --help prints the web flag family" \
  docker run --rm "$IMAGE" web --help
check "dsh --profile web --dump-default-config composes the bundles" \
  docker run --rm \
    -v "$HVOL:/home/dsh/.dsh" -v "$WVOL:/workspace" \
    "$IMAGE" --profile web --dump-default-config

echo "== first-boot seeding (fresh volume) =="
check "defaults seeded: settings.yaml" \
  docker run --rm --entrypoint /bin/sh \
    -v "$HVOL:/home/dsh/.dsh" -v "$WVOL:/workspace" \
    "$IMAGE" -c 'test -f /home/dsh/.dsh/settings.yaml'
check "defaults seeded: AGENTS.md" \
  docker run --rm --entrypoint /bin/sh \
    -v "$HVOL:/home/dsh/.dsh" -v "$WVOL:/workspace" \
    "$IMAGE" -c 'grep -q "Container environment briefing" /home/dsh/.dsh/AGENTS.md'

echo "== boot the web GUI with volumes and 0.0.0.0 bind (faithful mode) =="
CID=$(docker run -d -p "$PORT:3080" \
  -e DSH_WEB_BIND=0.0.0.0 \
  -e DSH_WEB_PORT=3080 \
  -v "$HVOL:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID")
echo "  container $CID on host port $PORT"

if wait_ready "$CID"; then pass "web server ready (URL line logged)"
else fail "web server never printed its URL line"; docker logs "$CID" 2>&1 | tail -25; fi

check "GET / returns 200 inside the container" \
  docker exec "$CID" curl -fsS -o /dev/null "http://127.0.0.1:3080/"
check "GET / returns 200 via the published port" \
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"

echo "== runs as the unprivileged dsh user =="
uid="$(docker exec "$CID" id -u)"
check "process runs as a non-root user" test "$uid" != "0"
echo "  death by non-root user = $(docker exec "$CID" id -un 2>/dev/null)"

echo "== harness home volume (self-modification lives here) =="
check "profile layout was auto-initialized on the volume" \
  docker exec "$CID" test -f /home/dsh/.dsh/profiles/web/package.json
check "profile node_modules fallback was healed at boot" \
  docker exec "$CID" test -e /home/dsh/.dsh/profiles/node_modules/react
own_home="$(docker exec "$CID" stat -c %U /home/dsh/.dsh)"
check "DSH_HOME owned by dsh" test "$own_home" = "dsh"
check "user patch layer is present (hot-reloaded overrides)" \
  docker exec "$CID" test -f /home/dsh/.dsh/profiles/web/cordis.patch.yml

echo "== workspace volume (the agent's working directory) =="
# PID 1 is tini now; the main harness is the `apps/cli/lib/bin.js web` process
# (the web app also spawns bin.js runner children). Pick the numerically
# smallest matching pid — that is the boot-time server. Grep-able pattern
# matches the probe shell too, so the numeric sort is what selects the server.
dshpid="$(docker exec "$CID" bash -c 'for p in /proc/[0-9]*; do if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q "lib/bin.js web"; then echo "${p#/proc/}"; fi; done | sort -n | head -1')"
cwd="$(docker exec "$CID" bash -c "readlink /proc/${dshpid}/cwd")"
check "harness process cwd is the workspace (/workspace)" test "$cwd" = "/workspace"
check "workspace writable by the agent user (write a file)" \
  docker exec "$CID" sh -c 'echo "agent wrote this" > /workspace/.smoke-marker'
check "agent file is visible to a second container on the same volume" \
  docker run --rm --entrypoint /bin/sh -v "$WVOL:/workspace" "$IMAGE" \
    -c 'grep -q "agent wrote this" /workspace/.smoke-marker'
own_ws="$(docker exec "$CID" stat -c %U /workspace)"
check "workspace owned by dsh" test "$own_ws" = "dsh"

echo "== workspace persistence across a restart =="
CID_RESTART="dsh-restart-$PREFIX"
docker rename "$CID" "$CID_RESTART" >/dev/null
docker stop "$CID_RESTART" >/dev/null
docker rm "$CID_RESTART" >/dev/null
CID=$(docker run -d -p "$PORT:3080" \
  -e DSH_WEB_BIND=0.0.0.0 -e DSH_WEB_PORT=3080 \
  -v "$HVOL:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers=("$CID")
wait_ready "$CID"
check "agent file still present after container recreation" \
  docker exec "$CID" grep -q "agent wrote this" /workspace/.smoke-marker
check "harness profile still present after recreation" \
  docker exec "$CID" test -f /home/dsh/.dsh/profiles/web/package.json

echo "== env → dsh web flag mapping =="
PORT2=$((PORT+1))
CID2=$(docker run -d -p "$PORT2:8080" \
  -e DSH_WEB_BIND=0.0.0.0 \
  -e DSH_WEB_PORT=8080 \
  -e DSH_WEB_TRUSTED_HOSTS="smoke.example.com" \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID2")
wait_ready "$CID2"
check "DSH_WEB_PORT=8080 serves on 8080" \
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT2/"
IP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CID2")
trusted_code=$(http_code -H "Host: smoke.example.com" "http://$IP2:8080/api/smoke-probe")
untrusted_code=$(http_code -H "Host: evil.example.com" "http://$IP2:8080/api/smoke-probe")
if [ "$trusted_code" != "403" ] && [ "$trusted_code" != "000" ]; then
  pass "/api fence accepts the DSH_WEB_TRUSTED_HOSTS authority (HTTP $trusted_code)"
else
  fail "/api fence rejected the trusted authority (HTTP $trusted_code)"
fi
if [ "$untrusted_code" = "403" ]; then
  pass "/api fence refuses an untrusted Host (HTTP 403)"
else
  fail "/api fence did not refuse untrusted Host (HTTP $untrusted_code)"
fi

echo "== first-boot seeding is idempotent (user edits survive) =="
PORT3=$((PORT+6))
docker exec "$CID2" sh -c 'echo "USER EDITED" >> /home/dsh/.dsh/AGENTS.md'
CID3=$(docker run -d -p "$PORT3:8080" \
  -e DSH_WEB_BIND=0.0.0.0 -e DSH_WEB_PORT=8080 \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID3")
check "user AGENTS.md edit survives a recreation (no re-seed overwrite)" \
  docker exec "$CID3" grep -q "USER EDITED" /home/dsh/.dsh/AGENTS.md
docker rm -f "$CID3" >/dev/null 2>&1

echo "== baked pnpm global config (plugin installs work out of the box) =="
check "pnpm on PATH" docker run --rm --entrypoint /bin/bash "$IMAGE" -lc 'command -v pnpm'
config="$(docker run --rm --entrypoint /bin/bash -e HOME=/home/dsh "$IMAGE" -lc 'pnpm config get dangerouslyAllowAllBuilds')"
check "pnpm dangerouslyAllowAllBuilds is set globally" test "$config" = "true"
store="$(docker run --rm --entrypoint /bin/bash -e HOME=/home/dsh -w /tmp "$IMAGE" -lc 'pnpm store path 2>/dev/null')"
check "pnpm store lives on the harness volume" \
  test "${store#/home/dsh/.dsh/.pnpm-store}" != "$store"

echo "== network mode: bundled reverse proxy (DSH_WEB_PROXY=1) =="
PORT_PX=$((PORT+7))
CIDPX=$(docker run -d -p "$PORT_PX:3080" \
  -e DSH_WEB_PROXY=1 \
  -e DSH_WEB_BIND=0.0.0.0 \
  -e DSH_WEB_PORT=3080 \
  -e DSH_WEB_TRUSTED_HOSTS="px.example.com" \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CIDPX")
wait_ready "$CIDPX"
check "proxy mode: GET / 200 via the published port" \
  curl -fsS --retry 6 --retry-connrefused --retry-delay 1 -o /dev/null \
    -H "Host: px.example.com" "http://127.0.0.1:$PORT_PX/"
IPPX=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CIDPX")
ws_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -H "Host: px.example.com" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "http://$IPPX:3080/api/events.mux")
if [ "$ws_code" = "101" ] || [ "$ws_code" = "200" ]; then
  pass "proxy mode: WebSocket upgrade to /api/events.mux got $ws_code (no 403)"
else
  fail "proxy mode: WS upgrade failed (HTTP $ws_code)"
fi
px_ok=$(http_code -H "Host: px.example.com" "http://$IPPX:3080/api/smoke-probe")
if [ "$px_ok" != "403" ] && [ "$px_ok" != "000" ]; then
  pass "proxy mode: Host allow-list forwards the trusted authority (HTTP $px_ok)"
else
  fail "proxy mode: trusted authority rejected (HTTP $px_ok)"
fi
px_deny=$(http_code -H "Host: evil.example.com" "http://$IPPX:3080/api/smoke-probe")
if [ "$px_deny" = "403" ]; then
  pass "proxy mode: untrusted Host refused by the proxy (HTTP 403)"
else
  fail "proxy mode: untrusted Host not refused (HTTP $px_deny)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE TEST: ALL CHECKS PASSED"
else
  echo "SMOKE TEST: $FAILED check(s) FAILED"
fi
exit "$FAILED"
